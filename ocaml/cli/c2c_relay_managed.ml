(* c2c_relay_managed.ml — machine-wide supervised relay connector.

   There is deliberately one connector per local user/machine, not one per
   repository or managed instance name.  The supervisor owns a POSIX lock for
   its lifetime, launches `c2c relay connect` as a child, and replaces that
   child when the c2c executable at the launch path changes.  This means an
   install/update takes effect without asking the operator to reconnect. *)

let ( // ) = Filename.concat

let instances_dir () =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")

let machine_state_dir () =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c")

let machine_lock_resource () = machine_state_dir () // "relay-connect"

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

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

(** B212: resolve the relaunch parameters (relay URL + poll interval) for the
    machine connector from its persisted supervisor [config.json] fields.
    [relay_url] persists as [`Null] when the connector was started from
    [$C2C_RELAY_URL] rather than [--relay-url]; fall back to the env var in
    that case.  Returns [Error msg] with an actionable message when no relay
    URL can be determined at all, so [restart] can print a clear error instead
    of failing deep inside a re-launch. *)
let restart_params_of_config (fields : (string * Yojson.Safe.t) list) :
    (string option * int, string) result =
  let relay_url =
    match List.assoc_opt "relay_url" fields with
    | Some (`String u) when String.trim u <> "" -> Some u
    | _ ->
        (* An empty/whitespace $C2C_RELAY_URL is not a usable URL — treat it as
           unset so restart reports the clear no-URL error rather than trying to
           relaunch with a blank URL. *)
        (match Sys.getenv_opt "C2C_RELAY_URL" with
         | Some u when String.trim u <> "" -> Some u
         | _ -> None)
  in
  let interval =
    match List.assoc_opt "interval" fields with
    | Some (`Int i) -> i
    | Some (`Float f) -> int_of_float f
    | _ -> 30
  in
  match relay_url with
  | None ->
      Error
        "no relay URL is known (config has no relay_url and $C2C_RELAY_URL is \
         unset); restart it explicitly with: c2c start relay-connect \
         --relay-url <URL>"
  | Some _ -> Ok (relay_url, interval)

(** B212: restart the one machine-wide relay connector.  `c2c restart
    relay-connect` previously fell through to the harness-client restart path,
    whose [load_config_opt] raised an uncaught [Not_found] on the connector's
    minimal supervisor [config.json].  Stop the current supervisor (SIGTERM its
    outer pid, wait up to [timeout_s], then SIGKILL) so the machine singleton
    lock is released, then start a fresh supervisor reusing the persisted relay
    URL + interval.  [start] is [@noreturn]: it daemonizes and exits, so this
    only returns (with an int status) on the no-URL error path. *)
let restart ~name ~fields ~broker_root ~timeout_s : int =
  match restart_params_of_config fields with
  | Error msg ->
      Printf.eprintf "error: cannot restart relay connector '%s': %s\n%!" name msg;
      1
  | Ok (relay_url, interval) ->
      let inst_dir = instances_dir () // name in
      let pid_path = inst_dir // "outer.pid" in
      (match read_pidfile pid_path with
       | Some pid when pid_alive pid ->
           Printf.eprintf
             "[c2c restart] stopping relay connector supervisor pid %d for '%s'...\n%!"
             pid name;
           (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
           let deadline = Unix.gettimeofday () +. timeout_s in
           let rec wait () =
             if pid_alive pid && Unix.gettimeofday () < deadline then
               (Unix.sleepf 0.1; wait ())
           in
           wait ();
           if pid_alive pid then begin
             Printf.eprintf
               "[c2c restart] supervisor pid %d did not exit within %.0fs; sending SIGKILL\n%!"
               pid timeout_s;
             (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
           end
       | _ ->
           Printf.eprintf
             "[c2c restart] no live relay connector supervisor for '%s'; starting a fresh one\n%!"
             name);
      start ~name ~daemon:true ~relay_url ~broker_root ~interval ~extra_args:[] ()
