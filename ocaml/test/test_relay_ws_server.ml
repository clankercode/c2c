(* test_relay_ws_server.ml — Tests for WebSocket push subscription (slice 2). *)

let () = Mirage_crypto_rng_unix.use_default ()

(* Helper for substring check *)
module String = struct
  include String
  let is_substring ~substring s =
    try
      let _ = Str.search_forward (Str.regexp_string substring) s 0 in
      true
    with Not_found -> false
  let starts_with ~prefix s =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix
end

(* Test: validate_subscribe_auth with valid signature *)
let test_validate_auth_valid () =
  (* Generate a test identity *)
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias#abc123" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let msg = alias ^ ts in
  let sig_ = Relay_identity.sign id msg in
  let sig_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_ in

  let lookup_pk ~alias:_ = Some pk in
  let result = Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 in
  match result with
  | Relay_ws_server.Auth_ok validated_alias ->
      Alcotest.(check string) "alias matches" alias validated_alias
  | Relay_ws_server.Auth_error msg ->
      Alcotest.fail (Printf.sprintf "expected Auth_ok, got Auth_error: %s" msg)

(* Test: validate_subscribe_auth with invalid signature *)
let test_validate_auth_invalid_sig () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias#abc123" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  (* Wrong signature - sign different data *)
  let sig_ = Relay_identity.sign id "wrong-data" in
  let sig_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_ in

  let lookup_pk ~alias:_ = Some pk in
  let result = Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 in
  match result with
  | Relay_ws_server.Auth_ok _ ->
      Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about signature" true
        (String.starts_with ~prefix:"signature" msg)

(* Test: validate_subscribe_auth with unknown alias *)
let test_validate_auth_unknown_alias () =
  let alias = "unknown-alias#xyz789" in
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let sig_b64 = "fakesig123456" in

  let lookup_pk ~alias:_ = None in
  let result = Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 in
  match result with
  | Relay_ws_server.Auth_ok _ ->
      Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about alias" true
        (String.is_substring ~substring:"identity binding" msg ||
         String.is_substring ~substring:"no identity" msg)

(* Test: validate_subscribe_auth with expired timestamp *)
let test_validate_auth_expired_ts () =
  let id = Relay_identity.generate ~alias_hint:"test" () in
  let pk = id.Relay_identity.public_key in
  let alias = "test-alias#abc123" in
  (* Timestamp 10 minutes ago - outside the 60s window *)
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday () -. 600.0) in
  let msg = alias ^ ts in
  let sig_ = Relay_identity.sign id msg in
  let sig_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_ in

  let lookup_pk ~alias:_ = Some pk in
  let result = Relay_ws_server.validate_subscribe_auth ~lookup_pk ~alias ~ts_str:ts ~sig_b64 in
  match result with
  | Relay_ws_server.Auth_ok _ ->
      Alcotest.fail "expected Auth_error, got Auth_ok"
  | Relay_ws_server.Auth_error msg ->
      Alcotest.(check bool) "got auth error" true (String.length msg > 0);
      Alcotest.(check bool) "error about timestamp" true
        (String.is_substring ~substring:"skew" msg ||
         String.is_substring ~substring:"window" msg)

(* Test: subscriber map operations *)
let test_subscriber_map_ops () =
  (* Test has_subscribers and subscriber_count with no subscribers *)
  Alcotest.(check bool) "no subscribers initially" false
    (Relay_ws_server.has_subscribers ~alias:"test-alias");
  Alcotest.(check int) "count is 0" 0
    (Relay_ws_server.subscriber_count ~alias:"test-alias");
  Alcotest.(check int) "total is 0" 0
    (Relay_ws_server.total_subscriber_count ())

(* Test: push_dm doesn't crash with no subscribers *)
let test_push_dm_no_subscribers () =
  (* Should not crash when no subscribers exist *)
  Relay_ws_server.push_dm
    ~to_alias:"nobody#xyz"
    ~from_alias:"sender#abc"
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

let () =
  Alcotest.run "Relay WS Server" [
    "auth", [
      Alcotest.test_case "valid signature" `Quick test_validate_auth_valid;
      Alcotest.test_case "invalid signature" `Quick test_validate_auth_invalid_sig;
      Alcotest.test_case "unknown alias" `Quick test_validate_auth_unknown_alias;
      Alcotest.test_case "expired timestamp" `Quick test_validate_auth_expired_ts;
    ];
    "subscriber_map", [
      Alcotest.test_case "map operations" `Quick test_subscriber_map_ops;
      Alcotest.test_case "push with no subscribers" `Quick test_push_dm_no_subscribers;
    ];
    "client_session", [
      Alcotest.test_case "recv replies to ping with masked pong" `Quick
        test_client_session_recv_replies_to_ping_with_masked_pong;
    ];
  ]
