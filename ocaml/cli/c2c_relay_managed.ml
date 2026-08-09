(* c2c_relay_managed.ml — machine-wide supervised relay connector.

   There is deliberately one connector per local user/machine, not one per
   repository or managed instance name.  The supervisor owns a POSIX lock for
   its lifetime, launches `c2c relay connect` as a child, and replaces that
   child when the c2c executable at the launch path changes.  This means an
   install/update takes effect without asking the operator to reconnect. *)

let ( // ) = Filename.concat

(* Keep the relay connector's config, pid, log, and singleton-lock paths in
   lockstep with [C2c_start.instances_dir].  This matters for isolated test/dev
   environments: without the override here, restart could read config from
   [$C2C_INSTANCES_DIR] while signalling a supervisor under [$HOME]. *)
let instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      Filename.concat (Sys.getenv "HOME")
        (".local" // "share" // "c2c" // "instances")

let machine_state_dir () = Filename.dirname (instances_dir ())

let machine_lock_resource () = machine_state_dir () // "relay-connect"

(* B210: the machine-wide connector singleton is enforced at BOTH the managed
   supervisor ([run_owner]) and the bare `c2c relay connect` CLI, so stray
   connectors (bare, or manual `--all-brokers`) cannot pile up and storm the
   relay with 429s. The two cannot share one POSIX lock — the supervisor holds
   the lock and forks+execs its connector child, and a POSIX record lock is
   owned per-process, so the child re-acquiring the same lockfile would see
   EAGAIN. The child is therefore EXEMPTED from the CLI-side check via this env
   var, which the supervisor sets before exec; the supervisor's own lock still
   guards against a second supervisor and against any bare connector. *)
let supervised_child_env = "C2C_RELAY_CONNECT_SUPERVISED"

(* Conventional instance name for the machine-wide supervised connector
   (`c2c start relay-connect` with no -n). B235 restart bootstrap uses this. *)
let default_instance_name = "relay-connect"

let is_default_relay_connect_name name =
  String.equal (String.trim name) default_instance_name

(* B235: bare `c2c relay connect` (not --once, not a supervised child) has no
   outer supervisor. If the process dies, remote DMs stop until an operator
   restarts it. Return a multi-line stderr warning; None when supervised or
   one-shot (no warning needed). Pure for unit tests. *)
let unsupervised_warning ~supervised ~once ~relay_url =
  if supervised || once then None
  else
    Some
      (Printf.sprintf
         "WARNING: unsupervised relay connector (B235).\n\
          This process is NOT supervised — if it exits, remote DMs stop\n\
          delivering with nothing restarting it.\n\
          Prefer:  c2c start relay-connect --relay-url %s\n\
          Recover: c2c restart relay-connect\n\
          Check:   c2c doctor --relay\n"
         relay_url)

let is_supervised_child () =
  Sys.getenv_opt supervised_child_env = Some "1"

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* B210: acquire the machine-wide connector singleton for a bare/unsupervised
   `c2c relay connect`. Supervised children are exempt (their supervisor owns
   the lock). Returns [`Exempt] for the supervised child, [`Acquired fd] for
   the sole owner (keep the fd for the process lifetime — closing or process
   exit releases it), or [`Already_running] when another connector already
   owns the host. Callers should refuse to start a duplicate persistent
   connector on [`Already_running]. *)
let acquire_connector_singleton () =
  if is_supervised_child () then `Exempt
  else begin
    mkdir_p (machine_state_dir ());
    match C2c_singleton_lock.try_acquire ~path:(machine_lock_resource ()) with
    | C2c_singleton_lock.Already_running -> `Already_running
    | C2c_singleton_lock.Acquired fd -> `Acquired fd
  end

(* First non-empty candidate among [candidates]. Pure helper for URL
   resolution in restart/bootstrap (env, saved config, override). *)
let first_nonempty_url candidates =
  List.find_map
    (function
      | Some s when String.trim s <> "" -> Some (String.trim s)
      | _ -> None)
    candidates

let json_to_file path json =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')

let write_pidfile path pid =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc (string_of_int pid);
      output_char oc '\n')

let read_pidfile path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          int_of_string_opt (String.trim (input_line ic)))
    with _ -> None

let pid_alive pid =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

let executable_on_path name =
  let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
  String.split_on_char ':' path
  |> List.find_map (fun dir ->
         let dir = if dir = "" then "." else dir in
         let candidate = dir // name in
         if Sys.file_exists candidate then
           try Unix.access candidate [ Unix.X_OK ]; Some candidate
           with Unix.Unix_error _ -> None
         else None)

(** Resolve argv[0] to a stable absolute path.  In particular, keep the path
    rather than /proc/self/exe: package installs atomically replace the path,
    while /proc/self/exe continues to name the old inode. *)
let resolve_self_binary () =
  let raw = Sys.argv.(0) in
  let path =
    if raw = "" then Option.value (executable_on_path "c2c") ~default:"c2c"
    else if Filename.is_relative raw && not (String.contains raw '/') then
      Option.value (executable_on_path raw) ~default:raw
    else if Filename.is_relative raw then Sys.getcwd () // raw
    else raw
  in
  (* Do not [realpath] this. Installers may atomically replace either this
     path or a symlink at this path; following it once would pin the supervisor
     to the old target and hide the update. *)
  path

type binary_stamp = {
  dev : int;
  ino : int;
  size : int;
  mtime : float;
}

let binary_stamp path =
  try
    let st = Unix.stat path in
    Some { dev = st.st_dev; ino = st.st_ino; size = st.st_size; mtime = st.st_mtime }
  with Unix.Unix_error _ -> None

let binary_changed ~before ~after = before <> after

let write_config ~config_path ~relay_url ~interval =
  json_to_file config_path (`Assoc [
    ("client", `String "relay-connect");
    ("scope", `String "machine");
    ("supervised", `Bool true);
    ("created_at", `Float (Unix.gettimeofday ()));
    ("relay_url", (match relay_url with Some u -> `String u | None -> `Null));
    ("interval", `Int interval);
  ])

let connector_argv ~self ~broker_root ~relay_url ~interval ~extra_args =
  let argv = ref [ self; "relay"; "connect"; "--all-brokers";
                   "--broker-root"; broker_root ] in
  Option.iter (fun u -> argv := !argv @ [ "--relay-url"; u ]) relay_url;
  !argv @ [ "--interval"; string_of_int interval ] @ extra_args

let remove_pidfile_if_owned path =
  match read_pidfile path with
  | Some pid when pid = Unix.getpid () -> (try Unix.unlink path with _ -> ())
  | _ -> ()

let child_status_code = function
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

let spawn_connector ~self ~argv ~log_path ~foreground =
  match Unix.fork () with
  | 0 ->
      if not foreground then begin
        (try
           let dn = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
           Unix.dup2 dn Unix.stdin; Unix.close dn
         with _ -> ());
        (try
           let fd = Unix.openfile log_path
               [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600 in
           Unix.dup2 fd Unix.stdout; Unix.dup2 fd Unix.stderr; Unix.close fd
         with _ -> ())
      end;
      (* B210: mark the child exempt from the CLI-side connector singleton —
         this supervisor already holds the machine lock. *)
      (try Unix.putenv supervised_child_env "1" with _ -> ());
      (try Unix.execv self (Array.of_list argv)
       with exn ->
         Printf.eprintf "relay-connect: exec %s failed: %s\n%!" self
           (Printexc.to_string exn);
         exit 127)
  | pid -> pid

let redirect_daemon_stdio log_path =
  (try
     let dn = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
     Unix.dup2 dn Unix.stdin; Unix.close dn
   with _ -> ());
  (try
     let fd = Unix.openfile log_path
         [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600 in
     Unix.dup2 fd Unix.stdout; Unix.dup2 fd Unix.stderr; Unix.close fd
   with _ -> ())

let supervise ~self ~argv ~log_path ~pid_path ~foreground =
  let stopping = ref false in
  let child = ref None in
  let request_stop _ =
    stopping := true;
    match !child with
    | Some pid -> (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ())
    | None -> ()
  in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle request_stop);
  Sys.set_signal Sys.sigint (Sys.Signal_handle request_stop);
  let cleanup () =
    (match !child with
     | Some pid -> (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ())
     | None -> ());
    remove_pidfile_if_owned pid_path
  in
  Fun.protect ~finally:cleanup (fun () ->
    let rec launch () =
      let launched_stamp = binary_stamp self in
      let pid = spawn_connector ~self ~argv ~log_path ~foreground in
      child := Some pid;
      let rec monitor () =
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ when !stopping ->
            Unix.sleepf 0.1; monitor ()
        | 0, _ when binary_changed ~before:launched_stamp ~after:(binary_stamp self) ->
            Printf.eprintf
              "[c2c relay-connect] c2c executable updated; restarting connector\n%!";
            (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
            ignore (Unix.waitpid [] pid);
            child := None;
            `Restart
        | 0, _ -> Unix.sleepf 0.5; monitor ()
        | _, status ->
            child := None;
            if !stopping then `Exit 0 else `Exit (child_status_code status)
      in
      match monitor () with
      | `Restart -> launch ()
      | `Exit code when code <> 0 && not !stopping ->
          Printf.eprintf
            "[c2c relay-connect] connector exited %d; retrying in 1s\n%!" code;
          Unix.sleepf 1.0;
          launch ()
      | `Exit code -> code
    in
    launch ())

let run_owner ~self ~broker_root ~name ~relay_url ~interval ~extra_args
    ~foreground ~ready_fd =
  mkdir_p (machine_state_dir ());
  match C2c_singleton_lock.try_acquire ~path:(machine_lock_resource ()) with
  | Already_running ->
      (match ready_fd with
       | Some fd -> ignore (Unix.write_substring fd "ALREADY\n" 0 8); Unix.close fd
       | None -> ());
      Printf.eprintf
        "error: a machine-wide relay connector is already running.\n\
         Use 'c2c instances' to find it; only one connection is needed.\n%!";
      1
  | Acquired lock_fd ->
      let inst_dir = instances_dir () // name in
      let pid_path = inst_dir // "outer.pid" in
      let log_path = inst_dir // "log" in
      mkdir_p inst_dir;
      (* The supervisor, not only its connector child, must detach its file
         descriptors. Otherwise command substitutions and non-interactive
         callers keep waiting on a pipe held open by the daemon. *)
      if not foreground then redirect_daemon_stdio log_path;
      write_config ~config_path:(inst_dir // "config.json") ~relay_url ~interval;
      write_pidfile pid_path (Unix.getpid ());
      (match ready_fd with
       | Some fd -> ignore (Unix.write_substring fd "READY\n" 0 6); Unix.close fd
       | None -> ());
      let argv = connector_argv ~self ~broker_root ~relay_url ~interval ~extra_args in
      let code =
        Fun.protect
          ~finally:(fun () -> C2c_singleton_lock.release lock_fd)
          (fun () -> supervise ~self ~argv ~log_path ~pid_path ~foreground)
      in
      code

let read_ready fd =
  let buf = Bytes.create 16 in
  let n = Unix.read fd buf 0 (Bytes.length buf) in
  Bytes.sub_string buf 0 n

(* B212: the machine-wide relay connector persists a distinct config shape
   ({client:"relay-connect", scope:"machine", supervised:true, relay_url,
   interval}) that deliberately omits the session_id/alias/resume fields the
   harness-client [C2c_start.load_config_opt] requires. Feeding that config to
   the harness restart path raised an uncaught [Not_found]; [c2c restart
   relay-connect] must recognise it and drive the machine lifecycle instead. *)
type managed_config = {
  mc_relay_url : string option;
  mc_interval : int;
}

(* Pure classifier: is this JSON a supervised relay-connect config? If so,
   extract the relay URL + poll interval. Never raises. *)
let parse_managed_config (json : Yojson.Safe.t) : managed_config option =
  match json with
  | `Assoc a ->
      let is_relay_connect =
        (match List.assoc_opt "client" a with
         | Some (`String "relay-connect") -> true
         | _ -> false)
        || (match List.assoc_opt "supervised" a with
            | Some (`Bool true) -> true
            | _ -> false)
      in
      if not is_relay_connect then None
      else
        let mc_relay_url =
          match List.assoc_opt "relay_url" a with
          | Some (`String s) when String.trim s <> "" -> Some s
          | _ -> None
        in
        let mc_interval =
          match List.assoc_opt "interval" a with
          | Some (`Int i) when i > 0 -> i
          | _ -> 30
        in
        Some { mc_relay_url; mc_interval }
  | _ -> None

(* Read the named instance's config.json and classify it. Returns None when
   the instance dir has no config, the config is not JSON, or it is some other
   managed client (not the supervised relay connector). Never raises. *)
let read_managed_config ~name : managed_config option =
  let path = instances_dir () // name // "config.json" in
  if not (Sys.file_exists path) then None
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some json -> parse_managed_config json
    | None -> None

(* Stop the supervisor recorded in the instance's outer.pid (SIGTERM, then
   SIGKILL after [timeout_s]). Returns true when no supervisor is running or
   it has exited; false if a pid is still alive after the SIGKILL fallback. *)
let stop_supervisor ~name ~timeout_s : bool =
  let pid_path = instances_dir () // name // "outer.pid" in
  match read_pidfile pid_path with
  | Some pid when pid_alive pid
                  && not (C2c_pid_identity.pidfile_pid_is_ours ~pidfile:pid_path ~pid) ->
      (* #85: the number is live but was recycled onto another process. There is
         no supervisor to stop, and signalling it would hit a stranger. *)
      true
  | Some pid when pid_alive pid ->
      (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
      let deadline = Unix.gettimeofday () +. timeout_s in
      let rec wait () =
        if not (pid_alive pid) then true
        else if Unix.gettimeofday () >= deadline then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          Unix.sleepf 0.2;
          not (pid_alive pid)
        end
        else (Unix.sleepf 0.1; wait ())
      in
      wait ()
  | _ -> true

(** Start the one machine-wide relay service.  A different [name] changes
    only its managed display/stop name; it cannot create a second connector. *)
let[@noreturn] start ~name ~daemon ~relay_url ~broker_root ~interval ~extra_args () =
  (* Resolve before daemon mode chdirs to /. Relative checkout invocations
     such as ./_build/default/ocaml/cli/c2c.exe must keep working. *)
  let self = resolve_self_binary () in
  if not daemon then
    exit (run_owner ~self ~broker_root ~name ~relay_url ~interval ~extra_args
            ~foreground:true ~ready_fd:None)
  else begin
    let ready_r, ready_w = Unix.pipe ~cloexec:false () in
    flush_all ();
    match Unix.fork () with
    | 0 ->
        Unix.close ready_r;
        ignore (try Unix.setsid () with _ -> 0);
        (try Unix.chdir "/" with _ -> ());
        exit (run_owner ~self ~broker_root ~name ~relay_url ~interval ~extra_args
                ~foreground:false ~ready_fd:(Some ready_w))
    | supervisor_pid ->
        Unix.close ready_w;
        let status = read_ready ready_r in
        Unix.close ready_r;
        if status = "READY\n" then begin
          Printf.printf
            "[c2c start relay-connect] machine-wide supervisor pid=%d\n\
             [c2c start relay-connect] stop with: c2c stop %s\n%!"
            supervisor_pid name;
          exit 0
        end else begin
          ignore (Unix.waitpid [] supervisor_pid);
          exit 1
        end
  end

(** Restart the machine-wide relay connector [name]: stop the running
    supervisor, resolve its relay URL (saved config → override →
    [C2C_RELAY_URL]), then relaunch the daemon.

    B235: when [name] is the conventional [default_instance_name] and no
    managed config exists (typical after an ad-hoc `c2c relay connect` died),
    bootstrap a supervised instance instead of failing with "no config found".
    [relay_url_override] lets the CLI pass the same URL resolution as
    `relay setup` / `C2C_RELAY_URL` without coupling this module to the
    full CLI config loader.

    Returns a clean nonzero exit with an actionable message (never an uncaught
    exception) when the name is not a managed relay connector and cannot be
    bootstrapped, or no relay URL can be resolved. Does not return on success
    (relaunches via the [@noreturn] [start]). *)
let restart ?(relay_url_override : string option) ~name ~broker_root ~timeout_s
    () =
  let env_url =
    match Sys.getenv_opt "C2C_RELAY_URL" with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  match read_managed_config ~name with
  | None when not (is_default_relay_connect_name name) ->
      Printf.eprintf
        "error: '%s' is not a managed relay connector.\n\
        \  Use 'c2c instances' to find managed sessions and 'c2c restart NAME' for one.\n\
        \  For the machine-wide bridge: c2c start relay-connect --relay-url <URL>\n\
        \  or c2c restart relay-connect (bootstraps when URL is known).\n%!"
        name;
      exit 1
  | None ->
      (* B235 bootstrap: ad-hoc connector left no supervised config. *)
      let relay_url =
        first_nonempty_url [ relay_url_override; env_url ]
      in
      (match relay_url with
       | None ->
           Printf.eprintf
             "error: no managed config for '%s' and no relay URL known.\n\
             \  Ad-hoc `c2c relay connect` is unsupervised (B235).\n\
             \  Start the supervised connector:\n\
             \    c2c start relay-connect --relay-url <URL>\n\
             \  Or set C2C_RELAY_URL / run `c2c relay setup --url <URL>`, then:\n\
             \    c2c restart relay-connect\n%!"
             name;
           exit 1
       | Some url ->
           (* Best-effort: stop a prior supervised pid if any (usually none). *)
           ignore (stop_supervisor ~name ~timeout_s);
           Printf.printf
             "[c2c restart] no managed config for '%s'; starting supervised \
              connector (B235)\n\
              [c2c restart] prefer `c2c start relay-connect` over bare \
              `c2c relay connect` so crashes auto-restart\n%!"
             name;
           start ~name ~daemon:true ~relay_url:(Some url) ~broker_root
             ~interval:30 ~extra_args:[] ())
  | Some mc ->
      let relay_url =
        first_nonempty_url [ mc.mc_relay_url; relay_url_override; env_url ]
      in
      (match relay_url with
       | None ->
           Printf.eprintf
             "error: cannot restart relay connector '%s': no relay URL known.\n\
             \  The saved config has no relay_url and C2C_RELAY_URL is unset.\n\
             \  Restart it explicitly: c2c start relay-connect --relay-url <URL>\n%!"
             name;
           exit 1
       | Some _ ->
           if not (stop_supervisor ~name ~timeout_s) then begin
             Printf.eprintf
               "error: could not stop the existing relay connector '%s' \
                (supervisor pid still alive after SIGKILL).\n\
               \  Investigate with 'c2c instances', then retry.\n%!"
               name;
             exit 1
           end;
           Printf.printf
             "[c2c restart] relaunching machine-wide relay connector '%s'\n%!"
             name;
           start ~name ~daemon:true ~relay_url ~broker_root
             ~interval:mc.mc_interval ~extra_args:[] ())
