(* Exclusive delivery owner for one Codex machine-daemon thread. *)

type lease = {
  socket_identity : string;
  thread_id : string;
  sidecar_pid : int;
  sidecar_pid_start_time : int option;
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
  | Claim_uncertain of string

let ( // ) = Filename.concat

let lease_key ~socket_identity ~thread_id =
  Digest.to_hex (Digest.string (socket_identity ^ "\n" ^ thread_id))

let lease_path ~owners_dir ~socket_identity ~thread_id =
  owners_dir // (lease_key ~socket_identity ~thread_id ^ ".json")

let lease_filename_matches path (l : lease) =
  Filename.basename path
  = lease_key ~socket_identity:l.socket_identity ~thread_id:l.thread_id ^ ".json"

let lease_live (l : lease) : bool =
  match l.sidecar_pid_start_time with
  | Some expected ->
      (match C2c_pid_identity.read_pid_generation l.sidecar_pid with
       | C2c_pid_identity.Generation actual -> actual = expected
       | C2c_pid_identity.Absent | C2c_pid_identity.Unreadable -> false)
  | None -> false

type lease_owner_state = Lease_owner_live | Lease_owner_gone | Lease_owner_unknown

let lease_owner_state (l : lease) =
  match l.sidecar_pid_start_time with
  | None -> Lease_owner_unknown
  | Some expected ->
      (match C2c_pid_identity.read_pid_generation l.sidecar_pid with
       | C2c_pid_identity.Generation actual when actual = expected -> Lease_owner_live
       | C2c_pid_identity.Absent
       | C2c_pid_identity.Generation _ -> Lease_owner_gone
       | C2c_pid_identity.Unreadable -> Lease_owner_unknown)

(* Old lease files predate the persisted generation. They cannot prove which
   process owns their numeric PID, so they remain an owner until an explicit
   operator cleanup removes them. In particular, never turn an unverifiable
   legacy lease into a second owner merely because its PID cannot be inspected. *)
let holder_live_for_claim (l : lease) : bool =
  match l.sidecar_pid_start_time with
  | Some _ ->
      (match lease_owner_state l with
       | Lease_owner_live | Lease_owner_unknown -> true
       | Lease_owner_gone -> false)
  | None -> true

let lease_to_json (l : lease) : Yojson.Safe.t =
  `Assoc
    [ ("socket_identity", `String l.socket_identity);
      ("thread_id", `String l.thread_id);
      ("sidecar_pid", `Int l.sidecar_pid);
      ( "sidecar_pid_start_time",
        match l.sidecar_pid_start_time with Some n -> `Int n | None -> `Null );
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
  | Some (`String s) -> int_of_string_opt (String.trim s)
  | _ -> None

let optional_int_field fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Some None
  | Some (`Int i) -> Some (Some i)
  | Some (`String s) ->
      Option.map (fun i -> Some i) (int_of_string_opt (String.trim s))
  | _ -> None

let lease_of_json = function
  | `Assoc fields ->
      (match
         ( string_field fields "socket_identity",
           string_field fields "thread_id",
           int_field fields "sidecar_pid",
           optional_int_field fields "sidecar_pid_start_time",
           float_field fields "claimed_at",
           float_field fields "heartbeat_at",
           string_field fields "alias",
           string_field fields "broker_session_id" )
       with
       | Some socket_identity, Some thread_id, Some sidecar_pid,
         Some sidecar_pid_start_time, Some claimed_at, Some heartbeat_at, Some alias,
         Some broker_session_id ->
           Some { socket_identity; thread_id; sidecar_pid; sidecar_pid_start_time; claimed_at;
                  heartbeat_at; alias; broker_session_id }
       | _ -> None)
  | _ -> None

type lease_read =
  | Lease_missing
  | Lease_present of lease
  | Lease_unreadable

let read_lease_state path =
  match C2c_start.read_regular_file_nofollow path with
  | C2c_start.Regular_file_missing -> Lease_missing
  | C2c_start.Regular_file_unreadable _ -> Lease_unreadable
  | C2c_start.Regular_file_contents contents ->
      (try
         match lease_of_json (Yojson.Safe.from_string contents) with
         | Some lease when lease_filename_matches path lease -> Lease_present lease
         | Some _ | None -> Lease_unreadable
       with _ -> Lease_unreadable)

let read_lease path =
  match read_lease_state path with
  | Lease_present lease -> Some lease
  | Lease_missing | Lease_unreadable -> None

(* Return the exact bytes that still describe [expected].  The caller holds
   the stable lease lock while using these bytes with the content-pinned,
   no-follow unlink primitive.  A second read is intentional: if a writer
   replaced the pathname after the state read, the exact-content unlink will
   refuse it instead of deleting the replacement. *)
let lease_contents_for_owner path (expected : lease) =
  match C2c_start.read_regular_file_nofollow path with
  | C2c_start.Regular_file_contents contents ->
      (try
         match lease_of_json (Yojson.Safe.from_string contents) with
         | Some current
           when lease_filename_matches path current
                && current.socket_identity = expected.socket_identity
                && current.thread_id = expected.thread_id
                && current.sidecar_pid = expected.sidecar_pid
                && current.sidecar_pid_start_time = expected.sidecar_pid_start_time
                && current.alias = expected.alias
                && current.broker_session_id = expected.broker_session_id ->
             Some contents
         | _ -> None
       with _ -> None)
  | C2c_start.Regular_file_missing
  | C2c_start.Regular_file_unreadable _ -> None

let write_lease path (l : lease) =
  C2c_io.mkdir_p (Filename.dirname path);
  match
    C2c_io.write_file_atomic_locked path
      (Yojson.Safe.to_string (lease_to_json l) ^ "\n")
  with
  | Ok () -> ()
  | Error reason ->
      failwith
        (Printf.sprintf "failed to persist Codex sidecar lease %s: %s" path reason)

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
    ~alias ~broker_session_id ?sidecar_pid_start_time ?now
    ?(holder_live = holder_live_for_claim) () =
  let now = match now with Some t -> t | None -> Unix.gettimeofday () in
  C2c_io.mkdir_p owners_dir;
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  let ours =
    { socket_identity; thread_id; sidecar_pid; sidecar_pid_start_time; claimed_at = now;
      heartbeat_at = now; alias; broker_session_id }
  in
  with_lease_lock path (fun () ->
      match read_lease_state path with
      | Lease_missing ->
          write_lease path ours;
          Claimed ours
      | Lease_unreadable ->
          Claim_uncertain "Codex sidecar lease is unreadable or malformed"
      | Lease_present existing
        when existing.socket_identity <> socket_identity
             || existing.thread_id <> thread_id ->
          (* A valid file with a mismatched identity is still unknown owner
             state. Never overwrite it during claim arbitration. *)
          Claim_uncertain "Codex sidecar lease identity does not match its path"
      | Lease_present existing when Option.is_some existing.sidecar_pid_start_time
                        && existing.sidecar_pid = sidecar_pid
                        && existing.sidecar_pid_start_time = sidecar_pid_start_time ->
          let refreshed = { existing with heartbeat_at = now; alias; broker_session_id } in
          write_lease path refreshed;
          Already_ours refreshed
      | Lease_present existing when holder_live existing ->
          Held_live existing
      | Lease_present _stale ->
          write_lease path ours;
          Reclaimed ours)

let heartbeat ~owners_dir ~socket_identity ~thread_id ~sidecar_pid
    ~sidecar_pid_start_time ~alias ~broker_session_id ?now () =
  let now = match now with Some t -> t | None -> Unix.gettimeofday () in
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  with_lease_lock path (fun () ->
      match read_lease_state path with
      | Lease_present l
        when l.socket_identity = socket_identity
             && l.thread_id = thread_id
             && l.sidecar_pid = sidecar_pid
             && l.sidecar_pid_start_time = Some sidecar_pid_start_time
             && l.alias = alias
             && l.broker_session_id = broker_session_id
             && lease_owner_state l = Lease_owner_live ->
          let refreshed = { l with heartbeat_at = now } in
          write_lease path refreshed;
          Some refreshed
      | _ -> None)

let release ~owners_dir ~socket_identity ~thread_id ~sidecar_pid
    ?sidecar_pid_start_time () =
  let path = lease_path ~owners_dir ~socket_identity ~thread_id in
  try
    with_lease_lock path (fun () ->
        match read_lease_state path with
        | Lease_missing -> true
        | Lease_unreadable -> false
        | Lease_present l
          when l.socket_identity = socket_identity
               && l.thread_id = thread_id
               && l.sidecar_pid = sidecar_pid
               && (match sidecar_pid_start_time with
                   | Some expected -> l.sidecar_pid_start_time = Some expected
                   | None -> false) ->
            (* Pin the opened regular inode while unlinking it. A pathname
               replacement between the lease read and unlink must fail closed;
               a post-unlink [stat] alone can mistake a dangling replacement
               symlink for confirmed absence. *)
            (match lease_contents_for_owner path l with
             | Some contents ->
                 C2c_start.remove_path_contents_confirmed path contents
             | None -> false)
        | Lease_present _ -> false)
  with _ -> false

(* Durable owner cleanup is ordered: the lease is the proof that this process
   owns the registration and pidfiles.  If releasing that exact lease is
   uncertain, leave every dependent record in place for a later retry. *)
let release_before_cleanup ~release ~cleanup =
  let released = try release () with _ -> false in
  if not released then false
  else try cleanup () with _ -> false

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
  | Arm_failed of string
  | Arm_failed_ownership_retained of string

let arm_wait_budget_s = 5.0

let arm_failed_after_pending_cleanup ~stopped ~lease_released =
  if stopped && lease_released then
    Arm_failed
      "sidecar became operational but its pending arm records could not be removed"
  else if not stopped then
    Arm_failed_ownership_retained
      "sidecar became operational but its child could not be stopped after pending-arm cleanup failed"
  else
    Arm_failed_ownership_retained
      "sidecar child stopped but its exact lease could not be released after pending-arm cleanup failed"

let registration_is_live ~broker_root ~broker_session_id ~alias ~pid
    ~pid_start_time =
  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    List.exists
      (fun (r : C2c_mcp.registration) ->
         r.session_id = broker_session_id
         && r.alias = alias
         && r.pid = Some pid
         && r.pid_start_time = Some pid_start_time)
      (C2c_mcp.Broker.list_registrations broker)
  with _ -> false

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

let stop_pid ?sidecar_pid_start_time pid =
  let generation =
    match sidecar_pid_start_time with
    | Some n -> Some n
    | None -> None
  in
  let gone () =
    let reaped =
      try
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ -> false
        | _, _ -> true
      with Unix.Unix_error (Unix.ECHILD, _, _) -> false
    in
    reaped
    ||
    match generation with
    | Some expected ->
        (match C2c_pid_identity.read_pid_generation pid with
         | C2c_pid_identity.Absent -> true
         | C2c_pid_identity.Generation actual -> actual <> expected
         | C2c_pid_identity.Unreadable -> false)
    | None -> false
  in
  let signal signal =
    match generation with
    | Some expected ->
        C2c_pid_identity.signal_pid_if_generation_matches
          ~pid ~start_time:expected ~signal
    | None -> false
  in
  let sent = ref false in
  if not (gone ()) then sent := signal Sys.sigterm;
  let deadline = Unix.gettimeofday () +. 2.0 in
  let rec wait () =
    if gone () || Unix.gettimeofday () >= deadline then ()
    else (Unix.sleepf 0.05; wait ())
  in
  wait ();
  if not (gone ()) then sent := signal Sys.sigkill || !sent;
  if not (gone ()) then begin
    let deadline = Unix.gettimeofday () +. 1.0 in
    let rec wait_kill () =
      if gone () || Unix.gettimeofday () >= deadline then ()
      else (Unix.sleepf 0.02; wait_kill ())
    in
    wait_kill ()
  end;
  (* A signal being sent is not success: callers may clear leases and
     registrations only after the exact generation has disappeared. *)
  gone ()

type child_observation = Child_alive | Child_exited | Child_unavailable

let observe_child pid =
  try
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> Child_alive
    | _, _ -> Child_exited
  with Unix.Unix_error (Unix.ECHILD, _, _) -> Child_unavailable

let with_arm_lock path f =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  Unix.lockf fd Unix.F_LOCK 0;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
      Unix.close fd)
    f

let run_child ~instance_name ~owners_dir ~token ~socket_path ~thread_id ~alias
    ~broker_session_id ~broker_root ~arm_cancel_path ~arm_lock_path =
  Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1";
  let pending_path =
    C2c_start.codex_daemon_sidecar_arm_pending_path ~owners_dir ~token
  in
  if not
       (C2c_start.codex_daemon_sidecar_arm_paths_match_token ~owners_dir ~token
          ~pending_path ~cancel_path:arm_cancel_path ~lock_path:arm_lock_path)
  then exit 0;
  let cancelled () = Sys.file_exists arm_cancel_path in
  match unix_endpoint socket_path with
  | None -> exit 0
  | Some endpoint ->
      let socket_identity = endpoint.host in
      let pid = Unix.getpid () in
      let pid_start_time = C2c_mcp.Broker.read_pid_start_time pid in
      (* Without an exact generation the detached child cannot be safely
         stopped. Return before claiming or registering anything; the parent
         then reports Arm_failed and the hook keeps its delivery fallback. *)
      let pid_start_time =
        match pid_start_time with
        | Some n when C2c_pid_identity.pidfd_supported () -> Some n
        | _ -> exit 0
      in
      let token_provider () = Some "" in
      let loaded () =
        match token_provider () with
        | None -> []
        | Some token -> C2c_codex_ingress.real_loaded_threads ~endpoint ~token
      in
      (* Do not claim until the hinted id is a loaded Codex thread. *)
      let deadline = Unix.gettimeofday () +. 30.0 in
      let rec wait_loaded () =
        if cancelled () then exit 0;
        match select_owned_thread ~hint:thread_id ~loaded:(loaded ()) with
        | Some tid -> tid
        | None when Unix.gettimeofday () < deadline && socket_ok socket_path ->
            Unix.sleepf 0.2;
            wait_loaded ()
        | None -> exit 0
      in
      let unsupported = ref false in
      let claimed_thread = wait_loaded () in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      C2c_start.clear_codex_hook_fallback ~broker_root
        ~session_id:broker_session_id;
      let register () =
        C2c_mcp.Broker.register broker ~session_id:broker_session_id ~alias
          ~pid:(Some pid) ~pid_start_time:pid_start_time
          (* The detached daemon sidecar is the arrival-time delivery owner.
             Preserve this discriminator on every refresh so the Codex hook
             remains identity-only and cannot dual-drain the same inbox. *)
          ~client_type:(Some "codex-app-server") ~from_auto_gen:false ()
      in
      let cleanup_failed = ref false in
      let deregister () =
        let cleanup () =
          (* Clear the registry first.  If its read/lock/write confirmation is
             uncertain, retain the pidfiles so the whole owner record remains
             retryable. *)
          let registration_cleared =
            C2c_start.clear_registration_pid_if_owner ~broker_root
              ~session_id:broker_session_id ~pid ~pid_start_time
          in
          if not registration_cleared then false
          else
            match instance_name with
            | None -> true
            | Some instance_name ->
                let path = C2c_start.codex_daemon_sidecar_pid_path instance_name in
                let start_time_path =
                  C2c_start.codex_daemon_sidecar_pid_start_time_path instance_name
                in
                match C2c_start.read_pid_state path,
                      C2c_start.read_pid_state start_time_path with
                | C2c_start.Pidfile_absent, C2c_start.Pidfile_absent -> true
                | C2c_start.Pidfile_valid p, C2c_start.Pidfile_valid _
                  when p = pid ->
                    C2c_start.remove_pidfile_confirmed path
                    && C2c_start.remove_pidfile_confirmed start_time_path
                | _ -> false
        in
        let ok =
          release_before_cleanup
            ~release:(fun () ->
              release ~owners_dir ~socket_identity ~thread_id:claimed_thread
                ~sidecar_pid:pid ?sidecar_pid_start_time:pid_start_time ())
            ~cleanup
        in
        if not ok then begin
          cleanup_failed := true;
          Printf.eprintf
            "c2c: retaining Codex sidecar lease, registration, and pidfile state after cleanup failure (thread %s)\n%!"
            claimed_thread
        end;
        ok
      in
      let exit_after_deregister () =
        exit (if deregister () then 0 else 1)
      in
      (* The parent only observes a lease after this read-back succeeds, so
         [Armed] means the child can really own delivery. *)
      with_arm_lock arm_lock_path (fun () ->
          if cancelled () then exit 0;
          (* Arbitrate the daemon thread before touching the shared broker
             registration. A losing arm must never overwrite the winner's row
             or clear it during loser cleanup. *)
          (match
             try_claim ~owners_dir ~socket_identity ~thread_id:claimed_thread
               ~sidecar_pid:pid ?sidecar_pid_start_time:pid_start_time ~alias
               ~broker_session_id ()
           with
           | Held_live _ | Claim_uncertain _ -> exit 0
           | Claimed _ | Already_ours _ | Reclaimed _ -> ());
          if cancelled () then begin
            let released =
              try
                release ~owners_dir ~socket_identity ~thread_id:claimed_thread
                  ~sidecar_pid:pid ?sidecar_pid_start_time:pid_start_time ()
              with _ -> false
            in
            if released then exit 0 else begin
              Printf.eprintf
                "c2c: failed to release cancelled Codex sidecar lease; retaining it for retry\n%!";
              exit 1
            end
          end;
          try
            register ();
            if not
                 (registration_is_live ~broker_root ~broker_session_id ~alias ~pid
                    ~pid_start_time:(Option.get pid_start_time))
            then failwith "sidecar registration did not persist";
            if cancelled () then begin
              exit_after_deregister ()
            end
          with _ ->
            exit_after_deregister ());
      let sock_alive () = socket_ok socket_path in
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
          deregister = (fun () -> ignore (deregister ()));
          on_pass = (fun _ -> ());
          on_degraded = (fun ~degraded:_ ~binding_refused:_ -> ());
          on_thread_discovered =
            (fun tid -> String.equal tid claimed_thread);
          restart_requested = (fun ~thread_id:_ -> None);
          global_broker_root =
            (try Some (C2c_repo_fp.resolve_sessions_broker_root ()) with _ -> None);
          on_global_pass = (fun _ -> ());
          on_ingress_health =
            (fun h ->
              match h.C2c_codex_ingress.last_error with
              | Some "fallback:unsupported" ->
                  unsupported := true;
                  ignore
                    (C2c_start.mark_codex_hook_fallback ~broker_root
                       ~session_id:broker_session_id)
              | _ -> ());
          stop_requested = (fun () -> !unsupported);
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
          exit_after_deregister ())) in
      let prev_int = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
          exit_after_deregister ())) in
      Fun.protect
        ~finally:(fun () ->
          (try Sys.set_signal Sys.sigterm prev_term with _ -> ());
          (try Sys.set_signal Sys.sigint prev_int with _ -> ()))
        (fun () ->
           Fun.protect
             ~finally:(fun () -> ignore (deregister ()))
             (fun () -> ignore (C2c_codex_deliver_loop.run deps)));
      exit (if !cleanup_failed then 1 else 0)

