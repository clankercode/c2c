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
  mutable degraded_events : bool list;       (* on_degraded calls, in order *)
  clock : float ref;
}

let mk_harness ?(steps = []) () =
  { steps; registers = 0; deregisters = 0; passes = 0;
    degraded_events = []; clock = ref 0.0 }

let mk_deps ?(discover = fun () -> [ "thread-1" ]) ?(max_wall_s = infinity)
    ?(broker_root = temp_broker_root ()) (h : harness) : DL.deps =
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
    is_dnd = (fun () -> false);
    register = (fun () -> h.registers <- h.registers + 1);
    deregister = (fun () -> h.deregisters <- h.deregisters + 1);
    on_pass = (fun _ -> h.passes <- h.passes + 1);
    on_degraded = (fun b -> h.degraded_events <- h.degraded_events @ [ b ]);
    now = (fun () -> !(h.clock));
    sleep = (fun s -> h.clock := !(h.clock) +. s);
    poll_interval_s = 1.0;
    discover_interval_s = 0.0;   (* attempt discovery every idle poll *)
    max_wall_s }

(* ------------------------------------------------------------------ *)

let test_start_on_attach_and_drive () =
  let h = { steps = [ Ep.Sv_running; Ep.Sv_running; Ep.Sv_running; Ep.Sv_frontend_exited ];
            registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
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
  let h = { steps = [ Ep.Sv_frontend_exited ];
            registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
  let o = DL.run (mk_deps h) in
  Alcotest.(check int) "registered" 1 h.registers;
  Alcotest.(check int) "deregistered on exit" 1 h.deregisters;
  Alcotest.(check int) "no delivery passes" 0 o.DL.passes;
  Alcotest.(check (option string)) "never discovered a thread" None o.DL.thread_id;
  Alcotest.(check bool) "degraded (no thread this session)" true o.DL.degraded;
  Alcotest.(check bool) "final is terminal" true (o.DL.final = Ep.Sv_frontend_exited)

let test_server_death_terminal () =
  let h = { steps = [ Ep.Sv_running; Ep.Sv_server_died ];
            registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
  let o = DL.run (mk_deps h) in
  Alcotest.(check bool) "server death is terminal" true (o.DL.final = Ep.Sv_server_died);
  Alcotest.(check int) "deregistered" 1 h.deregisters;
  Alcotest.(check int) "one pass before death" 1 o.DL.passes

let test_degraded_no_thread () =
  (* Frontend never loads a thread: keep supervising, never deliver, mark
     degraded. The session is still reaped on exit. *)
  let h = { steps = [ Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ];
            registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
  let o = DL.run (mk_deps ~discover:(fun () -> []) h) in
  Alcotest.(check (option string)) "no thread discovered" None o.DL.thread_id;
  Alcotest.(check bool) "degraded" true o.DL.degraded;
  Alcotest.(check int) "no delivery passes without a thread" 0 o.DL.passes;
  Alcotest.(check int) "still deregistered cleanly" 1 h.deregisters;
  Alcotest.(check bool) "final terminal (offline)" true (o.DL.final = Ep.Sv_offline)

let test_max_wall_bound () =
  (* An always-running supervisor must still return under the wall-clock bound
     (sleep advances the fake clock), deregistering cleanly. *)
  let h = { steps = []; registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
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
  let h = { steps = [ Ep.Sv_running; Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ];
            registers = 0; deregisters = 0; passes = 0; degraded_events = []; clock = ref 0.0 } in
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
    [ true; false ] h.degraded_events

let test_on_degraded_stays_degraded_no_thread () =
  (* B138: a session that never loads a thread fires [true] once and never
     flips — the persisted signal stays degraded. *)
  let h = mk_harness ~steps:[ Ep.Sv_running; Ep.Sv_running; Ep.Sv_offline ] () in
  let _ = DL.run (mk_deps ~discover:(fun () -> []) h) in
  Alcotest.(check (list bool)) "only the initial degraded=true, never healthy"
    [ true ] h.degraded_events

let () =
  let open Alcotest in
  run "c2c_codex_deliver_loop"
    [ ( "lifecycle",
        [ test_case "start on attach + drive while running" `Quick test_start_on_attach_and_drive
        ; test_case "stop on immediate frontend exit" `Quick test_stop_on_immediate_exit
        ; test_case "server death is terminal" `Quick test_server_death_terminal
        ; test_case "degraded when no thread loaded" `Quick test_degraded_no_thread
        ; test_case "wall-clock bound returns + deregisters" `Quick test_max_wall_bound
        ; test_case "discovery stops after found" `Quick test_discover_throttle_reused_after_found
        ; test_case "on_degraded transitions true->false on thread load" `Quick test_on_degraded_transition_healthy
        ; test_case "on_degraded stays true when no thread loads" `Quick test_on_degraded_stays_degraded_no_thread ] )
    ]
