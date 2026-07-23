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

(* ---- B272: hard timeout on connect + HTTP upgrade handshake -------------- *)

let count_fds () =
  let dir = "/proc/self/fd" in
  if not (Sys.file_exists dir) then None
  else
    let d = Unix.opendir dir in
    let rec loop n =
      match Unix.readdir d with
      | exception End_of_file ->
          Unix.closedir d;
          Some n
      | _ -> loop (n + 1)
    in
    loop 0

(** Accept TCP connections and never speak — simulates a hung Railway/CF edge
    that leaves ESTAB sockets parked in [Lwt_io.read_line]. *)
let with_hung_peer (f : int -> unit Lwt.t) : unit Lwt.t =
  let open Lwt.Infix in
  let listen_fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt listen_fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind listen_fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
  >>= fun () ->
  Lwt_unix.listen listen_fd 16;
  let port =
    match Lwt_unix.getsockname listen_fd with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "hung peer: expected IPv4 bound port"
  in
  let clients : Lwt_unix.file_descr list ref = ref [] in
  let rec accept_loop () =
    Lwt.catch
      (fun () ->
         Lwt_unix.accept listen_fd >>= fun (c, _) ->
         clients := c :: !clients;
         (* Park without reading or writing. *)
         accept_loop ())
      (function
        | Unix.Unix_error ((Unix.EBADF | Unix.EINVAL), _, _) -> Lwt.return_unit
        | Lwt.Canceled -> Lwt.return_unit
        | _ -> Lwt.return_unit)
  in
  let acceptor = accept_loop () in
  Lwt.finalize
    (fun () -> f port)
    (fun () ->
       Lwt.cancel acceptor;
       Lwt_list.iter_p
         (fun c ->
            Lwt.catch (fun () -> Lwt_unix.close c) (fun _ -> Lwt.return_unit))
         !clients
       >>= fun () ->
       Lwt.catch (fun () -> Lwt_unix.close listen_fd) (fun _ -> Lwt.return_unit))

let hung_endpoint port : Relay_ws_client.endpoint =
  { Relay_ws_client.host = "127.0.0.1"
  ; port
  ; use_tls = false
  ; path = "/ws/subscribe"
  }

let test_connect_subscribe_times_out_on_hung_peer () =
  let open Lwt.Infix in
  Lwt_main.run
    (with_hung_peer (fun port ->
       let id = Relay_identity.generate ~alias_hint:"b272" () in
       let endpoint = hung_endpoint port in
       let t0 = Unix.gettimeofday () in
       Lwt.catch
         (fun () ->
            Relay_ws_client.connect_subscribe
              ~endpoint ~alias:"b272@deadbeefcaf0" ~identity:id ~timeout:0.25 ()
            >>= fun _ ->
            Alcotest.fail "expected connect/handshake timeout on hung peer")
         (function
           | Failure msg ->
               let elapsed = Unix.gettimeofday () -. t0 in
               Alcotest.(check bool) "error mentions timed out" true
                 (String.is_substring ~substring:"timed out" msg);
               Alcotest.(check bool) "error mentions WebSocket subscribe" true
                 (String.is_substring ~substring:"WebSocket subscribe" msg);
               Alcotest.(check bool) "returns near the timeout budget" true
                 (elapsed < 2.0 && elapsed >= 0.15);
               Lwt.return_unit
           | e ->
               Alcotest.fail
                 (Printf.sprintf "expected Failure timeout, got: %s"
                    (Printexc.to_string e)))))

