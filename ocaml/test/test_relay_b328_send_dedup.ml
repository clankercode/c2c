(* B328: sqlite relay send has no message-id dedup — seen_ids was dead schema.

   InMemoryRelay.send records every accepted message id in a FIFO-bounded
   seen_ids set and returns `Duplicate on replay. SqliteRelay.send (the
   production default via `c2c relay serve --storage sqlite`) unconditionally
   INSERTed into inboxes and never touched the seen_ids table its own schema
   creates, so client retries (connector outbox attempts) and cross-relay
   forward retries double-delivered on prod, and handle_forward's Duplicate
   arm could never fire against a sqlite peer.

   Pinned here, both backends agreeing:
   - replay of a live message id -> `Duplicate, exactly one inbox row;
   - dedup survives an inbox drain (it is not "still in the inbox");
   - the window prunes FIFO: a pruned id may be accepted again;
   - end-to-end: a replayed /forward against a real loopback sqlite relay
     answers ok:true + duplicate:true and delivers exactly one copy. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b328" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let reg_sql_public t ~node_id ~session_id ~alias =
  let status, _lease =
    Relay.SqliteRelay.register t ~node_id ~session_id ~alias ()
  in
  check string "register ok" "ok" status;
  match
    Relay.SqliteRelay.set_peer_discovery_visibility t ~alias
      ~visibility:Relay_backend_contract.Public
  with
  | Ok () -> ()
  | Error e -> failf "mark public %s: %s" alias e

let reg_mem_public t ~node_id ~session_id ~alias =
  let status, _lease =
    Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ()
  in
  check string "register ok" "ok" status;
  match
    Relay.InMemoryRelay.set_peer_discovery_visibility t ~alias
      ~visibility:Relay_backend_contract.Public
  with
  | Ok () -> ()
  | Error e -> failf "mark public %s: %s" alias e

(* Both backends take the same labeled shape; call sites spell the optional
   labels out so inference cannot erase them. *)
let sql_send t ~from_alias ~to_alias ~content ~message_id =
  Relay.SqliteRelay.send t ~from_alias ~to_alias ~content
    ~message_id:(Some message_id) ~pow_difficulty:(-1)

let mem_send t ~from_alias ~to_alias ~content ~message_id =
  Relay.InMemoryRelay.send t ~from_alias ~to_alias ~content
    ~message_id:(Some message_id) ~pow_difficulty:(-1)

(* --- backend level: replay -> Duplicate, one delivered copy -------------- *)

let test_sqlite_send_replay_is_duplicate () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql_public t ~node_id:"n-b328-a" ~session_id:"s-b328-a" ~alias:"b328-a";
    reg_sql_public t ~node_id:"n-b328-b" ~session_id:"s-b328-b" ~alias:"b328-b";
    let mid = "b328-msg-fixed-1" in
    (match
       sql_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
     with
     | `Ok _ -> ()
     | _ -> fail "first send should be Ok");
    (match
       sql_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
     with
     | `Duplicate _ -> ()
     | `Ok _ ->
       fail "replayed send returned Ok (pre-fix double-deliver: the ticket)"
     | `Error (c, m) -> failf "replayed send errored: %s %s" c m);
    let inbox =
      Relay.SqliteRelay.poll_inbox t ~node_id:"n-b328-b"
        ~session_id:"s-b328-b"
    in
    check int "exactly one delivered copy" 1 (List.length inbox);
    (* Dedup is not inbox-dependent: a replay after a drain still duplicates. *)
    match
      sql_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
    with
    | `Duplicate _ -> ()
    | _ -> fail "replay after drain must still be Duplicate")

let test_sqlite_dedup_window_prunes_fifo () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir ~dedup_window:3 () in
    reg_sql_public t ~node_id:"n-b328-a" ~session_id:"s-b328-a" ~alias:"b328-a";
    reg_sql_public t ~node_id:"n-b328-b" ~session_id:"s-b328-b" ~alias:"b328-b";
    let send mid =
      sql_send t ~from_alias:"b328-a" ~to_alias:"b328-b"
        ~content:(Printf.sprintf "content %s" mid) ~message_id:mid
    in
    List.iter
      (fun mid ->
        match send mid with
        | `Ok _ -> ()
        | _ -> failf "fresh send %s should be Ok" mid)
      [ "m1"; "m2"; "m3" ];
    (match send "m2" with
     | `Duplicate _ -> ()
     | _ -> fail "m2 is inside the window: replay must be Duplicate");
    (match send "m4" with
     | `Ok _ -> ()
     | _ -> fail "m4 is fresh: must be Ok (and prunes m1 FIFO)");
    (match send "m1" with
     | `Ok _ -> ()
     | _ -> fail "m1 was pruned FIFO: must be accepted again");
    (match send "m4" with
     | `Duplicate _ -> ()
     | _ -> fail "m4 is still inside the window: replay must be Duplicate"))

(* Backend agreement: the in-memory arm already had dedup; pin its contract
   so the two backends cannot silently diverge again. *)

