(* c2c_codex_adopt — promote a live vanilla Codex hook registration to the
   shared daemon-backed delivery path. Adoption owns only the delivery sidecar;
   the already-running vanilla Codex frontend remains operator-owned. *)

open Cmdliner
open Cmdliner.Term.Syntax

exception Adoption_error of string

let errorf fmt = Printf.ksprintf (fun s -> raise (Adoption_error s)) fmt

let required_registration ~broker ~alias : C2c_mcp.registration =
  let wanted = String.lowercase_ascii (String.trim alias) in
  match List.filter
          (fun (r : C2c_mcp.registration) ->
             String.lowercase_ascii r.alias = wanted)
          (C2c_mcp.Broker.list_registrations broker) with
  | [ registration ] -> registration
  | [] ->
      errorf "no registration found for alias '%s'; run the plain `codex` session with `c2c install codex` first" alias
  | rows ->
      errorf "alias '%s' has %d registrations; adoption refuses ambiguity"
        alias (List.length rows)

let same_candidate (left : C2c_mcp.registration) (right : C2c_mcp.registration) =
  left.session_id = right.session_id
  && String.lowercase_ascii left.alias = String.lowercase_ascii right.alias
  && left.client_type = right.client_type
  && left.registered_by = right.registered_by
  && left.cwd = right.cwd

let canonical_cwd (registration : C2c_mcp.registration) =
  match registration.cwd with
  | Some cwd when String.trim cwd <> "" ->
      (try Unix.realpath cwd with _ -> String.trim cwd)
  | _ ->
      errorf "registration '%s' has no workspace cwd; adoption refuses an unverified workspace"
        registration.alias

let registration_is_adoptable (registration : C2c_mcp.registration) =
  registration.client_type = Some "codex"
  && registration.registered_by = Some "codex-hook"

(* Hook rows are pidless by design. A fresh activity lease is useful evidence,
   but an authenticated loaded native thread is the stronger proof used below.
   A row classified dead is rejected; Unknown remains eligible until the exact
   daemon/thread/workspace proof succeeds. *)
let require_live_candidate registration =
  match C2c_mcp.Broker.registration_liveness_state registration with
  | C2c_mcp.Broker.Dead ->
      errorf "vanilla Codex registration '%s' is stale; trigger a new Codex hook event and retry"
        registration.alias
  | C2c_mcp.Broker.Alive | C2c_mcp.Broker.Unknown -> ()

let discover_exact_thread ~endpoint ~native_thread_id ~cwd =
  match
    C2c_codex_ingress.real_loaded_threads_for_cwd_result
      ~endpoint ~token:"" ~cwd
  with
  | C2c_codex_ingress.Loaded_threads_for_cwd [ thread_id ]
    when thread_id = native_thread_id -> thread_id
  | C2c_codex_ingress.Loaded_threads_for_cwd [] ->
      (match
         C2c_codex_ingress.real_thread_read_state
           ~endpoint ~token:"" ~thread_id:native_thread_id
       with
       | C2c_codex_ingress.Thread_read_not_loaded ->
           errorf
             "native Codex thread '%s' is persisted but not loaded in the machine daemon for workspace %s; the live vanilla frontend owns an embedded app-server and cannot be attached safely. Leave it active for hook delivery, or start it through `c2c start codex` for arrival-time delivery"
             native_thread_id cwd
       | C2c_codex_ingress.Thread_read_loaded ->
           errorf
             "native Codex thread '%s' is readable but not present in the daemon loaded-thread set for workspace %s; adoption refuses an unproven owner"
             native_thread_id cwd
       | C2c_codex_ingress.Thread_read_unavailable reason ->
           errorf
             "native Codex thread '%s' is not loaded in workspace %s and its exact persisted state could not be verified (%s); leave the vanilla session active and retry"
             native_thread_id cwd reason)
  | C2c_codex_ingress.Loaded_threads_for_cwd ids ->
      errorf "workspace %s has %d loaded Codex threads; adoption refuses to guess (wanted '%s')"
        cwd (List.length ids) native_thread_id
  | C2c_codex_ingress.Loaded_threads_for_cwd_unavailable reason ->
      errorf "cannot authenticate Codex daemon thread discovery: %s" reason

