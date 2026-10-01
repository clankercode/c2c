(* Exclusive delivery owner for one Codex machine-daemon thread. *)

type lease = {
  socket_identity : string;
  thread_id : string;
  sidecar_pid : int;
  claimed_at : float;
  heartbeat_at : float;
  alias : string;
  broker_session_id : string;
}

type claim_result =
  | Claimed of lease
  | Already_ours of lease
  | Held_live of lease
  | Reclaimed of lease

let ( // ) = Filename.concat

let lease_key ~socket_identity ~thread_id =
  Digest.to_hex (Digest.string (socket_identity ^ "\n" ^ thread_id))

let lease_path ~owners_dir ~socket_identity ~thread_id =
  owners_dir // (lease_key ~socket_identity ~thread_id ^ ".json")

let default_holder_live (l : lease) : bool =
  C2c_pid_identity.recorded_pid_is_ours
    ~expect:(C2c_pid_identity.Started_at l.claimed_at)
    ~pid:l.sidecar_pid

let lease_to_json (l : lease) : Yojson.Safe.t =
  `Assoc
    [ ("socket_identity", `String l.socket_identity);
      ("thread_id", `String l.thread_id);
      ("sidecar_pid", `Int l.sidecar_pid);
      ("claimed_at", `Float l.claimed_at);
      ("heartbeat_at", `Float l.heartbeat_at);
      ("alias", `String l.alias);
      ("broker_session_id", `String l.broker_session_id) ]

let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | _ -> None

let float_field fields key =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let int_field fields key =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None

