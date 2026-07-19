(* Tests for C2c_codex_deliver_loop (B131): the lifecycle-bound supervisor loop
   that drives T003 ingress + T007 auto-turn against a live app-server session.

   Fully scripted — NO live socket, NO real broker interaction beyond a throwaway
   temp broker root (the injected inject/turn clients never touch a socket, and
   an empty inbox means deliver_pass is a no-op file operation). These tests
   assert the LOOP behavior only (start-on-attach, drive-while-running,
   stop-on-exit, deregister-once, degraded-on-no-thread, wall-clock bound) — the
   T003/T007 gates are covered by their own suites and are NOT re-tested here. *)

module DL = C2c_codex_deliver_loop
module Ep = C2c_codex_app_server
module Ing = C2c_codex_ingress
module AT = C2c_codex_autoturn

let temp_broker_root () =
  let d = Filename.temp_file "c2c-deliver-loop-test" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  d

let fake_endpoint : Ep.endpoint = { transport = "ws"; host = "127.0.0.1"; port = 1 }

(* No-op inject/turn clients — never invoked when the inbox is empty, but present
   so the config is well-formed. *)
let noop_inject_client : Ing.client =
  { inject_items = (fun ~endpoint:_ ~token:_ ~thread_id:_ ~message_id:_ ~items:_ -> Ing.Inj_ok);
    history_contains = None }