let test_connect_subscribe_timeout_does_not_grow_fds () =
  let open Lwt.Infix in
  Lwt_main.run
    (with_hung_peer (fun port ->
       match count_fds () with
       | None ->
           (* Non-Linux / no /proc — skip the FD-growth assertion. *)
           Lwt.return_unit
       | Some baseline ->
           let id = Relay_identity.generate ~alias_hint:"b272fd" () in
           let endpoint = hung_endpoint port in
           let rec storm n =
             if n <= 0 then Lwt.return_unit
             else
               Lwt.catch
                 (fun () ->
                    Relay_ws_client.connect_subscribe
                      ~endpoint ~alias:"b272fd@deadbeefcaf1" ~identity:id
                      ~timeout:0.15 ()
                    >>= fun _ -> Lwt.return_unit)
                 (function Failure _ -> Lwt.return_unit | e -> Lwt.fail e)
               >>= fun () -> storm (n - 1)
           in
           storm 8 >>= fun () ->
           (* Give cancelled closes a tick to settle. *)
           Lwt.pause () >>= fun () ->
           Lwt.pause () >>= fun () ->
           (match count_fds () with
            | None -> Lwt.return_unit
            | Some after ->
                (* Acceptor may hold a handful of accepted FDs; client must not
                   leave one ESTAB per attempt. Allow small slack for noise. *)
                let growth = after - baseline in
                Alcotest.(check bool)
                  (Printf.sprintf
                     "FD growth bounded (baseline=%d after=%d growth=%d)"
                     baseline after growth)
                  true (growth <= 12);
                Lwt.return_unit)))

let test_connect_subscribe_succeeds_within_timeout () =
  let open Lwt.Infix in
  Lwt_main.run
    (let listen_fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
     Lwt_unix.setsockopt listen_fd Unix.SO_REUSEADDR true;
     Lwt_unix.bind listen_fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0))
     >>= fun () ->
     Lwt_unix.listen listen_fd 1;
     let port =
       match Lwt_unix.getsockname listen_fd with
       | Unix.ADDR_INET (_, p) -> p
       | _ -> failwith "expected IPv4"
     in
     let serve =
       Lwt_unix.accept listen_fd >>= fun (c, _) ->
       let ic = Lwt_io.of_fd ~mode:Lwt_io.Input c in
       let oc = Lwt_io.of_fd ~mode:Lwt_io.Output c in
       (* Drain request headers. *)
       let rec drain () =
         Lwt_io.read_line ic >>= fun line ->
         if line = "" then Lwt.return_unit else drain ()
       in
       drain () >>= fun () ->
       Lwt_io.write oc
         "HTTP/1.1 101 Switching Protocols\r\n\
          Upgrade: websocket\r\n\
          Connection: Upgrade\r\n\
          Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\
          \r\n"
       >>= fun () ->
       Lwt_io.flush oc >>= fun () ->
       (* Keep the socket open until the client owns the session. *)
       Lwt_unix.sleep 0.5 >>= fun () ->
       Lwt.catch (fun () -> Lwt_unix.close c) (fun _ -> Lwt.return_unit)
     in
     let id = Relay_identity.generate ~alias_hint:"b272ok" () in
     let endpoint = hung_endpoint port in
     Lwt.finalize
       (fun () ->
          serve
          <&>
          (Relay_ws_client.connect_subscribe
             ~endpoint ~alias:"b272ok@deadbeefcaf2" ~identity:id ~timeout:2.0 ()
           >>= fun (_session, close) ->
           close ()))
       (fun () ->
          Lwt.catch (fun () -> Lwt_unix.close listen_fd) (fun _ -> Lwt.return_unit)))

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
        ; Alcotest.test_case "server reads cohttp upgrade channels (B195)" `Quick
            test_server_session_reads_cohttp_upgrade_channels
        ; Alcotest.test_case "RFC websocket accept value" `Quick
            test_websocket_accept_rfc_example
        ] )
    ; ( "ws_client_endpoint",
        [ Alcotest.test_case "parse endpoint tls defaults (B189)" `Quick
            test_parse_endpoint_tls_defaults
        ] )
    ; ( "ws_client_connect_timeout",
        [ Alcotest.test_case "hung peer times out (B272)" `Quick
            test_connect_subscribe_times_out_on_hung_peer
        ; Alcotest.test_case "timeout storm does not grow FDs (B272)" `Quick
            test_connect_subscribe_timeout_does_not_grow_fds
        ; Alcotest.test_case "successful upgrade within timeout (B272)" `Quick
            test_connect_subscribe_succeeds_within_timeout
        ] )
    ]

