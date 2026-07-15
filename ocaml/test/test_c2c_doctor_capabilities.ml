(* test_c2c_doctor_capabilities — hermetic tests for Relay_doctor, the shared
   scheme/attempt-aware relay capability + broker-owned connector attribution
   logic behind `c2c doctor --relay` and the `c2c relay subscribe` guard (H4).

   This is the head of the serialized ocaml/test/dune doctor/capability lane;
   later slices (J1/H5/H6/F5a) add sibling test modules with their own stanzas.

   Covers the B093 acceptance list:
   - HTTPS subscribe=no and poll=yes (scheme-aware capabilities)
   - actual-attempt parity: doctor's subscribe capability uses the very
     predicate the subscribe command guard uses
   - unrelated-connector negative (broker-root scoping)
   - stale connector state
   - check IDs / statuses / every FAIL carries a fix
   - docs link target (published permalink, not the old 404)
   - env-gated public read-only smoke against https://relay.c2c.im *)

open Relay_doctor

(* ---- connector_state fixture -------------------------------------------- *)

let conn_state ?(last_sync = 0.0) ?(last_ok = 0.0) ?err_op ?err_detail ?err_ts
    ?(fwd = 0) ?(failed = 0) ?(dlq = 0) ?(inbound = 0) () :
    C2c_relay_connector.connector_state =
  {
    C2c_relay_connector.cs_last_sync_ts = last_sync;
    cs_last_ok_ts = last_ok;
    cs_last_error_op = err_op;
    cs_last_error_detail = err_detail;
    cs_last_error_ts = err_ts;
    cs_registered = [];
    (* H3 added cs_node_id to connector_state; this H4 fixture predates it.
       None = connector state without a node-id (pre-H3 shape). *)
    cs_node_id = None;
    cs_sessions = [];
    cs_pid = None;
    cs_outbox_forwarded = fwd;
    cs_outbox_failed = failed;
    cs_outbox_dlqed = dlq;
    cs_inbound_delivered = inbound;
    cs_inbound_rejected = 0;
  }

let has_needle ~needle haystack = string_contains ~needle haystack

(* ---- capabilities: scheme awareness ------------------------------------- *)

let test_https_subscribe_yes_poll_yes () =
  let c = capabilities ~url:"https://relay.c2c.im" ~reachable:true ~connector_running:false in
  Alcotest.(check bool) "https send=yes" true c.send;
  Alcotest.(check bool) "https subscribe=YES (B189 wss)" true c.subscribe;
  Alcotest.(check bool) "https poll=yes" true c.poll;
  Alcotest.(check bool) "https tls=yes" true c.tls;
  Alcotest.(check bool) "https connect follows connector_running (false)" false c.connect

let test_wss_subscribe_yes () =
  let c = capabilities ~url:"wss://relay.c2c.im/ws" ~reachable:true ~connector_running:true in
  Alcotest.(check bool) "wss subscribe=YES (B189)" true c.subscribe;
  Alcotest.(check bool) "wss tls=yes" true c.tls;
  Alcotest.(check bool) "wss connect=yes" true c.connect

let test_http_subscribe_yes () =
  let c = capabilities ~url:"http://localhost:7331" ~reachable:true ~connector_running:false in
  Alcotest.(check bool) "http subscribe=YES" true c.subscribe;
  Alcotest.(check bool) "http tls=no" false c.tls

let test_ws_subscribe_yes () =
  let c = capabilities ~url:"ws://localhost:7331/ws" ~reachable:true ~connector_running:false in
  Alcotest.(check bool) "ws subscribe=YES" true c.subscribe;
  Alcotest.(check bool) "ws tls=no" false c.tls

let test_unreachable_all_no () =
  let c = capabilities ~url:"http://localhost:7331" ~reachable:false ~connector_running:false in
  Alcotest.(check bool) "unreachable send=no" false c.send;
  Alcotest.(check bool) "unreachable subscribe=no" false c.subscribe;
  Alcotest.(check bool) "unreachable poll=no" false c.poll

let test_capabilities_message_shape () =
  let m_https = capabilities_message (capabilities ~url:"https://relay.c2c.im" ~reachable:true ~connector_running:false) in
  Alcotest.(check bool) "message has subscribe=yes over https" true
    (has_needle ~needle:"subscribe=yes" m_https);
  Alcotest.(check bool) "message has poll=yes over https" true
    (has_needle ~needle:"poll=yes" m_https);
  Alcotest.(check bool) "message tagged TLS" true (has_needle ~needle:"(TLS)" m_https);
  let m_http = capabilities_message (capabilities ~url:"http://localhost:7331" ~reachable:true ~connector_running:false) in
  Alcotest.(check bool) "message has subscribe=yes over http" true
    (has_needle ~needle:"subscribe=yes" m_http);
  Alcotest.(check bool) "message tagged plaintext" true (has_needle ~needle:"(plaintext)" m_http)

(* ---- actual-attempt parity: doctor uses the subscribe command's predicate - *)

let test_actual_attempt_parity () =
  (* The subscribe command guard (c2c_relay_cmd.ml) rejects a URL iff
     [not (subscribe_url_supported url)]. The doctor capability is
     [reachable && subscribe_url_supported url]. Same predicate → parity. *)
  List.iter
    (fun url ->
      let supported = subscribe_url_supported url in
      let cap = (capabilities ~url ~reachable:true ~connector_running:false).subscribe in
      Alcotest.(check bool)
        (Printf.sprintf "parity: cap.subscribe == subscribe_url_supported for %s" url)
        supported cap)
    [ "https://relay.c2c.im"; "wss://relay.c2c.im/ws"; "http://localhost:7331";
      "ws://localhost:7331/ws"; "relay.c2c.im" (* no scheme → supported *) ];
  Alcotest.(check bool) "https supported (B189)" true (subscribe_url_supported "https://relay.c2c.im");
  Alcotest.(check bool) "wss supported (B189)" true (subscribe_url_supported "wss://x/ws");
  Alcotest.(check bool) "http supported" true (subscribe_url_supported "http://localhost:7331");
  Alcotest.(check bool) "ws supported" true (subscribe_url_supported "ws://x/ws");
  Alcotest.(check bool) "ftp unsupported" false (subscribe_url_supported "ftp://x/ws")

(* ---- capabilities_check: id / status / fix ------------------------------ *)

let test_capabilities_check_pass_and_fix () =
  let r_ready = capabilities_check ~url:"http://localhost:7331" ~reachable:true ~connector_running:true in
  Alcotest.(check string) "check_id" "relay.capabilities" r_ready.check_id;
  Alcotest.(check bool) "reachable+connector → PASS" true (r_ready.status = Pass);
  Alcotest.(check bool) "PASS has no fix" true (r_ready.fix_command = None);
  Alcotest.(check bool) "docs_url present" true (r_ready.docs_url = Some docs_url);
  let r_noconn = capabilities_check ~url:"https://relay.c2c.im" ~reachable:true ~connector_running:false in
  Alcotest.(check bool) "reachable, no connector → Inconclusive" true (r_noconn.status = Inconclusive);
  Alcotest.(check bool) "no-connector offers a fix" true (r_noconn.fix_command <> None);
  let r_unreach = capabilities_check ~url:"https://relay.c2c.im" ~reachable:false ~connector_running:false in
  Alcotest.(check bool) "unreachable → Inconclusive (never false PASS)" true (r_unreach.status = Inconclusive)

(* ---- connector scoping: unrelated connector negative -------------------- *)

let broker_a = "/home/agent/.c2c/repos/aaaa1111/broker"
let broker_b = "/home/agent/.c2c/repos/bbbb2222/broker"

let test_scope_keeps_own_broker () =
  let lines =
    [ Printf.sprintf "12345 c2c relay connect --broker-root %s --relay-url https://relay.c2c.im" broker_a ]
  in
  let scoped = scope_connector_lines ~broker_root:broker_a lines in
  Alcotest.(check int) "own-broker line kept" 1 (List.length scoped)

let test_scope_drops_unrelated_connector () =
  (* An unrelated connector (different broker) using the SAME public relay must
     NOT be attributed to broker A — this is the exact B093 false positive. *)
  let lines =
    [ Printf.sprintf "12345 c2c relay connect --broker-root %s --relay-url https://relay.c2c.im" broker_b
    ; "67890 c2c relay connect --relay-url https://relay.c2c.im" (* no broker root at all *)
    ; "11111 grep c2c relay connect" (* unrelated shell mentioning the string *)
    ]
  in
  let scoped = scope_connector_lines ~broker_root:broker_a lines in
  Alcotest.(check int) "no unrelated connector attributed to broker A" 0 (List.length scoped)

let test_scope_empty_or_unresolved_broker () =
  let lines = [ "12345 c2c relay connect" ] in
  Alcotest.(check int) "empty broker_root → nothing scoped" 0
    (List.length (scope_connector_lines ~broker_root:"" lines));
  Alcotest.(check int) "<unresolved> broker_root → nothing scoped" 0
    (List.length (scope_connector_lines ~broker_root:"<unresolved>" lines))

(* ---- connector_running signal ------------------------------------------- *)

let test_connector_running_signal () =
  let now = 1000.0 in
  let fresh =
    conn_state ~last_sync:(now -. 10.0) ~last_ok:(now -. 10.0) ()
  in
  let stale =
    conn_state ~last_sync:(now -. 10000.0) ~last_ok:(now -. 10000.0) ()
  in
  let sync_only =
    conn_state ~last_sync:(now -. 10.0) ~last_ok:(now -. 10000.0) ()
  in
  (* B181: process presence alone is NOT a live bridge. *)
  Alcotest.(check bool) "scoped proc alone → NOT running" false
    (connector_running ~scoped_procs:[ "x" ] ~state:None ~now);
  Alcotest.(check bool) "fresh last_ok → running" true
    (connector_running ~scoped_procs:[] ~state:(Some fresh) ~now);
  Alcotest.(check bool) "stale state only → NOT running" false
    (connector_running ~scoped_procs:[] ~state:(Some stale) ~now);
  Alcotest.(check bool) "fresh last_sync but stale last_ok → NOT running" false
    (connector_running ~scoped_procs:[] ~state:(Some sync_only) ~now);
  Alcotest.(check bool) "proc + stale state → still NOT running (B181)" false
    (connector_running ~scoped_procs:[ "x" ] ~state:(Some stale) ~now);
  Alcotest.(check bool) "nothing → NOT running" false
    (connector_running ~scoped_procs:[] ~state:None ~now)

(* ---- connector_check: branches, ids, fixes ------------------------------ *)

let relay_url = "https://relay.c2c.im"
let now = 1_000_000.0

let cc ?(procs = []) ?state () =
  connector_check ~relay_url ~scoped_procs:procs ~state ~now

let test_connector_check_no_proc_no_state () =
  let r = cc () in
  Alcotest.(check string) "check_id" "relay.connector" r.check_id;
  Alcotest.(check bool) "no proc + no state → FAIL" true (r.status = Fail);
  Alcotest.(check bool) "FAIL has fix" true (r.fix_command <> None)

let test_connector_check_stale_state () =
  let r = cc ~state:(conn_state ~last_sync:(now -. 5000.0) ()) () in
  Alcotest.(check bool) "stale, no proc → FAIL" true (r.status = Fail);
  Alcotest.(check bool) "stale FAIL has fix" true (r.fix_command <> None);
  Alcotest.(check bool) "message mentions last sync" true
    (has_needle ~needle:"last sync" r.message)

let test_connector_check_fresh_state_no_proc () =
  (* B1 (peer-review): a fresh, healthy, broker-OWNED state file with NO scoped
     process is the canonical production path — `c2c relay connect --relay-url
     <url>` carries no --broker-root on argv, so scope_connector_lines yields
     []. The broker-owned state file is authoritative → PASS with a truthful
     "bridge live" message (was the false "connector not running"
     Inconclusive before). *)
  let st =
    conn_state ~last_sync:(now -. 10.0) ~last_ok:(now -. 10.0) ~fwd:4 ~inbound:2 ()
  in
  let r = cc ~state:st () in
  Alcotest.(check bool) "fresh healthy state alone → PASS" true (r.status = Pass);
  Alcotest.(check bool) "message says bridge live" true
    (has_needle ~needle:"bridge live" r.message);
  Alcotest.(check bool) "message is NOT the 'not running' falsehood" false
    (has_needle ~needle:"not running" r.message)

(* Full production path: a real pgrep line for the canonical launch (NO
   --broker-root on argv) must NOT be attributed by string match, leaving
   scoped_procs=[]; the fresh broker-owned state file then drives PASS. This is
   the exact input combo that produced the B1 false negative in the wild — the
   synthetic argv fixture in [test_connector_check_proc_healthy] carried a proc
   line that would not survive scoping in production. *)
let test_connector_check_production_argv_no_broker_root () =
  let argv_lines =
    [ Printf.sprintf "4242 c2c relay connect --relay-url %s" relay_url ]
  in
  let scoped =
    scope_connector_lines
      ~broker_root:"/home/agent/.c2c/repos/deadbeef1234/broker" argv_lines
  in
  Alcotest.(check int) "canonical argv not string-matched to this broker" 0
    (List.length scoped);
  let st =
    conn_state ~last_sync:(now -. 8.0) ~last_ok:(now -. 8.0) ~fwd:5 ~inbound:3 ()
  in
  let r = connector_check ~relay_url ~scoped_procs:scoped ~state:(Some st) ~now in
  Alcotest.(check bool) "production fresh-state → PASS" true (r.status = Pass);
  Alcotest.(check bool) "truthful bridge-live message" true
    (has_needle ~needle:"bridge live" r.message
    && not (has_needle ~needle:"not running" r.message))

(* Coherence: capabilities and the connector check consume the same
   broker-owned signal ([connector_running]) and can never contradict. Whenever
   capabilities reports connect=yes, the connector check must agree the
   connector is running — never the "connector not running" / unattributable
   falsehood — and on the healthy path both land on PASS. *)
let test_capabilities_connector_coherence () =
  let combos =
    [ ("fresh state, no proc (production)", [],
       Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ()))
    ; ("proc + fresh healthy state", [ "p" ],
       Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ()))
    ; ("proc + stale state (wedged)", [ "p" ],
       Some (conn_state ~last_sync:(now -. 9000.0) ~last_ok:(now -. 9000.0) ()))
    ; ("proc, no state (first sync)", [ "p" ], None)
    ; ("fresh sync stale ok, no proc", [],
       Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 9000.0)
               ~err_op:"sync" ~err_detail:"429" ~err_ts:(now -. 5.0) ()))
    ; ("stale state, no proc (down)", [],
       Some (conn_state ~last_sync:(now -. 9000.0) ~last_ok:(now -. 9000.0) ()))
    ; ("nothing", [], None)
    ]
  in
  (* Non-contradiction across every representable combo. *)
  List.iter
    (fun (label, procs, state) ->
      let running = connector_running ~scoped_procs:procs ~state ~now in
      let cr = connector_check ~relay_url ~scoped_procs:procs ~state ~now in
      let cap =
        (capabilities ~url:relay_url ~reachable:true ~connector_running:running)
          .connect
      in
      Alcotest.(check bool) (label ^ ": capabilities.connect == connector_running")
        running cap;
      if running then begin
        Alcotest.(check bool)
          (label ^ ": connect=yes never yields 'not running'") false
          (has_needle ~needle:"not running" cr.message);
        Alcotest.(check bool)
          (label ^ ": connect=yes never yields the unattributable FAIL") false
          (has_needle ~needle:"no relay connector attributable" cr.message)
      end)
    combos;
  (* Strong form on the healthy path: connect=yes ⇒ connector_check PASS
     (unless recent_err still marks FAIL while last_ok is fresh). *)
  List.iter
    (fun (label, procs, state) ->
      let running = connector_running ~scoped_procs:procs ~state ~now in
      let cr = connector_check ~relay_url ~scoped_procs:procs ~state ~now in
      Alcotest.(check bool) (label ^ ": connect=yes ⇒ PASS") true
        ((not running) || cr.status = Pass))
    [ ("fresh state, no proc", [],
       Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ()))
    ; ("proc + fresh healthy state", [ "p" ],
       Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ())) ]

