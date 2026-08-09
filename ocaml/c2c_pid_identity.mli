(** Is a recorded pid still OUR process? (#85)

    A leaf module with no c2c dependencies, so every layer that signals a pid
    can reach it. {!pid_alive} answers only "does this number exist"; a recorded
    pid outlives the process it named, and pids are recycled, so anything about
    to send a signal to a pid read from disk must ask {!pidfile_pid_is_ours}
    first. *)

val pid_alive : int -> bool
(** Does a process with this number exist? Says nothing about whose it is. *)

(** Whether a recorded pid still names the process c2c recorded, or has been
    recycled onto something else. See the implementation for why both
    thread-group leadership and start time are checked. *)
type pid_identity =
  | Pid_matches
  | Pid_absent
  | Pid_not_leader of int
  | Pid_recycled of float * float
  | Pid_unverifiable

(** What c2c knows about when the recorded process started. [Started_at] is an
    exact spawn timestamp (instance meta.json); [Recorded_at] is only an upper
    bound — the moment the record naming the pid was written, typically a
    pidfile's mtime. *)
type pid_expectation =
  | Started_at of float
  | Recorded_at of float
  | Unknown_start

val proc_tgid : int -> int option
val proc_comm : int -> string option
val proc_start_wall_clock : int -> float option
(** Shared /proc readers. Return [None] rather than raising when procfs cannot
    answer (process gone, permission denied, unexpected format). *)

val start_time_tolerance_s : float

val classify_pid_identity : pid:int -> expect:pid_expectation -> pid_identity
(** [classify_pid_identity ~pid ~expect] decides whether [pid] is still the
    recorded process. [Unknown_start] yields [Pid_unverifiable] rather than a
    guess. *)

val pidfile_expectation : string -> pid_expectation
(** [Recorded_at] the pidfile's mtime, or [Unknown_start] if it cannot be
    stat'd. *)

val pid_identity_is_ours : pid_identity -> bool
(** [Pid_unverifiable] counts as ours — absent evidence of reuse, preserve the
    pre-#85 behaviour. Existence and leadership are still enforced. *)

val recorded_pid_is_ours : expect:pid_expectation -> pid:int -> bool

val pidfile_pid_is_ours : pidfile:string -> pid:int -> bool
(** The guard for every "read a pid out of a file, then signal it" site. Use it
    before {b any} SIGTERM/SIGKILL of a pid that came off disk. *)

val pid_identity_reason : pid:int -> pid_identity -> string
(** Human-readable explanation, safe to print to an operator. *)
