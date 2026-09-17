(* B338: dev-mode (unsigned) heartbeat missing-lease must return
   404 + lease_not_found, not 200 + unknown_alias.

   The B293 split (reject_session_lease_missing) was implemented only on the
   signed arm of handle_heartbeat (the alias_of_session pre-check). The
   unsigned arm ran the backend heartbeat and echoed whatever came back, so
   against a token-less (dev) relay the backend's unknown_alias surfaced as
   HTTP 200 + error_code unknown_alias — and the client re-register repair
   that keys on lease_not_found (the connectors) never triggered.

   Pins here, against a real loopback sqlite Relay_server (dev mode, no
   token, no auth header):
   - unsigned heartbeat for an unknown (node_id, session_id) → 404 +
     lease_not_found (the B338 fix);
   - signed heartbeat for an unknown pair stays 404 + lease_not_found
     (B293 behaviour must not regress);
   - unsigned heartbeat for a LIVE pair stays 200 ok (the mapping must not
     swallow real heartbeats). *)

open Alcotest
open Lwt.Infix

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b338" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

module RS = Relay.Relay_server (Relay.SqliteRelay)

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let with_sqlite_server f =
  with_temp_dir (fun dir ->
    Lwt_main.run
      (loopback_socket () >>= fun (fd, port) ->
       let relay = Relay.SqliteRelay.create ~persist_dir:dir () in
       let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
       let stop, wake_stop = Lwt.wait () in
       let callback (conn, _) req body =
         RS.make_callback relay None conn req body ?broker_root:None
           ~native_tls:false ~rate_limiter
       in
       let spec = Cohttp_lwt_unix.Server.make ~callback () in
       let server =
         Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd)) spec
       in
       Lwt.pause () >>= fun () ->
       let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
       Lwt.finalize
         (fun () -> f ~base_url ~relay)
         (fun () ->
            Lwt.wakeup_later wake_stop ();
            server)))

let json_field key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some v -> v
       | None -> `Null)
  | _ -> `Null

let error_code json =
  match json_field "error_code" json with `String c -> c | _ -> ""

let http_status json =
  match json_field "http_status" json with `Int n -> n | _ -> 0

let ok_field json = json_field "ok" json

let test_unsigned_heartbeat_unknown_pair_is_404_lease_not_found () =
  with_sqlite_server (fun ~base_url ~relay:_ ->
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    Relay.Relay_client.heartbeat client
      ~node_id:"b338n-ghost" ~session_id:"b338s-ghost"
    >>= fun hb ->
    check string "unsigned missing lease reports lease_not_found"
      "lease_not_found" (error_code hb);
    check int "unsigned missing lease is 404 (re-register-worthy)" 404
      (http_status hb);
    Lwt.return_unit)

let test_signed_heartbeat_unknown_pair_stays_lease_not_found () =
  with_sqlite_server (fun ~base_url ~relay:_ ->
    let id_path =
      Filename.concat (Filename.get_temp_dir_name ()) "b338-signer-id.json"
    in
    let id = Relay_identity.load_or_create_at ~path:id_path ~alias_hint:"b338-owner" in
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    let proof = Relay_signed_ops.sign_register id ~alias:"b338-owner" ~relay_url:base_url in
    Relay.Relay_client.register_signed client
      ~node_id:"b338n-known" ~session_id:"b338s-known" ~alias:"b338-owner"
      ~client_type:"cli"
      ~identity_pk_b64:proof.Relay_signed_ops.identity_pk_b64
      ~sig_b64:proof.Relay_signed_ops.sig_b64
      ~nonce:proof.Relay_signed_ops.nonce ~ts:proof.Relay_signed_ops.ts ()
    >>= fun reg ->
    check bool "setup register ok" true (ok_field reg = `Bool true);
    let ohid = try Host_id.compute_host_hash () with _ -> "" in
    let fields =
      [ ("node_id", `String "b338n-ghost2"); ("session_id", `String "b338s-ghost2") ]
      @ (if ohid = "" then [] else [ ("opaque_host_id", `String ohid) ])
    in
    let body_str = Yojson.Safe.to_string (`Assoc fields) in
    let auth =
      Relay_signed_ops.sign_request id ~alias:"b338-owner" ~meth:"POST"
        ~path:"/heartbeat" ~body_str ()
    in
    Relay.Relay_client.heartbeat_signed client
      ~node_id:"b338n-ghost2" ~session_id:"b338s-ghost2" ~auth_header:auth
    >>= fun hb ->
    check string "signed missing lease still lease_not_found (B293)"
      "lease_not_found" (error_code hb);
    check int "signed missing lease still 404 (B293)" 404 (http_status hb);
    Lwt.return_unit)

let test_unsigned_heartbeat_live_pair_stays_ok () =
  with_sqlite_server (fun ~base_url ~relay:_ ->
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    Relay.Relay_client.register client
      ~node_id:"b338n-live" ~session_id:"b338s-live" ~alias:"b338-live"
      ~client_type:"cli" ()
    >>= fun reg ->
    check bool "live register ok (unsigned dev relay)" true
      (ok_field reg = `Bool true);
    Relay.Relay_client.heartbeat client
      ~node_id:"b338n-live" ~session_id:"b338s-live"
    >>= fun hb ->
    check bool "live pair heartbeat stays ok" true (ok_field hb = `Bool true);
    Lwt.return_unit)

let () =
  run "B338 dev-mode heartbeat missing lease is 404 lease_not_found"
    [ ( "unsigned_heartbeat",
        [ Alcotest.test_case "unknown pair is 404 lease_not_found" `Quick
            test_unsigned_heartbeat_unknown_pair_is_404_lease_not_found
        ; Alcotest.test_case "signed unknown pair stays 404 (B293 pin)" `Quick
            test_signed_heartbeat_unknown_pair_stays_lease_not_found
        ; Alcotest.test_case "live pair stays 200 ok" `Quick
            test_unsigned_heartbeat_live_pair_stays_ok
        ] )
    ]