let test_connector_check_proc_no_state () =
  let r = cc ~procs:[ "12345 c2c relay connect" ] () in
  Alcotest.(check bool) "proc, no state → Inconclusive (first sync)" true
    (r.status = Inconclusive);
  Alcotest.(check bool) "mentions process≠bridge" true
    (has_needle ~needle:"process≠bridge" r.message
    || has_needle ~needle:"process" r.message)

let test_connector_check_proc_wedged () =
  (* B181: long-lived PID + stale last_sync must FAIL as wedged, never PASS. *)
  let st =
    conn_state ~last_sync:(now -. 9000.0) ~last_ok:(now -. 9000.0) ()
  in
  let r = cc ~procs:[ "12345 c2c relay connect --broker-root /x" ] ~state:st () in
  Alcotest.(check bool) "proc + stale → FAIL" true (r.status = Fail);
  Alcotest.(check bool) "message says wedged" true
    (has_needle ~needle:"wedged" r.message);
  Alcotest.(check bool) "mentions process≠bridge health" true
    (has_needle ~needle:"process≠bridge" r.message);
  Alcotest.(check bool) "wedged still has a fix" true (r.fix_command <> None);
  Alcotest.(check bool) "bridge not live" false
    (connector_running ~scoped_procs:[ "p" ] ~state:(Some st) ~now)

