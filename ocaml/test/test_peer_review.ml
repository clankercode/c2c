(* test_peer_review.ml — Alcotest for Peer_review signed artifact *)

open Alcotest

let b64_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let make_identity () =
  Relay_identity.generate ~alias_hint:"test-peer-review" ()

let test_sign_and_verify () =
  let id = make_identity () in
  let art : Peer_review.t = {
    version = 1;
    reviewer = "test-agent";
    reviewer_pk = "";
    sha = "abc123def456";
    verdict = "PASS";
    criteria_checked = ["builds_cleanly"; "crypto_sound"];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123def456";
    targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
    notes = "test review notes";
    signature = "";
    build_exit_code = None;
    ts = 1234567890.0;
  } in
  let signed = Peer_review.sign ~identity:id art in
  check bool "signature not empty" (signed.Peer_review.signature <> "") true;
  check bool "reviewer_pk set" (signed.Peer_review.reviewer_pk <> "") true;
  (match Peer_review.verify signed with
   | Ok true -> ()
   | Ok false -> failwith "verify returned false"
   | Error e -> failwith ("verify error: " ^ Peer_review.verify_error_to_string e))

let test_verify_unknown_fails () =
  let id1 = make_identity () in
  let _id2 = make_identity () in
  let art : Peer_review.t = {
    version = 1;
    reviewer = "test-agent";
    reviewer_pk = "";
    sha = "abc123def456";
    verdict = "PASS";
    criteria_checked = [];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123def456";
    targets_built = { c2c = false; c2c_mcp_server = false; c2c_inbox_hook = false };
    notes = "";
    signature = "";
    build_exit_code = None;
    ts = 1234567890.0;
  } in
  let signed = Peer_review.sign ~identity:id1 art in
  let art_tampered = { signed with Peer_review.verdict = "FAIL" } in
  (match Peer_review.verify art_tampered with
   | Ok true -> failwith "verify should have failed on tampered artifact"
   | Ok false -> failwith "verify should have returned error on tampered content"
   | Error e ->
     if e = Peer_review.Invalid_signature then ()
     else failwith ("unexpected error: " ^ Peer_review.verify_error_to_string e))

let test_missing_signature () =
  let art : Peer_review.t = {
    version = 1;
    reviewer = "test-agent";
    reviewer_pk = b64_encode (String.make 32 'a');
    sha = "abc123";
    verdict = "PASS";
    criteria_checked = [];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123";
    targets_built = { c2c = false; c2c_mcp_server = false; c2c_inbox_hook = false };
    notes = "";
    signature = "";
    build_exit_code = None;
    ts = 0.0;
  } in
  match Peer_review.verify art with
  | Error Peer_review.Missing_signature -> ()
  | _ -> failwith "expected Missing_signature error"

let test_roundtrip_json () =
  let art : Peer_review.t = {
    version = 1;
    reviewer = "test-agent";
    reviewer_pk = b64_encode (String.make 32 'x');
    sha = "abc123";
    verdict = "PASS";
    criteria_checked = ["a"; "b"];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123";
    targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
    notes = "hello world";
    signature = b64_encode (String.make 64 's');
    ts = 1234567890.5;
    build_exit_code = None;
  } in
  let json = Peer_review.t_to_string art in
  match Peer_review.t_of_string json with
  | Some art2 ->
    check string "reviewer" art.reviewer art2.reviewer;
    check string "sha" art.sha art2.sha;
    check string "verdict" art.verdict art2.verdict;
    check string "skill_version" art.skill_version art2.skill_version;
    check (float 0.001) "ts" art.ts art2.ts;
    check bool "c2c" art.targets_built.Peer_review.c2c art2.targets_built.Peer_review.c2c;
    check bool "c2c_mcp_server" art.targets_built.Peer_review.c2c_mcp_server art2.targets_built.Peer_review.c2c_mcp_server;
    check bool "c2c_inbox_hook" art.targets_built.Peer_review.c2c_inbox_hook art2.targets_built.Peer_review.c2c_inbox_hook;
    check int "criteria_count" (List.length art.criteria_checked) (List.length art2.criteria_checked)
  | None -> failwith "roundtrip JSON parse failed"

(* --- H1 TOFU pin tests --------------------------------------------------- *)

let make_signed_artifact ~identity ~reviewer =
  let art : Peer_review.t = {
    version = 1;
    reviewer;
    reviewer_pk = "";
    sha = "deadbeef";
    verdict = "PASS";
    criteria_checked = [];
    skill_version = "1.0.0";
    commit_range = "0000000..deadbeef";
    targets_built = { c2c = false; c2c_mcp_server = false; c2c_inbox_hook = false };
    notes = "";
    signature = "";
    build_exit_code = None;
    ts = 1234567890.0;
  } in
  Peer_review.sign ~identity art

let with_temp_pin_path f =
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "c2c-peer-pin-test-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir tmp_dir 0o700;
  let path = Filename.concat tmp_dir "peer-pass-trust.json" in
  let cleanup () =
    (try Sys.remove path with _ -> ());
    (try Unix.rmdir tmp_dir with _ -> ())
  in
  Fun.protect ~finally:cleanup (fun () -> f path)

let test_first_verify_pins_pubkey () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"alice" in
  (* Pre-condition: store does not exist. *)
  check bool "no pin store before first verify" false (Sys.file_exists path);
  match Peer_review.verify_with_pin ~path signed with
  | Ok Peer_review.Pin_first_seen ->
    check bool "pin store created after first verify" true (Sys.file_exists path);
    let store = Peer_review.Trust_pin.load ~path () in
    (match Peer_review.Trust_pin.find_pin store ~alias:"alice" with
     | Some p ->
       check string "pinned pubkey matches artifact" signed.Peer_review.reviewer_pk p.pubkey
     | None -> failwith "pin missing after first-seen")
  | Ok _ -> failwith "expected Pin_first_seen"
  | Error e -> failwith ("unexpected verify error: " ^ Peer_review.verify_error_to_string e)