let lease_of_json = function
  | `Assoc fields ->
      (match
         ( string_field fields "socket_identity",
           string_field fields "thread_id",
           int_field fields "sidecar_pid",
           float_field fields "claimed_at",
           float_field fields "heartbeat_at",
           string_field fields "alias",
           string_field fields "broker_session_id" )
       with
       | Some socket_identity, Some thread_id, Some sidecar_pid,
         Some claimed_at, Some heartbeat_at, Some alias, Some broker_session_id ->
           Some { socket_identity; thread_id; sidecar_pid; claimed_at;
                  heartbeat_at; alias; broker_session_id }
       | _ -> None)
  | _ -> None

let read_lease path =
  if not (Sys.file_exists path) then None
  else
    try lease_of_json (Yojson.Safe.from_file path)
    with _ -> None

let write_lease path (l : lease) =
  C2c_io.mkdir_p (Filename.dirname path);
  match
    C2c_io.write_file_atomic_locked path
      (Yojson.Safe.to_string (lease_to_json l) ^ "\n")
  with
  | Ok () -> ()
  | Error _ ->
      (* Tests and first-create paths still need a write; fall back unlocked. *)
      ignore (C2c_io.write_file_atomic ~perm:0o600 path
                (Yojson.Safe.to_string (lease_to_json l) ^ "\n"))

(* Claim is a read/compare/write transaction. Locking the target only inside
   [write_lease] is insufficient because the atomic write replaces that inode;
   two claimants could both read "absent" before either rename completes. Keep a
   stable sidecar lock inode for the whole decision. *)
let with_lease_lock path f =
  let lock_path = path ^ ".lock" in
  C2c_io.mkdir_p (Filename.dirname lock_path);
  let fd = Unix.openfile lock_path [Unix.O_WRONLY; Unix.O_CREAT] 0o600 in
  Unix.lockf fd Unix.F_LOCK 0;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      Unix.close fd)
    f

let try_claim ~owners_dir ~socket_identity ~thread_id ~sidecar_pid
    ~alias ~broker_session_id ?now ?(holder_live = default_holder_live) () =
  let now = match now with Some t -> t | None -> Unix.gettimeofday () in
  C2c_io.mkdir_p owners_dir;
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  let ours =
    { socket_identity; thread_id; sidecar_pid; claimed_at = now;
      heartbeat_at = now; alias; broker_session_id }
  in
  with_lease_lock path (fun () ->
      match read_lease path with
      | None ->
          write_lease path ours;
          Claimed ours
      | Some existing
        when existing.socket_identity <> socket_identity
             || existing.thread_id <> thread_id ->
          (* Corrupt/mismatched file for this key; take it. *)
          write_lease path ours;
          Reclaimed ours
      | Some existing when existing.sidecar_pid = sidecar_pid ->
          let refreshed = { existing with heartbeat_at = now; alias; broker_session_id } in
          write_lease path refreshed;
          Already_ours refreshed
      | Some existing when holder_live existing ->
          Held_live existing
      | Some _stale ->
          write_lease path ours;
          Reclaimed ours)

let heartbeat ~owners_dir ~socket_identity ~thread_id ~sidecar_pid ?now () =
  let now = match now with Some t -> t | None -> Unix.gettimeofday () in
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  with_lease_lock path (fun () ->
      match read_lease path with
      | Some l when l.sidecar_pid = sidecar_pid ->
          let refreshed = { l with heartbeat_at = now } in
          write_lease path refreshed;
          Some refreshed
      | _ -> None)

let release ~owners_dir ~socket_identity ~thread_id ~sidecar_pid =
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  with_lease_lock path (fun () ->
      match read_lease path with
      | Some l when l.sidecar_pid = sidecar_pid ->
          (try Sys.remove path with _ -> ())
      | _ -> ())

let peek ~owners_dir ~socket_identity ~thread_id =
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  with_lease_lock path (fun () -> read_lease path)

let default_owners_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let root =
    match Sys.getenv_opt "C2C_STATE_HOME" with
    | Some d when String.trim d <> "" -> String.trim d
    | _ -> Filename.concat home ".local/share"
  in
  Filename.concat root "c2c/codex-daemon-owners"

let default_control_socket () =
  match Sys.getenv_opt "C2C_CODEX_DAEMON_SOCK" with
  | Some p when String.trim p <> "" ->
      let p = String.trim p in
      if Sys.file_exists p then Some p else None
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | None -> None
       | Some home ->
           let p =
             Filename.concat home
               (Filename.concat ".codex"
                  (Filename.concat "app-server-control"
                     "app-server-control.sock"))
           in
           if Sys.file_exists p then Some p else None)

let unix_endpoint path =
  try
    if not (Sys.file_exists path) then None
    else
      let host = Unix.realpath path in
      Some { C2c_codex_app_server.transport = "unix"; host; port = 0 }
  with _ -> None

type arm_result =
  | Armed of { child_pid : int }
  | Already_running of lease
  | Socket_unavailable
  | Claim_held of lease

(* Fail closed: never adopt a loaded thread that is not the hinted Codex
   thread. A session/alias id that is not in thread/loaded/list must not
   claim, or two aliases could inject one frontend thread. *)
let select_owned_thread ~hint ~loaded =
  if hint <> "" && List.exists (fun t -> String.equal t hint) loaded then
    Some hint
  else None

let socket_ok path =
  try
    match unix_endpoint path with
    | None -> false
    | Some ep ->
        let fd = C2c_codex_transport.ws_connect ep ~token:"" ~timeout:2.0 in
        (try Unix.close fd with _ -> ());
        true
  with _ -> false

let stop_pid pid =
  let gone () =
    try
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> false
      | _, _ -> true
    with Unix.Unix_error (Unix.ECHILD, _, _) ->
      not (Sys.file_exists (Printf.sprintf "/proc/%d" pid))
  in
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  let deadline = Unix.gettimeofday () +. 2.0 in
  let rec wait () =
    if gone () || Unix.gettimeofday () >= deadline then ()
    else (Unix.sleepf 0.05; wait ())
  in
  wait ();
  if not (gone ()) then
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())

let run_child ~instance_name ~owners_dir ~socket_path ~thread_id ~alias
    ~broker_session_id ~broker_root =
  Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1";
  match unix_endpoint socket_path with
  | None -> exit 0
  | Some endpoint ->
      let socket_identity = endpoint.host in
      let pid = Unix.getpid () in
      let token_provider () = Some "" in
      let loaded () =
        match token_provider () with
        | None -> []
        | Some token -> C2c_codex_ingress.real_loaded_threads ~endpoint ~token
      in
      (* Do not claim until the hinted id is a loaded Codex thread. *)
      let deadline = Unix.gettimeofday () +. 30.0 in
      let rec wait_loaded () =
        match select_owned_thread ~hint:thread_id ~loaded:(loaded ()) with
        | Some tid -> tid
        | None when Unix.gettimeofday () < deadline && socket_ok socket_path ->
            Unix.sleepf 0.2;
            wait_loaded ()
        | None -> exit 0
      in
      let claimed_thread = wait_loaded () in
      (match
         try_claim ~owners_dir ~socket_identity ~thread_id:claimed_thread
           ~sidecar_pid:pid ~alias ~broker_session_id ()
       with
       | Held_live _ -> exit 0
       | Claimed _ | Already_ours _ | Reclaimed _ -> ());
      let sock_alive () = socket_ok socket_path in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let register () =
        try
          C2c_mcp.Broker.register broker ~session_id:broker_session_id ~alias
            ~pid:(Some pid)
            ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time pid)
            ~client_type:(Some "codex") ~from_auto_gen:false ()
        with _ -> ()
      in
      let deregister () =
        release ~owners_dir ~socket_identity ~thread_id:claimed_thread
          ~sidecar_pid:pid;
        (try C2c_start.clear_registration_pid ~broker_root ~session_id:broker_session_id
         with _ -> ());
        (match instance_name with
         | None -> ()
         | Some instance_name ->
             (try
                let path = C2c_start.codex_daemon_sidecar_pid_path instance_name in
                match C2c_start.read_pid path with
                | Some p when p = pid -> C2c_start.remove_pidfile path
                | _ -> ()
              with _ -> ()))
      in
      let deps : C2c_codex_deliver_loop.deps =
        { broker_root;
          session_id = broker_session_id;
          managed_identity = alias;
          endpoint;
          token_provider;
          inject_client = C2c_codex_ingress.real_client ();
          turn_client = C2c_codex_autoturn.real_turn_client ();
          discover_threads =
            (fun () ->
              match select_owned_thread ~hint:claimed_thread ~loaded:(loaded ()) with
              | Some tid -> [ tid ]
              | None -> []);
          supervise_step =
            (fun () ->
              if sock_alive () then C2c_codex_app_server.Sv_running
              else C2c_codex_app_server.Sv_offline);
          session_active = sock_alive;
          is_dnd =
            (fun () ->
              try C2c_mcp.Broker.is_dnd broker ~session_id:broker_session_id
              with _ -> false);
          register;
          deregister;
          on_pass = (fun _ -> ());
          on_degraded = (fun ~degraded:_ ~binding_refused:_ -> ());
          on_thread_discovered =
            (fun tid -> String.equal tid claimed_thread);
          restart_requested = (fun ~thread_id:_ -> None);
          global_broker_root =
            (try Some (C2c_repo_fp.resolve_sessions_broker_root ()) with _ -> None);
          on_global_pass = (fun _ -> ());
          now = Unix.gettimeofday;
          sleep = Unix.sleepf;
          poll_interval_s = 2.0;
          discover_interval_s = 2.0;
          max_wall_s = infinity }
      in
      (* The fork inherits the launcher's signal handlers. Reset them before the
         sidecar can block in thread discovery, then install a sidecar-owned
         handler that releases the lease and broker row before exiting. *)
      ignore (Sys.signal Sys.sigterm Sys.Signal_default);
      ignore (Sys.signal Sys.sigint Sys.Signal_default);
      let prev_term = Sys.signal Sys.sigterm (Sys.Signal_handle (fun _ ->
          deregister (); exit 0)) in
      let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
          deregister (); exit 0)) in
      Fun.protect
        ~finally:(fun () ->
          (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
          (try Sys.set_signal Sys.sigint prev_int with _ -> ()))
        (fun () ->
           ignore (C2c_codex_deliver_loop.run deps);
           deregister ());
      exit 0

let arm ~thread_id ~alias ~broker_session_id ~broker_root ?instance_name ?owners_dir
    ?socket_path () =
  let owners_dir =
    match owners_dir with Some d -> d | None -> default_owners_dir ()
  in
  match
    match socket_path with Some p -> Some p | None -> default_control_socket ()
  with
  | None -> Socket_unavailable
  | Some socket_path ->
      (match unix_endpoint socket_path with
       | None -> Socket_unavailable
       | Some ep ->
           let socket_identity = ep.host in
           (match peek ~owners_dir ~socket_identity ~thread_id with
            | Some l when default_holder_live l -> Already_running l
            | _ ->
                match Unix.fork () with
                | 0 ->
                    (* This process never needs the operator's terminal. Close
                       the inherited tty before detaching so the sidecar cannot
                       turn a fish/Codex pane into a shared input/output pair. *)
                    let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
                    (try Unix.dup2 devnull Unix.stdin with _ -> ());
                    (try Unix.dup2 devnull Unix.stdout with _ -> ());
                    (try Unix.dup2 devnull Unix.stderr with _ -> ());
                    (try
                       if devnull <> Unix.stdin && devnull <> Unix.stdout &&
                          devnull <> Unix.stderr then Unix.close devnull
                     with _ -> ());
                    (* Do not inherit the launcher's signal handlers. *)
                    ignore (Sys.signal Sys.sigterm Sys.Signal_default);
                    ignore (Sys.signal Sys.sigint Sys.Signal_default);
                    ignore (Unix.setsid ());
                    (try Unix.chdir "/" with _ -> ());
                    run_child ~instance_name ~owners_dir ~socket_path ~thread_id ~alias
                      ~broker_session_id ~broker_root
                | child_pid ->
                    let deadline = Unix.gettimeofday () +. 0.4 in
                    let rec wait () =
                      match peek ~owners_dir ~socket_identity ~thread_id with
                      | Some l when l.sidecar_pid = child_pid -> ()
                      | _ when Unix.gettimeofday () < deadline ->
                          Unix.sleepf 0.02;
                          wait ()
                      | _ -> ()
                    in
                    wait ();
                    (match instance_name with
                     | None -> ()
                     | Some instance_name ->
                         (try
                            C2c_start.write_pid
                              (C2c_start.codex_daemon_sidecar_pid_path instance_name)
                              child_pid
                          with _ -> ()));
                    Armed { child_pid }))