let test_connector_check_proc_recent_error () =
  (* Sync cycling but last_ok stale / recent error → FAIL with fix. With B181
     last_ok freshness, this is not "live"; it is erroring/wedged. *)
  let st =
    conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 400.0)
      ~err_op:"sync" ~err_detail:"register: 429" ~err_ts:(now -. 5.0) ()
  in
  let r = cc ~procs:[ "12345 c2c relay connect" ] ~state:st () in
  Alcotest.(check bool) "proc + stale last_ok → FAIL" true (r.status = Fail);
  Alcotest.(check bool) "erroring connector STILL has a fix" true
    (r.fix_command <> None)

let test_connector_check_live_with_recent_error () =
  (* last_ok still fresh (transient blip) but recent_err set → FAIL + fix. *)
  let st =
    conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0)
      ~err_op:"sync" ~err_detail:"register: 429" ~err_ts:(now -. 5.0) ()
  in
  let r = cc ~procs:[ "12345 c2c relay connect" ] ~state:st () in
  Alcotest.(check bool) "live last_ok + recent error → FAIL" true (r.status = Fail);
  Alcotest.(check bool) "still has a fix" true (r.fix_command <> None);
  Alcotest.(check bool) "connector_running still true (fresh last_ok)" true
    (connector_running ~scoped_procs:[ "p" ] ~state:(Some st) ~now)

