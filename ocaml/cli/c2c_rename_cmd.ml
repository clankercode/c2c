(* c2c_rename_cmd — B140: deliberate atomic alias rename-everywhere.

   The sanctioned counterpart to the B135 sticky-alias forbid: renames the
   current session's alias across every identity store (registry, rooms,
   relay key files, TOFU pins, allowed_signers, instance config, schedules,
   memory) with rollback on partial failure. Implicit renames via
   register/init --alias or env drift remain refused. The heavy lifting is
   [C2c_mcp.Broker.rename_alias] — shared with the MCP `rename` tool.

   B179: after a successful local rename, best-effort rebind of the new
   alias on the configured relay (same identity key as `c2c relay
   register --alias`). Failure is non-fatal for the local rename and is
   surfaced under `relay_rebind` with a copy-pasteable next step. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax

let rename_cmd =
  let reserved_prefixes =
    String.concat ", " C2c_blocklist.reserved_client_prefixes
  in
  let new_alias_arg =
    Cmdliner.Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"NEW_ALIAS"
          ~doc:
            (Printf.sprintf
               "The new alias to adopt. Must be a valid, non-reserved, \
                non-blocklisted name not currently held by an alive peer. \
                Reserved auto-generated-client prefixes: %s. For a \
                Grok-family handoff, use a neutral alias such as gk-<name>. \
                When a relay URL is configured, rename auto-rebinds the new \
                alias (same identity key). If auto-rebind fails, run \
                `c2c relay register --alias=<new>`."
               reserved_prefixes))
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
  | Ok rename_json ->
      (* B179: post-commit relay rebind. Local rename already committed —
         never exit non-zero solely because the relay is down. *)
      let old_alias =
        match rename_json with
        | `Assoc fields ->
            (match List.assoc_opt "old_alias" fields with
             | Some (`String s) -> s
             | _ -> "")
        | _ -> ""
      in
      let is_noop =
        match rename_json with
        | `Assoc fields -> List.assoc_opt "noop" fields = Some (`Bool true)
        | _ -> false
      in
      let rebind_json =
        if is_noop then
          `Assoc
            [ ("status", `String "skipped")
            ; ("reason", `String "noop rename")
            ; ("new_alias", `String new_alias)
            ]
        else
          Relay_rename_rebind.rebind_sync ~old_alias ~new_alias ()
      in
      let result_json =
        Relay_rename_rebind.merge_into_rename_result ~rename_json
          ~rebind_json
      in
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
              | _ -> ());
             (match member "relay_rebind" with
              | Some (`Assoc rb) ->
                  let rb_str k =
                    match List.assoc_opt k rb with
                    | Some (`String s) -> s
                    | _ -> ""
                  in
                  (match List.assoc_opt "status" rb with
                   | Some (`String "ok") ->
                       Printf.printf
                         "  relay: rebound identity for %s on %s \
                          (old alias lease: dual-bind until TTL)\n"
                         (rb_str "new_alias") (rb_str "relay_url")
                   | Some (`String "skipped") ->
                       let reason = rb_str "reason" in
                       if reason <> "" && reason <> "no relay URL configured"
                       then
                         Printf.printf "  relay: rebind skipped (%s)\n" reason
                   | Some (`String "error") ->
                       Printf.printf "  relay: rebind failed: %s\n"
                         (rb_str "error");
                       let next = rb_str "next_step" in
                       if next <> "" then
                         Printf.printf "  next step: %s\n" next
                   | _ -> ())
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
             "Partial failure runs rollback. If an undo cannot complete, the \
              command reports rollback incomplete rather than claiming success. The \
              rename is refused when the target alias is held by an alive \
              session, has pending permission state, or carries pinned key \
              material from a previous holder."
         ; `P
             "This is the sanctioned rename path (B140). Implicit renames \
              via $(b,c2c register --alias) / $(b,c2c init --alias) on a \
              live session or C2C_MCP_AUTO_REGISTER_ALIAS drift remain \
              refused (sticky alias, B135)."
         ; `P
             "When a relay URL is configured ($(b,C2C_RELAY_URL) / \
              $(b,c2c relay setup)), rename automatically re-registers the \
              new alias on the relay with the same Ed25519 identity (B179). \
              The prior alias lease remains until TTL expiry (dual-bind \
              window). If auto-rebind fails, the local rename still \
              succeeds and the output prints a copy-pasteable \
              $(b,c2c relay register --alias=<new>) next step."
         ; `S "EXAMPLES"
         ; `P "$(b,c2c rename amaroo-coord)  — adopt the alias amaroo-coord"
         ; `P "$(b,c2c rename Lyra-Quill)  — case-only self-rename"
         ])
    rename_cmd
