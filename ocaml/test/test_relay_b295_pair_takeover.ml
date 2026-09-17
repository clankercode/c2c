(* B295: /register ok:true must MOVE the (node_id, session_id) lease key.

   Production symptom (sqlite backend, deterministic per alias): register
   returns ok:true, but the next signed poll_inbox/heartbeat for the same
   (node_id, session_id) is rejected signature_invalid — alias_of_session
   still resolves the pair to a DIFFERENT alias's row (pre-rename /
   pre-rebind leftover inside the 12-month alias reservation), or to None
   when that row is past the reservation.

   Mechanism pinned here: register upserts by alias only (ON CONFLICT(alias)
   / Hashtbl.replace) and never takes the pair over from another alias's
   row; sqlite alias_of_session reads LIMIT 1 with no ORDER BY, so the
   OLDEST row for the pair wins the scan. The registering alias's fresh row
   is shadowed forever — "the lease is not moved". *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b295" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

(* Pre-fix production shape: a foreign alias's row holding the pair. Inserted
   directly so its rowid sorts BEFORE any row a fixed register leaves behind
   (mirrors months-old prod data). *)
let sqlite_insert_foreign_pair_row dir ~alias ~node_id ~session_id ~last_seen =
  let db_path = Filename.concat dir "c2c_relay.db" in
  let conn = Sqlite3.db_open db_path in
  ignore (Sqlite3.exec conn "PRAGMA busy_timeout = 5000");
  let sql =
    Printf.sprintf
      "INSERT INTO secure_leases_v2 (alias, node_id, session_id, client_type, \
       registered_at, last_seen, ttl, identity_pk, enc_pubkey, signed_at, \
       sig_b64, opaque_host_id, client_version, client_os, discovery_visibility) \
       VALUES ('%s', '%s', '%s', 'unknown', %f, %f, 30.0, '', '', 0.0, '', '', \
       '', '', 'private')"
      alias node_id session_id last_seen last_seen
  in
  ignore (Sqlite3.exec conn sql);
  ignore (Sqlite3.db_close conn)

let test_sqlite_register_takes_over_live_pair () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status1, _ =
      Relay.SqliteRelay.register t ~node_id:"b295node" ~session_id:"b295sess"
        ~alias:"b295-old" ()
    in
    check string "old-alias register ok" "ok" status1;
    (* The ticket's exact step: same session re-registers (post-rename /
       rebind) under a new alias; the server says ok:true. *)
    let status2, lease2 =
      Relay.SqliteRelay.register t ~node_id:"b295node" ~session_id:"b295sess"
        ~alias:"b295-new" ()
    in
    check string "new-alias register ok:true" "ok" status2;
    check string "returned lease binds the new alias" "b295-new"
      (Relay.RegistrationLease.alias lease2);
    check (option string) "pair moves to the registering alias"
      (Some "b295-new")
      (Relay.SqliteRelay.alias_of_session t ~node_id:"b295node"
         ~session_id:"b295sess");
    let hstatus, hlease =
      Relay.SqliteRelay.heartbeat t ~node_id:"b295node" ~session_id:"b295sess"
        ~opaque_host_id:""
    in
    check string "heartbeat ok under the new owner" "ok" hstatus;
    check string "heartbeat refreshes the new owner's row" "b295-new"
      (Relay.RegistrationLease.alias hlease))

let test_sqlite_register_clears_stale_foreign_row () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    (* Foreign row past the 12-month reservation: pre-fix LIMIT 1 resolves
       to it and returns None even though a live row matches too. *)
    let stale =
      Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0
    in
    sqlite_insert_foreign_pair_row dir ~alias:"b295-ghost"
      ~node_id:"b295node2" ~session_id:"b295sess2" ~last_seen:stale;
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b295node2" ~session_id:"b295sess2"
        ~alias:"b295-live" ()
    in
    check string "register over ghost row ok:true" "ok" status;
    check (option string) "pair resolves to the live registrant, not the ghost"
      (Some "b295-live")
      (Relay.SqliteRelay.alias_of_session t ~node_id:"b295node2"
         ~session_id:"b295sess2"))

let test_inmemory_register_takes_over_pair () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let status1, _ =
      Relay.InMemoryRelay.register t ~node_id:"b295node" ~session_id:"b295sess"
        ~alias:"b295-old" ()
    in
    check string "in-memory old-alias register ok" "ok" status1;
    let status2, _ =
      Relay.InMemoryRelay.register t ~node_id:"b295node" ~session_id:"b295sess"
        ~alias:"b295-new" ()
    in
    check string "in-memory new-alias register ok:true" "ok" status2;
    check (option string) "in-memory pair moves to the registering alias"
      (Some "b295-new")
      (Relay.InMemoryRelay.alias_of_session t ~node_id:"b295node"
         ~session_id:"b295sess"))