let test_connector_check_proc_healthy () =
  let st =
    conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ~fwd:3 ~inbound:2 ()
  in
  let r = cc ~procs:[ "12345 c2c relay connect" ] ~state:st () in
  Alcotest.(check bool) "proc + healthy → PASS" true (r.status = Pass)

(* Invariant across every representable connector outcome: FAIL ⇒ fix present. *)
let test_every_fail_has_fix () =
  let cases =
    [ cc ()
    ; cc ~state:(conn_state ~last_sync:(now -. 5000.0) ()) ()
    ; cc ~state:(conn_state ~last_sync:(now -. 10.0) ()) ()
    ; cc ~procs:[ "p" ] ()
    ; cc ~procs:[ "p" ]
        ~state:(conn_state ~last_sync:(now -. 5.0) ~err_op:"sync"
                  ~err_detail:"boom" ~err_ts:(now -. 5.0) ()) ()
    ; cc ~procs:[ "p" ] ~state:(conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ()) ()
    ]
  in
  List.iter
    (fun r ->
      if r.status = Fail then
        Alcotest.(check bool)
          (Printf.sprintf "FAIL %S carries a fix" r.message)
          true (r.fix_command <> None))
    cases

(* ---- docs link target --------------------------------------------------- *)

let test_docs_link_target () =
  Alcotest.(check string) "docs_url is the published relay-quickstart permalink"
    "https://c2c.im/relay-quickstart/" docs_url;
  Alcotest.(check bool) "docs_url is NOT the old 404 /docs/relay" false
    (has_needle ~needle:"/docs/relay" docs_url)

