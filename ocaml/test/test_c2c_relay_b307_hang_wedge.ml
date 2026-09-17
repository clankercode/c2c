(* B307 regression: a REAL sync hang trips the SIGALRM handler, which
   force-exits 3 (B228) — but pre-fix nothing persisted a wedge record, so
   after a supervisor restart the hung root was retried at base cadence with
   NO cooldown: a deterministic hang was an infinite crash loop with zero
   learning, and every exit destroyed the in-memory wedge/strike tables.

   Fix contract:
   - the SIGALRM handler persists a B292-compatible wedge record
     (wedged_since / wedge_count / wedge_reason in connector-state.json) for
     the hung root BEFORE exiting 3, via the same lock-free tmp+rename RMW
     mark_connector_wedged uses (the interrupted sync may hold the registry /
     outbox locks, so the handler must never take one);
   - the escalating count is read from the file, so hangs compound across
     restarts and the restarted connector's cooldown reader applies
     wedge_cooldown_s (base 600s, cap 7200s) instead of retrying immediately;
   - sync_watchdog_s scales with observed pass work (B291-style) so a
     slow-but-alive pass is not SIGALRM-killed at the interval-derived floor;
     C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S overrides the deadline for tests and
     operators. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b307-test-%d-%d"
       (Unix.getpid ()) (Random.int 1_000_000)) in
  Unix.mkdir dir 0o755;
  dir

let rmrf path =
  let rec aux p =
    match (Unix.lstat p).st_kind with
    | Unix.S_DIR ->
        let entries = Sys.readdir p in
        Array.iter (fun e -> aux (Filename.concat p e)) entries;
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception _ -> ()
  in
  try aux path with _ -> ()

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

(* The machine loop's B291 gate skips zero-work roots before sync_once runs,
   so every root in a machine-shaped test needs an eligible registration. *)
let write_eligible_registry broker =
  mkdir_p broker;
  let pid = Unix.getpid () in
  let start =
    match Conn.read_pid_start_time_local pid with
    | Some n -> n
    | None -> failwith "current process must have a readable start time"
  in
  let oc = open_out (Filename.concat broker "registry.json") in
  Yojson.Safe.to_channel oc
    (`List [ `Assoc [ "session_id", `String "fixture-live";
                      "alias", `String "fixture-alias";
                      "pid", `Int pid;
                      "pid_start_time", `Int start ] ]);
  close_out oc

let waitpid_until ~timeout_s pid =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.02;
        loop ()
    | 0, _ -> None
    | _, status -> Some status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

(* Drain until at least [at_least] marker bytes arrive or the deadline passes. *)
let drain_until fd ~at_least ~deadline_s =
  Unix.set_nonblock fd;
  let buf = Buffer.create 32 in
  let chunk = Bytes.create 64 in
  let deadline = Unix.gettimeofday () +. deadline_s in
  let rec loop () =
    if Buffer.length buf >= at_least || Unix.gettimeofday () >= deadline then
      Buffer.contents buf
    else begin
      (match Unix.read fd chunk 0 64 with
       | n -> Buffer.add_subbytes buf chunk 0 n
       | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> ());
      Unix.sleepf 0.05;
      loop ()
    end
  in
  loop ()

let count_char c s =
  String.to_seq s |> Seq.filter (fun x -> x = c) |> Seq.length

let ok_result () : Conn.sync_result =
  { registered = []; registered_sessions = []; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; inbound_rejected_note = None;
    alerts_emitted = 0; rate_limited = false; retry_after_s = None;
    last_error = None; errors = [] }

(* Trip the REAL SIGALRM handler the way a deadline expiry does — the handler
   is the code under test, not the sync_fn. The sync then pends forever, so
   only the handler can end the process. *)
let hang_and_trip_alarm _t =
  Unix.kill (Unix.getpid ()) Sys.sigalrm;
  let promise, _resolver = Lwt.wait () in
  promise

