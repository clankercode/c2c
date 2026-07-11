(* c2c_register_cmd - broker registration command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

let register_cmd =
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to register (default: C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let session_id_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID" ~doc:"Session ID (default: resolved from C2C_MCP_SESSION_ID or the current client session).")
  in
  let no_metadata =
    Cmdliner.Arg.(value & flag & info [ "no-metadata" ] ~doc:"Opt out of metadata exposure/federation (cwd, canonical alias). Does NOT affect cwd capture, which is required for the worktree-mismatch guard.")
  in
  let broker_root_opt =
    Cmdliner.Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git). Overrides --cross-repo.")
  in
  let+ json = json_flag
  and+ alias_opt = alias
  and+ session_id_opt = session_id_opt
  and+ no_metadata = no_metadata
  and+ cross_repo = cross_repo_flag
  and+ broker_root_opt = broker_root_opt in
  let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~explicit_root:broker_root_opt ~cross_repo ()) in
  let alias, alias_from_auto_gen =
    match alias_opt with
    | Some a -> (a, false)
    | None -> (
        match env_auto_alias () with
        | Some a ->
            let from_auto_gen =
              match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" with
              | Some v -> String.trim v = "1"
              | None -> false
            in
            (a, from_auto_gen)
        | None ->
            Printf.eprintf
              "error: no alias specified and C2C_MCP_AUTO_REGISTER_ALIAS not set.\n\
               hint: Are you running this from inside the coding agent? Have you run `c2c install <client>` for your client?\n\
               Pass --alias ALIAS to register explicitly.\n%!";
            exit 1)
  in
  let session_id =
    match session_id_opt with
    | Some s -> s
    | None -> (
        match env_session_id () with
        | Some s -> s
        | None ->
            Printf.eprintf
              "error: no session ID specified and no ambient client session ID was found.\n\
               hint: Are you running this from inside the coding agent? Have you run `c2c install <client>` for your client?\n\
               Pass --session-id ID to specify explicitly.\n%!";
            exit 1)
  in
  (* B135: alias is sticky per session_id — refuse rename via --alias OR
     C2C_MCP_AUTO_REGISTER_ALIAS when it differs from the live registration.
     (Env-only renames were the half-rename path that left peers on the old
     name; check the resolved alias, not only the --alias flag.) *)
  (match
     C2c_mcp.Broker.sticky_alias_conflict broker ~session_id
       ~requested_alias:alias
   with
   | Some existing_alias ->
       let msg =
         C2c_mcp.Broker.sticky_alias_error ~session_id ~existing_alias
           ~requested_alias:alias
       in
       (if json then
          print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
        else
          Printf.eprintf "error: %s\n%!" msg);
       exit 1
   | None -> ());
  (* B071: C2C_MCP_CLIENT_PID env (managed launchers set it to the durable
     outer-loop pid) → stable agent-ancestor pid from /proc → None (unknown
     liveness, routable). Never getppid(): from an agent-harness shell that
     is a transient per-command shell, making the registration born-dead. *)
  let pid = resolve_registration_pid ~session_id () in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  (try
     C2c_mcp.Broker.register broker ~session_id ~alias ~pid ~pid_start_time
       ~client_type:(env_client_type ()) ~cwd:(Some (Sys.getcwd ()))
       ~metadata_opt_out:no_metadata ~from_auto_gen:alias_from_auto_gen ()
   with Invalid_argument msg ->
     (if json then
        print_json (`Assoc [("ok", `Bool false); ("error", `String msg)])
      else
        Printf.eprintf "error: %s\n%!" msg);
     exit 1);
  (match C2c_mcp.Broker.write_allowed_signers_entry broker ~alias with
   | Ok () -> ()
   | Error e -> Printf.eprintf "[allowed_signers] warning: %s\n%!" e);
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ("alias", `String alias)
          ; ("session_id", `String session_id)
          ])
  | Human ->
      Printf.printf "registered %s (session %s)\n" alias session_id

let deregister_cmd =
  let alias_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS" ~doc:"Alias to deregister.")
  in
  let broker_root_opt =
    Cmdliner.Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git). Overrides --cross-repo.")
  in
  let+ json = json_flag
  and+ alias = alias_arg
  and+ cross_repo = cross_repo_flag
  and+ broker_root_opt = broker_root_opt in
  let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~explicit_root:broker_root_opt ~cross_repo ()) in
  match C2c_mcp.Broker.deregister broker ~alias with
  | None ->
      Printf.eprintf "error: no registration found for alias '%s'\n%!" alias;
      exit 1
  | Some reg ->
      if json then
        print_json
          (`Assoc
            [ ("alias", `String reg.alias)
            ; ("session_id", `String reg.session_id)
            ; ("deregistered", `Bool true)
            ])
      else
        Printf.printf "deregistered %s (session %s)\n" reg.alias reg.session_id

let register : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "register" ~doc:"Register an alias for the current session.")
    register_cmd

let deregister : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "deregister" ~doc:"Remove a registration from the broker.")
    deregister_cmd