(* ---- env-gated public read-only smoke ----------------------------------- *)

(* Set C2C_DOCTOR_LIVE_SMOKE=1 to run a real GET https://relay.c2c.im/health
   (read-only) and assert scheme-aware capabilities against the live public
   relay. Skipped by default so normal `dune runtest` stays hermetic/offline. *)
let test_public_smoke () =
  match Sys.getenv_opt "C2C_DOCTOR_LIVE_SMOKE" with
  | Some "1" ->
      let url = "https://relay.c2c.im" in
      let client = Relay.Relay_client.make ~timeout:8.0 url in
      let health =
        try Some (Lwt_main.run (Relay.Relay_client.health client))
        with e ->
          Alcotest.failf "live /health probe raised: %s" (Printexc.to_string e)
      in
      let ok =
        match health with
        | Some (`Assoc fs) -> List.assoc_opt "ok" fs = Some (`Bool true)
        | _ -> false
      in
      Alcotest.(check bool) "public relay /health ok=true" true ok;
      let c = capabilities ~url ~reachable:(health <> None) ~connector_running:false in
      Alcotest.(check bool) "live: subscribe=YES over TLS (B189)" true c.subscribe;
      Alcotest.(check bool) "live: poll=yes" true c.poll;
      Alcotest.(check bool) "live: tls=yes" true c.tls
  | _ ->
      (* Not enabled: assert the deterministic scheme logic instead so the case
         is never vacuously empty. *)
      let c = capabilities ~url:"https://relay.c2c.im" ~reachable:true ~connector_running:false in
      Alcotest.(check bool) "offline stand-in: subscribe=YES over TLS (B189)" true c.subscribe;
      Alcotest.(check bool) "offline stand-in: poll=yes" true c.poll

