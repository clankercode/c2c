(* c2c_deliver_inbox — public interface (S1 scaffold)
   Exposes helpers for testing and for use by c2c_start.ml *)

type cli_args = {
  session_id : string option;
  terminal_pid : int option;
  pts : string option;
  broker_root : string;
  client : string;
  loop : bool;
  interval : float;
  max_iterations : int option;
  pidfile : string option;
  daemon : bool;
  daemon_log : string option;
  daemon_timeout : float;
  notify_debounce : float;
  xml_output_fd : int option;
  xml_output_path : string option;
  file_fallback : bool;
  timeout : float;
  dry_run : bool;
  json : bool;
  pty_master_fd : int option;  (* S4: PTY master fd for PTY-based delivery *)
  use_inotify : bool;          (* H3: inotifywait-based watcher *)
}

(* PID file helpers — also used by c2c_start.ml for consistency *)
val write_pidfile : string -> int -> unit
val read_pidfile : string -> int option
val pid_is_alive : int -> bool
val already_running : string -> bool

val run_loop : args:cli_args -> watched_pid:int option -> unit
(** [run_loop ~args ~watched_pid] runs the delivery loop.
    In S1 this is a stub that logs iteration counts.
    In S2+ this will poll inbox and inject messages. *)

val parse_args : unit -> cli_args
(** [parse_args ()] parses command-line arguments. *)

val default_broker_root : unit -> string
(** [default_broker_root ()] mirrors c2c_poll_inbox.default_broker_root. *)

type daemon_start_result = [
  | `Already_running of int
  | `Started of int
  | `Failed of string
]

val start_daemon :
  _child_argv:string list ->  (* S2: exec in child process *)
  pidfile_path:string ->
  log_path:string ->
  wait_timeout:float ->
  daemon_start_result
