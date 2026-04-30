(* #482 S1: c2c_deliver_inbox unit tests *)

let check b msg = if not b then Alcotest.fail msg

let round_trip_pidfile () =
  let tmp = Filename.temp_file "c2c_deliver_test" ".pid" in
  Fun.protect ~finally:(fun () -> try Unix.unlink tmp with _ -> ())
    (fun () ->
      C2c_deliver_inbox.write_pidfile tmp (Unix.getpid ());
      match C2c_deliver_inbox.read_pidfile tmp with
      | Some p -> check (p = Unix.getpid ()) "pid round-trip mismatch"
      | None -> Alcotest.fail "read_pidfile returned None")

let read_nonexistent () =
  match C2c_deliver_inbox.read_pidfile "/nonexistent/path/12345.pid" with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for nonexistent path"

let read_invalid () =
  let tmp = Filename.temp_file "c2c_deliver_test" ".pid" in
  Fun.protect ~finally:(fun () -> try Unix.unlink tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      Printf.fprintf oc "not-a-number\n";
      close_out oc;
      match C2c_deliver_inbox.read_pidfile tmp with
      | None -> ()
      | Some _ -> Alcotest.fail "expected None for invalid pid content")

let pid_is_alive_own () =
  check (C2c_deliver_inbox.pid_is_alive (Unix.getpid ())) "own pid should be alive"

let pid_is_alive_zero () =
  check (not (C2c_deliver_inbox.pid_is_alive 0)) "pid 0 should not be alive"

let pid_is_alive_neg () =
  check (not (C2c_deliver_inbox.pid_is_alive (-1))) "negative pid should not be alive"

let pid_is_alive_dead () =
  (* PID 2 is always dead on Linux (kernel thread) *)
  check (not (C2c_deliver_inbox.pid_is_alive 2)) "pid 2 should not be alive"

let already_running_false_no_file () =
  let tmp = Filename.temp_file "c2c_deliver_test" ".pid" in
  (try Unix.unlink tmp with _ -> ());
  check (not (C2c_deliver_inbox.already_running tmp))
    "expected false for nonexistent pidfile"

let already_running_false_dead_pid () =
  let tmp = Filename.temp_file "c2c_deliver_test" ".pid" in
  Fun.protect ~finally:(fun () -> try Unix.unlink tmp with _ -> ())
    (fun () ->
      let oc = open_out tmp in
      Printf.fprintf oc "2\n";
      close_out oc;
      check (not (C2c_deliver_inbox.already_running tmp))
        "expected false for dead pid in pidfile")

let already_running_true () =
  let tmp = Filename.temp_file "c2c_deliver_test" ".pid" in
  Fun.protect ~finally:(fun () -> try Unix.unlink tmp with _ -> ())
    (fun () ->
      C2c_deliver_inbox.write_pidfile tmp (Unix.getpid ());
      check (C2c_deliver_inbox.already_running tmp) "expected true for our own pid")

let effective_submit_delay_none () =
  match C2c_deliver_inbox.effective_submit_delay ~client:"generic" ~submit_delay:None with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for generic client"

let effective_submit_delay_some () =
  match C2c_deliver_inbox.effective_submit_delay ~client:"generic" ~submit_delay:(Some 2.5) with
  | Some 2.5 -> ()
  | None -> Alcotest.fail "expected Some 2.5"
  | Some _ -> Alcotest.fail "expected 2.5"

let effective_submit_delay_kimi_default () =
  match C2c_deliver_inbox.effective_submit_delay ~client:"kimi" ~submit_delay:None with
  | Some 1.5 -> ()
  | None -> Alcotest.fail "expected Some 1.5 for kimi"
  | Some _ -> Alcotest.fail "expected 1.5 for kimi"

let effective_submit_delay_kimi_override () =
  match C2c_deliver_inbox.effective_submit_delay ~client:"kimi" ~submit_delay:(Some 3.0) with
  | Some 3.0 -> ()
  | _ -> Alcotest.fail "expected override value 3.0 for kimi"

let run_loop_max_iterations () =
  let args = {
    C2c_deliver_inbox.
    session_id = Some "test-session";
    terminal_pid = None;
    pts = None;
    broker_root = "/tmp/test-broker";
    client = "generic";
    loop = true;
    interval = 0.01;
    max_iterations = Some 3;
    pidfile = None;
    daemon = false;
    daemon_log = None;
    daemon_timeout = 10.0;
    notify_only = false;
    notify_debounce = 30.0;
    xml_output_fd = None;
    xml_output_path = None;
    event_fifo = None;
    response_fifo = None;
    file_fallback = false;
    timeout = 5.0;
    submit_delay = None;
    dry_run = false;
    json = false;
  } in
  (* Verify it returns without hanging — in S1 run_loop is a stub *)
  C2c_deliver_inbox.run_loop ~args ~watched_pid:None

let run_loop_watched_pid_exit () =
  let args = {
    C2c_deliver_inbox.
    session_id = Some "test-session";
    terminal_pid = None;
    pts = None;
    broker_root = "/tmp/test-broker";
    client = "generic";
    loop = true;
    interval = 0.01;
    max_iterations = None;
    pidfile = None;
    daemon = false;
    daemon_log = None;
    daemon_timeout = 10.0;
    notify_only = false;
    notify_debounce = 30.0;
    xml_output_fd = None;
    xml_output_path = None;
    event_fifo = None;
    response_fifo = None;
    file_fallback = false;
    timeout = 5.0;
    submit_delay = None;
    dry_run = false;
    json = false;
  } in
  (* Pass a clearly-dead watched_pid — should exit immediately *)
  C2c_deliver_inbox.run_loop ~args ~watched_pid:(Some 2)

let suite = [
  "read_pidfile ok", `Quick, round_trip_pidfile;
  "read_pidfile nonexistent", `Quick, read_nonexistent;
  "read_pidfile invalid", `Quick, read_invalid;
  "pid_is_alive own", `Quick, pid_is_alive_own;
  "pid_is_alive zero", `Quick, pid_is_alive_zero;
  "pid_is_alive negative", `Quick, pid_is_alive_neg;
  "pid_is_alive dead", `Quick, pid_is_alive_dead;
  "already_running false (no file)", `Quick, already_running_false_no_file;
  "already_running false (dead pid)", `Quick, already_running_false_dead_pid;
  "already_running true", `Quick, already_running_true;
  "effective_submit_delay none", `Quick, effective_submit_delay_none;
  "effective_submit_delay some", `Quick, effective_submit_delay_some;
  "effective_submit_delay kimi default", `Quick, effective_submit_delay_kimi_default;
  "effective_submit_delay kimi override", `Quick, effective_submit_delay_kimi_override;
  "run_loop max_iterations", `Quick, run_loop_max_iterations;
  "run_loop watched_pid exit", `Quick, run_loop_watched_pid_exit;
]

let () = Alcotest.run "c2c_deliver_inbox" [ "pidfile", suite ]
