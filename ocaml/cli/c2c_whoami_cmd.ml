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
      (* #26: when the default-session.json fallback is ambiguous (another
         registration exists), env_session_id fails closed to None rather than
         silently adopting a stale alias — list the broker's registrations as
         candidates so the operator can pick their own session explicitly. *)
      let broker_root = resolve_broker_root () in
      identity_error ~json
        ~reason:"no session ID could be resolved."
        ~candidate:None
        ~steps:
          ([ "c2c init   # registers this context and persists a fallback session when no env is set"
           ; "Claude Code: CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID"
           ; "Codex: CODEX_THREAD_ID / `c2c install codex` / managed `c2c new codex`"
           ; "Grok: GROK_SESSION_ID (hooks) or GROK_AGENT + active_sessions / `c2c install grok`"
           ; "Agy: ANTIGRAVITY_CONVERSATION_ID / `c2c install agy`"
           ; "Cursor Agent (best-effort): CURSOR_AGENT / CURSOR_ASKPASS_SOCKET — run `c2c init` once"
           ; "Advanced: export C2C_MCP_SESSION_ID=<your-session>"
           ; "c2c whoami   # re-check before send"
           ]
           @ candidate_identity_fix_steps ~broker_root)
        ()
  | Some sid ->
      let regs = C2c_mcp.Broker.list_registrations broker in
      let reg_opt =
        List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs
      in
      (* B187: never present AUTO_REGISTER_ALIAS (or empty alias) as success
         when this session is not registered — that was the dogfood path that
         stamped another client's identity onto whoami/send. *)
      let alias, reg_client_type =
        match reg_opt with
        | Some r -> (r.alias, r.client_type)
        | None ->
            (match env_auto_alias () with
             | Some a ->
                 refuse_borrowed_auto_alias ~json ~session_id:sid ~alias:a ()
             | None -> refuse_unregistered_identity ~json ~session_id:sid ())
      in
      assert_identity_client_ok ~json ~alias ~reg_client_type ();
      (* Load per-alias Ed25519 key if --keys was requested and alias is known *)
      let identity_data =
        if keys then
          match C2c_signing_helpers.per_alias_key_path ~alias with
          | None -> None
          | Some path ->
              if not (Sys.file_exists path) then None
              else
                (match Relay_identity.load ~path () with
                 | Ok id -> Some id
                 | Error _ -> None)
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
            ("alias", `String alias);
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
          Printf.printf "alias:     %s\nsession_id: %s\n" alias sid;
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
            Pass --relay to query the live lease for your alias. Refuses \
            borrowed/cross-client identities (B187) instead of presenting them \
            as success.")
    whoami_cmd
