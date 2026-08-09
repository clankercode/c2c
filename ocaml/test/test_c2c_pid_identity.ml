(* #85 — a recorded pid outlives the process it names, and pids are recycled.

   The live incident: a 21-day-old kimi instance recorded outer pid 821300; by
   the time anyone ran `c2c stop`, that number belonged to a THREAD of an
   unrelated desktop application. `kill(pid, 0)` succeeded, so the instance read
   "running" forever and the stop SIGTERMed the application — which exited, and
   c2c reported "stopped", exit 0.

   These tests use this test process itself as the live-and-ours case, and a
   thread of this process as the recycled case, so they exercise real procfs
   rather than a mock of it. *)

open Alcotest

module P = C2c_pid_identity

let self = Unix.getpid ()

(* A non-leader thread id of this process. Alcotest runs single-threaded, so we
   start one and hold it for the duration of the test binary. *)
let sibling_tid =
  let tid = ref None in
  let ready = Mutex.create () in
  let cond = Condition.create () in
  let _ =
    Thread.create
      (fun () ->
        Mutex.lock ready;
        tid := Some (Unix.readlink "/proc/thread-self" |> Filename.basename);
        Condition.signal cond;
        Mutex.unlock ready;
        (* Keep the thread alive so /proc/<tid> exists throughout. *)
        Thread.delay 3600.0)
      ()
  in
  Mutex.lock ready;
  while !tid = None do
    Condition.wait cond ready
  done;
  Mutex.unlock ready;
  match !tid with
  | Some s -> int_of_string s
  | None -> failwith "no sibling tid"

let identity =
  testable (fun ppf i -> Fmt.string ppf (P.pid_identity_reason ~pid:0 i)) ( = )

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    if i + nl > hl then false
    else if String.sub haystack i nl = needle then true
    else go (i + 1)
  in
  nl = 0 || go 0

(* --- the shape that caused the incident ---------------------------------- *)

let test_thread_is_never_ours () =
  (* /proc/<tid> exists, so pid_alive says yes — that is exactly the trap. *)
  check bool "pid_alive is true for a thread id" true (P.pid_alive sibling_tid);
  match P.classify_pid_identity ~pid:sibling_tid ~expect:P.Unknown_start with
  | P.Pid_not_leader tgid ->
      check int "names this process as the thread group" self tgid
  | other ->
      failf "expected Pid_not_leader, got %s"
        (P.pid_identity_reason ~pid:sibling_tid other)

let test_thread_rejected_without_any_recorded_state () =
  (* Leadership needs no recorded timestamp, so instances predating start_ts are
     protected too. *)
  check bool "thread is not ours" false
    (P.recorded_pid_is_ours ~expect:P.Unknown_start ~pid:sibling_tid)

let test_reason_names_the_owning_process () =
  let reason =
    P.pid_identity_reason ~pid:sibling_tid (P.Pid_not_leader self)
  in
  check bool "mentions the pid" true
    (contains ~needle:(string_of_int sibling_tid) reason);
  check bool "mentions the thread group" true
    (contains ~needle:(string_of_int self) reason);
  check bool "says it was recycled" true (contains ~needle:"recycled" reason)

(* --- start-time evidence -------------------------------------------------- *)

let self_start =
  match P.proc_start_wall_clock self with
  | Some t -> t
  | None -> failwith "cannot read own start time"

let test_exact_start_ts_matches () =
  check identity "our own pid with our own start time" P.Pid_matches
    (P.classify_pid_identity ~pid:self ~expect:(P.Started_at self_start))

let test_start_ts_off_by_days_is_recycled () =
  (* The 21-day-old instance case, had the pid landed on a leader process. *)
  let long_ago = self_start -. (21.0 *. 86400.0) in
  match P.classify_pid_identity ~pid:self ~expect:(P.Started_at long_ago) with
  | P.Pid_recycled (observed, expected) ->
      check (float 1.0) "observed is our real start" self_start observed;
      check (float 1.0) "expected is what was recorded" long_ago expected
  | other ->
      failf "expected Pid_recycled, got %s" (P.pid_identity_reason ~pid:self other)

let test_start_ts_within_tolerance_matches () =
  let jittered = self_start +. (P.start_time_tolerance_s /. 2.0) in
  check identity "small skew still matches" P.Pid_matches
    (P.classify_pid_identity ~pid:self ~expect:(P.Started_at jittered))

(* --- the pidfile-mtime bound, for records with no spawn timestamp --------- *)

