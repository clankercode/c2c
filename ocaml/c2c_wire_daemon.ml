(** Kimi Wire daemon lifecycle management.

    Manages background `c2c_wire_bridge` daemon processes that deliver
    c2c broker messages via `kimi --wire`.

    State directory: ~/.local/share/c2c/wire-daemons/
    Each session has a <session-id>.pid and <session-id>.log file there. *)

let ( // ) = Filename.concat

let home () = Sys.getenv "HOME"

let state_dir () =
  let xdg =
    match Sys.getenv_opt "XDG_DATA_HOME" with
    | Some s when s <> "" -> s
    | _ -> home () // ".local" // "share"
  in
  xdg // "c2c" // "wire-daemons"

let pidfile_path session_id = state_dir () // (session_id ^ ".pid")
let logfile_path session_id = state_dir () // (session_id ^ ".log")

let read_pid pidfile =
  try
    let raw = String.trim (In_channel.input_all (open_in pidfile)) in
    int_of_string_opt raw
  with _ -> None

let pid_is_alive pid =
  if pid <= 0 then false
  else
    try Unix.kill pid 0; true
    with
    | Unix.Unix_error (Unix.ESRCH, _, _) -> false
    | Unix.Unix_error (Unix.EPERM, _, _) -> true

type daemon_status =
  { session_id : string
  ; running    : bool
  ; pid        : int option
  ; pidfile    : string
  ; logfile    : string option
  }

let get_status session_id =
  let pf = pidfile_path session_id in
  let pid = read_pid pf in
  let running = match pid with Some p -> pid_is_alive p | None -> false in
  { session_id; running; pid; pidfile = pf
  ; logfile = (if running then Some (logfile_path session_id) else None)
  }

let list_daemons () =
  let dir = state_dir () in
  if not (Sys.file_exists dir) then []
  else begin
    let entries =
      try Array.to_list (Sys.readdir dir)
      with Sys_error _ -> []
    in
    List.filter_map (fun fname ->
        if Filename.check_suffix fname ".pid" then
          Some (Filename.chop_suffix fname ".pid")
        else None)
      entries
    |> List.map get_status
  end

(** Ensure state directory exists. *)
let ensure_state_dir () = C2c_io.mkdir_p (state_dir ())

(** Start a wire bridge daemon for the given session.
    Forks a detached child that runs the wire bridge loop.
    Returns the daemon status after starting. *)
let start_daemon ~session_id ~alias ~broker_root ~command ~work_dir ~interval =
  let existing = get_status session_id in
  if existing.running then
    (existing, `Already_running)
  else begin
    ensure_state_dir ();
    let pidfile = pidfile_path session_id in
    let logfile = logfile_path session_id in
    (* Build the wire bridge loop: fork a child process *)
    match Unix.fork () with
    | 0 ->
        (* Child: become session leader, redirect stdout/stderr to log *)
        ignore (Unix.setsid ());
        let log_fd =
          Unix.openfile logfile
            [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
        in
        Unix.dup2 log_fd Unix.stdout;
        Unix.dup2 log_fd Unix.stderr;
        Unix.close log_fd;
        (* Write our own pidfile *)
        let pid = Unix.getpid () in
        let oc = open_out pidfile in
        Printf.fprintf oc "%d\n" pid;
        close_out oc;
        (* Run deliver loop *)
        while true do
          (try
             let n = C2c_wire_bridge.run_once_live
                 ~broker_root ~session_id ~alias ~command ~work_dir
             in
             if n > 0 then
               Printf.printf "[wire-daemon] delivered %d message(s)\n%!" n
           with exn ->
             Printf.printf "[wire-daemon] error: %s\n%!" (Printexc.to_string exn));
          Unix.sleepf interval
        done;
        exit 0
    | child_pid ->
        (* Parent: wait briefly for pidfile to appear, then return *)
        let deadline = Unix.gettimeofday () +. 3.0 in
        let rec wait () =
          if Unix.gettimeofday () < deadline then begin
            if Sys.file_exists pidfile && read_pid pidfile <> None then ()
            else begin Unix.sleepf 0.05; wait () end
          end
        in
        wait ();
        ignore (Unix.waitpid [ Unix.WNOHANG ] child_pid);
        let status = get_status session_id in
        (status, `Started)
  end

let stop_daemon session_id =
  let st = get_status session_id in
  if not st.running then
    (st, `Not_running)
  else begin
    let pid = Option.get st.pid in
    (try Unix.kill pid Sys.sigterm
     with Unix.Unix_error _ -> ());
    (* Wait up to 3s for it to die *)
    let deadline = Unix.gettimeofday () +. 3.0 in
    let rec wait () =
      if not (pid_is_alive pid) then ()
      else if Unix.gettimeofday () < deadline then begin
        Unix.sleepf 0.1; wait ()
      end else
        (try Unix.kill pid Sys.sigkill with _ -> ())
    in
    wait ();
    (try Sys.remove st.pidfile with _ -> ());
    ({ st with running = false }, `Stopped)
  end

let status_to_json st =
  `Assoc
    ([ ("session_id", `String st.session_id)
     ; ("running",    `Bool st.running)
     ; ("pid",        match st.pid with Some p -> `Int p | None -> `Null)
     ; ("pidfile",    `String st.pidfile)
     ]
     @ (match st.logfile with
        | Some l -> [ ("log", `String l) ]
        | None -> []))
