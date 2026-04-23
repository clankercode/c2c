(* S7: Observer + mobile-pair contract tests.
   Tests:
   - auth_decision for observer WS paths (peer route, Ed25519 required)
   - auth_decision for /binding/<id> DELETE (self-auth)
   - auth_decision for mobile-pair/prepare and mobile-pair (self-auth, already covered)
   - full mobile-pair round-trip: prepare → confirm → revoke
   - observer binding lifecycle: add → WS session register → remove *)

module RS = Relay.Relay_server(Relay.InMemoryRelay)

let b64url_encode s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let b64url_decode s =
  Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let unit_sep = "\x1f"

let canonical_msg ~ctx fields =
  String.concat unit_sep (ctx :: fields)

let mobile_pair_token_sign_ctx = "c2c/v1/mobile-pair-token"

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

(* ---- Observer path auth_decision tests ---- *)

let decide_observer path =
  RS.auth_decision ~path ~include_dead:false ~token:(Some "t0p")
    ~auth_header:None ~ed25519_verified:false

let test_observer_path_needs_ed25519 () =
  let (ok, msg) = decide_observer "/observer/test-binding-01" in
  Alcotest.(check bool) "/observer/<id> rejected without Ed25519" false ok;
  let msg_has_ed25519 = match msg with
    | Some m -> (try ignore (Str.search_forward (Str.regexp "Ed25519") m 0); true with Not_found -> false)
    | None -> false in
  Alcotest.(check bool) "error mentions Ed25519" true msg_has_ed25519

let test_observer_path_with_ed25519 () =
  let hdr = Some "Ed25519 alias=x,ts=1,nonce=n,sig=s" in
  let (ok, _) = RS.auth_decision ~path:"/observer/test-binding-01"
      ~include_dead:false ~token:(Some "t0p") ~auth_header:hdr
      ~ed25519_verified:true in
  Alcotest.(check bool) "/observer/<id> allowed with Ed25519" true ok

let test_observer_path_dev_mode_allowed () =
  let (ok, _) = RS.auth_decision ~path:"/observer/test-binding-01"
      ~include_dead:false ~token:None ~auth_header:None ~ed25519_verified:false in
  Alcotest.(check bool) "/observer/<id> allowed in dev mode (no token)" true ok

(* ---- /binding/ DELETE path auth_decision tests ---- *)

let decide_binding_delete binding_id =
  let path = "/binding/" ^ binding_id in
  RS.auth_decision ~path ~include_dead:false ~token:(Some "t0p")
    ~auth_header:None ~ed25519_verified:false

let test_binding_delete_is_self_auth () =
  let (ok, _) = decide_binding_delete "test-bind-del" in
  Alcotest.(check bool) "DELETE /binding/<id> self-auth (no header)" true ok

let test_binding_delete_with_bearer_ignored () =
  let hdr = Some "Bearer t0p" in
  let path = "/binding/test-bind-del" in
  let (ok, _) = RS.auth_decision ~path ~include_dead:false ~token:(Some "t0p")
      ~auth_header:hdr ~ed25519_verified:false in
  Alcotest.(check bool) "DELETE /binding/<id> self-auth (Bearer ignored)" true ok

(* ---- Full mobile-pair round-trip via InMemoryRelay ---- *)