let test_inmemory_send_replay_is_duplicate () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    reg_mem_public t ~node_id:"n-b328-a" ~session_id:"s-b328-a" ~alias:"b328-a";
    reg_mem_public t ~node_id:"n-b328-b" ~session_id:"s-b328-b" ~alias:"b328-b";
    let mid = "b328-msg-fixed-1" in
    (match
       mem_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
     with
     | `Ok _ -> ()
     | _ -> fail "first send should be Ok");
    (match
       mem_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
     with
     | `Duplicate _ -> ()
     | _ -> fail "in-memory replay must be Duplicate");
    let inbox =
      Relay.InMemoryRelay.poll_inbox t ~node_id:"n-b328-b"
        ~session_id:"s-b328-b"
    in
    check int "in-memory: exactly one delivered copy" 1 (List.length inbox);
    match
      mem_send t ~from_alias:"b328-a" ~to_alias:"b328-b" ~content:"hello" ~message_id:mid
    with
    | `Duplicate _ -> ()
    | _ -> fail "in-memory replay after drain must still be Duplicate")

(* --- e2e: /forward replay answers duplicate:true against sqlite ---------- *)

module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

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

let json_ok = function
  | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool true)
  | _ -> false

let json_flag name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`Bool b) -> b
     | _ -> false)
  | _ -> false

let post_forward ~base_url ~origin_id ~alias ~body_str =
  let auth =
    Relay_signed_ops.sign_request origin_id ~alias ~meth:"POST"
      ~path:"/forward" ~body_str ()
  in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "application/json"); ("Authorization", auth) ]
  in
  Cohttp_lwt_unix.Client.call `POST
    (Uri.of_string (base_url ^ "/forward"))
    ~headers ~body:(Cohttp_lwt.Body.of_string body_str)
  >>= fun (resp, b) ->
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Cohttp_lwt.Body.to_string b >>= fun s ->
  match Yojson.Safe.from_string s with
  | json -> Lwt.return (status, json)
  | exception Yojson.Json_error m -> Lwt.fail_with ("invalid json: " ^ m)

let test_e2e_forward_replay_answers_duplicate () =
  with_temp_dir (fun dir ->
    with_sqlite_server (fun ~base_url ~relay ->
      let victim_id =
        Relay_identity.load_or_create_at
          ~path:(Filename.concat dir "id-victim.json")
          ~alias_hint:"b328-victim"
      in
      let vp =
        Relay_signed_ops.sign_register victim_id ~alias:"b328-victim"
          ~relay_url:base_url
      in
      let client = Relay.Relay_client.make ~timeout:5.0 base_url in
      Relay.Relay_client.register_signed client ~node_id:"n-b328-victim"
        ~session_id:"s-b328-victim" ~alias:"b328-victim" ~client_type:"cli"
        ~identity_pk_b64:vp.Relay_signed_ops.identity_pk_b64
        ~sig_b64:vp.Relay_signed_ops.sig_b64 ~nonce:vp.Relay_signed_ops.nonce
        ~ts:vp.Relay_signed_ops.ts ()
      >>= fun reg ->
      check bool "victim registered" true (json_ok reg);
      (match
         Relay.SqliteRelay.set_peer_discovery_visibility relay
           ~alias:"b328-victim"
           ~visibility:Relay_backend_contract.Public
       with
       | Ok () -> ()
       | Error e -> failf "mark victim public: %s" e);
      (* The origin relay's keypair: /forward requests are signed with it and
         this relay trusts it via the peer table. *)
      let origin_id =
        Relay_identity.load_or_create_at
          ~path:(Filename.concat dir "id-origin.json")
          ~alias_hint:"b328-origin"
      in
      Relay.SqliteRelay.add_peer_relay relay
        { name = "b328-origin-host"; url = base_url;
          identity_pk = origin_id.Relay_identity.public_key };
      let mid = "b328-fwd-fixed-1" in
      let fwd_body =
        Relay_forwarder.build_body ~self_host:"b328-origin-host"
          ~from_alias:"b328-sender" ~to_alias:"b328-victim"
          ~content:"via forward" ~message_id:mid
      in
      let body_str = Yojson.Safe.to_string fwd_body in
      let claimed = "b328-sender@b328-origin-host" in
      post_forward ~base_url ~origin_id ~alias:claimed ~body_str
      >>= fun (st1, j1) ->
      check bool "first forward ok" true (json_ok j1);
      check int "first forward http 200" 200 st1;
      post_forward ~base_url ~origin_id ~alias:claimed ~body_str
      >>= fun (_st2, j2) ->
      if not (json_ok j2) then
        print_endline ("replayed forward response: " ^ Yojson.Safe.to_string j2);
      check bool "replayed forward ok" true (json_ok j2);
      check bool "replayed forward flagged duplicate" true
        (json_flag "duplicate" j2);
      let inbox =
        Relay.SqliteRelay.peek_inbox relay ~node_id:"n-b328-victim"
          ~session_id:"s-b328-victim"
      in
      check int "forward replay delivered exactly one copy" 1
        (List.length inbox);
      Lwt.return_unit))

let () =
  run "B328 sqlite send message-id dedup"
    [ ("sqlite send dedup", [ test_case "replay is Duplicate, one copy" `Quick
          test_sqlite_send_replay_is_duplicate ])
    ; ("sqlite dedup window", [ test_case "window prunes FIFO" `Quick
          test_sqlite_dedup_window_prunes_fifo ])
    ; ("in-memory parity", [ test_case "replay is Duplicate, one copy" `Quick
          test_inmemory_send_replay_is_duplicate ])
    ; ("e2e sqlite /forward replay", [ test_case "replay answers duplicate:true" `Quick
          test_e2e_forward_replay_answers_duplicate ])
    ]
