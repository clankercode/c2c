(* test_relay_ws_server.ml — Tests for WebSocket push subscription (slice 2). *)

let () = Mirage_crypto_rng_unix.use_default ()

module String = struct
  include String

  let is_substring ~substring s =
    try
      ignore (Str.search_forward (Str.regexp_string substring) s 0);
      true
    with Not_found -> false

  let starts_with ~prefix s =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix
end

let test_validate_auth_valid () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias@3d08761ae3f3" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let msg = alias ^ ts in
  let sig_ = Relay_identity.sign id msg in
  let sig_b64 =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
  in
  let lookup_pk ~alias:_ = Some pk in
  match Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 with
  | Relay_ws_server.Auth_ok validated_alias ->
      Alcotest.(check string) "alias matches" alias validated_alias
  | Relay_ws_server.Auth_error msg ->
      Alcotest.fail (Printf.sprintf "expected Auth_ok, got Auth_error: %s" msg)

let test_validate_auth_invalid_sig () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias@3d08761ae3f3" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let sig_ = Relay_identity.sign id "wrong-data" in
  let sig_b64 =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
  in
  let lookup_pk ~alias:_ = Some pk in
  match Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 with
  | Relay_ws_server.Auth_ok _ -> Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about signature" true
        (String.starts_with ~prefix:"signature" msg)

let test_validate_auth_unknown_alias () =
  let alias = "unknown-alias@abcdef012345" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let sig_b64 = "fakesig123456" in
  let lookup_pk ~alias:_ = None in
  match Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 with
  | Relay_ws_server.Auth_ok _ -> Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about alias" true
        (String.is_substring ~substring:"identity binding" msg
         || String.is_substring ~substring:"no identity" msg)

let test_validate_auth_expired_ts () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias@3d08761ae3f3" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday () -. 600.0) in
  let msg = alias ^ ts in
  let sig_ = Relay_identity.sign id msg in
  let sig_b64 =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
  in
  let lookup_pk ~alias:_ = Some pk in
  match Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 with
  | Relay_ws_server.Auth_ok _ -> Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about timestamp" true
        (String.is_substring ~substring:"skew" msg
         || String.is_substring ~substring:"window" msg)

let test_subscriber_map_ops () =
  Alcotest.(check bool) "no subscribers initially" false
    (Relay_ws_server.has_subscribers ~alias:"test-alias");
  Alcotest.(check int) "count is 0" 0
    (Relay_ws_server.subscriber_count ~alias:"test-alias");
  Alcotest.(check int) "total is 0" 0
    (Relay_ws_server.total_subscriber_count ())

let test_push_dm_no_subscribers () =
  Relay_ws_server.push_dm
    ~to_alias:"nobody@abcdef012345"
    ~from_alias:"sender@3d08761ae3f3"
    ~body:"test message"
    ~ts:(Unix.gettimeofday ());
  Alcotest.(check bool) "push didn't crash" true true

let test_client_session_recv_replies_to_ping_with_masked_pong () =
  let open Lwt.Infix in
  Lwt_main.run (
    let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let client_fd = Lwt_unix.of_unix_file_descr a in
    let server_fd = Lwt_unix.of_unix_file_descr b in
    let client_ic = Lwt_io.of_fd ~mode:Lwt_io.Input client_fd in
    let client_oc = Lwt_io.of_fd ~mode:Lwt_io.Output client_fd in
    let server_ic = Lwt_io.of_fd ~mode:Lwt_io.Input server_fd in
    let server_oc = Lwt_io.of_fd ~mode:Lwt_io.Output server_fd in
    let client = Relay_ws_frame.Client_session.create client_ic client_oc "mask" in
    Relay_ws_frame.write_ping server_oc >>= fun () ->
    Relay_ws_frame.Client_session.recv client >>= fun msg ->
    Alcotest.(check bool) "recv reports ping" true (msg = Some `Ping);
    Relay_ws_frame.read_frame server_ic >>= fun frame ->
    Alcotest.(check int) "client replied with pong opcode"
      Relay_ws_frame.opcode_pong frame.Relay_ws_frame.opcode;
    Lwt.return_unit)

let test_parse_endpoint_tls_defaults () =
  let https = Relay_ws_client.parse_endpoint "https://relay.c2c.im" in
  Alcotest.(check string) "https host" "relay.c2c.im" https.Relay_ws_client.host;
  Alcotest.(check int) "https default port 443" 443 https.Relay_ws_client.port;
  Alcotest.(check bool) "https use_tls" true https.Relay_ws_client.use_tls;
  Alcotest.(check string) "https path" "/ws/subscribe" https.Relay_ws_client.path;
  let wss = Relay_ws_client.parse_endpoint "wss://relay.c2c.im/custom" in
  Alcotest.(check bool) "wss use_tls" true wss.Relay_ws_client.use_tls;
  Alcotest.(check int) "wss default port 443" 443 wss.Relay_ws_client.port;
  let http = Relay_ws_client.parse_endpoint "http://localhost:7331" in
  Alcotest.(check bool) "http not tls" false http.Relay_ws_client.use_tls;
  Alcotest.(check int) "http explicit port" 7331 http.Relay_ws_client.port;
  let bare = Relay_ws_client.parse_endpoint "http://localhost" in
  Alcotest.(check int) "http default port 7331" 7331 bare.Relay_ws_client.port;
  Alcotest.(check string) "host header omits default 443"
    "relay.c2c.im" (Relay_ws_client.host_header https);
  let custom = Relay_ws_client.parse_endpoint "https://relay.example:8443" in
  Alcotest.(check string) "host header keeps non-default port"
    "relay.example:8443" (Relay_ws_client.host_header custom)

let () =
  Alcotest.run "Relay WS Server"
    [ ( "auth",
        [ Alcotest.test_case "valid signature" `Quick test_validate_auth_valid
        ; Alcotest.test_case "invalid signature" `Quick test_validate_auth_invalid_sig
        ; Alcotest.test_case "unknown alias" `Quick test_validate_auth_unknown_alias
        ; Alcotest.test_case "expired timestamp" `Quick test_validate_auth_expired_ts
        ] )
    ; ( "subscriber_map",
        [ Alcotest.test_case "map operations" `Quick test_subscriber_map_ops
        ; Alcotest.test_case "push with no subscribers" `Quick test_push_dm_no_subscribers
        ] )
    ; ( "client_session",
        [ Alcotest.test_case "recv replies to ping with masked pong" `Quick
            test_client_session_recv_replies_to_ping_with_masked_pong
        ] )
    ; ( "ws_client_endpoint",
        [ Alcotest.test_case "parse endpoint tls defaults (B189)" `Quick
            test_parse_endpoint_tls_defaults
        ] )
    ]
