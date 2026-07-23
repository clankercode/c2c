(* relay_ws_client.ml — client WebSocket connect for relay subscribe.
   Supports plaintext (ws/http) and TLS (wss/https) endpoints.

   Production relay (https://relay.c2c.im) terminates TLS at the edge
   (Railway/Cloudflare); the origin still speaks plain HTTP. Client-side
   wss is therefore sufficient for the public TLS path. Self-hosted
   `c2c relay serve --tls-cert` still terminates TLS in-process; the
   server's fd-dup upgrade path is plain-bytes after cohttp, so
   end-to-end native-TLS WS on that mode may need further work — the
   edge-TLS production case is the B189 target.

   Auth headers match the server contract in Relay_ws_server:
   X-C2C-Alias / X-C2C-Timestamp / X-C2C-Signature (Ed25519 over alias||ts).

   B272: connect + TLS + HTTP upgrade share one hard wall-clock timeout
   (default 10s). On timeout/cancel, registered channel close runs so
   ESTAB sockets do not accumulate under a hung edge (B270).

   B274: open_channels uses Lwt.finalize (not Lwt.catch alone) so
   Lwt.pick cancel mid-connect always closes the TCP FD.
*)

open Lwt.Infix

type endpoint = {
  host : string;
  port : int;
  use_tls : bool;
  path : string;
}

(** Default wall-clock budget for DNS + TCP connect + TLS + HTTP upgrade. *)
let default_connect_timeout_s = 10.0

let scheme_is_tls = function
  | Some "https" | Some "wss" -> true
  | _ -> false

let default_port ~use_tls = if use_tls then 443 else 7331

let parse_endpoint ?(path = "/ws/subscribe") url =
  let uri = Uri.of_string url in
  let use_tls = scheme_is_tls (Uri.scheme uri) in
  let host = Option.value (Uri.host uri) ~default:"localhost" in
  let port =
    match Uri.port uri with
    | Some p -> p
    | None -> default_port ~use_tls
  in
  { host; port; use_tls; path }

let host_header (ep : endpoint) =
  (* Omit default ports so SNI/vhost-style Host matches common edge configs. *)
  let default = default_port ~use_tls:ep.use_tls in
  if ep.port = default then ep.host
  else Printf.sprintf "%s:%d" ep.host ep.port

let authenticator_of_pem_file path =
  let pem =
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let n = in_channel_length ic in
        let buf = Bytes.create n in
        really_input ic buf 0 n;
        Bytes.to_string buf)
  in
  match X509.Certificate.decode_pem_multiple pem with
  | Error (`Msg m) ->
      Error (`Msg (Printf.sprintf "C2C_RELAY_CA_BUNDLE parse error (%s): %s" path m))
  | Ok certs ->
      Ok
        (X509.Authenticator.chain_of_trust
           ~time:(fun () -> Some (Ptime_clock.now ()))
           certs)

let resolve_authenticator ?ca_bundle () =
  let from_env =
    match ca_bundle with
    | Some p when p <> "" -> Some p
    | _ ->
        match Sys.getenv_opt "C2C_RELAY_CA_BUNDLE" with
        | Some p when p <> "" -> Some p
        | _ -> None
  in
  match from_env with
  | Some path -> authenticator_of_pem_file path
  | None ->
      (match Ca_certs.authenticator () with
       | Ok a -> Ok a
       | Error (`Msg m) -> Error (`Msg ("system CA authenticator: " ^ m)))

let peer_name_of_host host =
  match Domain_name.of_string host with
  | Error _ -> None
  | Ok dn ->
      (match Domain_name.host dn with
       | Ok h -> Some h
       | Error _ -> None)

let resolve_inet host port =
  Lwt_unix.getaddrinfo host (string_of_int port)
    [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  >>= function
  | [] ->
      Lwt.fail_with (Printf.sprintf "DNS lookup failed for %s" host)
  | addr :: _ -> Lwt.return addr.Unix.ai_addr

(** Idempotent close for a raw connected (or connecting) socket. *)
let make_socket_close sock =
  let closed = ref false in
  fun () ->
    if !closed then Lwt.return_unit
    else begin
      closed := true;
      Lwt.catch (fun () -> Lwt_unix.close sock) (fun _ -> Lwt.return_unit)
    end

(* B274: Lwt.catch does NOT run on cancellation; Lwt.finalize does.
   Own the socket until [transferred]; cancel mid-connect always closes. *)
let open_channels (ep : endpoint) ?ca_bundle ?(on_close = fun _ -> ()) () =
  resolve_inet ep.host ep.port >>= fun ai_addr ->
  let sock =
    Lwt_unix.socket (Unix.domain_of_sockaddr ai_addr) Unix.SOCK_STREAM 0
  in
  let close_sock = make_socket_close sock in
  on_close close_sock;
  let transferred = ref false in
  Lwt.finalize
    (fun () ->
       Lwt_unix.connect sock ai_addr >>= fun () ->
       if not ep.use_tls then begin
         let ic = Lwt_io.of_fd ~mode:Lwt_io.Input sock in
         let oc = Lwt_io.of_fd ~mode:Lwt_io.Output sock in
         transferred := true;
         Lwt.return (ic, oc, close_sock)
       end else begin
         Mirage_crypto_rng_unix.use_default ();
         match resolve_authenticator ?ca_bundle () with
         | Error (`Msg m) -> Lwt.fail_with m
         | Ok authenticator ->
             let peer_name = peer_name_of_host ep.host in
             (match Tls.Config.client ~authenticator ?peer_name () with
              | Error (`Msg m) -> Lwt.fail_with ("TLS client config: " ^ m)
              | Ok cfg ->
                  (* Own FD (not Tls_lwt.connect_ext) so cancel can close mid-TLS. *)
                  Tls_lwt.Unix.client_of_fd cfg ?host:peer_name sock
                  >>= fun tls ->
                  let close () =
                    Lwt.catch
                      (fun () -> Tls_lwt.Unix.close tls)
                      (fun _ -> close_sock ())
                  in
                  on_close close;
                  let ic, oc = Tls_lwt.of_t ~close tls in
                  transferred := true;
                  Lwt.return (ic, oc, close))
       end)
    (fun () ->
       if !transferred then Lwt.return_unit else close_sock ())

