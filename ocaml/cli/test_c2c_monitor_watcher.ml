let sleep seconds =
  C2c_monitor_watcher.sleep_seconds seconds

let process_alive pid =
  try Unix.kill pid 0; true with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | _ -> false

let wait_until_dead pid =
  let deadline = Unix.gettimeofday () +. 2.0 in
  let rec loop () =
    if not (process_alive pid) then true
    else if Unix.gettimeofday () >= deadline then false
    else (sleep 0.05; loop ())
  in
  loop ()

let cleanup_kills_process_group_child () =
  let watcher =
    C2c_monitor_watcher.start
      ~program:"/bin/sh"
      ~args:[ "-c"; "sleep 30 & echo $!; wait" ]
  in
  let child_pid = int_of_string (input_line watcher.stdout_ic) in
  Alcotest.(check bool) "grandchild started" true (process_alive child_pid);
  C2c_monitor_watcher.terminate ~grace_seconds:0.1 watcher;
  Alcotest.(check bool) "grandchild cleaned up" true (wait_until_dead child_pid);
  C2c_monitor_watcher.terminate watcher

let reap_marks_exited_watcher_closed () =
  let watcher =
    C2c_monitor_watcher.start ~program:"/bin/sh" ~args:[ "-c"; "exit 0" ]
  in
  sleep 0.1;
  C2c_monitor_watcher.reap_if_exited watcher;
  Alcotest.(check bool) "closed after reap" true watcher.C2c_monitor_watcher.closed;
  C2c_monitor_watcher.terminate watcher

let () =
  Alcotest.run "c2c monitor watcher"
    [ ( "process supervision",
        [ Alcotest.test_case "terminate kills watcher process group" `Quick cleanup_kills_process_group_child;
          Alcotest.test_case "reap notices watcher exit" `Quick reap_marks_exited_watcher_closed ] )
    ]
