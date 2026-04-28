(* c2c_relay_managed.ml — managed `c2c start relay-connect` daemon.

   Wraps the existing `c2c relay connect` foreground process in the same
   managed-instance discipline used by `c2c start <client>` for harness
   sessions: instance dir under ~/.local/share/c2c/instances/<name>/,
   `config.json` for `c2c instances` listing, `outer.pid` for `c2c stop`,
   and a log file for the daemon's stdout/stderr.

   Design choices:
   - **Single-fork daemonization** (parent → child). Parent writes the
     pidfile with the child's PID and exits; child sets up its session,
     redirects stdio to the log file, and execs `c2c relay connect`.
     Simpler than classic double-fork; sufficient for our use because we
     don't need to detach from a controlling terminal that the user
     cares about reattaching to.
   - **Auto-restart NOT implemented in v1.** The connector is a single
     long-running process. If it crashes the user re-runs
     `c2c start relay-connect`. Future iteration: wrap the exec'd child
     in a respawn loop, like the `run-*-inst-outer` scripts did for
     harness clients. Keeping v1 simple to ship; documented in the
     commit body.
   - **Foreground mode (`--no-daemon`)**: we still create the instance
     dir + config so `c2c instances` lists it, but we exec without
     forking. The pidfile records our own PID. Useful for tmux-managed
     dogfooding. *)

let ( // ) = Filename.concat

let instances_dir () =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")

let mkdir_p path = C2c_utils.mkdir_p path

let json_to_file path json =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> try close_out oc with _ -> ()) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')

let write_pidfile path pid =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> try close_out oc with _ -> ()) (fun () ->
      output_string oc (string_of_int pid);
      output_char oc '\n')

let read_pidfile path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> try close_in ic with _ -> ()) (fun () ->
          let line = String.trim (input_line ic) in
          int_of_string_opt line)
    with _ -> None

let pid_alive pid =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

(** [resolve_self_binary ()] returns the path to the currently running
    `c2c` executable, used to relaunch ourselves as `c2c relay connect`. *)
let resolve_self_binary () =
  (* Best effort — fall back to "c2c" on PATH. *)
  match Sys.argv.(0) with
  | "" | "c2c" -> "c2c"
  | path when Filename.is_relative path ->
      (* dune exe path or PATH lookup *)
      if Sys.file_exists path then
        (* relative — qualify against cwd *)
        Filename.concat (Sys.getcwd ()) path
      else "c2c"
  | path -> path

(* ------------------------------------------------------------------------ *)
(* Public entry                                                             *)
(* ------------------------------------------------------------------------ *)

(** [start ~name ~daemon ~relay_url ~interval ~extra_args ()] is the entry
    point for `c2c start relay-connect`. Sets up the instance dir, then
    either forks a daemon or execs in-place. Returns the exit code (in
    foreground mode the daemon's exec replaces us, so this only returns
    on error). *)
let start ~name ~daemon ~relay_url ~interval ~extra_args () =
  let inst_dir = instances_dir () // name in
  let outer_pid_path = inst_dir // "outer.pid" in
  let log_path = inst_dir // "log" in
  let config_path = inst_dir // "config.json" in

  (* Refuse if there's already a live PID for this instance. *)
  (match read_pidfile outer_pid_path with
   | Some pid when pid_alive pid ->
       Printf.eprintf
         "error: relay-connect instance '%s' already running (pid=%d).\n\
          Stop it first: c2c stop %s\n%!" name pid name;
       exit 1
   | _ -> ());

  mkdir_p inst_dir;

  (* Write config.json so `c2c instances` recognises this as a managed
     instance. The `client` field is the discriminator. *)
  let config = `Assoc [
    ("client", `String "relay-connect");
    ("created_at", `Float (Unix.gettimeofday ()));
    ("relay_url", (match relay_url with Some u -> `String u | None -> `Null));
    ("interval", `Int interval);
  ] in
  json_to_file config_path config;

  (* Build relay-connect argv. We dispatch through the c2c binary itself
     (`c2c relay connect ...`) rather than calling Lwt entrypoints
     directly — that path is already battle-tested and keeps a single
     code path for the connector logic. *)
  let self = resolve_self_binary () in
  let argv = ref [ self; "relay"; "connect" ] in
  (match relay_url with
   | Some u -> argv := !argv @ [ "--relay-url"; u ]
   | None -> ());
  argv := !argv @ [ "--interval"; string_of_int interval ];
  argv := !argv @ extra_args;

  if not daemon then begin
    (* Foreground mode: write our own pid, exec in place. *)
    write_pidfile outer_pid_path (Unix.getpid ());
    Printf.printf "[c2c start relay-connect] foreground pid=%d log=%s\n%!"
      (Unix.getpid ()) log_path;
    Printf.printf "[c2c start relay-connect] argv: %s\n%!"
      (String.concat " " !argv);
    Unix.execvp self (Array.of_list !argv)
  end else begin
    (* Daemon mode: fork; parent writes pidfile + exits, child sets up
       its session and execs the connector. *)
    flush_all ();
    match Unix.fork () with
    | 0 ->
        (* Child: detach + redirect stdio + exec. *)
        let _ = (try Unix.setsid () with _ -> 0) in
        (try Unix.chdir "/" with _ -> ());
        (try
           let dn = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
           Unix.dup2 dn Unix.stdin;
           Unix.close dn
         with _ -> ());
        (try
           let log_fd =
             Unix.openfile log_path
               [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
           in
           Unix.dup2 log_fd Unix.stdout;
           Unix.dup2 log_fd Unix.stderr;
           Unix.close log_fd
         with _ -> ());
        Unix.execvp self (Array.of_list !argv)
    | child_pid ->
        write_pidfile outer_pid_path child_pid;
        Printf.printf
          "[c2c start relay-connect] daemonized pid=%d log=%s\n\
           [c2c start relay-connect] stop with: c2c stop %s\n%!"
          child_pid log_path name;
        exit 0
  end
