(* c2c_hook_cmd - Claude Code hook subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

let min_hook_runtime_ms = 100.0

let sleep_to_min_runtime start_time =
  (* Sleep so total runtime is at least min_hook_runtime_ms. Prevents Node.js
     ECHILD race: fast-exiting hooks are reaped by the kernel before Claude
     Code's waitpid(), which then fails with ECHILD. *)
  let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
  let sleep_s = max 0.0 ((min_hook_runtime_ms -. elapsed_ms) /. 1000.0) in
  if sleep_s > 0.0 then Unix.sleepf sleep_s

let hook_post_tool_cmd =
  (* No arguments - reads env vars C2C_MCP_SESSION_ID and C2C_MCP_BROKER_ROOT *)
  let open Cmdliner.Term in
  const (fun () ->
    let start_time = Unix.gettimeofday () in
    let session_id =
      try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
    in
    let broker_root =
      try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
    in
    if session_id = "" || broker_root = "" then begin
      sleep_to_min_runtime start_time;
      exit 0
    end;
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      (* #387 A2: skip drain for channel-capable sessions so the MCP
         server's watcher can own delivery (avoids the dual-drainer race
         where hook stdout displaces the `<channel>` notification). *)
      let messages =
        if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then begin
          prerr_endline
            (Printf.sprintf
               "[hook] skipping drain — session %s is channel-capable; \
                watcher owns delivery"
               session_id);
          []
        end else
          C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker ~session_id
      in
      (match messages with
       | [] -> ()
       | _ ->
         let buf = Buffer.create 256 in
         let lookup_role from_alias =
           match C2c_mcp.Broker.list_registrations broker
                 |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
           | Some reg -> reg.C2c_mcp.role
           | None     -> None
         in
         List.iter
           (fun (m : C2c_mcp.message) ->
              let tag = C2c_mcp.extract_tag_from_content m.content in
              let role = lookup_role m.from_alias in
               let envelope =
                 C2c_mcp.format_c2c_envelope
                   ~from_alias:m.from_alias
                   ~to_alias:m.to_alias
                   ?tag
                   ?role
                   ?reply_via:m.reply_via
                   ~ts:m.ts
                   ~with_reply_hint:true
                   ~content:m.content
                   ()
               in
              Buffer.add_string buf envelope;
              Buffer.add_char buf '\n')
           messages;
         let json : Yojson.Safe.t =
           `Assoc [
             ("hookSpecificOutput", `Assoc [
               ("hookEventName", `String "PostToolUse");
               ("additionalContext", `String (Buffer.contents buf));
             ])
           ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ());
      sleep_to_min_runtime start_time;
      exit 0
    with e ->
      prerr_endline (Printexc.to_string e);
      sleep_to_min_runtime start_time;
      exit 1) $ const ()

let hook_post_tool : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "post-tool" ~doc:"PostToolUse hook: drain inbox and emit messages.")
    hook_post_tool_cmd