let test_recorded_at_is_one_sided () =
  (* A process that started BEFORE the record was written is normal: the pidfile
     is written after the fork, and may be rewritten later still. *)
  check identity "started before the record — fine" P.Pid_matches
    (P.classify_pid_identity ~pid:self
       ~expect:(P.Recorded_at (self_start +. 3600.0)));
  (* A process that started well AFTER cannot be the one the record names. *)
  match
    P.classify_pid_identity ~pid:self
      ~expect:(P.Recorded_at (self_start -. 86400.0))
  with
  | P.Pid_recycled _ -> ()
  | other ->
      failf "expected Pid_recycled for a process younger than its record, got %s"
        (P.pid_identity_reason ~pid:self other)

let test_pidfile_expectation_reads_mtime () =
  let path = Filename.temp_file "c2c-pid-identity" ".pid" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match P.pidfile_expectation path with
      | P.Recorded_at mtime ->
          (* Just written, so it postdates this process. *)
          check bool "mtime is at or after our start" true (mtime >= self_start)
      | other ->
          failf "expected Recorded_at, got %s"
            (match other with
             | P.Unknown_start -> "Unknown_start"
             | _ -> "Started_at"))

let test_pidfile_expectation_missing_file () =
  check bool "absent pidfile yields Unknown_start" true
    (P.pidfile_expectation "/nonexistent/c2c/pid/file" = P.Unknown_start)

let test_pidfile_guard_end_to_end () =
  let path = Filename.temp_file "c2c-pid-identity" ".pid" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check bool "our own pid passes" true
        (P.pidfile_pid_is_ours ~pidfile:path ~pid:self);
      (* The incident shape, through the guard every kill site now calls. *)
      check bool "a thread of ours does not" false
        (P.pidfile_pid_is_ours ~pidfile:path ~pid:sibling_tid))

(* --- absence and the deliberate asymmetry --------------------------------- *)

let test_absent_pid () =
  (* Very high pid, well above /proc/sys/kernel/pid_max defaults. *)
  check identity "no such process" P.Pid_absent
    (P.classify_pid_identity ~pid:0x3FFFFFFF ~expect:P.Unknown_start);
  check identity "pid 0 is not a target" P.Pid_absent
    (P.classify_pid_identity ~pid:0 ~expect:P.Unknown_start);
  check identity "negative pid is not a target" P.Pid_absent
    (P.classify_pid_identity ~pid:(-1) ~expect:P.Unknown_start)

let test_unverifiable_counts_as_ours () =
  (* Without evidence of reuse we keep the pre-#85 behaviour, so an instance
     with no recorded start time can still be stopped. Existence and leadership
     have already been checked by the time we get here. *)
  check bool "unverifiable is ours" true (P.pid_identity_is_ours P.Pid_unverifiable);
  check bool "matches is ours" true (P.pid_identity_is_ours P.Pid_matches);
  check bool "absent is not" false (P.pid_identity_is_ours P.Pid_absent);
  check bool "thread is not" false (P.pid_identity_is_ours (P.Pid_not_leader 1));
  check bool "recycled is not" false (P.pid_identity_is_ours (P.Pid_recycled (1., 2.)))

let test_proc_readers () =
  check (option int) "tgid of self is self" (Some self) (P.proc_tgid self);
  check (option int) "tgid of a thread is the leader" (Some self)
    (P.proc_tgid sibling_tid);
  check bool "comm is readable" true (P.proc_comm self <> None);
  check bool "start time is readable" true (P.proc_start_wall_clock self <> None);
  check (option int) "tgid of an absent pid" None (P.proc_tgid 0x3FFFFFFF);
  check bool "start time of an absent pid" true
    (P.proc_start_wall_clock 0x3FFFFFFF = None)

let () =
  run "c2c_pid_identity"
    [ ( "recycled onto a thread (the #85 incident)",
        [ test_case "thread is never ours" `Quick test_thread_is_never_ours
        ; test_case "rejected with no recorded state" `Quick
            test_thread_rejected_without_any_recorded_state
        ; test_case "reason names the owning process" `Quick
            test_reason_names_the_owning_process
        ] )
    ; ( "start-time evidence",
        [ test_case "exact start_ts matches" `Quick test_exact_start_ts_matches
        ; test_case "off by days is recycled" `Quick
            test_start_ts_off_by_days_is_recycled
        ; test_case "within tolerance matches" `Quick
            test_start_ts_within_tolerance_matches
        ] )
    ; ( "pidfile mtime bound",
        [ test_case "one-sided" `Quick test_recorded_at_is_one_sided
        ; test_case "reads mtime" `Quick test_pidfile_expectation_reads_mtime
        ; test_case "missing file" `Quick test_pidfile_expectation_missing_file
        ; test_case "guard end to end" `Quick test_pidfile_guard_end_to_end
        ] )
    ; ( "absence and asymmetry",
        [ test_case "absent pids" `Quick test_absent_pid
        ; test_case "unverifiable counts as ours" `Quick
            test_unverifiable_counts_as_ours
        ; test_case "proc readers" `Quick test_proc_readers
        ] )
    ]