let test_second_verify_with_same_pubkey_passes () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed_a = make_signed_artifact ~identity:id ~reviewer:"alice" in
  (* First verify pins. *)
  (match Peer_review.verify_with_pin ~path signed_a with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "first verify did not pin");
  (* Second verify with the same identity must match. *)
  let signed_b = make_signed_artifact ~identity:id ~reviewer:"alice" in
  match Peer_review.verify_with_pin ~path signed_b with
  | Ok Peer_review.Pin_match -> ()
  | Ok Peer_review.Pin_first_seen -> failwith "expected Pin_match, got Pin_first_seen (pin was lost)"
  | Ok (Peer_review.Pin_mismatch _) -> failwith "expected Pin_match, got Pin_mismatch"
  | Error e -> failwith ("verify error: " ^ Peer_review.verify_error_to_string e)

let test_second_verify_with_different_pubkey_rejected () =
  with_temp_pin_path @@ fun path ->
  let id1 = make_identity () in
  let id2 = make_identity () in
  let signed_a = make_signed_artifact ~identity:id1 ~reviewer:"alice" in
  let signed_b = make_signed_artifact ~identity:id2 ~reviewer:"alice" in
  (* Sanity: the two identities really do produce different reviewer_pks. *)
  check bool "two identities have distinct pubkeys"
    true (signed_a.Peer_review.reviewer_pk <> signed_b.Peer_review.reviewer_pk);
  (* First verify: id1 pins. *)
  (match Peer_review.verify_with_pin ~path signed_a with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "first verify did not pin");
  (* Second verify: id2 forges as alice — signature is valid in isolation,
     but TOFU must reject. *)
  match Peer_review.verify_with_pin ~path signed_b with
  | Ok (Peer_review.Pin_mismatch { alias; pinned_pubkey; artifact_pubkey; _ }) ->
    check string "mismatch alias" "alice" alias;
    check string "pinned pubkey is id1's"
      signed_a.Peer_review.reviewer_pk pinned_pubkey;
    check string "artifact pubkey is id2's"
      signed_b.Peer_review.reviewer_pk artifact_pubkey;
    (* And the pin must NOT have been overwritten silently. *)
    let store = Peer_review.Trust_pin.load ~path () in
    (match Peer_review.Trust_pin.find_pin store ~alias:"alice" with
     | Some p ->
       check string "pin still bound to id1's pubkey"
         signed_a.Peer_review.reviewer_pk p.pubkey
     | None -> failwith "pin disappeared")
  | Ok Peer_review.Pin_first_seen -> failwith "TOFU FAILED: pin was lost between verifies"
  | Ok Peer_review.Pin_match -> failwith "TOFU FAILED: forged pubkey accepted as matching pin"
  | Error e -> failwith ("unexpected verify error: " ^ Peer_review.verify_error_to_string e)

let test_rotate_pin_replaces_existing () =
  with_temp_pin_path @@ fun path ->
  let id1 = make_identity () in
  let id2 = make_identity () in
  let signed_a = make_signed_artifact ~identity:id1 ~reviewer:"alice" in
  let signed_b = make_signed_artifact ~identity:id2 ~reviewer:"alice" in
  (* Pin id1. *)
  (match Peer_review.verify_with_pin ~path signed_a with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "first verify did not pin");
  (* Confirm normal verify_with_pin would reject id2. *)
  (match Peer_review.verify_with_pin ~path signed_b with
   | Ok (Peer_review.Pin_mismatch _) -> ()
   | _ -> failwith "rotation precondition failed: expected mismatch");
  (* Explicit rotation must replace the pin and surface the prior.
     #432 TOFU Finding 4: pin_rotate now returns a Result with the
     verify_error if signature is invalid. signed_b is properly
     signed via make_signed_artifact, so we expect Ok prior. *)
  let prior = match Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed_b with
    | Ok p -> p
    | Error e -> failwith ("rotation rejected: " ^ Peer_review.verify_error_to_string e)
  in
  (match prior with
   | Some p ->
     check string "rotation returns prior pubkey"
       signed_a.Peer_review.reviewer_pk p.pubkey
   | None -> failwith "expected prior pin from rotation");
  (* After rotation, signed_b verifies as a normal match. *)
  (match Peer_review.verify_with_pin ~path signed_b with
   | Ok Peer_review.Pin_match -> ()
   | Ok Peer_review.Pin_first_seen -> failwith "post-rotate: pin not persisted"
   | Ok (Peer_review.Pin_mismatch _) -> failwith "post-rotate: still mismatched"
   | Error e -> failwith ("post-rotate verify error: " ^ Peer_review.verify_error_to_string e));
  (* And signed_a (the old pubkey) is now the rejected one. *)
  match Peer_review.verify_with_pin ~path signed_a with
  | Ok (Peer_review.Pin_mismatch _) -> ()
  | _ -> failwith "post-rotate: old pubkey should now be rejected"

let test_rotate_pin_with_no_prior_pin () =
  (* Edge case: --rotate-pin used on first verify is a no-op equivalent
     to TOFU first-seen. Must not error. *)
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"bob" in
  let prior = match Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed with
    | Ok p -> p
    | Error e -> failwith ("rotation rejected: " ^ Peer_review.verify_error_to_string e)
  in
  check bool "no prior pin on first rotate" true (prior = None);
  (* And the pin is now persisted. *)
  match Peer_review.verify_with_pin ~path signed with
  | Ok Peer_review.Pin_match -> ()
  | _ -> failwith "expected Pin_match after rotate-as-first"

