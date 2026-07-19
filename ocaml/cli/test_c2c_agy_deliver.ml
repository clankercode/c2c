(* #66 regression tests for the agy agentapi delivery watcher.

   Two defects, both newly reachable on the Stop hook since #61:
   - [run_agentapi_send] used an unbounded [Unix.waitpid], so a hung
     `agy agentapi send-message` would wedge the agent at its turn boundary.
     [wait_child_bounded] must return promptly on a hung child and reap it.
   - a post-injection drain that raised propagated into the hook's outer
     `try _ -> ()` and left the mail to re-inject next turn. [drain_after_inject]
     must swallow the failure (never raise) and leave a broker.log trace. *)

let test_bounded_wait_clean_exit () =
  let pid = Unix.fork () in
  if pid = 0 then Unix._exit 0
  else
    Alcotest.(check bool) "clean exit 0 within window -> true" true
      (C2c_agy_deliver.wait_child_bounded ~timeout:5.0 pid)

let test_bounded_wait_nonzero_exit () =
  let pid = Unix.fork () in
  if pid = 0 then Unix._exit 3
  else
    Alcotest.(check bool) "non-zero exit -> false" false
      (C2c_agy_deliver.wait_child_bounded ~timeout:5.0 pid)

(* The load-bearing one: a child that would run far longer than the timeout must
   NOT block the caller, and must be dead afterwards (killed + reaped). *)
let test_bounded_wait_times_out_promptly () =
  let pid = Unix.fork () in
  if pid = 0 then (Unix.sleep 30; Unix._exit 0)
  else begin
    let t0 = Unix.gettimeofday () in
    let r = C2c_agy_deliver.wait_child_bounded ~timeout:0.3 pid in
    let elapsed = Unix.gettimeofday () -. t0 in
    Alcotest.(check bool) "hung child -> false" false r;
    Alcotest.(check bool) "returns well before the child's 30s" true
      (elapsed < 5.0);
    (* Give the SIGTERM/SIGKILL a moment to be reflected, then confirm dead. *)
    Unix.sleepf 0.2;
    Alcotest.(check bool) "hung child was killed, not left running" false
      (C2c_agy_deliver.pid_alive pid)
  end

(* A raising drain must not propagate (reaching the assert proves that) and must
   leave a broker.log record so a repeating re-injection is diagnosable. *)
let test_drain_after_inject_swallows_and_logs () =
  let dir = Filename.temp_file "c2c_agy_drain" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  C2c_agy_deliver.drain_after_inject ~broker_root:dir ~label:"repo"
    (fun () -> failwith "boom");
  Alcotest.(check bool) "did not raise; broker.log written on drain failure" true
    (Sys.file_exists (Filename.concat dir "broker.log"))

let () =
  Alcotest.run "c2c_agy_deliver"
    [ ( "bounded_wait",
        [ Alcotest.test_case "clean exit" `Quick test_bounded_wait_clean_exit
        ; Alcotest.test_case "nonzero exit" `Quick test_bounded_wait_nonzero_exit
        ; Alcotest.test_case "times out promptly" `Quick
            test_bounded_wait_times_out_promptly ] )
    ; ( "drain_after_inject",
        [ Alcotest.test_case "swallows and logs" `Quick
            test_drain_after_inject_swallows_and_logs ] )
    ]