let hook_stop_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (* Uses C2c_hook_lib for shared stdin-parsing + drain logic, matching
       the standalone c2c_stop_hook.exe behaviour exactly. *)
    let session_id =
      match C2c_hook_lib.resolve_session_id () with
      | Ok sid -> sid
      | Error _ -> exit 0
    in
    let broker_root =
      Option.value (C2c_hook_lib.env_nonempty "C2C_MCP_BROKER_ROOT") ~default:""
    in
    if session_id = "" then exit 0;
    try
      let repo_broker, messages, _alias =
        C2c_hook_lib.drain_all_messages ~session_id ~broker_root
      in
      if messages = [] then exit 0;
      let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in
      let json : Yojson.Safe.t =
        `Assoc
          [ ("decision", `String "block")
          ; ("reason", `String messages_text)
          ]
      in
      Printf.printf "%s\n" (Yojson.Safe.to_string json);
      exit 0
    with e ->
      prerr_endline (Printexc.to_string e);
      exit 1) $ const ()

let hook_stop : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "stop" ~doc:"Stop hook: deliver queued messages on text-only turns (blocks stop to inject messages).")
    hook_stop_cmd

(* --- Codex hook (#5, vanilla-codex slice) ------------------------------------

   One command serves every codex hook event: the payload's hook_event_name
   tells us which event fired. Installed by `c2c install codex` for
   UserPromptSubmit + PostToolUse + SessionStart + SessionEnd (see C2c_codex_hooks for the
   event-choice rationale).

   Contract with codex (validated against codex-rs 0.142 schemas):
   - stdin: JSON payload {hook_event_name, session_id, cwd, ...}
   - stdout: either empty (no-op) or
       {"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}
     hookEventName is REQUIRED and must equal the event name (per-event const
     in the output schema, additionalProperties=false).
   - NEVER break the codex turn: any error -> exit 0 with empty stdout.
     Runtime is hard-capped via alarm() well under the configured hook
     timeout. *)

(* Events whose codex output schema supports hookSpecificOutput.additionalContext.
   Stop is absent on purpose: its output supports decision=block only, so
   draining on Stop would eat messages we cannot deliver. *)
let codex_context_events =
  [ "SessionStart"; "SessionEnd"; "UserPromptSubmit"; "PostToolUse"; "PreToolUse" ]

let read_stdin_all ~max_bytes =
  let chunk_size = 8192 in
  let chunk = Bytes.create chunk_size in
  let buf = Buffer.create chunk_size in
  let rec loop remaining =
    if remaining <= 0 then Buffer.contents buf
    else
      match input stdin chunk 0 (min chunk_size remaining) with
      | 0 -> Buffer.contents buf
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          loop (remaining - n)
  in
  try loop max_bytes with _ -> Buffer.contents buf

let payload_string_field payload name =
  match payload with
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
       | _ -> None)
  | _ -> None

let codex_onboarding_text ~alias =
  Printf.sprintf
    "c2c: this codex session is now registered on the local agent-messaging \
     system as `%s`. Peer messages will appear automatically in your context \
     as `<c2c ...>` blocks. Key commands: `c2c whoami` (identity), `c2c list \
     --alive` (peers online), `c2c find <substr>` (peer lookup), `c2c send \
     <alias> \"msg\"` (DM), `c2c wait-inbox --timeout 5m` (blocking receive \
     when idle), `c2c rooms join swarm-lounge` (social room)."
    alias

let codex_wake_text ~alias =
  Printf.sprintf
    "c2c: connected as `%s`. Inbound agent messages arrive automatically via \
     hooks; send with `c2c send <alias> \"msg\"`, block-receive when idle \
     with `c2c wait-inbox`."
    alias

let hook_codex_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    (* Hard runtime cap: exit cleanly well before the configured hook timeout
       (10s) so a wedged broker dir can never stall a codex turn. *)
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       if C2c_hook_lib.is_subagent_quiet () then exit 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None -> exit 0
       in
       if not (List.mem event codex_context_events) then exit 0;
       (* Auto-update the /c2c codex skill from the embedded blob on session
          start, so vanilla codex sessions pick up skill changes from a new
          binary without re-running `c2c install codex`. Best-effort. *)
       if event = "SessionStart" then C2c_setup.refresh_codex_skill_if_stale ();
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let regs () = C2c_mcp.Broker.list_registrations broker in
       let registered sid =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) (regs ())
       in
       let payload_sid =
         match payload_string_field payload "session_id" with
         | Some s ->
             (match C2c_mcp.validate_session_id s with
              | Ok sid -> Some sid
              | Error _ -> None)
         | None -> None
       in
       let config_path =
         match Sys.getenv_opt "HOME" with
         | Some home -> Filename.concat home (Filename.concat ".codex" "config.toml")
         | None -> ""
       in
       let managed_sid_for_payload =
         match payload_sid with
         | Some tid ->
             C2c_mcp_helpers_post_broker.managed_session_id_from_codex_thread
               ~broker_root ~thread_id:tid
         | None -> None
       in
       if event = "SessionEnd" then begin
         let candidates =
           List.filter_map
             (fun x -> x)
             [ payload_sid; managed_sid_for_payload ]
         in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "codex-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (regs ())
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         exit 0
       end;
       (* Identity resolution, most-specific first:
          1. payload session_id has a registration (previous auto-register
             or an exact-id registration) — use it.
          2. payload session_id maps to a managed `c2c start codex` instance
             (codex thread-id file) — use the managed session.
          3. for payload-free fallback events only, ambient env
             (C2C_MCP_SESSION_ID / CODEX_THREAD_ID) or the `c2c init`
             default-session statefile resolves to a registration.
          4. nothing resolved -> auto-register this codex session. The static
             installer alias hint is used only after step 2 proves a managed
             `c2c start codex` owns this payload thread; vanilla codex exec
             sessions get a fresh per-thread alias instead. *)
       let resolved =
         let step1 =
           match payload_sid with
           | Some sid when registered sid -> Some sid
           | _ -> None
         in
         let step2 () =
           match managed_sid_for_payload with
           | Some sid when registered sid -> Some sid
           | None -> None
           | Some _ -> None
         in
          let step3 () =
            match payload_sid with
            | Some _ -> None
            | None ->
                (match C2c_cli_helpers.env_session_id () with
                 | Some sid when registered sid -> Some sid
                 | _ -> None)
          in
         match step1 with
         | Some _ -> step1
         | None ->
             (match step2 () with
              | Some _ as r -> r
              | None ->
                  (match step3 () with
                   | Some _ as r -> r
                   | None -> None))
       in
       let session_id, onboarded_alias =
         match resolved with
         | Some sid -> (sid, None)
         | None ->
             (* Auto-register: zero-setup onboarding for vanilla codex.
                Only when the payload carries a session_id — that id is
                stable for the conversation, so the registration persists
                and every later hook fire resolves via step 1 (no re-register
                loop). Without a payload sid we cannot register a stable
                identity, so stay silent. *)
             (match payload_sid with
              | None -> exit 0
              | Some payload_sid ->
                  (* from_auto_gen: client-prefixed aliases (codex-...) are on
                     the user-supplied blocklist; auto-generated ones bypass it
                     via the flag. Vanilla hooks always generate a fresh
                     payload-thread alias. Managed hooks may reuse the alias
                     `c2c install codex` wrote because the instance config maps
                     the native codex thread back to a stable c2c session id. *)
                  let managed_sid = managed_sid_for_payload in
                  let sid = Option.value managed_sid ~default:payload_sid in
                  let is_managed = Option.is_some managed_sid in
                  let alias, from_auto_gen =
                    if is_managed then
                      match C2c_cli_helpers.env_auto_alias () with
                      | Some a ->
                          ( a
                          , Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN"
                            |> Option.map String.trim = Some "1" )
                      | None ->
                          (match C2c_codex_hooks.installer_alias_hint ~config_path with
                           | Some a -> (a, true)
                           | None -> (C2c_setup.default_alias_for_client "codex", true))
                    else
                      (C2c_setup.default_alias_for_client "codex", true)
                  in
                  let pid =
                    if is_managed then
                      C2c_cli_helpers.resolve_registration_pid ~session_id:sid ()
                    else
                      None
                  in
                  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
                  let registered_by =
                    if is_managed then None else Some "codex-hook"
                  in
                  (try
                     C2c_mcp.Broker.register broker ~session_id:sid ~alias ~pid
                       ~pid_start_time ~client_type:(Some "codex")
                       ~cwd:(payload_string_field payload "cwd")
                       ~registered_by
                       ~from_auto_gen ()
                   with e ->
                     (try
                        prerr_endline
                          ("c2c hook codex: auto-register failed: "
                           ^ Printexc.to_string e)
                      with _ -> ());
                     exit 0);
                  (* Persist the identity for plain `c2c` CLI calls from this
                     codex session (same statefile `c2c init` uses), but never
                     steal a statefile that still points at a live identity. *)
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some existing
                     when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
                   | _ ->
                       C2c_cli_helpers.write_session_statefile ~broker_root
                         ~session_id:sid ~alias ~client:(Some "codex"));
                  (sid, Some alias))
       in
       (* Wake-target capture (codex-wake-inject): the hook runs with the
          codex process's env, so $TMUX/$TMUX_PANE and $HERDR_PANE_ID /
          $HERDR_SOCKET_PATH identify this session's pane for BOTH vanilla
          and managed sessions. Refresh on session boundaries (SessionStart —
          sessions move panes) and on fresh auto-register so the wake
          injector can nudge an idle session. update_wake_targets is
          Some-overwrites / None-preserves and total. *)
       (if event = "SessionStart" || Option.is_some onboarded_alias then begin
          let tmux_location, herdr_pane, herdr_socket =
            C2c_wake_inject.wake_targets_from_env ()
          in
          C2c_mcp.Broker.update_wake_targets broker ~session_id
            ~tmux_location ~herdr_pane ~herdr_socket ()
        end);
       (* Drain. Turn boundaries (SessionStart / UserPromptSubmit) deliver
          everything including deferrable messages; mid-turn events
          (PostToolUse / PreToolUse) deliver only push (non-deferrable)
          messages, respecting sender intent. Ephemeral no-archive semantics
          are handled inside the broker drain. *)
       let full_drain = event = "SessionStart" || event = "UserPromptSubmit" in
       let repo_broker, messages =
         if full_drain then begin
           let repo_messages =
             if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then []
             else C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker ~session_id
           in
           let global_messages =
             try
               let root = C2c_repo_fp.resolve_sessions_broker_root () in
               if C2c_hook_lib.global_inbox_exists ~root ~session_id then
                 let gb = C2c_mcp.Broker.create ~root in
                 C2c_mcp.Broker.drain_inbox ~drained_by:"hook" gb ~session_id
               else []
             with _ -> []
           in
           (Some broker, repo_messages @ global_messages)
         end
         else
           let rb, msgs, _alias =
             C2c_hook_lib.drain_all_messages ~session_id ~broker_root
           in
           (rb, msgs)
       in
       let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in
       let intro =
         match onboarded_alias with
         | Some alias -> codex_onboarding_text ~alias
         | None ->
             if event = "SessionStart" then
               let alias =
                 List.find_map
                   (fun (r : C2c_mcp.registration) ->
                      if r.session_id = session_id then Some r.alias else None)
                   (regs ())
               in
               (match alias with
                | Some a -> codex_wake_text ~alias:a
                | None -> "")
             else ""
       in
       let context =
         match (intro, messages_text) with
         | "", "" -> ""
         | "", m -> m
         | i, "" -> i ^ "\n"
         | i, m -> i ^ "\n\n" ^ m
       in
       if context <> "" then begin
         let json : Yojson.Safe.t =
           `Assoc
             [ ( "hookSpecificOutput"
               , `Assoc
                   [ ("hookEventName", `String event)
                   ; ("additionalContext", `String context)
                   ] )
             ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ()
       end;
       exit 0
     with
     | e ->
         (* Never break the codex turn: swallow everything, exit 0. *)
         (try prerr_endline ("c2c hook codex: " ^ Printexc.to_string e) with _ -> ());
         exit 0)) $ const ()

