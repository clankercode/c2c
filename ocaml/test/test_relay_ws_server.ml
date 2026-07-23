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

(* --- B277: connection-cap enforcement + cleanup frees slots --- *)

let with_cap_limits ~max_total ~max_per_ip ?(retry_after_s = 7.0) f =
  Relay_ws_server.reset_connection_cap ();
  Relay_ws_server.set_connection_limits ~max_total ~max_per_ip ~retry_after_s ();
  Fun.protect
    ~finally:(fun () -> Relay_ws_server.reset_connection_cap ())
    f

let acquire_or_fail ~client_ip =
  match Relay_ws_server.try_acquire_slot ~client_ip with
  | Relay_ws_server.Acquired slot -> slot
  | Relay_ws_server.Denied _ -> Alcotest.fail "expected Acquired"

let test_cap_global_limit () =
  with_cap_limits ~max_total:2 ~max_per_ip:100 (fun () ->
    let s1 = acquire_or_fail ~client_ip:"10.0.0.1" in
    let s2 = acquire_or_fail ~client_ip:"10.0.0.2" in
    Alcotest.(check int) "active=2" 2 (Relay_ws_server.active_connection_count ());
    (match Relay_ws_server.try_acquire_slot ~client_ip:"10.0.0.3" with
     | Relay_ws_server.Acquired _ -> Alcotest.fail "expected global cap deny"
     | Relay_ws_server.Denied { reason; retry_after_s } ->
         Alcotest.(check bool) "Cap_global"
           true (reason = Relay_ws_server.Cap_global);
         Alcotest.(check (float 0.01)) "retry_after" 7.0 retry_after_s;
         Alcotest.(check string) "label" "global"
           (Relay_ws_server.cap_denial_label reason));
    let denied_g, denied_ip = Relay_ws_server.cap_denied_counts () in
    Alcotest.(check int) "denied_global=1" 1 denied_g;
    Alcotest.(check int) "denied_per_ip=0" 0 denied_ip;
    Relay_ws_server.release_slot s1;
    Alcotest.(check int) "active after release=1" 1
      (Relay_ws_server.active_connection_count ());
    let s3 = acquire_or_fail ~client_ip:"10.0.0.3" in
    Alcotest.(check int) "active refilled=2" 2
      (Relay_ws_server.active_connection_count ());
    Relay_ws_server.release_slot s2;
    Relay_ws_server.release_slot s3)

let test_cap_per_ip_limit () =
  with_cap_limits ~max_total:100 ~max_per_ip:2 (fun () ->
    let s1 = acquire_or_fail ~client_ip:"192.0.2.10" in
    let s2 = acquire_or_fail ~client_ip:"192.0.2.10" in
    Alcotest.(check int) "per-ip count=2" 2
      (Relay_ws_server.per_ip_connection_count ~client_ip:"192.0.2.10");
    (match Relay_ws_server.try_acquire_slot ~client_ip:"192.0.2.10" with
     | Relay_ws_server.Acquired _ -> Alcotest.fail "expected per-ip deny"
     | Relay_ws_server.Denied { reason; _ } ->
         Alcotest.(check bool) "Cap_per_ip"
           true (reason = Relay_ws_server.Cap_per_ip);
         Alcotest.(check string) "label" "per_ip"
           (Relay_ws_server.cap_denial_label reason));
    (* Other IPs still allowed under global headroom. *)
    let s_other = acquire_or_fail ~client_ip:"192.0.2.99" in
    Alcotest.(check int) "other ip count=1" 1
      (Relay_ws_server.per_ip_connection_count ~client_ip:"192.0.2.99");
    Relay_ws_server.release_slot s1;
    Alcotest.(check int) "per-ip after release=1" 1
      (Relay_ws_server.per_ip_connection_count ~client_ip:"192.0.2.10");
    let s3 = acquire_or_fail ~client_ip:"192.0.2.10" in
    Relay_ws_server.release_slot s2;
    Relay_ws_server.release_slot s3;
    Relay_ws_server.release_slot s_other;
    Alcotest.(check int) "active drained" 0
      (Relay_ws_server.active_connection_count ()))

let test_cap_release_idempotent () =
  with_cap_limits ~max_total:1 ~max_per_ip:1 (fun () ->
    let s = acquire_or_fail ~client_ip:"127.0.0.1" in
    Relay_ws_server.release_slot s;
    Relay_ws_server.release_slot s;
    Relay_ws_server.release_slot s;
    Alcotest.(check int) "active still 0 after double free" 0
      (Relay_ws_server.active_connection_count ());
    let s2 = acquire_or_fail ~client_ip:"127.0.0.1" in
    Relay_ws_server.release_slot s2)