let expect_exit pid ~timeout_s ~code ~what =
  match waitpid_until ~timeout_s pid with
  | Some (Unix.WEXITED c) when c = code -> ()
  | Some (Unix.WEXITED c) ->
      Alcotest.failf "%s: expected exit %d, got exit %d" what code c
  | Some status ->
      Alcotest.failf "%s: expected exit %d, got %s" what code
        (match status with
         | Unix.WEXITED c -> Printf.sprintf "exit %d" c
         | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
         | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
  | None ->
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      Alcotest.failf "%s: child did not exit within %.0fs" what timeout_s

(* A REAL hang must persist the hang-wedge BEFORE the B228 force-exit, and the
   count must compound across restarts (escalating cooldown). Two sequential
   hung processes over the same root: the second handler run reads count 1
   from the file the first one wrote and writes 2. *)
let test_real_hang_persists_wedge_before_exit () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let hang_child () =
    match Unix.fork () with
    | 0 ->
        let t =
          Conn.make_state ~relay_url:"http://unreachable.invalid"
            ~token:None ~identity:None ~broker_root:tmp ~node_id:"b307-hang"
            ~heartbeat_ttl:300.0 ~interval:30.0 ~verbose:false
        in
        ignore
          (Conn.run_sync_once ~shutdown:(ref false) ~sync_fn:hang_and_trip_alarm
             t);
        (* The handler must _exit 3; landing here means it did not. *)
        Unix._exit 42
    | pid -> pid
  in
  (* First hang: wedge count 1. *)
  expect_exit (hang_child ()) ~timeout_s:5.0 ~code:3
    ~what:"first hung sync";
  (match Conn.read_connector_state tmp with
   | None -> Alcotest.fail "hung sync wrote no connector-state at all"
   | Some st ->
       Alcotest.(check bool)
         "first hang persisted wedged_since before exiting" true
         (st.Conn.cs_wedged_since <> None);
       Alcotest.(check int) "first hang wedge count" 1 st.Conn.cs_wedge_count;
       Alcotest.(check bool) "wedge reason names the hang" true
         (match st.Conn.cs_wedge_reason with
          | Some r -> String.length r > 0
          | None -> false));
  (* Second hang over the same root (the restarted connector): count 2. *)
  expect_exit (hang_child ()) ~timeout_s:5.0 ~code:3
    ~what:"second hung sync (post-restart)";
  (match Conn.read_connector_state tmp with
   | Some st ->
       Alcotest.(check int)
         "wedge count escalates across restarts" 2 st.Conn.cs_wedge_count
   | None -> Alcotest.fail "connector-state vanished after second hang")

(* End-to-end learning: after the handler-written wedge, a RESTARTED machine
   connector drops the hung root (cooldown) while other roots keep syncing —
   and never retries the hung root at base cadence. *)
let test_restarted_connector_honors_hang_wedge () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let bad = Filename.concat tmp "hung-broker" in
  let good = Filename.concat tmp "good-broker" in
  write_eligible_registry bad;
  write_eligible_registry good;
  (* Phase A: production-shaped machine pass — the bad root goes through
     run_sync_once (the real alarm arming) and hangs; the handler must persist
     the wedge before the B228 force-exit kills the process. *)
  let phase_a () =
    match Unix.fork () with
    | 0 ->
        let sync_once shutdown t =
          if t.Conn.broker_root = bad then
            Conn.run_sync_once ~shutdown ~sync_fn:hang_and_trip_alarm t
          else Ok (ok_result ())
        in
        Unix._exit
          (Conn.start_machine_impl ~sync_once
             ~discover_roots:(fun ~primary -> [ bad; primary ])
             ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
             ~primary_broker_root:good ~node_id:"b307-machine"
             ~heartbeat_ttl:300.0 ~interval:0.05 ~verbose:false ~once:false)
    | pid -> pid
  in
  expect_exit (phase_a ()) ~timeout_s:5.0 ~code:3 ~what:"machine hang pass";
  (match Conn.read_connector_state bad with
   | Some st ->
       Alcotest.(check bool) "machine hang wedge persisted" true
         (st.Conn.cs_wedged_since <> None)
   | None ->
       Alcotest.fail "machine hang left no wedge record in the hung root");
  (* Phase B: the restarted connector (fresh process, fresh tables). The
     parked root must be adopted into cooldown from the persisted record and
     skipped; the good root keeps syncing. Reaching the parked root at all is
     the pre-fix behavior (retry at base cadence) — fail loudly on it. *)
  let byte_r, byte_w = Unix.pipe () in
  let phase_b () =
    match Unix.fork () with
    | 0 ->
        Unix.close byte_r;
        let sync_once _shutdown t =
          if t.Conn.broker_root = bad then Unix._exit 9;
          ignore (Unix.write_substring byte_w "B" 0 1);
          Ok (ok_result ())
        in
        let code =
          Conn.start_machine_impl ~sync_once
            ~discover_roots:(fun ~primary -> [ bad; primary ])
            ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
            ~primary_broker_root:good ~node_id:"b307-machine"
            ~heartbeat_ttl:300.0 ~interval:0.05 ~verbose:false ~once:false
        in
        Unix.close byte_w;
        Unix._exit code
    | pid -> pid
  in
  let pid = phase_b () in
  Unix.close byte_w;
  let marks = drain_until byte_r ~at_least:1 ~deadline_s:2.5 in
  Unix.close byte_r;
  Alcotest.(check bool)
    "good root kept syncing while the hung root is in cooldown"
    (count_char 'B' marks >= 1) true;
  Unix.kill pid Sys.sigterm;
  match waitpid_until ~timeout_s:3.0 pid with
  | Some (Unix.WEXITED 9) ->
      Alcotest.fail
        "restarted connector re-synced the hung root: persisted hang-wedge \
         cooldown not honored (B307)"
  | Some (Unix.WEXITED 0) -> ()
  | Some status ->
      Alcotest.failf "restarted connector exited abnormally: %s"
        (match status with
         | Unix.WEXITED c -> Printf.sprintf "exit %d" c
         | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
         | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
  | None ->
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      Alcotest.fail "restarted connector did not stop within 3s"

(* B291-style scaling, pure contract: the alarm deadline must track observed
   pass work so a slow-but-alive many-root pass is not SIGALRM-killed at the
   interval-derived floor, and the env override wins for tests/operators. *)
let test_watchdog_scales_with_pass_work () =
  Unix.putenv "C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S" "";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S" "")
    @@ fun () ->
  let t =
    Conn.make_state ~relay_url:"http://unreachable.invalid" ~token:None
      ~identity:None ~broker_root:"/tmp" ~node_id:"b307-scale"
      ~heartbeat_ttl:300.0 ~interval:30.0 ~verbose:false
  in
  Alcotest.(check (float 1e-9)) "no pass work -> interval-derived base" 120.0
    (Conn.sync_watchdog_s t);
  Alcotest.(check (float 1e-9)) "scales with observed pass work" 900.0
    (Conn.sync_watchdog_s ~pass_work_s:300.0 t);
  Alcotest.(check (float 1e-9)) "base wins when work is small" 120.0
    (Conn.sync_watchdog_s ~pass_work_s:5.0 t);
  Unix.putenv "C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S" "7";
  Alcotest.(check (float 1e-9)) "env override wins over scaling" 7.0
    (Conn.sync_watchdog_s ~pass_work_s:300.0 t)

(* Regression guard for the composed behavior (the scaling contract above is
   its red): pass 1 (1.2s) completes under the 2s base and seeds the observed
   work; pass 2 sleeps 3.0s — past the base, inside the scaled 3x1.2s window —
   so a slow-but-alive pass must NOT be SIGALRM-killed. *)
let test_slow_but_alive_pass_not_alarm_killed () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let root = Filename.concat tmp "slow-broker" in
  write_eligible_registry root;
  let byte_r, byte_w = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close byte_r;
      Unix.putenv "C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S" "2";
      let pass = ref 0 in
      let sync_fn _t =
        incr pass;
        let work = if !pass = 1 then 1.2 else 3.0 in
        if !pass >= 2 then ignore (Unix.write_substring byte_w "S" 0 1);
        Lwt.bind (Lwt_unix.sleep work) (fun () -> Lwt.return (ok_result ()))
      in
      let sync_once shutdown t =
        Conn.run_sync_once ~shutdown ~sync_fn t
      in
      let code =
        Conn.start_machine_impl ~sync_once
          ~discover_roots:(fun ~primary -> [ primary ])
          ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
          ~primary_broker_root:root ~node_id:"b307-slow"
          ~heartbeat_ttl:300.0 ~interval:0.05 ~verbose:false ~once:false
      in
      Unix.close byte_w;
      Unix._exit code
  | pid ->
      Unix.close byte_w;
      let marks = drain_until byte_r ~at_least:1 ~deadline_s:12.0 in
      Unix.close byte_r;
      Alcotest.(check bool) "second (slow) pass completed" true
        (count_char 'S' marks >= 1);
      Unix.kill pid Sys.sigterm;
      expect_exit pid ~timeout_s:3.0 ~code:0 ~what:"slow-but-alive connector"

let () =
  Alcotest.run "c2c-relay-b307-hang-wedge"
    [ ( "B307 hang-wedge persistence"
      , [ Alcotest.test_case "real hang persists wedge before exit 3" `Quick
            test_real_hang_persists_wedge_before_exit
      ; Alcotest.test_case
            "restarted connector honors the hang-wedge cooldown" `Quick
            test_restarted_connector_honors_hang_wedge
      ; Alcotest.test_case "watchdog deadline scales with pass work" `Quick
            test_watchdog_scales_with_pass_work
      ; Alcotest.test_case "slow-but-alive pass is not alarm-killed" `Quick
            test_slow_but_alive_pass_not_alarm_killed ] ) ]
