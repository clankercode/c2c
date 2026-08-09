(* C2c_pid_identity — is a recorded pid still OUR process? (#85)

   Deliberately a LEAF module: no dependency on the registry, the broker or
   anything else, so every layer that signals a pid can reach it. C2c_liveness
   used to host this and could not be called from C2c_agent_state_handlers
   without a dependency cycle. *)

let pid_alive (pid : int) : bool =
  pid > 0 && Sys.file_exists (Printf.sprintf "/proc/%d" pid)

(* `pid_alive` above answers "does something with this number exist", which is
   NOT the same question as "is this still OUR process". PIDs are recycled, and
   a managed instance's recorded outer pid outlives the process by design (the
   instance dir is durable). Measured on this host 2026-08-09: a 21-day-old
   kimi instance recorded outer pid 821300, which by then belonged to a THREAD
   of an unrelated desktop app. `kill 0` succeeded, so the instance read
   "running" forever — and `c2c stop` would have signalled that app.

   Two independent signals settle it, and we use both:

   1. Thread-group leadership. A managed outer process is always a thread-group
      leader (it is a forked child, not a thread). If /proc/<pid>/status reports
      Tgid <> pid, the number names a thread inside some other process and is
      categorically not ours. This needs no recorded state, so it protects even
      instances written before start_ts existed — and it is what catches the
      case above.

   2. Start time. /proc/<pid>/stat field 22 is the process start in clock ticks
      since boot; combined with btime from /proc/stat it gives a wall clock that
      can be compared against what c2c knows. A recycled pid differs by hours or
      days, never by seconds.

   Signal 2 has two flavours because c2c records two different things. An
   instance's meta.json holds the exact spawn timestamp, so the comparison is an
   equality within tolerance. A bare pidfile holds only the number — but the
   file's own mtime is an upper bound: a process that started AFTER the pidfile
   naming it was written cannot be the process that file describes. That bound
   needs no schema change and covers every sidecar, notifier and watcher
   pidfile. It is one-sided, so it can only ever be too permissive (a pid
   recycled onto a process that started before the record slips through), never
   wrongly hostile to a live process. *)

(* The failure modes are deliberately asymmetric. Reporting a live instance dead
   is an annoyance (a stop that refuses, cleaned up by hand). Reporting a
   recycled pid live means signalling a stranger's process. So every ambiguity
   that we can resolve resolves toward "not ours". *)

type pid_identity =
  | Pid_matches
      (* Alive, thread-group leader, and start time agrees with the record. *)
  | Pid_absent
      (* No such process. *)
  | Pid_not_leader of int
      (* The number names a thread inside thread group [tgid] — never ours. *)
  | Pid_recycled of float * float
      (* (observed_start_wall, expected_start_wall) — same number, other process. *)
  | Pid_unverifiable
      (* Alive and a leader, but nothing to compare a start time against. *)

(* What we know about when the recorded process started. *)
type pid_expectation =
  | Started_at of float
      (* Exact spawn wall clock (instance meta.json "start_ts"). *)
  | Recorded_at of float
      (* The record naming this pid was written then; the process must not have
         started after it. Typically a pidfile's mtime. *)
  | Unknown_start
      (* Nothing to compare against — leadership and existence still apply. *)

(* USER_HZ, the unit of /proc/<pid>/stat field 22. Fixed at 100 by the Linux
   procfs ABI regardless of the kernel's internal CONFIG_HZ — this is not the
   scheduler tick and must not be read from getconf CLK_TCK's compile-time
   value. *)
let user_hz = 100.0

(* Allowance between the recorded spawn timestamp and the start time procfs
   reports. c2c records start_ts within milliseconds of the fork, and clock
   ticks quantise to 10ms, so this only has to absorb rounding — but it is set
   generously because the cost of being too tight (refusing to stop a live
   session) is worse than the cost of being loose (a recycled pid would have to
   land within two minutes of the original to slip through, which no real
   recycle does). *)
let start_time_tolerance_s = 120.0

let proc_field_int ~(path : string) ~(prefix : string) : int option =
  try
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
        let rec scan () =
          match input_line ic with
          | exception End_of_file -> None
          | line ->
              if String.length line >= String.length prefix
                 && String.sub line 0 (String.length prefix) = prefix
              then
                let rest =
                  String.sub line (String.length prefix)
                    (String.length line - String.length prefix)
                in
                (match int_of_string_opt (String.trim rest) with
                 | Some n -> Some n
                 | None -> scan ())
              else scan ()
        in
        scan ())
  with Sys_error _ -> None

(* Thread group id of [pid]. Equal to [pid] for a real process; different when
   [pid] names a non-leader thread. *)
let proc_tgid (pid : int) : int option =
  proc_field_int ~path:(Printf.sprintf "/proc/%d/status" pid) ~prefix:"Tgid:"

(* Process name, for explaining a rejection to a human. *)
let proc_comm (pid : int) : string option =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/comm" pid) in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () -> try Some (String.trim (input_line ic)) with End_of_file -> None)
  with Sys_error _ -> None