let noop_turn_client : AT.turn_client =
  { thread_status = (fun ~endpoint:_ ~token:_ ~thread_id:_ -> `Idle);
    start_turn = (fun ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key:_ ~items:_ ->
        AT.Turn_started "turn-fake");
    turn_in_history = None }

type harness = {
  mutable steps : Ep.supervise_result list;  (* consumed front-to-back *)
  mutable registers : int;
  mutable deregisters : int;
  mutable passes : int;
  mutable global_pass_events : Ing.health list;  (* on_global_pass calls *)
  (* on_degraded calls, in order: (degraded, binding_refused) *)
  mutable degraded_events : (bool * bool) list;
  clock : float ref;
}

let mk_harness ?(steps = []) () =
  { steps; registers = 0; deregisters = 0; passes = 0;
    global_pass_events = []; degraded_events = []; clock = ref 0.0 }

let mk_deps ?(discover = fun () -> [ "thread-1" ]) ?(max_wall_s = infinity)
    ?(broker_root = temp_broker_root ()) ?(global_broker_root = None)
    ?(is_dnd = fun () -> false) ?(on_thread_discovered = fun _ -> true)
    ?(restart_requested = fun ~thread_id:_ -> None)
    (h : harness) : DL.deps =
  { broker_root;
    session_id = "deliver-loop-test-sess";
    managed_identity = "deliver-loop-test-alias";
    endpoint = fake_endpoint;
    token_provider = (fun () -> Some "tok");
    inject_client = noop_inject_client;
    turn_client = noop_turn_client;
    discover_threads = discover;
    supervise_step =
      (fun () ->
        match h.steps with
        | x :: rest -> h.steps <- rest; x
        | [] -> Ep.Sv_frontend_exited);
    session_active = (fun () -> true);
    is_dnd;
    register = (fun () -> h.registers <- h.registers + 1);
    deregister = (fun () -> h.deregisters <- h.deregisters + 1);
    on_pass = (fun _ -> h.passes <- h.passes + 1);
    on_degraded =
      (fun ~degraded ~binding_refused ->
        h.degraded_events <- h.degraded_events @ [ (degraded, binding_refused) ]);
    on_thread_discovered;
    restart_requested;
    global_broker_root;
    on_global_pass = (fun gh -> h.global_pass_events <- h.global_pass_events @ [ gh ]);
    now = (fun () -> !(h.clock));
    sleep = (fun s -> h.clock := !(h.clock) +. s);
    poll_interval_s = 1.0;
    discover_interval_s = 0.0;   (* attempt discovery every idle poll *)
    max_wall_s }

(* Just the degraded flags, in order — for assertions that do not care about
   the #31 reason discriminator. *)
let degraded_flags (h : harness) = List.map fst h.degraded_events

(* ------------------------------------------------------------------ *)

let test_b168_default_stale_threshold_on_autoturn_config () =
  (* B168: the production loop must inherit the 2-minute stale-inbox SLA on
     both the T003 inject config and the T007 auto-turn config. *)
  let h = mk_harness () in
  let d = mk_deps h in
  let at = DL.build_autoturn_config d ~thread_id:"thread-1" in
  Alcotest.(check (float 1e-6)) "autoturn stale threshold = 120s"
    120.0 at.AT.stale_inbox_threshold_s;
  Alcotest.(check (float 1e-6)) "ingress stale-pending threshold = 120s"
    120.0 at.AT.ingress_cfg.Ing.stale_pending_threshold_s;
  Alcotest.(check (float 1e-6)) "autoturn default constant"
    AT.default_stale_inbox_threshold_s 120.0;
  Alcotest.(check (float 1e-6)) "ingress default constant"
    Ing.default_stale_pending_threshold_s 120.0

let test_start_on_attach_and_drive () =
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let o = DL.run (mk_deps h) in
  Alcotest.(check int) "registered exactly once" 1 h.registers;
  Alcotest.(check int) "deregistered exactly once" 1 h.deregisters;
  Alcotest.(check (option string)) "drove the discovered thread" (Some "thread-1") o.DL.thread_id;
  Alcotest.(check bool) "not degraded (thread found)" false o.DL.degraded;
  Alcotest.(check int) "ran one deliver pass per running step" 3 o.DL.passes;
  Alcotest.(check int) "on_pass fired per pass" 3 h.passes;
  Alcotest.(check bool) "final is the terminal frontend-exit" true
    (o.DL.final = Ep.Sv_frontend_exited)

let test_stop_on_immediate_exit () =
  (* Frontend already exited: loop returns on the first step, having registered
     and (in the finally) deregistered — no orphaned loop. *)
  let h = mk_harness ~steps:[ Ep.Sv_frontend_exited ] () in
  let o = DL.run (mk_deps h) in
  Alcotest.(check int) "registered" 1 h.registers;
  Alcotest.(check int) "deregistered on exit" 1 h.deregisters;
  Alcotest.(check int) "no delivery passes" 0 o.DL.passes;
  Alcotest.(check (option string)) "never discovered a thread" None o.DL.thread_id;
  Alcotest.(check bool) "degraded (no thread this session)" true o.DL.degraded;
  Alcotest.(check bool) "final is terminal" true (o.DL.final = Ep.Sv_frontend_exited)

let test_server_death_terminal () =
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_server_died ] () in
  let o = DL.run (mk_deps h) in
  Alcotest.(check bool) "server death is terminal" true (o.DL.final = Ep.Sv_server_died);
  Alcotest.(check int) "deregistered" 1 h.deregisters;
  Alcotest.(check int) "one pass before death" 1 o.DL.passes

let test_discovery_persists_then_restart_before_delivery () =
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running ] () in
  let discovered = ref [] in
  let o =
    DL.run
      (mk_deps
         ~on_thread_discovered:(fun tid -> discovered := tid :: !discovered; true)
         ~restart_requested:(fun ~thread_id ->
           if thread_id = "thread-1" then Some "/resolved/c2c" else None) h)
  in
  Alcotest.(check (list string)) "thread callback exactly once"
    [ "thread-1" ] (List.rev !discovered);
  Alcotest.(check (option string)) "restart executable returned"
    (Some "/resolved/c2c") o.DL.restart_executable;
  Alcotest.(check int) "restart happens before another ingress pass" 0 o.DL.passes;
  Alcotest.(check int) "deregistered once" 1 h.deregisters

let test_degraded_no_thread () =
  (* Frontend never loads a thread: keep supervising, never deliver, mark
     degraded. The session is still reaped on exit. *)
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ] () in
  let o = DL.run (mk_deps ~discover:(fun () -> []) h) in
  Alcotest.(check (option string)) "no thread discovered" None o.DL.thread_id;
  Alcotest.(check bool) "degraded" true o.DL.degraded;
  Alcotest.(check int) "no delivery passes without a thread" 0 o.DL.passes;
  Alcotest.(check int) "still deregistered cleanly" 1 h.deregisters;
  Alcotest.(check bool) "final terminal (offline)" true (o.DL.final = Ep.Sv_offline)

let test_max_wall_bound () =
  (* An always-running supervisor must still return under the wall-clock bound
     (sleep advances the fake clock), deregistering cleanly. *)
  let h = mk_harness () in
  (* steps=[] means supervise_step returns Sv_frontend_exited by default — force
     an always-running supervisor via a custom step fn. *)
  let broker_root = temp_broker_root () in
  let base = mk_deps ~broker_root ~max_wall_s:3.0 h in
  let deps = { base with DL.supervise_step = (fun () -> Ep.Sv_running) } in
  let o = DL.run deps in
  Alcotest.(check bool) "bounded exit reports offline" true (o.DL.final = Ep.Sv_offline);
  Alcotest.(check int) "deregistered on wall-clock exit" 1 h.deregisters;
  Alcotest.(check bool) "clock advanced past the wall bound" true (!(h.clock) >= 3.0)

let test_discover_throttle_reused_after_found () =
  (* Once a thread is discovered, discovery is not attempted again (the loop
     stops probing thread/loaded/list). *)
  let discover_calls = ref 0 in
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ] () in
  let base = mk_deps h in
  let deps = { base with DL.discover_threads =
      (fun () -> incr discover_calls; [ "thread-x" ]) } in
  let o = DL.run deps in
  Alcotest.(check (option string)) "found thread" (Some "thread-x") o.DL.thread_id;
  Alcotest.(check int) "discovery attempted exactly once (stops after found)" 1 !discover_calls

let test_on_degraded_transition_healthy () =
  (* B138: on_degraded is fired [true] at loop start and flipped to [false] the
     moment a thread is discovered — exactly one healthy transition. *)
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let _ = DL.run (mk_deps h) in
  Alcotest.(check (list bool)) "degraded true at start, then false on thread load"
    [ true; false ] (degraded_flags h);
  Alcotest.(check bool) "no stamp claims a refused binding" false
    (List.exists snd h.degraded_events)

let test_on_degraded_stays_degraded_no_thread () =
  (* B138: a session that never loads a thread fires [true] once and never
     flips — the persisted signal stays degraded. *)
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ] () in
  let _ = DL.run (mk_deps ~discover:(fun () -> []) h) in
  Alcotest.(check (list bool)) "only the initial degraded=true, never healthy"
    [ true ] (degraded_flags h);
  Alcotest.(check (list (pair bool bool)))
    "the no-thread degradation is NOT reported as a refused binding"
    [ (true, false) ] h.degraded_events

let test_heartbeat_restamps_while_alive () =
  (* #27: while the loop is alive it re-stamps the degraded signal on a
     throttle (~heartbeat_interval_s) so the persisted heartbeat advances and a
     reader can tell a live loop from a dead one. With a thread loaded, the
     re-stamps carry the CURRENT (healthy) state. The fake clock advances 1s per
     poll; heartbeat_interval_s = 10, so after 25 running polls (clock 0..24) two
     heartbeats fire (at clock 10 and 20) on top of the two start/thread-load
     transitions. Semantics are unchanged — only [updated_at] advances. *)
  Alcotest.(check (float 1e-6)) "heartbeat throttle is 10s"
    10.0 DL.heartbeat_interval_s;
  let steps = List.init 25 (fun _ -> Ep.Sv_running) in
  let h = mk_harness ~steps () in
  let _ = DL.run (mk_deps h) in
  Alcotest.(check (list bool))
    "start=true, thread-load=false, then healthy heartbeats re-stamp false"
    [ true; false; false; false ] (degraded_flags h)

let test_i31_refused_binding_latches_degraded () =
  (* #31: [on_thread_discovered] returning FALSE means the #24 guard refused to
     mint a duplicate thread binding (a live managed sibling owns the thread).
     The unit is running without a binding — genuinely degraded — so the
     discovery stamp must stay [true] and the #27 heartbeats must re-stamp the
     LATCHED value, never flipping back to healthy. 25 running polls => two
     heartbeats (clock 10 and 20) on top of the start/discovery stamps. *)
  let steps = List.init 25 (fun _ -> Ep.Sv_running) in
  let h = mk_harness ~steps () in
  let o = DL.run (mk_deps ~on_thread_discovered:(fun _ -> false) h) in
  Alcotest.(check (option string)) "thread was still discovered/driven"
    (Some "thread-1") o.DL.thread_id;
  Alcotest.(check (list bool))
    "degraded latched true through discovery and every heartbeat"
    [ true; true; true; true ] (degraded_flags h);
  Alcotest.(check bool) "never re-stamped healthy" false
    (List.exists (fun (b, _) -> b = false) h.degraded_events);
  (* #31 nit 1: every stamp AFTER discovery must carry the binding-refused
     reason, so doctor/health can offer the followable remediation. The initial
     start stamp predates discovery and is honestly [no-thread]. *)
  Alcotest.(check (list (pair bool bool)))
    "discovery + heartbeats report the refusal reason; the start stamp does not"
    [ (true, false); (true, true); (true, true); (true, true) ]
    h.degraded_events;
  Alcotest.(check bool) "outcome reports degraded" true o.DL.degraded;
  Alcotest.(check bool) "outcome attributes it to the refused binding" true
    o.DL.binding_refused

let test_i31_persisted_binding_clears_degraded () =
  (* #31 converse: a SUCCESSFUL persist latches healthy — unchanged behaviour. *)
  let steps = List.init 25 (fun _ -> Ep.Sv_running) in
  let h = mk_harness ~steps () in
  let o = DL.run (mk_deps ~on_thread_discovered:(fun _ -> true) h) in
  Alcotest.(check (list bool)) "healthy after a persisted binding"
    [ true; false; false; false ] (degraded_flags h);
  Alcotest.(check bool) "no stamp claims a refused binding" false
    (List.exists snd h.degraded_events);
  Alcotest.(check bool) "outcome not degraded" false o.DL.degraded;
  Alcotest.(check bool) "outcome not binding-refused" false o.DL.binding_refused

let test_i31_discovery_callback_raising_fails_closed () =
  (* #31: an exception from [on_thread_discovered] is an UNKNOWN binding state;
     fail closed to degraded rather than claiming health, and never wedge the
     supervisor. *)
  let steps = List.init 12 (fun _ -> Ep.Sv_running) in
  let h = mk_harness ~steps () in
  let o = DL.run (mk_deps ~on_thread_discovered:(fun _ -> failwith "boom") h) in
  Alcotest.(check bool) "loop survived the raising callback" true
    (o.DL.final = Ep.Sv_frontend_exited);
  Alcotest.(check bool) "outcome degraded (fail-closed)" true o.DL.degraded;
  Alcotest.(check bool) "no healthy stamp" false
    (List.exists (fun (b, _) -> b = false) h.degraded_events)

(* ------------------------- B141: global (cross-repo) inbox ------------------------- *)

let mk_msg ?(from = "cross-repo-peer") ?message_id content : C2c_mcp.message =
  { from_alias = from; to_alias = "deliver-loop-test-alias"; content;
    deferrable = false; reply_via = None; enc_status = None; ts = 1000.0;
    ephemeral = false; message_id; pow_difficulty = None }

let seed_global_inbox ~root msgs =
  let b = C2c_mcp.Broker.create ~root in
  C2c_mcp.Broker.save_inbox b ~session_id:"deliver-loop-test-sess" msgs

let read_global_inbox ~root =
  let b = C2c_mcp.Broker.create ~root in
  C2c_mcp.Broker.read_inbox b ~session_id:"deliver-loop-test-sess"

(* Recording inject client: captures (thread, message_id) per inject. *)
let recording_inject_client () =
  let calls = ref [] in
  ( { Ing.inject_items =
        (fun ~endpoint:_ ~token:_ ~thread_id ~message_id ~items:_ ->
          calls := (thread_id, message_id) :: !calls;
          Ing.Inj_ok);
      history_contains = None },
    calls )

let test_global_inbox_injected_no_turn () =
  (* Cross-repo mail in the sessions-broker inbox is injected into the attached
     thread (arrival-time model-visibility) but NEVER starts a turn, and is
     never drained from the inbox. *)
  let groot = temp_broker_root () in
  seed_global_inbox ~root:groot [ mk_msg ~message_id:"gm-1" "cross-repo hello" ];
  let inject_client, calls = recording_inject_client () in
  let turns = ref 0 in
  let turn_client =
    { AT.thread_status = (fun ~endpoint:_ ~token:_ ~thread_id:_ -> `Idle);
      start_turn =
        (fun ~endpoint:_ ~token:_ ~thread_id:_ ~batch_key:_ ~items:_ ->
          incr turns; AT.Turn_started "turn-x");
      turn_in_history = None }
  in
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let base = mk_deps ~global_broker_root:(Some groot) h in
  let deps = { base with DL.inject_client; turn_client } in
  let o = DL.run deps in
  Alcotest.(check bool) "global pass ran" true (o.DL.global_passes > 0);
  Alcotest.(check bool) "on_global_pass fired" true (h.global_pass_events <> []);
  Alcotest.(check bool) "injected the cross-repo message into the thread" true
    (List.exists (fun (t, _) -> t = "thread-1") !calls);
  Alcotest.(check int) "exactly one injection (ledger dedupes across passes)" 1
    (List.length !calls);
  Alcotest.(check int) "cross-repo mail never starts a turn" 0 !turns;
  Alcotest.(check int) "never drained from the global inbox" 1
    (List.length (read_global_inbox ~root:groot))

