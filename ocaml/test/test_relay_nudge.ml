(* test_relay_nudge.ml — #335 v1a instrumentation tests.

   Verify that nudge_tick + nudge_session emit structured JSON entries to
   broker.log so OOM-and-resume cycles self-document. Mirrors the shape of
   the #327 send-memory-handoff diagnostic logging. *)

open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-nudge-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    let buf = Buffer.create 256 in
    (try while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done with End_of_file -> ());
    Buffer.contents buf)

let contains haystack needle =
  let nl = String.length needle in
  let hl = String.length haystack in
  let rec scan i = i + nl <= hl
    && (String.sub haystack i nl = needle || scan (i+1))
  in scan 0

(* The default messages baked into relay_nudge.ml. We re-use one for
   substituting into the messages-list directly so tests don't depend on
   the JSON-from-disk loader path. *)
let test_message : Relay_nudge.nudge_message =
  { Relay_nudge.text = "test-nudge-body" }

(* Read /proc/<pid>/stat starttime field (field 22, 0-indexed 19 of post-comm
   tail). Mirrors the private Broker.read_pid_start_time so tests can register
   a row with a matching pid_start_time and exercise the Alive path. *)
let read_starttime pid =
  let path = Printf.sprintf "/proc/%d/stat" pid in
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
        let line = input_line ic in
        match String.rindex_opt line ')' with
        | None -> None
        | Some idx ->
            let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
            let parts = String.split_on_char ' ' tail in
            (match List.nth_opt parts 19 with
             | Some token -> (try Some (int_of_string token) with _ -> None)
             | None -> None))
  with Sys_error _ | End_of_file -> None

(* Helper: register the current process as a live alive_with_pid row. Used by
   v1a tests that under v2a need a real Alive row (pid=None is now Unknown). *)
let register_live_self broker ~session_id ~alias =
  let my_pid = Unix.getpid () in
  let st = read_starttime my_pid in
  C2c_mcp.Broker.register broker ~session_id ~alias
    ~pid:(Some my_pid) ~pid_start_time:st ()

(* AC1 — log_nudge_tick writes a structured event with the right counters
   when the only registration is alive + DND'd. *)
let test_log_nudge_tick_structure () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register one DND-active session so the tick sees alive_total=1,
         skipped_dnd=1, sent=0. Use the current pid + matching start so
         liveness resolves to Alive under v2a. *)
      register_live_self broker ~session_id:"s-dnd" ~alias:"dnd-recipient";
      let _ = C2c_mcp.Broker.set_dnd broker ~session_id:"s-dnd" ~dnd:true () in
      Relay_nudge.nudge_tick
        ~from_session_id:"test-tick-1"
        ~broker
        ~cadence_minutes:30.0
        ~idle_minutes:25.0
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log exists after tick" true (Sys.file_exists log_path);
      let body = read_file log_path in
      check bool "log contains nudge_tick event" true
        (contains body "\"event\":\"nudge_tick\"");
      check bool "log contains from_session_id" true
        (contains body "\"from_session_id\":\"test-tick-1\"");
      check bool "log records alive_total=1" true
        (contains body "\"alive_total\":1");
      check bool "log records skipped_dnd=1" true
        (contains body "\"skipped_dnd\":1");
      check bool "log records sent=0" true
        (contains body "\"sent\":0"))

(* AC2 — log_nudge_enqueue writes one entry per send with to_pid_state.
   Under v2a, only Alive rows reach nudge_session, so this test now uses a
   live pid and asserts to_pid_state=alive_with_pid. The pidless / Lyra-
   Quill-X "alive_no_pid"-skip path is covered by
   test_pidless_registration_skipped below. *)
let test_log_nudge_enqueue_records_pid_state () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      register_live_self broker ~session_id:"s-recv" ~alias:"recv-live";
      C2c_mcp.Broker.touch_session broker ~session_id:"s-recv";
      Relay_nudge.nudge_tick
        ~from_session_id:"test-tick-2"
        ~broker
        ~cadence_minutes:0.05  (* 3 seconds — well under default *)
        ~idle_minutes:0.0      (* zero idle threshold → fire immediately *)
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      let body = read_file log_path in
      check bool "log contains nudge_enqueue event" true
        (contains body "\"event\":\"nudge_enqueue\"");
      check bool "log records to_pid_state=alive_with_pid for live recipient" true
        (contains body "\"to_pid_state\":\"alive_with_pid\"");
      check bool "log records to_alias=recv-live" true
        (contains body "\"to_alias\":\"recv-live\""))

(* AC3 — nudge_tick handles empty registries cleanly: emits one tick log
   line with all counters zero, no enqueue logs, no exceptions. *)
let test_nudge_tick_empty_registry () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      Relay_nudge.nudge_tick
        ~from_session_id:"test-tick-empty"
        ~broker
        ~cadence_minutes:30.0
        ~idle_minutes:25.0
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log exists after empty tick" true (Sys.file_exists log_path);
      let body = read_file log_path in
      check bool "log contains nudge_tick event" true
        (contains body "\"event\":\"nudge_tick\"");
      check bool "alive_total is 0" true (contains body "\"alive_total\":0");
      check bool "sent is 0" true (contains body "\"sent\":0");
      check bool "no nudge_enqueue line written" false
        (contains body "\"event\":\"nudge_enqueue\""))

