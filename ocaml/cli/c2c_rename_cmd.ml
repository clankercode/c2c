(* c2c_rename_cmd — B140: deliberate atomic alias rename-everywhere.

   The sanctioned counterpart to the B135 sticky-alias forbid: renames the
   current session's alias across every identity store (registry, rooms,
   relay key files, TOFU pins, allowed_signers, instance config, schedules,
   memory) with rollback on partial failure. Implicit renames via
   register/init --alias or env drift remain refused. The heavy lifting is
   [C2c_mcp.Broker.rename_alias] — shared with the MCP `rename` tool. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax

let rename_cmd =
  let new_alias_arg =
    Cmdliner.Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"NEW_ALIAS"
          ~doc:
            "The new alias to adopt. Must be a valid, non-reserved, \
             non-blocklisted name not currently held by an alive peer.")
  in
  let session_id_opt =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "session-id"; "s" ] ~docv:"ID"
          ~doc:
            "Session ID (default: resolved from C2C_MCP_SESSION_ID or the \
             current client session).")
  in
  let broker_root_opt =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "broker-root"; "root" ] ~docv:"DIR"
          ~doc:
            "Broker root dir (default: auto-resolve via env/git). Overrides \
             --cross-repo.")
  in
  let+ json = json_flag
  and+ new_alias = new_alias_arg
  and+ session_id_opt = session_id_opt
  and+ cross_repo = cross_repo_flag
  and+ broker_root_opt = broker_root_opt in
  let broker =
    C2c_mcp.Broker.create
      ~root:
        (resolve_effective_broker_root ~explicit_root:broker_root_opt
           ~cross_repo ())
  in
  let session_id =
    match session_id_opt with
    | Some s -> s
    | None -> (
        match env_session_id () with
        | Some s -> s
        | None ->
            Printf.eprintf
              "error: no session ID specified and no ambient client session \
               ID was found.\n\
               hint: Are you running this from inside the coding agent? Have \
               you run `c2c install <client>` for your client?\n\
               Pass --session-id ID to specify explicitly.\n\
               %!";
            exit 1)
  in
  match C2c_mcp.Broker.rename_alias broker ~session_id ~new_alias with
  | Error msg ->
      (if json then
         print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
       else Printf.eprintf "error: %s\n%!" msg);
      exit 1
  | Ok result_json ->
      if json then print_json result_json
      else begin
        let member name =
          match result_json with
          | `Assoc fields -> List.assoc_opt name fields
          | _ -> None
        in
        let str name =
          match member name with Some (`String s) -> s | _ -> ""
        in
        (match member "noop" with
         | Some (`Bool true) ->
             Printf.printf "already registered as %s — nothing to do\n"
               (str "new_alias")
         | _ ->
             Printf.printf "renamed %s -> %s (session %s)\n" (str "old_alias")
               (str "new_alias") session_id;
             (match member "rooms_renamed" with
              | Some (`List (_ :: _ as rooms)) ->
                  Printf.printf "  rooms updated: %s\n"
                    (String.concat ", "
                       (List.filter_map
                          (function `String s -> Some s | _ -> None)
                          rooms))
              | _ -> ());
             (match member "warnings" with
              | Some (`List (_ :: _ as warnings)) ->
                  List.iter
                    (function
                      | `String w -> Printf.printf "  warning: %s\n" w
                      | _ -> ())
                    warnings
              | _ -> ()));
        Printf.printf "%!"
      end

let rename : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "rename"
       ~doc:
         "Deliberately rename this session's alias everywhere, atomically."
       ~man:
         [ `S "DESCRIPTION"
         ; `P
             "Renames the current session's alias across every identity \
              store: broker registry, room memberships, relay identity key \
              files, TOFU pins, allowed_signers, managed instance config, \
              and the repo-local schedules/memory dirs. Peers see the new \
              alias immediately (no restart needed); each room you are in \
              gets a peer_renamed notice, and an alias_renamed marker is \
              appended to your message archive for durable attribution."
         ; `P
             "Partial failure rolls back — no half-rename ever sticks. The \
              rename is refused when the target alias is held by an alive \
              session, has pending permission state, or carries pinned key \
              material from a previous holder."
         ; `P
             "This is the sanctioned rename path (B140). Implicit renames \
              via $(b,c2c register --alias) / $(b,c2c init --alias) on a \
              live session or C2C_MCP_AUTO_REGISTER_ALIAS drift remain \
              refused (sticky alias, B135)."
         ; `S "EXAMPLES"
         ; `P "$(b,c2c rename amaroo-coord)  — adopt the alias amaroo-coord"
         ; `P "$(b,c2c rename Lyra-Quill)  — case-only self-rename"
         ])
    rename_cmd
