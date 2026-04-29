(* Integration tests for relay_e2e.ml — S3b E2E crypto.
   Tests round-trip encrypt/decrypt, sig verify, and temp key dir override. *)

open Relay_e2e
module Enc = Relay_enc

let test_encrypt_decrypt_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  (* Alice generates an X25519 keypair for encryption *)
  let alice_sk, alice_pk = Mirage_crypto_ec.X25519.gen_key () in
  let alice_seed = Mirage_crypto_ec.X25519.secret_to_octets alice_sk in
  (* Bob generates an X25519 keypair *)
  let bob_sk, bob_pk = Mirage_crypto_ec.X25519.gen_key () in
  let bob_seed = Mirage_crypto_ec.X25519.secret_to_octets bob_sk in
  (* Alice encrypts a message for Bob *)
  let plaintext = "secret message from alice to bob" in
  let boxed_opt = encrypt_for_recipient ~pt:plaintext ~recipient_pk_b64:(b64_encode bob_pk) ~our_sk_seed:alice_seed in
  match boxed_opt with
  | None -> Alcotest.fail "encrypt_for_recipient returned None"
  | Some (ciphertext, nonce) ->
    Alcotest.(check bool) "ciphertext is non-empty" true (ciphertext <> "");
    Alcotest.(check bool) "nonce is non-empty" true (nonce <> "");
    (* Bob decrypts *)
    let decrypted_opt = decrypt_for_me ~ct_b64:ciphertext ~nonce_b64:nonce ~sender_pk_b64:(b64_encode alice_pk) ~our_sk_seed:bob_seed in
    match decrypted_opt with
    | None -> Alcotest.fail "decrypt_for_me returned None"
    | Some decrypted -> Alcotest.(check string) "decrypted matches original" plaintext decrypted

let test_sign_verify_envelope_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  let envelope = {
    from_ = "alice";
    from_x25519 = None;
    to_ = Some "bob";
    room = None;
    ts = 1234567890L;
    enc = "box-x25519-v1";
    recipients = [];
    sig_b64 = "";
    envelope_version = current_envelope_version;
  } in
  let sig_ = sign_envelope ~sk_seed:seed envelope in
  Alcotest.(check bool) "sig_ is non-empty" true (sig_ <> "");
  (* Create signed envelope for verification *)
  let signed_envelope = { envelope with sig_b64 = sig_ } in
  Alcotest.(check bool) "verify ok" true (verify_envelope_sig ~pk:pk_raw signed_envelope);
  (* Tamper with envelope — verify should fail *)
  let tampered = { signed_envelope with from_ = "eve" } in
  Alcotest.(check bool) "verify tampered fails" false (verify_envelope_sig ~pk:pk_raw tampered)

let test_full_e2e_two_party () =
  Mirage_crypto_rng_unix.use_default ();
  (* Setup: Alice and Bob each have identity keys (Ed25519) and encryption keys (X25519) *)
  let alice_sk, alice_pk = Mirage_crypto_ec.X25519.gen_key () in
  let alice_id_priv, alice_id_pub = Mirage_crypto_ec.Ed25519.generate () in
  let alice_id_seed = Mirage_crypto_ec.Ed25519.priv_to_octets alice_id_priv in
  let alice_id_pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets alice_id_pub in
  let bob_sk, bob_pk = Mirage_crypto_ec.X25519.gen_key () in
  let bob_id_priv, bob_id_pub = Mirage_crypto_ec.Ed25519.generate () in
  let bob_pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets bob_id_pub in
  let bob_id_seed = Mirage_crypto_ec.Ed25519.priv_to_octets bob_id_priv in
  (* Alice encrypts for Bob *)
  let pt = "hello bob, this is a secret" in
  let boxed_opt = encrypt_for_recipient ~pt ~recipient_pk_b64:(b64_encode bob_pk) ~our_sk_seed:(Mirage_crypto_ec.X25519.secret_to_octets alice_sk) in
  match boxed_opt with
  | None -> Alcotest.fail "encrypt_for_recipient returned None"
  | Some (ciphertext, nonce) ->
    (* Build envelope with sig *)
    let e = {
      from_ = "alice";
      from_x25519 = Some (b64_encode alice_pk);
      to_ = Some "bob";
      room = None;
      ts = 1234567890L;
      enc = "box-x25519-v1";
      recipients = [{ alias = "bob"; nonce = Some nonce; ciphertext }];
      sig_b64 = "";
      envelope_version = current_envelope_version;
    } in
    let sig_ = sign_envelope ~sk_seed:alice_id_seed e in
    let e_signed = { e with sig_b64 = sig_ } in
    Alcotest.(check bool) "bob verifies alice's sig" true (verify_envelope_sig ~pk:alice_id_pk_raw e_signed);
    (* Bob decrypts *)
    let decrypted_opt = decrypt_for_me ~ct_b64:ciphertext ~nonce_b64:nonce ~sender_pk_b64:(b64_encode alice_pk) ~our_sk_seed:(Mirage_crypto_ec.X25519.secret_to_octets bob_sk) in
    match decrypted_opt with
    | None -> Alcotest.fail "decrypt_for_me returned None"
    | Some decrypted -> Alcotest.(check string) "bob recovers plaintext" pt decrypted

let test_temp_key_dir_override () =
  Mirage_crypto_rng_unix.use_default ();
  (* Create a temp directory for keys *)
  let temp_dir = (Filename.get_temp_dir_name ()) ^ "/c2c_e2e_test_" ^ string_of_int (Unix.getpid ()) in
  (try Unix.mkdir temp_dir 0o700 with Unix.Unix_error _ -> ());
  let alias = "test-alias-e2e" in
  (* Set env var *)
  Unix.putenv "C2C_KEY_DIR" temp_dir;
  (* Generate a key *)
  let t1 = match Enc.load_or_generate ~alias () with
    | Ok t -> t
    | Error e -> Alcotest.fail ("load_or_generate failed: " ^ e)
  in
  Alcotest.(check string) "version is 1" "1" (string_of_int t1.Enc.version);
  (* Key file should be in temp_dir *)
  let expected_path = temp_dir ^ "/" ^ alias ^ ".x25519" in
  Alcotest.(check bool) "key file exists" true (Sys.file_exists expected_path);
  (* Load again — should get same key *)
  let t2 = match Enc.load_or_generate ~alias () with
    | Ok t -> t
    | Error e -> Alcotest.fail ("load_or_generate failed: " ^ e)
  in
  Alcotest.(check string) "same public key" t1.Enc.public_key t2.Enc.public_key;
  (* Cleanup *)
  (try Sys.remove expected_path with _ -> ());
  (try Unix.rmdir temp_dir with _ -> ());
  Unix.putenv "C2C_KEY_DIR" ""

let () =
  Alcotest.run "relay_e2e_integration" [
    "encrypt_decrypt", [
      Alcotest.test_case "encrypt/decrypt roundtrip" `Quick test_encrypt_decrypt_roundtrip;
    ];
    "sign_verify", [
      Alcotest.test_case "sign/verify envelope roundtrip" `Quick test_sign_verify_envelope_roundtrip;
    ];
    "full_e2e", [
      Alcotest.test_case "two-party full E2E" `Quick test_full_e2e_two_party;
    ];
    "key_dir_override", [
      Alcotest.test_case "C2C_KEY_DIR env override" `Quick test_temp_key_dir_override;
    ];
  ]