let test_cap_stats_json () =
  with_cap_limits ~max_total:5 ~max_per_ip:3 ~retry_after_s:11.0 (fun () ->
    let s = acquire_or_fail ~client_ip:"203.0.113.1" in
    ignore (Relay_ws_server.try_acquire_slot ~client_ip:"203.0.113.1");
    ignore (Relay_ws_server.try_acquire_slot ~client_ip:"203.0.113.1");
    ignore (Relay_ws_server.try_acquire_slot ~client_ip:"203.0.113.1");
    (* max_per_ip=3: third acquire above fills to 3, fourth denies.
       We already have s, plus two more Acquired, then deny. *)
    let j = Relay_ws_server.connection_cap_stats_json () in
    match j with
    | `Assoc fields ->
        let get_int k =
          match List.assoc_opt k fields with
          | Some (`Int n) -> n
          | _ -> Alcotest.fail ("missing int " ^ k)
        in
        let get_float k =
          match List.assoc_opt k fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> float_of_int n
          | _ -> Alcotest.fail ("missing float " ^ k)
        in
        Alcotest.(check int) "subscribers" 3 (get_int "subscribers");
        Alcotest.(check int) "max_subscribers" 5 (get_int "max_subscribers");
        Alcotest.(check int) "max_per_ip" 3 (get_int "max_per_ip");
        Alcotest.(check (float 0.01)) "retry_after_s" 11.0
          (get_float "retry_after_s");
        Alcotest.(check bool) "denied_per_ip >= 1" true
          (get_int "denied_per_ip" >= 1);
        Relay_ws_server.release_slot s
    | _ -> Alcotest.fail "expected Assoc")

let test_session_cleanup_releases_slot () =
  let open Lwt.Infix in
  with_cap_limits ~max_total:2 ~max_per_ip:2 (fun () ->
    Lwt_main.run (
      let slot = acquire_or_fail ~client_ip:"198.51.100.1" in
      Alcotest.(check int) "held before session" 1
        (Relay_ws_server.active_connection_count ());
      let raw_ic, raw_oc = Lwt_io.pipe () in
      let _sink_ic, sink_oc = Lwt_io.pipe () in
      let cohttp_ic = Cohttp_lwt_unix.Private.Input_channel.create raw_ic in
      let session =
        Relay_ws_frame.Session.of_cohttp_channels cohttp_ic sink_oc
      in
      (* Close the write side so recv sees EOF and the session ends. *)
      let closer =
        Lwt_unix.sleep 0.05 >>= fun () ->
        Lwt_io.close raw_oc
      in
      let handler =
        Relay_ws_server.handle_subscriber_session
          ~aliases:["cleanup-alias@abcdef012345"]
          ~session
          ~lookup_pk:(fun ~alias:_ -> None)
          ~slot
          ()
      in
      Lwt.pick [handler; closer] >>= fun () ->
      (* Give finalize a tick if pick cancelled the handler path. *)
      Lwt_unix.sleep 0.05 >>= fun () ->
      (* Explicit release is idempotent if finalize already ran. *)
      Relay_ws_server.release_slot slot;
      Alcotest.(check int) "slot freed after session end" 0
        (Relay_ws_server.active_connection_count ());
      Lwt.return_unit))

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

let test_server_session_reads_cohttp_upgrade_channels () =
  let open Lwt.Infix in
  Lwt_main.run (
    let raw_ic, raw_oc = Lwt_io.pipe () in
    let _sink_ic, sink_oc = Lwt_io.pipe () in
    let cohttp_ic = Cohttp_lwt_unix.Private.Input_channel.create raw_ic in
    let session =
      Relay_ws_frame.Session.of_cohttp_channels cohttp_ic sink_oc
    in
    Relay_ws_frame.write_frame_masked ~opcode:Relay_ws_frame.opcode_text
      ~masking_key:"mask" ~payload:"native-tls-frame" raw_oc
    >>= fun () ->
    Lwt_io.flush raw_oc >>= fun () ->
    Relay_ws_frame.Session.recv session >>= fun msg ->
    Alcotest.(check bool) "reads frame through cohttp input buffer" true
      (msg = Some (`Text "native-tls-frame"));
    Lwt_io.close raw_oc)

let test_websocket_accept_rfc_example () =
  Alcotest.(check string) "RFC 6455 accept value"
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    (Relay_ws_frame.websocket_accept "dGhlIHNhbXBsZSBub25jZQ==")

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
    ; ( "connection_cap_b277",
        [ Alcotest.test_case "global cap + free on release" `Quick test_cap_global_limit
        ; Alcotest.test_case "per-ip cap independent IPs" `Quick test_cap_per_ip_limit
        ; Alcotest.test_case "release is idempotent" `Quick test_cap_release_idempotent
        ; Alcotest.test_case "stats json fields" `Quick test_cap_stats_json
        ; Alcotest.test_case "session cleanup frees slot" `Quick
            test_session_cleanup_releases_slot
        ] )
    ; ( "client_session",
        [ Alcotest.test_case "recv replies to ping with masked pong" `Quick
            test_client_session_recv_replies_to_ping_with_masked_pong
        ; Alcotest.test_case "server reads cohttp upgrade channels (B195)" `Quick
            test_server_session_reads_cohttp_upgrade_channels
        ; Alcotest.test_case "RFC websocket accept value" `Quick
            test_websocket_accept_rfc_example
        ] )
    ; ( "ws_client_endpoint",
        [ Alcotest.test_case "parse endpoint tls defaults (B189)" `Quick
            test_parse_endpoint_tls_defaults
        ] )
    ]