let test_global_none_disables () =
  (* global_broker_root = None → no global pass, even with running steps. *)
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let o = DL.run (mk_deps h) in
  Alcotest.(check int) "no global passes when unset" 0 o.DL.global_passes;
  Alcotest.(check bool) "no global sink events" true (h.global_pass_events = [])

let test_global_no_inbox_file_no_artifacts () =
  (* A configured root whose inbox file does not exist: the loop must not run a
     global pass NOR create broker artifacts in the sessions root. *)
  let groot = temp_broker_root () in
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let o = DL.run (mk_deps ~global_broker_root:(Some groot) h) in
  Alcotest.(check int) "no global passes without an inbox file" 0 o.DL.global_passes;
  Alcotest.(check bool) "no inbox file created as a side effect" false
    (Sys.file_exists (Filename.concat groot "deliver-loop-test-sess.inbox.json"))

let test_global_respects_dnd () =
  (* DND on: the global pass is skipped (fail-closed, same as the T007 gate);
     mail stays durably queued. *)
  let groot = temp_broker_root () in
  seed_global_inbox ~root:groot [ mk_msg ~message_id:"gm-dnd" "held by dnd" ];
  let inject_client, calls = recording_inject_client () in
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ] () in
  let base = mk_deps ~global_broker_root:(Some groot) ~is_dnd:(fun () -> true) h in
  let deps = { base with DL.inject_client } in
  let o = DL.run deps in
  Alcotest.(check int) "no global passes under DND" 0 o.DL.global_passes;
  Alcotest.(check int) "nothing injected under DND" 0 (List.length !calls);
  Alcotest.(check int) "mail still queued" 1
    (List.length (read_global_inbox ~root:groot))