let auth_headers ~alias ~identity =
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let msg = alias ^ ts in
  let sig_ = Relay_identity.sign identity msg in
  let sig_b64 =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
  in
  (ts, sig_b64)

let make_upgrade_request ~ep ~alias ~ts ~sig_b64 ~ws_key =
  Printf.sprintf
    "GET %s HTTP/1.1\r\n\
     Host: %s\r\n\
     Upgrade: websocket\r\n\
     Connection: Upgrade\r\n\
     Sec-WebSocket-Key: %s\r\n\
     Sec-WebSocket-Version: 13\r\n\
     X-C2C-Alias: %s\r\n\
     X-C2C-Timestamp: %s\r\n\
     X-C2C-Signature: %s\r\n\
     \r\n"
    ep.path (host_header ep) ws_key alias ts sig_b64

let skip_headers ic =
  let rec loop () =
    Lwt_io.read_line ic >>= fun line ->
    if line = "" then Lwt.return_unit else loop ()
  in
  loop ()

let timeout_error ~timeout ~(endpoint : endpoint) =
  Failure
    (Printf.sprintf
       "WebSocket subscribe connect/handshake timed out after %.1fs (%s:%d%s)"
       timeout endpoint.host endpoint.port
       (if endpoint.use_tls then ", tls" else ""))

let connect_subscribe ~(endpoint : endpoint) ~alias ~identity ?ca_bundle
    ?(timeout = default_connect_timeout_s) () =
  let timeout = if timeout <= 0. then default_connect_timeout_s else timeout in
  let close_ref = ref (fun () -> Lwt.return_unit) in
  let set_close c = close_ref := c in
  (* When true, ownership of [close] transferred to the caller — do not
     close in finalize. *)
  let transferred = ref false in
  Lwt.catch
    (fun () ->
       Lwt_unix.with_timeout timeout (fun () ->
         Lwt.finalize
           (fun () ->
              open_channels endpoint ?ca_bundle ~on_close:set_close ()
              >>= fun (ic, oc, close) ->
              set_close close;
              let ts, sig_b64 = auth_headers ~alias ~identity in
              let ws_key =
                Base64.encode_string
                  (String.init 16 (fun _ -> Char.chr (Random.int 256)))
              in
              let request =
                make_upgrade_request ~ep:endpoint ~alias ~ts ~sig_b64 ~ws_key
              in
              Lwt_io.write oc request >>= fun () ->
              Lwt_io.flush oc >>= fun () ->
              Lwt_io.read_line ic >>= fun status_line ->
              let ok =
                String.length status_line >= 12
                && String.sub status_line 0 12 = "HTTP/1.1 101"
              in
              if not ok then
                (* Drain a bit of body for diagnostics, then fail. *)
                Lwt.catch
                  (fun () ->
                     skip_headers ic >>= fun () ->
                     Lwt_io.read ~count:512 ic >>= fun body ->
                     Lwt.fail_with
                       (Printf.sprintf "WebSocket upgrade failed: %s%s"
                          status_line
                          (if body = "" then "" else "\n" ^ body)))
                  (fun _ ->
                     Lwt.fail_with
                       (Printf.sprintf "WebSocket upgrade failed: %s" status_line))
              else
                skip_headers ic >>= fun () ->
                let masking_key =
                  String.init 4 (fun _ -> Char.chr (Random.int 256))
                in
                let session =
                  Relay_ws_frame.Client_session.create ic oc masking_key
                in
                transferred := true;
                Lwt.return (session, close))
           (fun () ->
              if !transferred then Lwt.return_unit
              else
                Lwt.catch (fun () -> !close_ref ()) (fun _ -> Lwt.return_unit))))
    (function
      | Lwt_unix.Timeout -> Lwt.fail (timeout_error ~timeout ~endpoint)
      | e -> Lwt.fail e)

let connect_subscribe_url ~url ~alias ~identity ?ca_bundle ?timeout () =
  let endpoint = parse_endpoint url in
  connect_subscribe ~endpoint ~alias ~identity ?ca_bundle ?timeout ()