(* Adoption-owned lifecycle files are required to be absent before the
   transaction. This keeps rollback simple and avoids overwriting another
   instance's durable state. *)
type file_state = File_absent | File_present of string | File_unknown of string

let read_file_state path =
  match C2c_start.read_regular_file_nofollow path with
  | C2c_start.Regular_file_missing -> File_absent
  | C2c_start.Regular_file_contents contents -> File_present contents
  | C2c_start.Regular_file_unreadable reason -> File_unknown reason

let require_absent path label =
  match read_file_state path with
  | File_absent -> ()
  | File_present _ -> errorf "%s already exists; adoption refuses to overwrite it" label
  | File_unknown reason ->
      errorf "cannot inspect %s safely: %s" label reason

let remove_owned path contents =
  ignore (C2c_start.remove_path_contents_confirmed path contents)

let capture_owned path label =
  match read_file_state path with
  | File_present contents -> contents
  | File_absent -> errorf "adoption-owned %s disappeared during the transaction" label
  | File_unknown reason ->
      errorf "cannot verify adoption-owned %s after writing it: %s" label reason

let write_owned_file path contents =
  match C2c_io.write_file_atomic ~perm:0o600 path contents with
  | Ok () -> ()
  | Error reason -> errorf "could not persist %s: %s" path reason

let remove_created path =
  match read_file_state path with
  | File_present contents -> remove_owned path contents
  | File_absent -> ()
  | File_unknown _ -> ()

let restore_hook_registration broker (registration : C2c_mcp.registration) =
  (* Re-registration is safe only after the exact sidecar lease has been
     released. The explicit fields restore the hook-owned row while preserving
     DND, keys, and other metadata belonging to this same session. *)
  C2c_mcp.Broker.register broker
    ~session_id:registration.session_id ~alias:registration.alias
    ~pid:registration.pid ~pid_start_time:registration.pid_start_time
    ~client_type:registration.client_type
    ~plugin_version:registration.plugin_version
    ~enc_pubkey:registration.enc_pubkey
    ~ed25519_pubkey:registration.ed25519_pubkey
    ~pubkey_signed_at:registration.pubkey_signed_at
    ~pubkey_sig:registration.pubkey_sig
    ~role:registration.role
    ~tmux_location:registration.tmux_location
    ~herdr_pane:registration.herdr_pane
    ~herdr_socket:registration.herdr_socket
    ~cwd:registration.cwd
    ~metadata_opt_out:registration.metadata_opt_out
    ~registered_by:registration.registered_by
    ~opaque_host_id:registration.opaque_host_id
    ~preserve_existing_metadata:true ()

let adopted_marker_contents = "vanilla-codex-adopted\n"

let find_sidecar_lease ~thread_id ~socket_identity ~broker_session_id ~alias () =
  C2c_codex_daemon_sidecar.leases_for_thread
    ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ()) ~thread_id
  |> List.find_opt (fun (lease : C2c_codex_daemon_sidecar.lease) ->
       lease.socket_identity = socket_identity
       && lease.broker_session_id = broker_session_id
       && lease.alias = alias
       && Option.is_some lease.sidecar_pid_start_time)

