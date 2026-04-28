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

(* AC1 — log_nudge_tick writes a structured event with the right counters
   when the only registration is alive + DND'd. *)
let test_log_nudge_tick_structure () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register one DND-active session so the tick sees alive_total=1,
         skipped_dnd=1, sent=0. *)
      C2c_mcp.Broker.register broker ~session_id:"s-dnd" ~alias:"dnd-recipient"
        ~pid:None ~pid_start_time:None ();
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

(* AC2 — log_nudge_enqueue writes one entry per send with to_pid_state. *)
let test_log_nudge_enqueue_records_pid_state () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register a recipient with pid:None so to_pid_state should be
         "alive_no_pid" — exactly the Lyra-Quill-X pattern that #335 v0
         finding flagged. *)
      C2c_mcp.Broker.register broker ~session_id:"s-recv" ~alias:"recv-noid"
        ~pid:None ~pid_start_time:None ();
      (* Force last_activity_ts old enough to be idle-eligible. *)
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
      check bool "log records to_pid_state=alive_no_pid for pidless recipient" true
        (contains body "\"to_pid_state\":\"alive_no_pid\"");
      check bool "log records to_alias=recv-noid" true
        (contains body "\"to_alias\":\"recv-noid\""))

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
    ]
