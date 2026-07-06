(* c2c_refresh_peer_cmd - stale registration repair command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

let refresh_peer_run json target pid_opt session_id_opt dry_run =
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let start_time = match pid_opt with
    | Some pid ->
        if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then begin
          (match output_mode with
           | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "PID %d is not alive" pid)) ])
           | Human -> Printf.eprintf "error: PID %d is not alive. Refusing to update.\n%!" pid);
          exit 1
        end;
        C2c_mcp.Broker.read_pid_start_time pid
    | None -> None
  in
  let session_change_fields old_session_id =
    match session_id_opt with
    | Some sid when sid <> old_session_id ->
        [ ("old_session_id", `String old_session_id)
        ; ("new_session_id", `String sid)
        ]
    | _ -> []
  in
  let session_change_note old_session_id =
    match session_id_opt with
    | Some sid when sid <> old_session_id ->
        Printf.sprintf ", session_id %S -> %S" old_session_id sid
    | _ -> ""
  in
  C2c_mcp.Broker.with_registry_lock broker (fun () ->
    let regs = C2c_mcp.Broker.list_registrations broker in
    let match_result =
      match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = target) regs with
      | Some r -> Some ("alias", r)
      | None ->
          (match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = target) regs with
           | Some r -> Some ("session_id", r)
           | None ->
               (match session_id_opt with
                | Some sid ->
                    Option.map
                      (fun r -> ("session_id", r))
                      (List.find_opt
                         (fun (r : C2c_mcp.registration) -> r.session_id = sid)
                         regs)
                | None -> None))
    in
    let matched_by, matched_reg = match match_result with
      | Some pair -> pair
      | None ->
          (match output_mode with
           | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "No registration found for '%s'" target)) ])
           | Human -> Printf.eprintf "error: No registration found for '%s'.\n%!" target);
          exit 1
    in
    let old_pid = matched_reg.pid in
    if pid_opt = None then begin
      if C2c_mcp.Broker.registration_is_alive matched_reg then
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("alias", `String matched_reg.alias); ("matched_by", `String matched_by)
            ; ("status", `String "already_alive")
            ; ("pid", match old_pid with None -> `Null | Some p -> `Int p) ])
        | Human ->
            Printf.printf "Registration for '%s' is already alive (pid=%s). No change needed.\n"
              matched_reg.alias (match old_pid with None -> "None" | Some p -> string_of_int p)
      else begin
        (match output_mode with
         | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String "Dead PID. Provide --pid.") ])
         | Human -> Printf.eprintf "error: Dead PID. Provide --pid <live-pid> to refresh.\n%!");
        exit 1
      end
    end else begin
      let new_pid = match pid_opt with Some pid -> pid | None -> assert false in
      let new_regs = List.map (fun (r : C2c_mcp.registration) ->
        if r.session_id = matched_reg.session_id then
          { r with
            pid = pid_opt;
            pid_start_time = start_time;
            session_id = Option.value session_id_opt ~default:r.session_id
          }
        else r
      ) regs in
      let session_fields = session_change_fields matched_reg.session_id in
      if dry_run then
        match output_mode with
        | Json -> print_json (`Assoc
            ([ ("alias", `String matched_reg.alias); ("matched_by", `String matched_by)
             ; ("status", `String "dry_run")
             ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
             ; ("new_pid", `Int new_pid)
             ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ]
             @ session_fields))
        | Human ->
            Printf.printf "[dry-run] Would update '%s': pid %s -> %d%s\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              new_pid
              (session_change_note matched_reg.session_id)
      else begin
        C2c_mcp.Broker.save_registrations broker new_regs;
        match output_mode with
        | Json -> print_json (`Assoc
            ([ ("ok", `Bool true); ("alias", `String matched_reg.alias)
             ; ("matched_by", `String matched_by); ("status", `String "updated")
             ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
             ; ("new_pid", `Int new_pid)
             ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ]
             @ session_fields))
        | Human ->
            Printf.printf "Updated '%s': pid %s -> %d%s\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              new_pid
              (session_change_note matched_reg.session_id)
      end
    end)

let refresh_peer_cmd =
  let target =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS_OR_SESSION_ID" ~doc:"Alias or session ID of the peer to refresh.")
  in
  let pid_opt =
    Cmdliner.Arg.(value & opt (some int) None & info [ "pid" ] ~docv:"PID" ~doc:"New live PID to point the registration at.")
  in
  let session_id_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID" ~doc:"Correct session_id to write (fixes drift).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run" ] ~doc:"Show what would change without writing.")
  in
  let+ json = json_flag
  and+ target = target
  and+ pid_opt = pid_opt
  and+ session_id_opt = session_id_opt
  and+ dry_run = dry_run in
  refresh_peer_run json target pid_opt session_id_opt dry_run

let refresh_peer : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "refresh-peer" ~doc:"Refresh a stale broker registration to a new live PID.")
    refresh_peer_cmd