(* #335 v2a — pidless / unknown / dead registrations skip nudge. *)

(* AC1 — pidless registration (pid=None) is skipped, alive_no_pid increments,
   no nudge_enqueue line is emitted. Under v2a, pid=None resolves to
   liveness_state Unknown, which the nudge_tick match arm only counts. *)
let test_pidless_registration_skipped () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-noid" ~alias:"pidless-zombie"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.touch_session broker ~session_id:"s-noid";
      Relay_nudge.nudge_tick
        ~from_session_id:"test-v2a-ac1"
        ~broker
        ~cadence_minutes:0.05
        ~idle_minutes:0.0
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      let body = read_file log_path in
      check bool "no nudge_enqueue line for pidless alias" false
        (contains body "\"to_alias\":\"pidless-zombie\"");
      check bool "tick log records alive_no_pid=1" true
        (contains body "\"alive_no_pid\":1");
      check bool "tick log records sent=0" true
        (contains body "\"sent\":0"))

(* AC2a — pid set to a likely-dead pid (very high number) → liveness Dead →
   skipped, no enqueue, alive_total=0, alive_no_pid=0. *)
let test_dead_pid_registration_skipped () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead_pid = 999999 in
      C2c_mcp.Broker.register broker ~session_id:"s-dead" ~alias:"dead-pid-row"
        ~pid:(Some dead_pid) ~pid_start_time:(Some 12345) ();
      C2c_mcp.Broker.touch_session broker ~session_id:"s-dead";
      Relay_nudge.nudge_tick
        ~from_session_id:"test-v2a-ac2a"
        ~broker
        ~cadence_minutes:0.05
        ~idle_minutes:0.0
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      let body = read_file log_path in
      check bool "no nudge_enqueue line for dead-pid alias" false
        (contains body "\"to_alias\":\"dead-pid-row\"");
      check bool "tick log records alive_total=0" true
        (contains body "\"alive_total\":0");
      check bool "tick log records alive_no_pid=0" true
        (contains body "\"alive_no_pid\":0"))

(* AC2b — pid set to current process pid, but pid_start_time deliberately
   wrong (0). Liveness check reads /proc/<pid>/stat, finds a real starttime,
   compares to stored 0, returns Dead (mismatch). The row should be skipped
   and not increment alive_no_pid (it has a pid). *)
let test_unknown_pid_registration_skipped () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let my_pid = Unix.getpid () in
      C2c_mcp.Broker.register broker ~session_id:"s-mismatch" ~alias:"mismatch-row"
        ~pid:(Some my_pid) ~pid_start_time:(Some 0) ();
      C2c_mcp.Broker.touch_session broker ~session_id:"s-mismatch";
      Relay_nudge.nudge_tick
        ~from_session_id:"test-v2a-ac2b"
        ~broker
        ~cadence_minutes:0.05
        ~idle_minutes:0.0
        ~messages:[ test_message ]
        ();
      let log_path = Filename.concat dir "broker.log" in
      let body = read_file log_path in
      check bool "no nudge_enqueue line for mismatched-start row" false
        (contains body "\"to_alias\":\"mismatch-row\"");
      check bool "tick log records alive_no_pid=0 (pid was set)" true
        (contains body "\"alive_no_pid\":0"))

(* AC3 — alive registration with current pid + matching start time, idle, not
   DND, fires exactly one nudge_enqueue line with to_pid_state=alive_with_pid. *)
let test_alive_with_pid_eligible () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let my_pid = Unix.getpid () in
      let starttime = read_starttime my_pid in
      (* Skip the test gracefully if we can't read /proc/self/stat (non-Linux). *)
      (match starttime with
       | None ->
           check bool "skipped (no /proc starttime available)" true true
       | Some st ->
           C2c_mcp.Broker.register broker ~session_id:"s-alive" ~alias:"alive-with-pid-row"
             ~pid:(Some my_pid) ~pid_start_time:(Some st) ();
           C2c_mcp.Broker.touch_session broker ~session_id:"s-alive";
           Relay_nudge.nudge_tick
             ~from_session_id:"test-v2a-ac3"
             ~broker
             ~cadence_minutes:0.05
             ~idle_minutes:0.0
             ~messages:[ test_message ]
             ();
           let log_path = Filename.concat dir "broker.log" in
           let body = read_file log_path in
           check bool "nudge_enqueue line emitted for alive recipient" true
             (contains body "\"to_alias\":\"alive-with-pid-row\"");
           check bool "to_pid_state is alive_with_pid" true
             (contains body "\"to_pid_state\":\"alive_with_pid\"");
           check bool "tick log records alive_total=1" true
             (contains body "\"alive_total\":1");
           check bool "tick log records sent=1" true
             (contains body "\"sent\":1")))

let () =
  run "relay_nudge"
    [ ( "instrumentation #335",
        [ test_case "nudge_tick logs structured event with counts" `Quick
            test_log_nudge_tick_structure
        ; test_case "nudge_enqueue records to_pid_state for pidless recipients" `Quick
            test_log_nudge_enqueue_records_pid_state
        ; test_case "nudge_tick on empty registry emits zero counters, no enqueue" `Quick
            test_nudge_tick_empty_registry
        ] )
    ; ( "v2a pidless skip #335",
        [ test_case "pidless registration is skipped, alive_no_pid increments" `Quick
            test_pidless_registration_skipped
        ; test_case "dead-pid registration is skipped, alive_total=0" `Quick
            test_dead_pid_registration_skipped
        ; test_case "unknown-state registration (pid set, start mismatch) is skipped" `Quick
            test_unknown_pid_registration_skipped
        ; test_case "alive_with_pid + idle + non-DND fires exactly one nudge" `Quick
            test_alive_with_pid_eligible
        ] )
    ]