(* [#432 TOFU Finding 4] pin_rotate must reject artifacts whose
   signature is invalid. Pre-fix the function trusted callers to verify
   first; post-fix it verifies internally. Tampering the signature
   bytes after signing produces an artifact that fails Ed25519 verify;
   pin_rotate must return Error Invalid_signature and NOT modify the
   pin store. *)
let test_pin_rotate_rejects_invalid_signature () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"alice" in
  (* Tamper the signature: flip the last byte after b64 decode + encode. *)
  let open Peer_review in
  let tampered =
    let sig_str = match b64url_decode signed.signature with
      | Ok s -> s
      | Error _ -> failwith "decode signed.signature"
    in
    let buf = Bytes.of_string sig_str in
    let len = Bytes.length buf in
    let last = Bytes.get_uint8 buf (len - 1) in
    Bytes.set_uint8 buf (len - 1) (last lxor 0x01);
    { signed with signature = b64url_encode (Bytes.to_string buf) }
  in
  (* Confirm the tampered artifact does fail verify. The verify
     function returns either Ok false or Error Invalid_signature
     depending on whether ed25519's verify primitive returned false
     or raised — both are "rejection" outcomes. *)
  (match Peer_review.verify tampered with
   | Ok false -> ()
   | Error Peer_review.Invalid_signature -> ()
   | Ok true -> failwith "tampered signature unexpectedly verified"
   | Error e ->
     failwith ("unexpected verify error: " ^ Peer_review.verify_error_to_string e));
  (* The pin store starts empty — pin_rotate on a tampered artifact
     must return Error AND leave the store empty. *)
  (match Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell tampered with
   | Error Peer_review.Invalid_signature -> ()
   | Error other ->
     failwith ("expected Invalid_signature, got: " ^ Peer_review.verify_error_to_string other)
   | Ok _ ->
     failwith "pin_rotate accepted tampered signature — security regression");
  (* And confirm: the store has no pin for "alice" (the rotation didn't
     persist anything). *)
  let store = Peer_review.Trust_pin.load ~path () in
  match Peer_review.Trust_pin.find_pin store ~alias:"alice" with
  | None -> ()
  | Some _ ->
    failwith "pin written despite Invalid_signature — security regression"

(* [#432 TOFU Finding 4] companion: pin_rotate on a valid signature
   path still works exactly as before (returns Ok prior). The
   pre-existing test_explicit_rotate_pin_replaces_with_prior covers
   the success path; this is a smoke that the legacy success contract
   continues to hold post-Result-shape change. *)
let test_pin_rotate_accepts_valid_signature () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"dave" in
  match Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed with
  | Ok None -> ()  (* No prior pin; rotate-as-first. *)
  | Ok (Some _) -> failwith "did not expect prior pin"
  | Error e -> failwith ("rotation rejected unexpectedly: " ^ Peer_review.verify_error_to_string e)

(* [#432 TOFU Finding 5] operator-attestation gate: Mcp_operator_token
   accepted when C2C_OPERATOR_AUTH_TOKEN env matches. Models the future
   MCP rotate-tool path. *)
let test_pin_rotate_mcp_token_accepted_when_env_matches () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"erin" in
  let prior_env = Sys.getenv_opt "C2C_OPERATOR_AUTH_TOKEN" in
  Fun.protect
    ~finally:(fun () ->
      match prior_env with
      | Some v -> Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" v
      | None ->
        (* No portable unsetenv in stdlib Unix; clear via empty string,
           which validate_operator_attestation rejects (the empty-string
           guard inside the validator). *)
        Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "")
    (fun () ->
      Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "secret-token-for-test";
      match
        Peer_review.pin_rotate ~path
          ~attestation:(Peer_review.Mcp_operator_token "secret-token-for-test")
          signed
      with
      | Ok None -> ()
      | Ok (Some _) -> failwith "unexpected prior pin"
      | Error e ->
        failwith
          ("Mcp_operator_token with matching env should be accepted, got: "
           ^ Peer_review.verify_error_to_string e))

(* [#432 TOFU Finding 5] operator-attestation gate: Mcp_operator_token
   REJECTED when C2C_OPERATOR_AUTH_TOKEN env does not match. Critical:
   on reject, NO pin write AND NO audit-log fire — load-bearing
   security claim. *)
let test_pin_rotate_mcp_token_rejected_zero_write () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"frank" in
  let prior_env = Sys.getenv_opt "C2C_OPERATOR_AUTH_TOKEN" in
  let captured : Peer_review.pin_rotate_log_event list ref = ref [] in
  let prior_hook = !Peer_review.pin_rotate_log_hook in
  Fun.protect
    ~finally:(fun () ->
      Peer_review.pin_rotate_log_hook := prior_hook;
      match prior_env with
      | Some v -> Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" v
      | None -> Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "")
    (fun () ->
      Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "real-operator-token";
      Peer_review.pin_rotate_log_hook := (fun ev -> captured := ev :: !captured);
      (match
         Peer_review.pin_rotate ~path
           ~attestation:(Peer_review.Mcp_operator_token "wrong-token")
           signed
       with
       | Error Peer_review.Operator_unauthorized -> ()
       | Error other ->
         failwith
           ("expected Operator_unauthorized, got: "
            ^ Peer_review.verify_error_to_string other)
       | Ok _ ->
         failwith "pin_rotate accepted Mcp_operator_token with mismatched env — security regression");
      let store = Peer_review.Trust_pin.load ~path () in
      (match Peer_review.Trust_pin.find_pin store ~alias:"frank" with
       | None -> ()
       | Some _ ->
         failwith "pin written despite Operator_unauthorized — security regression");
      check int "audit-log not fired on operator-unauth reject" 0 (List.length !captured))

(* [#432 TOFU Finding 5] operator-attestation gate: Mcp_operator_token
   REJECTED when C2C_OPERATOR_AUTH_TOKEN env is unset (empty). Default
   deployments lack the env var; an MCP rotate caller must NOT silently
   succeed in that environment. *)
let test_pin_rotate_mcp_token_rejected_when_env_unset () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"gary" in
  let prior_env = Sys.getenv_opt "C2C_OPERATOR_AUTH_TOKEN" in
  Fun.protect
    ~finally:(fun () ->
      match prior_env with
      | Some v -> Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" v
      | None -> Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "")
    (fun () ->
      Unix.putenv "C2C_OPERATOR_AUTH_TOKEN" "";
      match
        Peer_review.pin_rotate ~path
          ~attestation:(Peer_review.Mcp_operator_token "any-token")
          signed
      with
      | Error Peer_review.Operator_unauthorized -> ()
      | Error other ->
        failwith
          ("expected Operator_unauthorized when env unset, got: "
           ^ Peer_review.verify_error_to_string other)
      | Ok _ ->
        failwith "pin_rotate accepted Mcp_operator_token with empty env — security regression")

let test_pin_store_survives_load_save_roundtrip () =
  with_temp_pin_path @@ fun path ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"carol" in
  (match Peer_review.verify_with_pin ~path signed with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "first verify did not pin");
  (* Reload from disk and verify the pin is intact. *)
  let store = Peer_review.Trust_pin.load ~path () in
  match Peer_review.Trust_pin.find_pin store ~alias:"carol" with
  | Some p ->
    check string "reloaded pubkey" signed.Peer_review.reviewer_pk p.pubkey;
    check bool "first_seen populated" true (p.first_seen > 0.0);
    check bool "last_seen populated" true (p.last_seen > 0.0)
  | None -> failwith "pin missing after reload"

(* --- #55 pin-rotate audit log hook --------------------------------------- *)

(* Capture pin-rotate events emitted by the library hook so the assertions
   are independent of the broker.log writer wiring (which lives in
   c2c_mcp.ml). The CLI/broker wiring is exercised by an end-to-end test
   below that calls the published [log_peer_pass_pin_rotate] writer
   indirectly via the hook. *)

let with_captured_rotate_log f =
  let captured : Peer_review.pin_rotate_log_event list ref = ref [] in
  let prior_hook = !Peer_review.pin_rotate_log_hook in
  Peer_review.set_pin_rotate_logger (fun ev ->
    captured := ev :: !captured);
  Fun.protect
    ~finally:(fun () -> Peer_review.pin_rotate_log_hook := prior_hook)
    (fun () -> f captured)

let test_pin_rotate_emits_log_event_with_prior () =
  with_temp_pin_path @@ fun path ->
  with_captured_rotate_log @@ fun captured ->
  let id1 = make_identity () in
  let id2 = make_identity () in
  let signed_a = make_signed_artifact ~identity:id1 ~reviewer:"alice" in
  let signed_b = make_signed_artifact ~identity:id2 ~reviewer:"alice" in
  (* Pin id1 first. *)
  (match Peer_review.verify_with_pin ~path signed_a with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "first verify did not pin");
  (* Rotate to id2 — must emit a log event. *)
  let _ = Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed_b in
  match List.rev !captured with
  | [ ev ] ->
    check string "log alias" "alice" ev.Peer_review.alias;
    check string "log old_pubkey is id1's"
      signed_a.Peer_review.reviewer_pk ev.Peer_review.old_pubkey;
    check string "log new_pubkey is id2's"
      signed_b.Peer_review.reviewer_pk ev.Peer_review.new_pubkey;
    check bool "prior_first_seen present" true (ev.Peer_review.prior_first_seen <> None);
    check bool "ts populated" true (ev.Peer_review.ts > 0.0);
    check string "log path matches store path" path ev.Peer_review.path
  | other ->
    failwith (Printf.sprintf "expected exactly 1 log event, got %d"
                (List.length other))

let test_pin_rotate_emits_log_event_no_prior () =
  with_temp_pin_path @@ fun path ->
  with_captured_rotate_log @@ fun captured ->
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"bob" in
  let _ = Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed in
  match List.rev !captured with
  | [ ev ] ->
    check string "log alias" "bob" ev.Peer_review.alias;
    check string "old_pubkey empty for first-rotate" "" ev.Peer_review.old_pubkey;
    check string "new_pubkey is signer's"
      signed.Peer_review.reviewer_pk ev.Peer_review.new_pubkey;
    check bool "prior_first_seen absent" true (ev.Peer_review.prior_first_seen = None)
  | other ->
    failwith (Printf.sprintf "expected exactly 1 log event, got %d"
                (List.length other))

(* End-to-end: confirm the broker.log writer (registered at module init in
   c2c_mcp.ml) actually appends a JSON line under the pin-store's parent
   directory. We don't import C2c_mcp directly here (test target lives in
   ocaml/test/dune already wired with c2c_mcp_lib? — guard by registering
   our own writer that mirrors the broker writer, to keep this test
   library-only). The broker wiring is exercised by integration tests in
   test_c2c_mcp.ml via the actual peer-pass DM path. *)
let test_pin_rotate_log_writes_json_line_under_pin_dir () =
  with_temp_pin_path @@ fun path ->
  with_captured_rotate_log @@ fun _captured ->
  (* Register a sibling writer that produces broker.log in the pin store's
     parent directory using the same shape c2c_mcp.log_peer_pass_pin_rotate
     produces. We override on top of the capture hook so both fire (the
     capture above keeps last hook in [prior_hook]; we extend it). *)
  let log_path = Filename.concat (Filename.dirname path) "broker.log" in
  let prior_hook = !Peer_review.pin_rotate_log_hook in
  Peer_review.set_pin_rotate_logger (fun ev ->
    prior_hook ev;
    let prior_field = match ev.Peer_review.prior_first_seen with
      | None -> ("prior_first_seen", `Null)
      | Some f -> ("prior_first_seen", `Float f)
    in
    let line =
      `Assoc
        [ ("ts", `Float ev.Peer_review.ts)
        ; ("event", `String "peer_pass_pin_rotate")
        ; ("alias", `String ev.Peer_review.alias)
        ; ("old_pubkey", `String ev.Peer_review.old_pubkey)
        ; ("new_pubkey", `String ev.Peer_review.new_pubkey)
        ; prior_field
        ]
      |> Yojson.Safe.to_string
    in
    let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 log_path in
    output_string oc (line ^ "\n");
    close_out oc);
  let id = make_identity () in
  let signed = make_signed_artifact ~identity:id ~reviewer:"dora" in
  let _ = Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell signed in
  check bool "broker.log created" true (Sys.file_exists log_path);
  let ic = open_in log_path in
  let line =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () -> input_line ic)
  in
  let json = Yojson.Safe.from_string line in
  let get_str f j =
    match j with
    | `Assoc fields ->
      (match List.assoc_opt f fields with Some (`String s) -> s | _ -> "")
    | _ -> ""
  in
  check string "event tag" "peer_pass_pin_rotate" (get_str "event" json);
  check string "alias" "dora" (get_str "alias" json);
  check string "new_pubkey" signed.Peer_review.reviewer_pk (get_str "new_pubkey" json);
  check string "old_pubkey empty" "" (get_str "old_pubkey" json)

