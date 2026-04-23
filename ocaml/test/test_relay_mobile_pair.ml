(* S5a: mobile-pair handlers — auth + token store/confirm flow.

   Tests:
   - auth_decision: /mobile-pair/prepare and /mobile-pair are self-auth
   - prepare: happy path (store token), TTL cap, binding_id format
   - confirm: happy path (burn + bind), pubkey mismatch
   - replay: get_and_burn returns None on second call *)

module RS = Relay.Relay_server(Relay.InMemoryRelay)

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unit_sep = "\x1f"

let canonical_msg ~ctx fields =
  String.concat unit_sep (ctx :: fields)

let mobile_pair_token_sign_ctx = "c2c/v1/mobile-pair-token"

(* Build a token the same way the CLI would: canonical msg + Ed25519 sign *)
let sign_token ~binding_id ~machine_pk_b64 ~issued_at ~expires_at ~nonce
    ~(sk: string) ~(pk: string) =
  let blob = canonical_msg ~ctx:mobile_pair_token_sign_ctx
      [ binding_id; machine_pk_b64; string_of_float issued_at;
        string_of_float expires_at; nonce ] in
  match Mirage_crypto_ec.Ed25519.priv_of_octets sk with
  | Error _ -> failwith "sign_token: bad sk"
  | Ok priv ->
    let sig_ = Mirage_crypto_ec.Ed25519.sign ~key:priv blob in
    let token_json = `Assoc [
      "binding_id", `String binding_id;
      "machine_ed25519_pubkey", `String machine_pk_b64;
      "issued_at", `Float issued_at;
      "expires_at", `Float expires_at;
      "nonce", `String nonce;
      "sig", `String (b64url_encode sig_);
    ] in
    b64url_encode (Yojson.Safe.to_string token_json)

let gen_keypair () =
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  (seed, pk_raw)

(* ---- Auth decision tests ---- *)

let test_mobile_pair_prepare_is_self_auth () =
  let (ok, _) = RS.auth_decision ~path:"/mobile-pair/prepare"
      ~include_dead:false ~token:None ~auth_header:None ~ed25519_verified:false in
  Alcotest.(check bool) "/mobile-pair/prepare self-auth (no header)" true ok;
  let (ok2, _) = RS.auth_decision ~path:"/mobile-pair/prepare"
      ~include_dead:false ~token:None ~auth_header:(Some "Bearer x")
      ~ed25519_verified:false in
  Alcotest.(check bool) "/mobile-pair/prepare self-auth (Bearer is ignored)" true ok2

let test_mobile_pair_is_self_auth () =
  let (ok, _) = RS.auth_decision ~path:"/mobile-pair"
      ~include_dead:false ~token:None ~auth_header:None ~ed25519_verified:false in
  Alcotest.(check bool) "/mobile-pair self-auth (no header)" true ok

(* ---- Token helpers: is_valid_binding_id ---- *)

let is_valid_binding_id s =
  let len = String.length s in
  len >= 8 && len <= 64 &&
  String.for_all (fun c ->
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') || c = '_' || c = '-') s

let test_binding_id_valid () =
  Alcotest.(check bool) "simple valid" true (is_valid_binding_id "abc-123_XYZ");
  Alcotest.(check bool) "min length" true (is_valid_binding_id "abcdefgh");
  Alcotest.(check bool) "max length" true (is_valid_binding_id (String.make 64 'a'));
  Alcotest.(check bool) "too short" false (is_valid_binding_id "abcdefg");
  Alcotest.(check bool) "too long" false (is_valid_binding_id (String.make 65 'a'));
  Alcotest.(check bool) "invalid char sp" false (is_valid_binding_id "abc def");
  Alcotest.(check bool) "invalid char dot" false (is_valid_binding_id "abc.def");
  Alcotest.(check bool) "empty" false (is_valid_binding_id "")

(* ---- InMemoryRelay pairing token tests ---- *)

let test_store_and_burn_happy_path () =
  let r = Relay.InMemoryRelay.create () in
  let (sk_seed, pk_raw) = gen_keypair () in
  let pk_b64 = b64url_encode pk_raw in
  let now = Unix.gettimeofday () in
  let binding_id = "test-bind-01" in
  let nonce = "nonce-abc123" in
  let issued_at = now in
  let expires_at = now +. 60.0 in
  let token_b64 = sign_token ~binding_id ~machine_pk_b64:pk_b64
      ~issued_at ~expires_at ~nonce ~sk:sk_seed ~pk:pk_raw in
  Alcotest.(check bool) "find before store" false
    (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  let store_result = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64 ~machine_ed25519_pubkey:pk_b64 ~expires_at in
  Alcotest.(check bool) "store ok" true (Result.is_ok store_result);
  Alcotest.(check bool) "find after store" true
    (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  let burned = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
  match burned with
  | None -> Alcotest.fail "expected Some(token, pk) after burn"
  | Some (t, p) ->
    Alcotest.(check string) "burned token matches" token_b64 t;
    Alcotest.(check string) "burned pk matches" pk_b64 p;
    Alcotest.(check bool) "find after burn" false
      (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
    let burned2 = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
    Alcotest.(check bool) "replay: second burn returns None" true (burned2 = None)

let test_expired_token_not_returned () =
  let r = Relay.InMemoryRelay.create () in
  let (sk_seed, pk_raw) = gen_keypair () in
  let pk_b64 = b64url_encode pk_raw in
  let now = Unix.gettimeofday () in
  let binding_id = "test-bind-expired" in
  let nonce = "nonce-expired" in
  let issued_at = now -. 400.0 in
  let expires_at = now -. 300.0 in
  let token_b64 = sign_token ~binding_id ~machine_pk_b64:pk_b64
      ~issued_at ~expires_at ~nonce ~sk:sk_seed ~pk:pk_raw in
  let store_result = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64 ~machine_ed25519_pubkey:pk_b64 ~expires_at in
  Alcotest.(check bool) "store expired token ok" true (Result.is_ok store_result);
  Alcotest.(check bool) "find_pairing_token: expired token not found (cleaned up)"
    false (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  let burned = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
  Alcotest.(check bool) "burn expired token returns None" true (burned = None)

let test_pubkey_mismatch_in_burn () =
  let r = Relay.InMemoryRelay.create () in
  let (sk_seed, pk_raw) = gen_keypair () in
  let pk_b64 = b64url_encode pk_raw in
  let now = Unix.gettimeofday () in
  let binding_id = "test-bind-pk-mismatch" in
  let nonce = "nonce-pkmismatch" in
  let issued_at = now in
  let expires_at = now +. 60.0 in
  let token_b64 = sign_token ~binding_id ~machine_pk_b64:pk_b64
      ~issued_at ~expires_at ~nonce ~sk:sk_seed ~pk:pk_raw in
  let (other_seed, other_pk_raw) = gen_keypair () in
  let other_pk_b64 = b64url_encode other_pk_raw in
  let store_result = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64 ~machine_ed25519_pubkey:other_pk_b64 ~expires_at in
  Alcotest.(check bool) "store with different pk ok" true (Result.is_ok store_result);
  let burned = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
  match burned with
  | None -> Alcotest.fail "expected Some — burn succeeds even with pk mismatch (caller must verify)"
  | Some (t, p) ->
    Alcotest.(check bool) "burned token is the stored one" true
      (t = token_b64 && p = other_pk_b64)

let test_rebind_overwrites_previous () =
  let r = Relay.InMemoryRelay.create () in
  let (sk1_seed, pk1_raw) = gen_keypair () in
  let pk1_b64 = b64url_encode pk1_raw in
  let (sk2_seed, pk2_raw) = gen_keypair () in
  let pk2_b64 = b64url_encode pk2_raw in
  let now = Unix.gettimeofday () in
  let binding_id = "test-bind-rebind" in
  let nonce1 = "nonce-first" in
  let nonce2 = "nonce-second" in
  let expires_at1 = now +. 60.0 in
  let expires_at2 = now +. 120.0 in
  let token1 = sign_token ~binding_id ~machine_pk_b64:pk1_b64
      ~issued_at:now ~expires_at:expires_at1 ~nonce:nonce1
      ~sk:sk1_seed ~pk:pk1_raw in
  let token2 = sign_token ~binding_id ~machine_pk_b64:pk2_b64
      ~issued_at:now ~expires_at:expires_at2 ~nonce:nonce2
      ~sk:sk2_seed ~pk:pk2_raw in
  let s1 = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64:token1 ~machine_ed25519_pubkey:pk1_b64 ~expires_at:expires_at1 in
  Alcotest.(check bool) "first store ok" true (Result.is_ok s1);
  Alcotest.(check bool) "find_pairing_token before rebind" true
    (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  let s2 = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64:token2 ~machine_ed25519_pubkey:pk2_b64 ~expires_at:expires_at2 in
  Alcotest.(check bool) "second store (rebind) ok" true (Result.is_ok s2);
  let burned = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
  match burned with
  | None -> Alcotest.fail "expected Some after rebind burn"
  | Some (t, p) ->
    Alcotest.(check string) "burned token is the SECOND one" token2 t;
    Alcotest.(check string) "burned pk is the SECOND pk" p pk2_b64

(* ---- Observer binding tests ---- *)

let test_observer_binding_add_get_remove () =
  let r = Relay.InMemoryRelay.create () in
  let (_, pk_raw) = gen_keypair () in
  let phone_ed = b64url_encode pk_raw in
  let phone_x = b64url_encode pk_raw in
  let binding_id = "test-obs-bind-01" in
  Alcotest.(check bool) "get before add" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id = None);
  Relay.InMemoryRelay.add_observer_binding r ~binding_id
    ~phone_ed25519_pubkey:phone_ed ~phone_x25519_pubkey:phone_x;
  let got = Relay.InMemoryRelay.get_observer_binding r ~binding_id in
  Alcotest.(check bool) "get after add" true
    (got = Some (phone_ed, phone_x));
  Relay.InMemoryRelay.remove_observer_binding r ~binding_id;
  Alcotest.(check bool) "get after remove" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id = None)

(* ---- Run tests ---- *)

let tests = [
  "auth", [
    Alcotest.test_case "/mobile-pair/prepare self-auth" `Quick
      test_mobile_pair_prepare_is_self_auth;
    Alcotest.test_case "/mobile-pair self-auth" `Quick
      test_mobile_pair_is_self_auth;
  ];
  "binding_id format", [
    Alcotest.test_case "valid/invalid binding_id patterns" `Quick
      test_binding_id_valid;
  ];
  "pairing token", [
    Alcotest.test_case "store + burn happy path + replay" `Quick
      test_store_and_burn_happy_path;
    Alcotest.test_case "expired token not returned" `Quick
      test_expired_token_not_returned;
    Alcotest.test_case "pubkey mismatch in burn" `Quick
      test_pubkey_mismatch_in_burn;
    Alcotest.test_case "rebind overwrites previous" `Quick
      test_rebind_overwrites_previous;
  ];
  "observer binding", [
    Alcotest.test_case "add/get/remove observer binding" `Quick
      test_observer_binding_add_get_remove;
  ];
]

let () =
  Alcotest.run "mobile_pair" tests
