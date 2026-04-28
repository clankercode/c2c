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
  (* Explicit rotation must replace the pin and surface the prior. *)
  let prior = Peer_review.pin_rotate ~path signed_b in
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
  let prior = Peer_review.pin_rotate ~path signed in
  check bool "no prior pin on first rotate" true (prior = None);
  (* And the pin is now persisted. *)
  match Peer_review.verify_with_pin ~path signed with
  | Ok Peer_review.Pin_match -> ()
  | _ -> failwith "expected Pin_match after rotate-as-first"

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
    Alcotest.test_case "pin store survives load/save roundtrip" `Quick test_pin_store_survives_load_save_roundtrip;
  ];
]
