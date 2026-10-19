(* `c2c t3`: operator CLI and foreground service for one local T3 Code home.

   The command is deliberately a thin adapter over the native client, durable
   state journal and service policy modules.  It never edits T3 state and never
   borrows a provider/native caller credential. *)

open C2c_cli_helpers
open Cmdliner.Term
open Cmdliner.Term.Syntax
open Lwt.Infix

module T3 = C2c_t3_client
module Service = C2c_t3_service
module State = C2c_t3_state
module Recovery = C2c_t3_recovery

let ( // ) = Filename.concat

let getenv_nonempty name =
  match Sys.getenv_opt name with Some value when String.trim value <> "" -> Some (String.trim value) | _ -> None

let home_dir () = Option.value (getenv_nonempty "HOME") ~default:"."
let t3_home () = Option.value (getenv_nonempty "T3CODE_HOME") ~default:(home_dir () // ".t3")
let config_dir () = Option.value (getenv_nonempty "C2C_T3_CONFIG_DIR") ~default:(home_dir () // ".c2c" // "t3")
let state_dir () = Option.value (getenv_nonempty "C2C_T3_STATE_DIR") ~default:(home_dir () // ".local" // "state" // "c2c" // "t3")

let now () = Unix.gettimeofday ()

let run_lwt f =
  try Lwt_main.run f with exn -> Error (Printexc.to_string exn)

let run_t3 f =
  try Lwt_main.run f with exn -> Error (T3.Protocol (Printexc.to_string exn))

let run_lwt_exn f =
  try Lwt_main.run f with exn -> raise exn

let print_error error = Printf.eprintf "error: %s\n%!" error

let string_of_mode = function
  | `Auto -> "auto" | `Queue -> "queue" | `Steer -> "steer" | `Restart -> "restart"

let mode_of_string = function
  | "auto" -> Ok `Auto | "queue" -> Ok `Queue | "steer" -> Ok `Steer | "restart" -> Ok `Restart
  | value -> Error ("unknown delivery mode " ^ value ^ "; use auto, queue, steer, or restart")

let as_command term = Cmdliner.Term.(const (fun code -> exit code) $ term)

let t3_binary () =
  match getenv_nonempty "C2C_T3_BIN" with
  | Some path when Filename.is_relative path -> Error "C2C_T3_BIN must be an absolute path"
  | Some path -> Ok path
  | None ->
      let path_entries =
        String.split_on_char ':' (Option.value (Sys.getenv_opt "PATH") ~default:"")
      in
      match List.find_opt (fun dir -> Sys.file_exists (dir // "t3")) path_entries with
      | Some dir -> Ok (dir // "t3")
      | None -> Error "T3 CLI was not found; set C2C_T3_BIN to its absolute path"

let environment_id runtime =
  let seed = "t3-home:" ^ runtime.T3.t3_home in
  "t3-env-" ^ String.sub (Digestif.SHA256.(to_hex (digest_string seed))) 0 32

let authorized ?(rebind = false) () =
  match T3.authorize ~rebind ~config_dir:(config_dir ()) ~t3_home:(t3_home ()) () with
  | Error error -> Error (T3.error_to_string error)
  | Ok (client, runtime) ->
      (match run_t3 (T3.initialize client) with
       | Error error -> Error (T3.error_to_string error)
       | Ok () -> Ok (client, runtime))

let open_state () =
  match State.open_state ~dir:(state_dir ()) () with
  | Ok state -> Ok state
  | Error error -> Error (State.open_error_to_string error)

let with_state f =
  match open_state () with
  | Error error -> print_error error; 1
  | Ok state -> Fun.protect ~finally:(fun () -> State.close state) (fun () -> f state)

let thread_mapping_json mapping =
  `Assoc
    [ ("threadId", `String mapping.State.thread_id);
      ("alias", `String mapping.alias);
      ("createdAt", `Float mapping.created_at);
      ("tombstone", match mapping.tombstone with
       | None -> `Null
       | Some tombstone -> `Assoc [ ("at", `Float tombstone.tombstoned_at); ("reason", `String tombstone.reason) ]) ]

let state_snapshot () =
  let directory = state_dir () in
  let path = directory // "state.json" in
  if not (Sys.file_exists directory) then
    `Assoc [ ("available", `Bool false); ("reason", `String "state directory is absent") ]
  else
    let private_ok () =
      try
        let st = Unix.lstat directory in
        st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid ()
        && st.Unix.st_perm land 0o077 = 0
      with _ -> false
    in
    if not (private_ok ()) then
      `Assoc [ ("available", `Bool false); ("reason", `String "state directory ownership or permissions are unsafe") ]
    else if not (Sys.file_exists path) then
      `Assoc [ ("available", `Bool true); ("initialized", `Bool false); ("pending", `Int 0); ("mappings", `Int 0) ]
    else
      try
        match Yojson.Safe.from_file path with
        | `Assoc fields ->
            let length key = match List.assoc_opt key fields with Some (`List values) -> List.length values | _ -> 0 in
            `Assoc [ ("available", `Bool true); ("initialized", `Bool true); ("pending", `Int (length "journal")); ("mappings", `Int (length "mappings")); ("acked", `Int (length "acked")) ]
        | _ -> `Assoc [ ("available", `Bool false); ("reason", `String "state.json is not an object") ]
      with _ -> `Assoc [ ("available", `Bool false); ("reason", `String "state.json is malformed") ]

let pair_cmd pairing_code replace json =
  match T3.resolve_home () with
  | Error error -> print_error (T3.error_to_string error); 1
  | Ok home ->
      (match T3.discover ~t3_home:home () with
       | Error error -> print_error (T3.error_to_string error); 1
       | Ok runtime ->
           let validate () =
             match T3.discover ~t3_home:home () with
             | Error error -> Error error
             | Ok current when current.origin = runtime.origin && current.proof = runtime.proof -> Ok ()
             | Ok _ -> Error (T3.Runtime_changed "T3 restarted while pairing")
           in
           let code_result =
             match pairing_code with
             | Some code -> Ok code
             | None ->
                 (match t3_binary () with
                  | Error message -> Error (T3.Discovery message)
                  | Ok binary -> run_t3 (T3.create_pairing_code ~runtime ~t3_bin:binary))
           in
           (match code_result with
            | Error error -> print_error (T3.error_to_string error); 1
            | Ok code ->
                (match pairing_code with
                 | None -> Printf.printf "Pairing code: %s\nEnter the code shown in T3 (or pass --pairing-code):\n%!" code
                 | Some _ -> ());
                let code =
                  match pairing_code with
                  | Some code -> code
                  | None ->
                      (try String.trim (input_line stdin) with End_of_file -> "")
                in
                if code = "" then (print_error "pairing code is empty"; 1)
                else
                  match run_t3
                          (T3.pair ~runtime ~validate ~pairing_code:code
                             ~client_name:"c2c-t3-connector" ~config_dir:(config_dir ()) ~replace ()) with
                  | Error error -> print_error (T3.error_to_string error); 1
                  | Ok credential ->
                      if json then
                        print_json (`Assoc [ ("ok", `Bool true); ("configDir", `String (config_dir ())); ("generation", `Int (T3.credential_generation credential)) ])
                      else Printf.printf "Paired with T3 at %s (credential generation %d).\n" runtime.origin (T3.credential_generation credential);
                      0))

let pair_term =
  let pairing_code = Cmdliner.Arg.(value & opt (some string) None & info [ "pairing-code" ] ~docv:"CODE" ~doc:"T3 pairing code. If omitted, create one and prompt for it.") in
  let replace = Cmdliner.Arg.(value & flag & info [ "replace" ] ~doc:"Replace an existing connector credential explicitly.") in
  let json = json_flag in
  as_command (const pair_cmd $ pairing_code $ replace $ json)

let list_cmd json =
  match authorized () with
  | Error error -> print_error error; 1
  | Ok (client, runtime) ->
      with_state (fun state ->
        match run_t3 (Service.discover client) with
        | Error error -> print_error (T3.error_to_string error); 1
        | Ok scan ->
            let mappings = State.mappings state in
            let rows =
              List.map
                (fun thread ->
                  let mapping = List.find_opt (fun (m : State.mapping) -> m.thread_id = thread.Service.thread_id) mappings in
                  `Assoc [ ("projectId", `String thread.project_id); ("threadId", `String thread.thread_id);
                           ("title", `String thread.title); ("alias", match mapping with Some m -> `String m.alias | None -> `Null);
                           ("runtimeMode", match thread.runtime_mode with Some s -> `String s | None -> `Null) ])
                scan.listed
            in
            if json then print_json (`Assoc [ ("environmentId", `String (environment_id runtime)); ("complete", `Bool scan.complete); ("errors", `List (List.map (fun e -> `String e) scan.errors)); ("threads", `List rows) ])
            else begin
              List.iter (fun row ->
                match row with
                | `Assoc f ->
                    let get k = match List.assoc_opt k f with Some (`String s) -> s | _ -> "-" in
                    Printf.printf "%s  %s  %s  %s\n" (get "alias") (get "threadId") (get "runtimeMode") (get "title")
                | _ -> ()) rows;
              if not scan.complete then Printf.eprintf "warning: discovery incomplete; aliases were not retired.\n%!"
            end;
            0)

let list_term = as_command (const list_cmd $ json_flag)

let status_cmd json =
  let credential =
    match T3.load_credential ~config_dir:(config_dir ()) with
    | Ok value -> `Assoc [ ("present", `Bool true); ("generation", `Int (T3.credential_generation value)); ("scopes", `List (List.map (fun s -> `String s) (T3.credential_scopes value))) ]
    | Error error -> `Assoc [ ("present", `Bool false); ("error", `String (T3.error_to_string error)) ]
  in
  let runtime =
    match T3.discover ~t3_home:(t3_home ()) () with
    | Ok value -> `Assoc [ ("ready", `Bool true); ("origin", `String value.origin); ("pid", `Int value.pid); ("home", `String value.t3_home) ]
    | Error error -> `Assoc [ ("ready", `Bool false); ("error", `String (T3.error_to_string error)) ]
  in
  let state = state_snapshot () in
  let unit = `Assoc [ ("path", `String (C2c_t3_systemd.unit_path ())); ("active", `Bool (C2c_t3_systemd.unit_is_active ())); ("enabled", `Bool (C2c_t3_systemd.unit_is_enabled ())) ] in
  let result = `Assoc [ ("configDir", `String (config_dir ())); ("stateDir", `String (state_dir ())); ("credential", credential); ("runtime", runtime); ("state", state); ("unit", unit) ] in
  if json then print_json result else Printf.printf "T3 connector: %s\n" (if runtime <> `Assoc [] then "see status --json" else "degraded");
  0

let status_term = as_command (const status_cmd $ json_flag)

let resolve_target state locator =
  let registered = List.map (fun (r : C2c_mcp.registration) -> r.alias) (C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:(resolve_broker_root ()))) in
  match Service.resolve_locator ~mappings:(State.mappings state) ~registered_aliases:registered locator with
  | Service.Alias alias -> Ok (State.find_by_alias state ~alias)
  | Service.Thread_alias alias -> Ok (State.find_by_alias state ~alias)
  | Service.Ambiguous_thread id -> Error ("thread locator is ambiguous: " ^ id)
  | Service.Unknown_thread id -> Error ("unknown T3 thread: " ^ id)

let send_cmd locator message mode json =
  match authorized () with
  | Error error -> print_error error; 1
  | Ok (client, _) ->
      with_state (fun state ->
        match resolve_target state locator with
        | Error error -> print_error error; 1
        | Ok None -> print_error ("no local T3 mapping for " ^ locator); 1
        | Ok (Some mapping) ->
            (match mode_of_string mode with
             | Error error -> print_error error; 1
             | Ok mode ->
                 let request_id = "c2c-t3-cli-" ^ String.sub (Digestif.SHA256.(to_hex (digest_string (mapping.thread_id ^ "\000" ^ message)))) 0 32 in
                 match run_t3 (T3.send_message client ~thread_id:mapping.thread_id ~message ~mode ~client_request_id:request_id) with
                 | Error error -> print_error (T3.error_to_string error); 1
                 | Ok receipt ->
                     if json then print_json (`Assoc [ ("threadId", `String receipt.receipt_thread_id); ("messageId", `String receipt.message_id); ("runId", `String receipt.run_id); ("mode", `String (string_of_mode mode)) ])
                     else Printf.printf "sent to %s (message %s, run %s)\n" mapping.alias receipt.message_id receipt.run_id;
                     0))

let send_term =
  let locator = Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS" ~doc:"Local T3 alias or t3.<thread-id> locator.") in
  let message = Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"MESSAGE" ~doc:"Message text sent as an agent-originated T3 message.") in
  let mode = Cmdliner.Arg.(value & opt string "auto" & info [ "mode" ] ~docv:"MODE" ~doc:"Delivery mode: auto, queue, steer, or restart.") in
  as_command (const send_cmd $ locator $ message $ mode $ json_flag)

let recovery_config_path () = config_dir () // "config.json"

let private_connector_dir path =
  (try
     match Unix.lstat path with
     | st when st.Unix.st_kind = Unix.S_DIR && st.Unix.st_uid = Unix.geteuid ()
                && st.Unix.st_perm land 0o077 = 0 -> Ok ()
     | _ -> Error (path ^ " is not a private directory owned by this user")
   with Unix.Unix_error (Unix.ENOENT, _, _) ->
     (try C2c_io.mkdir_p ~mode:0o700 path; Ok () with exn -> Error (Printexc.to_string exn))
      | exn -> Error (Printexc.to_string exn))

let recovery_enabled () =
  match getenv_nonempty "C2C_T3_RECOVERY" with
  | Some ("0" | "false" | "off") -> false
  | Some ("1" | "true" | "on") -> true
  | _ ->
      (match (try Some (Yojson.Safe.from_file (recovery_config_path ())) with _ -> None) with
       | Some (`Assoc fields) ->
           (match List.assoc_opt "recoveryEnabled" fields with Some (`Bool enabled) -> enabled | _ -> true)
       | _ -> true)

let set_recovery_cmd enabled json =
  let path = recovery_config_path () in
  let existing =
    if not (Sys.file_exists path) then `Assoc []
    else
      try Yojson.Safe.from_file path
      with exn -> print_error ("refusing to overwrite malformed T3 config: " ^ Printexc.to_string exn); exit 1
  in
  let fields = match existing with `Assoc fields -> fields | _ -> print_error "refusing to overwrite non-object T3 config"; exit 1 in
  (match private_connector_dir (config_dir ()) with Ok () -> () | Error error -> print_error error; exit 1);
  (if Sys.file_exists path then
     match (try Some (Unix.lstat path) with _ -> None) with
     | Some st when st.Unix.st_kind = Unix.S_REG && st.Unix.st_uid = Unix.geteuid () && st.Unix.st_perm land 0o077 = 0 -> ()
     | _ -> print_error "refusing to replace a non-private T3 connector config"; exit 1);
  match C2c_io.write_file_atomic ~perm:0o600 path
          (Yojson.Safe.to_string (`Assoc (List.remove_assoc "recoveryEnabled" fields @ [ ("recoveryEnabled", `Bool enabled) ])) ^ "\n") with
  | Error error -> print_error error; 1
  | Ok () -> if json then print_json (`Assoc [ ("recoveryEnabled", `Bool enabled); ("path", `String path) ]) else Printf.printf "model-availability recovery %s\n" (if enabled then "enabled" else "disabled"); 0

let recovery_term enabled =
  as_command (const set_recovery_cmd $ const enabled $ json_flag)

let recovery_status_cmd json =
  if json then print_json (`Assoc [ ("recoveryEnabled", `Bool (recovery_enabled ())); ("path", `String (recovery_config_path ())) ])
  else Printf.printf "model-availability recovery: %s\n" (if recovery_enabled () then "enabled" else "disabled");
  0

let recovery_status_term = as_command (const recovery_status_cmd $ json_flag)

let service_owner ~environment_id ~broker () =
  { Service.environment_id; broker; pid = Some (Unix.getpid ());
    pid_start_time = C2c_mcp.Broker.capture_pid_start_time (Some (Unix.getpid ())); cwd = Some (Sys.getcwd ()); opaque_host_id = None }

let service_once ~client ~runtime ~state ~mode ~cross_repo ~recovery =
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let owner = service_owner ~environment_id:(environment_id runtime) ~broker () in
  match run_t3 (Service.discover client) with
  | Error error -> Error (T3.error_to_string error)
  | Ok scan ->
      let missing = Service.missing_bound_thread_ids ~scan ~mappings:(State.mappings state) in
      let point_reads =
        run_lwt_exn
          (Lwt_list.map_s
             (fun thread_id -> Service.read_bound_thread client ~thread_id >|= fun result -> (thread_id, result)) missing)
      in
      let point_reads =
        List.map
          (fun (thread_id, result) ->
             (thread_id,
              match result with
              | Ok point_read -> point_read
              | Error error -> Service.Failed (T3.error_to_string error)))
          point_reads
      in
      let plan = Service.plan_reconciliation ~scan ~mappings:(State.mappings state) ~point_reads () in
           let applied = Service.apply_plan ~owner ~state ~plan in
           let mode = match mode_of_string mode with Ok value -> value | Error _ -> `Auto in
           List.iter (fun candidate -> ignore (Service.accept_inbox ~mode ~cross_repo ~owner ~state ~mapping:(Option.get candidate.Service.mapping) ())) applied.published;
           let thread_ids = List.map (fun candidate -> candidate.Service.thread.thread_id) applied.published in
           let recovery_result =
             run_lwt_exn (Recovery.sweep ~enabled:recovery ~client ~state ~environment_id:owner.environment_id
                        ~credential_generation:(T3.credential_generation_of client) ~thread_ids ~clock:now ())
           in
           let dispatcher =
             Service.create_dispatcher ~state
               ~credential_generation:(fun () -> T3.credential_generation_of client)
               ~can_send:(Recovery.can_dispatch ~enabled:recovery)
               ~send:(fun ~thread_id ~message ~mode ~client_request_id ->
                 T3.send_message client ~thread_id ~message ~mode ~client_request_id)
               ~clock:now ()
           in
           let rec dispatch count =
             if count >= 1024 then Lwt.return ()
             else Service.dispatch_once dispatcher >>= function
               | Service.Idle | Service.Submitted _ | Service.Retained _ | Service.Held _ -> dispatch (count + 1)
               | Service.Waiting delay -> Lwt_unix.sleep (min delay 60.) >>= fun () -> dispatch (count + 1)
           in
           (match recovery_result with
            | _ -> run_lwt_exn (dispatch 0));
           Ok (scan, applied)

let foreground_cmd foreground once interval mode cross_repo recovery =
  if not foreground && not once then Printf.eprintf "starting c2c T3 connector in foreground (Ctrl-C to stop)\n%!";
  match authorized () with
  | Error error -> print_error error; 1
  | Ok (client, runtime) ->
      with_state (fun state ->
        let rec loop first =
          let () =
            match service_once ~client ~runtime ~state ~mode ~cross_repo ~recovery with
            | Error error -> Printf.eprintf "warning: T3 service degraded: %s\n%!" error
            | Ok (_scan, _applied) -> ()
          in
          if once then 0 else (ignore (Unix.select [] [] [] interval); loop false)
        in
        loop true)

let foreground_term =
  let foreground = Cmdliner.Arg.(value & flag & info [ "foreground" ] ~doc:"Run in the foreground (the default for this command).") in
  let once = Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run one discovery/delivery/recovery sweep and exit (fixture/operator use).") in
  let interval = Cmdliner.Arg.(value & opt float 60. & info [ "interval" ] ~docv:"SECONDS" ~doc:"Seconds between serialized service sweeps (default 60).") in
  let mode = Cmdliner.Arg.(value & opt string "auto" & info [ "mode" ] ~docv:"MODE" ~doc:"Inbound delivery mode: auto, queue, steer, or restart.") in
  let cross_repo = cross_repo_flag in
  let recovery = Cmdliner.Arg.(value & opt bool (recovery_enabled ()) & info [ "recovery" ] ~docv:"BOOL" ~doc:"Enable model-availability Continue recovery (default enabled).") in
  as_command (const foreground_cmd $ foreground $ once $ interval $ mode $ cross_repo $ recovery)

let doctor_cmd json =
  let runtime = match T3.discover ~t3_home:(t3_home ()) () with Ok r -> `Assoc [ ("ready", `Bool true); ("origin", `String r.origin); ("pid", `Int r.pid) ] | Error e -> `Assoc [ ("ready", `Bool false); ("error", `String (T3.error_to_string e)) ] in
  let credential = match T3.load_credential ~config_dir:(config_dir ()) with Ok c -> `Assoc [ ("present", `Bool true); ("generation", `Int (T3.credential_generation c)) ] | Error error -> `Assoc [ ("present", `Bool false); ("error", `String (T3.error_to_string error)) ] in
  let state = state_snapshot () in
  let runtime_ready = match runtime with `Assoc fields -> List.assoc_opt "ready" fields = Some (`Bool true) | _ -> false in
  let result = `Assoc [ ("healthy", `Bool (runtime_ready && (match credential with `Assoc fields -> List.assoc_opt "present" fields = Some (`Bool true) | _ -> false))); ("runtime", runtime); ("credential", credential); ("state", state); ("recoveryEnabled", `Bool (recovery_enabled ())); ("unit", `Assoc [ ("path", `String (C2c_t3_systemd.unit_path ())); ("active", `Bool (C2c_t3_systemd.unit_is_active ())); ("enabled", `Bool (C2c_t3_systemd.unit_is_enabled ())) ]) ] in
  if json then print_json result else begin
    Printf.printf "T3 service doctor\n  runtime: %s\n  credential: %s\n  state: %s\n  recovery: %s\n  unit: %s\n" (if runtime_ready then "ready" else "degraded") (if credential = `Assoc [ ("present", `Bool true) ] then "paired" else "unpaired") (Yojson.Safe.to_string state) (if recovery_enabled () then "enabled" else "disabled") (if C2c_t3_systemd.unit_is_active () then "active" else "inactive")
  end;
  0

let doctor_term = as_command (const doctor_cmd $ json_flag)

let repair_cmd dry_run json =
  let paths = [ config_dir (); state_dir () ] in
  let actions = List.filter (fun path -> not (Sys.file_exists path)) paths in
  let unit_missing = not (Sys.file_exists (C2c_t3_systemd.unit_path ())) in
  let result =
    if dry_run then `Assoc [ ("dryRun", `Bool true); ("wouldCreate", `List (List.map (fun p -> `String p) actions)); ("wouldRepairUnit", `Bool unit_missing); ("credentialPreserved", `Bool true) ]
    else begin
      List.iter mkdir_p actions;
      let unit_result =
        if not unit_missing then "present"
        else
          match C2c_t3_systemd.c2c_path () with
          | Error error -> "held: " ^ error
          | Ok c2c_path ->
              (match C2c_t3_systemd.install ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
               | C2c_t3_systemd.Installed _ -> "repaired"
               | C2c_t3_systemd.Skipped reason -> "held: " ^ reason
               | C2c_t3_systemd.Failed reason -> "held: " ^ reason)
      in
      `Assoc [ ("dryRun", `Bool false); ("created", `List (List.map (fun p -> `String p) actions)); ("unit", `String unit_result); ("credentialPreserved", `Bool true) ]
    end
  in
  if json then print_json result else Printf.printf "%s\n" (Yojson.Safe.to_string result);
  0

let repair_term =
  let dry_run = Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Report safe repairs without changing files.") in
  as_command (const repair_cmd $ dry_run $ json_flag)

let install_cmd dry_run =
  match C2c_t3_systemd.c2c_path () with
  | Error error -> print_error error; 1
  | Ok c2c_path ->
      match C2c_t3_systemd.install ~dry_run ~c2c_path ~t3_home:(t3_home ()) ~config_dir:(config_dir ()) ~state_dir:(state_dir ()) () with
      | C2c_t3_systemd.Installed path -> Printf.printf "%s %s\n" (if dry_run then "would install" else "installed") path; 0
      | Skipped reason -> Printf.eprintf "%s\n%!" reason; 1
      | Failed reason -> print_error reason; 1

let install_term = as_command (const install_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Show the unit path without writing or enabling it."))

let service_stop_cmd dry_run =
  let () =
    if dry_run then Printf.printf "would stop and disable %s\n" C2c_t3_systemd.unit_name
    else
      match C2c_t3_systemd.stop () with
      | C2c_t3_systemd.Systemctl_ok -> Printf.printf "stopped %s\n" C2c_t3_systemd.unit_name
      | C2c_t3_systemd.Systemctl_failed e -> print_error e
  in
  0

let service_uninstall_cmd dry_run = C2c_t3_systemd.uninstall ~dry_run (); Printf.printf "%s %s (state and queued mail retained)\n" (if dry_run then "would remove" else "removed") C2c_t3_systemd.unit_name; 0

let recovery_group =
  Cmdliner.Cmd.group ~default:recovery_status_term
    (Cmdliner.Cmd.info "recovery" ~doc:"Enable or disable durable model-availability Continue recovery.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "enable" ~doc:"Enable recovery for future service sweeps.") (recovery_term true);
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "disable" ~doc:"Hold recovery intents without deleting them.") (recovery_term false);
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show the current durable recovery setting.") recovery_status_term ]

let service_group : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.group ~default:foreground_term
    (Cmdliner.Cmd.info "service" ~doc:"Run and supervise the native connector for one local T3 Code instance.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "install" ~doc:"Install, enable, and start the owned user-systemd unit.") install_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "doctor" ~doc:"Read-only redacted readiness and health report.") doctor_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "repair" ~doc:"Conservatively repair owned directories; credentials and mail are preserved.") repair_term;
      recovery_group;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop and disable the owned user-systemd unit.") (as_command (const service_stop_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Do not call systemctl.")));
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "uninstall" ~doc:"Remove the owned unit while retaining connector state and queued mail.") (as_command (const service_uninstall_cmd $ Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Do not remove the unit."))) ]

let t3_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "t3" ~doc:"Connect c2c to an unmodified local T3 Code service.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "pair" ~doc:"Pair with T3 using its local PKCE pairing flow.") pair_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List open root T3 threads and their stable c2c aliases.") list_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show connector readiness and durable queue status.") status_term;
      Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send an operator-mode message to a local T3 thread.") send_term;
      service_group ]