let test_build_global_ingress_config () =
  let h = mk_harness () in
  let deps_none = mk_deps h in
  Alcotest.(check bool) "None root -> no config" true
    (DL.build_global_ingress_config deps_none ~thread_id:"t" = None);
  let groot = temp_broker_root () in
  let deps_some = mk_deps ~global_broker_root:(Some groot) h in
  match DL.build_global_ingress_config deps_some ~thread_id:"t-42" with
  | None -> Alcotest.fail "expected Some config for a set global root"
  | Some cfg ->
      Alcotest.(check string) "config targets the sessions root" groot
        cfg.Ing.broker_root;
      Alcotest.(check string) "same session key" "deliver-loop-test-sess"
        cfg.Ing.session_id;
      Alcotest.(check string) "same thread" "t-42" cfg.Ing.thread_id

let () =
  let open Alcotest in
  run "c2c_codex_deliver_loop"
    [ ( "lifecycle",
        [ test_case "start on attach + drive while running" `Quick test_start_on_attach_and_drive
        ; test_case "stop on immediate frontend exit" `Quick test_stop_on_immediate_exit
        ; test_case "server death is terminal" `Quick test_server_death_terminal
        ; test_case "persist discovery then restart before delivery" `Quick test_discovery_persists_then_restart_before_delivery
        ; test_case "degraded when no thread loaded" `Quick test_degraded_no_thread
        ; test_case "wall-clock bound returns + deregisters" `Quick test_max_wall_bound
        ; test_case "discovery stops after found" `Quick test_discover_throttle_reused_after_found
        ; test_case "on_degraded transitions true->false on thread load" `Quick test_on_degraded_transition_healthy
        ; test_case "on_degraded stays true when no thread loads" `Quick test_on_degraded_stays_degraded_no_thread
        ; test_case "heartbeat re-stamps degraded signal while alive (#27)" `Quick test_heartbeat_restamps_while_alive
        ; test_case "refused thread binding latches degraded across heartbeats (#31)" `Quick test_i31_refused_binding_latches_degraded
        ; test_case "persisted thread binding clears degraded (#31)" `Quick test_i31_persisted_binding_clears_degraded
        ; test_case "raising discovery callback fails closed to degraded (#31)" `Quick test_i31_discovery_callback_raising_fails_closed ] )
    ; ( "global-inbox (B141)",
        [ test_case "cross-repo mail injected, no turn, never drained" `Quick test_global_inbox_injected_no_turn
        ; test_case "None root disables global delivery" `Quick test_global_none_disables
        ; test_case "no inbox file: no pass, no artifacts" `Quick test_global_no_inbox_file_no_artifacts
        ; test_case "DND skips the global pass" `Quick test_global_respects_dnd
        ; test_case "build_global_ingress_config shape" `Quick test_build_global_ingress_config ] )
    ; ( "b168-stale-sla",
        [ test_case "default stale thresholds are 120s" `Quick
            test_b168_default_stale_threshold_on_autoturn_config ] )
    ]
