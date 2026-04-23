(* S5b: Device-pair OAuth contract tests.
   Tests auth_decision routing for device-pair paths.
   Full handler/state tests would require moving device_pair_pending_mem
   into the RELAY state (like observer_bindings_mem). *)

module RS = Relay.Relay_server(Relay.InMemoryRelay)

let decide path =
  RS.auth_decision ~path ~include_dead:false ~token:None
    ~auth_header:None ~ed25519_verified:false

let test_device_pair_init_is_self_auth () =
  let (ok, _) = decide "/device-pair/init" in
  Alcotest.(check bool) "/device-pair/init self-auth" true ok

let test_device_pair_register_is_self_auth () =
  let (ok, _) = decide "/device-pair/abcd1234" in
  Alcotest.(check bool) "POST /device-pair/<user_code> self-auth" true ok

let test_device_pair_poll_is_self_auth () =
  let (ok, _) = RS.auth_decision ~path:"/device-pair/abcd1234"
      ~include_dead:false ~token:None ~auth_header:None ~ed25519_verified:false in
  Alcotest.(check bool) "GET /device-pair/<user_code> self-auth" true ok

let tests = [
  "device_pair auth", [
    Alcotest.test_case "/device-pair/init self-auth" `Quick
      test_device_pair_init_is_self_auth;
    Alcotest.test_case "POST /device-pair/<user_code> self-auth" `Quick
      test_device_pair_register_is_self_auth;
    Alcotest.test_case "GET /device-pair/<user_code> self-auth" `Quick
      test_device_pair_poll_is_self_auth;
  ];
]

let () =
  Alcotest.run "device_pair" tests
