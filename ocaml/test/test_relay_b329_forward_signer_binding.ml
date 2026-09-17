(* B329: cross-relay forward-out never bound body from_alias to the verified
   Ed25519 signer — the mismatch check lived only in the local-delivery arm
   of handle_send, and the forward-out branch responded before reaching it.

   Attack pinned here: an authenticated peer verified as alice on relay A
   POSTs /send with body from_alias "b329-bob" and to_alias
   "b329-victim@b329-host-b". Relay A signs the forward with ITS relay
   identity (relay-to-relay trust) and the peer delivers it as
   b329-bob@b329-host-a — sender spoofing across relays.

   Fix under test: the alias-mismatch rejection is hoisted above the
   host-routing branch, so forwarded sends are bound to the signer too.
   A matching from_alias still forwards normally (positive control). *)

open Alcotest
module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b329" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let with_two_servers f =
  with_temp_dir (fun dir ->
    let dir_a = Filename.concat dir "a" and dir_b = Filename.concat dir "b" in
    Unix.mkdir dir_a 0o700;
    Unix.mkdir dir_b 0o700;
    Lwt_main.run
      (loopback_socket () >>= fun (fd_a, port_a) ->
       loopback_socket () >>= fun (fd_b, port_b) ->
       let relay_a =
         Relay.SqliteRelay.create ~persist_dir:dir_a
           ~self_host:(Some "b329-host-a") ()
       in
       let relay_b =
         Relay.SqliteRelay.create ~persist_dir:dir_b
           ~self_host:(Some "b329-host-b") ()
       in
       let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
       let cb r (conn, _) req body =
         RS.make_callback r None conn req body ?broker_root:None
           ~native_tls:false ~rate_limiter
       in
       let stop, wake_stop = Lwt.wait () in
       let spec_a = Cohttp_lwt_unix.Server.make ~callback:(cb relay_a) () in
       let spec_b = Cohttp_lwt_unix.Server.make ~callback:(cb relay_b) () in
       let sa = Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd_a)) spec_a in
       let sb = Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd_b)) spec_b in
       Lwt.pause () >>= fun () ->
       let base_a = Printf.sprintf "http://127.0.0.1:%d" port_a in
       let base_b = Printf.sprintf "http://127.0.0.1:%d" port_b in
       Lwt.finalize
         (fun () -> f ~base_a ~base_b ~relay_a ~relay_b ~dir)
         (fun () ->
            Lwt.wakeup_later wake_stop ();
            sa >>= fun () -> sb)))

(* Register [alias] on relay A with a fresh signed identity so the outer
   Ed25519 request verifier binds the Authorization alias to the key. *)
let register_signed_on_a ~base_a ~dir ~alias ~node_id ~session_id =
  let id =
    Relay_identity.load_or_create_at
      ~path:(Filename.concat dir (alias ^ "-id.json"))
      ~alias_hint:alias
  in
  let p = Relay_signed_ops.sign_register id ~alias ~relay_url:base_a in
  let client = Relay.Relay_client.make ~timeout:5.0 base_a in
  Relay.Relay_client.register_signed client ~node_id ~session_id ~alias
    ~client_type:"cli" ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
    ~sig_b64:p.Relay_signed_ops.sig_b64 ~nonce:p.Relay_signed_ops.nonce
    ~ts:p.Relay_signed_ops.ts ()
  >>= fun reg ->
  match reg with
  | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) ->
    Lwt.return id
  | other ->
    Printf.ksprintf Lwt.fail_with "register %s failed: %s" alias
      (Yojson.Safe.to_string other)

let json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String s) -> s
     | Some (`Bool b) -> string_of_bool b
     | Some (`Int i) -> string_of_int i
     | _ -> "")
  | _ -> ""