(* Boot time in seconds since the epoch. *)
let proc_btime () : int option =
  proc_field_int ~path:"/proc/stat" ~prefix:"btime "

(* /proc/<pid>/stat field 22 (1-indexed), the start time in clock ticks since
   boot. comm can contain spaces AND parens, so the fields after it are found
   by splitting on the LAST ')' — index 19 of the remaining 0-indexed tail,
   whose element 0 is state. Mirrors Broker.read_pid_start_time; kept here so
   the instance path does not depend on the registry module. *)
let proc_start_ticks (pid : int) : int option =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/stat" pid) in
    Fun.protect
      ~finally:(fun () -> try close_in ic with _ -> ())
      (fun () ->
        let line = input_line ic in
        match String.rindex_opt line ')' with
        | None -> None
        | Some idx ->
            if idx + 2 > String.length line then None
            else
              let tail =
                String.sub line (idx + 2) (String.length line - idx - 2)
              in
              (match List.nth_opt (String.split_on_char ' ' tail) 19 with
               | Some token -> int_of_string_opt token
               | None -> None))
  with Sys_error _ | End_of_file -> None

(* Wall-clock start of [pid], or None when procfs cannot answer. *)
let proc_start_wall_clock (pid : int) : float option =
  match proc_btime (), proc_start_ticks pid with
  | Some btime, Some ticks -> Some (float_of_int btime +. (float_of_int ticks /. user_hz))
  | _ -> None

(* [classify_pid_identity ~pid ~expect] decides whether [pid] is still the
   process c2c recorded. [Unknown_start] downgrades the verdict to
   Pid_unverifiable rather than inventing evidence. *)
let classify_pid_identity ~(pid : int) ~(expect : pid_expectation) : pid_identity
    =
  if pid <= 0 then Pid_absent
  else if not (Sys.file_exists (Printf.sprintf "/proc/%d" pid)) then Pid_absent
  else
    match proc_tgid pid with
    | Some tgid when tgid <> pid -> Pid_not_leader tgid
    | _ -> (
        match expect with
        | Unknown_start -> Pid_unverifiable
        | Started_at expected -> (
            match proc_start_wall_clock pid with
            | None -> Pid_unverifiable
            | Some observed ->
                if Float.abs (observed -. expected) <= start_time_tolerance_s
                then Pid_matches
                else Pid_recycled (observed, expected))
        | Recorded_at recorded -> (
            match proc_start_wall_clock pid with
            | None -> Pid_unverifiable
            | Some observed ->
                (* One-sided: only a process that started measurably LATER than
                   the record can be ruled out. Starting earlier is normal — the
                   pidfile is written after the fork, and may be rewritten
                   later still. *)
                if observed -. recorded <= start_time_tolerance_s then
                  Pid_matches
                else Pid_recycled (observed, recorded)))

(* Upper bound on the start time of whatever [pidfile] names: the file's own
   mtime. [Unknown_start] when it cannot be stat'd, so an unreadable pidfile
   degrades to the leadership check rather than to a refusal. *)
let pidfile_expectation (pidfile : string) : pid_expectation =
  match Unix.stat pidfile with
  | st -> Recorded_at st.Unix.st_mtime
  | exception Unix.Unix_error _ -> Unknown_start

(* Does this pid still belong to us? Pid_unverifiable counts as ours: without a
   recorded start time there is no evidence of reuse, and treating "unknown" as
   dead would break stop for any instance predating start_ts. The leadership
   and existence checks still apply in that case, so the dangerous case (#85)
   is caught regardless. *)
let pid_identity_is_ours = function
  | Pid_matches | Pid_unverifiable -> true
  | Pid_absent | Pid_not_leader _ | Pid_recycled _ -> false

let recorded_pid_is_ours ~(expect : pid_expectation) ~(pid : int) : bool =
  pid_identity_is_ours (classify_pid_identity ~pid ~expect)

(* The guard for every "read a pid out of a file, then signal it" site. *)
let pidfile_pid_is_ours ~(pidfile : string) ~(pid : int) : bool =
  recorded_pid_is_ours ~expect:(pidfile_expectation pidfile) ~pid

let pid_identity_reason ~(pid : int) = function
  | Pid_matches -> "pid matches the recorded start time"
  | Pid_unverifiable -> "pid is live but has no recorded start time to verify"
  | Pid_absent -> Printf.sprintf "no process with pid %d" pid
  | Pid_not_leader tgid ->
      Printf.sprintf
        "pid %d is a thread of process %d%s, not a c2c instance — the pid was \
         recycled"
        pid tgid
        (match proc_comm tgid with Some c -> Printf.sprintf " (%s)" c | None -> "")
  | Pid_recycled (observed, recorded) ->
      Printf.sprintf
        "pid %d started %.0fs %s c2c's record for it%s — the pid was recycled"
        pid
        (Float.abs (observed -. recorded))
        (if observed > recorded then "after" else "before")
        (match proc_comm pid with Some c -> Printf.sprintf " and is now %s" c | None -> "")
