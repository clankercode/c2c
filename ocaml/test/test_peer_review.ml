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

let () = Alcotest.run "Peer_review" [
  "signed_peer_pass", [
    Alcotest.test_case "sign and verify roundtrip" `Quick test_sign_and_verify;
    Alcotest.test_case "tampered content fails verify" `Quick test_verify_unknown_fails;
    Alcotest.test_case "missing signature error" `Quick test_missing_signature;
    Alcotest.test_case "JSON roundtrip" `Quick test_roundtrip_json;
  ];
]
