(* B293: "no live lease" must not be reported as a bad signature, and the
   connector must drop a dead cached registration instead of heartbeating a
   lease it does not own forever.

   Relay half: handle_heartbeat / handle_inbox_read collapse three
   materially different situations — forged signature, lease owned by
   another alias, lease absent/expired — into signature_invalid. A client
   cannot tell "re-register, your lease is gone" from "your key is wrong".

   Connector half: a session enters t.registered on a successful register
   and only ever leaves via retain_eligible_registered (local session went
   away). A failing heartbeat/poll never evicts it, so the connector
   retries a dead lease forever and never takes the one action that
   repairs it. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b293" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

(* --- Part A: relay error-code split, against a real loopback sqlite
   Relay_server (production parity for c2c relay serve --storage sqlite) --- *)

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

let test_heartbeat_unknown_pair_is_lease_not_found () =
  with_temp_dir (fun dir ->
    let id_path = Filename.concat dir "id.json" in
    with_sqlite_server (fun ~base_url ~relay ->
      (* Signer is legitimately bound (own alias, own identity) but the
         (node_id, session_id) in the body never held a lease. *)
      let id = Relay_identity.load_or_create_at ~path:id_path ~alias_hint:"b293-owner" in
      let client = Relay.Relay_client.make ~timeout:5.0 base_url in
      let proof = Relay_signed_ops.sign_register id ~alias:"b293-owner" ~relay_url:base_url in
      Relay.Relay_client.register_signed client
        ~node_id:"b293n-known" ~session_id:"b293s-known" ~alias:"b293-owner"
        ~client_type:"cli"
        ~identity_pk_b64:proof.Relay_signed_ops.identity_pk_b64
        ~sig_b64:proof.Relay_signed_ops.sig_b64
        ~nonce:proof.Relay_signed_ops.nonce ~ts:proof.Relay_signed_ops.ts ()
      >>= fun reg ->
      check bool "setup register ok" true (json_field "ok" reg = `Bool true);
      let ohid = try Host_id.compute_host_hash () with _ -> "" in
      let fields =
        [ ("node_id", `String "b293n-ghost")
        ; ("session_id", `String "b293s-ghost") ]
        @ (if ohid = "" then [] else [ ("opaque_host_id", `String ohid) ])
      in
      let body_str = Yojson.Safe.to_string (`Assoc fields) in
      let auth =
        Relay_signed_ops.sign_request id ~alias:"b293-owner" ~meth:"POST"
          ~path:"/heartbeat" ~body_str ()
      in
      Relay.Relay_client.heartbeat_signed client
        ~node_id:"b293n-ghost" ~session_id:"b293s-ghost" ~auth_header:auth
      >>= fun hb ->
      check string "absent lease reports lease_not_found"
        "lease_not_found" (error_code hb);
      check int "http_status distinguishes re-register-worthy from fatal" 404
        (http_status hb);
      Lwt.return_unit))

let test_heartbeat_foreign_owner_is_still_signature_invalid () =
  with_temp_dir (fun dir ->
    let holder_path = Filename.concat dir "id-holder.json" in
    let other_path = Filename.concat dir "id-other.json" in
    with_sqlite_server (fun ~base_url ~relay ->
      (* The pair IS leased — by a different alias. That is a genuine
         ownership mismatch and must stay signature_invalid (403). *)
      let holder =
        Relay_identity.load_or_create_at ~path:holder_path ~alias_hint:"b293-true-owner"
      in
      let other =
        Relay_identity.load_or_create_at ~path:other_path ~alias_hint:"b293-other"
      in
      let client = Relay.Relay_client.make ~timeout:5.0 base_url in
      let reg alias id node sid =
        let p = Relay_signed_ops.sign_register id ~alias ~relay_url:base_url in
        Relay.Relay_client.register_signed client
          ~node_id:node ~session_id:sid ~alias ~client_type:"cli"
          ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
          ~sig_b64:p.Relay_signed_ops.sig_b64
          ~nonce:p.Relay_signed_ops.nonce ~ts:p.Relay_signed_ops.ts ()
      in
      reg "b293-true-owner" holder "b293n" "b293s" >>= fun reg1 ->
      check bool "true owner registered" true (json_field "ok" reg1 = `Bool true);
      reg "b293-other" other "b293n2" "b293s2" >>= fun reg2 ->
      check bool "other alias registered" true (json_field "ok" reg2 = `Bool true);
      (* heartbeat_signed appends the local host id when resolvable; the
         signed blob must cover the exact body bytes sent, or the signature
         fails to verify and a tokenless relay falls back to the unsigned
         path (verified_alias = None) — which would run the heartbeat. *)
      let ohid = try Host_id.compute_host_hash () with _ -> "" in
      let fields =
        [ ("node_id", `String "b293n"); ("session_id", `String "b293s") ]
        @ (if ohid = "" then [] else [ ("opaque_host_id", `String ohid) ])
      in
      let body_str = Yojson.Safe.to_string (`Assoc fields) in
      let auth =
        Relay_signed_ops.sign_request other ~alias:"b293-other" ~meth:"POST"
          ~path:"/heartbeat" ~body_str ()
      in
      Relay.Relay_client.heartbeat_signed client
        ~node_id:"b293n" ~session_id:"b293s" ~auth_header:auth
      >>= fun hb ->
      check string "foreign owner still reports signature_invalid"
        "signature_invalid" (error_code hb);
      check int "and still 403" 403 (http_status hb);
      Lwt.return_unit))

let test_inbox_read_unknown_pair_is_lease_not_found () =
  with_temp_dir (fun dir ->
    let id_path = Filename.concat dir "id.json" in
    with_sqlite_server (fun ~base_url ~relay ->
      let id = Relay_identity.load_or_create_at ~path:id_path ~alias_hint:"b293-owner" in
      let client = Relay.Relay_client.make ~timeout:5.0 base_url in
      let proof = Relay_signed_ops.sign_register id ~alias:"b293-owner" ~relay_url:base_url in
      Relay.Relay_client.register_signed client
        ~node_id:"b293n-known" ~session_id:"b293s-known" ~alias:"b293-owner"
        ~client_type:"cli"
        ~identity_pk_b64:proof.Relay_signed_ops.identity_pk_b64
        ~sig_b64:proof.Relay_signed_ops.sig_b64
        ~nonce:proof.Relay_signed_ops.nonce ~ts:proof.Relay_signed_ops.ts ()
      >>= fun reg ->
      check bool "setup register ok" true (json_field "ok" reg = `Bool true);
      let signed_poll node sid =
        let body_str =
          Yojson.Safe.to_string
            (`Assoc [ ("node_id", `String node); ("session_id", `String sid) ])
        in
        let auth =
          Relay_signed_ops.sign_request id ~alias:"b293-owner" ~meth:"POST"
            ~path:"/poll_inbox" ~body_str ()
        in
        Relay.Relay_client.poll_inbox_signed client ~node_id:node ~session_id:sid
          ~auth_header:auth
      in
      signed_poll "b293n-known" "b293s-known" >>= fun owned ->
      check bool "owned pair polls fine" true (json_field "ok" owned = `Bool true);
      signed_poll "b293n-ghost" "b293s-ghost" >>= fun ghost ->
      check string "absent lease reports lease_not_found on poll_inbox"
        "lease_not_found" (error_code ghost);
      check int "http_status 404" 404 (http_status ghost);
      Lwt.return_unit))

