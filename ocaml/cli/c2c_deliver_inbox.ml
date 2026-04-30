(* c2c_deliver_inbox — OCaml deliver-inbox daemon (S1 scaffold)
   Replaces c2c_deliver_inbox.py (Python). S1 scope: CLI parsing,
   daemon fork+setsid+pgrp, pidfile, log redirection, already_running guard,
   run_loop stub that does nothing yet (stubs for S2 onward).

   Single-file executable: all logic in this file, `let () =` is the
   OCaml program body. *)

let ( // ) = Filename.concat

(* ---------------------------------------------------------------------------
 * Types
 * --------------------------------------------------------------------------- *)

type daemon_start_result = [
  | `Already_running of int
  | `Started of int
  | `Failed of string
]

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
  notify_only : bool;
  notify_debounce : float;
  xml_output_fd : int option;
  xml_output_path : string option;
  event_fifo : string option;
  response_fifo : string option;
  file_fallback : bool;
  timeout : float;
  submit_delay : float option;
  dry_run : bool;
  json : bool;
}

(* ---------------------------------------------------------------------------
 * Utility: pidfile
 * --------------------------------------------------------------------------- *)

let read_pidfile path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = String.trim (input_line ic) in
          Some (int_of_string line))
    with _ -> None

let write_pidfile path pid =
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> try close_out oc with _ -> ())
    (fun () -> Printf.fprintf oc "%d\n" pid)

let pid_is_alive pid =
  if pid <= 0 then false
  else
    try Unix.kill pid 0; true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true

let already_running pidfile =
  match read_pidfile pidfile with
  | Some p when pid_is_alive p -> true
  | _ -> false

(* ---------------------------------------------------------------------------
 * Daemon: fork + setsid + pgrp + log redirection
 * --------------------------------------------------------------------------- *)

let start_daemon
    ~(_child_argv : string list)  (* S2: exec child_argv in child process *)
    ~(pidfile_path : string)
    ~(log_path : string)
    ~(wait_timeout : float)
    : daemon_start_result =
  match already_running pidfile_path with
  | true ->
    (match read_pidfile pidfile_path with
     | Some p -> `Already_running p
     | None -> `Failed "pidfile exists but unreadable")
  | false ->
    (try Unix.unlink pidfile_path with Unix.Unix_error _ -> ());
    (match Unix.fork () with
     | 0 ->
       (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
       let log_dir = Filename.dirname log_path in
       (try Unix.mkdir log_dir 0o755
        with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
       let log_fd = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
       Unix.dup2 log_fd Unix.stdout;
       Unix.dup2 log_fd Unix.stderr;
       Unix.close log_fd;
       let pid = Unix.getpid () in
       write_pidfile pidfile_path pid;
       (assert false : daemon_start_result)
     | child_pid ->
       let deadline = Unix.gettimeofday () +. wait_timeout in
       let rec wait () =
         if Unix.gettimeofday () >= deadline then
           `Failed "pidfile not written before timeout"
         else
           match read_pidfile pidfile_path with
           | Some p when pid_is_alive p -> `Started p
           | _ ->
             (try ignore (Unix.waitpid [ Unix.WNOHANG ] child_pid)
              with Unix.Unix_error _ -> ());
             Unix.sleepf 0.1;
             wait ()
       in
       wait ())

(* ---------------------------------------------------------------------------
 * Effective submit delay (mirrors Python deliver-inbox)
 * --------------------------------------------------------------------------- *)

let effective_submit_delay ~(client : string) ~(submit_delay : float option) : float option =
  match submit_delay with
  | Some d -> Some d
  | None ->
    if client = "kimi" then Some 1.5
    else None

(* ---------------------------------------------------------------------------
 * STUB: run_loop — does nothing yet (S2 will add inbox polling)
 * --------------------------------------------------------------------------- *)

let run_loop ~(args : cli_args) ~(watched_pid : int option) : unit =
  let iterations = ref 0 in
  let total_delivered = ref 0 in
  let max_iterations = args.max_iterations in
  let rec loop () =
    match max_iterations with
    | Some m when !iterations >= m -> ()
    | _ ->
      incr iterations;
      Printf.printf "[c2c-deliver-inbox] iteration %d (stub — no-op)\n%!" !iterations;
      flush stdout;
      total_delivered := !total_delivered + 0;
      (match watched_pid with
       | Some wp when not (pid_is_alive wp) ->
         Printf.printf "[c2c-deliver-inbox] watched pid %d exited, stopping\n%!" wp;
         flush stdout;
         ()
       | _ ->
         Unix.sleepf args.interval;
         loop ())
  in
  loop ();
  Printf.printf "[c2c-deliver-inbox] loop finished after %d iterations\n%!" !iterations;
  flush stdout

(* ---------------------------------------------------------------------------
 * CLI argument parsing
 * --------------------------------------------------------------------------- *)

let parse_args () : cli_args =
  let session_id = ref None in
  let terminal_pid = ref None in
  let pts = ref None in
  let broker_root = ref None in
  let client = ref "generic" in
  let loop = ref false in
  let interval = ref 1.0 in
  let max_iterations = ref None in
  let pidfile = ref None in
  let daemon = ref false in
  let daemon_log = ref None in
  let daemon_timeout = ref 10.0 in
  let notify_only = ref false in
  let notify_debounce = ref 30.0 in
  let xml_output_fd = ref None in
  let xml_output_path = ref None in
  let event_fifo = ref None in
  let response_fifo = ref None in
  let file_fallback = ref false in
  let timeout = ref 5.0 in
  let submit_delay = ref None in
  let dry_run = ref false in
  let json = ref false in

  let speclist = [
    ("--session-id", Arg.String (fun s -> session_id := Some s),
     " broker session id to deliver");
    ("--broker-root", Arg.String (fun s -> broker_root := Some s),
     " broker root directory");
    ("--client", Arg.String (fun s -> client := s),
     " client type (claude|codex|codex-headless|opencode|kimi|crush|generic)");
    ("--loop", Arg.Set loop, " keep polling and delivering");
    ("--interval", Arg.Set_float interval, " polling interval in seconds");
    ("--max-iterations", Arg.Int (fun i -> max_iterations := Some i),
     " maximum loop iterations");
    ("--pidfile", Arg.String (fun s -> pidfile := Some s),
     " pidfile path");
    ("--daemon", Arg.Set daemon, " start detached");
    ("--daemon-log", Arg.String (fun s -> daemon_log := Some s),
     " daemon log path");
    ("--daemon-timeout", Arg.Set_float daemon_timeout,
     " timeout for daemon startup (default 10s)");
    ("--notify-only", Arg.Set notify_only,
     " peek only, inject poll_inbox nudge without content");
    ("--notify-debounce", Arg.Set_float notify_debounce,
     " minimum seconds between repeated notify nudges");
    ("--xml-output-fd", Arg.Int (fun i -> xml_output_fd := Some i),
     " write Codex XML frames to this fd");
    ("--xml-output-path", Arg.String (fun s -> xml_output_path := Some s),
     " write Codex XML frames by opening this fifo/path");
    ("--event-fifo", Arg.String (fun s -> event_fifo := Some s),
     " read Codex bridge permission events from this FIFO");
    ("--response-fifo", Arg.String (fun s -> response_fifo := Some s),
     " write permission approval decisions to this FIFO");
    ("--file-fallback", Arg.Set file_fallback,
     " use file-based broker when Unix socket unavailable");
    ("--timeout", Arg.Set_float timeout,
     " timeout for inbox drain operations (default 5s)");
    ("--submit-delay", Arg.Float (fun d -> submit_delay := Some d),
     " override delay between bracketed paste and Enter");
    ("--dry-run", Arg.Set dry_run,
     " peek and render without draining or injecting");
    ("--json", Arg.Set json, " output JSON");
    ("--pid", Arg.Int (fun i -> terminal_pid := Some i),
     " terminal/process pid");
    ("--terminal-pid", Arg.Int (fun i -> terminal_pid := Some i),
     " terminal/process pid (same as --pid)");
    ("--pts", Arg.String (fun s -> pts := Some s),
     " pts device (required with --terminal-pid)");
  ] in
  let anon _ = () in
  Arg.parse speclist anon "c2c-deliver-inbox [options]";
  let broker_root_val =
    match !broker_root with
    | Some b -> b
    | None -> failwith "--broker-root required"
  in
  {
    session_id = !session_id;
    terminal_pid = !terminal_pid;
    pts = !pts;
    broker_root = broker_root_val;
    client = !client;
    loop = !loop;
    interval = !interval;
    max_iterations = !max_iterations;
    pidfile = !pidfile;
    daemon = !daemon;
    daemon_log = !daemon_log;
    daemon_timeout = !daemon_timeout;
    notify_only = !notify_only;
    notify_debounce = !notify_debounce;
    xml_output_fd = !xml_output_fd;
    xml_output_path = !xml_output_path;
    event_fifo = !event_fifo;
    response_fifo = !response_fifo;
    file_fallback = !file_fallback;
    timeout = !timeout;
    submit_delay = !submit_delay;
    dry_run = !dry_run;
    json = !json;
  }

(* ---------------------------------------------------------------------------
 * Broker root resolution (mirrors c2c_poll_inbox.default_broker_root)
 * S1 stub: returns $C2C_MCP_BROKER_ROOT or $HOME/.c2c/repos/default/broker
 * --------------------------------------------------------------------------- *)

let default_broker_root () : string =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some b -> b
  | None ->
    let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
    home // ".c2c" // "repos" // "default" // "broker"

(* ---------------------------------------------------------------------------
 * OCaml program body — the `let () =` below IS the executable entry point.
 * --------------------------------------------------------------------------- *)

let () =
  let args = parse_args () in
  let broker_root =
    if args.broker_root <> "" then args.broker_root
    else default_broker_root ()
  in
  let session_id =
    match args.session_id with
    | Some s -> s
    | None -> failwith "--session-id required"
  in
  let pidfile_path =
    match args.pidfile with
    | Some p -> p
    | None ->
      let state_dir = Filename.concat (Sys.getcwd ()) ".c2c-deliver-state" in
      (try Unix.mkdir state_dir 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      Filename.concat state_dir (session_id ^ ".pid")
  in
  let log_path =
    match args.daemon_log with
    | Some l -> l
    | None -> pidfile_path ^ ".log"
  in

  if args.daemon then begin
    (* _child_argv deferred to S2 (exec in child process) *)
    match start_daemon
        ~_child_argv:(Sys.argv |> Array.to_list)
        ~pidfile_path
        ~log_path
        ~wait_timeout:args.daemon_timeout with
    | `Already_running pid ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc [
              "ok", `Bool true;
              "daemon", `Bool true;
              "already_running", `Bool true;
              "pid", `Int pid;
              "pidfile", `String pidfile_path;
              "log_path", `String log_path;
            ]))
      else
        Printf.printf "daemon already running pid=%d\n" pid
    | `Started pid ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc [
              "ok", `Bool true;
              "daemon", `Bool true;
              "already_running", `Bool false;
              "pid", `Int pid;
              "pidfile", `String pidfile_path;
              "log_path", `String log_path;
            ]))
      else
        Printf.printf "daemon started pid=%d\n" pid
    | `Failed msg ->
      if args.json then
        Printf.printf "%s\n"
          (Yojson.Safe.pretty_to_string (
            `Assoc ["ok", `Bool false; "error", `String msg]))
      else
        Printf.eprintf "daemon start failed: %s\n" msg;
      exit 1
  end else begin
    let watched_pid = args.terminal_pid in
    if args.loop then
      run_loop ~args ~watched_pid
    else
      Printf.printf "[c2c-deliver-inbox] session=%s broker_root=%s client=%s (single-shot stub)\n%!"
        session_id broker_root args.client
  end
