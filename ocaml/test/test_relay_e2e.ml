(* Unit tests for relay_e2e.ml — S3 E2E encryption.
   Spec: M1-breakdown.md §S3. *)

open Relay_e2e

let test_enc_status () =
  Alcotest.(check string) "Ok" "ok" (enc_status_to_string Ok);
  Alcotest.(check string) "Plain" "plain" (enc_status_to_string Plain);
  Alcotest.(check string) "Failed" "failed" (enc_status_to_string Failed);
  Alcotest.(check string) "Not_for_me" "not-for-me" (enc_status_to_string Not_for_me);
  Alcotest.(check string) "Downgrade_warning" "downgrade-warning" (enc_status_to_string Downgrade_warning);
  Alcotest.(check string) "Key_changed" "key-changed" (enc_status_to_string Key_changed)

let test_sign_verify_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  let msg = "hello world" in
  let sig_bytes = sign_ed25519 ~sk_seed:seed msg in
  Alcotest.(check bool) "verify ok" true (verify_ed25519 ~pk:pk_raw ~msg ~sig_:sig_bytes);
  Alcotest.(check bool) "verify tampered fails" false (verify_ed25519 ~pk:pk_raw ~msg:"tampered" ~sig_:sig_bytes)

let test_box_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let sk, pk_raw = Mirage_crypto_ec.X25519.gen_key () in
  let sk_seed = Mirage_crypto_ec.X25519.secret_to_octets sk in
  let pk_bytes = Bytes.of_string pk_raw in
  let pt = "secret message" in
  let nonce = random_nonce () in
  let boxed = match Hacl_star.Hacl.NaCl.box ~pt:(Bytes.of_string pt) ~n:(Bytes.of_string nonce) ~pk:pk_bytes ~sk:(Bytes.of_string sk_seed) with
    | Some ct -> ct
    | None -> Alcotest.fail "box returned None"
  in
  let opened = Hacl_star.Hacl.NaCl.box_open ~ct:boxed ~n:(Bytes.of_string nonce) ~pk:pk_bytes ~sk:(Bytes.of_string sk_seed) in
  match opened with
  | Some pt' -> Alcotest.(check string) "roundtrip ok" pt (Bytes.unsafe_to_string pt')
  | None -> Alcotest.fail "box_open returned None"

let test_canonical_json_byte_stability () =
  let e = {
    from_ = "alice";
    to_ = Some "bob";
    room = None;
    ts = 1234567890L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "nonce123"; ciphertext = "ct123" } ];
    sig_b64 = "sig123";
  } in
  let json1 = canonical_json e in
  let json2 = canonical_json e in
  Alcotest.(check string) "byte-stable" json1 json2

let test_canonical_json_sorted () =
  let e = {
    from_ = "alice";
    to_ = Some "bob";
    room = None;
    ts = 1234567890L;
    enc = "box-x25519-v1";
    recipients = [ { alias = "bob"; nonce = Some "nonce123"; ciphertext = "ct123" } ];
    sig_b64 = "sig123";
  } in
  let json = canonical_json e in
  let enc_pos = try String.index json 'e' with Not_found -> -1 in
  let from_pos = try String.index json 'f' with Not_found -> -1 in
  Alcotest.(check bool) "enc before from in sorted output" (enc_pos < from_pos) true

let test_downgrade_detection () =
  let ds = make_downgrade_state () in
  let e_plain = { from_ = "alice"; to_ = Some "bob"; room = None; ts = 1L; enc = "plain"; recipients = []; sig_b64 = "" } in
  let (status, ds) = decide_enc_status ds e_plain in
  Alcotest.(check string) "first msg plain -> Plain" (enc_status_to_string status) "plain";
  let e_enc = { e_plain with enc = "box-x25519-v1" } in
  let (status, ds) = decide_enc_status ds e_enc in
  Alcotest.(check string) "encrypted after plain -> Ok" (enc_status_to_string status) "ok";
  let (status, _) = decide_enc_status ds e_plain in
  Alcotest.(check string) "plain after encrypted -> downgrade-warning" (enc_status_to_string status) "downgrade-warning"

let test_find_my_recipient_hit () =
  let recipients = [ { alias = "alice"; nonce = None; ciphertext = "" }; { alias = "bob"; nonce = Some "n"; ciphertext = "ct" } ] in
  match find_my_recipient ~my_alias:"bob" recipients with
  | Some r -> Alcotest.(check string) "found bob" r.alias "bob"
  | None -> Alcotest.fail "expected to find bob"

let test_find_my_recipient_miss () =
  let recipients = [ { alias = "alice"; nonce = None; ciphertext = "" } ] in
  match find_my_recipient ~my_alias:"bob" recipients with
  | Some _ -> Alcotest.fail "should not have found bob"
  | None -> Alcotest.(check unit) "miss ok" () ()

let test_tofu_mismatch () =
  Alcotest.(check bool) "same pk = no mismatch" false (check_pinned_ed25519_mismatch ~pinned_pk:"abc" ~claimed_pk:"abc");
  Alcotest.(check bool) "diff pk = mismatch" true (check_pinned_ed25519_mismatch ~pinned_pk:"abc" ~claimed_pk:"def");
  Alcotest.(check bool) "x25519 same = no mismatch" false (check_pinned_x25519_mismatch ~pinned_pk:"xyz" ~claimed_pk:"xyz");
  Alcotest.(check bool) "x25519 diff = mismatch" true (check_pinned_x25519_mismatch ~pinned_pk:"xyz" ~claimed_pk:"uvw")

let () =
  Alcotest.run "relay_e2e" [
    "enc_status", [
      Alcotest.test_case "enc_status_to_string all variants" `Quick test_enc_status;
    ];
    "sign_verify", [
      Alcotest.test_case "Ed25519 sign/verify roundtrip" `Quick test_sign_verify_roundtrip;
    ];
    "box", [
      Alcotest.test_case "NaCl box/box_open roundtrip with 24B nonce" `Quick test_box_roundtrip;
    ];
    "canonical_json", [
      Alcotest.test_case "byte-stable across two calls" `Quick test_canonical_json_byte_stability;
      Alcotest.test_case "fields emitted in sorted order" `Quick test_canonical_json_sorted;
    ];
    "downgrade", [
      Alcotest.test_case "downgrade detection triggers correctly" `Quick test_downgrade_detection;
    ];
    "find_recipient", [
      Alcotest.test_case "find_my_recipient hit" `Quick test_find_my_recipient_hit;
      Alcotest.test_case "find_my_recipient miss" `Quick test_find_my_recipient_miss;
    ];
    "tofu", [
      Alcotest.test_case "TOFU mismatch detection" `Quick test_tofu_mismatch;
    ];
  ]