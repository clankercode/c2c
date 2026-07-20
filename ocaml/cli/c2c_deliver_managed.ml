(* c2c_deliver_managed.ml — machine-wide supervised delivery service (#35 phase 1).

   Scaffold only: one supervised singleton per local user/machine, modeled on
   [C2c_relay_managed]. Owns a POSIX machine lock + pidfile for its lifetime.
   Phase 1 has NO client adapters and does not change any delivery path; the
   process simply holds the lock and idles so start/stop/doctor/tests can
   prove the skeleton. Later phases add watchers and per-client adapters. *)

let ( // ) = Filename.concat

(* Keep state next to [C2c_start.instances_dir] / [C2c_relay_managed] so isolated
   test/dev environments (C2C_INSTANCES_DIR) cannot contend with the real HOME
   singleton. *)
let instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      Filename.concat (Sys.getenv "HOME")
        (".local" // "share" // "c2c" // "instances")

let machine_state_dir () = Filename.dirname (instances_dir ())

let machine_lock_resource () = machine_state_dir () // "deliver-service"

(** Conventional instance name for `c2c start deliver-service` (no -n). *)
let default_instance_name = "deliver-service"

let is_default_deliver_service_name name =
  String.equal (String.trim name) default_instance_name

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

let write_config ~config_path =
  json_to_file config_path
    (`Assoc
       [ ("client", `String "deliver-service")
       ; ("scope", `String "machine")
       ; ("supervised", `Bool true)
       ; ("phase", `Int 1)
       ; ("created_at", `Float (Unix.gettimeofday ()))
       ])

type managed_config = { mc_phase : int }

let parse_managed_config (json : Yojson.Safe.t) : managed_config option =
  match json with
  | `Assoc a ->
      let is_deliver =
        (match List.assoc_opt "client" a with
         | Some (`String "deliver-service") -> true
         | _ -> false)
        || (match List.assoc_opt "supervised" a, List.assoc_opt "scope" a with
            | Some (`Bool true), Some (`String "machine") ->
                (* Distinguish from relay-connect: require client tag when both
                   supervised+machine appear. Prefer explicit client match. *)
                (match List.assoc_opt "client" a with
                 | Some (`String "deliver-service") -> true
                 | _ -> false)
            | _ -> false)
      in
      if not is_deliver then None
      else
        let mc_phase =
          match List.assoc_opt "phase" a with
          | Some (`Int i) when i > 0 -> i
          | _ -> 1
        in
        Some { mc_phase }
  | _ -> None

let read_managed_config ~name : managed_config option =
  let path = instances_dir () // name // "config.json" in
  if not (Sys.file_exists path) then None
  else
    match (try Some (Yojson.Safe.from_file path) with _ -> None) with
    | Some json -> parse_managed_config json
    | None -> None

let remove_pidfile_if_owned path =
  match read_pidfile path with
  | Some pid when pid = Unix.getpid () -> (try Unix.unlink path with _ -> ())
  | _ -> ()

let redirect_daemon_stdio log_path =
  (try
     let dn = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
     Unix.dup2 dn Unix.stdin;
     Unix.close dn
   with _ -> ());
  (try
     let fd =
       Unix.openfile log_path
         [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ]
         0o600
     in
     Unix.dup2 fd Unix.stdout;
     Unix.dup2 fd Unix.stderr;
     Unix.close fd
   with _ -> ())

(** Phase-1 idle loop: hold the lock, respond to SIGTERM/SIGINT, sleep.
    No adapters, no inbox watching. *)
let idle_supervise ~pid_path =
  let stopping = ref false in
  let request_stop _ = stopping := true in
  Sys.set_signal Sys.sigterm (Sys.Signal_handle request_stop);
  Sys.set_signal Sys.sigint (Sys.Signal_handle request_stop);
  Fun.protect
    ~finally:(fun () -> remove_pidfile_if_owned pid_path)
    (fun () ->
      while not !stopping do
        Unix.sleepf 0.5
      done;
      0)

type supervisor_status =
  | Alive of { pid : int; name : string }
  | Dead of { reason : string }

(** Doctor stub: is the machine-wide deliver-service supervisor alive?
    Prefers outer.pid under the default instance name; falls back to "no
    pidfile / not running" when absent. Does not try the lock (lock probe
    would race with a live owner). *)
let supervisor_status ?(name = default_instance_name) () : supervisor_status =
  let pid_path = instances_dir () // name // "outer.pid" in
  match read_pidfile pid_path with
  | Some pid when pid_alive pid -> Alive { pid; name }
  | Some pid ->
      Dead
        { reason =
            Printf.sprintf
              "pidfile present (pid=%d) but process not alive" pid
        }
  | None -> Dead { reason = "no outer.pid (supervisor not started)" }

let supervisor_status_to_json (s : supervisor_status) : Yojson.Safe.t =
  match s with
  | Alive { pid; name } ->
      `Assoc
        [ ("service", `String "deliver-service")
        ; ("status", `String "alive")
        ; ("pid", `Int pid)
        ; ("name", `String name)
        ; ("phase", `Int 1)
        ; ("adapters", `List [])
        ]
  | Dead { reason } ->
      `Assoc
        [ ("service", `String "deliver-service")
        ; ("status", `String "dead")
        ; ("reason", `String reason)
        ; ("phase", `Int 1)
        ; ("adapters", `List [])
        ]

let pp_supervisor_status_human (s : supervisor_status) =
  match s with
  | Alive { pid; name } ->
      Printf.printf
        "=== deliver-service (machine-wide, #35 phase 1) ===\n\n\
        \  status: ALIVE (pid=%d, name=%s)\n\
        \  adapters: none yet (scaffold only)\n\
        \  stop: c2c stop %s\n\n%!"
        pid name name
  | Dead { reason } ->
      Printf.printf
        "=== deliver-service (machine-wide, #35 phase 1) ===\n\n\
        \  status: DEAD (%s)\n\
        \  start: c2c start deliver-service\n\
        \  adapters: none yet (scaffold only)\n\n%!"
        reason

let stop_supervisor ~name ~timeout_s : bool =
  let pid_path = instances_dir () // name // "outer.pid" in
  match read_pidfile pid_path with
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

let run_owner ~name ~foreground ~ready_fd =
  mkdir_p (machine_state_dir ());
  match C2c_singleton_lock.try_acquire ~path:(machine_lock_resource ()) with
  | Already_running ->
      (match ready_fd with
       | Some fd ->
           ignore (Unix.write_substring fd "ALREADY\n" 0 8);
           Unix.close fd
       | None -> ());
      Printf.eprintf
        "error: a machine-wide deliver-service is already running.\n\
         Use 'c2c instances' / 'c2c doctor deliver-service' to inspect it;\n\
         only one supervisor is needed (#35).\n%!";
      1
  | Acquired lock_fd ->
      let inst_dir = instances_dir () // name in
      let pid_path = inst_dir // "outer.pid" in
      let log_path = inst_dir // "log" in
      mkdir_p inst_dir;
      if not foreground then redirect_daemon_stdio log_path;
      write_config ~config_path:(inst_dir // "config.json");
      write_pidfile pid_path (Unix.getpid ());
      (match ready_fd with
       | Some fd ->
           ignore (Unix.write_substring fd "READY\n" 0 6);
           Unix.close fd
       | None -> ());
      let code =
        Fun.protect
          ~finally:(fun () -> C2c_singleton_lock.release lock_fd)
          (fun () -> idle_supervise ~pid_path)
      in
      code

let read_ready fd =
  let buf = Bytes.create 16 in
  let n = Unix.read fd buf 0 (Bytes.length buf) in
  Bytes.sub_string buf 0 n

(** Start the one machine-wide deliver-service. A different [name] changes
    only its managed display/stop name; it cannot create a second service. *)
let[@noreturn] start ~name ~daemon () =
  if not daemon then
    exit (run_owner ~name ~foreground:true ~ready_fd:None)
  else begin
    let ready_r, ready_w = Unix.pipe ~cloexec:false () in
    flush_all ();
    match Unix.fork () with
    | 0 ->
        Unix.close ready_r;
        ignore (try Unix.setsid () with _ -> 0);
        (try Unix.chdir "/" with _ -> ());
        exit (run_owner ~name ~foreground:false ~ready_fd:(Some ready_w))
    | supervisor_pid ->
        Unix.close ready_w;
        let status = read_ready ready_r in
        Unix.close ready_r;
        if status = "READY\n" then begin
          Printf.printf
            "[c2c start deliver-service] machine-wide supervisor pid=%d\n\
             [c2c start deliver-service] phase 1 scaffold (no adapters yet)\n\
             [c2c start deliver-service] stop with: c2c stop %s\n%!"
            supervisor_pid name;
          exit 0
        end else if status = "ALREADY\n" then begin
          (* Child already printed the full Already_running diagnostic. *)
          ignore (Unix.waitpid [] supervisor_pid);
          exit 1
        end else begin
          ignore (Unix.waitpid [] supervisor_pid);
          exit 1
        end
  end

let restart ~name ~timeout_s () =
  match read_managed_config ~name with
  | None when not (is_default_deliver_service_name name) ->
      Printf.eprintf
        "error: '%s' is not a managed deliver-service.\n\
        \  For the machine-wide service: c2c start deliver-service\n\
        \  or c2c restart deliver-service.\n%!"
        name;
      exit 1
  | None | Some _ ->
      if not (stop_supervisor ~name ~timeout_s) then begin
        Printf.eprintf
          "error: could not stop deliver-service '%s' (pid still alive \
           after SIGKILL).\n%!"
          name;
        exit 1
      end;
      Printf.printf
        "[c2c restart] relaunching machine-wide deliver-service '%s'\n%!"
        name;
      start ~name ~daemon:true ()
