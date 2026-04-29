(* Layer 3 slice 1 — identity keypair + on-disk format tests.

   Covers:
   - generate produces 32/32-byte public/seed + 64-byte signature
   - fingerprint format matches spec (SHA256:<43 chars base64url-nopad>)
   - JSON round-trip preserves all fields
   - save/load preserves identity byte-for-byte
   - save enforces 0600 / load refuses >0600
   - canonical_msg uses 0x1f separator
*)

let with_tmp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "c2c-identity-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o700;
  let finally () =
    (try Sys.remove (Filename.concat dir "identity.json") with _ -> ());
    (try Sys.remove (Filename.concat dir "identity.json.tmp") with _ -> ());
    try Unix.rmdir dir with _ -> ()
  in
  match f dir with
  | exception e -> finally (); raise e
  | v -> finally (); v

let expect_ok name = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "%s: unexpected Error %s" name msg

let test_generate_shapes () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  Alcotest.(check int) "public_key 32 bytes" 32 (String.length id.public_key);
  Alcotest.(check int) "seed 32 bytes" 32 (String.length id.private_key_seed);
  Alcotest.(check string) "alg" "ed25519" id.alg;
  Alcotest.(check int) "version" 1 id.version;
  Alcotest.(check string) "alias_hint preserved" "test" id.alias_hint;
  (* fingerprint format: "SHA256:" + 43 chars *)
  Alcotest.(check int) "fingerprint length" (7 + 43)
    (String.length id.fingerprint);
  Alcotest.(check bool) "fingerprint prefix" true
    (String.length id.fingerprint >= 7
     && String.sub id.fingerprint 0 7 = "SHA256:")

let test_sign_verify_roundtrip () =
  let id = Relay_identity.generate () in
  let msg = "hello world" in
  let sig_ = Relay_identity.sign id msg in
  Alcotest.(check int) "signature 64 bytes" 64 (String.length sig_);
  Alcotest.(check bool) "verify with matching pk+msg" true
    (Relay_identity.verify ~pk:id.public_key ~msg ~sig_);
  Alcotest.(check bool) "verify fails with wrong msg" false
    (Relay_identity.verify ~pk:id.public_key ~msg:"other" ~sig_);
  let id2 = Relay_identity.generate () in
  Alcotest.(check bool) "verify fails with wrong pk" false
    (Relay_identity.verify ~pk:id2.public_key ~msg ~sig_)

let test_verify_malformed () =
  let id = Relay_identity.generate () in
  let sig_ = Relay_identity.sign id "x" in
  Alcotest.(check bool) "short pk rejected" false
    (Relay_identity.verify ~pk:"short" ~msg:"x" ~sig_);
  Alcotest.(check bool) "short sig rejected" false
    (Relay_identity.verify ~pk:id.public_key ~msg:"x" ~sig_:"short")

let test_json_roundtrip () =
  let id = Relay_identity.generate ~alias_hint:"foo" () in
  let j = Relay_identity.to_json id in
  let id2 = expect_ok "of_json" (Relay_identity.of_json j) in
  Alcotest.(check string) "public_key" id.public_key id2.public_key;
  Alcotest.(check string) "seed" id.private_key_seed id2.private_key_seed;
  Alcotest.(check string) "fingerprint" id.fingerprint id2.fingerprint;
  Alcotest.(check string) "created_at" id.created_at id2.created_at;
  Alcotest.(check string) "alias_hint" id.alias_hint id2.alias_hint

let test_save_load_roundtrip () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "identity.json" in
  let id = Relay_identity.generate ~alias_hint:"abc" () in
  expect_ok "save" (Relay_identity.save ~path id);
  let id2 = expect_ok "load" (Relay_identity.load ~path ()) in
  Alcotest.(check string) "public_key" id.public_key id2.public_key;
  Alcotest.(check string) "seed" id.private_key_seed id2.private_key_seed;
  (* Re-sign with loaded identity — should verify against original pk *)
  let sig_ = Relay_identity.sign id2 "msg" in
  Alcotest.(check bool) "loaded key signs verifiably" true
    (Relay_identity.verify ~pk:id.public_key ~msg:"msg" ~sig_)

let test_save_enforces_0600 () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "identity.json" in
  let id = Relay_identity.generate () in
  expect_ok "save" (Relay_identity.save ~path id);
  let st = Unix.stat path in
  Alcotest.(check int) "file mode 0600"
    0o600 (st.Unix.st_perm land 0o777)

let test_load_refuses_loose_perms () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "identity.json" in
  let id = Relay_identity.generate () in
  expect_ok "save" (Relay_identity.save ~path id);
  Unix.chmod path 0o644;
  match Relay_identity.load ~path () with
  | Ok _ -> Alcotest.fail "expected Error on 0644 identity.json"
  | Error msg ->
    Alcotest.(check bool) "error mentions permissions" true
      (let needle = "permissions" in
       try
         let _ = Str.search_forward (Str.regexp_string needle) msg 0 in true
       with Not_found -> false)

let test_load_or_create_at_eacces_falls_back_to_memory () =
  (* Simulate a volume where we can read but not write (e.g. Railway /data
     with wrong uid).  load_or_create_at should NOT failwith — it must
     log clearly, fall back to in-memory identity, and return.
     The marker file may end up in /tmp (fallback) or alongside the path
     depending on directory permissions; we verify behavior via exit path. *)
  with_tmp_dir @@ fun dir ->
  let readonly_subdir = Filename.concat dir "readonly" in
  Unix.mkdir readonly_subdir 0o500;  (* read+execute only, no write *)
  let id_path = Filename.concat readonly_subdir "relay-server-identity.json" in
  (* Calling with a path in the readonly dir — save will fail with EACCES.
     The function must return an identity rather than raising. *)
  let id = Relay_identity.load_or_create_at ~path:id_path ~alias_hint:"eacces-test" in
  Alcotest.(check bool) "returned identity has non-empty pk"
    true (String.length id.public_key > 0);
  Alcotest.(check bool) "returned identity has alias hint"
    true (String.length id.alias_hint > 0)

let test_canonical_msg_separator () =
  let out =
    Relay_identity.canonical_msg ~ctx:"c2c/v1/register" [ "alice"; "42" ]
  in
  Alcotest.(check string) "ctx + fields joined with 0x1f"
    ("c2c/v1/register\x1falice\x1f42") out

let tests = [
  "generate_shapes",          `Quick, test_generate_shapes;
  "sign_verify_roundtrip",    `Quick, test_sign_verify_roundtrip;
  "verify_malformed",         `Quick, test_verify_malformed;
  "json_roundtrip",           `Quick, test_json_roundtrip;
  "save_load_roundtrip",      `Quick, test_save_load_roundtrip;
  "save_enforces_0600",       `Quick, test_save_enforces_0600;
  "load_refuses_loose_perms", `Quick, test_load_refuses_loose_perms;
  "canonical_msg_separator",  `Quick, test_canonical_msg_separator;
  "load_or_create_at_eacces", `Quick, test_load_or_create_at_eacces_falls_back_to_memory;
]

let () =
  Random.self_init ();
  Alcotest.run "relay_identity" [ "layer3", tests ]