let adopt_one ~json alias =
  Unix.putenv "C2C_CODEX_INGRESS_LIVE" "1";
  let broker_root = C2c_cli_helpers.resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let initial = required_registration ~broker ~alias in
  if not (registration_is_adoptable initial) then
    errorf "alias '%s' is not a live vanilla codex-hook registration; refusing adoption"
      initial.alias;
  require_live_candidate initial;
  let cwd = canonical_cwd initial in
  let native_thread_id = initial.session_id in
  let socket_path =
    match C2c_codex_daemon_sidecar.default_control_socket () with
    | Some path -> path
    | None ->
        errorf "Codex managed daemon control socket is unavailable; vanilla hook delivery remains active"
  in
  let endpoint =
    match C2c_codex_daemon_sidecar.unix_endpoint socket_path with
    | Some endpoint -> endpoint
    | None -> errorf "Codex daemon control socket is not usable; no state was changed"
  in
  let thread_id = discover_exact_thread ~endpoint ~native_thread_id ~cwd in
  let instance_name = initial.alias in
  let instance_dir = C2c_start.instance_dir instance_name in
  let config_path = C2c_start.config_path instance_name in
  let mapping_path = C2c_codex_session.mapping_path ~instance_dir in
  let attachment_path = C2c_codex_session.daemon_attachment_path ~instance_dir in
  let marker_path = C2c_start.adopted_codex_marker_path instance_name in
  let expected_cwd_path = C2c_start.expected_cwd_path instance_name in
  let lifecycle_lock =
    C2c_start.acquire_instance_lock_for_daemon_attach ~name:instance_name
  in
  Fun.protect
    ~finally:(fun () ->
      C2c_start.release_instance_lock_for_daemon_attach
        ~name:instance_name lifecycle_lock)
    (fun () ->
      (* Re-read after taking the lock. A hook event may have changed the row
         while discovery was in progress. *)
      let current = required_registration ~broker ~alias:initial.alias in
      if not (same_candidate initial current) then
        errorf "vanilla Codex registration changed during adoption; retry while the session is active";
      if not (registration_is_adoptable current) then
        errorf "vanilla Codex registration no longer belongs to codex-hook; refusing adoption";
      require_live_candidate current;
      require_absent config_path "managed instance config";
      require_absent mapping_path "Codex session mapping";
      require_absent attachment_path "daemon attachment";
      require_absent marker_path "adoption marker";
      require_absent expected_cwd_path "adopted workspace record";
      let config_written = ref false in
      let mapping_written = ref false in
      let marker_written = ref false in
      let cwd_written = ref false in
      let attachment_written = ref false in
      let sidecar_lease : C2c_codex_daemon_sidecar.lease option ref = ref None in
      let sidecar_owner_retained = ref false in
      let rollback_files () =
        (* Every adoption-owned path was proven absent before the transaction.
           Remove by exact contents even when the writer failed before its
           success flag was set, so a partial config/mapping cannot poison a
           later retry. *)
        remove_created attachment_path;
        remove_created marker_path;
        remove_created expected_cwd_path;
        remove_created mapping_path;
        remove_created config_path
      in
      let rollback_registration () =
        if !sidecar_owner_retained then false
        else
          let stopped =
            match !sidecar_lease with
            | Some lease ->
                C2c_codex_daemon_sidecar.stop_lease
                  ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                  lease
            | None ->
                (* [arm] may have changed the row before returning a failure.
                   Sweep only an exact lease for this thread/socket/session and
                   restore the hook row after the owner is gone. *)
                (match find_sidecar_lease ~thread_id
                         ~socket_identity:endpoint.host
                         ~broker_session_id:current.session_id
                         ~alias:current.alias () with
                 | Some lease ->
                     C2c_codex_daemon_sidecar.stop_lease
                       ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                       lease
                 | None -> true)
          in
          if stopped then
            (try restore_hook_registration broker current; true with _ -> false)
          else false
      in
      let rollback () =
        let registration_ok = rollback_registration () in
        if registration_ok then rollback_files ()
        else
          Printf.eprintf
            "c2c codex adopt: ownership cleanup is uncertain; retaining the sidecar barrier and lifecycle files for retry\n%!"
      in
      try
        let now = Unix.gettimeofday () in
        C2c_start.write_config
          { C2c_start.name = instance_name; client = "codex";
            session_id = current.session_id; resume_session_id = thread_id;
            codex_resume_target = Some thread_id; alias = current.alias;
            extra_args = []; created_at = now; last_launch_at = Some now;
            last_exit_code = None; last_exit_reason = None; broker_root;
            auto_join_rooms = C2c_swarm_config.swarm_config_social_room ();
            binary_override = None; model_override = None; agent_name = None };
        config_written := true;
        if not (C2c_codex_session.persist_discovered_thread
                  ~instance_dir ~name:instance_name ~broker_root ~thread_id)
        then errorf "Codex thread '%s' is already owned by another managed delivery owner" thread_id;
        mapping_written := true;
        write_owned_file expected_cwd_path (cwd ^ "\n");
        cwd_written := true;
        write_owned_file marker_path adopted_marker_contents;
        marker_written := true;
        let armed =
          match
            C2c_codex_daemon_sidecar.arm ~instance_name ~thread_id
              ~alias:current.alias ~broker_session_id:current.session_id
              ~broker_root ()
          with
          | C2c_codex_daemon_sidecar.Armed { child_pid } ->
              let lease =
                C2c_codex_daemon_sidecar.peek
                  ~owners_dir:(C2c_codex_daemon_sidecar.default_owners_dir ())
                  ~socket_identity:endpoint.host ~thread_id
              in
              (match lease with
               | Some lease when lease.sidecar_pid = child_pid
                              && lease.thread_id = thread_id
                              && lease.alias = current.alias
                              && lease.broker_session_id = current.session_id
                              && lease.socket_identity = endpoint.host
                              && Option.is_some lease.sidecar_pid_start_time
                              && C2c_mcp.Broker.read_pid_start_time child_pid
                                 = lease.sidecar_pid_start_time
                              -> sidecar_lease := Some lease
               | _ -> errorf "sidecar armed without an exact matching ownership lease");
              child_pid
          | C2c_codex_daemon_sidecar.Already_running _ ->
              errorf "another delivery owner already owns Codex thread '%s'; adoption refuses pre-existing ownership" thread_id
          | C2c_codex_daemon_sidecar.Claim_held _ ->
              errorf "another delivery owner already owns Codex thread '%s'" thread_id
          | C2c_codex_daemon_sidecar.Socket_unavailable ->
              errorf "Codex daemon socket became unavailable; vanilla hook delivery remains active"
          | C2c_codex_daemon_sidecar.Arm_failed reason ->
              errorf "daemon delivery sidecar could not be armed: %s" reason
          | C2c_codex_daemon_sidecar.Arm_failed_ownership_retained reason ->
              sidecar_owner_retained := true;
              errorf "daemon delivery ownership was retained after an uncertain failure: %s" reason
        in
        let owner_start_time = C2c_mcp.Broker.read_pid_start_time armed in
        if not
             (C2c_codex_session.write_adopted_daemon_attachment
                ~instance_dir ~endpoint ~owner_pid:armed
                ~owner_pid_start_time:owner_start_time ~thread_id ())
        then errorf "managed daemon attachment state could not be persisted";
        attachment_written := true;
        let result =
          `Assoc [ ("ok", `Bool true); ("alias", `String current.alias);
                   ("session_id", `String current.session_id);
                   ("thread_id", `String thread_id);
                   ("transport", `String "codex-daemon");
                   ("delivery", `String "app-server");
                   ("frontend", `String "vanilla-untouched") ]
        in
        if json then C2c_cli_helpers.print_json result
        else
          Printf.printf
            "adopted vanilla Codex %s (thread %s) onto the shared daemon; the existing frontend remains running\n%!"
            current.alias thread_id
      with
      | Adoption_error message ->
          rollback ();
          if !sidecar_owner_retained then
            errorf "%s; hook fallback remains disabled until ownership is resolved" message
          else raise (Adoption_error message)
      | exn ->
          rollback ();
          raise exn)

let adopt_cmd =
  let alias =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS"
      ~doc:"Vanilla Codex c2c alias to promote into daemon-backed delivery.")
  in
  let json = Arg.(value & flag & info [ "json" ]
    ~doc:"Print a machine-readable result.") in
  let+ alias = alias and+ json = json in
  try adopt_one ~json alias
  with Adoption_error message ->
    Printf.eprintf "error: %s\n%!" message;
    exit 1

let adopt : unit Cmd.t =
  Cmd.v
    (Cmd.info "adopt"
       ~doc:"Promote a live vanilla Codex alias into shared daemon delivery."
       ~man:[ `S "DESCRIPTION"
            ; `P "Promotes a live plain codex session registered by `c2c hook codex`. c2c authenticates the existing Codex daemon, proves exactly one loaded native thread in the registration workspace, and arms the same delivery sidecar used by managed Codex. The vanilla Codex frontend and its draft remain untouched."
            ; `P "Adoption requires a live codex-hook registration and an exact native thread loaded in the shared daemon. A normal vanilla TUI may own an embedded app-server that the daemon cannot attach to; c2c refuses that state safely, leaves hook-boundary delivery active, and recommends `c2c start codex` for arrival-time delivery." ])
    adopt_cmd