(* B210: machine-wide duplicate-connector detection. *)
let test_persistent_pids_dedup_and_once_excluded () =
  let lines =
    [ "111 c2c relay connect --all-brokers --broker-root /a/broker"
    ; "111 c2c relay connect --all-brokers --broker-root /a/broker"  (* dup pid *)
    ; "222 c2c relay connect --relay-url https://relay.c2c.im"
    ; "333 c2c relay connect --once --broker-root /b/broker"          (* transient *)
    ]
  in
  let pids = Relay_doctor.persistent_connector_pids lines in
  Alcotest.(check (list int)) "distinct persistent pids, --once excluded"
    [ 111; 222 ] pids

let test_duplicate_check_none_when_singleton () =
  Alcotest.(check bool) "0 pids -> None" true
    (Relay_doctor.duplicate_connector_check ~pids:[] = None);
  Alcotest.(check bool) "1 pid -> None" true
    (Relay_doctor.duplicate_connector_check ~pids:[ 42 ] = None)

let test_duplicate_check_fail_when_multiple () =
  match Relay_doctor.duplicate_connector_check ~pids:[ 111; 222; 333 ] with
  | Some c ->
      Alcotest.(check string) "check id" "relay.connector_singleton" c.Relay_doctor.check_id;
      Alcotest.(check bool) "status is FAIL" true (c.Relay_doctor.status = Relay_doctor.Fail);
      Alcotest.(check bool) "has fix command" true (c.Relay_doctor.fix_command <> None)
  | None -> Alcotest.fail "expected duplicate-connector FAIL for 3 pids"

(* B218: is_real_connector_line — classify pgrep "PID cmdline" lines by the
   ACTUAL executable + subcommand, not substring presence. The false-positive
   lines below all embed "c2c relay connect" yet must NOT count as connectors;
   they are exactly what pgrep -af returns on a dev host and what promoted the
   phantom "N connectors running" FAIL. Fails-before / passes-after: against the
   OLD substring logic (`not (contains "--once")` + pid extract), every one of
   the reject cases below returned true → these assertions failed; the new
   classifier makes them pass. *)
let test_is_real_connector_accepts_real () =
  List.iter
    (fun (label, line) ->
      Alcotest.(check bool) label true (Relay_doctor.is_real_connector_line line))
    [ ("bare c2c relay connect", "1001 c2c relay connect");
      ("managed child --all-brokers", "1002 c2c relay connect --all-brokers --broker-root /a/broker");
      ("manual with --relay-url", "1003 c2c relay connect --relay-url https://relay.c2c.im");
      ("absolute c2c path", "1004 /home/agent/.local/bin/c2c relay connect --all-brokers");
      ("c2c.exe", "1005 /opt/c2c/bin/c2c.exe relay connect");
      ("python interpreter runs script",
       "1006 python3 /opt/c2c/scripts/c2c_relay_connector.py --relay-url https://relay.c2c.im");
      ("shebang script direct exec",
       "1007 /opt/c2c/scripts/c2c_relay_connector.py --relay-url https://relay.c2c.im") ]

