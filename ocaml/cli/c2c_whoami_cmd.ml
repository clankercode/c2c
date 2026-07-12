(* c2c_whoami_cmd - identity lookup command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

let whoami_cmd =
  let keys =
    Cmdliner.Arg.(value & flag & info [ "keys"; "K" ]
      ~doc:"Also show the per-alias Ed25519 public key and fingerprint (from <broker-root>/keys/<alias>.ed25519).")
  in
  let check_relay =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "relay" ]
          ~doc:"Also query the relay (best-effort, ~4s) for this alias's lease \
                TTL/expiry. Default is offline-safe — no network round-trip unless \
                this flag is passed.")
  in
  let+ json = json_flag
  and+ keys = keys
  and+ check_relay = check_relay in
  mcp_nudge_if_needed ~cmd:"whoami";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  match env_session_id () with
  | None ->
      Printf.eprintf "error: no session ID could be resolved.\n\
hint: Run 'c2c init' once — it registers this context and persists a fallback identity\n\
      so later c2c commands resolve it automatically (no env vars needed).\n\
      Claude Code: CLAUDE_CODE_SESSION_ID/CLAUDE_SESSION_ID; Codex: CODEX_THREAD_ID /\n\
      'c2c install codex'; Grok: GROK_SESSION_ID (hooks) or GROK_AGENT + active_sessions\n\
      (tool shells) / 'c2c install grok'. Advanced: set C2C_MCP_SESSION_ID.\n%!";
      exit 1
  | Some sid ->
      let regs = C2c_mcp.Broker.list_registrations broker in
      let alias =
        match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs with
        | Some r -> Some r.alias
        | None ->
            (* fall back: resolve by C2C_MCP_AUTO_REGISTER_ALIAS when session_id drifted *)
            (match env_auto_alias () with
             | None -> None
             | Some a ->
                 (match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = a) regs with
                  | Some r -> Some r.alias
                  | None -> None))
      in
      (* Load per-alias Ed25519 key if --keys was requested and alias is known *)
      let identity_data =
        if keys then
          match alias with
          | None -> None
          | Some a ->
              (match C2c_signing_helpers.per_alias_key_path ~alias:a with
               | None -> None
               | Some path ->
                   (match Sys.file_exists path with
                    | false -> None
                    | true ->
                        (match Relay_identity.load ~path () with
                         | Ok id -> Some id
                         | Error _ -> None)))
        else None
      in
      (* B094: relay state (configured URL, relay identity fingerprint, host_id,
         lease TTL/expiry via --relay). Pure-local unless --relay opts into a
         best-effort signed /list round-trip. *)
      let relay_snap = C2c_relay_state.snapshot ~broker () in
      let relay_lease =
        if check_relay then
          Some (C2c_relay_state.fetch_alias_lease
                  ~alias:relay_snap.C2c_relay_state.alias
                  ~relay_url:relay_snap.C2c_relay_state.relay_url
                  ~our_host_id:relay_snap.C2c_relay_state.host_id ())
        else None
      in
      match output_mode with
      | Json ->
          let base = [
            ("session_id", `String sid);
            ("alias", `String (Option.value alias ~default:""));
          ] in
          let with_keys = match identity_data with
            | None -> base
            | Some id ->
                let pk_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key in
                base @ [
                  ("public_key", `String pk_b64);
                  ("fingerprint", `String id.Relay_identity.fingerprint);
                  ("alg", `String id.Relay_identity.alg);
                ]
          in
          let with_relay = with_keys @ [ ("relay", C2c_relay_state.relay_json relay_snap relay_lease) ] in
          print_json (`Assoc with_relay)
      | Human ->
          Printf.printf "alias:     %s\nsession_id: %s\n"
            (Option.value alias ~default:"(not registered)")
            sid;
          (match identity_data with
           | None -> ()
           | Some id ->
               let pk_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key in
               Printf.printf "public_key: %s\nfingerprint: %s\nalg:        %s\n"
                 pk_b64 id.Relay_identity.fingerprint id.Relay_identity.alg);
          Printf.printf "\n";
          C2c_relay_state.print_relay_section relay_snap relay_lease
            ~now:(Unix.gettimeofday ()) ()

let whoami : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "whoami"
      ~doc:"Show current c2c identity (alias, session, and relay state: \
            configured relay URL, host_id, identity fingerprint). Addressing: \
            bare <alias> = local; <alias>@<host_id> = cross-host via relay \
            (use 'c2c relay list' for peer host_ids; 'c2c host-id' for your own). \
            Pass --relay to query the live lease for your alias.")
    whoami_cmd