(* --- HTTP end-to-end against a real loopback relay with SQLITE storage
   (production parity for c2c relay serve --storage sqlite): the ticket's
   register ok:true followed by signature_invalid on the next signed
   poll_inbox / heartbeat in the same sync pass. --- *)

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

let json_error_code = function
  | `Assoc fields ->
      (match List.assoc_opt "error_code" fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> ""

let test_e2e_register_then_signed_poll_under_new_alias () =
  with_temp_dir (fun dir ->
    let old_id_path = Filename.concat dir "id-old.json" in
    let new_id_path = Filename.concat dir "id-new.json" in
    with_sqlite_server (fun ~base_url ~relay ->
      let old_id =
        Relay_identity.load_or_create_at ~path:old_id_path
          ~alias_hint:"b295-old"
      in
      let new_id =
        Relay_identity.load_or_create_at ~path:new_id_path
          ~alias_hint:"b295-new"
      in
      let client = Relay.Relay_client.make ~timeout:5.0 base_url in
      let reg alias id =
        let p = Relay_signed_ops.sign_register id ~alias ~relay_url:base_url in
        Relay.Relay_client.register_signed client
          ~node_id:"b295node" ~session_id:"b295sess" ~alias ~client_type:"cli"
          ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
          ~sig_b64:p.Relay_signed_ops.sig_b64
          ~nonce:p.Relay_signed_ops.nonce ~ts:p.Relay_signed_ops.ts ()
      in
      reg "b295-old" old_id >>= fun reg_old ->
      check bool "old-alias register ok" true (json_ok reg_old);
      reg "b295-new" new_id >>= fun reg_new ->
      check bool "new-alias register ok:true (ticket)" true (json_ok reg_new);
      let signed_poll id alias =
        let body =
          `Assoc
            [ ("node_id", `String "b295node")
            ; ("session_id", `String "b295sess") ]
        in
        let body_str = Yojson.Safe.to_string body in
        let auth =
          Relay_signed_ops.sign_request id ~alias ~meth:"POST"
            ~path:"/poll_inbox" ~body_str ()
        in
        Relay.Relay_client.poll_inbox_signed client
          ~node_id:"b295node" ~session_id:"b295sess" ~auth_header:auth
      in
      let signed_heartbeat id alias =
        (* heartbeat_signed appends the local host id when resolvable; the
           signed blob must cover the exact body bytes sent. *)
        let ohid = try Host_id.compute_host_hash () with _ -> "" in
        let fields =
          [ ("node_id", `String "b295node")
          ; ("session_id", `String "b295sess") ]
          @ (if ohid = "" then []
             else [ ("opaque_host_id", `String ohid) ])
        in
        let body_str = Yojson.Safe.to_string (`Assoc fields) in
        let auth =
          Relay_signed_ops.sign_request id ~alias ~meth:"POST"
            ~path:"/heartbeat" ~body_str ()
        in
        Relay.Relay_client.heartbeat_signed client
          ~node_id:"b295node" ~session_id:"b295sess" ~auth_header:auth
      in
      signed_poll new_id "b295-new" >>= fun poll ->
      if not (json_ok poll) then
        print_endline ("poll_inbox response: " ^ Yojson.Safe.to_string poll);
      check bool "signed poll_inbox under new alias succeeds" true
        (json_ok poll);
      (if not (json_ok poll) then
         check string "poll error code" "signature_invalid"
           (json_error_code poll));
      signed_heartbeat new_id "b295-new" >>= fun hb ->
      check bool "signed heartbeat under new alias succeeds" true
        (json_ok hb);
      (if not (json_ok hb) then
         check string "heartbeat error code" "signature_invalid"
           (json_error_code hb));
      check (option string) "server pair resolves to new alias"
        (Some "b295-new")
        (Relay.SqliteRelay.alias_of_session relay ~node_id:"b295node"
           ~session_id:"b295sess");
      Lwt.return_unit))

let () =
  run "B295 relay pair takeover"
    [ ("sqlite register takes over the live pair",
       [ test_case "register moves lease key" `Quick
           test_sqlite_register_takes_over_live_pair ])
    ; ("sqlite register clears stale foreign row",
       [ test_case "register clears stale foreign row" `Quick
           test_sqlite_register_clears_stale_foreign_row ])
    ; ("in-memory register takes over pair",
       [ test_case "register moves lease key" `Quick
           test_inmemory_register_takes_over_pair ])
    ; ("e2e sqlite server register then signed poll",
       [ test_case "register then signed poll under new alias" `Quick
           test_e2e_register_then_signed_poll_under_new_alias ])
    ]