let hook_codex : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "codex"
       ~doc:"Codex CLI hook: reads the codex hook payload (JSON) on stdin, resolves this session's c2c identity (auto-registering vanilla sessions on first fire), drains the inbox, and emits messages as hookSpecificOutput.additionalContext. Installed into ~/.codex/config.toml by `c2c install codex`. Never fails the codex turn: errors exit 0 with empty output.")
    hook_codex_cmd

(* --- Claude session hook (claude-session-hooks slice) -------------------------

   Mirrors `c2c hook codex`'s structure and safety contract for Claude Code
   session-lifecycle events. Installed by `c2c install claude` for
   SessionStart + SessionEnd (script: ~/.claude/hooks/c2c-session-hook.sh).

   Contract with Claude Code:
   - stdin: JSON payload {hook_event_name, session_id, cwd, ...}; SessionStart
     additionally carries source: startup|resume|clear|compact.
   - stdout: either empty (no-op) or
       {"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"..."}}
   - NEVER break the claude turn: any error -> exit 0 with empty stdout.
     Runtime is hard-capped via alarm() well under the hook timeout.

   Identity resolution is env-FIRST (this differs from codex!): the hook
   process inherits the claude session's env, so a managed session
   (`c2c start claude`) carries C2C_MCP_SESSION_ID=<instance-name> — that
   registration IS the session identity; we must never fork a second
   registration from the payload UUID. *)

(* Events this hook handles. Add future events (e.g. UserPromptSubmit) here;
   the per-event behaviour dispatches on [event] below. *)
let claude_session_events = [ "SessionStart"; "SessionEnd" ]

let claude_onboarding_text ~alias =
  Printf.sprintf
    "c2c: this Claude Code session is now registered on the local \
     agent-messaging system as `%s`. Peer messages are delivered \
     automatically into your context as `<c2c ...>` blocks. Key commands: \
     `c2c whoami` (identity), `c2c list --alive` (peers online), `c2c find \
     <substr>` (peer lookup), `c2c send <alias> \"msg\"` (DM), `c2c \
     wait-inbox --timeout 5m` (blocking receive when idle), `c2c rooms join \
     swarm-lounge` (social room). The /c2c skill has the full reference."
    alias

let claude_wake_text ~alias =
  Printf.sprintf
    "c2c: connected as `%s`. Inbound agent messages arrive automatically via \
     hooks; send with `c2c send <alias> \"msg\"`, block-receive when idle \
     with `c2c wait-inbox`. The /c2c skill has the full reference."
    alias

let hook_claude_cmd =
  let open Cmdliner.Term in
  const (fun () ->
    let start_time = Unix.gettimeofday () in
    (* Fast exits must still hold the min-runtime floor: Claude Code's
       waitpid() hits ECHILD when a hook is reaped too quickly (same race
       sleep_to_min_runtime guards in hook_post_tool_cmd / hook_stop_cmd). *)
    let exit_floored code =
      (try sleep_to_min_runtime start_time with _ -> ());
      exit code
    in
    (* Hard runtime cap: exit cleanly well before the hook timeout so a
       wedged broker dir can never stall a claude session start. *)
    (try
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> exit 0));
       ignore (Unix.alarm 8)
     with _ -> ());
    (try
       (* Subagent guard (B042): spawned Claude subagents inherit the parent
          env and must never be registered or drained. *)
       if C2c_hook_lib.is_subagent_quiet () then exit_floored 0;
       let raw = read_stdin_all ~max_bytes:(1024 * 1024) in
       let payload =
         try Yojson.Safe.from_string (String.trim raw) with _ -> `Null
       in
       let event =
         match payload_string_field payload "hook_event_name" with
         | Some e -> e
         | None -> exit_floored 0
       in
       if not (List.mem event claude_session_events) then exit_floored 0;
       (* Auto-update the /c2c claude skill from the embedded blob on session
          start, so sessions pick up skill changes from a new binary without
          re-running `c2c install claude`. Best-effort, never prints. *)
       if event = "SessionStart" then C2c_setup.refresh_claude_skill_if_stale ();
       let broker_root = C2c_utils.resolve_broker_root () in
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let regs () = C2c_mcp.Broker.list_registrations broker in
       let registered sid =
         List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) (regs ())
       in
       let validated s =
         match C2c_mcp.validate_session_id s with
         | Ok sid -> Some sid
         | Error _ -> None
       in
       let payload_sid =
         Option.bind (payload_string_field payload "session_id") validated
       in
       let env_sid =
         match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
         | Some s when String.trim s <> "" -> validated (String.trim s)
         | _ -> None
       in
       if event = "SessionEnd" then begin
         (* Deregister ONLY hook auto-registrations for this session. Managed
            (`c2c start claude`) and MCP-registered sessions have a different
            registered_by and are never touched. *)
         let candidates = List.filter_map (fun x -> x) [ payload_sid; env_sid ] in
         (match
            List.find_opt
              (fun (r : C2c_mcp.registration) ->
                 r.registered_by = Some "claude-hook"
                 && List.exists (fun sid -> r.session_id = sid) candidates)
              (regs ())
          with
          | Some r -> ignore (C2c_mcp.Broker.deregister broker ~alias:r.alias)
          | None -> ());
         exit_floored 0
       end;
       (* SessionStart identity resolution, env first:
          1. C2C_MCP_SESSION_ID env has a registration (managed session, or
             any session whose env carries an explicit identity) — use it.
          2. payload session_id (claude-native UUID) has a registration
             (previous auto-register) — use it.
          3. payload-free fallback only: the `c2c init` statefile resolves to
             a live registration — use it. Restricted to payload-free fires
             (mirrors codex step 3 / B080): a fresh claude UUID must get a
             fresh identity, not inherit another session's statefile.
          4. nothing -> auto-register the payload session_id, UNLESS
             C2C_MCP_SESSION_ID is set: then the MCP server owns registration
             and auto-registering the payload UUID would fork a duplicate
             identity — stay silent instead. *)
       let resolved =
         match env_sid with
         | Some sid when registered sid -> Some sid
         | _ ->
             (match payload_sid with
              | Some sid when registered sid -> Some sid
              | Some _ -> None
              | None ->
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some sid when registered sid -> Some sid
                   | _ -> None))
       in
       let session_id, onboarded_alias =
         match resolved with
         | Some sid -> (sid, None)
         | None ->
             if Option.is_some env_sid then exit_floored 0;
             (match payload_sid with
              | None -> exit_floored 0
              | Some sid ->
                  (* Auto-register: zero-setup onboarding for vanilla claude.
                     The payload UUID is stable for the conversation, so the
                     registration persists and every later fire resolves via
                     step 2 (no re-register loop). *)
                  let alias = C2c_setup.default_alias_for_client "claude" in
                  (try
                     C2c_mcp.Broker.register broker ~session_id:sid ~alias
                       ~pid:None
                       ~pid_start_time:(C2c_mcp.Broker.capture_pid_start_time None)
                       ~client_type:(Some "claude")
                       ~cwd:(payload_string_field payload "cwd")
                       ~registered_by:(Some "claude-hook")
                       ~from_auto_gen:true ()
                   with e ->
                     (try
                        prerr_endline
                          ("c2c hook claude: auto-register failed: "
                           ^ Printexc.to_string e)
                      with _ -> ());
                     exit_floored 0);
                  (* Persist the identity for plain `c2c` CLI calls from this
                     claude session, but never steal a statefile that still
                     points at a live identity. *)
                  (match C2c_cli_helpers.read_session_statefile ~broker_root with
                   | Some existing
                     when C2c_cli_helpers.statefile_session_registered ~broker_root existing -> ()
                   | _ ->
                       C2c_cli_helpers.write_session_statefile ~broker_root
                         ~session_id:sid ~alias ~client:(Some "claude"));
                  (sid, Some alias))
       in
       let alias_of sid =
         List.find_map
           (fun (r : C2c_mcp.registration) ->
              if r.session_id = sid then Some r.alias else None)
           (regs ())
       in
       (* Part 1: onboarding (fresh auto-register) or wake note (known session). *)
       let intro =
         match onboarded_alias with
         | Some alias -> claude_onboarding_text ~alias
         | None ->
             (match alias_of session_id with
              | Some a -> claude_wake_text ~alias:a
              | None -> "")
       in
       (* Part 2: post-compact context (#317). SessionStart source=compact
          means the transcript was just compacted — re-inject operational
          context via the C2c_post_compact_hook library renderer (shared with
          the standalone c2c-post-compact-hook binary; the block is
          self-bounding at ~4KiB). *)
       let post_compact_context =
         if payload_string_field payload "source" = Some "compact" then
           try
             match C2c_post_compact_hook.repo_root (), alias_of session_id with
             | Some repo, Some alias ->
                 C2c_post_compact_hook.format_context_block
                   (C2c_post_compact_hook.Args.make ~alias ~repo
                      ~ts:(C2c_post_compact_hook.iso8601_now ()))
             | _ -> ""
           with _ -> ""
         else ""
       in
       (* Part 3: cold-boot context (#317). Fires once per session — the
          library keeps a marker at <broker_root>/.cold_boot_done/<sid>, so
          later SessionStarts (resume/compact) and the PostToolUse hook
          naturally no-op. Self-bounding. *)
       let cold_boot_context =
         try
           Option.value
             (C2c_cold_boot_context.context_for_session ~broker_root ~session_id)
             ~default:""
         with _ -> ""
       in
       (* Part 4: message drain (repo + global sessions broker) — full drain
          at the session boundary, EXCEPT the repo drain when the session is
          channel-capable (managed claude uses channel push; dual-drain would
          race the watcher). *)
       let repo_messages =
         if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then []
         else C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker ~session_id
       in
       let global_messages =
         try
           let root = C2c_repo_fp.resolve_sessions_broker_root () in
           if C2c_hook_lib.global_inbox_exists ~root ~session_id then
             let gb = C2c_mcp.Broker.create ~root in
             C2c_mcp.Broker.drain_inbox ~drained_by:"hook" gb ~session_id
           else []
         with _ -> []
       in
       let messages_text =
         C2c_hook_lib.format_messages_as_text ~repo_broker:(Some broker)
           (repo_messages @ global_messages)
       in
       let context =
         [ intro; post_compact_context; cold_boot_context; messages_text ]
         |> List.filter (fun s -> String.trim s <> "")
         |> String.concat "\n\n"
       in
       if context <> "" then begin
         let json : Yojson.Safe.t =
           `Assoc
             [ ( "hookSpecificOutput"
               , `Assoc
                   [ ("hookEventName", `String event)
                   ; ("additionalContext", `String context)
                   ] )
             ]
         in
         print_string (Yojson.Safe.to_string json);
         print_newline ()
       end;
       exit_floored 0
     with
     | e ->
         (* Never break the claude turn: swallow everything, exit 0. *)
         (try prerr_endline ("c2c hook claude: " ^ Printexc.to_string e) with _ -> ());
         exit_floored 0)) $ const ()

let hook_claude : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "claude"
       ~doc:"Claude Code session-lifecycle hook: reads the hook payload (JSON) on stdin, resolves this session's c2c identity env-first (auto-registering vanilla sessions on SessionStart), refreshes the /c2c skill, emits onboarding/wake text + cold-boot / post-compact context + queued messages as hookSpecificOutput.additionalContext, and deregisters hook auto-registrations on SessionEnd. Installed into ~/.claude/settings.json by `c2c install claude`. Never fails the claude turn: errors exit 0 with empty output.")
    hook_claude_cmd

let hook : unit Cmdliner.Cmd.t =
  let info = Cmdliner.Cmd.info "hook"
    ~doc:"Hook subcommands for coding-agent host integration. Use 'post-tool' for Claude PostToolUse (drain inbox), 'stop' for Claude Stop (text-only turn delivery), 'claude' for Claude SessionStart/SessionEnd, and 'codex' for all Codex CLI hook events."
  in
  (* Default to post-tool for backward compat: `c2c hook` (no subcommand) behaves
     as the PostToolUse hook, same as before the hook group refactor. *)
  Cmdliner.Cmd.group ~default:hook_post_tool_cmd info [ hook_post_tool; hook_stop; hook_codex; hook_claude ]
