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
*)

open Lwt.Infix

type endpoint = {
  host : string;
  port : int;
  use_tls : bool;
  path : string;
}

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

let open_channels (ep : endpoint) ?ca_bundle () =
  if not ep.use_tls then
    Lwt_unix.getaddrinfo ep.host (string_of_int ep.port)
      [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
    >>= function
    | [] ->
        Lwt.fail_with (Printf.sprintf "DNS lookup failed for %s" ep.host)
    | addr :: _ ->
        let sock = Lwt_unix.socket
            (Unix.domain_of_sockaddr addr.Unix.ai_addr)
            Unix.SOCK_STREAM 0
        in
        Lwt.catch
          (fun () ->
             Lwt_unix.connect sock addr.Unix.ai_addr >>= fun () ->
             let ic = Lwt_io.of_fd ~mode:Lwt_io.Input sock in
             let oc = Lwt_io.of_fd ~mode:Lwt_io.Output sock in
             let close () =
               Lwt.catch (fun () -> Lwt_unix.close sock) (fun _ -> Lwt.return_unit)
             in
             Lwt.return (ic, oc, close))
          (fun e ->
             Lwt.catch (fun () -> Lwt_unix.close sock) (fun _ -> Lwt.return_unit)
             >>= fun () -> Lwt.fail e)
  else begin
    Mirage_crypto_rng_unix.use_default ();
    match resolve_authenticator ?ca_bundle () with
    | Error (`Msg m) -> Lwt.fail_with m
    | Ok authenticator ->
        let peer_name = peer_name_of_host ep.host in
        (match Tls.Config.client ~authenticator ?peer_name () with
         | Error (`Msg m) -> Lwt.fail_with ("TLS client config: " ^ m)
         | Ok cfg ->
             Tls_lwt.connect_ext cfg (ep.host, ep.port) >>= fun (ic, oc) ->
             let close () =
               Lwt.catch
                 (fun () -> Lwt_io.close ic >>= fun () -> Lwt_io.close oc)
                 (fun _ -> Lwt.return_unit)
             in
             Lwt.return (ic, oc, close))
  end

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

let connect_subscribe ~(endpoint : endpoint) ~alias ~identity ?ca_bundle () =
  open_channels endpoint ?ca_bundle () >>= fun (ic, oc, close) ->
  let handshake_ok = ref false in
  Lwt.catch
    (fun () ->
       let ts, sig_b64 = auth_headers ~alias ~identity in
       let ws_key =
         Base64.encode_string (String.init 16 (fun _ -> Char.chr (Random.int 256)))
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
         handshake_ok := true;
         let masking_key =
           String.init 4 (fun _ -> Char.chr (Random.int 256))
         in
         let session =
           Relay_ws_frame.Client_session.create ic oc masking_key
         in
         Lwt.return (session, close))
    (fun e ->
       (if not !handshake_ok then close () else Lwt.return_unit) >>= fun () ->
       Lwt.fail e)

let connect_subscribe_url ~url ~alias ~identity ?ca_bundle () =
  let endpoint = parse_endpoint url in
  connect_subscribe ~endpoint ~alias ~identity ?ca_bundle ()