let arm ~thread_id ~alias ~broker_session_id ~broker_root ?instance_name ?owners_dir
    ?socket_path ?(arm_wait_s = arm_wait_budget_s) () =
  if not (C2c_pid_identity.pidfd_supported ()) then
    Arm_failed "daemon sidecar requires owner-bound pidfd signalling"
  else
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
            | Some l when lease_live l -> Already_running l
            | _ ->
                (match read_lease_state
                         (lease_path ~owners_dir ~socket_identity ~thread_id) with
                 | Lease_unreadable ->
                     Arm_failed "Codex sidecar lease is unreadable or malformed"
                 | Lease_missing | Lease_present _ ->
                let token =
                  Digest.to_hex
                    (Digest.string
                       (Printf.sprintf "%s:%d:%.12f" broker_session_id
                          (Unix.getpid ()) (Unix.gettimeofday ())))
                in
                let arm_cancel_path =
                  C2c_start.codex_daemon_sidecar_arm_cancel_path ~owners_dir ~token
                in
                let arm_lock_path =
                  C2c_start.codex_daemon_sidecar_arm_lock_path ~owners_dir ~token
                in
                (* A termination signal between [fork] and publication of the
                   pending-arm record used to let cleanup observe neither a
                   lease nor a child.  Keep SIGTERM/SIGINT pending until the
                   record is durable; the handler can then cancel this exact
                   arm even if the child claims its lease immediately after
                   publication. *)
                let previous_signal_mask =
                  try Thread.sigmask Unix.SIG_BLOCK [ Sys.sigterm; Sys.sigint ]
                  with _ -> []
                in
                let restore_signal_mask () =
                  try ignore (Thread.sigmask Unix.SIG_SETMASK previous_signal_mask)
                  with _ -> ()
                in
                match Unix.fork () with
                | 0 ->
                    (* The detached child must handle termination normally; the
                       mask is only for the parent's fork/publication window. *)
                    restore_signal_mask ();
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
                    run_child ~instance_name ~owners_dir ~token ~socket_path ~thread_id ~alias
                      ~broker_session_id ~broker_root ~arm_cancel_path ~arm_lock_path
                | child_pid ->
                    (* Capture the child generation before any wait/reap path.
                       Never derive it later from a possibly reused PID. *)
                    let child_pid_start_time =
                      C2c_mcp.Broker.read_pid_start_time child_pid
                    in
                    let publication_error = ref None in
                    let pending_published =
                      try
                        match
                          C2c_start.write_codex_daemon_sidecar_arm ~owners_dir ~token
                            ~thread_id ~pid:child_pid
                            ~pid_start_time:child_pid_start_time ~broker_session_id
                        with
                        | Ok () -> true
                        | Error reason ->
                            publication_error := Some reason;
                            false
                      with e ->
                        publication_error := Some (Printexc.to_string e);
                        false
                    in
                    if not pending_published then begin
                      (* There is no durable arm record to hand to a later
                         cleanup owner, so publication failure is a synchronous
                         startup failure. Keep the signal mask installed. A
                         missing generation is not permission to signal the
                         numeric PID, even though it is our direct child: only
                         [waitpid] may observe it in that state. *)
                      let stop_and_reap () =
                        match child_pid_start_time with
                        | Some start_time ->
                            stop_pid ~sidecar_pid_start_time:start_time child_pid
                        | None ->
                            (try
                               ignore (Unix.waitpid [] child_pid);
                               true
                             with Unix.Unix_error (Unix.ECHILD, _, _) -> false)
                      in
                      let stopped = stop_and_reap () in
                      (* SIGKILL can bypass the child's finally block after it
                         has claimed a lease. Remove only a lease carrying this
                         exact child generation, then clear its exact broker
                         registration. *)
                      let cleanup_ok =
                        match peek ~owners_dir ~socket_identity ~thread_id with
                        | Some lease
                          when lease.sidecar_pid = child_pid
                               && lease.sidecar_pid_start_time = child_pid_start_time ->
                            release_before_cleanup
                              ~release:(fun () ->
                                release ~owners_dir
                                  ~socket_identity:lease.socket_identity
                                  ~thread_id:lease.thread_id ~sidecar_pid:child_pid
                                  ?sidecar_pid_start_time:child_pid_start_time ())
                              ~cleanup:(fun () ->
                                match child_pid_start_time with
                                | Some start_time ->
                                    C2c_start.clear_registration_pid_if_owner
                                      ~broker_root ~session_id:broker_session_id
                                      ~pid:child_pid ~pid_start_time:(Some start_time)
                                | None -> false)
                        | _ -> false
                      in
                      restore_signal_mask ();
                      if not stopped then failwith "sidecar child could not be reaped";
                      let reason =
                        match !publication_error with
                        | Some reason ->
                            "sidecar arm record could not be published: " ^ reason
                        | None -> "sidecar arm record could not be published"
                      in
                      if cleanup_ok then Arm_failed reason
                      else Arm_failed
                        (reason
                         ^ "; lease/registration cleanup was not confirmed and was retained for retry")
                    end else begin
                    restore_signal_mask ();
                    let deadline = Unix.gettimeofday () +. arm_wait_s in
                    let result = ref None in
                    let rec wait () =
                      let child_state = observe_child child_pid in
                      let lease = peek ~owners_dir ~socket_identity ~thread_id in
                      match child_state, lease with
                      | Child_alive, Some l
                        when l.sidecar_pid = child_pid
                             && lease_live l
                             && l.sidecar_pid_start_time = child_pid_start_time
                             && (match l.sidecar_pid_start_time with
                                 | Some start_time ->
                                     registration_is_live ~broker_root
                                       ~broker_session_id ~alias ~pid:child_pid
                                       ~pid_start_time:start_time
                                 | None -> false) ->
                          result := Some (Armed { child_pid })
                      | (Child_exited | Child_unavailable), _ ->
                          result := Some
                            (Arm_failed "sidecar child exited or could not be reaped")
                      | Child_alive, _ when Unix.gettimeofday () < deadline ->
                          Unix.sleepf 0.02;
                          wait ()
                      | Child_alive, _ ->
                          result := Some (Arm_failed "sidecar did not claim its lease")
                    in
                    wait ();
                    (* Confirm the operational claim once more after the
                       registration/lease observation. This closes the small
                       child-exited-after-read window before [Armed] escapes. *)
                    (match !result with
                     | Some (Armed _) ->
                         Unix.sleepf 0.02;
                         let child_state = observe_child child_pid in
                         (match child_state,
                                peek ~owners_dir ~socket_identity ~thread_id with
                          | Child_alive, Some l
                            when l.sidecar_pid = child_pid
                                 && lease_live l
                                 && l.sidecar_pid_start_time = child_pid_start_time
                                 && (match l.sidecar_pid_start_time with
                                     | Some start_time ->
                                         registration_is_live ~broker_root
                                           ~broker_session_id ~alias ~pid:child_pid
                                           ~pid_start_time:start_time
                                     | None -> false) -> ()
                          | _ ->
                              result := Some
                                (Arm_failed
                                   "sidecar stopped before arm became operational"))
                     | _ -> ());
                    let result =
                      Option.value !result
                        ~default:(Arm_failed "sidecar arm timed out")
                    in
                    (match result with
                     | (Armed _ as armed) ->
                         (match instance_name with
                          | Some instance_name ->
                              (try
                                 C2c_start.write_codex_daemon_sidecar_pid
                                   instance_name child_pid
                               with _ -> ())
                          | None -> ());
                         if C2c_start.remove_codex_daemon_sidecar_arm ~owners_dir ~token
                         then armed
                         else begin
                           (* The child is already operational at this point.
                              A failed pending-record removal must therefore
                              perform the same exact-owner shutdown as every
                              other failed arm before the hook is allowed to
                              enable fallback delivery.  If any owner-bound
                              step is uncertain, retain the ownership barrier
                              and make the hook suppress fallback delivery. *)
                           let stopped =
                             stop_pid ?sidecar_pid_start_time:child_pid_start_time
                               child_pid
                           in
                           let lease_released =
                             if not stopped then false
                             else
                               match peek ~owners_dir ~socket_identity
                                       ~thread_id with
                               | Some lease
                                 when lease.sidecar_pid = child_pid
                                      && lease.sidecar_pid_start_time = child_pid_start_time ->
                                   release ~owners_dir
                                     ~socket_identity:lease.socket_identity
                                     ~thread_id:lease.thread_id
                                     ~sidecar_pid:child_pid
                                     ?sidecar_pid_start_time:child_pid_start_time ()
                               | None -> true
                               | Some _ -> false
                             in
                             let cleanup_result =
                               arm_failed_after_pending_cleanup ~stopped ~lease_released
                             in
                             match cleanup_result with
                             | Arm_failed_ownership_retained _ -> cleanup_result
                             | Arm_failed _ -> begin
                               (* Registration cleanup is exact-generation
                                  pinned too.  It is safe to permit fallback
                                  once the child and lease are gone; retain
                                  the pending record itself for a later,
                                  identity-pinned retry if necessary. *)
                               ignore
                                 (C2c_start.clear_registration_pid_if_owner
                                    ~broker_root ~session_id:broker_session_id
                                    ~pid:child_pid
                                    ~pid_start_time:child_pid_start_time);
                               cleanup_result
                             end
                             | other -> other
                         end
                     | Arm_failed _ as failed ->
                         (* A child that never observes a valid loaded thread
                            must not survive the hook's fallback decision. Keep
                            the pending record if owner-bound termination fails,
                            so a later stop can retry it. *)
                         let stopped =
                           stop_pid ?sidecar_pid_start_time:child_pid_start_time
                             child_pid
                         in
                         if stopped then begin
                           (try ignore (Unix.waitpid [] child_pid)
                            with Unix.Unix_error (Unix.ECHILD, _, _) -> ());
                           ignore
                             (C2c_start.remove_codex_daemon_sidecar_arm ~owners_dir ~token);
                         end;
                         failed
                     | Arm_failed_ownership_retained _ as failed -> failed
                     | other ->
                         ignore
                           (C2c_start.remove_codex_daemon_sidecar_arm ~owners_dir ~token);
                         other)
                    end)
                ))

