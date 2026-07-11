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
      r_exists.RTSR.body_text r_missing.RTSR.body_text)

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
      r_exists.RTSR.body_text r_missing.RTSR.body_text)

(* --- 6: replaying a successful revoke against a re-created binding --- *)

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
       request verbatim — the nonce cache must reject it. *)
    add_binding relay ~binding_id ~machine ~phone;
    delete ~base_url ~binding_id ~body () >|= fun r2 ->
    Alcotest.(check int) "replayed revoke is 401" 401 (RTSR.status_code r2);
    Alcotest.(check string) "replay denial code" "nonce_replay"
      (error_code r2.RTSR.json);
    Alcotest.(check bool) "re-created binding survives the replay" true
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

(* --- 8: malformed binding id still 400, store untouched --- *)

let test_malformed_binding_id_still_400 () =
  RTSR.with_server ~token:test_token (fun ~base_url ~relay:_ ->
    let open Lwt.Infix in
    delete ~base_url ~binding_id:"nope" () >|= fun r ->
    Alcotest.(check int) "short binding id is 400" 400 (RTSR.status_code r))

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
          Alcotest.test_case "replay rejected" `Quick test_replay_rejected;
          Alcotest.test_case "stale ts rejected" `Quick
            test_stale_ts_rejected;
          Alcotest.test_case "nan ts rejected" `Quick test_nan_ts_rejected;
          Alcotest.test_case "malformed binding id 400" `Quick
            test_malformed_binding_id_still_400 ] ) ]