let test_is_real_connector_rejects_false_positives () =
  List.iter
    (fun (label, line) ->
      Alcotest.(check bool) label false (Relay_doctor.is_real_connector_line line))
    [ (* the sh -c wrapper Unix.open_process_in spawns to run the pgrep pipe *)
      ("sh -c pgrep wrapper", "2001 sh -c pgrep -af 'c2c relay connect' 2>/dev/null");
      ("bash -c pgrep wrapper", "2002 bash -c pgrep -af 'c2c relay connect'");
      (* bug-report / editor shell whose argv only quotes the string *)
      ("bash -c bl bug body",
       "2003 bash -c bl bug --title x --body \"repro: c2c relay connect dies\"");
      ("bl bug direct (quoted body)",
       "2004 bl bug --body \"...c2c relay connect false-positive...\"");
      ("grep the pattern", "2005 grep c2c relay connect");
      ("pgrep the pattern", "2006 pgrep -af c2c relay connect");
      (* c2c's OWN doctor process — subcommand is `doctor`, not `relay connect` *)
      ("c2c doctor --relay itself", "2007 c2c doctor --relay");
      ("c2c doctor json", "2008 /home/agent/.local/bin/c2c doctor --relay --json");
      (* --once transient sync is not a persistent connector *)
      ("c2c relay connect --once", "2009 c2c relay connect --once --broker-root /b/broker");
      (* editor/pager holding a file that mentions the pattern *)
      ("editor with file arg", "2010 vim /home/agent/notes/c2c-relay-connect.md");
      (* non-integer leading token → not a pgrep PID line *)
      ("garbage line", "not-a-pid c2c relay connect") ]

(* Zero real connectors among a realistic pgrep dump ⇒ no duplicate FAIL. *)
let test_zero_real_connectors_no_false_fail () =
  let noise =
    [ "3001 sh -c pgrep -af 'c2c relay connect' 2>/dev/null";
      "3002 bash -c bl bug --body \"...c2c relay connect...\"";
      "3003 grep c2c relay connect";
      "3004 c2c doctor --relay" ]
  in
  let pids = Relay_doctor.persistent_connector_pids noise in
  Alcotest.(check (list int)) "zero real connectors → no pids" [] pids;
  Alcotest.(check bool) "zero connectors → duplicate check None" true
    (Relay_doctor.duplicate_connector_check ~pids = None)

(* Exactly N real connectors ⇒ exactly N pids, false positives filtered out. *)
let test_counts_real_connectors_only () =
  let mixed =
    [ "4001 c2c relay connect --all-brokers";                       (* real *)
      "4002 c2c relay connect --relay-url https://relay.c2c.im";    (* real *)
      "4003 sh -c pgrep -af 'c2c relay connect'";                   (* wrapper *)
      "4004 grep c2c relay connect";                                (* grep *)
      "4005 c2c doctor --relay";                                    (* self *)
      "4006 c2c relay connect --once" ]                             (* transient *)
  in
  let pids = Relay_doctor.persistent_connector_pids mixed in
  Alcotest.(check (list int)) "only the two real persistent connectors counted"
    [ 4001; 4002 ] pids;
  (match Relay_doctor.duplicate_connector_check ~pids with
   | Some c -> Alcotest.(check bool) "2 real connectors → FAIL" true
                 (c.Relay_doctor.status = Relay_doctor.Fail)
   | None -> Alcotest.fail "expected FAIL for 2 real connectors")

(* scope_connector_lines must also reject substring-only lines that happen to
   mention the broker root (e.g. a bug-report shell quoting the broker path). *)
let test_scope_rejects_substring_only_broker_mention () =
  let broker = "/home/agent/.c2c/repos/cccc3333/broker" in
  let lines =
    [ Printf.sprintf "5001 bash -c bl bug --body \"c2c relay connect wedged under %s\"" broker;
      Printf.sprintf "5002 c2c relay connect --broker-root %s" broker ]
  in
  let scoped = Relay_doctor.scope_connector_lines ~broker_root:broker lines in
  Alcotest.(check int) "only the real connector for this broker is scoped" 1
    (List.length scoped)

let () =
  Alcotest.run "c2c_doctor_capabilities"
    [ ( "B210 duplicate-connector",
        [ Alcotest.test_case "persistent pids dedup + --once excluded" `Quick
            test_persistent_pids_dedup_and_once_excluded;
          Alcotest.test_case "None when 0/1 connector" `Quick
            test_duplicate_check_none_when_singleton;
          Alcotest.test_case ">1 connector → FAIL+fix" `Quick
            test_duplicate_check_fail_when_multiple ] );
      ( "B218 connector-line classifier",
        [ Alcotest.test_case "accepts real OCaml + Python connectors" `Quick
            test_is_real_connector_accepts_real;
          Alcotest.test_case "rejects wrappers/grep/self/quoted-arg" `Quick
            test_is_real_connector_rejects_false_positives;
          Alcotest.test_case "zero real connectors → no false FAIL" `Quick
            test_zero_real_connectors_no_false_fail;
          Alcotest.test_case "counts real connectors only" `Quick
            test_counts_real_connectors_only;
          Alcotest.test_case "scope rejects substring-only broker mention" `Quick
            test_scope_rejects_substring_only_broker_mention ] );
      ( "capabilities-scheme",
        [ Alcotest.test_case "https subscribe=yes poll=yes" `Quick test_https_subscribe_yes_poll_yes;
          Alcotest.test_case "wss subscribe=yes" `Quick test_wss_subscribe_yes;
          Alcotest.test_case "http subscribe=yes" `Quick test_http_subscribe_yes;
          Alcotest.test_case "ws subscribe=yes" `Quick test_ws_subscribe_yes;
          Alcotest.test_case "unreachable all=no" `Quick test_unreachable_all_no;
          Alcotest.test_case "message shape" `Quick test_capabilities_message_shape ] );
      ( "actual-attempt-parity",
        [ Alcotest.test_case "doctor cap == subscribe guard predicate" `Quick test_actual_attempt_parity ] );
      ( "capabilities-check",
        [ Alcotest.test_case "id/status/fix" `Quick test_capabilities_check_pass_and_fix ] );
      ( "connector-scoping",
        [ Alcotest.test_case "keeps own broker" `Quick test_scope_keeps_own_broker;
          Alcotest.test_case "drops unrelated connector" `Quick test_scope_drops_unrelated_connector;
          Alcotest.test_case "empty/unresolved broker" `Quick test_scope_empty_or_unresolved_broker;
          Alcotest.test_case "connector_running signal" `Quick test_connector_running_signal ] );
      ( "connector-check",
        [ Alcotest.test_case "no proc no state → FAIL" `Quick test_connector_check_no_proc_no_state;
          Alcotest.test_case "stale state → FAIL" `Quick test_connector_check_stale_state;
          Alcotest.test_case "fresh state no proc → PASS (B1)" `Quick test_connector_check_fresh_state_no_proc;
          Alcotest.test_case "production argv no broker-root → PASS (B1)" `Quick test_connector_check_production_argv_no_broker_root;
          Alcotest.test_case "proc no state → Inconclusive" `Quick test_connector_check_proc_no_state;
          Alcotest.test_case "proc + stale → wedged FAIL (B181)" `Quick test_connector_check_proc_wedged;
          Alcotest.test_case "proc stale last_ok → FAIL+fix" `Quick test_connector_check_proc_recent_error;
          Alcotest.test_case "live last_ok + recent err → FAIL+fix" `Quick test_connector_check_live_with_recent_error;
          Alcotest.test_case "proc healthy → PASS" `Quick test_connector_check_proc_healthy;
          Alcotest.test_case "every FAIL has a fix" `Quick test_every_fail_has_fix ] );
      ( "capabilities-connector-coherence",
        [ Alcotest.test_case "connect=yes ⇒ connector_check agrees (B1)" `Quick test_capabilities_connector_coherence ] );
      ( "docs-link",
        [ Alcotest.test_case "docs link target" `Quick test_docs_link_target ] );
      ( "public-smoke",
        [ Alcotest.test_case "public read-only smoke (env-gated)" `Quick test_public_smoke ] );
    ]
