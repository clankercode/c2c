(* B116: DELETE /binding/<binding_id> must require a signed owner proof.

   B111 found the revocation handler validated only binding-ID shape, then
   removed any matching binding and disclosed whether it existed — a bare
   binding ID acted as both authority and an existence oracle.

   Contract under test (HTTP-level, against the PRODUCTION make_callback on
   a TOKEN-CONFIGURED loopback server — Relay_test_support_real):

   1. anonymous / bare-ID DELETE is rejected (401) and the binding survives;
   2. the anonymous rejection is byte-identical for an existing and a
      missing binding (no existence oracle);
   3. a proof signed by the binding's machine Ed25519 key revokes it;
   4. a proof signed by the binding's phone Ed25519 key revokes it;
   5. a valid proof from an unrelated key is rejected with the SAME
      status + body as the same key probing a nonexistent binding
      (no existence oracle via valid-signature probing);
   6. replaying a previously-successful revoke request against a
      re-created binding is rejected (nonce replay cache);
   7. a stale-timestamp proof is rejected;
   8. malformed binding IDs still 400 without touching the store.

   All cases run inside token-configured brackets: /binding/* is a
   self-auth route, so these tests prove the HANDLER enforces the proof
   (not the outer gate / dev-mode fallthrough). *)

module RTSR = Relay_test_support_real

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let gen_identity () = Relay_identity.generate ()

let pk_b64 (id : Relay_identity.t) = b64url_encode id.Relay_identity.public_key

let test_token = "b116-test-token"

(* Distinct binding ids per test case: the nonce cache and (in some cases)
   rate-limiter state are process-global. *)

let add_binding relay ~binding_id ~(machine : Relay_identity.t)
    ~(phone : Relay_identity.t) =
  Relay.InMemoryRelay.add_observer_binding relay ~binding_id
    ~phone_ed25519_pubkey:(pk_b64 phone)
    ~phone_x25519_pubkey:(pk_b64 phone)
    ~machine_ed25519_pubkey:(pk_b64 machine)
    ~provenance_sig:"test-provenance"

let binding_exists relay ~binding_id =
  Relay.InMemoryRelay.get_observer_binding relay ~binding_id <> None

let revoke_body_of_proof (p : Relay_signed_ops.signed_proof) : Yojson.Safe.t =
  `Assoc [
    ("revoke_pk", `String p.Relay_signed_ops.identity_pk_b64);
    ("ts", `String p.Relay_signed_ops.ts);
    ("nonce", `String p.Relay_signed_ops.nonce);
    ("sig", `String p.Relay_signed_ops.sig_b64);
  ]

let delete ~base_url ~binding_id ?(body = `Assoc []) () =
  RTSR.call_json ~base_url ~meth:`DELETE ~path:("/binding/" ^ binding_id)
    ~body ()

let signed_delete ~base_url ~binding_id (id : Relay_identity.t) =
  let proof = Relay_signed_ops.sign_binding_revoke id ~binding_id in
  delete ~base_url ~binding_id ~body:(revoke_body_of_proof proof) ()

(* DELETE with an arbitrary Authorization header (exercises the outer
   Ed25519 request verifier's pre-dispatch path). *)
let delete_with_auth ~base_url ~binding_id ~auth ?(body = `Assoc []) () =
  RTSR.call ~base_url ~meth:`DELETE ~path:("/binding/" ^ binding_id)
    ~headers:[ ("Content-Type", "application/json"); ("Authorization", auth) ]
    ~body:(Yojson.Safe.to_string body) ()

let error_code json =
  match json with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "error_code" fields with
     | Some (`String c) -> c
     | _ -> "")
  | _ -> ""

let is_ok_true json =
  match json with
  | Some (`Assoc fields) -> List.assoc_opt "ok" fields = Some (`Bool true)
  | _ -> false

(* Normalized response headers for oracle comparison: sorted, lowercased
   keys, with the volatile Date header dropped. A header-level existence
   oracle (e.g. a rate-limit or cache header only present for a real
   binding) would surface as a diff here even though the JSON body matches. *)
let headers_norm r =
  Cohttp.Header.to_list r.RTSR.headers
  |> List.map (fun (k, v) -> (String.lowercase_ascii k, v))
  |> List.filter (fun (k, _) -> k <> "date")
  |> List.sort compare

let show_headers hs =
  String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) hs)

(* --- 1 + 2: anonymous bare-ID revoke rejected, no existence oracle --- *)

let test_anonymous_revoke_rejected_and_uniform () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let existing = "b116-anon-exists" and missing = "b116-anon-missing" in
    add_binding relay ~binding_id:existing ~machine ~phone;
    let open Lwt.Infix in
    delete ~base_url ~binding_id:existing () >>= fun r_exists ->
    delete ~base_url ~binding_id:missing () >|= fun r_missing ->
    Alcotest.(check int) "anonymous revoke of existing binding is 401"
      401 (RTSR.status_code r_exists);
    Alcotest.(check bool) "binding survives anonymous revoke attempt"
      true (binding_exists relay ~binding_id:existing);
    Alcotest.(check int) "anonymous revoke of missing binding is 401"
      401 (RTSR.status_code r_missing);
    Alcotest.(check string)
      "identical body for existing vs missing binding (no oracle)"
      r_exists.RTSR.body_text r_missing.RTSR.body_text;
    Alcotest.(check string)
      "identical headers for existing vs missing binding (no header oracle)"
      (show_headers (headers_norm r_exists))
      (show_headers (headers_norm r_missing)))

(* --- 3: machine-key owner proof revokes --- *)

let test_machine_key_revoke_succeeds () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-machine-ok" in
    add_binding relay ~binding_id ~machine ~phone;
    let open Lwt.Infix in
    signed_delete ~base_url ~binding_id machine >|= fun r ->
    Alcotest.(check int) "machine-key revoke is 200" 200 (RTSR.status_code r);
    Alcotest.(check bool) "response ok:true" true (is_ok_true r.RTSR.json);
    Alcotest.(check bool) "binding removed" false
      (binding_exists relay ~binding_id))

(* --- 4: phone-key owner proof revokes --- *)

let test_phone_key_revoke_succeeds () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-phone-ok" in
    add_binding relay ~binding_id ~machine ~phone;
    let open Lwt.Infix in
    signed_delete ~base_url ~binding_id phone >|= fun r ->
    Alcotest.(check int) "phone-key revoke is 200" 200 (RTSR.status_code r);
    Alcotest.(check bool) "binding removed" false
      (binding_exists relay ~binding_id))

(* --- 5: wrong-key proof rejected, uniformly with missing binding --- *)

let test_wrong_key_rejected_uniform () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let attacker = gen_identity () in
    let existing = "b116-wrongkey-exists" and missing = "b116-wrongkey-miss" in
    add_binding relay ~binding_id:existing ~machine ~phone;
    let open Lwt.Infix in
    signed_delete ~base_url ~binding_id:existing attacker >>= fun r_exists ->
    signed_delete ~base_url ~binding_id:missing attacker >|= fun r_missing ->
    Alcotest.(check int) "wrong-key revoke of existing binding is 401"
      401 (RTSR.status_code r_exists);
    Alcotest.(check string) "wrong-key denial code is revoke_denied"
      "revoke_denied" (error_code r_exists.RTSR.json);
    Alcotest.(check bool) "binding survives wrong-key attempt" true
      (binding_exists relay ~binding_id:existing);
    Alcotest.(check int) "wrong-key revoke of missing binding is 401"
      401 (RTSR.status_code r_missing);
    Alcotest.(check string)
      "identical body for existing vs missing binding (no oracle)"
      r_exists.RTSR.body_text r_missing.RTSR.body_text;
    Alcotest.(check string)
      "identical headers for existing vs missing binding (no header oracle)"
      (show_headers (headers_norm r_exists))
      (show_headers (headers_norm r_missing)))

(* --- 6: replaying a successful revoke against a re-created binding.
   The replay must deny through the SAME uniform revoke_denied body as a
   non-owner (no oracle) — not a distinct nonce_replay code. *)

let test_replay_rejected () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-replay-bind" in
    add_binding relay ~binding_id ~machine ~phone;
    let proof = Relay_signed_ops.sign_binding_revoke machine ~binding_id in
    let body = revoke_body_of_proof proof in
    let open Lwt.Infix in
    delete ~base_url ~binding_id ~body () >>= fun r1 ->
    Alcotest.(check int) "first signed revoke is 200" 200
      (RTSR.status_code r1);
    (* Re-pair with the SAME binding id and keys, then replay the captured
       request verbatim — the persisted nonce store must reject it. *)
    add_binding relay ~binding_id ~machine ~phone;
    delete ~base_url ~binding_id ~body () >|= fun r2 ->
    Alcotest.(check int) "replayed revoke is 401" 401 (RTSR.status_code r2);
    Alcotest.(check string) "replay denies uniformly (no nonce_replay oracle)"
      "revoke_denied" (error_code r2.RTSR.json);
    Alcotest.(check bool) "re-created binding survives the replay" true
      (binding_exists relay ~binding_id))

(* --- 6b: a valid-signature NON-OWNER proof must NOT consume a nonce
   (finding 1: anonymous nonce-store growth / DoS). We prove it indirectly
   but soundly: an attacker sends binding_id B with nonce N (denied,
   non-owner). If N had been recorded, the owner's later proof reusing N
   for the SAME binding would be rejected as a replay. Instead the owner
   revoke with nonce N must SUCCEED — showing the non-owner attempt left
   the nonce store untouched. *)

let test_non_owner_does_not_consume_nonce () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let attacker = gen_identity () in
    let binding_id = "b116-nonowner-nonce" in
    add_binding relay ~binding_id ~machine ~phone;
    (* Attacker signs with a fixed nonce N over the SAME binding_id. *)
    let ts = Printf.sprintf "%.6f" (Unix.gettimeofday ()) in
    let nonce = Relay_signed_ops.random_nonce_b64 () in
    let sign id =
      let pk = pk_b64 id in
      let blob = Relay_identity.canonical_msg
        ~ctx:Relay_common.binding_revoke_sign_ctx
        [ binding_id; pk; ts; nonce ] in
      `Assoc [ ("revoke_pk", `String pk); ("ts", `String ts);
               ("nonce", `String nonce);
               ("sig", `String (b64url_encode (Relay_identity.sign id blob))) ]
    in
    let open Lwt.Infix in
    delete ~base_url ~binding_id ~body:(sign attacker) () >>= fun r_att ->
    Alcotest.(check int) "non-owner proof 401" 401 (RTSR.status_code r_att);
    Alcotest.(check string) "non-owner denied uniformly" "revoke_denied"
      (error_code r_att.RTSR.json);
    Alcotest.(check bool) "binding survives non-owner attempt" true
      (binding_exists relay ~binding_id);
    (* Owner reuses the same nonce N — must succeed, proving N was never
       recorded by the non-owner attempt. *)
    delete ~base_url ~binding_id ~body:(sign machine) () >|= fun r_owner ->
    Alcotest.(check int) "owner revoke with same nonce succeeds (nonce free)"
      200 (RTSR.status_code r_owner);
    Alcotest.(check bool) "binding removed by owner" false
      (binding_exists relay ~binding_id))

(* --- 6d: a bogus Ed25519 Authorization header on /binding/<id> must not
   burn the revoke-nonce store. The outer request verifier consumes header
   nonces into the SHARED request_nonces store before signature
   verification; because revoke replay uses a DEDICATED store, an attacker
   pre-seeding the owner's nonce via a bogus header must NOT block the
   owner's later revoke with that same nonce. Also: no existence oracle. *)

let test_bogus_header_does_not_burn_revoke_nonce () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let existing = "b116-hdrseed-exists" and missing = "b116-hdrseed-miss" in
    add_binding relay ~binding_id:existing ~machine ~phone;
    (* Craft the owner proof first so we know the nonce the attacker will
       try to pre-seed. *)
    let proof = Relay_signed_ops.sign_binding_revoke machine ~binding_id:existing in
    let nonce = proof.Relay_signed_ops.nonce in
    let ts = proof.Relay_signed_ops.ts in
    (* Attacker sends a DELETE with a bogus Ed25519 header reusing that
       nonce (garbage sig, unknown alias) against both an existing and a
       missing binding. *)
    let bogus_auth =
      Printf.sprintf "Ed25519 alias=nobody,ts=%s,nonce=%s,sig=AAAA" ts nonce
    in
    let open Lwt.Infix in
    delete_with_auth ~base_url ~binding_id:existing ~auth:bogus_auth ()
    >>= fun r_exists ->
    delete_with_auth ~base_url ~binding_id:missing ~auth:bogus_auth ()
    >>= fun r_missing ->
    (* Both rejected identically (no oracle) and the binding survives. *)
    Alcotest.(check int) "bogus-header revoke of existing is 401"
      401 (RTSR.status_code r_exists);
    Alcotest.(check string)
      "bogus-header existing vs missing identical body (no oracle)"
      r_exists.RTSR.body_text r_missing.RTSR.body_text;
    Alcotest.(check bool) "binding survives bogus-header attempt" true
      (binding_exists relay ~binding_id:existing);
    (* The owner's real revoke with the same nonce must STILL succeed —
       proving the bogus header did not consume the revoke nonce. *)
    delete ~base_url ~binding_id:existing
      ~body:(revoke_body_of_proof proof) () >|= fun r_owner ->
    Alcotest.(check int) "owner revoke still succeeds after header pre-seed"
      200 (RTSR.status_code r_owner);
    Alcotest.(check bool) "binding removed by owner" false
      (binding_exists relay ~binding_id:existing))

(* --- 6c: oversized nonce rejected before any store access --- *)

let test_oversized_nonce_rejected () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-bignonce" in
    add_binding relay ~binding_id ~machine ~phone;
    let pk = pk_b64 machine in
    let ts = Printf.sprintf "%.6f" (Unix.gettimeofday ()) in
    let nonce = String.make 500 'A' in
    let blob = Relay_identity.canonical_msg
      ~ctx:Relay_common.binding_revoke_sign_ctx
      [ binding_id; pk; ts; nonce ] in
    let body = `Assoc [
      ("revoke_pk", `String pk); ("ts", `String ts);
      ("nonce", `String nonce);
      ("sig", `String (b64url_encode (Relay_identity.sign machine blob))) ] in
    let open Lwt.Infix in
    delete ~base_url ~binding_id ~body () >|= fun r ->
    Alcotest.(check int) "oversized-nonce revoke is 401" 401
      (RTSR.status_code r);
    Alcotest.(check bool) "binding survives oversized-nonce attempt" true
      (binding_exists relay ~binding_id))

(* --- 7: stale timestamp rejected --- *)

let test_stale_ts_rejected () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-stale-ts" in
    add_binding relay ~binding_id ~machine ~phone;
    let pk = pk_b64 machine in
    let ts = Printf.sprintf "%.6f" (Unix.gettimeofday () -. 3600.0) in
    let nonce = Relay_signed_ops.random_nonce_b64 () in
    let blob = Relay_identity.canonical_msg
      ~ctx:Relay_common.binding_revoke_sign_ctx
      [ binding_id; pk; ts; nonce ] in
    let sig_b64 = b64url_encode (Relay_identity.sign machine blob) in
    let body = `Assoc [
      ("revoke_pk", `String pk); ("ts", `String ts);
      ("nonce", `String nonce); ("sig", `String sig_b64);
    ] in
    let open Lwt.Infix in
    delete ~base_url ~binding_id ~body () >|= fun r ->
    Alcotest.(check int) "stale-ts revoke is 401" 401 (RTSR.status_code r);
    Alcotest.(check string) "stale-ts denial code" "timestamp_out_of_window"
      (error_code r.RTSR.json);
    Alcotest.(check bool) "binding survives stale-ts attempt" true
      (binding_exists relay ~binding_id))

(* --- 7b: non-finite ts ("nan") must not bypass the freshness window --- *)

let test_nan_ts_rejected () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let binding_id = "b116-nan-ts-bind" in
    add_binding relay ~binding_id ~machine ~phone;
    let pk = pk_b64 machine in
    let ts = "nan" in
    let nonce = Relay_signed_ops.random_nonce_b64 () in
    let blob = Relay_identity.canonical_msg
      ~ctx:Relay_common.binding_revoke_sign_ctx
      [ binding_id; pk; ts; nonce ] in
    let sig_b64 = b64url_encode (Relay_identity.sign machine blob) in
    let body = `Assoc [
      ("revoke_pk", `String pk); ("ts", `String ts);
      ("nonce", `String nonce); ("sig", `String sig_b64);
    ] in
    let open Lwt.Infix in
    delete ~base_url ~binding_id ~body () >|= fun r ->
    Alcotest.(check int) "nan-ts revoke is 401" 401 (RTSR.status_code r);
    Alcotest.(check string) "nan-ts denial code" "timestamp_out_of_window"
      (error_code r.RTSR.json);
    Alcotest.(check bool) "binding survives nan-ts attempt" true
      (binding_exists relay ~binding_id))

(* --- 8: malformed binding id still 400, and it leaves a real binding
   untouched (the 400 fires before any store mutation). We seed a valid
   binding, hit a separate malformed id, and assert the seeded binding
   survives and the malformed one is 400. *)

let test_malformed_binding_id_still_400 () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay ->
    let machine = gen_identity () and phone = gen_identity () in
    let seeded = "b116-seeded-ok" in
    add_binding relay ~binding_id:seeded ~machine ~phone;
    let open Lwt.Infix in
    delete ~base_url ~binding_id:"nope" () >|= fun r ->
    Alcotest.(check int) "short binding id is 400" 400 (RTSR.status_code r);
    Alcotest.(check bool) "seeded binding untouched by malformed request" true
      (binding_exists relay ~binding_id:seeded))

let () =
  Alcotest.run "relay_binding_revoke_auth"
    [ ( "binding-revoke-auth",
        [ Alcotest.test_case "anonymous bare-ID rejected + uniform" `Quick
            test_anonymous_revoke_rejected_and_uniform;
          Alcotest.test_case "machine-key revoke succeeds" `Quick
            test_machine_key_revoke_succeeds;
          Alcotest.test_case "phone-key revoke succeeds" `Quick
            test_phone_key_revoke_succeeds;
          Alcotest.test_case "wrong-key rejected + uniform" `Quick
            test_wrong_key_rejected_uniform;
          Alcotest.test_case "replay rejected (uniform)" `Quick
            test_replay_rejected;
          Alcotest.test_case "non-owner does not consume nonce" `Quick
            test_non_owner_does_not_consume_nonce;
          Alcotest.test_case "bogus Ed25519 header does not burn revoke nonce"
            `Quick test_bogus_header_does_not_burn_revoke_nonce;
          Alcotest.test_case "oversized nonce rejected" `Quick
            test_oversized_nonce_rejected;
          Alcotest.test_case "stale ts rejected" `Quick
            test_stale_ts_rejected;
          Alcotest.test_case "nan ts rejected" `Quick test_nan_ts_rejected;
          Alcotest.test_case "malformed binding id 400 (store untouched)"
            `Quick test_malformed_binding_id_still_400 ] ) ]