let is_arm_pending_filename name =
  String.length name > 5
  && String.sub name 0 5 = ".arm-"
  && Filename.check_suffix name ".json"

type owners_dir_read = Owners_dir_missing | Owners_dir_entries of string array | Owners_dir_unreadable

let read_owners_dir owners_dir =
  try
    match (Unix.stat owners_dir).Unix.st_kind with
    | Unix.S_DIR -> Owners_dir_entries (Sys.readdir owners_dir)
    | _ -> Owners_dir_unreadable
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Owners_dir_missing
  | _ -> Owners_dir_unreadable

(* Return both matching leases and whether the owner directory was fully
   understood. A malformed lease is an unknown live-owner state, so stop paths
   must retain their lifecycle records instead of silently filtering it out. *)
let collect_leases ~owners_dir ~matches =
  match read_owners_dir owners_dir with
  | Owners_dir_missing -> (true, [])
  | Owners_dir_unreadable -> (false, [])
  | Owners_dir_entries entries ->
    let ok = ref true and leases = ref [] in
    let names = Array.to_list entries in
    List.iter
      (fun name ->
        if C2c_start.is_lifecycle_recovery_artifact_name name then begin
          ok := false;
          Printf.eprintf
            "c2c: retaining Codex sidecar recovery artifact %s for retry\n%!"
            (owners_dir // name)
        end else if Filename.check_suffix name ".json"
           && not (is_arm_pending_filename name)
        then
          match read_lease_state (owners_dir // name) with
          | Lease_present lease when matches lease -> leases := lease :: !leases
          | Lease_present _ -> ()
          | Lease_missing -> ()
          | Lease_unreadable ->
              ok := false;
              Printf.eprintf
                "c2c: cannot parse Codex sidecar lease %s; retaining for retry\n%!"
                (owners_dir // name))
      names;
    (!ok, List.rev !leases)

let leases_for_session ~owners_dir ~broker_session_id =
  snd (collect_leases ~owners_dir
         ~matches:(fun l -> l.broker_session_id = broker_session_id))

let leases_for_thread ~owners_dir ~thread_id =
  snd (collect_leases ~owners_dir
         ~matches:(fun l -> l.thread_id = thread_id))

let stop_lease ~owners_dir (l : lease) =
  let path = lease_path ~owners_dir ~socket_identity:l.socket_identity
      ~thread_id:l.thread_id in
  let owner_record_matches =
    match read_lease_state path with
    | Lease_present current ->
        current.socket_identity = l.socket_identity
        && current.thread_id = l.thread_id
        && current.sidecar_pid = l.sidecar_pid
        && current.sidecar_pid_start_time = l.sidecar_pid_start_time
        && current.alias = l.alias
        && current.broker_session_id = l.broker_session_id
    | Lease_missing | Lease_unreadable -> false
  in
  if not owner_record_matches then begin
    Printf.eprintf
      "c2c: refusing to act on Codex sidecar lease with uncertain filename or owner identity (thread %s); retaining it for retry\n%!"
      l.thread_id;
    false
  end else match l.sidecar_pid_start_time with
  | None ->
      (* A legacy lease is unverifiable. Do not signal or release its numeric
         PID: it may have been recycled, or may still be live. *)
      Printf.eprintf
        "c2c: retaining unverifiable legacy Codex sidecar lease (pid %d, thread %s)\n%!"
        l.sidecar_pid l.thread_id;
      false
  | Some expected ->
      let stopped =
        match lease_owner_state l with
        | Lease_owner_live -> stop_pid ~sidecar_pid_start_time:expected l.sidecar_pid
        | Lease_owner_gone -> true
        | Lease_owner_unknown -> false
      in
      if stopped then begin
        let released =
          release ~owners_dir ~socket_identity:l.socket_identity ~thread_id:l.thread_id
            ~sidecar_pid:l.sidecar_pid ~sidecar_pid_start_time:expected ()
        in
        if released then true
        else begin
          Printf.eprintf
            "c2c: failed to release Codex sidecar lease for thread %s; retaining lease for retry\n%!"
            l.thread_id;
          false
        end
      end else begin
        Printf.eprintf
          "c2c: failed to stop Codex sidecar pid %d; retaining lease for thread %s\n%!"
          l.sidecar_pid l.thread_id;
        false
      end

let stop_for_session ~owners_dir ~broker_session_id =
  let arms_ok =
    C2c_start.cancel_codex_daemon_sidecar_arms ~owners_dir ~broker_session_id ()
  in
  let leases_ok, leases =
    collect_leases ~owners_dir
      ~matches:(fun l -> l.broker_session_id = broker_session_id)
  in
  let ok = ref (arms_ok && leases_ok)
  in
  leases |> List.iter (fun lease -> if not (stop_lease ~owners_dir lease) then ok := false);
  !ok

let stop_for_thread ~owners_dir ~thread_id =
  let arms_ok = C2c_start.cancel_codex_daemon_sidecar_arms ~owners_dir ~thread_id () in
  let leases_ok, leases =
    collect_leases ~owners_dir ~matches:(fun l -> l.thread_id = thread_id)
  in
  let ok = ref (arms_ok && leases_ok)
  in
  leases |> List.iter (fun lease -> if not (stop_lease ~owners_dir lease) then ok := false);
  !ok