(* --- #54b concurrent verify-and-rotate (read-modify-write) --------------- *)

(* Two child processes hammer the same pin store: one loops [pin_check]
   under id1 (first-seen → match → match …), the other loops [pin_rotate]
   to id2 then back to id1 in lockstep. Without with_pin_lock around the
   load→decide→save sequence, A.load could observe the pre-rotate state,
   B.rotate could land between A.load and A.save, and A.save would clobber
   B's update — the lost-update race.

   Assertions: after both children exit, the pin store reflects whichever
   identity ran the last save (one of id1/id2's pubkey, not a torn / empty
   value), and the JSON file is well-formed. The serialization invariant
   we care about for the security property is "no silent reversion": every
   transition is observable in the log, and the on-disk state matches one
   of the two writers' final intent. *)

let test_concurrent_pin_check_and_rotate_no_lost_update () =
  with_temp_pin_path @@ fun path ->
  let id1 = make_identity () in
  let id2 = make_identity () in
  let pk1 = (make_signed_artifact ~identity:id1 ~reviewer:"eve").Peer_review.reviewer_pk in
  let pk2 = (make_signed_artifact ~identity:id2 ~reviewer:"eve").Peer_review.reviewer_pk in
  (* Pin id1 once so both children start from a known state. *)
  let signed_a = make_signed_artifact ~identity:id1 ~reviewer:"eve" in
  (match Peer_review.verify_with_pin ~path signed_a with
   | Ok Peer_review.Pin_first_seen -> ()
   | _ -> failwith "seed pin failed");
  (* Spawn two child workers via Unix.fork. Each runs N rounds. *)
  let n_rounds = 50 in
  let child_check () =
    let signed = make_signed_artifact ~identity:id1 ~reviewer:"eve" in
    for _ = 1 to n_rounds do
      let _ = Peer_review.pin_check ~path signed in
      ()
    done;
    exit 0
  in
  let child_rotate () =
    let signed_to_2 = make_signed_artifact ~identity:id2 ~reviewer:"eve" in
    let signed_to_1 = make_signed_artifact ~identity:id1 ~reviewer:"eve" in
    for i = 1 to n_rounds do
      let target = if i mod 2 = 0 then signed_to_2 else signed_to_1 in
      let _ = Peer_review.pin_rotate ~path ~attestation:Peer_review.Cli_local_shell target in
      ()
    done;
    exit 0
  in
  let pid1 = Unix.fork () in
  if pid1 = 0 then child_check ();
  let pid2 = Unix.fork () in
  if pid2 = 0 then child_rotate ();
  let _, status1 = Unix.waitpid [] pid1 in
  let _, status2 = Unix.waitpid [] pid2 in
  (match status1, status2 with
   | WEXITED 0, WEXITED 0 -> ()
   | _ -> failwith "one of the workers crashed (likely from corrupted JSON / lost-update fallback)");
  (* On-disk store must be parseable JSON and reflect a non-empty pin
     for "eve" with a pubkey that is one of {pk1, pk2}. A torn write or
     an unsynchronized load→save sequence would manifest as either
     invalid JSON, a missing pin, or a pubkey from neither identity. *)
  let store = Peer_review.Trust_pin.load ~path () in
  (match Peer_review.Trust_pin.find_pin store ~alias:"eve" with
   | None -> failwith "pin lost after concurrent run"
   | Some p ->
     check bool "final pubkey is one of the two writers'"
       true (p.pubkey = pk1 || p.pubkey = pk2);
     check bool "first_seen preserved positive" true (p.first_seen > 0.0);
     check bool "last_seen >= first_seen" true (p.last_seen >= p.first_seen))
(* --- #56 size cap tests -------------------------------------------------- *)

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc content)

let with_tempfile f =
  let path = Filename.temp_file "test_peer_review_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () ->
    f path)

let make_signed_artifact ?(notes = "") () =
  let id = make_identity () in
  let art : Peer_review.t = {
    version = 1;
    reviewer = "test-agent";
    reviewer_pk = "";
    sha = "abc123def456";
    verdict = "PASS";
    criteria_checked = ["builds_cleanly"];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123def456";
    targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
    notes;
    signature = "";
    build_exit_code = None;
    ts = 1234567890.0;
  } in
  Peer_review.sign ~identity:id art

let test_size_cap_rejects_oversized () =
  with_tempfile (fun path ->
    let signed = make_signed_artifact
      ~notes:(String.make (Peer_review.peer_pass_max_artifact_bytes + 1024) 'A')
      ()
    in
    write_file path (Peer_review.t_to_string signed);
    match Peer_review.read_artifact_capped path with
    | Ok _ -> failwith "read_artifact_capped should have rejected oversized file"
    | Error (`Read_error msg) -> failwith ("unexpected read error: " ^ msg)
    | Error (`Too_large sz) ->
      check bool "size exceeds cap" (sz > Peer_review.peer_pass_max_artifact_bytes) true)

let test_size_cap_read_artifact_error () =
  with_tempfile (fun path ->
    let signed = make_signed_artifact
      ~notes:(String.make (Peer_review.peer_pass_max_artifact_bytes + 1024) 'B')
      ()
    in
    write_file path (Peer_review.t_to_string signed);
    match Peer_review.read_artifact path with
    | Ok _ -> failwith "read_artifact should have rejected oversized file"
    | Error msg ->
      let needle = "exceeds size cap" in
      let contains s sub =
        let ls = String.length s and lsub = String.length sub in
        let rec loop i =
          if i + lsub > ls then false
          else if String.sub s i lsub = sub then true
          else loop (i + 1)
        in
        loop 0
      in
      check bool ("error mentions cap: " ^ msg) (contains msg needle) true)

let test_size_cap_normal_passes () =
  with_tempfile (fun path ->
    let signed = make_signed_artifact ~notes:"normal review notes" () in
    write_file path (Peer_review.t_to_string signed);
    match Peer_review.read_artifact path with
    | Ok art ->
      check string "reviewer survives roundtrip" "test-agent" art.Peer_review.reviewer;
      check string "verdict survives roundtrip" "PASS" art.Peer_review.verdict
    | Error msg -> failwith ("normal artifact rejected: " ^ msg))

(* --- #57 path-traversal validator tests ---------------------------------- *)

let valid_sha = "abc123def456abc123def456abc123def4567890"
let valid_alias = "alice_bot-1"

let assert_validator_rejects ~alias ~sha label =
  match Peer_review.validate_artifact_path_components ~alias ~sha with
  | Ok () -> failwith (Printf.sprintf "%s: validator unexpectedly accepted alias=%S sha=%S" label alias sha)
  | Error _ -> ()

let assert_artifact_path_raises ~alias ~sha label =
  match Peer_review.artifact_path ~sha ~alias with
  | exception Invalid_argument _ -> ()
  | _ -> failwith (Printf.sprintf "%s: artifact_path unexpectedly returned for alias=%S sha=%S" label alias sha)

let assert_verify_claim_rejects ~alias ~sha label =
  match Peer_review.verify_claim ~alias ~sha with
  | Peer_review.Claim_invalid msg ->
    if not (String.starts_with ~prefix:"alias/sha" msg) then
      failwith (Printf.sprintf "%s: Claim_invalid had unexpected reason: %s" label msg)
  | Peer_review.Claim_valid _ -> failwith (Printf.sprintf "%s: verify_claim unexpectedly returned Claim_valid" label)
  | Peer_review.Claim_missing m ->
    failwith (Printf.sprintf "%s: verify_claim returned Claim_missing (should be Claim_invalid pre-FS-check): %s" label m)

let assert_verify_claim_with_pin_rejects ~alias ~sha label =
  match Peer_review.verify_claim_with_pin ~alias ~sha () with
  | Peer_review.Claim_invalid msg ->
    if String.length msg < 9 || String.sub msg 0 9 <> "alias/sha" then
      failwith (Printf.sprintf "%s: Claim_invalid had unexpected reason: %s" label msg)
  | Peer_review.Claim_valid _ -> failwith (Printf.sprintf "%s: verify_claim_with_pin unexpectedly returned Claim_valid" label)
  | Peer_review.Claim_missing m ->
    failwith (Printf.sprintf "%s: verify_claim_with_pin returned Claim_missing (should be Claim_invalid pre-FS-check): %s" label m)

let test_alias_with_slash_rejected () =
  assert_validator_rejects ~alias:"foo/bar" ~sha:valid_sha "alias /";
  assert_artifact_path_raises ~alias:"foo/bar" ~sha:valid_sha "alias /";
  assert_verify_claim_rejects ~alias:"foo/bar" ~sha:valid_sha "alias / verify_claim";
  assert_verify_claim_with_pin_rejects ~alias:"foo/bar" ~sha:valid_sha "alias / verify_claim_with_pin"

let test_alias_with_backslash_rejected () =
  assert_validator_rejects ~alias:"foo\\bar" ~sha:valid_sha "alias \\";
  assert_artifact_path_raises ~alias:"foo\\bar" ~sha:valid_sha "alias \\";
  assert_verify_claim_rejects ~alias:"foo\\bar" ~sha:valid_sha "alias \\ verify_claim"

let test_alias_with_dotdot_rejected () =
  assert_validator_rejects ~alias:"foo..bar" ~sha:valid_sha "alias ..";
  assert_artifact_path_raises ~alias:"..etc" ~sha:valid_sha "alias .. (raises)";
  assert_verify_claim_rejects ~alias:"a..b" ~sha:valid_sha "alias .. verify_claim"

let test_alias_with_nul_rejected () =
  let bad = "foo\x00bar" in
  assert_validator_rejects ~alias:bad ~sha:valid_sha "alias NUL";
  assert_artifact_path_raises ~alias:bad ~sha:valid_sha "alias NUL"

let test_alias_with_leading_dot_rejected () =
  assert_validator_rejects ~alias:".secret" ~sha:valid_sha "alias leading .";
  assert_artifact_path_raises ~alias:".hidden" ~sha:valid_sha "alias leading .";
  assert_verify_claim_rejects ~alias:".oops" ~sha:valid_sha "alias leading . verify_claim"

let test_alias_empty_rejected () =
  assert_validator_rejects ~alias:"" ~sha:valid_sha "alias empty";
  assert_artifact_path_raises ~alias:"" ~sha:valid_sha "alias empty";
  assert_verify_claim_rejects ~alias:"" ~sha:valid_sha "alias empty verify_claim"

let test_alias_too_long_rejected () =
  (* #57b: 128-byte alias cap — DoS comfort (linear-scan upper bound).
     129 bytes of valid alphanumeric should fail length check before
     per-byte scan. *)
  let bad = String.make 129 'a' in
  assert_validator_rejects ~alias:bad ~sha:valid_sha "alias 129 bytes";
  assert_artifact_path_raises ~alias:bad ~sha:valid_sha "alias 129 bytes path";
  (* Boundary: exactly 128 bytes accepted. *)
  let ok = String.make 128 'a' in
  match Peer_review.validate_artifact_path_components ~alias:ok ~sha:valid_sha with
  | Ok () -> ()
  | Error m -> failwith (Printf.sprintf "128-byte alias unexpectedly rejected: %s" m)

let test_alias_with_nonprintable_rejected () =
  let bad = "foo\x07bar" in
  assert_validator_rejects ~alias:bad ~sha:valid_sha "alias non-printable BEL";
  let bad2 = "foo bar" in (* space — fails is_alias_byte_ok (>= 0x21) *)
  assert_validator_rejects ~alias:bad2 ~sha:valid_sha "alias contains space";
  let bad3 = "foo\x7f" in
  assert_validator_rejects ~alias:bad3 ~sha:valid_sha "alias DEL"

let test_sha_non_hex_rejected () =
  assert_validator_rejects ~alias:valid_alias ~sha:"deadbeefXX" "sha non-hex X";
  assert_validator_rejects ~alias:valid_alias ~sha:"DEADBEEF" "sha uppercase hex (rejected — lowercase only)";
  assert_validator_rejects ~alias:valid_alias ~sha:"abc!def0" "sha contains !";
  assert_artifact_path_raises ~alias:valid_alias ~sha:"abc/def0" "sha containing / (also non-hex)"

let test_sha_too_short_rejected () =
  assert_validator_rejects ~alias:valid_alias ~sha:"abc" "sha 3 chars";
  assert_validator_rejects ~alias:valid_alias ~sha:"a" "sha 1 char"

let test_sha_too_long_rejected () =
  let too_long = String.make 65 'a' in
  assert_validator_rejects ~alias:valid_alias ~sha:too_long "sha 65 chars";
  let way_too_long = String.make 200 '0' in
  assert_validator_rejects ~alias:valid_alias ~sha:way_too_long "sha 200 chars"

let test_sha_empty_rejected () =
  assert_validator_rejects ~alias:valid_alias ~sha:"" "sha empty";
  assert_artifact_path_raises ~alias:valid_alias ~sha:"" "sha empty"

let test_legitimate_alias_and_sha_accepted () =
  (* Regression: the validator must NOT reject legitimate inputs. *)
  (match Peer_review.validate_artifact_path_components ~alias:valid_alias ~sha:valid_sha with
   | Ok () -> ()
   | Error msg -> failwith ("legitimate alias/sha rejected: " ^ msg));
  (* artifact_path must compose without raising. *)
  let _ = Peer_review.artifact_path ~sha:valid_sha ~alias:valid_alias in
  (* verify_claim returns Claim_missing (file does not exist), not
     Claim_invalid — proves we're past the validator. *)
  (match Peer_review.verify_claim ~alias:valid_alias ~sha:valid_sha with
   | Peer_review.Claim_missing _ -> ()
   | Peer_review.Claim_valid _ -> failwith "verify_claim returned valid for non-existent artifact"
   | Peer_review.Claim_invalid msg ->
     failwith ("verify_claim rejected legitimate inputs: " ^ msg));
  (* Range-of-valid sha lengths and alias-classes. *)
  List.iter (fun sha ->
    match Peer_review.validate_artifact_path_components ~alias:valid_alias ~sha with
    | Ok () -> ()
    | Error msg -> failwith (Printf.sprintf "valid sha %S rejected: %s" sha msg))
    [ "abcd"; "abcdef01"; String.make 40 '0'; String.make 64 'f' ];
  List.iter (fun alias ->
    match Peer_review.validate_artifact_path_components ~alias ~sha:valid_sha with
    | Ok () -> ()
    | Error msg -> failwith (Printf.sprintf "valid alias %S rejected: %s" alias msg))
    [ "a"; "alpha"; "alpha-bot"; "x_y_z"; "agent-7"; "lyra-quill" ]

(* --- #427b: build_exit_code (verified-build) field ---------------------- *)

let make_v2_artifact ~build_rc ~identity =
  let art : Peer_review.t = {
    version = 2;
    reviewer = "test-agent";
    reviewer_pk = "";
    sha = "abc123def456";
    verdict = "PASS";
    criteria_checked = ["build-clean-IN-slice-worktree-rc=0"; "tests"];
    skill_version = "1.0.0";
    commit_range = "0000000..abc123def456";
    targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
    notes = "v2 schema artifact";
    signature = "";
    ts = 1234567890.0;
    build_exit_code = Some build_rc;
  } in
  Peer_review.sign ~identity art

let test_v2_build_rc_roundtrip () =
  let id_path = Filename.temp_file "peer_review_test_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove id_path with _ -> ()) (fun () ->
    let id = Relay_identity.generate ~alias_hint:"test-427b" () in
    let signed = make_v2_artifact ~build_rc:0 ~identity:id in
    check int "build_exit_code preserved" 0
      (match signed.Peer_review.build_exit_code with
       | Some n -> n
       | None -> failwith "build_exit_code lost on sign");
    check int "version bumped to 2" 2 signed.Peer_review.version;
    (* JSON roundtrip + verify *)
    let json = Peer_review.t_to_string signed in
    (match Peer_review.t_of_string json with
     | Some art2 ->
       check int "build_exit_code roundtrips through JSON" 0
         (Option.value art2.Peer_review.build_exit_code ~default:(-1));
       check int "version roundtrips through JSON" 2 art2.Peer_review.version;
       (match Peer_review.verify art2 with
        | Ok true -> ()
        | _ -> failwith "v2 artifact failed signature verification after JSON roundtrip")
     | None -> failwith "v2 artifact failed to parse from JSON"))

let test_v2_build_rc_in_signature_scope () =
  (* Tampering the build_exit_code post-sign must invalidate the signature. *)
  let id_path = Filename.temp_file "peer_review_test_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove id_path with _ -> ()) (fun () ->
    let id = Relay_identity.generate ~alias_hint:"test-427b" () in
    let signed = make_v2_artifact ~build_rc:0 ~identity:id in
    let tampered = { signed with Peer_review.build_exit_code = Some 1 } in
    match Peer_review.verify tampered with
    | Error Peer_review.Invalid_signature -> ()
    | Ok true -> failwith "tampered build_exit_code passed verification (signature not over field)"
    | Ok false | Error _ -> failwith "expected Invalid_signature on tampered build_exit_code")

let test_v1_artifact_omits_build_exit_code () =
  (* v1 artifacts (build_exit_code = None) emit JSON without the field —
     keeps canonical bytes byte-identical to pre-#427b artifacts so old
     stored signatures continue to verify. *)
  let id_path = Filename.temp_file "peer_review_test_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove id_path with _ -> ()) (fun () ->
    let id = Relay_identity.generate ~alias_hint:"test-427b" () in
    let art : Peer_review.t = {
      version = 1;
      reviewer = "legacy";
      reviewer_pk = "";
      sha = "deadbeefcafe";
      verdict = "PASS";
      criteria_checked = ["legacy"];
      skill_version = "1.0.0";
      commit_range = "";
      targets_built = { c2c = true; c2c_mcp_server = false; c2c_inbox_hook = false };
      notes = "";
      signature = "";
      ts = 1234567890.0;
      build_exit_code = None;
    } in
    let signed = Peer_review.sign ~identity:id art in
    let json = Peer_review.t_to_string signed in
    check bool "v1 JSON does NOT contain build_exit_code field"
      false
      (let needle = "build_exit_code" in
       let nl = String.length needle and ll = String.length json in
       let rec f i = i + nl <= ll && (String.sub json i nl = needle || f (i+1)) in
       f 0);
    (* And the v1 signature still verifies *)
    match Peer_review.verify signed with
    | Ok true -> ()
    | _ -> failwith "v1 artifact (build_exit_code=None) failed verification")

let test_v2_build_rc_nonzero_signs () =
  (* A FAIL-class verdict with non-zero rc should still produce a valid
     artifact — we don't gate sign on rc==0; that's a reviewer-discipline
     check at the verdict layer, not a schema constraint. *)
  let id_path = Filename.temp_file "peer_review_test_" ".json" in
  Fun.protect ~finally:(fun () -> try Sys.remove id_path with _ -> ()) (fun () ->
    let id = Relay_identity.generate ~alias_hint:"test-427b" () in
    let signed = make_v2_artifact ~build_rc:1 ~identity:id in
    check int "non-zero build_exit_code preserved" 1
      (Option.value signed.Peer_review.build_exit_code ~default:(-1));
    match Peer_review.verify signed with
    | Ok true -> ()
    | _ -> failwith "non-zero build_rc artifact failed verification")

let () = Alcotest.run "Peer_review" [
  "signed_peer_pass", [
    Alcotest.test_case "sign and verify roundtrip" `Quick test_sign_and_verify;
    Alcotest.test_case "tampered content fails verify" `Quick test_verify_unknown_fails;
    Alcotest.test_case "missing signature error" `Quick test_missing_signature;
    Alcotest.test_case "JSON roundtrip" `Quick test_roundtrip_json;
  ];
  "tofu_pin_h1", [
    Alcotest.test_case "first verify pins pubkey" `Quick test_first_verify_pins_pubkey;
    Alcotest.test_case "second verify with same pubkey passes" `Quick test_second_verify_with_same_pubkey_passes;
    Alcotest.test_case "second verify with different pubkey rejected" `Quick test_second_verify_with_different_pubkey_rejected;
    Alcotest.test_case "rotate-pin replaces existing" `Quick test_rotate_pin_replaces_existing;
    Alcotest.test_case "rotate-pin with no prior pin" `Quick test_rotate_pin_with_no_prior_pin;
    Alcotest.test_case "[#432 TOFU 4] pin_rotate rejects tampered signature" `Quick test_pin_rotate_rejects_invalid_signature;
    Alcotest.test_case "[#432 TOFU 4] pin_rotate accepts valid signature (success contract)" `Quick test_pin_rotate_accepts_valid_signature;
    Alcotest.test_case "[#432 TOFU 5] pin_rotate accepts Mcp_operator_token when env matches" `Quick test_pin_rotate_mcp_token_accepted_when_env_matches;
    Alcotest.test_case "[#432 TOFU 5] pin_rotate rejects Mcp_operator_token + zero pin write + zero audit-log" `Quick test_pin_rotate_mcp_token_rejected_zero_write;
    Alcotest.test_case "[#432 TOFU 5] pin_rotate rejects Mcp_operator_token when env unset" `Quick test_pin_rotate_mcp_token_rejected_when_env_unset;
    Alcotest.test_case "pin store survives load/save roundtrip" `Quick test_pin_store_survives_load_save_roundtrip;
  ];
  "pin_rotate_audit_log_55", [
    Alcotest.test_case "pin_rotate emits log event with prior" `Quick
      test_pin_rotate_emits_log_event_with_prior;
    Alcotest.test_case "pin_rotate emits log event with no prior" `Quick
      test_pin_rotate_emits_log_event_no_prior;
    Alcotest.test_case "pin_rotate logger writes broker.log JSON line" `Quick
      test_pin_rotate_log_writes_json_line_under_pin_dir;
  ];
  "pin_lock_concurrency_54b", [
    Alcotest.test_case "concurrent pin_check and pin_rotate: no lost-update" `Quick
      test_concurrent_pin_check_and_rotate_no_lost_update;
  ];
  "size_cap_56", [
    Alcotest.test_case "oversized artifact rejected by capped reader" `Quick test_size_cap_rejects_oversized;
    Alcotest.test_case "oversized artifact rejected by read_artifact" `Quick test_size_cap_read_artifact_error;
    Alcotest.test_case "normal-sized artifact still passes" `Quick test_size_cap_normal_passes;
  ];
  "path_traversal_57", [
    Alcotest.test_case "alias containing '/' rejected" `Quick test_alias_with_slash_rejected;
    Alcotest.test_case "alias containing '\\' rejected" `Quick test_alias_with_backslash_rejected;
    Alcotest.test_case "alias containing '..' rejected" `Quick test_alias_with_dotdot_rejected;
    Alcotest.test_case "alias containing NUL rejected" `Quick test_alias_with_nul_rejected;
    Alcotest.test_case "alias with leading '.' rejected" `Quick test_alias_with_leading_dot_rejected;
    Alcotest.test_case "alias empty rejected" `Quick test_alias_empty_rejected;
    Alcotest.test_case "alias too long (>128 bytes) rejected (#57b)" `Quick test_alias_too_long_rejected;
    Alcotest.test_case "alias with non-printable byte rejected" `Quick test_alias_with_nonprintable_rejected;
    Alcotest.test_case "sha non-hex rejected" `Quick test_sha_non_hex_rejected;
    Alcotest.test_case "sha too short rejected" `Quick test_sha_too_short_rejected;
    Alcotest.test_case "sha too long rejected" `Quick test_sha_too_long_rejected;
    Alcotest.test_case "sha empty rejected" `Quick test_sha_empty_rejected;
    Alcotest.test_case "legitimate alias [a-z0-9_-] and sha [0-9a-f]{40} accepted" `Quick
      test_legitimate_alias_and_sha_accepted;
  ];
  "verified_build_427b", [
    Alcotest.test_case "v2 build_rc roundtrip + verify" `Quick test_v2_build_rc_roundtrip;
    Alcotest.test_case "v2 build_rc is in signature scope (tamper detected)" `Quick test_v2_build_rc_in_signature_scope;
    Alcotest.test_case "v1 artifact omits build_exit_code field (back-compat)" `Quick test_v1_artifact_omits_build_exit_code;
    Alcotest.test_case "v2 non-zero build_rc still produces valid artifact" `Quick test_v2_build_rc_nonzero_signs;
  ];
]