(* --- Part B: connector recovery, against the scripted loopback harness --- *)

module S = Relay_test_support

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_broker_root f =
  let dir = Filename.temp_dir "c2c_b293_broker" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

let sm_session = "sess-b293"
let sm_alias = "b293-probe"

(* Connector sync only acts on eligible registrations (live PID + matching
   start-time). Bare rows are skipped as historical, so the fixture must
   look live or the case no-ops with last_error=None. *)
let write_registry broker_root =
  let pid = Unix.getpid () in
  let pid_start =
    match C2c_relay_connector.read_pid_start_time_local pid with
    | Some n -> n
    | None ->
        (match C2c_mcp.Broker.read_pid_start_time pid with
         | Some n -> n
         | None -> 1)
  in
  write_file
    (Filename.concat broker_root "registry.json")
    (Yojson.Safe.to_string
       (`List
         [ `Assoc
             [ ("session_id", `String sm_session);
               ("alias", `String sm_alias);
               ("client_type", `String "test");
               ("pid", `Int pid);
               ("pid_start_time", `Int pid_start);
             ];
         ]))

let make_connector ~relay_url ~broker_root ~registered : C2c_relay_connector.t =
  { C2c_relay_connector.relay_url;
    token = None;
    identity = None;
    broker_root;
    node_id = "n-b293";
    heartbeat_ttl = 60.0;
    interval = 1.0;
    verbose = false;
    registered;
    active_ws_bindings = [];
    owner_mismatch_strikes = [];
    alert_state = C2c_relay_alert.initial_state;
    last_pass_s = 0.0;
  }

let run_sync t = Lwt_main.run (C2c_relay_connector.sync t)

let count_requests srv path =
  List.length
    (List.filter (fun (r : S.captured_request) -> r.S.path = path) (S.requests srv))

let reg_ok = {|{"ok":true,"result":"ok","lease":{"alias":"b293-probe"}}|}
let poll_ok = {|{"ok":true,"messages":[]}|}
let hb_ok = {|{"ok":true,"lease":{"alias":"b293-probe"}}|}
let lease_gone =
  {|{"ok":false,"error_code":"lease_not_found","error":"no live lease for session"}|}
let owner_mismatch =
  {|{"ok":false,"error_code":"signature_invalid","error":"verified signer \"x\" does not own session (n, s)"}|}

(* Heartbeat reports lease_not_found: the cached registration is dead and
   register — the one repair — must happen instead of retrying the dead
   lease. Recovery within the SAME pass keeps the alias leased and the pass
   a success (no whole-root no-progress feeding the staleness watchdog). *)
let test_connector_heartbeat_lease_not_found_registers () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat" [ S.response lease_gone ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response poll_ok ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response poll_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          let r = run_sync t in
          check (list string) "alias re-registered" [ sm_alias ] r.registered;
          check bool "in-pass repair is not a sync error" true
            (r.last_error = None);
          check bool "session re-entered t.registered" true
            (List.mem sm_session t.registered);
          check int "exactly one register" 1 (count_requests srv "/register");
          check int "heartbeat attempted once" 1
            (count_requests srv "/heartbeat")))

(* The pre-fix wedge: heartbeat fails forever with the same dead lease. Pin
   that a repaired session STAYS healthy on the following pass. *)
let test_connector_repaired_session_stays_registered () =
  (* First heartbeat says lease gone, then the lease is healthy. *)
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat"
        [ S.response lease_gone; S.response hb_ok ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response poll_ok ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response poll_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          ignore (run_sync t);
          let r2 = run_sync t in
          (* Pre-existing shape: [registered] lists aliases REGISTERED this
             pass, so a heartbeated steady state reports none — the durable
             evidence is [registered_sessions] / t.registered. *)
          check (list string) "steady pass registers nothing new" []
            r2.registered;
          check bool "second pass is clean" true (r2.last_error = None);
          check bool "session still in t.registered" true
            (List.mem sm_session t.registered);
          check (list (pair string string)) "recorded session binding persists"
            [ (sm_alias, sm_session) ] r2.registered_sessions;
          check int "no second register" 1 (count_requests srv "/register");
          check int "second heartbeat happened" 2
            (count_requests srv "/heartbeat")))

(* Owner mismatch (live lease under someone else's keys): NOT dropped on
   the first failure — a transient (register-takeover racing this pass)
   must not thrash the connector between register and heartbeat. After it
   repeats on a consecutive pass the cached registration is dropped and
   the next pass re-registers. *)
let test_connector_owner_mismatch_drops_after_repeat () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response poll_ok ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response poll_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          let r1 = run_sync t in
          check bool "first mismatch tolerated (still registered)" true
            (List.mem sm_session t.registered);
          check bool "but still reported as an error" true
            (r1.last_error <> None);
          check int "no register yet" 0 (count_requests srv "/register");
          let _r2 = run_sync t in
          check bool "repeated mismatch drops the cached registration" false
            (List.mem sm_session t.registered);
          check int "still no register this pass" 0
            (count_requests srv "/register");
          let _r3 = run_sync t in
          check int "register happens the pass after the drop" 1
            (count_requests srv "/register");
          check bool "re-registered again" true
            (List.mem sm_session t.registered)))

(* A strike must decay on success, or one transient mismatch permanently
   lowers the tolerance for that session. *)
let test_connector_owner_mismatch_strike_decays_on_success () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat"
        [ S.response owner_mismatch; S.response hb_ok;
          S.response owner_mismatch; S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response poll_ok ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response poll_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          ignore (run_sync t);                      (* mismatch: strike 1 *)
          ignore (run_sync t);                      (* ok: strike cleared *)
          let _r3 = run_sync t in                   (* mismatch: strike 1 *)
          check bool "cleared strike restarts at one" true
            (List.mem sm_session t.registered);
          let _r4 = run_sync t in                   (* mismatch: strike 2 *)
          check bool "two consecutive mismatches still drop" false
            (List.mem sm_session t.registered)))

(* The poll arm: a lease that died between heartbeat and the inbound fetch
   must also be dropped, or the connector keeps polling a dead lease until
   the local session disappears. B317: the fetch starts with the
   non-destructive peek, which is where the dead lease is now discovered;
   classification and drop handling are unchanged. *)
let test_connector_poll_lease_not_found_drops_registration () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat" [ S.response hb_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response lease_gone ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response lease_gone ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          let r1 = run_sync t in
          check bool "dead lease dropped from t.registered" false
            (List.mem sm_session t.registered);
          check (list string) "alias not reported registered" []
            r1.registered;
          check bool "poll failure is still a sync error" true
            (r1.last_error <> None);
          let _r2 = run_sync t in
          check int "next pass re-registers" 1
            (count_requests srv "/register")))

(* B317 review fix: the inbound fetch runs peek AND poll against the same
   ownership check, so a mismatching relay body can arrive TWICE in one
   pass. B293's threshold is documented as consecutive PASSES — the strike
   must be bumped at most once per pass, or one transient mismatch drops
   the registration immediately (the thrash the threshold exists to
   prevent). *)
let test_connector_owner_mismatch_bumped_once_per_pass () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat" [ S.response hb_ok ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          let r1 = run_sync t in
          check bool "one mismatching pass tolerates (still registered)" true
            (List.mem sm_session t.registered);
          check bool "mismatch still reported as an error" true
            (r1.last_error <> None);
          let _r2 = run_sync t in
          check bool "second consecutive mismatching pass drops" false
            (List.mem sm_session t.registered)))

(* B323: the HEARTBEAT arm and the poll arm both see the foreign lease in
   ONE pass — exactly one strike, or the documented two-consecutive-pass
   tolerance collapses to one pass. Pins the per-(session, pass) strike
   memo (9e7eaa10) for the heartbeat arm's half of it; the previous case
   covers the peek+poll pair behind a healthy heartbeat. *)
let test_connector_owner_mismatch_bumped_once_per_pass_heartbeat_and_poll () =
  let routes =
    [ S.route ~meth:"POST" ~path:"/heartbeat" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/peek_inbox" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/poll_inbox" [ S.response owner_mismatch ];
      S.route ~meth:"POST" ~path:"/register" [ S.response reg_ok ];
    ]
  in
  S.with_server ~routes (fun srv ->
      with_broker_root (fun broker_root ->
          write_registry broker_root;
          let t = make_connector ~relay_url:(S.url srv) ~broker_root
              ~registered:[ sm_session ] in
          let r1 = run_sync t in
          check bool
            "heartbeat+poll mismatch in one pass tolerates (still registered)"
            true
            (List.mem sm_session t.registered);
          check bool "mismatch still reported as an error" true
            (r1.last_error <> None);
          let _r2 = run_sync t in
          check bool "second consecutive mismatching pass drops" false
            (List.mem sm_session t.registered)))

let () =
  run "B293 relay lease recovery"
    [ ("relay error codes",
       [ test_case "heartbeat unknown pair -> lease_not_found" `Quick
           test_heartbeat_unknown_pair_is_lease_not_found
       ; test_case "heartbeat foreign owner -> signature_invalid" `Quick
           test_heartbeat_foreign_owner_is_still_signature_invalid
       ; test_case "poll_inbox unknown pair -> lease_not_found" `Quick
           test_inbox_read_unknown_pair_is_lease_not_found
       ])
    ; ("connector recovery",
       [ test_case "heartbeat lease_not_found registers in-pass" `Quick
           test_connector_heartbeat_lease_not_found_registers
       ; test_case "repaired session stays registered" `Quick
           test_connector_repaired_session_stays_registered
       ; test_case "owner mismatch drops after repeat" `Quick
           test_connector_owner_mismatch_drops_after_repeat
       ; test_case "owner mismatch strike decays on success" `Quick
           test_connector_owner_mismatch_strike_decays_on_success
       ; test_case "poll lease_not_found drops registration" `Quick
           test_connector_poll_lease_not_found_drops_registration
       ; test_case "owner mismatch bumped once per pass" `Quick
           test_connector_owner_mismatch_bumped_once_per_pass
       ; test_case "heartbeat+poll mismatch bumped once per pass (B323)" `Quick
           test_connector_owner_mismatch_bumped_once_per_pass_heartbeat_and_poll
       ])
    ]