let test_mobile_pair_full_round_trip () =
  let r = Relay.InMemoryRelay.create () in
  let (machine_sk, machine_pk_raw) = gen_keypair () in
  let machine_pk_b64 = b64url_encode machine_pk_raw in
  let (phone_sk, phone_pk_raw) = gen_keypair () in
  let phone_ed_b64 = b64url_encode phone_pk_raw in
  let phone_x_b64 = b64url_encode phone_pk_raw in
  let now = Unix.gettimeofday () in
  let binding_id = "round-trip-bind" in
  let nonce = "nonce-roundtrip" in
  let issued_at = now in
  let expires_at = now +. 300.0 in
  let token_b64 = sign_token ~binding_id ~machine_pk_b64
      ~issued_at ~expires_at ~nonce ~sk:machine_sk ~pk:machine_pk_raw in
  let store_result = Relay.InMemoryRelay.store_pairing_token r ~binding_id
      ~token_b64 ~machine_ed25519_pubkey:machine_pk_b64 ~expires_at in
  Alcotest.(check bool) "store pairing token ok" true (Result.is_ok store_result);
  Alcotest.(check bool) "binding found before confirm" true
    (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  let burned = Relay.InMemoryRelay.get_and_burn_pairing_token r ~binding_id in
  Alcotest.(check bool) "burn returns Some" true (Option.is_some burned);
  let (t, p) = Option.get burned in
  Alcotest.(check string) "burned token matches" token_b64 t;
  Alcotest.(check string) "burned pk matches" machine_pk_b64 p;
  Alcotest.(check bool) "binding consumed after burn" false
    (Relay.InMemoryRelay.find_pairing_token r ~binding_id);
  Relay.InMemoryRelay.add_observer_binding r ~binding_id
    ~phone_ed25519_pubkey:phone_ed_b64 ~phone_x25519_pubkey:phone_x_b64
    ~machine_ed25519_pubkey:"" ~provenance_sig:"";
  let observer_binding = Relay.InMemoryRelay.get_observer_binding r ~binding_id in
  Alcotest.(check bool) "observer binding exists after confirm" true
    (observer_binding = Some (phone_ed_b64, phone_x_b64, "", ""));
  Relay.InMemoryRelay.remove_observer_binding r ~binding_id;
  Alcotest.(check bool) "observer binding gone after revoke" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id = None)

(* ---- get_observer_binding on nonexistent binding returns None ---- *)

let test_get_nonexistent_binding_returns_none () =
  let r = Relay.InMemoryRelay.create () in
  let existed = match Relay.InMemoryRelay.get_observer_binding r ~binding_id:"no-such-bind" with
    | None -> false | Some _ -> true in
  Alcotest.(check bool) "nonexistent binding reports not found" false existed

(* ---- ObserverSessions wiring via InMemoryRelay ShortQueue ---- *)

let test_observer_binding_isolation () =
  let r = Relay.InMemoryRelay.create () in
  let (_, pk_raw) = gen_keypair () in
  let phone_ed = b64url_encode pk_raw in
  let phone_x = b64url_encode pk_raw in
  let binding_a = "isolate-bind-a" in
  let binding_b = "isolate-bind-b" in
  Relay.InMemoryRelay.add_observer_binding r ~binding_id:binding_a
    ~phone_ed25519_pubkey:phone_ed ~phone_x25519_pubkey:phone_x
    ~machine_ed25519_pubkey:"" ~provenance_sig:"";
  Relay.InMemoryRelay.add_observer_binding r ~binding_id:binding_b
    ~phone_ed25519_pubkey:phone_ed ~phone_x25519_pubkey:phone_x
    ~machine_ed25519_pubkey:"" ~provenance_sig:"";
  Alcotest.(check bool) "binding A exists" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id:binding_a <> None);
  Alcotest.(check bool) "binding B exists" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id:binding_b <> None);
  Relay.InMemoryRelay.remove_observer_binding r ~binding_id:binding_a;
  Alcotest.(check bool) "binding A gone after remove" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id:binding_a = None);
  Alcotest.(check bool) "binding B still exists" true
    (Relay.InMemoryRelay.get_observer_binding r ~binding_id:binding_b <> None)

(* ---- Run tests ---- *)

let tests = [
  "observer auth_decision", [
    Alcotest.test_case "/observer/<id> needs Ed25519" `Quick
      test_observer_path_needs_ed25519;
    Alcotest.test_case "/observer/<id> allowed with Ed25519" `Quick
      test_observer_path_with_ed25519;
    Alcotest.test_case "/observer/<id> allowed dev mode" `Quick
      test_observer_path_dev_mode_allowed;
  ];
  "binding delete auth_decision", [
    Alcotest.test_case "DELETE /binding/<id> self-auth" `Quick
      test_binding_delete_is_self_auth;
    Alcotest.test_case "DELETE /binding/<id> Bearer ignored" `Quick
      test_binding_delete_with_bearer_ignored;
  ];
  "mobile-pair round-trip", [
    Alcotest.test_case "prepare → confirm → revoke full flow" `Quick
      test_mobile_pair_full_round_trip;
    Alcotest.test_case "get nonexistent binding returns None" `Quick
      test_get_nonexistent_binding_returns_none;
  ];
  "observer binding isolation", [
    Alcotest.test_case "bindings are isolated per binding_id" `Quick
      test_observer_binding_isolation;
  ];
]

let () =
  Alcotest.run "relay_observer_contract" tests