let post_send_signed ~base ~id ~alias ~body_json =
  let body_str = Yojson.Safe.to_string body_json in
  let auth =
    Relay_signed_ops.sign_request id ~alias ~meth:"POST" ~path:"/send"
      ~body_str ()
  in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "application/json"); ("Authorization", auth) ]
  in
  Cohttp_lwt_unix.Client.call `POST (Uri.of_string (base ^ "/send"))
    ~headers ~body:(Cohttp_lwt.Body.of_string body_str)
  >>= fun (resp, b) ->
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Cohttp_lwt.Body.to_string b >>= fun s ->
  match Yojson.Safe.from_string s with
  | json -> Lwt.return (status, json)
  | exception Yojson.Json_error m -> Lwt.fail_with ("invalid json: " ^ m)

let victim_inbox relay_b =
  Relay.SqliteRelay.peek_inbox relay_b ~node_id:"n-b329-victim"
    ~session_id:"s-b329-victim"

let setup ~base_a ~base_b ~relay_a ~relay_b ~dir =
  (* Victim lives on relay B, publicly reachable (B264). *)
  let st, _ =
    Relay.SqliteRelay.register relay_b ~node_id:"n-b329-victim"
      ~session_id:"s-b329-victim" ~alias:"b329-victim" ()
  in
  check string "victim registered on B" "ok" st;
  (match
     Relay.SqliteRelay.set_peer_discovery_visibility relay_b
       ~alias:"b329-victim" ~visibility:Relay_backend_contract.Public
   with
   | Ok () -> ()
   | Error e -> failf "mark victim public: %s" e);
  (* A knows B as a peer relay (host name -> B's url + identity key). *)
  Relay.SqliteRelay.add_peer_relay relay_a
    { name = "b329-host-b"; url = base_b;
      identity_pk =
        (Relay.SqliteRelay.relay_identity relay_b).Relay_identity.public_key };
  (* B trusts relay A's identity for inbound /forward. *)
  Relay.SqliteRelay.add_peer_relay relay_b
    { name = "b329-host-a"; url = base_a;
      identity_pk =
        (Relay.SqliteRelay.relay_identity relay_a).Relay_identity.public_key };
  register_signed_on_a ~base_a ~dir ~alias:"b329-alice"
    ~node_id:"n-b329-alice" ~session_id:"s-b329-alice"

let test_forward_out_rejects_signer_spoof () =
  with_two_servers (fun ~base_a ~base_b ~relay_a ~relay_b ~dir ->
    ignore base_b;
    setup ~base_a ~base_b ~relay_a ~relay_b ~dir >>= fun alice_id ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "b329-bob")
        ; ("to_alias", `String "b329-victim@b329-host-b")
        ; ("content", `String "spoofed hello") ]
    in
    post_send_signed ~base:base_a ~id:alice_id ~alias:"b329-alice" ~body_json
    >>= fun (status, json) ->
    if json_field "ok" json = "true" then
      print_endline ("spoofed forward accepted: " ^ Yojson.Safe.to_string json);
    check string "spoofed send is not ok" "false" (json_field "ok" json);
    check string "rejected as signature_invalid" "signature_invalid"
      (json_field "error_code" json);
    check int "http 403 forbidden" 403 status;
    check int "victim inbox on B stays empty" 0
      (List.length (victim_inbox relay_b));
    Lwt.return_unit)

let test_forward_out_with_matching_alias_still_delivers () =
  with_two_servers (fun ~base_a ~base_b ~relay_a ~relay_b ~dir ->
    ignore relay_a;
    setup ~base_a ~base_b ~relay_a ~relay_b ~dir >>= fun alice_id ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "b329-alice")
        ; ("to_alias", `String "b329-victim@b329-host-b")
        ; ("content", `String "legit cross-relay hello") ]
    in
    post_send_signed ~base:base_a ~id:alice_id ~alias:"b329-alice" ~body_json
    >>= fun (_status, json) ->
    if json_field "ok" json <> "true" then
      print_endline ("legit forward response: " ^ Yojson.Safe.to_string json);
    check string "matching-signer forward ok" "true" (json_field "ok" json);
    let inbox = victim_inbox relay_b in
    check int "victim received the forwarded message" 1 (List.length inbox);
    (match inbox with
     | msg :: _ ->
       check string "delivered under the signer-bound sender" "b329-alice@b329-host-a"
         (json_field "from_alias" msg)
     | [] -> ());
    Lwt.return_unit)


(* The relay-address form <name>@<opaque host id> is a legitimate
   from_alias: the binding strips the opaque host tag before comparing, so
   address-shaped senders still forward (the tag rides along in the
   delivered name). *)
let test_forward_out_with_opaque_host_tagged_sender () =
  with_two_servers (fun ~base_a ~base_b ~relay_a ~relay_b ~dir ->
    setup ~base_a ~base_b ~relay_a ~relay_b ~dir >>= fun alice_id ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "b329-alice@3d08761ae3f3")
        ; ("to_alias", `String "b329-victim@b329-host-b")
        ; ("content", `String "address-shaped cross-relay hello") ]
    in
    post_send_signed ~base:base_a ~id:alice_id ~alias:"b329-alice" ~body_json
    >>= fun (_status, json) ->
    if json_field "ok" json <> "true" then
      print_endline ("addressed forward response: " ^ Yojson.Safe.to_string json);
    check string "opaque-host-tagged from_alias forwards" "true"
      (json_field "ok" json);
    let inbox = victim_inbox relay_b in
    check int "victim received the addressed message" 1 (List.length inbox);
    (match inbox with
     | msg :: _ ->
       check string "delivered with the address-shaped sender"
         "b329-alice@3d08761ae3f3@b329-host-a"
         (json_field "from_alias" msg)
     | [] -> ());
    Lwt.return_unit)

let () =
  run "B329 forward-out binds from_alias to the verified signer"
    [ ("spoofed cross-relay send",
       [ test_case "rejected before forwarding" `Quick
           test_forward_out_rejects_signer_spoof ])
    ; ("matching cross-relay send",
       [ test_case "still delivers" `Quick
           test_forward_out_with_matching_alias_still_delivers ])
    ; ("opaque-host-tagged sender",
       [ test_case "address-shaped from_alias still forwards" `Quick
           test_forward_out_with_opaque_host_tagged_sender ])
    ]
