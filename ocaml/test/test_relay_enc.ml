(* Layer 3 slice 1 — X25519 encryption keypair + on-disk format tests.

   Covers:
   - generate produces 32/32-byte public/seed
   - JSON round-trip preserves all fields
   - save/load preserves key bytes byte-for-byte
   - save enforces 0600 / load refuses >0600
   - load_or_generate regenerates only on ENOENT (not on perms error)
   - absent key file → generates + saves new key
   - backward compat: file with extra fields is tolerated on load
 *)

let with_tmp_dir f =
  let base = Filename.get_temp_dir_name () in
  let name =
    Printf.sprintf "c2c-enc-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let dir = Filename.concat base name in
  Unix.mkdir dir 0o700;
  let finally () =
    (try Sys.remove (Filename.concat dir "key.x25519") with _ -> ());
    (try Sys.remove (Filename.concat dir "key.x25519.tmp") with _ -> ());
    try Unix.rmdir dir with _ -> ()
  in
  match f dir with
  | exception e -> finally (); raise e
  | v -> finally (); v

let expect_ok name = function
  | Ok v -> v
  | Error msg -> Alcotest.failf "%s: unexpected Error %s" name msg

let expect_error name = function
  | Error _ -> ()
  | Ok v -> Alcotest.failf "%s: expected Error, got Ok" name

let test_generate_shapes () =
  let key = Relay_enc.generate () in
  Alcotest.(check int) "public_key 32 bytes" 32 (String.length key.public_key);
  Alcotest.(check int) "seed 32 bytes" 32 (String.length key.private_key_seed);
  Alcotest.(check string) "alg" "x25519" key.alg;
  Alcotest.(check int) "version" 1 key.version;
  Alcotest.(check int) "created_at length > 0" 1
    (if String.length key.created_at > 0 then 1 else 0)

let test_public_key_b64 () =
  let key = Relay_enc.generate () in
  let b64 = Relay_enc.public_key_b64 key in
  Alcotest.(check bool) "b64 length > 0" true (String.length b64 > 0);
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet b64 with
  | Ok decoded ->
      Alcotest.(check string) "b64 roundtrip pk" key.public_key decoded
  | Error (`Msg m) ->
      Alcotest.failf "b64 decode failed: %s" m

let test_json_roundtrip () =
  let key = Relay_enc.generate () in
  let j = Relay_enc.to_json key in
  let key2 = expect_ok "of_json" (Relay_enc.of_json j) in
  Alcotest.(check string) "public_key" key.public_key key2.public_key;
  Alcotest.(check string) "seed" key.private_key_seed key2.private_key_seed;
  Alcotest.(check string) "alg" key.alg key2.alg;
  Alcotest.(check int) "version" key.version key2.version;
  Alcotest.(check string) "created_at" key.created_at key2.created_at

let test_of_json_unknown_field () =
  let key = Relay_enc.generate () in
  let j = Relay_enc.to_json key in
  let j_extra = `Assoc (Yojson.Safe.Util.to_assoc j @ [ "extra_field", `String "ignored" ]) in
  match Relay_enc.of_json j_extra with
  | Ok key2 ->
      Alcotest.(check string) "public_key preserved" key.public_key key2.public_key
  | Error msg ->
      Alcotest.failf "of_json rejected extra field: %s" msg

let test_save_load_roundtrip () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let key = Relay_enc.generate () in
  expect_ok "save" (Relay_enc.save ~path key);
  let key2 = expect_ok "load" (Relay_enc.load ~path ()) in
  Alcotest.(check string) "public_key" key.public_key key2.public_key;
  Alcotest.(check string) "seed" key.private_key_seed key2.private_key_seed

let test_save_enforces_0600 () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let key = Relay_enc.generate () in
  expect_ok "save" (Relay_enc.save ~path key);
  let st = Unix.stat path in
  Alcotest.(check int) "file mode 0600"
    0o600 (st.Unix.st_perm land 0o777)

let test_load_refuses_loose_perms () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let key = Relay_enc.generate () in
  expect_ok "save" (Relay_enc.save ~path key);
  Unix.chmod path 0o644;
  expect_error "load rejects 0644" (Relay_enc.load ~path ())

let test_load_or_generate_regenerates_on_enoent () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let session_id = "test-session-enoent" in
  let key1 = expect_ok "load_or_generate absent"
    (Relay_enc.load_or_generate ~session_id ~path ()) in
  Alcotest.(check int) "generated pk 32B" 32 (String.length key1.public_key);
  Alcotest.(check bool) "file created" true (Sys.file_exists path);
  let key2 = expect_ok "load_or_generate exists"
    (Relay_enc.load_or_generate ~session_id ~path ()) in
  Alcotest.(check string) "same pk on reload" key1.public_key key2.public_key

let test_load_or_generate_preserves_on_perms_error () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let session_id = "test-session-perms" in
  let (_ : Relay_enc.t) = expect_ok "load_or_generate init"
    (Relay_enc.load_or_generate ~session_id ~path ()) in
  Unix.chmod path 0o644;
  let result = Relay_enc.load_or_generate ~session_id ~path () in
  expect_error "load_or_generate rejects loose-perms" result

let test_load_or_generate_corrupt_json_error () =
  with_tmp_dir @@ fun dir ->
  let path = Filename.concat dir "key.x25519" in
  let session_id = "test-session-corrupt" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc "not json at all";
  close_out oc;
  let result = Relay_enc.load_or_generate ~session_id ~path () in
  expect_error "load_or_generate rejects corrupt JSON" result

let tests = [
  "generate_shapes",           `Quick, test_generate_shapes;
  "public_key_b64",           `Quick, test_public_key_b64;
  "json_roundtrip",           `Quick, test_json_roundtrip;
  "of_json_unknown_field",    `Quick, test_of_json_unknown_field;
  "save_load_roundtrip",      `Quick, test_save_load_roundtrip;
  "save_enforces_0600",       `Quick, test_save_enforces_0600;
  "load_refuses_loose_perms", `Quick, test_load_refuses_loose_perms;
  "load_or_generate_regenerates_on_enoent",      `Quick, test_load_or_generate_regenerates_on_enoent;
  "load_or_generate_preserves_on_perms_error",   `Quick, test_load_or_generate_preserves_on_perms_error;
  "load_or_generate_corrupt_json_error",         `Quick, test_load_or_generate_corrupt_json_error;
]

let () =
  Random.self_init ();
  Alcotest.run "relay_enc" [ "layer3", tests ]
