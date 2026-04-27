(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

(* Debug output — gated by C2C_MCP_DEBUG env var *)
let debug_enabled =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let ( // ) = Filename.concat
open Cmdliner.Term.Syntax
open C2c_mcp
module Relay = Relay
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent

(* Resolve the Claude config dir.
   Prefers CLAUDE_CONFIG_DIR if set, otherwise resolves ~/.claude as a symlink
   (so profile dirs like ~/.claude-mm/ work via the symlink). *)
let resolve_claude_dir () =
  match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let dot_claude = Filename.concat (Sys.getenv "HOME") ".claude" in
      (try
         let rec resolve_link p max_depth =
           if max_depth <= 0 then p
           else
             let stat = Unix.lstat p in
             if stat.Unix.st_kind = Unix.S_LNK then
               let target = Unix.readlink p in
               let resolved = if Filename.is_relative target then
                                Filename.concat (Filename.dirname p) target
                              else target in
               resolve_link resolved (max_depth - 1)
             else p
         in
         resolve_link dot_claude 10
       with _ -> dot_claude)

(* --- broker root resolution (delegated to C2c_utils) ---------------------- *)

let resolve_broker_root = C2c_utils.resolve_broker_root

let broker_root_from_env () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> Some path
  | _ -> None

let git_repo_toplevel () =
  match Git_helpers.git_repo_toplevel () with
  | Some line when Sys.is_directory line -> Some line
  | _ -> None

let git_shorthash () =
  match Git_helpers.git_shorthash () with
  | Some line when int_of_string_opt line = None -> Some line
  | _ -> None

let version_string () =
  let base = Version.version in
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  let ts = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec in
  match git_shorthash () with
  | Some h -> Printf.sprintf "%s %s %s" base h ts
  | None -> Printf.sprintf "%s %s" base ts

let find_python_script script =
  match git_repo_toplevel () with
  | Some dir ->
      let path = dir // script in
      if Sys.file_exists path then Some path else None
  | None -> None

(* --- session / alias resolution ------------------------------------------- *)

let env_session_id () =
  match C2c_mcp.session_id_from_env () with
  | Some s ->
      if debug_enabled then Printf.eprintf "[DEBUG env_session_id] returning Some=%s\n%!" s;
      Some s
  | None ->
      if debug_enabled then Printf.eprintf "[DEBUG env_session_id] returning None\n%!";
      None

let env_auto_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let env_client_type () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
  | Some v when String.trim v <> "" -> Some (String.trim v)
  | _ -> None

let resolve_alias ?(override : string option = None) broker =
  match override with
  | Some a when String.trim a <> "" ->
      let r = String.trim a in
      if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] override=%s\n%!" r;
      r
  | _ ->
      (* Prefer C2C_MCP_SESSION_ID lookup over C2C_MCP_AUTO_REGISTER_ALIAS.
         C2C_MCP_SESSION_ID identifies the actual registered session; using it
         to look up the registered alias handles the case where the caller
         (e.g. a container with C2C_MCP_AUTO_REGISTER_ALIAS=peer-b-{ts})
         is not the actual sender alias. *)
      match env_session_id () with
      | Some sid ->
          let regs = C2c_mcp.Broker.list_registrations broker in
          (match
             List.find_opt
               (fun (r : C2c_mcp.registration) -> r.session_id = sid)
               regs
           with
          | Some r ->
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_sid=%s -> alias=%s\n%!" sid r.alias;
              r.alias
          | None -> (
              (* Session not registered; fall back to env_auto_alias for
                 non-MCP callers or dynamically-registered sessions. *)
              match env_auto_alias () with
              | Some a ->
                  if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] sid=%s not registered, fallback=%s\n%!" sid a;
                  a
              | None ->
                  Printf.eprintf "error: session %s is not registered and no alias is set.\n%!" sid;
                  exit 1))
      | None -> (
          match env_auto_alias () with
          | Some a ->
              if debug_enabled then Printf.eprintf "[DEBUG resolve_alias] from_env_auto_alias=%s\n%!" a;
              a
          | None ->
              Printf.eprintf "error: cannot determine your alias. Set C2C_MCP_AUTO_REGISTER_ALIAS or C2C_MCP_SESSION_ID.\n%!";
              exit 1)

let resolve_session_id () =
  match env_session_id () with
  | Some sid -> sid
  | None ->
      Printf.eprintf
        "error: cannot determine session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n%!";
      exit 1

(* Like resolve_session_id but falls back to alias-based lookup when the
   session_id in the env doesn't match any registration. This handles the case
   where C2C_MCP_SESSION_ID was set by the harness to one value (e.g. "planner1")
   but the actual broker registration used a different session_id (e.g. "opencode-c2c")
   because the MCP server registered under a different identifier. *)
let resolve_session_id_for_inbox broker =
  let sid = resolve_session_id () in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let has_direct = List.exists (fun (r : C2c_mcp.registration) -> r.session_id = sid) regs in
  if debug_enabled then Printf.eprintf "[DEBUG resolve_sid_for_inbox] sid=%s has_direct=%b regs_count=%d\n%!"
    sid has_direct (List.length regs);
  if has_direct then sid
  else begin
    (* Fall back: look for a registration whose alias matches C2C_MCP_AUTO_REGISTER_ALIAS *)
    match env_auto_alias () with
    | None -> sid (* no fallback available, use original sid *)
    | Some alias ->
        (match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = alias) regs with
         | None -> sid
         | Some r ->
             Printf.eprintf
               "info: C2C_MCP_SESSION_ID=%s not in registry; using session_id=%s (alias=%s)\n%!"
               sid r.session_id alias;
             r.session_id)
  end

(* --- output helpers -------------------------------------------------------- *)

let json_flag =
  Cmdliner.Arg.(value & flag & info [ "json"; "j" ] ~doc:"Output machine-readable JSON.")

let print_json json =
  Yojson.Safe.pretty_to_channel stdout json;
  print_newline ()

let current_c2c_command () =
  let fallback =
    if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c"
  in
  let resolved =
    try Unix.readlink "/proc/self/exe"
    with Unix.Unix_error _ -> fallback
  in
  if Filename.is_relative resolved then Sys.getcwd () // resolved else resolved

(* --- MCP nudge: steer agents toward MCP tools when available ---------------- *)

(** Print a one-line nudge to stderr when the agent could use an MCP tool
    instead of the CLI. Fires only when:
    - MCP session env vars are present (C2C_MCP_SESSION_ID, C2C_MCP_AUTO_REGISTER_ALIAS)
    - C2C_CLI_FORCE is not set
    Does not affect command exit code — always returns unit. *)
let mcp_nudge_if_needed ~cmd =
  if Sys.getenv_opt "C2C_CLI_FORCE" = Some "1" then ()
  else
    let env_has_value var =
      match Sys.getenv_opt var with
      | Some s when String.trim s <> "" -> true
      | _ -> false
    in
    if env_has_value "C2C_MCP_SESSION_ID" && env_has_value "C2C_MCP_AUTO_REGISTER_ALIAS" then
      let tool_name =
        match cmd with
        | "send"      -> "mcp__c2c__send"
        | "poll-inbox"| "peek-inbox" -> "mcp__c2c__poll_inbox"
        | "list"      -> "mcp__c2c__list"
        | "whoami"    -> "mcp__c2c__whoami"
        | _ -> ""
      in
      if tool_name <> "" then
        Printf.eprintf
          "hint: MCP is available — consider using %s instead of `c2c %s`\n\
           (suppress with C2C_CLI_FORCE=1)\n%!"
          tool_name cmd

(* --- subcommand: commands (audit by safety tier) --------------------------- *)

let commands_by_safety_cmd =
  let show_all =
    Cmdliner.Arg.(value & flag & info [ "all" ] ~doc:"Include tier-4 internal commands.")
  in
  let+ show_all = show_all in
  let tier1 = [
    ("list", "List registered c2c peers");
    ("whoami", "Show current c2c identity");
    ("poll-inbox", "Drain (or peek at) your inbox");
    ("peek-inbox", "Peek at your inbox without draining");
    ("send", "Send a message to a registered peer alias");
    ("send-all", "Broadcast a message to all peers");
    ("rooms", "Manage persistent N:N rooms (list/join/leave/send/history/tail/invite/members/visibility)");
    ("my-rooms", "List rooms you are a member of");
    ("history", "Show archived inbox messages");
    ("dead-letter", "Show dead-letter entries");
    ("tail-log", "Show recent broker RPC log entries");
    ("health", "Show broker health diagnostics");
    ("status", "Show compact swarm overview");
    ("verify", "Verify c2c message exchange progress");
    ("prune-rooms", "Evict dead members from all rooms");
    ("instances", "List managed c2c instances");
    ("doctor", "Health snapshot + push-pending analysis");
    ("stats", "Show per-agent message statistics across the swarm");
    ("set-compact", "Mark this session as compacting");
    ("clear-compact", "Clear the compacting flag");
    ("open-pending-reply", "Open a pending permission reply slot");
    ("check-pending-reply", "Check if a permission reply is valid");
  ] in
  let tier2 = [
    ("start", "Start a managed c2c instance");
    ("stop", "Stop a managed c2c instance");
    ("restart", "Restart a managed c2c instance");
    ("reset-thread", "Restart a managed codex or codex-headless instance onto a specific thread");
    ("register", "Register an alias for the current session");
    ("rooms send", "Send a message to a room");
    ("rooms invite", "Invite an alias to a room");
    ("rooms visibility", "Get or set room visibility");
    ("agent list", "List all canonical role files");
    ("agent new", "Create a new canonical role file");
    ("agent delete", "Delete a canonical role file");
    ("agent rename", "Rename a canonical role file");
    ("agent run", "Launch an ephemeral one-shot agent from a role");
    ("agent refine", "Interactively refine an existing role file");
    ("roles compile", "Compile canonical role(s) to client agent files");
    ("roles validate", "Validate canonical role files for completeness");
    ("config show", "Show current c2c config values");
    ("config generation-client", "Show generation-client config");
    ("wire-daemon list", "List all wire-daemon state files");
    ("wire-daemon status", "Show status of a wire-daemon");
    ("get-tmux-location", "Print the current tmux pane address (session:window.pane)");
  ] in
  let tier3 = [
    ("relay serve", "Start relay server (background, requires operator)");
    ("relay gc", "Run relay garbage collection");
    ("relay setup", "Configure relay connection");
    ("relay connect", "Run the relay connector");
    ("relay register", "Register Ed25519 identity on relay");
    ("relay dm", "Send/receive cross-host direct messages");
    ("relay status", "Show relay health");
    ("relay rooms", "Manage relay rooms");
    ("relay list", "List relay peers");
    ("setcap", "Grant PTY injection capability (requires sudo)");
    ("inject", "Inject messages or keycodes into a live session (deprecated)");
    ("smoke-test", "Run an end-to-end broker smoke test");
    ("diag", "Show diagnostic info for a managed instance");
    ("gui", "Launch the c2c TUI");
    ("install", "Install c2c + client integrations");
    ("init", "Generate a new Ed25519 identity keypair");
    ("hook", "PostToolUse hook: drain inbox and emit messages");
    ("wire-daemon start", "Start a wire-daemon for a session");
    ("wire-daemon stop", "Stop a running wire-daemon");
  ] in
  let tier4 = [
    ("serve", "Run the MCP server (JSON-RPC over stdio)");
    ("mcp", "Alias for serve");
    ("oc-plugin stream-write-statefile", "[internal] Stream statefile writes");
    ("oc-plugin drain-inbox-to-spool", "[internal] Drain inbox to spool");
    ("cc-plugin write-statefile", "[internal] Write Claude Code statefile");
    ("wire-daemon format-prompt", "[diagnostic] Format broker messages as Wire prompt text");
    ("wire-daemon spool-write", "[diagnostic] Write messages to a spool file");
    ("wire-daemon spool-read", "[diagnostic] Read messages from a spool file");
    ("statefile", "Read/write broker statefile");
    ("supervisor", "Supervisor subcommands");
    ("refresh-peer", "Refresh a stale broker registration");
    ("repo", "Per-repo config management");
  ] in
  let print_section title cmds =
    Printf.printf "\n== %s ==\n\n" title;
    List.iter (fun (name, desc) -> Printf.printf "  %-30s %s\n" name desc) cmds
  in
  Printf.printf "c2c commands by safety tier\n";
  print_section (safety_to_label Tier1) tier1;
  print_section (safety_to_label Tier2) tier2;
  if not (is_agent_session ()) then print_section (safety_to_label Tier3) tier3;
  if show_all then print_section (safety_to_label Tier4) tier4

let commands_by_safety =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "commands"
       ~doc:"List all c2c commands grouped by safety tier."
       ~man:[ `P "Useful for auditing which commands are safe to run inside an agent session." ])
    commands_by_safety_cmd

(* --- subcommand: send ----------------------------------------------------- *)

let send_cmd =
  let to_alias =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS" ~doc:"Recipient alias.")
  in
  let message =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"MSG" ~doc:"Message body (remaining args joined with spaces).")
  in
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Send messages as this alias. The alias must already be registered with the broker; use $(b,c2c register --alias ALIAS) first. Useful for operators or tests running outside an agent session.")
  in
  let no_warn_substitution =
    Cmdliner.Arg.(value & flag & info [ "no-warn-substitution" ]
      ~doc:"Suppress the shell-substitution warning.")
  in
  let ephemeral_flag =
    Cmdliner.Arg.(value & flag & info [ "ephemeral" ]
      ~doc:"Mark the message as ephemeral. Local 1:1 only: the recipient's broker delivers normally but skips the archive append, so post-delivery the only persistent trace is the recipient's transcript / channel notification (per-session-local, gets compacted). For remote recipients ($(b,alias@host)), the relay outbox path persists by design and this flag is silently ignored on the relay side in v1; cross-host ephemeral is a follow-up. Receipt confirmation is impossible by design.")
  in
  let+ json = json_flag
  and+ to_alias = to_alias
  and+ message = message
  and+ from_override = from_override
  and+ no_warn_substitution = no_warn_substitution
  and+ ephemeral = ephemeral_flag in
  mcp_nudge_if_needed ~cmd:"send";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
  let content = String.concat " " message in
  (* Class E: warn when message body looks like an un-expanded shell
     substitution pattern that the shell failed to expand. *)
  let _ =
    if (not no_warn_substitution) && likes_shell_substitution content
    then Printf.eprintf
      "warning: message body appears to contain a shell substitution pattern \
       (e.g. $(...) or `...`).\n\
       If this was intended literally, re-send with --no-warn-substitution.\n\
       To avoid this, quote the pattern: '$(date)' or escape the $.\n%!"
    else ()
  in
  let output_mode = if json then Json else Human in
  if from_alias = to_alias then (
    Printf.eprintf "error: cannot send a message to yourself (%s)\n%!" from_alias;
    exit 1
  );
  (try
     if debug_enabled then Printf.eprintf "[DEBUG send_cmd] calling enqueue_message from=%s to=%s\n%!" from_alias to_alias;
     flush stderr;
     C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content ~ephemeral ();
     if debug_enabled then Printf.eprintf "[DEBUG send_cmd] enqueue_message returned\n%!";
     flush stderr;
     let ts = Unix.gettimeofday () in
     let compacting_warning =
       let regs = C2c_mcp.Broker.list_registrations broker in
       match List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = to_alias) regs with
       | Some r ->
           (match C2c_mcp.Broker.is_compacting broker ~session_id:r.session_id with
            | Some c ->
                let dur = Unix.gettimeofday () -. c.started_at in
                let reason_str = match c.reason with Some r -> " (" ^ r ^ ")" | None -> "" in
                Some (Printf.sprintf "recipient compacting for %.0fs%s" dur reason_str)
            | None -> None)
       | None -> None
     in
     match output_mode with
     | Json ->
         let fields =
           [ ("queued", `Bool true)
           ; ("ts", `Float ts)
           ; ("from_alias", `String from_alias)
           ; ("to_alias", `String to_alias)
           ]
         in
         let fields = match compacting_warning with Some w -> fields @ [("compacting_warning", `String w)] | None -> fields in
         print_json (`Assoc fields)
     | Human ->
         Printf.printf "ok -> %s (from %s)" to_alias from_alias;
         (match compacting_warning with Some w -> Printf.printf " [%s]" w | None -> ());
         print_newline ()
   with Invalid_argument msg ->
     (* If the target looks like a room name, give a helpful redirect hint. *)
     let is_room =
       (try
          let rooms = C2c_mcp.Broker.list_rooms broker in
          List.exists (fun r -> r.C2c_mcp.Broker.ri_room_id = to_alias) rooms
        with _ -> false)
     in
     if is_room then begin
       Printf.eprintf "error: '%s' is a room, not a peer alias.\n" to_alias;
       Printf.eprintf "hint:  use `c2c room send %s <message>` to send to a room.\n%!" to_alias
     end else
       Printf.eprintf "error: %s\n%!" msg;
     exit 1)

(* --- subcommand: list ----------------------------------------------------- *)

let list_cmd =
  let all =
    Cmdliner.Arg.(value & flag & info [ "all"; "a" ] ~doc:"Show extended info (session ID, registered time).")
  in
  let+ json = json_flag
  and+ all = all in
  mcp_nudge_if_needed ~cmd:"list";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let output_mode = if json then Json else Human in
  if regs = [] then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "No registered peers.\n")
  else
    match output_mode with
    | Json ->
        let json_regs =
          List.map
            (fun (r : C2c_mcp.registration) ->
              let base : (string * Yojson.Safe.t) list =
                [ ("session_id", `String r.session_id)
                ; ("alias", `String r.alias)
                ]
              in
              let with_pid =
                match r.pid with
                | Some n -> base @ [ ("pid", `Int n) ]
                | None -> base
              in
              let alive_val : Yojson.Safe.t =
                match C2c_mcp.Broker.registration_liveness_state r with
                | C2c_mcp.Broker.Alive -> `Bool true
                | C2c_mcp.Broker.Dead -> `Bool false
                | C2c_mcp.Broker.Unknown -> `Null
              in
              let with_alive = with_pid @ [ ("alive", alive_val) ] in
              let fields =
                match r.registered_at with
                | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                | None -> with_alive
              in
              let fields =
                match r.compacting with
                | Some c ->
                    let reason_json = match c.reason with Some r -> `String r | None -> `Null in
                    fields @ [ ("compacting", `Assoc [ ("started_at", `Float c.started_at); ("reason", reason_json) ]) ]
                | None -> fields
              in
              `Assoc fields)
            regs
        in
        print_json (`List json_regs)
    | Human ->
        List.iter
          (fun (r : C2c_mcp.registration) ->
            let alive_str =
              match C2c_mcp.Broker.registration_liveness_state r with
              | C2c_mcp.Broker.Alive -> "alive"
              | C2c_mcp.Broker.Dead -> "dead "
              | C2c_mcp.Broker.Unknown -> "??? (unknown client_type)"
            in
            let pid_str =
              match r.pid with
              | Some p -> Printf.sprintf " pid=%d" p
              | None -> ""
            in
            if all then
              let session_short =
                let s = r.session_id in
                if String.length s > 12 then String.sub s 0 12 ^ "..." else s
              in
              let time_str =
                match r.registered_at with
                | None -> ""
                | Some ts ->
                    let t = Unix.gmtime ts in
                    Printf.sprintf " %04d-%02d-%02d %02d:%02d"
                      (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
              in
              Printf.printf "  %-20s %s%s  %s%s\n" r.alias alive_str pid_str session_short time_str
            else
              Printf.printf "  %-20s %s%s\n" r.alias alive_str pid_str)
          regs

(* --- subcommand: whoami --------------------------------------------------- *)

let whoami_cmd =
  let+ json = json_flag in
  mcp_nudge_if_needed ~cmd:"whoami";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let output_mode = if json then Json else Human in
  match env_session_id () with
  | None ->
      Printf.eprintf "error: no session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n\
hint: Run 'c2c init' to register and get started, or pass --session-id explicitly.\n%!";
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
      match output_mode with
      | Json ->
          print_json
            (`Assoc
              [ ("session_id", `String sid)
              ; ("alias", `String (Option.value alias ~default:""))
              ])
      | Human ->
          Printf.printf "alias:     %s\nsession_id: %s\n"
            (Option.value alias ~default:"(not registered)")
            sid

(* --- subcommand: set-compact --------------------------------------------- *)

let set_compact_cmd =
  let reason =
    Cmdliner.Arg.(value & opt (some string) None & info [ "reason"; "r" ]
      ~docv:"REASON" ~doc:"Human-readable reason for compaction (e.g. context-limit-near).")
  in
  let+ json = json_flag
  and+ reason_opt = reason in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  match env_session_id () with
  | None ->
      Printf.eprintf "error: no session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n\
hint: Run 'c2c init' to register and get started, or pass --session-id explicitly.\n%!";
      exit 1
  | Some sid ->
      let result = C2c_mcp.Broker.set_compacting broker ~session_id:sid ?reason:reason_opt () in
      match result with
      | None ->
          if json then print_json (`Assoc [("ok", `Bool false); ("error", `String "session not registered")])
          else Printf.eprintf "error: session not registered\n%!";
          exit 1
      | Some c ->
          if json then
            print_json (`Assoc [("ok", `Bool true); ("started_at", `Float c.started_at)])
          else
            Printf.printf "compacting set (started_at=%.0f%s)\n"
              c.started_at
              (match c.reason with Some r -> ", reason=" ^ r | None -> "")

(* --- subcommand: clear-compact -------------------------------------------- *)

let clear_compact_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  match env_session_id () with
  | None ->
      Printf.eprintf "error: no session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n\
hint: Run 'c2c init' to register and get started, or pass --session-id explicitly.\n%!";
      exit 1
  | Some sid ->
      let ok = C2c_mcp.Broker.clear_compacting broker ~session_id:sid in
      if json then print_json (`Assoc [("ok", `Bool ok)])
      else if ok then Printf.printf "compacting cleared\n%!"
      else Printf.eprintf "error: session not registered or no compacting flag to clear\n%!";
      if not ok then exit 1

(* --- subcommand: open-pending-reply --------------------------------------- *)
(* Called by plugin before sending a permission/question request to supervisors. *)

let open_pending_reply_cmd =
  let perm_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PERM_ID"
      ~doc:"Unique permission request ID.")
  in
  let kind =
    Cmdliner.Arg.(value & opt (some string) None & info [ "kind"; "k" ]
      ~docv:"KIND" ~doc:"Kind: 'permission' or 'question' (default: permission).")
  in
  let supervisors =
    Cmdliner.Arg.(value & opt (some string) None & info [ "supervisors"; "s" ]
      ~docv:"SUPERVISORS" ~doc:"Comma-separated list of supervisor aliases.")
  in
  let+ json = json_flag
  and+ perm_id = perm_id
  and+ kind = kind
  and+ supervisors = supervisors in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id =
    match env_session_id () with
    | Some s -> s
    | None ->
        Printf.eprintf "error: no session ID. Set C2C_MCP_SESSION_ID or run from a supported client session.\n\
hint: Run 'c2c init' to register and get started, or pass --session-id explicitly.\n%!";
        exit 1
  in
  let alias =
    match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = session_id)
            (C2c_mcp.Broker.list_registrations broker) with
    | Some reg -> reg.alias
    | None ->
        Printf.eprintf "error: session not registered.\n%!";
        exit 1
  in
  let kind_val = match kind with
    | Some "question" -> C2c_mcp.Question
    | _ -> C2c_mcp.Permission
  in
  let supervisors_list = match supervisors with
    | Some s ->
        String.split_on_char ',' s
        |> List.map String.trim
        |> List.filter (fun x -> x <> "")
    | None -> []
  in
  let ttl_seconds =
    match Sys.getenv_opt "C2C_PERMISSION_TTL" with
    | Some v ->
        (try float_of_string (String.trim v) with _ -> 600.0)
    | None -> 600.0
  in
  let now = Unix.gettimeofday () in
  let pending : C2c_mcp.pending_permission =
    { perm_id; kind = kind_val; requester_session_id = session_id
    ; requester_alias = alias; supervisors = supervisors_list
    ; created_at = now; expires_at = now +. ttl_seconds }
  in
  C2c_mcp.Broker.open_pending_permission broker pending;
  if json then
    print_json (`Assoc [
      ("ok", `Bool true);
      ("perm_id", `String perm_id);
      ("kind", `String (C2c_mcp.pending_kind_to_string kind_val));
      ("ttl_seconds", `Float ttl_seconds);
      ("expires_at", `Float pending.expires_at)
    ])
  else
    Printf.printf "pending reply opened: perm_id=%s kind=%s ttl=%.0fs\n"
      perm_id (C2c_mcp.pending_kind_to_string kind_val) ttl_seconds

(* --- subcommand: check-pending-reply ------------------------------------- *)
(* Called by plugin when receiving a reply from a supervisor. *)

let check_pending_reply_cmd =
  let perm_id =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PERM_ID"
      ~doc:"Unique permission request ID.")
  in
  let reply_from =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"REPLY_FROM"
      ~doc:"Alias the reply is from.")
  in
  let+ json = json_flag
  and+ perm_id = perm_id
  and+ reply_from = reply_from in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  match C2c_mcp.Broker.find_pending_permission broker perm_id with
  | None ->
      if json then
        print_json (`Assoc [
          ("valid", `Bool false);
          ("requester_session_id", `Null);
          ("error", `String "unknown permission ID")
        ])
      else
        Printf.eprintf "error: unknown permission ID\n%!";
      exit 1
  | Some pending ->
      if List.mem reply_from pending.supervisors then
        if json then
          print_json (`Assoc [
            ("valid", `Bool true);
            ("requester_session_id", `String pending.requester_session_id);
            ("error", `Null)
          ])
        else
          Printf.printf "valid: reply from %s is authorized for perm_id=%s\n"
            reply_from perm_id
      else
        if json then
          print_json (`Assoc [
            ("valid", `Bool false);
            ("requester_session_id", `Null);
            ("error", `String ("reply from non-supervisor: " ^ reply_from))
          ])
        else
          Printf.eprintf "error: reply from non-supervisor: %s\n%!" reply_from

(* --- subcommand: poll-inbox ----------------------------------------------- *)

let poll_inbox_cmd =
  let peek =
    Cmdliner.Arg.(value & flag & info [ "peek"; "p" ] ~doc:"Peek without draining.")
  in
  let session_id_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID"
      ~doc:"Session ID whose inbox to drain. Overrides C2C_MCP_SESSION_ID.")
  in
  let+ json = json_flag
  and+ peek = peek
  and+ session_id_opt = session_id_flag in
  mcp_nudge_if_needed ~cmd:"poll-inbox";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = match session_id_opt with
    | Some sid -> sid
    | None -> resolve_session_id_for_inbox broker
  in
  let messages =
    if peek then
      C2c_mcp.Broker.read_inbox broker ~session_id
    else
      C2c_mcp.Broker.drain_inbox broker ~session_id
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (m : C2c_mcp.message) ->
               `Assoc
                 [ ("from_alias", `String m.from_alias)
                 ; ("to_alias", `String m.to_alias)
                 ; ("content", `String m.content)
                 ; ("ts", `Float m.ts)
                 ])
             messages))
  | Human ->
      if messages = [] then
        Printf.printf "(no messages)\n"
      else
        List.iter
          (fun (m : C2c_mcp.message) -> Printf.printf "[%s] %s\n" m.from_alias m.content)
          messages

(* --- subcommand: send-all ------------------------------------------------- *)

let send_all_cmd =
  let message =
    Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"MSG" ~doc:"Message body.")
  in
  let exclude =
    Cmdliner.Arg.(value & opt (list string) [] & info [ "exclude"; "x" ] ~docv:"ALIAS" ~doc:"Aliases to skip.")
  in
  let from_override =
    Cmdliner.Arg.(value & opt (some string) None & info [ "from"; "F" ] ~docv:"ALIAS" ~doc:"Override sender alias. Useful for operators/tests running outside an agent session.")
  in
  let+ json = json_flag
  and+ exclude = exclude
  and+ message = message
  and+ from_override = from_override in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
  let content = String.concat " " message in
  let result =
    C2c_mcp.Broker.send_all broker ~from_alias ~content ~exclude_aliases:exclude
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ( "sent_to",
              `List (List.map (fun a -> `String a) result.sent_to) )
          ; ( "skipped",
              `List
                (List.map
                   (fun (a, r) ->
                     `Assoc [ ("alias", `String a); ("reason", `String r) ])
                   result.skipped) )
          ])
  | Human ->
      Printf.printf "Sent to: %s\n"
        (match result.sent_to with [] -> "(none)" | l -> String.concat ", " l);
      if result.skipped <> [] then
        List.iter
          (fun (a, r) -> Printf.printf "  skipped %s (%s)\n" a r)
          result.skipped

(* --- subcommand: sweep ---------------------------------------------------- *)

let instances_dir_base =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")

(** Read session_ids of all c2c start managed sessions.
    These sessions should be excluded from sweep (they're recoverable via
    operator re-running the printed resume command). *)
let c2c_start_session_ids () =
  let base = instances_dir_base in
  if not (Sys.file_exists base) then []
  else
    Array.fold_left (fun acc name ->
      let full = base // name in
      if Sys.is_directory full && Sys.file_exists (full // "config.json") then
        (try
          match Yojson.Safe.from_file (full // "config.json") with
          | `Assoc fields ->
              (match List.assoc_opt "session_id" fields with
               | Some (`String sid) -> sid :: acc
               | _ -> acc)
          | _ -> acc
        with _ -> acc)
      else acc)
      [] (Sys.readdir base)

let sweep_cmd =
  let+ json = json_flag in
  let outer_loops_running =
    Sys.command "pgrep -c -f 'run-(kimi|codex|opencode|crush|claude)-inst-outer' > /dev/null 2>&1" = 0
  in
  if outer_loops_running then begin
    Printf.eprintf "warning: managed client outer loops detected. Sweep may drop live sessions.\n";
    Printf.eprintf "  Use 'c2c instances' or 'c2c list' to check before proceeding.\n%!";
  let c2c_start_count = List.length (c2c_start_session_ids ()) in
  if c2c_start_count > 0 then begin
    Printf.eprintf "info: %d c2c start managed session(s) excluded from sweep (recoverable).\n" c2c_start_count;
  end
  end;
  let c2c_start_sids = c2c_start_session_ids () in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let result = C2c_mcp.Broker.sweep broker in
  let dropped_regs, deleted_inboxes =
    List.filter (fun (r : C2c_mcp.registration) -> not (List.mem r.session_id c2c_start_sids)) result.dropped_regs,
    List.filter (fun sid -> not (List.mem sid c2c_start_sids)) result.deleted_inboxes
  in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
          [ ( "dropped_regs",
              `List
                (List.map
                   (fun (r : C2c_mcp.registration) ->
                     `Assoc
                       [ ("session_id", `String r.session_id)
                       ; ("alias", `String r.alias)
                       ])
                   dropped_regs) )
          ; ( "deleted_inboxes",
              `List (List.map (fun s -> `String s) deleted_inboxes) )
          ; ("preserved_messages", `Int result.preserved_messages)
          ])
  | Human ->
      Printf.printf "Dropped %d registrations, %d inboxes, %d messages preserved.\n"
        (List.length dropped_regs)
        (List.length deleted_inboxes)
        result.preserved_messages;
      List.iter
        (fun (r : C2c_mcp.registration) -> Printf.printf "  dropped: %s (%s)\n" r.alias r.session_id)
        dropped_regs

(* --- subcommand: sweep-dryrun --------------------------------------------- *)

let sweep_dryrun_run json =
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let reg_by_sid = Hashtbl.create 16 in
  let alias_rows = Hashtbl.create 16 in
  let live_regs = ref [] in
  let dead_regs = ref [] in
  let legacy_regs = ref [] in
  List.iter (fun (r : C2c_mcp.registration) ->
    Hashtbl.replace reg_by_sid r.session_id r;
    let rows = try Hashtbl.find alias_rows r.alias with Not_found -> [] in
    Hashtbl.replace alias_rows r.alias (r :: rows);
    match C2c_mcp.Broker.registration_liveness_state r with
    | C2c_mcp.Broker.Alive -> live_regs := r :: !live_regs
    | C2c_mcp.Broker.Dead -> dead_regs := r :: !dead_regs
    | C2c_mcp.Broker.Unknown -> legacy_regs := r :: !legacy_regs
  ) regs;
  let inbox_count sid =
    try
      let msgs = C2c_mcp.Broker.read_inbox broker ~session_id:sid in
      Some (List.length msgs)
    with _ -> None
  in
  let orphan_inboxes = ref [] in
  let inbox_file_count = ref 0 in
  (try
     let files = Sys.readdir root in
     Array.iter (fun fname ->
       if Filename.check_suffix fname ".inbox.json" then begin
         incr inbox_file_count;
         let sid = String.sub fname 0 (String.length fname - String.length ".inbox.json") in
         if not (Hashtbl.mem reg_by_sid sid) then
           orphan_inboxes := (sid, inbox_count sid) :: !orphan_inboxes
       end
     ) files
   with Sys_error _ -> ());
  let duplicate_aliases = Hashtbl.fold (fun alias rows acc ->
    if List.length rows > 1 then
      (alias, List.map (fun (r : C2c_mcp.registration) -> r.session_id) rows) :: acc
    else acc
  ) alias_rows [] in
  let pid_map = Hashtbl.create 8 in
  List.iter (fun (r : C2c_mcp.registration) ->
    match r.pid with
    | Some pid ->
        let rows = try Hashtbl.find pid_map pid with Not_found -> [] in
        Hashtbl.replace pid_map pid (r :: rows)
    | None -> ()
  ) regs;
  let duplicate_pids = Hashtbl.fold (fun pid rows acc ->
    if List.length rows >= 2 then
      let aliases = List.map (fun (r : C2c_mcp.registration) -> r.alias) rows in
      (pid, aliases) :: acc
    else acc
  ) pid_map [] in
  let nonempty_dead = List.filter_map (fun (r : C2c_mcp.registration) ->
    match inbox_count r.session_id with
    | Some n when n > 0 -> Some (r.session_id, r.alias, n)
    | _ -> None
  ) !dead_regs in
  let nonempty_orphans = List.filter_map (fun (sid, count) ->
    match count with
    | Some n when n > 0 -> Some (sid, n)
    | _ -> None
  ) !orphan_inboxes in
  let risk = List.length nonempty_dead + List.length nonempty_orphans in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let json_reg (r : C2c_mcp.registration) =
        `Assoc
          [ ("session_id", `String r.session_id)
          ; ("alias", `String r.alias)
          ; ("pid", match r.pid with None -> `Null | Some p -> `Int p)
          ; ("inbox_messages", match inbox_count r.session_id with None -> `Null | Some n -> `Int n)
          ]
      in
      print_json (`Assoc
        [ ("root", `String root)
        ; ("totals", `Assoc
            [ ("registrations", `Int (List.length regs))
            ; ("live", `Int (List.length !live_regs))
            ; ("legacy_pidless", `Int (List.length !legacy_regs))
            ; ("dead", `Int (List.length !dead_regs))
            ; ("inbox_files_on_disk", `Int !inbox_file_count)
            ; ("orphan_inboxes", `Int (List.length !orphan_inboxes))
            ; ("would_drop_if_swept", `Int (List.length !dead_regs + List.length !orphan_inboxes))
            ; ("nonempty_content_at_risk", `Int risk)
            ])
        ; ("live_regs", `List (List.map json_reg !live_regs))
        ; ("legacy_pidless_regs", `List (List.map json_reg !legacy_regs))
        ; ("dead_regs", `List (List.map json_reg !dead_regs))
        ; ("orphan_inboxes", `List (List.map (fun (sid, count) ->
              `Assoc [ ("session_id", `String sid); ("messages", match count with None -> `Null | Some n -> `Int n) ]
            ) !orphan_inboxes))
        ; ("duplicate_aliases", `Assoc (List.map (fun (alias, sids) ->
              (alias, `List (List.map (fun s -> `String s) sids))
            ) duplicate_aliases))
        ; ("duplicate_pids", `List (List.map (fun (pid, aliases) ->
              `Assoc [ ("pid", `Int pid); ("aliases", `List (List.map (fun a -> `String a) aliases)) ]
            ) duplicate_pids))
        ])
  | Human ->
      Printf.printf "broker root: %s\n\n" root;
      Printf.printf "totals:\n";
      Printf.printf "  registrations          %d\n" (List.length regs);
      Printf.printf "    live                 %d\n" (List.length !live_regs);
      Printf.printf "    legacy (pid=None)    %d\n" (List.length !legacy_regs);
      Printf.printf "    dead                 %d\n" (List.length !dead_regs);
      Printf.printf "  inbox files on disk    %d\n" !inbox_file_count;
      Printf.printf "  orphan inboxes         %d\n" (List.length !orphan_inboxes);
      Printf.printf "  would drop if swept    %d\n" (List.length !dead_regs + List.length !orphan_inboxes);
      if risk > 0 then
        Printf.printf "  NON-EMPTY content risk %d\n" risk;
      if duplicate_aliases <> [] then begin
        Printf.printf "\nduplicate aliases (routing black-hole risk):\n";
        List.iter (fun (alias, sids) ->
          Printf.printf "  %s: %s\n" alias (String.concat ", " sids)
        ) duplicate_aliases
      end;
      if duplicate_pids <> [] then begin
        Printf.printf "\nduplicate PIDs (likely ghost registrations):\n";
        List.iter (fun (pid, aliases) ->
          Printf.printf "  pid=%d: %s\n" pid (String.concat ", " aliases)
        ) duplicate_pids
      end;
      if !dead_regs <> [] then begin
        Printf.printf "\ndead registrations (would be dropped):\n";
        List.iter (fun (r : C2c_mcp.registration) ->
          let suffix = match inbox_count r.session_id with
            | Some n when n > 0 -> Printf.sprintf "  [%d pending msgs]" n
            | _ -> ""
          in
          Printf.printf "  %-20s %s  pid=%s%s\n" r.alias r.session_id
            (match r.pid with None -> "None" | Some p -> string_of_int p)
            suffix
        ) !dead_regs
      end;
      if nonempty_dead <> [] || nonempty_orphans <> [] then begin
        Printf.printf "\nNON-EMPTY content that sweep would delete:\n";
        List.iter (fun (sid, alias, n) ->
          Printf.printf "  %s (%s)  (%d msgs)\n" sid alias n
        ) nonempty_dead;
        List.iter (fun (sid, n) ->
          Printf.printf "  %s  (%d msgs)\n" sid n
        ) nonempty_orphans;
        Printf.printf "  -> consider draining these before running sweep.\n"
      end

let sweep_dryrun_cmd =
  let+ json = json_flag in
  sweep_dryrun_run json

let sweep_dryrun =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "sweep-dryrun" ~doc:"Read-only preview of what sweep would drop (safe during active swarm).")
    sweep_dryrun_cmd

(** Compute the legacy broker root: <git-common-dir>/c2c/mcp.
    This is what resolve_broker_root used before the #294 per-repo fingerprint change. *)
let legacy_broker_root () =
  match Git_helpers.git_common_dir () with
  | Some git_dir ->
      (try
         if (Unix.stat git_dir).Unix.st_kind = Unix.S_DIR then
           let abs_git = if Filename.is_relative git_dir then Sys.getcwd () // git_dir else git_dir in
           abs_git // "c2c" // "mcp"
         else ""
       with _ -> "")
  | None -> ""

let migrate_broker_run ~from_path ~to_path ~dry_run ~json =
  let mkdir_p dir =
    let rec loop d =
      if d = "/" || d = "." || d = "" then ()
      else if Sys.file_exists d then ()
      else begin
        loop (Filename.dirname d);
        try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      end
    in
    loop dir
  in
  let copy_file src dst =
    if dry_run then Printf.printf "[DRY-RUN] would copy: %s -> %s\n" src dst
    else begin
      mkdir_p (Filename.dirname dst);
      try
        let buf_size = 65536 in
        let buf = Bytes.create buf_size in
        let src_ic = open_in src in
        Fun.protect ~finally:(fun () -> close_in src_ic) @@ fun () ->
        let dst_oc = open_out dst in
        Fun.protect ~finally:(fun () -> close_out dst_oc) @@ fun () ->
        let rec loop () =
          let n = input src_ic buf 0 buf_size in
          if n = 0 then () else begin
            output dst_oc buf 0 n;
            loop ()
          end
        in
        loop ()
      with e ->
        if json then print_json (`Assoc [ "ok", `Bool false; "error", `String (Printexc.to_string e) ])
        else Printf.eprintf "error copying %s: %s\n" src (Printexc.to_string e)
    end
  in
  let rec copy_dir src dst acc =
    if not (Sys.file_exists src) then acc
    else
      try
        mkdir_p dst;
        let entries = Array.to_list (Sys.readdir src) |> List.filter (fun f -> not (f = "." || f = "..")) in
        List.fold_right (fun f acc' ->
          let s = src // f in
          let d = dst // f in
          if Sys.is_directory s then
            copy_dir s d acc'  (* recurse into subdirectory *)
          else begin
            copy_file s d;
            d :: acc'
          end
        ) entries acc
      with _ -> acc
  in
  let from = Option.value from_path ~default:(legacy_broker_root ()) in
  let to_ = Option.value to_path ~default:(resolve_broker_root ()) in
  if not (Sys.file_exists from) then begin
    if json then print_json (`Assoc ["ok", `Bool false; "error", `String ("source broker does not exist: " ^ from)])
    else Printf.eprintf "error: source broker does not exist: %s\n" from;
    exit 1
  end;
  if from = to_ then begin
    if json then print_json (`Assoc ["ok", `Bool false; "error", `String "from and to paths are the same"])
    else Printf.eprintf "error: from and to paths are the same\n";
    exit 1
  end;
  if not json then begin
    Printf.printf "Migrating broker data:\n";
    Printf.printf "  from: %s\n" from;
    Printf.printf "  to:   %s\n" to_;
    if dry_run then Printf.printf "  mode: DRY RUN (no files will be written)\n"
    else Printf.printf "  mode: LIVE (files will be written)\n"
  end;
  (* Copy individual files *)
  List.iter (fun f ->
    let src = from // f in
    if Sys.file_exists src then copy_file src (to_ // f)
  ) ["registry.json"; "registry.json.lock"; "deaths.jsonl"];
  (* Copy subdirs: inboxes, memory, archive *)
  let _ = copy_dir (from // "inbox.json.d") (to_ // "inbox.json.d") [] in
  let _ = copy_dir (from // "memory") (to_ // "memory") [] in
  let _ = copy_dir (from // "archive") (to_ // "archive") [] in
  if not dry_run then begin
    mkdir_p to_;
    (* Verify by checking for key files at destination *)
    let verified = Sys.file_exists (to_ // "registry.json") in
    if json then
      if verified then print_json (`Assoc ["ok", `Bool true; "from", `String from; "to", `String to_; "dry_run", `Bool false])
      else print_json (`Assoc ["ok", `Bool false; "error", `String "migration completed but registry.json not found at destination"; "from", `String from; "to", `String to_])
    else
      if verified then Printf.printf "\nMigration complete. Verify: ls %s\n" to_
      else Printf.eprintf "\nMigration completed but registry.json not found at destination.\n"
  end else begin
    if json then print_json (`Assoc ["ok", `Bool true; "from", `String from; "to", `String to_; "dry_run", `Bool dry_run])
    else Printf.printf "\nDRY RUN complete. Run without --dry-run to execute.\n"
  end

let migrate_broker_cmd =
  let open Cmdliner in
  let from =
    Arg.(value & opt (some string) None & info ["from"; "f"]
           ~docv:"PATH"
           ~doc:"Source broker root (default: the legacy .git/c2c/mcp path)")
  in
  let to_ =
    Arg.(value & opt (some string) None & info ["to"; "t"]
           ~docv:"PATH"
           ~doc:"Destination broker root (default: your HOME/.c2c/repos/<fp>/broker)")
  in
  let dry_run = Arg.(value & flag & info ["dry-run"; "n"] ~doc:"Show what would be copied without writing.") in
  let json = json_flag in
  let+ from_path = from
  and+ to_path = to_
  and+ dry_run = dry_run
  and+ json = json in
  migrate_broker_run ~from_path ~to_path ~dry_run ~json

let migrate_broker =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "migrate-broker"
       ~doc:"Migrate broker data from the legacy .git/c2c/mcp path to the new per-repo path. Use --dry-run first.")
    migrate_broker_cmd

(* --- subcommand: history -------------------------------------------------- *)

let history_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max messages to return.")
  in
  let session_id_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID"
      ~doc:"Session ID to read archive for. Overrides C2C_MCP_SESSION_ID.")
  in
  let+ json = json_flag
  and+ limit = limit
  and+ session_id_opt = session_id_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = match session_id_opt with
    | Some sid -> sid
    | None -> resolve_session_id_for_inbox broker
  in
  let entries = C2c_mcp.Broker.read_archive broker ~session_id ~limit in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (e : C2c_mcp.Broker.archive_entry) ->
               `Assoc
                 [ ("drained_at", `Float e.ae_drained_at)
                 ; ("from_alias", `String e.ae_from_alias)
                 ; ("to_alias", `String e.ae_to_alias)
                 ; ("content", `String e.ae_content)
                 ])
             entries))
  | Human ->
      if entries = [] then
        Printf.printf "(no history)\n"
      else
        List.iter
          (fun (e : C2c_mcp.Broker.archive_entry) ->
            let time =
              let t = Unix.gmtime e.ae_drained_at in
              Printf.sprintf "%04d-%02d-%02d %02d:%02d"
                (1900 + t.tm_year) (1 + t.tm_mon) t.tm_mday t.tm_hour t.tm_min
            in
            Printf.printf "[%s] <%s> %s\n" time e.ae_from_alias e.ae_content)
          entries

(* --- subcommand: health --------------------------------------------------- *)

let check_supervisor_config () =
  let env_sup =
    match Sys.getenv_opt "C2C_PERMISSION_SUPERVISOR" with
    | Some v when String.trim v <> "" -> Some v
    | _ -> (match Sys.getenv_opt "C2C_SUPERVISORS" with Some v when String.trim v <> "" -> Some v | _ -> None)
  in
  match env_sup with
  | Some v -> (`Green, Printf.sprintf "supervisor: %s (from env)" v)
  | None ->
      let sidecar = Filename.concat (Sys.getcwd ()) ".opencode/c2c-plugin.json" in
      let sidecar_sup =
        if Sys.file_exists sidecar then
          try
            let ic = open_in sidecar in
            let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let n = in_channel_length ic in really_input_string ic n) in
            let j = Yojson.Safe.from_string data in
            let sup = Yojson.Safe.Util.(j |> member "supervisors") in
            let single = Yojson.Safe.Util.(j |> member "supervisor") in
            (match sup, single with
             | `List items, _ ->
                 let names = List.filter_map (function `String s -> Some s | _ -> None) items in
                 if names <> [] then Some (String.concat ", " names) else None
             | _, `String s when s <> "" -> Some s
             | _ -> None)
          with _ -> None
        else None
      in
      let repo_sup =
        let repo_cfg_path = Filename.concat (Sys.getcwd ()) ".c2c/repo.json" in
        if Sys.file_exists repo_cfg_path then
          try
            let ic = open_in repo_cfg_path in
            let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let n = in_channel_length ic in really_input_string ic n) in
            let j = Yojson.Safe.from_string data in
            let sup = Yojson.Safe.Util.(j |> member "supervisors") in
            (match sup with
             | `List items ->
                 let names = List.filter_map (function `String s -> Some s | _ -> None) items in
                 if names <> [] then Some (String.concat ", " names) else None
             | _ -> None)
          with _ -> None
        else None
      in
      (match sidecar_sup, repo_sup with
       | Some v, _ -> (`Green, Printf.sprintf "supervisor: %s (from sidecar)" v)
       | _, Some v -> (`Green, Printf.sprintf "supervisor: %s (from .c2c/repo.json)" v)
       | None, None -> (`Yellow, "supervisor: coordinator1 (default — run: c2c init --supervisor <alias> or c2c repo set supervisor <alias>)"))

let check_relay_http () =
  let url = match Sys.getenv_opt "C2C_RELAY_URL" with Some v when v <> "" -> v | _ -> "https://relay.c2c.im" in
  try
    let client = Relay.Relay_client.make ~timeout:5.0 url in
    let result = Lwt_main.run (Relay.Relay_client.health client) in
    let version = Yojson.Safe.Util.(result |> member "version" |> to_string_option |> Option.value ~default:"?") in
    let git_hash = Yojson.Safe.Util.(result |> member "git_hash" |> to_string_option |> Option.value ~default:"?") in
    let auth_mode = Yojson.Safe.Util.(result |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown") in
    let ok = Yojson.Safe.Util.(result |> member "ok") = `Bool true in
    if ok then
      let auth_str = match auth_mode with
        | "dev" -> " ⚠ dev mode (no auth)"
        | "prod" -> " prod mode"
        | _ -> ""  (* field absent in older relay versions — suppress *)
      in
      let local_hash = Option.value (git_shorthash ()) ~default:"?" in
      let stale_warn =
        if git_hash <> "?" && local_hash <> "?" && git_hash <> local_hash then begin
          let commits_ahead =
            let cmd = Printf.sprintf "git rev-list --count %s..HEAD 2>/dev/null" git_hash in
            match Unix.open_process_in cmd with
            | ic ->
                let n = try String.trim (input_line ic) with End_of_file -> "" in
                ignore (Unix.close_process_in ic);
                (match int_of_string_opt n with Some k when k > 0 ->
                   Printf.sprintf " (%d commit%s — run 'c2c doctor' for classification)" k (if k=1 then "" else "s")
                 | _ -> "")
            | exception _ -> ""
          in
          Printf.sprintf " ⚠ relay behind local (deployed: %s, local: %s)%s" git_hash local_hash commits_ahead
        end else ""
      in
      let color = if stale_warn <> "" then `Yellow else `Green in
      (color, Printf.sprintf "relay: reachable — %s @ %s%s%s (%s)" version git_hash auth_str stale_warn url)
    else (`Red, Printf.sprintf "relay: error response from %s" url)
  with exn ->
    (`Red, Printf.sprintf "relay: unreachable (%s)" (Printexc.to_string exn))

let check_plugin_installs () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let results = ref [] in
  let add r = results := r :: !results in

  (* Claude Code: PostToolUse hook in ~/.claude/settings.json *)
  let settings_path = home // ".claude" // "settings.json" in
  (if Sys.file_exists settings_path then
     try
       let ic = open_in settings_path in
       let data = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
         let n = in_channel_length ic in really_input_string ic n) in
       let j = Yojson.Safe.from_string data in
       let hooks_str = Yojson.Safe.to_string Yojson.Safe.Util.(j |> member "hooks") in
       if String.length hooks_str > 2 && (let needle = "c2c" in
         let nl = String.length needle and ll = String.length hooks_str in
         let found = ref false in
         for i = 0 to ll - nl do
           if String.sub hooks_str i nl = needle then found := true
         done; !found)
       then add (`Green, "claude-code: PostToolUse hook configured")
       else add (`Yellow, "claude-code: no c2c hook (run: c2c install claude)")
     with _ -> add (`Gray, "claude-code: could not read settings.json")
   else add (`Gray, "claude-code: settings.json not found"));

  (* OpenCode: project-level or global plugin *)
  let project_plugin = (Sys.getcwd ()) // ".opencode" // "plugins" // "c2c.ts" in
  let global_plugin = home // ".config" // "opencode" // "plugins" // "c2c.ts" in
  let global_size = try (Unix.stat global_plugin).Unix.st_size with Unix.Unix_error _ -> 0 in
  (if Sys.file_exists project_plugin then
     add (`Green, "opencode: plugin installed (project-level)")
   else if Sys.file_exists global_plugin && global_size >= 1024 then
     add (`Green, "opencode: plugin installed (global)")
   else if Sys.file_exists global_plugin then
     add (`Yellow, Printf.sprintf "opencode: global plugin is a stub (%d bytes) — run: c2c install opencode from c2c repo" global_size)
   else
     add (`Yellow, "opencode: plugin not installed (run: c2c install opencode)"));

  (* GUI: check if webkit2gtk-4.1 is available (required to build/run Tauri GUI) *)
  let webkit_available =
    (* Try pkg-config first; fall back to checking for the library file directly *)
    Sys.command "pkg-config --exists webkit2gtk-4.1 2>/dev/null" = 0
    || (match Sys.command "ldconfig -p 2>/dev/null | grep -q webkit2gtk-4.1" with
       | 0 -> true | _ -> false)
  in
  (if webkit_available then
     add (`Green, "gui: webkit2gtk-4.1 available (can build/run Tauri GUI)")
   else
     add (`Yellow, "gui: webkit2gtk-4.1 missing — install: sudo pacman -S webkit2gtk-4.1"));

  List.rev !results

(* Scan for running deprecated PTY-based wake daemons.
   Returns a list of (script_name, pids, fix_hint) for any that are running. *)
let check_deprecated_daemons () :
    (string * int list * string) list =
  let patterns =
    [ ( "c2c_claude_wake_daemon.py"
      , "deprecated: use /loop 4m in Claude Code instead" )
    ; ( "c2c_opencode_wake_daemon.py"
      , "deprecated: TypeScript plugin handles delivery; kill this daemon" )
    ; ( "c2c_kimi_wake_daemon.py"
      , "deprecated: use Wire bridge (c2c wire-daemon start) instead" )
    ; ( "c2c_crush_wake_daemon.py"
      , "deprecated: Crush PTY wake is unreliable; no replacement" )
    ]
  in
  List.filter_map
    (fun (script, hint) ->
       (* Require python in the command to avoid matching pgrep/shell wrappers
          that contain the script name as part of an eval or snapshot string. *)
       let pattern = "python.*" ^ script in
       let cmd =
         Printf.sprintf "pgrep -a -f %s 2>/dev/null" (Filename.quote pattern)
       in
       let ic = Unix.open_process_in cmd in
       let lines = ref [] in
       (try
          while true do
            lines := input_line ic :: !lines
          done
        with End_of_file -> ());
       ignore (Unix.close_process_in ic);
       (* Filter: only keep lines where the process executable is python,
          not shell wrappers (zsh/bash eval) that contain the script name
          as part of a snapshot or pgrep invocation string. *)
       let is_python_proc line =
         let parts = String.split_on_char ' ' (String.trim line) in
         match parts with
         | _ :: cmd :: _ ->
             let base = Filename.basename cmd in
             let lc = String.lowercase_ascii base in
             String.length lc >= 6
             && String.sub lc 0 6 = "python"
         | _ -> false
       in
       let pids =
         List.filter_map
           (fun line ->
              if not (is_python_proc line) then None
              else
                let line = String.trim line in
                match String.split_on_char ' ' line with
                | pid_str :: _ -> (
                    match int_of_string_opt pid_str with
                    | Some pid -> Some pid
                    | None -> None)
                | [] -> None)
           !lines
       in
       if pids = [] then None else Some (script, pids, hint))
    patterns

(* PTY-inject capability check: managed kimi/codex/opencode deliver daemons
   use pidfd_getfd, which needs CAP_SYS_PTRACE when yama ptrace_scope >= 1.
   This surfaces the "forgot to setcap python3" footgun in `c2c health`. *)
let check_pty_inject_capability () : [ `Ok | `Missing_cap of string | `Unknown ] =
  let py =
    let ic = Unix.open_process_in "command -v python3 2>/dev/null" in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    if String.trim line = "" then "python3" else String.trim line
  in
  let yama_ok =
    try
      let ic = open_in "/proc/sys/kernel/yama/ptrace_scope" in
      let v = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> String.trim (input_line ic)) in
      v = "0"
    with _ -> false
  in
  if yama_ok then `Ok
  else
    let cmd = Printf.sprintf "getcap %s 2>/dev/null" (Filename.quote py) in
    let ic = Unix.open_process_in cmd in
    let line = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    let has_cap =
      let needle = "cap_sys_ptrace" in
      let nl = String.length needle and ll = String.length line in
      let rec loop i =
        if i + nl > ll then false
        else if String.sub line i nl = needle then true
        else loop (i + 1)
      in
      loop 0
    in
    if line = "" then `Missing_cap py
    else if has_cap then `Ok
    else `Missing_cap py

let health_cmd =
  let+ json = json_flag in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let root_exists = Sys.is_directory root in
  let registry_exists = Sys.file_exists (root // "registry.json") in
  let dead_letter_exists =
    Sys.file_exists (C2c_mcp.Broker.dead_letter_path broker)
  in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let liveness_counts = List.map C2c_mcp.Broker.registration_liveness_state regs in
  let alive_count   = List.filter (( = ) C2c_mcp.Broker.Alive)   liveness_counts |> List.length in
  let unknown_count = List.filter (( = ) C2c_mcp.Broker.Unknown) liveness_counts |> List.length in
  let dead_count    = List.filter (( = ) C2c_mcp.Broker.Dead)    liveness_counts |> List.length in
  let rooms = C2c_mcp.Broker.list_rooms broker in
  let pty_cap = check_pty_inject_capability () in
  let pty_cap_str = match pty_cap with
    | `Ok -> "ok"
    | `Missing_cap py -> Printf.sprintf "missing — `sudo setcap cap_sys_ptrace=ep %s` (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery)" py
    | `Unknown -> "unknown"
  in
  let stale_daemons = check_deprecated_daemons () in
  let supervisor_check = check_supervisor_config () in
  let relay_check = check_relay_http () in
  let plugin_checks = check_plugin_installs () in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let stale_json =
        `List
          (List.map
             (fun (script, pids, hint) ->
                `Assoc
                  [ ("script", `String script)
                  ; ("pids", `List (List.map (fun p -> `Int p) pids))
                  ; ("fix", `String hint)
                  ])
             stale_daemons)
      in
      let color_str = function `Green -> "green" | `Yellow -> "yellow" | `Red -> "red" | `Gray -> "gray" in
      let plugin_json = `List (List.map (fun (c, msg) -> `Assoc [("status", `String (color_str c)); ("message", `String msg)]) plugin_checks) in
      let (sup_col, sup_msg) = supervisor_check in
      let (rel_col, rel_msg) = relay_check in
      print_json
        (`Assoc
          [ ("broker_root", `String root)
          ; ("root_exists", `Bool root_exists)
          ; ("registry_exists", `Bool registry_exists)
          ; ("dead_letter_exists", `Bool dead_letter_exists)
          ; ("registrations", `Int (List.length regs))
          ; ("alive", `Int alive_count)
          ; ("unknown", `Int unknown_count)
          ; ("dead", `Int dead_count)
          ; ("rooms", `Int (List.length rooms))
          ; ("pty_inject_cap", `String (match pty_cap with `Ok -> "ok" | `Missing_cap _ -> "missing" | `Unknown -> "unknown"))
          ; ("stale_deprecated_daemons", stale_json)
          ; ("supervisor", `Assoc [("status", `String (color_str sup_col)); ("message", `String sup_msg)])
          ; ("relay", `Assoc [("status", `String (color_str rel_col)); ("message", `String rel_msg)])
          ; ("plugins", plugin_json)
          ])
  | Human ->
      let icon = function `Green -> "✓" | `Yellow -> "⚠" | `Red -> "✗" | `Gray -> "–" in
      Printf.printf "broker root:    %s\n" root;
      Printf.printf "root exists:    %s\n" (string_of_bool root_exists);
      Printf.printf "registry:       %s\n" (string_of_bool registry_exists);
      Printf.printf "dead-letter:    %s\n" (string_of_bool dead_letter_exists);
      Printf.printf "registrations:  %d (%d alive, %d unknown, %d dead)\n"
        (List.length regs) alive_count unknown_count dead_count;
      Printf.printf "rooms:          %d\n" (List.length rooms);
      Printf.printf "pty-inject cap: %s\n" pty_cap_str;
      let (sup_col, sup_msg) = supervisor_check in
      Printf.printf "%s %s\n" (icon sup_col) sup_msg;
      let (rel_col, rel_msg) = relay_check in
      Printf.printf "%s %s\n" (icon rel_col) rel_msg;
      List.iter (fun (c, msg) -> Printf.printf "%s %s\n" (icon c) msg) plugin_checks;
      if stale_daemons = [] then
        Printf.printf "stale daemons:  none\n"
      else begin
        Printf.printf "stale daemons:  %d deprecated process(es) running!\n"
          (List.length stale_daemons);
        List.iter
          (fun (script, pids, hint) ->
             let pid_str =
               String.concat ", " (List.map string_of_int pids)
             in
             Printf.printf "  ⚠  %s (pid %s)\n" script pid_str;
             Printf.printf "     fix: %s\n" hint;
             Printf.printf "     kill: kill %s\n" pid_str)
          stale_daemons
      end

(* --- subcommand: status --------------------------------------------------- *)

type managed_instance_view =
  { mi_name : string
  ; mi_client : string
  ; mi_status : string
  ; mi_delivery_mode : string
  ; mi_pid : int option
  ; mi_created_at : float option
  ; mi_tmux_location : string option
  }

let read_managed_instances () =
  let base =
    Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")
  in
  let dirs =
    if not (Sys.file_exists base) then []
    else
      Array.fold_left
        (fun acc name ->
           let full = base // name in
           if Sys.is_directory full && Sys.file_exists (full // "config.json")
           then full :: acc
           else acc)
        [] (Sys.readdir base)
  in
  List.sort String.compare dirs
  |> List.map (fun dir ->
         let name = Filename.basename dir in
         let config_path = dir // "config.json" in
         let config =
           try Some (Yojson.Safe.from_file config_path) with _ -> None
         in
         let config_string name fields =
           match List.assoc_opt name fields with Some (`String s) -> Some s | _ -> None
         in
         let config_float name fields =
           match List.assoc_opt name fields with
           | Some (`Float f) -> Some f
           | Some (`Int n) -> Some (float_of_int n)
           | _ -> None
         in
         let client =
           match config with
           | Some (`Assoc fields) ->
               (match List.assoc_opt "client" fields with Some (`String c) -> c | _ -> "?")
           | _ -> "?"
         in
         let created_at =
           match config with
           | Some (`Assoc fields) -> config_float "created_at" fields
           | _ -> None
         in
         let binary_path =
           match config with
           | Some (`Assoc fields) ->
               (match config_string "binary_override" fields with
                | Some path -> path
                | None ->
                    (match Hashtbl.find_opt C2c_start.clients client with
                     | Some cfg -> cfg.C2c_start.binary
                     | None -> client))
           | _ ->
               (match Hashtbl.find_opt C2c_start.clients client with
                | Some cfg -> cfg.C2c_start.binary
                | None -> client)
         in
         let status, pid =
           let outer_pid_path = dir // "outer.pid" in
           if Sys.file_exists outer_pid_path then begin
             let pid_s =
               let ic = open_in outer_pid_path in
               Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
                   let s = input_line ic in
                   String.trim s)
             in
             match int_of_string_opt pid_s with
             | Some pid ->
                 (try
                    ignore (Unix.kill pid 0);
                    ("running", Some pid)
                  with Unix.Unix_error _ -> ("stopped", Some pid))
             | None -> ("unknown", None)
           end
           else ("stopped", None)
          in
          let delivery_mode =
            C2c_start.delivery_mode ~client ~name ~binary_path ~start_time:created_at ()
          in
          let tmux_location =
            let tmux_json_path = dir // "tmux.json" in
            if Sys.file_exists tmux_json_path then
              (try
                let json = Yojson.Safe.from_file tmux_json_path in
                match json with
                | `Assoc fields ->
                    (match List.assoc_opt "session" fields with
                     | Some (`String s) -> Some s
                     | _ -> None)
                | _ -> None
              with _ -> None)
            else None
          in
          { mi_name = name
          ; mi_client = client
          ; mi_status = status
          ; mi_delivery_mode = delivery_mode
          ; mi_pid = pid
          ; mi_created_at = created_at
          ; mi_tmux_location = tmux_location
          })

let safe_is_directory path =
  try Sys.file_exists path && Sys.is_directory path with Sys_error _ -> false

let rec rm_rf path =
  if safe_is_directory path then (
    Array.iter (fun entry -> rm_rf (path // entry)) (Sys.readdir path);
    Unix.rmdir path)
  else
    (try Sys.remove path with Sys_error _ -> ())

let prune_stopped_instances_older_than ~days ~instances_dir managed_instances =
  let cutoff = Unix.gettimeofday () -. (float_of_int days *. 86400.0) in
  let stale_instances =
    List.filter
      (fun (inst : managed_instance_view) ->
         inst.mi_status = "stopped"
         && (match inst.mi_created_at with
             | Some created_at -> created_at < cutoff
             | None -> false))
      managed_instances
  in
  List.iter
    (fun (inst : managed_instance_view) ->
       let path = instances_dir // inst.mi_name in
       if Sys.file_exists path then rm_rf path)
    stale_instances;
  stale_instances

let status_cmd =
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 1
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let+ json = json_flag
  and+ min_messages = min_messages in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let now = Unix.gettimeofday () in
  let archive_dir = root // "archive" in

  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
  let last_sent_by_alias = Hashtbl.create 16 in
  let last_recv_by_sid = Hashtbl.create 16 in

  if safe_is_directory archive_dir then (
    let entries =
      try Array.to_list (Sys.readdir archive_dir)
      with Sys_error _ -> []
    in
    List.iter
      (fun fname ->
         if Filename.check_suffix fname ".jsonl" then (
           let session_id = Filename.chop_extension fname in
           let path = archive_dir // fname in
           try
             let ic = open_in path in
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let rec loop () =
                    match input_line ic with
                    | exception End_of_file -> ()
                    | line ->
                        let line = String.trim line in
                        if line <> "" then (
                          try
                            let json = Yojson.Safe.from_string line in
                            let open Yojson.Safe.Util in
                            let from_alias =
                              try json |> member "from_alias" |> to_string
                              with _ -> ""
                            in
                            let drained_at =
                              match json |> member "drained_at" with
                              | `Float f -> f
                              | `Int i -> float_of_int i
                              | _ -> 0.0
                            in
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1);
                              let prev_ts =
                                try Hashtbl.find last_sent_by_alias from_alias
                                with Not_found -> 0.0
                              in
                              if drained_at > prev_ts then
                                Hashtbl.replace last_sent_by_alias from_alias
                                  drained_at
                            );
                            let prev_recv =
                              try Hashtbl.find last_recv_by_sid session_id
                              with Not_found -> 0.0
                            in
                            if drained_at > prev_recv then
                              Hashtbl.replace last_recv_by_sid session_id
                                drained_at;
                            let prev_recv_count =
                              try Hashtbl.find received_by_sid session_id
                              with Not_found -> 0
                            in
                            Hashtbl.replace received_by_sid session_id
                              (prev_recv_count + 1)
                          with _ -> ());
                        loop ()
                  in
                  loop ())
           with Sys_error _ -> ()))
      entries
  );

  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let rooms = C2c_mcp.Broker.list_rooms broker in

  let alive_peers =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive then (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             let last_sent =
               try Hashtbl.find last_sent_by_alias r.alias
               with Not_found -> 0.0
             in
             let last_recv =
               try Hashtbl.find last_recv_by_sid r.session_id with Not_found ->
                 try Hashtbl.find last_recv_by_sid r.alias
                 with Not_found -> 0.0
             in
             let last_active = max last_sent last_recv in
             let goal_met = sent >= goal_count && received >= goal_count in
             Some (r.alias, sent, received, goal_met, last_active)
           else None)
         else None)
      regs
  in

  let dead_peer_count = List.length regs - List.length alive_peers in
  let overall_goal_met =
    alive_peers <> []
    && List.for_all (fun (_, _, _, gm, _) -> gm) alive_peers
  in
  let managed_instances = read_managed_instances () in

  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      let peer_json (alias, sent, received, goal_met, last_active) =
        `Assoc
          [ ("alias", `String alias)
          ; ("sent", `Int sent)
          ; ("received", `Int received)
          ; ("goal_met", `Bool goal_met)
          ; ("last_active_ts", `Float last_active)
          ]
      in
      let room_json (r : C2c_mcp.Broker.room_info) =
        let alive_members =
          List.filter_map
            (fun (m : C2c_mcp.Broker.room_member_info) ->
               if m.rmi_alive <> Some false then Some (`String m.rmi_alias)
               else None)
            r.ri_member_details
        in
        `Assoc
          [ ("room_id", `String r.ri_room_id)
          ; ("member_count", `Int r.ri_member_count)
          ; ("alive_count", `Int r.ri_alive_member_count)
          ; ("alive_members", `List alive_members)
          ]
      in
      print_json
        (`Assoc
           [ ("alive_peers", `List (List.map peer_json alive_peers))
           ; ("dead_peer_count", `Int dead_peer_count)
           ; ("total_peer_count", `Int (List.length regs))
           ; ( "managed_instances",
               `List
                 (List.map
                    (fun inst ->
                       `Assoc
                         [ ("name", `String inst.mi_name)
                         ; ("client", `String inst.mi_client)
                         ; ("status", `String inst.mi_status)
                         ; ("delivery_mode", `String inst.mi_delivery_mode)
                         ; ("pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
                         ])
                    managed_instances) )
           ; ("rooms", `List (List.map room_json rooms))
           ; ("overall_goal_met", `Bool overall_goal_met)
           ])
  | Human ->
      Printf.printf "c2c Status\n";
      Printf.printf "==================================================\n\n";
      Printf.printf "Alive peers (%d/%d):\n" (List.length alive_peers)
        (List.length regs);
      List.iter
        (fun (alias, sent, received, goal_met, last_active) ->
           let age =
             let delta = now -. last_active in
             if delta < 0.0 then "just now"
             else if delta < 60.0 then Printf.sprintf "%.0fs ago" delta
             else if delta < 3600.0 then
               Printf.sprintf "%.0fm ago" (delta /. 60.0)
             else if delta < 86400.0 then
               Printf.sprintf "%.0fh ago" (delta /. 3600.0)
             else Printf.sprintf "%.0fd ago" (delta /. 86400.0)
           in
           let status = if goal_met then "goal_met" else "pending" in
           Printf.printf "  %-20s sent=%3d recv=%3d  %-8s  last=%s\n" alias
             sent received status age)
        alive_peers;
      if alive_peers = [] then Printf.printf "  (none)\n";
      Printf.printf "\nRooms:\n";
      List.iter
        (fun (r : C2c_mcp.Broker.room_info) ->
           Printf.printf "  %-20s %d member(s), %d alive\n" r.ri_room_id
             r.ri_member_count r.ri_alive_member_count)
        rooms;
      if rooms = [] then Printf.printf "  (none)\n";
      Printf.printf "\nManaged instances:\n";
      List.iter
        (fun inst ->
           let pid_str =
             match inst.mi_pid with
             | Some pid -> Printf.sprintf " (pid %d)" pid
             | None -> ""
           in
           Printf.printf "  %-20s %-10s %-12s %s%s\n" inst.mi_name
             inst.mi_client inst.mi_status inst.mi_delivery_mode pid_str)
        managed_instances;
      if managed_instances = [] then Printf.printf "  (none)\n";
      Printf.printf "\nOverall goal_met: %s\n"
        (if overall_goal_met then "YES" else "NO")

let status =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "status" ~doc:"Show compact swarm overview.")
    status_cmd

(* --- subcommand: verify --------------------------------------------------- *)

let verify_cmd =
  let alive_only =
    Cmdliner.Arg.(
      value & flag
      & info [ "alive-only" ] ~doc:"Exclude dead registrations from results.")
  in
  let min_messages =
    Cmdliner.Arg.(
      value
      & opt int 0
      & info [ "min-messages" ] ~docv:"N"
          ~doc:"Minimum total messages (sent+received) to include a peer.")
  in
  let+ json = json_flag
  and+ alive_only = alive_only
  and+ min_messages = min_messages in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let archive_dir = root // "archive" in
  let sent_by_alias = Hashtbl.create 16 in
  let received_by_sid = Hashtbl.create 16 in
  if safe_is_directory archive_dir then (
    let entries =
      try Array.to_list (Sys.readdir archive_dir)
      with Sys_error _ -> []
    in
    List.iter
      (fun fname ->
         if Filename.check_suffix fname ".jsonl" then (
           let session_id = Filename.chop_extension fname in
           let path = archive_dir // fname in
           try
             let ic = open_in path in
             Fun.protect
               ~finally:(fun () -> close_in_noerr ic)
               (fun () ->
                  let rec loop recv_count =
                    match input_line ic with
                    | exception End_of_file -> recv_count
                    | line ->
                        let line = String.trim line in
                        if line <> "" then (
                          try
                            let json = Yojson.Safe.from_string line in
                            let open Yojson.Safe.Util in
                            let from_alias =
                              try json |> member "from_alias" |> to_string
                              with _ -> ""
                            in
                            if from_alias <> "" && from_alias <> "c2c-system"
                            then (
                              let prev =
                                try Hashtbl.find sent_by_alias from_alias
                                with Not_found -> 0
                              in
                              Hashtbl.replace sent_by_alias from_alias
                                (prev + 1)
                            );
                            loop (recv_count + 1)
                          with _ -> loop recv_count
                        ) else loop recv_count
                  in
                  let recv_count = loop 0 in
                  Hashtbl.replace received_by_sid session_id recv_count)
           with Sys_error _ -> ()))
      entries
  );
  let goal_count = 20 in
  let regs = C2c_mcp.Broker.list_registrations broker in
  let participants =
    List.filter_map
      (fun (r : C2c_mcp.registration) ->
         if alive_only && not (C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive) then
           None
         else (
           let sent =
             try Hashtbl.find sent_by_alias r.alias with Not_found -> 0
           in
           let received =
             try Hashtbl.find received_by_sid r.session_id with Not_found ->
               try Hashtbl.find received_by_sid r.alias with Not_found -> 0
           in
           if sent + received >= min_messages then
             Some (r.alias, sent, received)
           else None))
      regs
  in
  let goal_met =
    participants <> []
    && List.for_all
         (fun (_, s, r) -> s >= goal_count && r >= goal_count)
         participants
  in
  if json then
    print_json
      (`Assoc
         [ ( "participants"
           , `List
               (List.map
                  (fun (alias, sent, received) ->
                     `Assoc
                       [ ("alias", `String alias)
                       ; ("sent", `Int sent)
                       ; ("received", `Int received)
                       ])
                  participants) )
         ; ("goal_met", `Bool goal_met)
         ; ("source", `String "broker")
         ])
  else (
    List.iter
      (fun (alias, sent, received) ->
         let status =
           if sent >= goal_count && received >= goal_count then "goal_met"
           else "in_progress"
         in
         Printf.printf "%s: sent=%d received=%d status=%s\n" alias sent
           received status)
      participants;
    Printf.printf "goal_met: %s\n" (if goal_met then "yes" else "no"))

let verify =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "verify" ~doc:"Verify c2c message exchange progress.")
    verify_cmd

(* --- subcommand: git ----------------------------------------------------- *)

let has_author_flag args =
  List.exists (fun arg ->
    String.length arg >= 8 && String.sub arg 0 8 = "--author"
    || (String.length arg > 8 && String.sub arg 0 9 = "--author="))
    args

let has_sign_flag args =
  List.exists (fun arg -> arg = "-S" || arg = "--gpg-sign") args

let is_signing_subcmd = function
  | "commit" | "tag" -> true
  | _ -> false

let git_cmd =
  let+ args = Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"ARG" ~doc:"Git argument (passed through verbatim).") in
  let args = if args = [] then ["--version"] else args in
  let alias =
    match env_auto_alias () with
    | Some a -> a
    | None ->
        (match Relay_identity.load () with
         | Ok id when id.alias_hint <> "" -> id.alias_hint
         | _ -> "anonymous")
  in
  let attribution = C2c_start.repo_config_git_attribution () in
  let env =
    if attribution && not (has_author_flag args) then
      let author_name = alias in
      let author_email = Printf.sprintf "%s@c2c.im" alias in
      Some (author_name, author_email)
    else None
  in
  let git_path = Git_helpers.find_real_git () in
  let sign_config_args, sign_flag =
    if C2c_start.repo_config_git_sign ()
       && not (has_sign_flag args)
       && List.length args > 0
       && is_signing_subcmd (List.hd args)
       && alias <> "anonymous"
    then
       let broker_root = resolve_broker_root () in
       let key_path = Filename.concat broker_root ("keys" // alias ^ ".ed25519.ssh") in
       let signers_path = Filename.concat broker_root "allowed_signers" in
       if Sys.file_exists key_path then
         ( [ "-c"; "gpg.format=ssh"
           ; "-c"; "user.signingkey=" ^ key_path
           ; "-c"; "gpg.ssh.allowedSignersFile=" ^ signers_path
           ; "-c"; "commit.gpgsign=true" ],
           ["-S"] )
       else ([], [])
    else ([], [])
  in
  let subcmd = List.hd args in
  let rest = List.tl args in
  let argv = Array.of_list (git_path :: sign_config_args @ [subcmd] @ sign_flag @ rest) in
  let env_array = match env with
    | None -> [||]
    | Some (name, email) -> [| "GIT_AUTHOR_NAME=" ^ name; "GIT_AUTHOR_EMAIL=" ^ email |]
  in
  Unix.execve git_path argv (Array.append env_array (Unix.environment ()))

let git =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "git"
       ~doc:"Git wrapper that auto-injects --author for commits when git.attribution=true in .c2c/config.toml (default: on).")
    git_cmd

(* --- subcommand: register ------------------------------------------------- *)

let register_cmd =
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc:"Alias to register (default: C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let session_id_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID" ~doc:"Session ID (default: resolved from C2C_MCP_SESSION_ID or the current client session).")
  in
  let+ json = json_flag
  and+ alias_opt = alias
  and+ session_id_opt = session_id_opt in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let alias =
    match alias_opt with
    | Some a -> a
    | None -> (
        match env_auto_alias () with
        | Some a -> a
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
  (* Prefer C2C_MCP_CLIENT_PID (set by managed launchers to the outer loop PID)
     over getppid(), so `c2c register` from inside a managed session pins
     liveness to the durable outer process rather than a transient shell. *)
  let pid =
    match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
    | Some s -> (match int_of_string_opt (String.trim s) with Some p -> Some p | None -> Some (Unix.getppid ()))
    | None -> Some (Unix.getppid ())
  in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id ~alias ~pid ~pid_start_time ~client_type:(env_client_type ()) ();
  C2c_mcp.Broker.write_allowed_signers_entry broker ~alias;
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

(* --- subcommand: get-tmux-location ---------------------------------------- *)

let get_tmux_location_cmd =
  let+ json = json_flag in
  match Sys.getenv_opt "TMUX" with
  | None ->
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | Some _ ->
      let capture cmd =
        try
          let ic = Unix.open_process_in cmd in
          Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> Some (input_line ic))
        with _ -> None
      in
      match capture "tmux display-message -p '#S:#I.#P'" with
      | None ->
          Printf.eprintf "error: tmux display-message failed. Is tmux running?\n%!";
          exit 1
      | Some addr ->
          let output_mode = if json then Json else Human in
          match output_mode with
          | Json -> print_json (`String addr)
          | Human -> Printf.printf "%s\n" addr

(* --- subcommand: tail-log ------------------------------------------------ *)

let tail_log_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max log entries (default 50, max 500).")
  in
  let+ json = json_flag
  and+ limit = limit in
  let limit = min (max limit 1) 500 in
  let root = resolve_broker_root () in
  let log_path = root // "broker.log" in
  let output_mode = if json then Json else Human in
  if not (Sys.file_exists log_path) then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "(no log)\n")
  else
    let lines =
      let ic = open_in log_path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let buf = Buffer.create 4096 in
        (try while true do
             let line = String.trim (input_line ic) in
             if line <> "" then begin
               Buffer.add_string buf line;
               Buffer.add_char buf '\n'
             end
           done with End_of_file -> ());
        String.split_on_char '\n' (Buffer.contents buf)
        |> List.filter (fun s -> String.trim s <> ""))
    in
    let n = List.length lines in
    let tail =
      if n <= limit then lines
      else
        let drop = n - limit in
        let rec skip i = function
          | [] -> []
          | _ :: rest when i > 0 -> skip (i - 1) rest
          | lst -> lst
        in
        skip drop lines
    in
    let parsed =
      List.filter_map
        (fun line ->
          try Some (Yojson.Safe.from_string line)
          with _ -> None)
        tail
    in
    match output_mode with
    | Json -> print_json (`List parsed)
    | Human -> List.iter (fun line -> print_endline line) tail

(* --- subcommand: server-info ----------------------------------------- *)

let server_info_cmd =
  let+ json = json_flag in
  let output_mode = if json then Json else Human in
  let info = C2c_mcp.server_info in
  match output_mode with
  | Json -> print_json info
  | Human ->
    (match info with
     | `Assoc fields ->
       List.iter (fun (k, v) ->
         match v with
         | `String s -> Printf.printf "%s: %s\n" k s
         | `List l -> Printf.printf "%s:\n" k; List.iter (fun item -> Printf.printf "  - %s\n" (Yojson.Safe.to_string item)) l
         | _ -> Printf.printf "%s: %s\n" k (Yojson.Safe.to_string v))
         fields
     | _ -> print_json info)

(* --- subcommand: my-rooms ---------------------------------------------- *)

let my_rooms_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = resolve_session_id_for_inbox broker in
  let rooms = C2c_mcp.Broker.my_rooms broker ~session_id in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (r : C2c_mcp.Broker.room_info) ->
               let alive_members =
                 List.filter_map
                   (fun (m : C2c_mcp.Broker.room_member_info) ->
                      if m.rmi_alive <> Some false then Some (`String m.rmi_alias)
                      else None)
                   r.ri_member_details
               in
               `Assoc
                 [ ("room_id", `String r.ri_room_id)
                 ; ("member_count", `Int r.ri_member_count)
                 ; ("alive_count", `Int r.ri_alive_member_count)
                 ; ("members",
                     `List (List.map (fun a -> `String a) r.ri_members))
                 ; ("alive_members", `List alive_members)
                 ; ( "visibility",
                     `String
                       (match r.ri_visibility with
                       | C2c_mcp.Public -> "public"
                       | C2c_mcp.Invite_only -> "invite_only"))
                 ])
             rooms))
  | Human ->
      if rooms = [] then
        Printf.printf "Not in any rooms.\n"
      else
        List.iter
          (fun (r : C2c_mcp.Broker.room_info) ->
            let alive = if r.ri_alive_member_count > 0 then
              Printf.sprintf ", %d alive" r.ri_alive_member_count
            else "" in
            Printf.printf "%s (%d members%s)\n" r.ri_room_id r.ri_member_count alive)
          rooms

(* --- subcommand: dead-letter ---------------------------------------------- *)

let dead_letter_cmd =
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit"; "l" ] ~docv:"N" ~doc:"Max entries to return.")
  in
  let+ json = json_flag
  and+ limit = limit in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let path = C2c_mcp.Broker.dead_letter_path broker in
  let output_mode = if json then Json else Human in
  if not (Sys.file_exists path) then (
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "(no dead-letter file)\n")
  else
    let ic = open_in path in
    let entries =
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let buf = Buffer.create 4096 in
        (try while true do
             let line = input_line ic in
             Buffer.add_string buf line;
             Buffer.add_char buf '\n'
           done with End_of_file -> ());
        let content = Buffer.contents buf in
        if String.trim content = "" then []
        else
          String.split_on_char '\n' content
          |> List.filter (fun s -> String.trim s <> "")
          |> List.filter_map
               (fun line ->
                 try Some (Yojson.Safe.from_string line)
                 with _ -> None))
    in
    let n = List.length entries in
    let entries =
      if n <= limit then entries
      else
        let drop = n - limit in
        let rec skip i = function
          | [] -> []
          | _ :: rest when i > 0 -> skip (i - 1) rest
          | lst -> lst
        in
        skip drop entries
    in
    match output_mode with
    | Json -> print_json (`List entries)
    | Human ->
        if entries = [] then
          Printf.printf "(empty)\n"
        else
          List.iter (fun j -> print_endline (Yojson.Safe.pretty_to_string j)) entries

(* --- subcommand: prune-rooms ---------------------------------------------- *)

let prune_rooms_cmd =
  let+ json = json_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let evicted = C2c_mcp.Broker.prune_rooms broker in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (room_id, alias) ->
               `Assoc [ ("room_id", `String room_id); ("alias", `String alias) ])
             evicted))
  | Human ->
      if evicted = [] then
        Printf.printf "No dead members to evict.\n"
      else
        (Printf.printf "Evicted %d dead members:\n" (List.length evicted);
         List.iter
           (fun (room_id, alias) ->
             Printf.printf "  %s from %s\n" alias room_id)
           evicted)

(* --- subcommand: monitor (inotify-based inbox watcher) --------------------- *)

(* Read an inbox JSON file, returning the parsed message list. *)
let read_inbox_file path =
  try
    let ic = open_in path in
    let content = Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let buf = Buffer.create 512 in
      (try while true do Buffer.add_channel buf ic 1 done with End_of_file -> ());
      Buffer.contents buf)
    in
    (match Yojson.Safe.from_string content with
     | `List msgs -> msgs
     | _ -> [])
  with _ -> []

(* Extract a string field from a JSON assoc or return a default. *)
let jstr fields key def =
  match List.assoc_opt key fields with Some (`String s) -> s | _ -> def

(* Truncate a string to max_len, appending "…" if clipped. *)
let truncate s max_len =
  let s = String.trim s in
  if String.length s > max_len then String.sub s 0 max_len ^ "…" else s

(* Current time as [HH:MM:SS] *)
let now_hms () =
  let t = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "[%02d:%02d:%02d]" t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(* Determine if a to_alias value is a room fanout (contains '#') *)
let parse_to_alias s =
  match String.split_on_char '#' s with
  | [_alias; room] -> `Room room
  | _ -> `Direct s

(* Short-window dedup for room fanouts. One room message lands in N peer
   archives; each archive append emits. Keyed on (from_alias, to_alias,
   content) — if we saw the exact same triple within the last 30s, skip.
   Max 1024 entries, oldest evicted on overflow. *)
let dedup_seen : (string * string * string, float) Hashtbl.t = Hashtbl.create 64
let dedup_window_s = 30.0

let dedup_check ~from ~to_raw ~content =
  let key = (from, to_raw, content) in
  let now = Unix.gettimeofday () in
  (* Opportunistic GC when table gets large *)
  if Hashtbl.length dedup_seen > 1024 then begin
    let stale = Hashtbl.fold (fun k ts acc ->
      if now -. ts > dedup_window_s then k :: acc else acc) dedup_seen [] in
    List.iter (Hashtbl.remove dedup_seen) stale
  end;
  match Hashtbl.find_opt dedup_seen key with
  | Some ts when now -. ts < dedup_window_s -> false
  | _ -> Hashtbl.replace dedup_seen key now; true

(* Emit one notification line per unique sender, collapsing bursts. *)
let emit_messages ~my_alias ~all ~full_body msgs =
  (* Group messages by from_alias *)
  let by_sender = Hashtbl.create 4 in
  List.iter (fun msg ->
    match msg with
    | `Assoc fields ->
        let from = jstr fields "from_alias" "?" in
        let existing = try Hashtbl.find by_sender from with Not_found -> [] in
        Hashtbl.replace by_sender from (existing @ [fields])
    | _ -> ()
  ) msgs;
  Hashtbl.iter (fun from sender_msgs ->
    let n = List.length sender_msgs in
    let first = List.hd sender_msgs in
    let to_raw = jstr first "to_alias" "" in
    let is_mine = match my_alias with
      | None -> true
      | Some me -> to_raw = me || String.length to_raw > String.length me + 1
                   && String.sub to_raw 0 (String.length me) = me
    in
    let body = jstr first "content" "" in
    (* Normalize room fanouts: each peer's archive tags to_alias with their
       own alias prefix (coder1#swarm-lounge vs planner1#swarm-lounge) so
       dedup sees them as distinct. Strip alias, keep just #<room>. *)
    let dedup_to = match parse_to_alias to_raw with
      | `Room room -> "#" ^ room
      | `Direct d -> d
    in
    let keep = dedup_check ~from ~to_raw:dedup_to ~content:body in
    if keep && (all || is_mine) then begin
      let icon = if is_mine then "📬" else "💬" in
      let dest = match parse_to_alias to_raw with
        | `Room room -> "@" ^ room
        | `Direct d -> if is_mine then "you" else d
      in
      let subject =
        if n = 1 then
          if full_body then Printf.sprintf "\"%s\"" body
          else Printf.sprintf "\"%s\"" (truncate body 80)
        else
          Printf.sprintf "(%d msgs) \"%s\"" n (truncate body 60)
      in
      Printf.printf "%s %s  %s→%s  %s\n%!"
        (now_hms ()) icon from dest subject
    end
  ) by_sender

let monitor_cmd =
  let open Cmdliner in
  let open Cmdliner.Term in
  let broker_root_opt =
    Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git).")
  in
  let alias_opt =
    Arg.(value & opt (some string) None & info ["alias";"a"] ~docv:"ALIAS"
           ~doc:"My alias (default: C2C_MCP_SESSION_ID). Only messages addressed to \
                 this alias are shown by default.")
  in
  let all_flag =
    Arg.(value & flag & info ["all"]
           ~doc:"Also show messages addressed to other peers (situational awareness).")
  in
  let drains_flag =
    Arg.(value & flag & info ["drains"]
           ~doc:"Show drain events (when a peer polls their inbox to empty).")
  in
  let sweeps_flag =
    Arg.(value & flag & info ["sweeps"]
           ~doc:"Show sweep/delete events.")
  in
  let full_body_flag =
    Arg.(value & flag & info ["full-body";"body"]
           ~doc:"Emit full message content instead of an 80-char subject snippet.")
  in
  let from_opt =
    Arg.(value & opt (some string) None & info ["from"] ~docv:"ALIAS"
           ~doc:"Only show messages from this sender alias.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Emit JSON objects instead of human-readable lines.")
  in
  let archive_flag =
    Arg.(value & flag & info ["archive"]
           ~doc:"Watch append-only archive (archive/*.jsonl) instead of live inboxes. \
                 Avoids the race where the PostToolUse hook drains the inbox before \
                 the monitor can peek. Every drained message is recorded here.")
  in
  let include_self_flag =
    Arg.(value & flag & info ["include-self"]
           ~doc:"Include messages sent by you. Off by default — your own broadcasts \
                 and DMs echo back through archive/inbox events and are noise.")
  in
  const (fun broker_root_arg alias_arg all drains sweeps full_body from_filter json archive include_self ->
    let broker_root =
      match broker_root_arg with
      | Some r -> r
      | None ->
          (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
           | Some r -> r
           | None -> (try resolve_broker_root () with _ ->
               Printf.eprintf "c2c monitor: cannot resolve broker root \
                 (set C2C_MCP_BROKER_ROOT or run from inside the repo)\n%!";
               exit 1))
    in
    let my_alias =
      match alias_arg with
      | Some a -> Some a
      | None -> Sys.getenv_opt "C2C_MCP_SESSION_ID"
    in
    let registry_path = Filename.concat broker_root "registry.json" in
    (* Read aliases from registry.json — returns (alias, session_id) pairs. *)
    let read_registry_aliases () =
      try
        let ic = open_in registry_path in
        let content = really_input_string ic (in_channel_length ic) in
        close_in ic;
        match Yojson.Safe.from_string content with
        | `Assoc fields ->
            (match List.assoc_opt "registrations" fields with
             | Some (`List regs) ->
                 List.filter_map (fun r -> match r with
                   | `Assoc rfields ->
                       (match List.assoc_opt "alias" rfields,
                              List.assoc_opt "session_id" rfields with
                        | Some (`String a), Some (`String s) -> Some (a, s)
                        | _ -> None)
                   | _ -> None) regs
             | _ -> [])
        | _ -> []
      with _ -> []
    in
    (* Snapshot: alias → session_id. Used to diff registry changes. *)
    let known_peers : (string, string) Hashtbl.t = Hashtbl.create 16 in
    List.iter (fun (a, s) -> Hashtbl.replace known_peers a s) (read_registry_aliases ());
    (* Snapshot: room_id → alias set. Used to diff room membership changes. *)
    let known_room_members : (string, (string, unit) Hashtbl.t) Hashtbl.t =
      Hashtbl.create 4
    in
    let read_room_members room_id =
      let path = broker_root // "rooms" // room_id // "members.json" in
      try
        let ic = open_in path in
        let content = really_input_string ic (in_channel_length ic) in
        close_in ic;
        (match Yojson.Safe.from_string content with
         | `List members ->
             List.filter_map (fun m -> match m with
               | `Assoc fields -> (match List.assoc_opt "alias" fields with
                   | Some (`String a) -> Some a | _ -> None)
               | _ -> None) members
         | _ -> [])
      with _ -> []
    in
    (try
       let rooms_dir = broker_root // "rooms" in
       if Sys.file_exists rooms_dir then
         Array.iter (fun room_id ->
           let tbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
           List.iter (fun a -> Hashtbl.replace tbl a ()) (read_room_members room_id);
           Hashtbl.replace known_room_members room_id tbl
         ) (Sys.readdir rooms_dir)
     with _ -> ());
    (* Archive mode watches <broker_root>/archive/*.jsonl (append-only).
       Each drained message is a full JSON object on its own line. We track
       per-file read offsets so we only emit newly-appended lines. This avoids
       the race where the PostToolUse hook drains the live inbox before our
       inotify event fires on <root>/*.inbox.json. *)
    let watch_dir =
      if archive then Filename.concat broker_root "archive" else broker_root
    in
    if archive && not (Sys.file_exists watch_dir) then begin
      (try Unix.mkdir watch_dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end;
    (* Per-file read offsets for archive mode. Init to current size so we
       don't re-emit historical entries on startup. *)
    let archive_offsets : (string, int) Hashtbl.t = Hashtbl.create 16 in
    if archive && Sys.file_exists watch_dir then begin
      Array.iter (fun fname ->
        let n = String.length fname in
        if n > 6 && String.sub fname (n - 6) 6 = ".jsonl" then
          let path = Filename.concat watch_dir fname in
          try
            let st = Unix.stat path in
            Hashtbl.replace archive_offsets path st.Unix.st_size
          with _ -> ()
      ) (Sys.readdir watch_dir)
    end;
    let read_new_archive_entries path =
      let prev = try Hashtbl.find archive_offsets path with Not_found -> 0 in
      try
        let st = Unix.stat path in
        let sz = st.Unix.st_size in
        if sz <= prev then []
        else
          let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
            let _ = Unix.lseek fd prev Unix.SEEK_SET in
            let buf = Bytes.create (sz - prev) in
            let rec read_all off rem =
              if rem <= 0 then () else
              let r = Unix.read fd buf off rem in
              if r = 0 then () else read_all (off + r) (rem - r)
            in
            read_all 0 (sz - prev);
            Hashtbl.replace archive_offsets path sz;
            let text = Bytes.unsafe_to_string buf in
            let lines = String.split_on_char '\n' text in
            List.filter_map (fun ln ->
              let ln = String.trim ln in
              if ln = "" then None
              else try Some (Yojson.Safe.from_string ln) with _ -> None
            ) lines)
      with _ -> []
    in
    (* Belt-and-braces startup orphan check: if the parent already died before
       we enter the inotify loop, exit immediately rather than loop forever. *)
    (if Unix.getppid () = 1 then exit 0);
    let cmd =
      if archive then
        (* Archive: flat dir, original space-delimited format. *)
        Printf.sprintf
          "inotifywait -m -e close_write,modify,delete,moved_to --format '%%e %%f' %s"
          (Filename.quote watch_dir)
      else
        (* Live: recursive so rooms/<id>/members.json is caught.
           Tab-delimited with %w%f = full path avoids space-in-path ambiguity.
           No -q: we read stderr to detect "Watches established." and emit a
           monitor.ready event so tests/callers don't need a fixed sleep. *)
        Printf.sprintf
          "inotifywait -m -r -e close_write,modify,delete,moved_to --format '%%e\t%%w%%f' %s"
          (Filename.quote watch_dir)
    in
    let (ic, _oc, err_ic) = Unix.open_process_full cmd (Unix.environment ()) in
    (* Drain inotifywait stderr in a background thread; set a flag once we see
       "Watches established." so the main thread knows inotifywait is armed.
       This replaces the fixed sleep in callers (tests, plugin) with a
       deterministic signal, preventing the race where events are triggered
       before inotifywait finishes setting up watches. *)
    let ready_flag = Atomic.make false in
    let str_contains haystack needle =
      let hl = String.length haystack and nl = String.length needle in
      if nl = 0 then true
      else if nl > hl then false
      else begin
        let found = ref false in
        let i = ref 0 in
        while !i <= hl - nl && not !found do
          if String.sub haystack !i nl = needle then found := true;
          incr i
        done;
        !found
      end
    in
    let _err_thread = Thread.create (fun () ->
      (try while true do
        let line = String.lowercase_ascii (input_line err_ic) in
        if str_contains line "watches established" then
          Atomic.set ready_flag true
      done with End_of_file | Sys_error _ -> ());
      (* Signal on EOF too so main thread never waits forever. *)
      Atomic.set ready_flag true
    ) () in
    (* Poll ready_flag up to 10s with 50ms sleeps — no timed Condition needed. *)
    let deadline = Unix.gettimeofday () +. 10.0 in
    while not (Atomic.get ready_flag) && Unix.gettimeofday () < deadline do
      Thread.delay 0.05
    done;
    if json then begin
      let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
      print_string (Yojson.Safe.to_string
        (`Assoc [ "event_type", `String "monitor.ready"
                ; "monitor_ts", `String ts ]));
      print_newline ()
    end;
    Fun.protect ~finally:(fun () -> ignore (Unix.close_process_full (ic, _oc, err_ic))) (fun () ->
      try while true do
        (* If our parent died (reparented to init/PID 1), we are an orphan —
           exit rather than accumulate as a zombie monitor process. *)
        (if Unix.getppid () = 1 then exit 0);
        let line = input_line ic in
        (* Archive uses space-delimited "EVENT FILENAME"; live uses
           tab-delimited "EVENT\tFULL_PATH" (recursive, full path). *)
        let parts =
          if archive then String.split_on_char ' ' (String.trim line)
          else String.split_on_char '\t' (String.trim line)
        in
        (match parts with
         | event :: filename :: _ when archive ->
             let n = String.length filename in
             let is_jsonl = n > 6 && String.sub filename (n - 6) 6 = ".jsonl" in
             if is_jsonl then begin
               let sid = String.sub filename 0 (n - 6) in
               let path = Filename.concat watch_dir filename in
               let entries = read_new_archive_entries path in
               (* Apply --from filter *)
               let entries = match from_filter with
                 | None -> entries
                 | Some f -> List.filter (fun m -> match m with
                     | `Assoc fields -> jstr fields "from_alias" "" = f
                     | _ -> false) entries
               in
               (* Drop self-sent unless --include-self *)
               let entries =
                 if include_self then entries
                 else match my_alias with
                   | None -> entries
                   | Some me -> List.filter (fun m -> match m with
                       | `Assoc fields -> jstr fields "from_alias" "" <> me
                       | _ -> true) entries
               in
               (match entries with
                | [] -> ()
                | msgs ->
                    if json then begin
                      let is_mine = match my_alias with
                        | None -> true | Some me -> sid = me in
                      if all || is_mine then
                        List.iter (fun m ->
                          let m_with_ts = match m with
                            | `Assoc fields ->
                                let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                                `Assoc (("event_type", `String "message")
                                        :: ("monitor_ts", `String ts) :: fields)
                            | _ -> m
                          in
                          print_string (Yojson.Safe.to_string m_with_ts);
                          print_newline ()
                        ) msgs
                    end else
                      emit_messages ~my_alias ~all ~full_body msgs)
             end;
             ignore event
         | event :: full_path :: _ ->
             (* In live mode filename is a full path; basename is used for routing. *)
             let filename = Filename.basename full_path in
             let n = String.length filename in
             let is_inbox = n > 11 && String.sub filename (n - 11) 11 = ".inbox.json" in
             let is_lock  = n >= 5  && String.sub filename (n - 5) 5 = ".lock" in
             if is_inbox && not is_lock then begin
               let alias = String.sub filename 0 (n - 11) in
               let event_up = String.uppercase_ascii event in
               let is_delete = String.length event_up >= 6
                               && String.sub event_up 0 6 = "DELETE" in
               if is_delete then begin
                 if sweeps then begin
                   if json then begin
                     let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "sweep"
                               ; "alias",      `String alias
                               ; "monitor_ts", `String ts ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🗑️  SWEEP  %s (inbox deleted)\n%!" (now_hms ()) alias
                 end
               end else begin
                 let inbox_path = Filename.concat broker_root filename in
                 let msgs = read_inbox_file inbox_path in
                 (* Apply --from filter *)
                 let msgs = match from_filter with
                   | None -> msgs
                   | Some f -> List.filter (fun m -> match m with
                       | `Assoc fields -> jstr fields "from_alias" "" = f
                       | _ -> false) msgs
                 in
                 (* Drop self-sent unless --include-self *)
                 let msgs =
                   if include_self then msgs
                   else match my_alias with
                     | None -> msgs
                     | Some me -> List.filter (fun m -> match m with
                         | `Assoc fields -> jstr fields "from_alias" "" <> me
                         | _ -> true) msgs
                 in
                 (match msgs with
                  | [] ->
                      if drains then begin
                        if json then begin
                          let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                          print_string (Yojson.Safe.to_string
                            (`Assoc [ "event_type", `String "drain"
                                    ; "alias",      `String alias
                                    ; "monitor_ts", `String ts ]));
                          print_newline ()
                        end else
                          Printf.printf "%s 📤  DRAIN  %s (inbox cleared)\n%!" (now_hms ()) alias
                      end
                  | msgs ->
                      if json then begin
                        let is_mine = match my_alias with
                          | None -> true | Some me -> alias = me in
                        if all || is_mine then
                          List.iter (fun m ->
                            let m_with_ts = match m with
                              | `Assoc fields ->
                                  let ts = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
                                  `Assoc (("event_type", `String "message")
                                          :: ("monitor_ts", `String ts) :: fields)
                              | _ -> m
                            in
                            print_string (Yojson.Safe.to_string m_with_ts);
                            print_newline ()
                          ) msgs
                      end else
                        emit_messages ~my_alias ~all ~full_body msgs)
               end
             end else if filename = "registry.json" && not archive then begin
               (* Registry changed — diff against snapshot and emit peer events. *)
               let new_regs = read_registry_aliases () in
               let new_tbl : (string, string) Hashtbl.t = Hashtbl.create 16 in
               List.iter (fun (a, s) -> Hashtbl.replace new_tbl a s) new_regs;
               let ts () = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
               (* Emit peer.alive for any alias not previously known. *)
               List.iter (fun (a, _s) ->
                 if not (Hashtbl.mem known_peers a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "peer.alive"
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🟢  PEER   %s (registered)\n%!" (now_hms ()) a
                 end
               ) new_regs;
               (* Emit peer.dead for any alias no longer present. *)
               Hashtbl.iter (fun a _s ->
                 if not (Hashtbl.mem new_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "peer.dead"
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🔴  PEER   %s (deregistered)\n%!" (now_hms ()) a
                 end
               ) known_peers;
               (* Update snapshot. *)
               Hashtbl.reset known_peers;
               List.iter (fun (a, s) -> Hashtbl.replace known_peers a s) new_regs
             end else if filename = "members.json"
                      && Filename.basename (Filename.dirname (Filename.dirname full_path)) = "rooms"
             then begin
               (* Room membership changed — extract room_id, diff, emit events. *)
               let room_id = Filename.basename (Filename.dirname full_path) in
               let new_members = read_room_members room_id in
               let new_tbl : (string, unit) Hashtbl.t = Hashtbl.create 4 in
               List.iter (fun a -> Hashtbl.replace new_tbl a ()) new_members;
               let prev_tbl =
                 try Hashtbl.find known_room_members room_id
                 with Not_found ->
                   let t : (string, unit) Hashtbl.t = Hashtbl.create 4 in
                   Hashtbl.replace known_room_members room_id t; t
               in
               let ts () = Printf.sprintf "%.3f" (Unix.gettimeofday ()) in
               List.iter (fun a ->
                 if not (Hashtbl.mem prev_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "room.join"
                               ; "room_id",    `String room_id
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 🚪  ROOM   %s joined %s\n%!" (now_hms ()) a room_id
                 end
               ) new_members;
               Hashtbl.iter (fun a () ->
                 if not (Hashtbl.mem new_tbl a) then begin
                   if json then begin
                     print_string (Yojson.Safe.to_string
                       (`Assoc [ "event_type", `String "room.leave"
                               ; "room_id",    `String room_id
                               ; "alias",      `String a
                               ; "monitor_ts", `String (ts ()) ]));
                     print_newline ()
                   end else
                     Printf.printf "%s 👋  ROOM   %s left %s\n%!" (now_hms ()) a room_id
                 end
               ) prev_tbl;
               Hashtbl.reset prev_tbl;
               List.iter (fun a -> Hashtbl.replace prev_tbl a ()) new_members
             end
         | _ -> ()
        )
      done with End_of_file -> ())
  ) $ broker_root_opt $ alias_opt $ all_flag $ drains_flag $ sweeps_flag
    $ full_body_flag $ from_opt $ json_flag $ archive_flag $ include_self_flag

let monitor =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "monitor"
       ~doc:"Watch broker inboxes and emit formatted event notifications."
       ~man:[ `S "DESCRIPTION"
            ; `P "Watches the broker inbox directory with $(b,inotifywait) and emits \
                  one formatted line per new message (or event). Designed for Claude Code's \
                  Monitor tool — each output line becomes the notification summary."
            ; `P "Default behaviour: only show messages addressed to your alias \
                  ($(b,C2C_MCP_SESSION_ID)). New messages only — drains and sweeps \
                  suppressed unless $(b,--drains)/$(b,--sweeps) are set."
            ; `P "Burst deduplication: multiple messages from the same sender in one \
                  inbox write are collapsed to a single line with a count."
            ; `S "OUTPUT FORMAT"
            ; `P "[HH:MM:SS] ICON  TYPE  from→to  \"subject…\""
            ; `P "ICON: 📬 = addressed to you, 💬 = peer traffic (--all), \
                  📤 = drain (--drains), 🗑️ = sweep (--sweeps)"
            ; `S "EXAMPLES"
            ; `P "$(b,c2c monitor)  — watch your own inbox (default)"
            ; `P "$(b,c2c monitor --all)  — broad swarm monitor"
            ; `P "$(b,c2c monitor --all --drains --sweeps)  — everything"
            ; `P "$(b,c2c monitor --from coder1)  — only messages from coder1"
            ; `P "$(b,c2c monitor --full-body)  — include complete message body"
            ; `P "$(b,c2c monitor --json)  — JSON output for programmatic parsing"
            ; `P "$(b,c2c monitor --archive --all)  — watch append-only archive; \
                  no race with PostToolUse hook drains. Recommended for Claude Code."
            ; `P "In Claude Code: Monitor({command: \"c2c monitor --archive --all\", persistent: true})"
            ])
    monitor_cmd

(* --- subcommand: hook (PostToolUse inbox hook) ----------------------------- *)

let min_hook_runtime_ms = 100.0

let sleep_to_min_runtime start_time =
  (* Sleep so total runtime is at least min_hook_runtime_ms. Prevents Node.js
     ECHILD race: fast-exiting hooks are reaped by the kernel before Claude
     Code's waitpid(), which then fails with ECHILD. *)
  let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
  let sleep_s = max 0.0 ((min_hook_runtime_ms -. elapsed_ms) /. 1000.0) in
  if sleep_s > 0.0 then Unix.sleepf sleep_s

let hook_cmd =
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
      let messages = C2c_mcp.Broker.drain_inbox broker ~session_id in
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
              Buffer.add_string buf
                (let reply_via = Option.value m.reply_via ~default:"c2c_send" in
                 let role_attr = match lookup_role m.from_alias with
                   | Some r -> Printf.sprintf " role=\"%s\"" r
                   | None   -> ""
                 in
                 Printf.sprintf "<c2c event=\"message\" from=\"%s\" alias=\"%s\" source=\"broker\" reply_via=\"%s\" action_after=\"continue\"%s>%s</c2c>\n"
                   m.from_alias m.to_alias reply_via role_attr m.content))
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

let hook = Cmdliner.Cmd.v (Cmdliner.Cmd.info "hook" ~doc:"PostToolUse hook: drain inbox and emit messages.") hook_cmd

(* --- relay subcommands (shell-out to Python) -------------------------------- *)

let relay_serve_cmd =
  let listen =
    Cmdliner.Arg.(value & opt (some string) None & info [ "listen" ] ~docv:"HOST:PORT" ~doc:"Address to listen on (default: 127.0.0.1:7331).")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token for authentication.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let storage =
    Cmdliner.Arg.(value & opt (some string) None & info [ "storage" ] ~docv:"memory|sqlite" ~doc:"Storage backend (default: memory).")
  in
  let db_path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "db-path" ] ~docv:"PATH" ~doc:"SQLite database path (use with --storage sqlite).")
  in
  let gc_interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "gc-interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds (default: 300).")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let tls_cert =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-cert" ] ~docv:"PATH" ~doc:"PEM certificate file for TLS (enables HTTPS).")
  in
  let tls_key =
    Cmdliner.Arg.(value & opt (some string) None & info [ "tls-key" ] ~docv:"PATH" ~doc:"PEM private-key file for TLS (required with --tls-cert).")
  in
  let allowed_identities =
    Cmdliner.Arg.(value & opt (some string) None & info [ "allowed-identities" ] ~docv:"PATH"
      ~doc:"JSON file mapping {alias: identity_pk_b64} (L3/5). Listed aliases require a matching signed register; unlisted aliases stay first-mover-wins.")
  in
  let persist_dir =
    Cmdliner.Arg.(value & opt (some string) None & info [ "persist-dir" ] ~docv:"DIR"
      ~doc:"Directory for persistent room history storage (or C2C_RELAY_PERSIST_DIR). Room messages are written to <dir>/rooms/<room_id>/history.jsonl and loaded on startup.")
  in
  let remote_broker_ssh_target =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-ssh-target" ] ~docv:"USER@HOST"
      ~doc:"SSH target for remote broker polling (e.g. user@broker-host.example.com).")
  in
  let remote_broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-root" ] ~docv:"PATH"
      ~doc:"Remote broker root path (e.g. /home/user/.local/share/c2c). Used with --remote-broker-ssh-target.")
  in
  let remote_broker_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "remote-broker-id" ] ~docv:"ID"
      ~doc:"Identifier for this remote broker (default: \"default\"). Used with --remote-broker-ssh-target.")
  in
  let+ listen = listen
  and+ token = token
  and+ token_file = token_file
  and+ storage = storage
  and+ db_path = db_path
  and+ gc_interval = gc_interval
  and+ verbose = verbose
  and+ tls_cert = tls_cert
  and+ tls_key = tls_key
  and+ allowed_identities = allowed_identities
  and+ persist_dir = persist_dir
  and+ remote_broker_ssh_target = remote_broker_ssh_target
  and+ remote_broker_root = remote_broker_root
  and+ remote_broker_id = remote_broker_id in
  (* Parse listen address (default 127.0.0.1:7331) *)
  let host, port = match listen with
    | None -> ("127.0.0.1", 7331)
    | Some v ->
        (match String.split_on_char ':' v with
         | [host; port_str] ->
             (match int_of_string_opt port_str with
              | Some p -> (host, p)
              | None ->
                  Printf.eprintf "error: invalid port in --listen %S\n%!" v;
                  exit 1)
         | _ ->
             Printf.eprintf "error: --listen must be HOST:PORT (%S)\n%!" v;
             exit 1)
  in
  (* Resolve token: prefer direct value, fall back to file *)
  let token = match token with
    | Some t -> Some t
    | None ->
        (match token_file with
         | Some f ->
             (try Some (Stdlib.input_line (open_in f)) with
              | Sys_error msg ->
                  Printf.eprintf "error reading token file: %s\n%!" msg;
                  exit 1
              | End_of_file ->
                  Printf.eprintf "error: token file %S is empty\n%!" f;
                  exit 1)
         | None -> None)
  in
  (* Convert gc_interval from int option to float (0.0 = disabled) *)
  let gc_interval = match gc_interval with
    | Some i -> float_of_int i
    | None -> 0.0
  in
  (* Storage backend selection. InMemoryRelay is the default. SqliteRelay is
     planned (OCaml-native, replacing the deprecated Python fallback). *)
  let tls_cfg =
    match tls_cert, tls_key with
    | Some c, Some k -> Some (`Cert_key (c, k))
    | None, None -> None
    | Some _, None ->
        Printf.eprintf "error: --tls-cert requires --tls-key\n%!"; exit 1
    | None, Some _ ->
        Printf.eprintf "error: --tls-key requires --tls-cert\n%!"; exit 1
  in
  let allowlist = match allowed_identities with
  | None -> []
  | Some path ->
    (try
      let json = Yojson.Safe.from_file path in
      match json with
      | `Assoc pairs ->
        List.map (fun (alias, v) -> match v with
          | `String pk_b64 -> (alias, pk_b64)
          | _ ->
            Printf.eprintf "error: --allowed-identities entry for %S must be a string\n%!" alias;
            exit 1) pairs
      | _ ->
        Printf.eprintf "error: --allowed-identities file must be a JSON object { alias: pk_b64, ... }\n%!";
        exit 1
    with
    | Sys_error msg ->
      Printf.eprintf "error reading --allowed-identities: %s\n%!" msg; exit 1
    | Yojson.Json_error msg ->
      Printf.eprintf "error parsing --allowed-identities: %s\n%!" msg; exit 1)
in
let persist_dir = match persist_dir with
  | Some d -> Some d
  | None -> Sys.getenv_opt "C2C_RELAY_PERSIST_DIR"
in
Random.self_init ();
Version.banner ~role:"relay-server" ~git_hash:(Option.value (git_shorthash ()) ~default:"unknown");
Printf.eprintf "  listen=%s:%d\n%!" host port;
match storage with
| Some "sqlite" ->
    Printf.printf "storage: sqlite\n%!";
    (match persist_dir with
     | Some d -> Printf.eprintf "  persist-dir=%s\n%!" d
     | None -> Printf.eprintf "  persist-dir=%s\n%!" (Filename.concat (Sys.getcwd()) ""));
    (match db_path with
     | Some p -> Printf.eprintf "  db-path=%s\n%!" p
     | None -> ());
    let relay = Relay.SqliteRelay.create ?persist_dir () in
    let remote_polling_stop = match remote_broker_ssh_target, remote_broker_root with
      | Some ssh_target, Some broker_root ->
          let broker_id = Option.value remote_broker_id ~default:"default" in
          let broker = { Relay_remote_broker.id = broker_id; ssh_target; broker_root } in
          Printf.eprintf "  remote-broker: polling %s:%s\n%!" ssh_target broker_root;
          Some (Relay_remote_broker.start_polling ~broker ~interval:5.0
            ~on_fetch:(fun n -> Printf.eprintf "  [remote-broker] fetched %d messages\n%!" n))
      | _ -> None
    in
    let _ = remote_polling_stop in
    let module Server = Relay.Relay_server(Relay.SqliteRelay) in
    Lwt_main.run (Server.start_server ~host ~port ~relay ~token ~verbose ~gc_interval ?tls:tls_cfg ~allowlist ())
| _ ->
    Printf.printf "storage: memory\n%!";
    (match persist_dir with
     | Some d -> Printf.eprintf "  persist-dir=%s\n%!" d
     | None -> Printf.eprintf "  persist-dir=none (in-memory only)\n%!");
    let relay = Relay.InMemoryRelay.create ?persist_dir () in
    let remote_polling_stop = match remote_broker_ssh_target, remote_broker_root with
      | Some ssh_target, Some broker_root ->
          let broker_id = Option.value remote_broker_id ~default:"default" in
          let broker = { Relay_remote_broker.id = broker_id; ssh_target; broker_root } in
          Printf.eprintf "  remote-broker: polling %s:%s\n%!" ssh_target broker_root;
          Some (Relay_remote_broker.start_polling ~broker ~interval:5.0
            ~on_fetch:(fun n -> Printf.eprintf "  [remote-broker] fetched %d messages\n%!" n))
      | _ -> None
    in
    let _ = remote_polling_stop in
    let module Server = Relay.Relay_server(Relay.InMemoryRelay) in
    Lwt_main.run (Server.start_server ~host ~port ~relay ~token ~verbose ~gc_interval ?tls:tls_cfg ~allowlist ())

let relay_config_path () =
  match Sys.getenv_opt "C2C_RELAY_CONFIG" with
  | Some p when p <> "" -> p
  | _ ->
      (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
       | Some d when d <> "" -> Filename.concat d "relay.json"
       | _ ->
           let home = try Sys.getenv "HOME" with Not_found -> "." in
           Filename.concat home ".config/c2c/relay.json")

let read_file_trimmed path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    String.trim (really_input_string ic (in_channel_length ic)))

let load_relay_config () =
  let path = relay_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    try Yojson.Safe.from_file path
    with _ -> `Assoc []

let relay_config_string_field key =
  match load_relay_config () with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String v) when v <> "" -> Some v
       | _ -> None)
  | _ -> None

let relay_url_resolution_doc =
  "Relay server URL (or C2C_RELAY_URL or saved c2c relay setup config)."

let relay_token_resolution_doc =
  "Bearer token (or C2C_RELAY_TOKEN or saved c2c relay setup config)."

let relay_url_required_error =
  "error: --relay-url required (or set C2C_RELAY_URL or run c2c relay setup).\n"

let resolve_relay_url opt =
  match opt with
  | Some v when v <> "" -> Some v
  | _ ->
      (match Sys.getenv_opt "C2C_RELAY_URL" with
       | Some v when v <> "" -> Some v
       | _ -> relay_config_string_field "url")

let resolve_relay_token opt =
  match opt with
  | Some v when v <> "" -> Some v
  | _ ->
      (match Sys.getenv_opt "C2C_RELAY_TOKEN" with
       | Some v when v <> "" -> Some v
       | _ -> relay_config_string_field "token")

let relay_connect_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier (default: hostname-githash).")
  in
  let broker_root =
    Cmdliner.Arg.(value & opt (some string) None & info [ "broker-root" ] ~docv:"DIR" ~doc:"Broker root directory.")
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"Poll interval in seconds (default: 30).")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ broker_root = broker_root
  and+ interval = interval
  and+ once = once
  and+ verbose = verbose in
  let use_python = Sys.getenv_opt "C2C_RELAY_CONNECTOR_BACKEND" = Some "python" in
  let effective_broker_root = match broker_root with
    | Some b -> b
    | None -> resolve_broker_root ()
  in
  let effective_node_id = match node_id with
    | Some n -> n
    | None -> "unknown-node"
  in
  let effective_token = match token, token_file with
    | Some t, _ when t <> "" -> Some t
    | _, Some f -> (try Some (read_file_trimmed f) with _ -> None)
    | _, None -> resolve_relay_token None
  in
  let effective_interval = float_of_int (Option.value interval ~default:30) in
  let effective_identity_path = match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
    | Some p -> Some p
    | None ->
        (match Relay_identity.default_path () with
         | p when Sys.file_exists p -> Some p
         | _ -> None)
  in
  let effective_identity = match effective_identity_path with
    | Some p -> (match Relay_identity.load ~path:p () with | Ok id -> Some id | Error _ -> None)
    | None -> None
  in
  let effective_relay_url = Option.value (resolve_relay_url relay_url) ~default:"http://localhost:7331" in
  if not use_python then
    exit (C2c_relay_connector.start
      ~relay_url:effective_relay_url
      ~token:effective_token
      ~identity:effective_identity
      ~broker_root:effective_broker_root
      ~node_id:effective_node_id
      ~heartbeat_ttl:300.0
      ~interval:effective_interval
      ~verbose
      ~once)
  else
    match find_python_script "c2c_relay_connector.py" with
    | None ->
        Printf.eprintf "error: cannot find c2c_relay_connector.py. Run from inside the c2c git repo.\n%!";
        exit 1
    | Some script ->
        let args = [ "python3"; script; "--relay-url"; effective_relay_url ] in
        let args = match token, token_file with
          | Some v, _ when v <> "" -> args @ [ "--token"; v ]
          | _, Some _ -> args
          | _ -> (match resolve_relay_token None with None -> args | Some v -> args @ [ "--token"; v ])
        in
        let args = match token_file with None -> args | Some v -> args @ [ "--token-file"; v ] in
        let args = match effective_node_id with "unknown-node" -> args | v -> args @ [ "--node-id"; v ] in
        let args = args @ [ "--broker-root"; effective_broker_root ] in
        let args = match interval with None -> args | Some v -> args @ [ "--interval"; string_of_int v ] in
        let args = if once then args @ [ "--once" ] else args in
        let args = if verbose then args @ [ "--verbose" ] else args in
        let args = match Relay_identity.load () with
          | Ok _ -> args @ [ "--identity-path"; Relay_identity.default_path () ]
          | Error _ -> args
        in
        Unix.execvp "python3" (Array.of_list args)

let relay_setup_cmd =
  let url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "url" ] ~docv:"URL" ~doc:"Relay server URL.")
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:"Bearer token.")
  in
  let token_file =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token-file" ] ~docv:"PATH" ~doc:"Read bearer token from a file.")
  in
  let node_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "node-id" ] ~docv:"ID" ~doc:"Node identifier.")
  in
  let show =
    Cmdliner.Arg.(value & flag & info [ "show" ] ~doc:"Show current relay configuration.")
  in
  let+ url = url
  and+ token = token
  and+ token_file = token_file
  and+ node_id = node_id
  and+ show = show in
  let save path json =
    mkdir_p (Filename.dirname path);
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n')
  in
  let path = relay_config_path () in
  if show then begin
    let cfg = load_relay_config () in
    print_endline (Yojson.Safe.pretty_to_string cfg);
    exit 0
  end;
  let token_final =
    match token with
    | Some _ as v -> v
    | None ->
        (match token_file with
         | Some f -> (try Some (read_file_trimmed f) with _ -> None)
         | None -> None)
  in
  (* Merge: keep existing fields, override with provided ones. *)
  let existing = match load_relay_config () with `Assoc l -> l | _ -> [] in
  let set_field fields key = function
    | None -> fields
    | Some v ->
      (key, `String v) :: List.filter (fun (k, _) -> k <> key) fields
  in
  let merged =
    existing
    |> (fun f -> set_field f "url" url)
    |> (fun f -> set_field f "token" token_final)
    |> (fun f -> set_field f "node_id" node_id)
  in
  save path (`Assoc merged);
  Printf.printf "wrote %s\n" path;
  exit 0

let relay_status_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let+ relay_url = relay_url
  and+ token = token in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = Lwt_main.run (Relay.Relay_client.health client) in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

let relay_list_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let dead =
    Cmdliner.Arg.(value & flag & info [ "dead" ] ~doc:"Include dead sessions.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ dead = dead in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let result = (match Relay_identity.load () with
        | Ok id when not dead ->
            (* /list (no include_dead) is a peer route: requires Ed25519 in prod mode *)
            let alias = Option.value ~default:"anon" (env_auto_alias ()) in
            let auth = Relay_signed_ops.sign_request id ~alias ~meth:"GET" ~path:"/list" ~body_str:"" () in
            Lwt_main.run (Relay.Relay_client.list_peers_signed client ~auth_header:auth ())
        | _ ->
            (* /list?include_dead=1 is an admin route (Bearer only); also fallback when no identity *)
            Lwt_main.run (Relay.Relay_client.list_peers client ~include_dead:dead ())) in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

let relay_rooms_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"list|join|leave|send|history|invite|uninvite|set-visibility" ~doc:"Rooms subcommand.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let room =
    Cmdliner.Arg.(value & opt (some string) None & info [ "room" ] ~docv:"ROOM" ~doc:"Room id (required for history).")
  in
  let limit =
    Cmdliner.Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N" ~doc:"Max messages for history (default 50).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias (required for join/leave/send/invite/uninvite).")
  in
  let invitee_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "invitee-pk" ] ~docv:"PK" ~doc:"Base64url invitee identity public key (required for invite/uninvite).")
  in
  let visibility =
    Cmdliner.Arg.(value & opt (some string) None & info [ "visibility" ] ~docv:"public|invite_only" ~doc:"Room visibility (required for set-visibility).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"Message body for 'send' (joined with spaces).")
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ room = room
  and+ limit = limit
  and+ alias = alias
  and+ invitee_pk = invitee_pk
  and+ visibility = visibility
  and+ words = words in
  match subcmd with
  | "join" | "leave" ->
      let sign_ctx = if subcmd = "join" then Relay.room_join_sign_ctx
                     else Relay.room_leave_sign_ctx in
      (match resolve_relay_url relay_url, room, alias with
       | None, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _ ->
           Printf.eprintf "error: --room required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, None ->
           Printf.eprintf "error: --alias required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | Some url, Some room_id, Some alias ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result =
             match Relay_identity.load () with
             | Ok id ->
                 let p = Relay_signed_ops.sign_room_op id ~ctx:sign_ctx ~room_id ~alias in
                 let fn = if subcmd = "join" then Relay.Relay_client.join_room_signed
                          else Relay.Relay_client.leave_room_signed in
                 Lwt_main.run (fn client ~alias ~room_id
                   ~identity_pk:p.Relay_signed_ops.identity_pk_b64
                   ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
                   ~sig_:p.Relay_signed_ops.sig_b64)
             | Error _ ->
                 let fn = if subcmd = "join" then Relay.Relay_client.join_room
                          else Relay.Relay_client.leave_room in
                 Lwt_main.run (fn client ~alias ~room_id)
           in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "send" ->
      (match resolve_relay_url relay_url, room, alias, words with
       | None, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms send'.\n%!";
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms send'.\n%!";
           exit 1
       | _, _, _, [] ->
           Printf.eprintf "error: message body required for 'rooms send'.\n%!";
           exit 1
       | Some url, Some room_id, Some from_alias, ws ->
           let content = String.concat " " ws in
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           (* L4/4: sign the send with the local identity when available.
              Falls back to legacy unsigned path if no identity is on disk
              (spec soft-rollout). *)
           let result =
             match Relay_identity.load () with
             | Ok id ->
                 let envelope =
                   Relay_signed_ops.sign_send_room id
                     ~room_id ~from_alias ~content
                 in
                 Lwt_main.run
                   (Relay.Relay_client.send_room_signed client
                      ~from_alias ~room_id ~content ~envelope ())
             | Error _ ->
                 Lwt_main.run
                   (Relay.Relay_client.send_room client
                      ~from_alias ~room_id ~content ())
           in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "history" ->
      (match resolve_relay_url relay_url, room with
       | None, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None ->
           Printf.eprintf "error: --room required for 'rooms history'.\n%!";
           exit 1
       | Some url, Some room_id ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run (Relay.Relay_client.room_history client ~room_id ~limit ()) in
           (* L4/3 client verify: annotate each history entry with sig_ok. *)
           let annotate entry =
             match entry with
             | `Assoc fs ->
                 (match List.assoc_opt "envelope" fs with
                  | Some env ->
                      let get_s k = match List.assoc_opt k fs with
                        | Some (`String s) -> Some s | _ -> None in
                      (match get_s "room_id", get_s "from_alias", get_s "content" with
                       | Some r, Some fa, Some c ->
                           let ok = match Relay_signed_ops.verify_history_envelope
                             ~room_id:r ~from_alias:fa ~content:c env with
                             | Ok () -> `Bool true
                             | Error _ -> `Bool false in
                           `Assoc (("sig_ok", ok) :: fs)
                       | _ -> `Assoc (("sig_ok", `Null) :: fs))
                  | None -> `Assoc (("sig_ok", `Null) :: fs))
             | other -> other
           in
           let annotated = match result with
             | `Assoc fs ->
                 let fs' = List.map (fun (k, v) ->
                   if k = "history" then
                     match v with
                     | `List items -> (k, `List (List.map annotate items))
                     | other -> (k, other)
                   else (k, v)) fs in
                 `Assoc fs'
             | other -> other
           in
           print_endline (Yojson.Safe.pretty_to_string annotated);
           (match annotated with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "list" ->
      (match resolve_relay_url relay_url with
       | None ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | Some url ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run (Relay.Relay_client.list_rooms client) in
            print_endline (Yojson.Safe.pretty_to_string result);
            (match result with
             | `Assoc fields ->
                 (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
             | _ -> exit 1))
  | "invite" | "uninvite" ->
      (match resolve_relay_url relay_url, room, alias, invitee_pk with
       | None, _, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _, _ ->
           Printf.eprintf "error: --room required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, None, _ ->
           Printf.eprintf "error: --alias required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | _, _, _, None ->
           Printf.eprintf "error: --invitee-pk required for 'rooms %s'.\n%!" subcmd;
           exit 1
       | Some url, Some room_id, Some from_alias, Some invitee_pk_val ->
           let sign_ctx = if subcmd = "invite" then Relay.room_invite_sign_ctx
                          else Relay.room_uninvite_sign_ctx in
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result =
             match Relay_identity.load () with
             | Ok id ->
                 let p = Relay_signed_ops.sign_room_op id ~ctx:sign_ctx ~room_id ~alias:from_alias in
                 let fn = if subcmd = "invite"
                          then Relay.Relay_client.invite_room_signed
                          else Relay.Relay_client.uninvite_room_signed in
                 Lwt_main.run (fn client ~alias:from_alias ~room_id ~invitee_pk:invitee_pk_val
                   ~identity_pk:p.Relay_signed_ops.identity_pk_b64
                   ~ts:p.Relay_signed_ops.ts ~nonce:p.Relay_signed_ops.nonce
                   ~sig_:p.Relay_signed_ops.sig_b64)
             | Error _ ->
                 let fn = if subcmd = "invite"
                          then Relay.Relay_client.invite_room
                          else Relay.Relay_client.uninvite_room in
                 Lwt_main.run (fn client ~alias:from_alias ~room_id ~invitee_pk:invitee_pk_val)
           in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))
  | "set-visibility" ->
      (match resolve_relay_url relay_url, room, visibility with
       | None, _, _ ->
           Printf.eprintf "%s%!" relay_url_required_error;
           exit 1
       | _, None, _ ->
           Printf.eprintf "error: --room required for 'rooms set-visibility'.\n%!";
           exit 1
       | _, _, None ->
           Printf.eprintf "error: --visibility required for 'rooms set-visibility'.\n%!";
           exit 1
       | Some url, Some room_id, Some visibility_val ->
           let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
           let result = Lwt_main.run
             (Relay.Relay_client.set_room_visibility client ~room_id ~visibility:visibility_val)
           in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1))

(* c2c relay register — bind Ed25519 identity on the relay (§8.2) *)
let relay_register_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(required & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Alias to register.")
  in
  let+ relay_url = relay_url and+ token = token and+ alias = alias in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let node_id = Printf.sprintf "cli-%s" alias in
      let session_id = node_id in
      let result = (match Relay_identity.load () with
        | Ok id ->
            let p = Relay_signed_ops.sign_register id ~alias ~relay_url:url in
            Lwt_main.run (Relay.Relay_client.register_signed client
              ~node_id ~session_id ~alias ~client_type:"cli"
              ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
              ~sig_b64:p.Relay_signed_ops.sig_b64
              ~nonce:p.Relay_signed_ops.nonce
              ~ts:p.Relay_signed_ops.ts ())
        | Error _ ->
            Lwt_main.run (Relay.Relay_client.register client
              ~node_id ~session_id ~alias ~client_type:"cli" ~identity_pk:"" ()))
      in
      print_endline (Yojson.Safe.pretty_to_string result);
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
       | _ -> exit 1)

(* c2c relay dm — cross-host direct messages (§8.3) *)
let relay_dm_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"send|poll" ~doc:"DM subcommand: send or poll.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Your alias (required for poll).")
  in
  let words =
    Cmdliner.Arg.(value & pos_right 0 string [] & info [] ~docv:"WORDS" ~doc:"For send: <to-alias> <message...>")
  in
  let no_warn_substitution =
    Cmdliner.Arg.(value & flag & info [ "no-warn-substitution" ]
      ~doc:"Suppress the shell-substitution warning.")
  in
  let+ subcmd = subcmd and+ relay_url = relay_url and+ token = token
  and+ alias = alias and+ words = words
  and+ no_warn_substitution = no_warn_substitution in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      (match subcmd with
       | "send" ->
           (match words with
            | [] | [_] ->
                Printf.eprintf "error: usage: dm send <to-alias> <message...>\n%!";
                exit 1
            | to_alias :: msg_words ->
                let from_alias = match alias with
                  | Some a -> a
                  | None ->
                      Printf.eprintf "error: --alias required for dm send\n%!";
                      exit 1
                in
                let content = String.concat " " msg_words in
                (* Class E: warn when message body looks like an un-expanded shell
                   substitution pattern that the shell failed to expand. *)
                let _ =
                  if (not no_warn_substitution) && likes_shell_substitution content
                  then Printf.eprintf
                    "warning: message body appears to contain a shell substitution pattern \
                     (e.g. $(...) or `...`).\n\
                     If this was intended literally, re-send with --no-warn-substitution.\n\
                     To avoid this, quote the pattern: '$(date)' or escape the $.\n%!"
                  else ()
                in
                let body_str = Yojson.Safe.to_string (`Assoc [
                  ("from_alias", `String from_alias);
                  ("to_alias", `String to_alias);
                  ("content", `String content);
                ]) in
                let result = (match Relay_identity.load () with
                  | Ok id ->
                      let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                        ~meth:"POST" ~path:"/send" ~body_str () in
                      Lwt_main.run (Relay.Relay_client.send_signed client
                        ~from_alias ~to_alias ~content ~auth_header:auth ())
                  | Error _ ->
                      Lwt_main.run (Relay.Relay_client.send client
                        ~from_alias ~to_alias ~content ())) in
                print_endline (Yojson.Safe.pretty_to_string result);
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
                 | _ -> exit 1))
       | "poll" ->
           let from_alias = match alias with
             | Some a -> a
             | None ->
                 Printf.eprintf "error: --alias required for dm poll\n%!";
                 exit 1
           in
           let node_id = Printf.sprintf "cli-%s" from_alias in
           let body_str = Yojson.Safe.to_string (`Assoc [
             ("node_id", `String node_id);
             ("session_id", `String node_id);
           ]) in
           let result = (match Relay_identity.load () with
             | Ok id ->
                 let auth = Relay_signed_ops.sign_request id ~alias:from_alias
                   ~meth:"POST" ~path:"/poll_inbox" ~body_str () in
                 Lwt_main.run (Relay.Relay_client.poll_inbox_signed client
                   ~node_id ~session_id:node_id ~auth_header:auth)
             | Error _ ->
                 Lwt_main.run (Relay.Relay_client.poll_inbox client
                   ~node_id ~session_id:node_id)) in
           print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1)
       | other ->
           Printf.eprintf "error: unknown dm subcommand: %s\n%!" other;
           exit 1)

(* c2c relay mobile-pair — Issue a mobile pairing token via QR code flow (§S5a) *)
let relay_mobile_pair_cmd =
  let subcmd =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
       ~docv:"prepare|confirm|revoke" ~doc:"Mobile-pair subcommand: prepare issues a pairing token; confirm completes binding; revoke deletes a binding.")
  in
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ]
       ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ]
       ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let binding_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "binding-id" ]
       ~docv:"ID" ~doc:"Binding ID (for confirm).")
  in
  let phone_ed_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "phone-ed-pk" ]
       ~docv:"B64" ~doc:"Phone Ed25519 pubkey base64url (for confirm).")
  in
  let phone_x_pk =
    Cmdliner.Arg.(value & opt (some string) None & info [ "phone-x-pk" ]
       ~docv:"B64" ~doc:"Phone X25519 pubkey base64url (for confirm).")
  in
  let ttl =
    Cmdliner.Arg.(value & opt (some float) None & info [ "ttl" ]
       ~docv:"SECONDS" ~doc:"Token TTL in seconds (default: 300, max: 300).")
  in
  let user_code =
    Cmdliner.Arg.(value & opt (some string) None & info [ "user-code" ]
       ~docv:"CODE" ~doc:"User code from device-pair init (for claim).")
  in
  let+ subcmd = subcmd
  and+ relay_url = relay_url
  and+ token = token
  and+ binding_id = binding_id
  and+ phone_ed_pk = phone_ed_pk
  and+ phone_x_pk = phone_x_pk
  and+ ttl = ttl
  and+ user_code = user_code
  and+ json = json_flag in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      match subcmd with
      | "prepare" ->
          (match Relay_identity.load () with
           | Error _ ->
               Printf.eprintf "error: no identity.json found. Run 'c2c relay identity init' first.\n%!";
               exit 1
           | Ok id ->
               let bid = match binding_id with
                 | Some b -> b
                 | None -> Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
               in
               let now = Unix.gettimeofday () in
               let ttl_val = match ttl with Some t -> t | None -> 300.0 in
               let ttl_val = min ttl_val 300.0 in
               let issued_at = now in
               let expires_at = issued_at +. ttl_val in
               let nonce = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
               let machine_pk_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key
               in
               let blob = Relay_identity.canonical_msg ~ctx:Relay.mobile_pair_token_sign_ctx
                 [ bid; machine_pk_b64; string_of_float issued_at;
                   string_of_float expires_at; nonce ]
               in
               let sig_ = Relay_identity.sign id blob in
               let sig_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
               in
               let token_json = `Assoc [
                 "binding_id", `String bid;
                 "machine_ed25519_pubkey", `String machine_pk_b64;
                 "issued_at", `Float issued_at;
                 "expires_at", `Float expires_at;
                 "nonce", `String nonce;
                 "sig", `String sig_b64;
               ] in
               let token_b64 =
                 Yojson.Safe.to_string token_json |>
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
               in
               let result = Lwt_main.run
                 (Relay.Relay_client.mobile_pair_prepare client
                    ~machine_ed25519_pubkey:machine_pk_b64 ~token:token_b64)
               in
                if json then print_endline (Yojson.Safe.pretty_to_string result)
                else (
                  match List.assoc_opt "binding_id" (Yojson.Safe.Util.to_assoc result) with
                  | Some (`String bid) ->
                      let broker_root = resolve_broker_root () in
                      C2c_relay_connector.add_mobile_binding broker_root ~binding_id:bid;
                      Printf.printf "binding_id: %s\ntoken: %s\nnonce: %s\nttl: %.0f\n"
                        bid token_b64 nonce ttl_val;
                      Printf.printf "QR content: %s\n%!" token_b64
                  | _ -> ()
                );
                exit 0)
      | "confirm" ->
          let token_val = match token with Some t -> t | None -> "" in
          let ed_pk = phone_ed_pk in
          let x_pk = phone_x_pk in
          if ed_pk = None then (Printf.eprintf "error: --phone-ed-pk required for confirm.\n%!"; exit 1);
          if x_pk = None then (Printf.eprintf "error: --phone-x-pk required for confirm.\n%!"; exit 1);
          let ed_pk = Option.get ed_pk in
          let x_pk = Option.get x_pk in
          let result = Lwt_main.run
            (Relay.Relay_client.mobile_pair_confirm client
               ~token:token_val ~phone_ed25519_pubkey:ed_pk ~phone_x25519_pubkey:x_pk)
          in
          if json then print_endline (Yojson.Safe.pretty_to_string result)
          else print_endline (Yojson.Safe.pretty_to_string result);
           (match result with
            | `Assoc fields ->
                (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
            | _ -> exit 1)
      | "revoke" ->
          let bid = binding_id in
          if bid = None then (Printf.eprintf "error: --binding-id required for revoke.\n%!"; exit 1);
          let bid = Option.get bid in
          let result = Lwt_main.run
            (Relay.Relay_client.mobile_pair_revoke client ~binding_id:bid)
          in
          if json then print_endline (Yojson.Safe.pretty_to_string result)
          else print_endline (Yojson.Safe.pretty_to_string result);
          (match result with
           | `Assoc fields ->
               (match List.assoc_opt "ok" fields with Some (`Bool true) -> exit 0 | _ -> exit 1)
           | _ -> exit 1)
      | "init" ->
          (match Relay_identity.load () with
           | Error _ ->
               Printf.eprintf "error: no identity.json found. Run 'c2c relay identity init' first.\n%!";
               exit 1
           | Ok id ->
               let machine_pk_b64 =
                 Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key
               in
               let result = Lwt_main.run
                 (Relay.Relay_client.device_pair_init client ~machine_ed25519_pubkey:machine_pk_b64)
               in
               if json then print_endline (Yojson.Safe.pretty_to_string result)
               else (
                 match List.assoc_opt "user_code" (Yojson.Safe.Util.to_assoc result) with
                 | Some (`String uc) ->
                     let poll_interval = match List.assoc_opt "poll_interval" (Yojson.Safe.Util.to_assoc result) with
                       | Some (`Float f) -> Printf.sprintf "%.0f" f | _ -> "2" in
                     let expires_at = match List.assoc_opt "expires_at" (Yojson.Safe.Util.to_assoc result) with
                       | Some (`Float f) -> Printf.sprintf "%.0f" f | _ -> "0" in
                     Printf.printf "user_code: %s\npoll_interval: %ss\nexpires_at: %s\n" uc poll_interval expires_at;
                     Printf.eprintf "Enter this code on your phone at the relay URL.\n%!"
                 | _ -> ()
               );
               exit 0)
      | "claim" ->
          (match user_code with
           | None ->
               Printf.eprintf "error: --user-code required for claim.\n%!";
               exit 1
           | Some uc ->
               let rec poll_loop () =
                 let result = Lwt_main.run
                   (Relay.Relay_client.device_pair_poll client ~user_code:uc)
                 in
                 let status = match List.assoc_opt "status" (Yojson.Safe.Util.to_assoc result) with
                   | Some (`String s) -> s | _ -> "" in
                 if status = "claimed" then
                   (if json then print_endline (Yojson.Safe.pretty_to_string result)
                    else (
                      match List.assoc_opt "binding_id" (Yojson.Safe.Util.to_assoc result) with
                      | Some (`String bid) ->
                          Printf.printf "Pairing complete! binding_id: %s\n%!" bid
                      | _ -> Printf.eprintf "Pairing complete.\n%!"
                    );
                    exit 0)
                 else
                   (if not json then Printf.eprintf "Waiting... status: %s\n%!" status;
                    let () = ignore (Lwt_main.run (Lwt_unix.sleep 2.0)) in
                    poll_loop ())
               in
               poll_loop ())
      | other ->
          Printf.eprintf "error: unknown mobile-pair subcommand: %s (use prepare, confirm, revoke, init, or claim)\n%!" other;
          exit 1

let relay_gc_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let interval =
    Cmdliner.Arg.(value & opt (some int) None & info [ "interval" ] ~docv:"SECONDS" ~doc:"GC interval in seconds.")
  in
  let once =
    Cmdliner.Arg.(value & flag & info [ "once" ] ~doc:"Run once and exit.")
  in
  let verbose =
    Cmdliner.Arg.(value & flag & info [ "verbose"; "v" ] ~doc:"Enable verbose output.")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ interval = interval
  and+ once = once
  and+ verbose = verbose in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let run_once () =
        let open Lwt.Infix in
        Relay.Relay_client.gc client >>= fun result ->
        if verbose || once then print_endline (Yojson.Safe.pretty_to_string result);
        let ok = match result with
          | `Assoc fields ->
              (match List.assoc_opt "ok" fields with Some (`Bool true) -> true | _ -> false)
          | _ -> false
        in
        Lwt.return ok
      in
      if once then begin
        let ok = Lwt_main.run (run_once ()) in
        exit (if ok then 0 else 1)
      end else begin
        let sleep_s = match interval with Some s -> float_of_int s | None -> 30.0 in
        let rec loop () =
          let open Lwt.Infix in
          run_once () >>= fun _ -> Lwt_unix.sleep sleep_s >>= loop
        in
        Lwt_main.run (loop ())
      end

(* c2c relay poll-inbox — poll a remote relay's /remote_inbox/<session_id> endpoint.
   Used by a remote node to receive messages ferried through the relay from a remote broker. *)
let relay_poll_inbox_cmd =
  let relay_url =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL" ~doc:relay_url_resolution_doc)
  in
  let token =
    Cmdliner.Arg.(value & opt (some string) None & info [ "token" ] ~docv:"TOKEN" ~doc:relay_token_resolution_doc)
  in
  let session_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID" ~doc:"Session ID to poll (required).")
  in
  let+ relay_url = relay_url
  and+ token = token
  and+ session_id = session_id in
  match resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" relay_url_required_error;
      exit 1
  | Some url ->
      let session_id = match session_id with
        | Some s -> s
        | None ->
            Printf.eprintf "error: --session-id required.\n%!";
            exit 1
      in
      let client = Relay.Relay_client.make ?token:(resolve_relay_token token) url in
      let path = "/remote_inbox/" ^ session_id in
      let result = Lwt_main.run (Relay.Relay_client.request client ~meth:`GET ~path ()) in
      (match result with
       | `Assoc fields ->
           (match List.assoc_opt "messages" fields with
            | Some (`List msgs) ->
                if msgs = [] then exit 0
                else begin
                  List.iter (fun msg ->
                    match msg with
                    | `Assoc msg_fields ->
                        let from_alias = match List.assoc_opt "from_alias" msg_fields with Some (`String s) -> s | _ -> "?" in
                        let content = match List.assoc_opt "content" msg_fields with Some (`String s) -> s | _ -> "" in
                        let ts = match List.assoc_opt "ts" msg_fields with Some (`Float f) -> string_of_float f | _ -> "?" in
                        Printf.printf "[%s] %s: %s\n%!" ts from_alias content
                    | _ -> ())
                    msgs;
                  exit 0
                end
            | _ ->
                Printf.eprintf "error: unexpected response shape: %s\n%!" (Yojson.Safe.to_string result);
                exit 1)
       | _ ->
           Printf.eprintf "error: unexpected response: %s\n%!" (Yojson.Safe.to_string result);
           exit 1)

(* --- relay identity (Layer 3 slice 6) ------------------------------------- *)
(* Wraps Relay_identity (ocaml/relay_identity.ml) with init/show/fingerprint
   subcommands for managing ~/.config/c2c/identity.json. See
   docs/c2c-research/relay-peer-identity-spec.md §8. *)

let relay_identity_init_cmd =
  let alias_hint =
    Cmdliner.Arg.(value & opt string "" & info [ "alias-hint" ] ~docv:"HINT"
      ~doc:"Informational alias label stored in identity.json (not authoritative).")
  in
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force" ]
      ~doc:"Overwrite an existing identity file without prompting.")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ alias_hint = alias_hint
  and+ path = path
  and+ force = force
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  if (not force) && Sys.file_exists target then begin
    if json then
      print_endline (Printf.sprintf
        {|{"ok":false,"error":"identity exists","path":%S,"hint":"pass --force to overwrite"}|}
        target)
    else
      Printf.eprintf
        "error: %s already exists. Pass --force to overwrite.\n%!" target;
    exit 1
  end;
  let id = Relay_identity.generate ~alias_hint () in
  match Relay_identity.save ~path:target id with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf
          {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok () ->
      if json then
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
          ]))
      else begin
        Printf.printf "identity written to %s\n" target;
        Printf.printf "  fingerprint: %s\n" id.fingerprint;
        if id.alias_hint <> "" then
          Printf.printf "  alias_hint:  %s\n" id.alias_hint;
        Printf.printf "  created_at:  %s\n" id.created_at
      end

let relay_identity_show_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let json = Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Emit JSON output.") in
  let+ path = path
  and+ json = json in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg ->
      if json then
        print_endline (Printf.sprintf {|{"ok":false,"error":%S}|} msg)
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok id ->
      if json then
        (* Never emit the private_key on show — only public metadata. *)
        print_endline (Yojson.Safe.to_string
          (`Assoc [
            "ok", `Bool true;
            "path", `String target;
            "fingerprint", `String id.fingerprint;
            "alias_hint", `String id.alias_hint;
            "created_at", `String id.created_at;
            "alg", `String id.alg;
            "version", `Int id.version;
          ]))
      else begin
        Printf.printf "path:        %s\n" target;
        Printf.printf "fingerprint: %s\n" id.fingerprint;
        Printf.printf "alg:         %s\n" id.alg;
        if id.alias_hint <> "" then
          Printf.printf "alias_hint:  %s\n" id.alias_hint;
        Printf.printf "created_at:  %s\n" id.created_at
      end

let relay_identity_fingerprint_cmd =
  let path =
    Cmdliner.Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH"
      ~doc:"Override identity file path (default: ~/.config/c2c/identity.json).")
  in
  let+ path = path in
  let target = match path with Some p -> p | None -> Relay_identity.default_path () in
  match Relay_identity.load ~path:target () with
  | Error msg -> Printf.eprintf "error: %s\n%!" msg; exit 1
  | Ok id -> print_endline id.fingerprint

let relay_identity_init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init" ~doc:"Generate a new Ed25519 identity keypair.")
    relay_identity_init_cmd

let relay_identity_show =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "show" ~doc:"Print identity metadata (fingerprint, alias_hint, created_at).")
    relay_identity_show_cmd

let relay_identity_fingerprint =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "fingerprint" ~doc:"Print just the SHA256 fingerprint, one line.")
    relay_identity_fingerprint_cmd

let relay_identity =
  Cmdliner.Cmd.group
    ~default:relay_identity_show_cmd
    (Cmdliner.Cmd.info "identity"
      ~doc:"Manage the local Ed25519 identity used for peer authentication.")
    [ relay_identity_init; relay_identity_show; relay_identity_fingerprint ]

let relay_serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Start the relay server.") relay_serve_cmd
let relay_connect = Cmdliner.Cmd.v (Cmdliner.Cmd.info "connect" ~doc:"Run the relay connector.") relay_connect_cmd
let relay_setup = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setup" ~doc:"Configure relay connection.") relay_setup_cmd
let relay_status = Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show relay health.") relay_status_cmd
let relay_list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List relay peers.") relay_list_cmd
let relay_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "rooms" ~doc:"Manage relay rooms.") relay_rooms_cmd
 let relay_gc = Cmdliner.Cmd.v (Cmdliner.Cmd.info "gc" ~doc:"Run relay garbage collection.") relay_gc_cmd
 let relay_poll_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "poll-inbox" ~doc:"Poll a remote relay's /remote_inbox/<session_id> endpoint.") relay_poll_inbox_cmd
 let relay_register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register Ed25519 identity on the relay.") relay_register_cmd
 let relay_dm = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dm" ~doc:"Send or receive cross-host direct messages.") relay_dm_cmd
 let relay_mobile_pair = Cmdliner.Cmd.v (Cmdliner.Cmd.info "mobile-pair" ~doc:"Mobile device pairing via QR token flow (§S5a).") relay_mobile_pair_cmd

 let relay_group =
  Cmdliner.Cmd.group
    ~default:relay_status_cmd
    (Cmdliner.Cmd.info "relay"
       ~doc:"Cross-machine relay: serve, connect, setup, status, list, rooms, gc, identity, register, dm, mobile-pair."
       ~man:[ `S "DESCRIPTION"
            ; `P "The relay connects brokers across machines. Use $(b,c2c relay setup) once, then $(b,c2c relay connect) to keep your broker connected to the relay."
            ; `P "Common workflow: run $(b,c2c relay setup) once, then $(b,c2c relay connect) to keep your broker connected to the relay."
            ])
    [ relay_serve; relay_connect; relay_setup; relay_status; relay_list; relay_rooms; relay_gc; relay_poll_inbox; relay_identity; relay_register; relay_dm; relay_mobile_pair ]

(* --- skills helpers -------------------------------------------------------- *)

let skills_dir () = Sys.getcwd () // ".opencode" // "skills"

let list_subdirs dir =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun name ->
      let path = dir // name in
      try Sys.is_directory path with _ -> false)
  with _ -> []

let read_first_lines path n =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let lines = ref [] in
      for _i = 1 to n do
        match input_line ic with
        | line -> lines := line :: !lines
        | exception End_of_file -> ()
      done;
      List.rev !lines)
  with _ -> []

let parse_skill_frontmatter dir name =
  let skill_md = dir // name // "SKILL.md" in
  let lines = read_first_lines skill_md 10 in
  let name_ref = ref None in
  let desc_ref = ref None in
  let strip_quotes s =
    let len = String.length s in
    if len >= 2 && s.[0] = '"' && s.[len - 1] = '"'
    then String.sub s 1 (len - 2)
    else s
  in
  let in_frontmatter = ref false in
  List.iter (fun line ->
    let line = String.trim line in
    if line = "---" then in_frontmatter := not !in_frontmatter
    else if !in_frontmatter then
      if Str.string_match (Str.regexp "^name:[ ]*\\([^ ].*\\)$") line 0
      then name_ref := Some (Str.matched_group 1 line)
      else if Str.string_match (Str.regexp "^description:[ ]*\\(\".*\"\\)$") line 0
      then desc_ref := Some (strip_quotes (Str.matched_group 1 line))
      else if Str.string_match (Str.regexp "^description:[ ]*\\([^ ].*\\)$") line 0
      then desc_ref := Some (Str.matched_group 1 line)
  ) lines;
  (!name_ref, !desc_ref)

let skills_list_cmd =
  let json = json_flag in
  let+ json = json in
  let dir = skills_dir () in
  let names = list_subdirs dir in
  if json then
    let skills = List.map (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      `Assoc ([ ("id", `String name) ]
        @ (match parsed_name with Some n -> [ ("name", `String n) ] | None -> [])
        @ (match desc with Some d -> [ ("description", `String d) ] | None -> []))
    ) names in
    print_json (`List skills)
  else
    List.iter (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      Printf.printf "%s\n" name;
      (match parsed_name with Some n -> Printf.printf "  name: %s\n" n | None -> ());
      (match desc with Some d -> Printf.printf "  description: %s\n" d | None -> ());
      print_newline ()
    ) names

let skills_serve_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"SKILL" ~doc:"Skill name (directory name under .opencode/skills/)")
  in
  let+ name = name in
  let dir = skills_dir () in
  let skill_md = dir // name // "SKILL.md" in
  try
    let content = read_first_lines skill_md 10000 in
    List.iter (fun line -> Printf.printf "%s\n" line) content
  with _ ->
    Printf.eprintf "error: skill '%s' not found in %s\n%!" name dir;
    exit 1

let skills_group =
  Cmdliner.Cmd.group
    ~default:skills_list_cmd
    (Cmdliner.Cmd.info "skills" ~doc:"List and serve c2c swarm skills.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all available skills.") skills_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Print a skill's full content.") skills_serve_cmd ]

(* --- main entry point ----------------------------------------------------- *)

let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a registered peer alias.") send_cmd
let list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List registered C2C peers.") list_cmd
let whoami = Cmdliner.Cmd.v (Cmdliner.Cmd.info "whoami" ~doc:"Show current c2c identity.") whoami_cmd
let set_compact = Cmdliner.Cmd.v (Cmdliner.Cmd.info "set-compact" ~doc:"Mark this session as compacting (context summarization in progress).") set_compact_cmd
let clear_compact = Cmdliner.Cmd.v (Cmdliner.Cmd.info "clear-compact" ~doc:"Clear the compacting flag for this session.") clear_compact_cmd
let open_pending_reply = Cmdliner.Cmd.v (Cmdliner.Cmd.info "open-pending-reply" ~doc:"Open a pending permission reply slot before sending a permission request to supervisors.") open_pending_reply_cmd
let check_pending_reply = Cmdliner.Cmd.v (Cmdliner.Cmd.info "check-pending-reply" ~doc:"Check if a permission reply is valid (called when receiving a reply).") check_pending_reply_cmd
let poll_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "poll-inbox" ~doc:"Drain (or peek at) your inbox.") poll_inbox_cmd
(* peek-inbox is an alias for poll-inbox --peek *)
let peek_inbox_cmd =
  let session_id_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID"
      ~doc:"Session ID whose inbox to peek. Overrides C2C_MCP_SESSION_ID.")
  in
  let+ json = json_flag
  and+ session_id_opt = session_id_flag in
  mcp_nudge_if_needed ~cmd:"peek-inbox";
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id = match session_id_opt with
    | Some sid -> sid
    | None -> resolve_session_id_for_inbox broker
  in
  let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map
             (fun (m : C2c_mcp.message) ->
               `Assoc
                 [ ("from_alias", `String m.from_alias)
                 ; ("to_alias", `String m.to_alias)
                 ; ("content", `String m.content)
                 ; ("ts", `Float m.ts)
                 ])
             messages))
  | Human ->
      if messages = [] then
        Printf.printf "(no messages)\n"
      else
        List.iter
          (fun (m : C2c_mcp.message) -> Printf.printf "[%s] %s\n" m.from_alias m.content)
          messages

(* --- subcommand: setcap --------------------------------------------------- *)

let setcap_cmd =
  let apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
                    ~doc:"Exec `sudo setcap cap_sys_ptrace=ep <interp>` (needs tty + sudo).")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable output.")
  in
  let+ apply = apply
  and+ json = json in
  match find_python_script "c2c_setcap.py" with
  | None ->
      Printf.eprintf "error: cannot find c2c_setcap.py. Run from inside the c2c git repo.\n%!";
      exit 1
  | Some script ->
      let args = [ "python3"; script ] in
      let args = if apply then args @ [ "--apply" ] else args in
      let args = if json then args @ [ "--json" ] else args in
      Unix.execvp "python3" (Array.of_list args)

let setcap = Cmdliner.Cmd.v (Cmdliner.Cmd.info "setcap"
                               ~doc:"Grant CAP_SYS_PTRACE to the c2c Python interpreter (only needed for Codex PTY notify daemon; OpenCode + Kimi use non-PTY delivery).")
               setcap_cmd

let peek_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "peek-inbox" ~doc:"Peek at your inbox without draining.") peek_inbox_cmd
let send_all = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.") send_all_cmd
let sweep = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sweep" ~doc:"Remove dead registrations and orphan inboxes.") sweep_cmd
let history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show archived inbox messages.") history_cmd
let health = Cmdliner.Cmd.v (Cmdliner.Cmd.info "health" ~doc:"Show broker health diagnostics.") health_cmd
let register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register an alias for the current session.") register_cmd
let tail_log = Cmdliner.Cmd.v (Cmdliner.Cmd.info "tail-log" ~doc:"Show recent broker RPC log entries.") tail_log_cmd
let server_info = Cmdliner.Cmd.v (Cmdliner.Cmd.info "server-info" ~doc:"Show c2c client version and feature flags.") server_info_cmd
let my_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "my-rooms" ~doc:"List rooms you are a member of.") my_rooms_cmd
let dead_letter = Cmdliner.Cmd.v (Cmdliner.Cmd.info "dead-letter" ~doc:"Show dead-letter entries.") dead_letter_cmd
let prune_rooms = Cmdliner.Cmd.v (Cmdliner.Cmd.info "prune-rooms" ~doc:"Evict dead members from all rooms.") prune_rooms_cmd
let get_tmux_location = Cmdliner.Cmd.v (Cmdliner.Cmd.info "get-tmux-location" ~doc:"Print the current tmux pane address (session:window.pane).") get_tmux_location_cmd

(* --- subcommand: smoke-test ----------------------------------------------- *)

let smoke_test_cmd =
  let+ json = json_flag in
  let tmp_dir = Filename.temp_file "c2c-smoke-" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let broker_root = tmp_dir // "broker" in
  Unix.mkdir broker_root 0o755;
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let session_a = "smoke-session-a" in
  let session_b = "smoke-session-b" in
  let alias_a = "smoke-a" in
  let alias_b = "smoke-b" in
  let pid = Some (Unix.getpid ()) in
  let pid_start_time = C2c_mcp.Broker.capture_pid_start_time pid in
  C2c_mcp.Broker.register broker ~session_id:session_a ~alias:alias_a ~pid ~pid_start_time ();
  C2c_mcp.Broker.register broker ~session_id:session_b ~alias:alias_b ~pid ~pid_start_time ();
  let marker =
    Printf.sprintf "c2c-smoke-%d-%d"
      (Unix.gettimeofday () |> int_of_float)
      (Random.int 100000)
  in
  C2c_mcp.Broker.enqueue_message broker ~from_alias:alias_a ~to_alias:alias_b ~content:marker ();
  let messages = C2c_mcp.Broker.drain_inbox broker ~session_id:session_b in
  let ok = List.exists (fun (m : C2c_mcp.message) -> m.content = marker) messages in
  let rec rm_rf path =
    if Sys.is_directory path then (
      let entries = Sys.readdir path in
      Array.iter (fun e -> rm_rf (path // e)) entries;
      Unix.rmdir path)
    else Sys.remove path
  in
  rm_rf tmp_dir;
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`Assoc [ ("ok", `Bool ok); ("marker", `String marker) ])
  | Human ->
      if ok then
        Printf.printf "smoke-test passed (marker: %s)\n" marker
      else (
        Printf.eprintf "smoke-test failed: marker not received (marker: %s)\n%!" marker;
        exit 1)

let smoke_test = Cmdliner.Cmd.v (Cmdliner.Cmd.info "smoke-test" ~doc:"Run an end-to-end broker smoke test.") smoke_test_cmd

(* Phase 1 split: install/setup code moved to c2c_setup.ml *)

(* --- repo config helpers (also used by init_cmd + repo subcommand) ------- *)

let repo_config_path () =
  Filename.concat (Sys.getcwd ()) ".c2c" // "repo.json"

let load_repo_config () =
  let path = repo_config_path () in
  if not (Sys.file_exists path) then `Assoc []
  else
    (try Yojson.Safe.from_file path
     with _ -> `Assoc [])

let save_repo_config json =
  let path = repo_config_path () in
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error _ -> ());
  C2c_setup.json_write_file path json

let valid_strategies = [ "first-alive"; "round-robin"; "broadcast" ]

(* --- subcommand: init ---------------------------------------------------- *)

let detect_client () =
   (match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some sid ->
        List.find_opt (fun c ->
          let cl = String.length c in
          String.length sid >= cl && String.sub sid 0 cl = c) C2c_setup.detect_client_prefixes
    | None -> None)
  |> (function
      | Some _ as v -> v
      | None ->
          let has_bin name =
            let path = try Sys.getenv "PATH" with Not_found -> "" in
            List.exists (fun d -> Sys.file_exists (d // name))
              (String.split_on_char ':' path)
          in
          List.find_opt has_bin [ "opencode"; "claude"; "codex"; "kimi" ])

let init_cmd =
  let open Cmdliner in
  let client_opt =
    Arg.(value & opt (some string) None & info ["client"; "c"] ~docv:"CLIENT"
           ~doc:(Printf.sprintf "Client to configure: %s. Auto-detected when omitted." C2c_setup.init_configurable_client_list))
  in
  let alias_opt_arg =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Alias to register under. Auto-generated when omitted.")
  in
  let room_arg =
    Arg.(value & opt string "swarm-lounge" & info ["room"; "r"] ~docv:"ROOM"
           ~doc:"Room to join on init (default: swarm-lounge). Pass empty string to skip.")
  in
  let no_setup =
    Arg.(value & flag & info ["no-setup"]
           ~doc:"Skip client MCP setup; only register and join room.")
  in
  let supervisor_arg =
    Arg.(value & opt (some string) None & info ["supervisor"; "S"] ~docv:"ALIAS[,ALIAS2,...]"
           ~doc:"Permission supervisor alias(es). Written to .c2c/repo.json. Equivalent to c2c repo set supervisor.")
  in
  let supervisor_strategy_arg =
    Arg.(value & opt (some string) None & info ["supervisor-strategy"] ~docv:"STRATEGY"
           ~doc:"Supervisor dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let relay_url_arg =
    Arg.(value & opt (some string) None & info ["relay"]
           ~docv:"URL" ~doc:"Configure and register with a relay at this URL. Prints connector start command as next step.")
  in
  let+ json = json_flag
  and+ client_opt = client_opt
  and+ alias_opt = alias_opt_arg
  and+ room = room_arg
  and+ no_setup = no_setup
  and+ supervisor_opt = supervisor_arg
  and+ supervisor_strategy_opt = supervisor_strategy_arg
  and+ relay_url = relay_url_arg in
  let output_mode = if json then Json else Human in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in

  let client_resolved =
    match client_opt with
    | Some c -> Some c
    | None -> detect_client ()
  in

  let setup_result =
    if no_setup then `Skipped
    else match client_resolved with
      | None ->
          (match output_mode with
           | Human ->
               Printf.printf "No client detected. Specify one with --client:\n";
               Printf.printf "  c2c init --client opencode\n";
               Printf.printf "  c2c init --client claude\n";
               Printf.printf "  c2c init --client codex\n";
               Printf.printf "  c2c init --client codex-headless\n"
           | Json -> ());
          `No_client
      | Some client ->
          (try
             C2c_setup.do_install_client ~output_mode ~dry_run:false ~client ~alias_opt ~broker_root_opt:(Some root) ~target_dir_opt:None ~force:false ();
             `Ok (C2c_setup.canonical_install_client client)
           with e -> `Error (Printexc.to_string e))
  in

  let session_id =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some s when String.trim s <> "" -> s
    | _ -> C2c_setup.generate_session_id ()
  in
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        let a = match client_resolved with
          | Some c -> C2c_setup.default_alias_for_client c
          | None -> C2c_setup.generate_alias ()
        in
        Printf.eprintf "[c2c register] no --alias given; auto-picked alias=%s. Pass --alias NAME to override.\n%!" a;
        a
  in
  (* Ensure Ed25519 identity exists — idempotent, safe to run always. *)
  let _identity_init_rc = Sys.command "c2c relay identity init 2>/dev/null" in
  ignore _identity_init_rc;

  C2c_mcp.Broker.register broker ~session_id ~alias ~pid:None ~pid_start_time:None ~client_type:(env_client_type ()) ();

  let room_result =
    if String.trim room = "" then `Skipped
    else
      (try
         let (_ : C2c_mcp.room_member list) =
           C2c_mcp.Broker.join_room broker ~session_id ~alias ~room_id:room
         in
         `Joined room
       with Invalid_argument msg -> `Error msg)
  in

  let supervisor_result =
    match supervisor_opt with
    | None -> `Skipped
    | Some sup_str ->
        let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' sup_str) in
        if aliases = [] then `Error "empty supervisor list"
        else begin
          (match supervisor_strategy_opt with
           | Some s when not (List.mem s valid_strategies) ->
               Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!"
                 s (String.concat ", " valid_strategies);
               exit 1
           | _ -> ());
          let config = load_repo_config () in
          let fields = match config with `Assoc f -> f | _ -> [] in
          let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
          let fields' = ref
            (("supervisors", supervisor_val)
             :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors"
                                           && k <> "supervisor_strategy") fields)
          in
          (match supervisor_strategy_opt with
           | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
           | None -> ());
          save_repo_config (`Assoc !fields');
          `Set (aliases, supervisor_strategy_opt)
        end
  in

  (* Relay attachment: setup + register when --relay URL is given. *)
  let relay_result = match relay_url with
    | None -> `Skipped
    | Some rurl ->
        (try
           (* Save relay config: same path resolution as relay_setup_cmd. *)
           let config_path =
             match Sys.getenv_opt "C2C_RELAY_CONFIG" with
             | Some p when p <> "" -> p
             | _ ->
                 (match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
                  | Some d when d <> "" -> Filename.concat d "relay.json"
                  | _ ->
                      let home = try Sys.getenv "HOME" with Not_found -> "." in
                      Filename.concat home ".config/c2c/relay.json")
           in
           let existing = try
             let ic = open_in config_path in
             Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
               Yojson.Safe.from_channel ic)
           with _ -> `Assoc [] in
           let set_field fields key v =
             (key, `String v) :: List.filter (fun (k, _) -> k <> key) fields
           in
           let merged = match existing with
             | `Assoc l -> set_field l "url" rurl
             | _ -> [("url", `String rurl)]
           in
           let oc = open_out config_path in
           Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
             output_string oc (Yojson.Safe.pretty_to_string (`Assoc merged)));
           Printf.printf "  relay:     saved config\n";
           (* Register with relay. *)
           (match Relay_identity.load () with
            | Ok id ->
                let client = Relay.Relay_client.make rurl in
                let node_id = Printf.sprintf "cli-%s" alias in
                let session_id = node_id in
                let p = Relay_signed_ops.sign_register id ~alias ~relay_url:rurl in
                let result = Lwt_main.run (Relay.Relay_client.register_signed client
                  ~node_id ~session_id ~alias ~client_type:"cli"
                  ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
                  ~sig_b64:p.Relay_signed_ops.sig_b64
                  ~nonce:p.Relay_signed_ops.nonce
                  ~ts:p.Relay_signed_ops.ts ()) in
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with
                      | Some (`Bool true) -> Printf.printf "  relay:     registered %s\n" alias
                      | _ -> Printf.printf "  relay:     registration returned non-ok\n")
                 | _ -> Printf.printf "  relay:     unexpected response\n")
            | Error _ ->
                (* Unauthenticated registration. *)
                let client = Relay.Relay_client.make rurl in
                let node_id = Printf.sprintf "cli-%s" alias in
                let session_id = node_id in
                let result = Lwt_main.run (Relay.Relay_client.register client
                  ~node_id ~session_id ~alias ~client_type:"cli" ~identity_pk:"" ()) in
                (match result with
                 | `Assoc fields ->
                     (match List.assoc_opt "ok" fields with
                      | Some (`Bool true) -> Printf.printf "  relay:     registered %s (unauthenticated)\n" alias
                      | _ -> Printf.printf "  relay:     registration returned non-ok\n")
                 | _ -> Printf.printf "  relay:     unexpected response\n"));
           `Ok rurl
         with e -> `Error (Printexc.to_string e))
  in

  (match output_mode with
   | Json ->
       let setup_json = match setup_result with
         | `Ok c -> `String (Printf.sprintf "configured %s" c)
         | `Skipped -> `String "skipped"
         | `No_client -> `String "no client detected"
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
       let room_json = match room_result with
         | `Joined r -> `String r
         | `Skipped -> `Null
         | `Error e -> `String (Printf.sprintf "error: %s" e)
       in
        let supervisor_json = match supervisor_result with
          | `Set (aliases, strat) ->
              `Assoc ([ ("ok", `Bool true); ("aliases", `List (List.map (fun a -> `String a) aliases)) ]
                      @ (match strat with Some s -> [("strategy", `String s)] | None -> []))
          | `Skipped -> `Null
          | `Error e -> `Assoc [("ok", `Bool false); ("error", `String e)]
        in
        let relay_json = match relay_result with
          | `Ok url -> `Assoc [("ok", `Bool true); ("relay_url", `String url)]
          | `Skipped -> `Null
          | `Error e -> `Assoc [("ok", `Bool false); ("error", `String e)]
        in
        print_json (`Assoc
          [ ("ok", `Bool true)
          ; ("session_id", `String session_id)
          ; ("alias", `String alias)
          ; ("broker_root", `String root)
          ; ("setup", setup_json)
          ; ("room", room_json)
          ; ("supervisor", supervisor_json)
          ; ("relay", relay_json)
         ])
   | Human ->
       Printf.printf "\nc2c init complete!\n";
       Printf.printf "  session:  %s\n" session_id;
       Printf.printf "  alias:    %s\n" alias;
       Printf.printf "  broker:   %s\n" root;
       (match setup_result with
        | `Ok c -> Printf.printf "  setup:    %s configured\n" c
        | `Skipped -> ()
        | `No_client -> Printf.printf "  setup:    skipped (no client detected)\n"
        | `Error e -> Printf.printf "  setup:    error — %s\n" e);
       (match room_result with
        | `Joined r -> Printf.printf "  room:     joined #%s\n" r
        | `Skipped -> ()
        | `Error e -> Printf.printf "  room:     error joining — %s\n" e);
         (match supervisor_result with
          | `Set (aliases, strat) ->
              Printf.printf "  supervisor: %s%s\n" (String.concat ", " aliases)
                (match strat with Some s -> Printf.sprintf " (strategy: %s)" s | None -> "")
          | `Skipped -> ()
          | `Error e -> Printf.printf "  supervisor: error — %s\n" e);

         (match relay_result with
          | `Ok rurl ->
              Printf.printf "\nRelay attached. Start the connector with:\n";
              Printf.printf "  c2c relay connect --relay-url %s\n" rurl
          | `Skipped -> ()
          | `Error e -> Printf.printf "  relay:     error — %s\n" e);

         Printf.printf "\nYou're ready! Try:\n";
        Printf.printf "  c2c list              — see peers\n";
        Printf.printf "  c2c send ALIAS MSG    — send a message\n";
        Printf.printf "  c2c poll-inbox        — check your inbox\n";
        Printf.printf "  c2c send-room %s MSG  — chat in the room\n" room)

let completion_cmd =
  let shell_arg =
    Cmdliner.Arg.(value & opt (some string) None & info [ "shell" ] ~docv:"SHELL"
      ~doc:"Shell to generate completions for: bash, zsh, or pwsh. Detects from $SHELL if omitted.")
  in
  let detect_shell () =
    try
      let shell = Sys.getenv "SHELL" in
      if Filename.check_suffix shell "bash" then Some "bash"
      else if Filename.check_suffix shell "zsh" then Some "zsh"
      else if Filename.check_suffix shell "pwsh" || Filename.check_suffix shell "powershell" then Some "pwsh"
      else None
    with Not_found -> None
  in
  let cmdliner_bin () =
    try
      let opam_prefix = Sys.getenv "OPAM_SWITCH_PREFIX" in
      Filename.concat opam_prefix "bin" // "cmdliner"
    with Not_found ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".opam/c2c/bin/cmdliner"
  in
  let term =
    let+ shell = shell_arg in
    let shell = match shell with
      | Some s -> Some (String.lowercase_ascii (String.trim s))
      | None -> detect_shell ()
    in
    match shell with
    | Some s when List.mem s ["bash"; "zsh"; "pwsh"] ->
        let cmd = Printf.sprintf "%s tool-completion --standalone-completion %s c2c"
          (cmdliner_bin ()) s
        in
        let run_and_check cmd =
          let ic = Unix.open_process_in cmd in
          let rec copy_all () =
            try print_endline (input_line ic); copy_all ()
            with End_of_file -> ()
          in
          copy_all ();
          match Unix.close_process_in ic with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED n ->
              Printf.eprintf "error: cmdliner exited with code %d\n%!" n;
              exit 1
          | _ ->
              Printf.eprintf "error: cmdliner terminated unexpectedly\n%!";
              exit 1
        in
        run_and_check cmd
    | Some s ->
        Printf.eprintf "error: unknown shell '%s'. Supported: bash, zsh, pwsh\n%!" s;
        exit 1
    | None ->
        Printf.eprintf "error: could not detect shell. Please specify --shell explicitly\n%!";
        exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "completion"
       ~doc:"Generate shell completion scripts for bash, zsh, and pwsh.")
    term

let init =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "init"
       ~doc:"One-command project onboarding: configure client MCP, register, join swarm-lounge."
       ~man:[ `S "DESCRIPTION"
            ; `P "$(b,c2c init) configures the current AI client for c2c messaging, registers \
                  the session, and joins swarm-lounge. Run once per project."
            ; `P "Auto-detects the client from $(b,C2C_MCP_SESSION_ID) or installed binaries. \
                  Override with $(b,--client)."
            ; `S "EXAMPLES"
            ; `P "$(b,c2c init)  — auto-detect client, configure, register, join swarm-lounge"
            ; `P "$(b,c2c init --client opencode --alias my-bot)  — explicit client and alias"
            ; `P "$(b,c2c init --no-setup --room project-room)  — skip MCP setup, join custom room"
            ; `P "$(b,c2c init --supervisor coordinator1)  — set permission supervisor"
            ; `P "$(b,c2c init --supervisor coordinator1,planner1 --supervisor-strategy round-robin)  — multi-supervisor"
            ])
    init_cmd

let install =
  let info = Cmdliner.Cmd.info "install"
    ~doc:"Install c2c — binary and/or client integrations."
    ~man:
      [ `S "DESCRIPTION"
      ; `P "With no subcommand, $(b,c2c install) runs an interactive TUI that \
            detects which clients are on PATH and offers to configure each. \
            Press $(b,Enter) to accept the defaults (install c2c binary + \
            configure every detected client that isn't already set up), \
            $(b,c) to customize, or $(b,n) to abort."
      ; `P
          ("Use the subcommands for scriptable (non-interactive) installs: \
            $(b,c2c install self) installs only the binary; \
            $(b,c2c install " ^ C2c_setup.install_client_pipe_list ^ ") configures one \
            client; $(b,c2c install all) does the same as the TUI's default \
            path without prompting.")
      ]
  in
  Cmdliner.Cmd.group ~default:C2c_setup.install_default_term info
    ([ C2c_setup.install_self_subcmd
     ; C2c_setup.install_all_subcmd
     ; C2c_setup.install_git_hook_subcmd
     ]
     @ List.map C2c_setup.install_client_subcmd C2c_setup.install_subcommand_clients)

(* --- subcommand: serve (MCP server mode) ---------------------------------- *)

let serve_cmd =
  let open Cmdliner.Term in
  let+ () = const () in
  let root =
    match broker_root_from_env () with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  C2c_mcp.auto_register_startup ~broker_root:root;
  C2c_mcp.auto_join_rooms_startup ~broker_root:root;
  let open Lwt.Syntax in
  let auto_drain =
    match Sys.getenv_opt "C2C_MCP_AUTO_DRAIN_CHANNEL" with
    | Some v ->
        let n = String.lowercase_ascii (String.trim v) in
        not (List.mem n [ "0"; "false"; "no"; "off" ])
    | None -> false
  in
  let session_id =
    match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
    | Some v when String.trim v <> "" -> Some (String.trim v)
    | _ -> None
  in
  let starts_with_ci ~prefix s =
    let p = String.lowercase_ascii prefix in
    let v = String.lowercase_ascii s in
    String.length v >= String.length p && String.sub v 0 (String.length p) = p
  in
  let parse_content_length line =
    match String.index_opt line ':' with
    | None -> None
    | Some i ->
        let n = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
        int_of_string_opt n
  in
  let rec read_until_blank () =
    let* line = Lwt_io.read_line_opt Lwt_io.stdin in
    match line with
    | None -> Lwt.return_unit
    | Some l -> if String.trim l = "" then Lwt.return_unit else read_until_blank ()
  in
  let rec read_message () =
    let* first = Lwt_io.read_line_opt Lwt_io.stdin in
    match first with
    | None -> Lwt.return_none
    | Some line ->
        let trimmed = String.trim line in
        if trimmed = "" then read_message ()
        else if starts_with_ci ~prefix:"Content-Length:" trimmed then
          match parse_content_length trimmed with
          | None -> Lwt.return_none
          | Some len ->
              let* () = read_until_blank () in
              let* body = Lwt_io.read ~count:len Lwt_io.stdin in
              if String.length body = len then Lwt.return_some body else Lwt.return_none
        else Lwt.return_some line
  in
  let write_message json =
    let body = Yojson.Safe.to_string json in
    let* () = Lwt_io.write_line Lwt_io.stdout body in
    Lwt_io.flush Lwt_io.stdout
  in
  let jsonrpc_error ~id ~code ~message =
    `Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", id)
      ; ("error", `Assoc [ ("code", `Int code); ("message", `String message) ])
      ]
  in
  let rec loop ~negotiated_capabilities =
    let* msg = read_message () in
    match msg with
    | None -> Lwt.return_unit
    | Some line ->
        let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
        match json with
        | Error () ->
            let* () = write_message (jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
            loop ~negotiated_capabilities
        | Ok request ->
            let negotiated_capabilities =
              C2c_capability.negotiated_in_initialize
                ~current:negotiated_capabilities request
            in
            let channel_capable =
              C2c_capability.has negotiated_capabilities
                C2c_capability.Claude_channel
            in
            let* response = C2c_mcp.handle_request ~broker_root:root request in
            let* () = match response with None -> Lwt.return_unit | Some resp -> write_message resp in
            let* () =
              match (auto_drain, channel_capable, session_id) with
              | false, _, _ -> Lwt.return_unit
              | true, false, _ -> Lwt.return_unit
              | true, true, None -> Lwt.return_unit
              | true, true, Some sid ->
                  let broker = C2c_mcp.Broker.create ~root in
                  let queued = C2c_mcp.Broker.drain_inbox_push broker ~session_id:sid in
                  let rec emit = function
                    | [] -> Lwt.return_unit
                    | m :: rest ->
                        let* () = write_message (C2c_mcp.channel_notification m) in
                        emit rest
                  in
                  emit queued
            in
            loop ~negotiated_capabilities
  in
  Lwt_main.run (loop ~negotiated_capabilities:[])

let serve = Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Run the MCP server (JSON-RPC over stdio).") serve_cmd

let mcp = Cmdliner.Cmd.v (Cmdliner.Cmd.info "mcp" ~doc:"Alias for serve (runs the MCP server).") serve_cmd

(* --- subcommand: refresh-peer ---------------------------------------------- *)

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
  C2c_mcp.Broker.with_registry_lock broker (fun () ->
    let regs = C2c_mcp.Broker.list_registrations broker in
    let match_result = List.find_opt (fun (r : C2c_mcp.registration) -> r.alias = target) regs in
    let matched_by, matched_reg = match match_result with
      | Some r -> ("alias", r)
      | None ->
          (match List.find_opt (fun (r : C2c_mcp.registration) -> r.session_id = target) regs with
           | Some r -> ("session_id", r)
           | None ->
               (match output_mode with
                | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "No registration found for '%s'" target)) ])
                | Human -> Printf.eprintf "error: No registration found for '%s'.\n%!" target);
               exit 1)
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
      let new_regs = List.map (fun (r : C2c_mcp.registration) ->
        if r.session_id = matched_reg.session_id then
          { r with pid = pid_opt; pid_start_time = start_time }
        else r
      ) regs in
      if dry_run then
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("alias", `String matched_reg.alias); ("matched_by", `String matched_by)
            ; ("status", `String "dry_run")
            ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
            ; ("new_pid", `Int (Option.get pid_opt))
            ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ])
        | Human ->
            Printf.printf "[dry-run] Would update '%s': pid %s -> %d\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              (Option.get pid_opt)
      else begin
        C2c_mcp.Broker.save_registrations broker new_regs;
        match output_mode with
        | Json -> print_json (`Assoc
            [ ("ok", `Bool true); ("alias", `String matched_reg.alias)
            ; ("matched_by", `String matched_by); ("status", `String "updated")
            ; ("old_pid", match old_pid with None -> `Null | Some p -> `Int p)
            ; ("new_pid", `Int (Option.get pid_opt))
            ; ("new_pid_start_time", match start_time with None -> `Null | Some t -> `Int t) ])
        | Human ->
            Printf.printf "Updated '%s': pid %s -> %d\n"
              matched_reg.alias
              (match old_pid with None -> "None" | Some p -> string_of_int p)
              (Option.get pid_opt)
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

let refresh_peer =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "refresh-peer" ~doc:"Refresh a stale broker registration to a new live PID.")
    refresh_peer_cmd

(* --- subcommand: instances ------------------------------------------------ *)

let instances_dir () =
  Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")

let list_instance_dirs () =
  let base = instances_dir () in
  if not (Sys.file_exists base) then []
  else begin
    let dirs = Sys.readdir base in
    Array.fold_left (fun acc name ->
      let full = base // name in
      if Sys.is_directory full && Sys.file_exists (full // "config.json") then
        full :: acc
      else acc
    ) [] dirs
  end

let instances_cmd =
  let prune_older_than =
    Cmdliner.Arg.(
      value
      & opt (some int) None
      & info [ "prune-older-than" ] ~docv:"DAYS"
          ~doc:"Prune stopped instances older than DAYS before listing." )
  in
  let+ json = json_flag
  and+ prune_older_than = prune_older_than in
  let output_mode = if json then Json else Human in
  let instances_dir = instances_dir () in
  let managed_instances = read_managed_instances () in
  let managed_instances =
    match prune_older_than with
    | None -> managed_instances
    | Some days ->
        if days < 0 then (
          Printf.eprintf "error: --prune-older-than must be >= 0\n%!";
          exit 1);
        let stale = prune_stopped_instances_older_than ~days ~instances_dir managed_instances in
        if stale <> [] && output_mode = Human then
          Printf.eprintf
            "pruned %d stopped instance(s) older than %d day(s)\n%!"
            (List.length stale) days;
        read_managed_instances ()
  in
  if managed_instances = [] then begin
    match output_mode with
    | Json -> print_json (`List [])
    | Human -> Printf.printf "No managed instances.\n"
  end else begin
    let instances =
      List.map (fun inst ->
        let fields : (string * Yojson.Safe.t) list =
          [ ("name", `String inst.mi_name)
          ; ("client", `String inst.mi_client)
          ; ("status", `String inst.mi_status)
          ; ("delivery_mode", `String inst.mi_delivery_mode)
          ; ("outer_alive", `Bool (inst.mi_status = "running"))
          ; ("outer_pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
          ; ("tmux_location", match inst.mi_tmux_location with Some s -> `String s | None -> `Null)
          ]
        in
        let fields = match inst.mi_pid with
          | Some p -> fields @ [ ("pid", `Int p) ]
          | None -> fields
        in
        `Assoc fields)
        managed_instances
    in
    match output_mode with
    | Json -> print_json (`List instances)
    | Human ->
        List.iter (fun (inst : Yojson.Safe.t) ->
          match inst with
          | `Assoc fields ->
              let name = match List.assoc_opt "name" fields with Some (`String s) -> s | _ -> "?" in
              let client = match List.assoc_opt "client" fields with Some (`String s) -> s | _ -> "?" in
              let status = match List.assoc_opt "status" fields with Some (`String s) -> s | _ -> "?" in
              let delivery_mode = match List.assoc_opt "delivery_mode" fields with Some (`String s) -> s | _ -> "?" in
              let pid_str = match List.assoc_opt "pid" fields with Some (`Int n) -> Printf.sprintf " (pid %d)" n | _ -> "" in
              let tmux_str = match List.assoc_opt "tmux_location" fields with Some (`String s) -> " [" ^ s ^ "]" | _ -> "" in
              Printf.printf "  %-20s %-10s %-12s %s%s%s\n" name client status delivery_mode pid_str tmux_str
          | _ -> ()
        ) instances
  end

let instances = Cmdliner.Cmd.v (Cmdliner.Cmd.info "instances" ~doc:"List managed c2c instances.") instances_cmd

(* --- subcommand: diag ----------------------------------------------------- *)

let diag_cmd =
  let name_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name.")
  in
  let lines_arg =
    Cmdliner.Arg.(value & opt int 50 & info [ "lines"; "n" ] ~docv:"N" ~doc:"Number of stderr tail lines (default: 50).")
  in
  let+ name = name_arg
  and+ lines = lines_arg in
  let inst_dir = instances_dir () // name in
  if not (Sys.file_exists inst_dir) then begin
    Printf.eprintf "error: no instance dir for '%s'. Was it ever started?\n%!" name;
    exit 1
  end;
  (* Print last death record if any *)
  let broker_root = resolve_broker_root () in
  let deaths_path = broker_root // "deaths.jsonl" in
  let last_death =
    if Sys.file_exists deaths_path then
      (try
        let ic = open_in deaths_path in
        let last = ref None in
        (try while true do
          let line = String.trim (input_line ic) in
          if line <> "" then begin
            match Yojson.Safe.from_string line with
            | `Assoc fields ->
                (match List.assoc_opt "name" fields with
                 | Some (`String n) when n = name -> last := Some fields
                 | _ -> ())
            | _ -> ()
          end
        done with End_of_file -> ());
        close_in ic;
        !last
      with _ -> None)
    else None
  in
  (match last_death with
   | None -> ()
   | Some fields ->
       let exit_code = match List.assoc_opt "exit_code" fields with Some (`Int n) -> n | _ -> -1 in
       let duration_s = match List.assoc_opt "duration_s" fields with Some (`Float f) -> f | _ -> 0.0 in
       let ts = match List.assoc_opt "ts" fields with Some (`Float f) -> f | _ -> 0.0 in
       let t = Unix.gmtime ts in
       let ts_str = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
         (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
         t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec in
       Printf.printf "last death: exit=%d  duration=%.1fs  at=%s\n" exit_code duration_s ts_str);
  (* Print stderr.log tail *)
  let log_path = inst_dir // "stderr.log" in
  if not (Sys.file_exists log_path) then
    Printf.printf "no stderr.log (instance may not have produced any stderr)\n"
  else begin
    Printf.printf "\n--- stderr.log (last %d lines) ---\n" lines;
    let ic = open_in log_path in
    let all_lines = ref [] in
    (try while true do
      all_lines := input_line ic :: !all_lines
    done with End_of_file -> ());
    close_in ic;
    let all = List.rev !all_lines in
    let n = List.length all in
    let skip = max 0 (n - lines) in
    let rec drop i lst = match lst with [] -> [] | _ :: t -> if i > 0 then drop (i-1) t else lst in
    List.iter (fun l -> print_endline l) (drop skip all)
  end

let diag = Cmdliner.Cmd.v (Cmdliner.Cmd.info "diag" ~doc:"Show diagnostic info (last death + stderr tail) for a managed instance.") diag_cmd

(* --- subcommand: doctor --------------------------------------------------- *)

let doctor_cmd =
  let summary =
    Cmdliner.Arg.(value & flag & info [ "summary" ]
      ~doc:"Compact ACTION REQUIRED output with FIX NOW / COORDINATOR / ALL CLEAR sections.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ]
      ~doc:"Output machine-readable JSON.")
  in
  let check_rebase_base =
    Cmdliner.Arg.(value & flag & info [ "check-rebase-base" ]
      ~doc:"Check if HEAD is based on origin/master (exit 0 = OK, exit 1 = STALE).")
  in
  let+ summary = summary
  and+ json = json
  and+ check_rebase_base = check_rebase_base in
  if check_rebase_base then
    let git_dir = match git_repo_toplevel () with
      | None ->
          Printf.eprintf "error: must run from inside the c2c git repo.\n%!";
          exit 1
      | Some d -> d
    in
    let git cmd = Sys.command (Printf.sprintf "git -C %s %s" (Filename.quote git_dir) cmd) in
    let fetch_rc = git "fetch origin master" in
    if fetch_rc <> 0 then begin
      Printf.eprintf "warning: git fetch origin master returned %d (assuming origin is up-to-date)\n%!" fetch_rc
    end;
    let merge_base_rc = git "merge-base --is-ancestor origin/master HEAD" in
    if merge_base_rc = 0 then begin
      Printf.printf "BASE OK\n%!";
      exit 0
    end else begin
      Printf.printf "STALE — run: git rebase origin/master\n%!";
      exit 1
    end
  else
    let args = [] |> (if summary then fun l -> "--summary" :: l else Fun.id)
                |> (if json then fun l -> "--json" :: l else Fun.id) in
    match git_repo_toplevel () with
    | None ->
        Printf.eprintf "error: must run from inside the c2c git repo.\n%!";
        exit 1
    | Some toplevel ->
        let script = toplevel // "scripts" // "c2c-doctor.sh" in
        if not (Sys.file_exists script) then begin
          Printf.eprintf "error: scripts/c2c-doctor.sh not found.\n%!";
          exit 1
        end;
        Unix.execvp "bash" (Array.of_list (["bash"; script] @ args))

let doctor_docs_drift = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "docs-drift"
       ~doc:"Audit CLAUDE.md for stale repo paths, unregistered c2c \
             commands, wrong GitHub org URLs, and deprecated Python script \
             references. Use --warn-only inside `c2c doctor` rollups.")
    C2c_docs_drift.docs_drift_cmd

(* --- subcommand: doctor monitor-leak (Phase C #288) --- *)
let monitor_leak_cmd =
  let open Cmdliner in
  let threshold =
    Arg.(value & opt int 1 & info ["threshold"; "t"]
           ~docv:"N"
           ~doc:"Warn if any alias has more than N monitor processes (default: 1).")
  in
  let json = Arg.(value & flag & info ["json"] ~doc:"Output machine-readable JSON.") in
  let+ threshold = threshold
  and+ json = json in
  let broker_root = resolve_broker_root () in
  let lock_dir = broker_root // ".monitor-locks" in
  let get_lock_aliases () =
    if not (Sys.file_exists lock_dir) then []
    else
      try
        Array.to_list (Sys.readdir lock_dir)
        |> List.filter (fun f -> Filename.check_suffix f ".lock")
        |> List.map (fun f -> String.sub f 0 (String.length f - 5)) (* strip .lock *)
      with _ -> []
  in
  let lock_aliases = get_lock_aliases () in
  (* For each lock, also check if the monitor process is actually alive.
     A stale lock (crash/kill) means the process is gone — report it. *)
  let cmd = Printf.sprintf "pgrep -af 'c2c monitor --alias' 2>/dev/null | grep -v pgrep || true" in
  let ic = Unix.open_process_in cmd in
  let raw =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec read_lines acc =
        try read_lines ((input_line ic) :: acc)
        with End_of_file -> List.rev acc
      in read_lines [])
  in
  (* Parse pgrep output: "PID /path/to/c2c monitor --alias alias". Count per alias. *)
  let count_per_alias =
    let counts : (string, int ref) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun line ->
      let parts = String.split_on_char ' ' line in
      (* last non-empty part is the alias *)
      let alias = List.filter ((<>) "") parts |> List.rev |> function
        | alias :: _ -> alias
        | [] -> ""
      in
      if alias <> "" then begin
        let r = try Hashtbl.find counts alias with Not_found ->
          let r = ref 0 in Hashtbl.add counts alias r; r
        in
        incr r
      end
    ) raw;
    counts
  in
  let threshold_exceeded =
    List.filter (fun alias ->
      let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
      count > threshold
    ) lock_aliases
  in
  if json then begin
    let obj = `Assoc [
      "monitor_leak", `Bool (List.length threshold_exceeded > 0);
      "threshold", `Int threshold;
      "lock_aliases", `List (List.map (fun a -> `String a) lock_aliases);
      "counts", `Assoc (
        Hashtbl.fold (fun alias count acc ->
          (alias, `Int !count) :: acc
        ) count_per_alias []);
      "exceeded", `List (List.map (fun a -> `String a) threshold_exceeded);
    ] in
    print_string (Yojson.Safe.to_string obj);
    print_newline ()
  end else begin
    if List.length lock_aliases = 0 then
      Printf.printf "✓ No monitor locks found (no active monitors with circuit-breaker protection)\n"
    else begin
      Printf.printf "Monitor locks active for %d alias(es):\n" (List.length lock_aliases);
      List.iter (fun alias ->
        let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
        let status = if count > threshold then "⚠ LEAK" else "✓" in
        Printf.printf "  %s alias=%s process_count=%d lock_exists=true\n" status alias count
      ) lock_aliases;
      if List.length threshold_exceeded > 0 then begin
        Printf.eprintf "\n⚠ WARNING: %d alias(es) exceeded threshold (count > %d):\n" (List.length threshold_exceeded) threshold;
        List.iter (fun alias ->
          let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
          Printf.eprintf "  - %s: %d processes (threshold=%d)\n" alias count threshold
        ) threshold_exceeded;
        Printf.eprintf "  Run: pkill -f 'c2c monitor --alias <alias>'\n"
      end
    end
  end;
  exit (if List.length threshold_exceeded > 0 then 1 else 0)

let monitor_leak = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "monitor-leak"
       ~doc:"Check for duplicate c2c monitor processes per alias (Phase C #288). \
             Exits 1 if any alias has more than --threshold monitor processes.")
    monitor_leak_cmd

(* --- subcommand: doctor delivery-mode (#307a) --- *)

let delivery_mode_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Recipient alias whose archive to histogram. Defaults to the \
                 caller's MCP-session alias (C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let since_flag =
    Arg.(value & opt (some string) None & info ["since"] ~docv:"DUR"
           ~doc:"Window of time, e.g. 1h, 30m, 7d. Default: 24h when --last \
                 is also unset.")
  in
  let last_flag =
    Arg.(value & opt (some int) None & info ["last"] ~docv:"N"
           ~doc:"Window of last N most-recent messages. Combines with --since \
                 (--since wins when both bound the result).")
  in
  let json_flag = Arg.(value & flag & info ["json"]
                         ~doc:"Output machine-readable JSON.") in
  let+ alias_opt = alias_flag
  and+ since_opt = since_flag
  and+ last_opt = last_flag
  and+ json_out = json_flag in
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
        | Some a when String.trim a <> "" -> String.trim a
        | _ ->
            Printf.eprintf "error: --alias is required (no \
                            C2C_MCP_AUTO_REGISTER_ALIAS in env)\n%!";
            exit 1
  in
  let since_str_default =
    match since_opt, last_opt with
    | Some _, _ | None, Some _ -> since_opt
    | None, None -> Some "24h"
  in
  let min_ts =
    match since_str_default with
    | None -> None
    | Some s ->
        match C2c_stats.parse_duration s with
        | Some secs -> Some (Unix.gettimeofday () -. secs)
        | None ->
            Printf.eprintf "error: --since must be Nm|Nh|Nd (got %S)\n%!" s;
            exit 1
  in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let session_id =
    match C2c_mcp.Broker.list_registrations broker
          |> List.find_opt (fun r -> r.C2c_mcp.alias = alias) with
    | Some reg -> reg.C2c_mcp.session_id
    | None ->
        Printf.eprintf "error: alias %S not registered\n%!" alias;
        exit 1
  in
  let result =
    C2c_mcp.Broker.delivery_mode_histogram broker ~session_id
      ?min_ts ?last_n:last_opt ()
  in
  let total = result.C2c_mcp.Broker.dmh_total in
  let push = result.C2c_mcp.Broker.dmh_push in
  let poll = result.C2c_mcp.Broker.dmh_poll in
  let pct n =
    if total = 0 then 0.0
    else 100.0 *. float_of_int n /. float_of_int total
  in
  if json_out then begin
    let window =
      let base = [("messages", `Int total)] in
      let with_since = match since_str_default with
        | Some s -> ("since", `String s) :: base
        | None -> base
      in
      let with_last = match last_opt with
        | Some n -> ("last", `Int n) :: with_since
        | None -> with_since
      in
      `Assoc with_last
    in
    let by_sender =
      `List (List.map (fun s ->
          `Assoc
            [ ("alias", `String s.C2c_mcp.Broker.dms_alias)
            ; ("total", `Int s.dms_total)
            ; ("push", `Int s.dms_push)
            ; ("poll", `Int s.dms_poll)
            ])
          result.dmh_by_sender)
    in
    let obj = `Assoc
      [ ("alias", `String alias)
      ; ("window", window)
      ; ("counts", `Assoc
            [ ("push_intent", `Int push)
            ; ("poll_only", `Int poll)
            ])
      ; ("by_sender", by_sender)
      ; ("caveats", `List
            [ `String "sender_intent_not_actuals"
            ; `String "ephemeral_excluded"
            ])
      ]
    in
    print_endline (Yojson.Safe.to_string obj)
  end else begin
    let window_label =
      match since_str_default, last_opt with
      | Some s, Some n -> Printf.sprintf "last %s, capped to %d" s n
      | Some s, None -> Printf.sprintf "last %s" s
      | None, Some n -> Printf.sprintf "last %d messages" n
      | None, None -> "all archived"
    in
    Printf.printf "Delivery mode for %s (%s, %d archived messages)\n\n"
      alias window_label total;
    Printf.printf "Push intent (deferrable=false): %5d  (%5.1f%%)\n"
      push (pct push);
    Printf.printf "Poll-only (deferrable=true):    %5d  (%5.1f%%)\n\n"
      poll (pct poll);
    if result.dmh_by_sender = [] then
      Printf.printf "(no senders in window)\n"
    else begin
      Printf.printf "By sender:\n";
      Printf.printf "  %-22s %6s  %6s  %5s  %6s\n"
        "ALIAS" "TOTAL" "PUSH" "POLL" "POLL%";
      List.iter (fun s ->
          let p =
            if s.C2c_mcp.Broker.dms_total = 0 then 0.0
            else 100.0 *. float_of_int s.dms_poll
                 /. float_of_int s.dms_total
          in
          Printf.printf "  %-22s %6d  %6d  %5d  %5.1f%%\n"
            s.dms_alias s.dms_total s.dms_push s.dms_poll p)
        result.dmh_by_sender
    end;
    Printf.printf "\nNOTE: counts measure sender intent (deferrable flag), \
                   not which delivery path actually surfaced the message. \
                   Ephemeral messages (#284) are not archived and not \
                   counted. See #303 design doc for the deferrable contract.\n"
  end

let delivery_mode = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "delivery-mode"
       ~doc:"Histogram of an alias's recent inbox by deferrable flag (#307a). \
             Counts measure sender intent, not delivery actuals.")
    delivery_mode_cmd

let doctor = Cmdliner.Cmd.group
    ~default:doctor_cmd
    (Cmdliner.Cmd.info "doctor"
       ~doc:"Health snapshot + push-pending analysis (for Max / human operators).")
    [ doctor_docs_drift; monitor_leak; delivery_mode;
      C2c_opencode_plugin_drift.opencode_plugin_drift_cmd ]

(* --- subcommand: stats ---------------------------------------------------- *)

let stats_cmd =
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Filter to a single agent alias.")
  in
  let since_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "since" ] ~docv:"DUR"
      ~doc:"Only count messages within this duration (e.g. 1h, 30m, 7d).")
  in
  let append_sitrep_flag =
    Cmdliner.Arg.(value & flag & info [ "append-sitrep" ]
      ~doc:"Append or replace a Swarm stats section in the current UTC hourly sitrep.")
  in
  let top_flag =
    Cmdliner.Arg.(value & opt (some int) None & info [ "top"; "t" ] ~docv:"N"
      ~doc:"Show only the top N agents by total message count.")
  in
  let+ json = json_flag
  and+ alias_filter = alias_flag
  and+ since_str = since_flag
  and+ append_sitrep = append_sitrep_flag
  and+ top_n = top_flag in
  let root = resolve_broker_root () in
  C2c_stats.run ~root ~json ~alias_filter ~since_str ~append_sitrep ~top_n

let markdown_flag =
  Cmdliner.Arg.(value & flag & info [ "markdown"; "m" ]
    ~doc:"Output stats as grouped markdown tables with per-day totals.")

let csv_flag =
  Cmdliner.Arg.(value & flag & info [ "csv"; "c" ]
    ~doc:"Output stats as CSV (columns: day,alias,msgs_out,msgs_in). This is the default.")

let compact_flag =
  Cmdliner.Arg.(value & flag & info [ "compact" ]
    ~doc:"Output compact (non-pretty) JSON when used with --json.")

let stats_history_cmd =
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Filter to a single agent alias.")
  in
  let days_flag =
    Cmdliner.Arg.(value & opt int 7 & info [ "days"; "d" ] ~docv:"N"
      ~doc:"Lookback window in days (0 = all archive history).")
  in
  let bucket_flag =
    Cmdliner.Arg.(value & opt string "day" & info [ "bucket"; "b" ] ~docv:"GRAIN"
      ~doc:"Bucket granularity: hour | day | week (default: day).")
  in
  let top_flag =
    Cmdliner.Arg.(value & opt (some int) None & info [ "top"; "t" ] ~docv:"N"
      ~doc:"Keep only the top-N busiest aliases per bucket, ranked by msgs_out + msgs_in.")
  in
  let+ json = json_flag
  and+ markdown = markdown_flag
  and+ csv = csv_flag
  and+ compact = compact_flag
  and+ alias_filter = alias_flag
  and+ days = days_flag
  and+ bucket = bucket_flag
  and+ top = top_flag in
  let grain = match C2c_stats.parse_bucket bucket with
    | Some g -> g
    | None ->
        Printf.eprintf "error: --bucket must be hour|day|week (got %S)\n%!" bucket;
        exit 1
  in
  let root = resolve_broker_root () in
  C2c_stats.run_history ~root ~json ~markdown ~csv ~compact ~alias_filter ~days ~grain ~top_n:top ()

let stats =
  Cmdliner.Cmd.group
    ~default:stats_cmd
    (Cmdliner.Cmd.info "stats" ~doc:"Show per-agent message statistics across the swarm.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "history"
        ~doc:"Per-day rollup of swarm message counts (CSV by default; --json for JSON; --markdown for grouped markdown tables; --csv for explicit CSV; --compact for compact JSON).")
        stats_history_cmd ]

(* --- subcommand: start ---------------------------------------------------- *)

let roles_dir () = C2c_role.canonical_roles_dir ()

let role_file_path ~alias =
  roles_dir () // (alias ^ ".md")

let read_role ~alias =
  let path = role_file_path ~alias in
  try
    let role = C2c_role.parse_file path in
    Some role
  with Sys_error _ -> None

let yaml_scalar s =
  if s = "" || String.length s > 0 && (String.contains s ':' || String.contains s '#' ||
     String.contains s '"' || String.contains s '\'') then
    "\"" ^ String.escaped s ^ "\""
  else s

let write_role ~alias ~(role : C2c_role.t) =
  let dir = roles_dir () in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = role_file_path ~alias in
  let fm =
    Printf.sprintf
      "---\n\
       description: %s\n\
       role: %s\n\
       ---\n\
       %s\n"
      (yaml_scalar role.C2c_role.description)
      role.C2c_role.role
      role.C2c_role.body
  in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc fm)

let prompt_for_role ~alias =
  if Unix.isatty Unix.stdin then begin
    Printf.eprintf "\n[c2c start] No role file found for alias '%s'.\n" alias;
    Printf.eprintf "  What is this agent's role? (e.g. coder, planner, coordinator — press Enter to skip)\n";
    Printf.eprintf "  > %!";
    let line = try input_line stdin with End_of_file -> "" in
    let trimmed = String.trim line in
    if trimmed <> "" then begin
      let role = { C2c_role.
        description = "";
        role = "subagent";
        model = None;
        pmodel = None;
        role_class = None;
        pronouns = None;
        c2c_alias = None;
        c2c_auto_join_rooms = [];
        c2c_heartbeat = [];
        c2c_heartbeats = [];
        include_ = [];
        compatible_clients = [];
        required_capabilities = [];
        opencode = [];
        claude = [];
        codex = [];
        kimi = [];
        body = trimmed;
      } in
      write_role ~alias ~role;
      Printf.eprintf "[c2c start] Role saved to .c2c/roles/%s.md\n%!" alias;
      Some role
    end else None
  end else None

let default_kickoff_prompt ~name ~alias ?role () =
  let role_section = match role with
    | None -> ""
    | Some r -> Printf.sprintf "\nYour assigned role: %s\n" r
  in
  Printf.sprintf
    "You have been started as a c2c swarm agent.\n\
     Instance: %s  Alias: %s%s\n\
     Getting started:\n\
     1. Poll your inbox:  use the MCP poll_inbox tool (or: c2c poll-inbox)\n\
     2. See active peers: c2c list\n\
     3. Post in the lounge: send_room swarm-lounge with a hello message\n\
     4. Read CLAUDE.md for the mission brief and open tasks\n\n\
     The swarm coordinates via c2c instant messaging. You are now part of it."
    name alias role_section

let agent_file_path ~client ~name =
  C2c_role.client_agent_dir ~client // (name ^ ".md")

let render_role_for_client ?(model_override : string option) (r : C2c_role.t) ~client ~name =
  let pmodel_lookup (key : string) : string option =
    match C2c_start.repo_config_pmodel_lookup key with
    | None -> None
    | Some p -> Some (p.C2c_start.provider ^ ":" ^ p.C2c_start.model)
  in
  let resolved_pmodel =
    match model_override with
    | Some m -> Some m
    | None -> C2c_role.resolve_pmodel r ~class_lookup:pmodel_lookup
  in
  match resolved_pmodel with
  | Some p -> C2c_role.render_for_client r ~client ~resolved_pmodel:p ~name
  | None -> C2c_role.render_for_client r ~client ~name

(** Resolve the effective pmodel from a role and normalize it for launch args.
    Returns None if the role has no pmodel set.
    Used by cmd_start to derive --model from the role when no explicit --model
    flag is given. *)
let resolve_role_pmodel_for_launch (r : C2c_role.t) ~(client : string) : string option =
  let pmodel_lookup (key : string) : string option =
    match C2c_start.repo_config_pmodel_lookup key with
    | None -> None
    | Some p -> Some (p.C2c_start.provider ^ ":" ^ p.C2c_start.model)
  in
  match C2c_role.resolve_pmodel r ~class_lookup:pmodel_lookup with
  | None -> None
  | Some raw ->
      (match C2c_start.normalize_model_override_for_client ~client raw with
       | Ok normalized -> Some normalized
       | Error _ -> None)

let write_agent_file ~client ~name ~content =
  let path = agent_file_path ~client ~name in
  let dir = Filename.dirname path in
  mkdir_p dir;
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile lock_path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      Fun.protect ~finally:(fun () -> Unix.lockf fd Unix.F_ULOCK 0)
        (fun () ->
          let oc = open_out path in
          Fun.protect ~finally:(fun () -> close_out oc)
            (fun () -> output_string oc content; output_char oc '\n');
          Printf.eprintf "[c2c start] wrote compiled agent file: %s\n%!" path))

let get_opencode_theme (r : C2c_role.t) : string option =
  List.assoc_opt "theme" r.C2c_role.opencode

let start_cmd =
  let client =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"CLIENT"
      ~doc:(Printf.sprintf "Client to start (%s)." C2c_setup.start_client_list))
  in
  (* Trailing args after `--`: appended verbatim to the client's argv.
     e.g. `c2c start claude -- --foo bar` runs claude with `--foo bar`;
     `c2c start pty -- bash -i` runs bash with `-i`. *)
  let extra_argv =
    Cmdliner.Arg.(value & pos_right 1 (list string) [] & info [] ~docv:"ARG"
      ~doc:"Extra arguments passed to the client after `--`. Anything after `--` is appended verbatim to the client's argv.")
  in
  let name =
    Cmdliner.Arg.(value & opt (some string) None & info [ "name"; "n" ] ~docv:"NAME" ~doc:"Instance name (default: auto-generated).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias" ] ~docv:"ALIAS" ~doc:"Custom alias (defaults to instance name).")
  in
  let bin =
    Cmdliner.Arg.(value & opt (some string) None & info [ "bin" ] ~docv:"PATH" ~doc:"Custom binary path or name to launch.")
  in
  let session_id =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID" ~doc:"Explicit session target — UUID or named session for claude, exact thread/session target for codex and codex-headless, ses_* for opencode (overrides auto-generated).")
  in
  let one_hr_cache =
    Cmdliner.Arg.(value & flag & info [ "1hr-cache" ] ~doc:"Set ENABLE_PROMPT_CACHING_1H=1 (claude only; default off — 1h cache writes cost 2x, only worth it if you hit the cache).")
  in
  let auto_flag =
    Cmdliner.Arg.(value & flag & info [ "auto" ] ~doc:"Write a getting-started kickoff prompt that the plugin delivers on first session.idle. OpenCode only.")
  in
  let kickoff_prompt_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "kickoff-prompt" ] ~docv:"TEXT" ~doc:"Custom kickoff prompt text (implies --auto). OpenCode only.")
  in
  let kickoff_prompt_file_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "kickoff-prompt-file" ] ~docv:"PATH" ~doc:"Read kickoff prompt from file (mutually exclusive with --kickoff-prompt). Useful for passing multi-line kickoff via tmux-backed launchers.")
  in
  let agent =
    Cmdliner.Arg.(value & opt (some string) None & info [ "agent"; "a" ] ~docv:"NAME" ~doc:"Start from canonical role at .c2c/roles/<NAME>.md (compiled to client format on launch).")
  in
  let model =
    Cmdliner.Arg.(value & opt (some string) None & info [ "model"; "m" ] ~docv:"MODEL" ~doc:"Override the launch model. Accepts pmodel-style input; single-provider clients also accept bare model names.")
  in
  let reply_to =
    Cmdliner.Arg.(value & opt (some string) None & info [ "reply-to" ] ~docv:"ALIAS" ~doc:"Set C2C_MCP_REPLY_TO env var — used by ephemeral agents to know where to send completion results.")
  in
  let auto_join =
    Cmdliner.Arg.(value & opt (some string) None & info [ "auto-join" ] ~docv:"ROOMS" ~doc:"Comma-separated room IDs to auto-join on startup. Overrides the default swarm-lounge.")
  in
  let worktree =
    Cmdliner.Arg.(value & flag & info [ "worktree" ] ~doc:"Create an isolated git worktree for this agent before launching. Useful for parallel feature work. Implied when C2C_AUTO_WORKTREE=1.")
  in
  let branch_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "branch" ] ~docv:"BRANCH" ~doc:"Branch to check out in the new worktree (requires --worktree). Defaults to caller's current branch. Must not be 'master'.")
  in
  let tmux_loc =
    Cmdliner.Arg.(value & opt (some string) None & info [ "loc" ] ~docv:"TMUX_TARGET"
      ~doc:"Tmux target for generic tmux mode (e.g. 0:1.2 or %42). Required when CLIENT=tmux.")
  in
  let tmux_tail =
    Cmdliner.Arg.(value & pos_right 1 string [] & info [] ~docv:"CMD"
      ~doc:"For CLIENT=tmux, optional command argv to type into the target pane. Use -- before the command.")
  in
  let foreground_flag =
    Cmdliner.Arg.(value & flag & info [ "foreground"; "fg" ]
      ~doc:"For CLIENT=relay-connect: run connector in the foreground instead of \
            daemonizing. Useful for tmux-managed dogfooding. Ignored for other clients.")
  in
  let relay_url_opt =
    Cmdliner.Arg.(value & opt (some string) None & info [ "relay-url" ] ~docv:"URL"
      ~doc:"For CLIENT=relay-connect: relay URL to connect to. Falls back to \
            \\$C2C_RELAY_URL when omitted. Ignored for other clients.")
  in
  let interval_opt =
    Cmdliner.Arg.(value & opt int 30 & info [ "interval" ] ~docv:"SECS"
      ~doc:"For CLIENT=relay-connect: poll interval in seconds (default 30). \
            Ignored for other clients.")
  in
  let+ client = client
  and+ name_opt = name
  and+ alias_opt = alias
  and+ bin_opt = bin
  and+ session_id_opt = session_id
  and+ one_hr_cache = one_hr_cache
  and+ auto_flag = auto_flag
  and+ kickoff_prompt_text_raw = kickoff_prompt_opt
  and+ kickoff_prompt_file = kickoff_prompt_file_opt
  and+ agent_opt = agent
  and+ model_opt = model
  and+ reply_to = reply_to
  and+ auto_join = auto_join
  and+ worktree_flag = worktree
  and+ branch_flag = branch_opt
  and+ tmux_loc = tmux_loc
  and+ tmux_tail = tmux_tail
  and+ extra_argv = extra_argv
  and+ foreground_flag = foreground_flag
  and+ relay_url_opt = relay_url_opt
  and+ interval_opt = interval_opt in
  let extra_argv = List.concat extra_argv in
  let kickoff_prompt_text =
    match kickoff_prompt_text_raw, kickoff_prompt_file with
    | Some _, Some _ ->
        Printf.eprintf "error: --kickoff-prompt and --kickoff-prompt-file are mutually exclusive.\n%!";
        exit 1
    | Some t, None -> Some t
    | None, Some path ->
        (try
           let ic = open_in path in
           Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
             let n = in_channel_length ic in
             let buf = Bytes.create n in
             really_input ic buf 0 n;
             Some (Bytes.to_string buf)
         with Sys_error e ->
           Printf.eprintf "error: failed to read --kickoff-prompt-file %s: %s\n%!" path e;
           exit 1)
    | None, None -> None
  in
  (* The nested-session guard below applies to harness clients
     (claude/codex/etc.) where running `c2c start` from inside another
     agent session can hijack session IDs. relay-connect is a pure
     background daemon — no inheritance hazard — so it dispatches before
     the guard. *)
  if client <> "relay-connect" && Sys.getenv_opt "C2C_INSTANCE_NAME" <> None then begin
    Printf.eprintf "error: cannot run 'c2c start' from inside a c2c session.\n";
    Printf.eprintf "  Hint: use the outer shell or a separate terminal instead.\n%!";
    exit 1
  end;
  (* relay-connect: managed connector daemon. Branches off the harness-client
     pipeline early — connectors don't need session ids, role files, kickoff
     prompts, or tmux integration. The instance dir + outer.pid plumbing is
     shared with `c2c instances` / `c2c stop` so they Just Work. *)
  if client = "relay-connect" then begin
    let name = match name_opt with
      | Some n -> n
      | None -> "relay-connect"
    in
    let resolved_url =
      match relay_url_opt with
      | Some _ as some -> some
      | None -> Sys.getenv_opt "C2C_RELAY_URL"
    in
    if resolved_url = None then begin
      Printf.eprintf
        "error: relay-connect requires a relay URL.\n\
        \  Either pass --relay-url URL or export C2C_RELAY_URL.\n%!";
      exit 1
    end;
    C2c_relay_managed.start
      ~name
      ~daemon:(not foreground_flag)
      ~relay_url:resolved_url
      ~interval:interval_opt
      ~extra_args:extra_argv
      ();
    (* foreground mode exec'd in place; daemon mode parent has exit 0'd
       inside C2c_relay_managed.start. We only return here on error. *)
    exit 1
  end;
  if client <> "tmux" && tmux_loc <> None then begin
    Printf.eprintf "error: --loc is only valid with `c2c start tmux`.\n%!";
    exit 1
  end;
  if client <> "tmux" && tmux_tail <> [] then begin
    Printf.eprintf "error: extra argv after CLIENT is only supported for `c2c start tmux` in this slice.\n%!";
    exit 1
  end;
  let name = match name_opt with
    | Some n -> n
    | None ->
        let n = C2c_start.default_name client in
        Printf.eprintf "[c2c start] no -n given; auto-picked name=%s. Pass -n NAME to override.\n%!" n;
        n
  in
  let binary_path =
    match bin_opt with
    | Some path -> path
    | None ->
        (try
           let cfg = Stdlib.Hashtbl.find C2c_start.clients client in
           cfg.C2c_start.binary
         with Not_found -> client)
  in
  let model_override =
    match model_opt with
    | None -> None
    | Some raw ->
        (match C2c_start.normalize_model_override_for_client ~client raw with
         | Ok normalized -> Some normalized
         | Error msg ->
             Printf.eprintf "error: invalid --model for client '%s': %s\n%!" client msg;
             exit 1)
  in
  let effective_alias = Option.value alias_opt ~default:name in
  (* Resolve agent file path: canonical .c2c/roles/<agent>.md first,
     falling back to client-native agent path if canonical doesn't exist. *)
  let agent_role_path agent_name =
    C2c_role.resolve_agent_path ~name:agent_name ~client
  in
  (* --agent mode: load canonical role, render for client, write compiled file *)
  let (kickoff_prompt, alias_override, auto_join_rooms, agent_name, role_pmodel_override) =
    match agent_opt with
    | Some agent_name ->
        let role_path = agent_role_path agent_name in
        (try
           let role = C2c_role.parse_file role_path in
           if role.C2c_role.compatible_clients <> [] &&
              not (List.mem client role.C2c_role.compatible_clients) then
             (Printf.eprintf "error: role '%s' is not compatible with client '%s'.\n" agent_name client;
              Printf.eprintf "  compatible clients: %s\n%!" (String.concat ", " role.C2c_role.compatible_clients);
              exit 1);
           let missing =
             C2c_start.missing_role_capabilities ~client ~binary_path role
           in
           if missing <> [] then begin
             let available =
               C2c_start.probed_capabilities ~client ~binary_path
             in
             Printf.eprintf
               "error: role '%s' requires unsupported capabilities for client '%s'.\n"
               agent_name client;
             Printf.eprintf "  missing: %s\n%!" (String.concat ", " missing);
             Printf.eprintf "  available: %s\n%!"
               (if available = [] then "(none)" else String.concat ", " available);
             exit 1
           end;
            let role_pmodel = resolve_role_pmodel_for_launch role ~client in
            match render_role_for_client ?model_override role ~client ~name:agent_name with
            | Some rendered ->
                let effective_alias = Option.value role.C2c_role.c2c_alias ~default:agent_name in
                if client = "opencode" || client = "claude" then
                  write_agent_file ~client ~name ~content:rendered;
                let onboarding_preamble =
                  Printf.sprintf
                    "You are now running as %s. Complete these startup steps:\n\
                     1. Call `whoami` to confirm your identity and registration.\n\
                     2. Join the `swarm-lounge` room: use `join_room` with {\"room_id\": \"swarm-lounge\"}.\n\
                     3. Send a message to coordinator1 introducing yourself: use `send` with \
                     {\"to_alias\": \"coordinator1\", \"content\": \"<brief intro of your role and capabilities>\"}.\n\
                     4. Call `poll_inbox` to check for any messages addressed to you.\n\
                     5. Arm a heartbeat Monitor: use Monitor tool with \
                     command `heartbeat 4.1m \"<wake message>\"`, persistent:true.\n\
                     Begin now."
                    agent_name
                in
                let kickoff =
                  if client = "claude" then Some onboarding_preamble
                  else Some (default_kickoff_prompt ~name:agent_name ~alias:effective_alias ~role:role.C2c_role.body ())
                in
                let alias_override = role.C2c_role.c2c_alias in
               let auto_join_rooms =
                 if role.C2c_role.c2c_auto_join_rooms <> []
                 then Some (String.concat ", " role.C2c_role.c2c_auto_join_rooms)
                 else None
               in
               let theme = get_opencode_theme role in
               let subtitle = Printf.sprintf "%s  |  %s" client name in
               Banner.print_banner ?theme_name:theme ~subtitle (Printf.sprintf "c2c start --agent %s" agent_name);
                let effective_agent_name = Some agent_name in
                (kickoff, alias_override, auto_join_rooms, effective_agent_name, role_pmodel)
          | None ->
              Printf.eprintf "error: --agent is not supported for client '%s' yet.\n%!" client;
              exit 1
        with Sys_error _ ->
          Printf.eprintf "error: role file not found: %s\n%!" role_path;
          exit 1)
    | None ->
        (* Auto-inference: if .c2c/roles/<name>.md or <client-native>/<name>.md exists
           as a structured role, auto-apply --agent=<name> (silent, no banner).
           Explicit --agent always wins. *)
        let canonical_path = role_file_path ~alias:name in
        let client_native_path = C2c_role.client_agent_dir ~client // (name ^ ".md") in
        let role_path =
          if Sys.file_exists canonical_path then canonical_path
          else if Sys.file_exists client_native_path then client_native_path
          else canonical_path (* non-existent, will trigger Sys_error below *)
        in
        if Sys.file_exists role_path then
          (try
             let role = C2c_role.parse_file role_path in
             if role.C2c_role.compatible_clients <> [] &&
                not (List.mem client role.C2c_role.compatible_clients) then
                (Printf.eprintf "error: role '%s' is not compatible with client '%s'.\n" name client;
                 Printf.eprintf "  compatible clients: %s\n%!" (String.concat ", " role.C2c_role.compatible_clients);
                 exit 1);
             let missing =
               C2c_start.missing_role_capabilities ~client ~binary_path role
             in
             if missing <> [] then begin
               let available =
                 C2c_start.probed_capabilities ~client ~binary_path
               in
               Printf.eprintf
                 "error: role '%s' requires unsupported capabilities for client '%s'.\n"
                 name client;
               Printf.eprintf "  missing: %s\n%!" (String.concat ", " missing);
               Printf.eprintf "  available: %s\n%!"
                 (if available = [] then "(none)" else String.concat ", " available);
               exit 1
             end;
               let role_pmodel = resolve_role_pmodel_for_launch role ~client in
               (match render_role_for_client ?model_override role ~client ~name with
                | Some rendered ->
                    let effective_alias = Option.value role.C2c_role.c2c_alias ~default:name in
                    if client = "opencode" || client = "claude" then
                      write_agent_file ~client ~name ~content:rendered;
                    let onboarding_preamble =
                      Printf.sprintf
                        "You are now running as %s. Complete these startup steps:\n\
                         1. Call `whoami` to confirm your identity and registration.\n\
                         2. Join the `swarm-lounge` room: use `join_room` with {\"room_id\": \"swarm-lounge\"}.\n\
                         3. Send a message to coordinator1 introducing yourself: use `send` with \
                         {\"to_alias\": \"coordinator1\", \"content\": \"<brief intro of your role and capabilities>\"}.\n\
                         4. Call `poll_inbox` to check for any messages addressed to you.\n\
                         5. Arm a heartbeat Monitor: use Monitor tool with \
                         command `heartbeat 4.1m \"<wake message>\"`, persistent:true.\n\
                         Begin now."
                        name
                    in
                    let kickoff =
                      if client = "claude" then Some onboarding_preamble
                      else Some (default_kickoff_prompt ~name ~alias:effective_alias ~role:role.C2c_role.body ())
                    in
                    let alias_override = role.C2c_role.c2c_alias in
                    let auto_join_rooms =
                      if role.C2c_role.c2c_auto_join_rooms <> []
                      then Some (String.concat ", " role.C2c_role.c2c_auto_join_rooms)
                      else None
                    in
                     let agent_name = Some name in
                     (kickoff, alias_override, auto_join_rooms, agent_name, role_pmodel)
               | None ->
                        (* Role file exists but not supported for this client — fall through
                           to structured role path so user can still start with the role. *)
                        let role_opt =
                          match read_role ~alias:effective_alias with
                          | Some r -> Some r
                          | None -> prompt_for_role ~alias:effective_alias
                         in
                         let kickoff_prompt =
                           match kickoff_prompt_text with
                           | Some t -> Some t
                           | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                           | None ->
                               (match role_opt with
                                | Some _ -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                                 | None -> None)
                          in
                          (kickoff_prompt, alias_opt, None, None, None))
             with Sys_error _ ->
              (* Role file exists but can't be read as structured role — fall through. *)
              let role_opt =
                match read_role ~alias:effective_alias with
                | Some r -> Some r
                | None -> prompt_for_role ~alias:effective_alias
              in
              let kickoff_prompt =
                match kickoff_prompt_text with
                | Some t -> Some t
                | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                | None ->
                    (match role_opt with
                     | Some _ -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                      | None -> None)
                 in
                 (kickoff_prompt, alias_opt, None, None, None))
        else
          (* No structured role file — structured role path. *)
          let role_opt =
            match read_role ~alias:effective_alias with
            | Some r -> Some r
            | None ->
                (* If an explicit kickoff is already set, skip the interactive
                   role prompt — the caller knows what they want. This is the
                   path hit by `c2c agent run --pane` which pre-composes the
                   full kickoff and passes it via --kickoff-prompt-file. *)
                if client = "tmux" || kickoff_prompt_text <> None then None
                else prompt_for_role ~alias:effective_alias
          in
          let kickoff_prompt =
            match kickoff_prompt_text with
            | Some t -> Some t
            | None when auto_flag -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
            | None ->
                (match role_opt with
                 | Some _ -> Some (default_kickoff_prompt ~name ~alias:effective_alias ?role:(Option.map (fun r -> r.C2c_role.body) role_opt) ())
                 | None -> None)
           in
           (kickoff_prompt, alias_opt, None, None, None)
   in
   let auto_join_rooms = match auto_join with
    | Some rooms -> Some rooms
    | None -> auto_join_rooms
  in
  let auto_worktree = worktree_flag || (match Sys.getenv_opt "C2C_AUTO_WORKTREE" with Some "1" -> true | _ -> false) in
  (match session_id_opt with
  | Some _ ->
      Printf.printf "[c2c] resume mode — staying at parent cwd\n%!"
  | None when auto_worktree ->
      (* Resolve which branch the worktree should track:
         1. --branch flag (explicit override)
         2. caller's current git branch (auto-detected)
         3. error if neither is available or if branch is 'master' *)
      let branch = match branch_flag with
        | Some b -> b
        | None ->
            (match C2c_worktree.current_branch () with
             | Some b -> b
             | None ->
                 Printf.eprintf "error: --worktree requires a branch but git reports detached HEAD. Pass --branch <name> explicitly.\n%!";
                 exit 1)
      in
      if branch = "master" || branch = "main" then begin
        Printf.eprintf "error: --worktree refused on '%s'. Create a slice branch first (e.g. git checkout -b slice/my-work) or pass --branch <name>.\n%!" branch;
        exit 1
      end;
      let wt_dir = C2c_worktree.ensure_worktree ~alias:effective_alias ~branch in
      (try Unix.chdir wt_dir with Sys_error e ->
        Printf.eprintf "warning: failed to chdir to worktree %s: %s\n%!" wt_dir e);
      Printf.printf "[c2c] worktree: %s (branch: %s)\n%!" wt_dir branch
  | _ -> ());
  exit (C2c_start.cmd_start ~client ~name ~extra_args:extra_argv
      ?binary_override:bin_opt
      ?alias_override
      ?session_id_override:session_id_opt
      ?model_override
      ?role_pmodel_override
      ~one_hr_cache
      ?kickoff_prompt
      ?agent_name
      ?auto_join_rooms
      ?reply_to
      ?tmux_location:tmux_loc
      ~tmux_command:tmux_tail
      ())

let start = Cmdliner.Cmd.v (Cmdliner.Cmd.info "start" ~doc:"Start a managed c2c instance.") start_cmd

(* --- subcommand: gui ------------------------------------------------------ *)

let find_gui_binary () =
  (* 1. c2c-gui in PATH *)
  match Sys.getenv_opt "PATH" with
  | Some path_env ->
      let dirs = String.split_on_char ':' path_env in
      (match List.find_opt (fun d -> Sys.file_exists (d // "c2c-gui")) dirs with
      | Some d -> Some (d // "c2c-gui")
      | None ->
          (* 2. Relative to the c2c binary itself (e.g. ~/.local/bin/c2c → ~/.local/bin/c2c-gui) *)
          let self = Sys.executable_name in
          let sibling = Filename.dirname self // "c2c-gui" in
          if Sys.file_exists sibling then Some sibling else None)
  | None -> None

type gui_batch_check = { name : string; ok : bool; detail : string }

let registration_to_json (r : C2c_mcp.registration) : Yojson.Safe.t =
  let base = [ ("session_id", `String r.session_id); ("alias", `String r.alias) ] in
  let with_pid = match r.pid with Some n -> base @ [("pid", `Int n)] | None -> base in
  let alive_val = match C2c_mcp.Broker.registration_liveness_state r with
    | C2c_mcp.Broker.Alive -> `Bool true
    | C2c_mcp.Broker.Dead -> `Bool false
    | C2c_mcp.Broker.Unknown -> `Null
  in
  let with_alive = with_pid @ [("alive", alive_val)] in
  let with_dnd = if r.dnd then with_alive @ [("dnd", `Bool true)] else with_alive in
  `Assoc with_dnd

let room_to_json (ri : C2c_mcp.Broker.room_info) : Yojson.Safe.t =
  `Assoc
    [ ("room_id", `String ri.C2c_mcp.Broker.ri_room_id)
    ; ("member_count", `Int ri.C2c_mcp.Broker.ri_member_count)
    ; ("alive_member_count", `Int ri.C2c_mcp.Broker.ri_alive_member_count)
    ; ("members", `List (List.map (fun (m : string) -> `String m) ri.C2c_mcp.Broker.ri_members))
    ]

(** [gui_batch ()] runs a headless smoke test of the c2c broker.
    Validates config loading, CLI/MCP availability, inbox polling,
    render-model build, peer discovery, room listing, and pending permissions.
    Outputs a full swarm snapshot JSON to stderr. Exits 0 on success,
    non-zero on failure. *)
let gui_batch () =
  let broker_root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let checks : gui_batch_check list ref = ref [] in
  let add_check name ok detail =
    checks := { name; ok; detail } :: !checks
  in
  (* Snapshot data *)
  let peers_json : Yojson.Safe.t ref = ref (`List [])
  and rooms_json : Yojson.Safe.t ref = ref (`List [])
  and pending_perms_json : Yojson.Safe.t ref = ref (`List []) in

  (* Check 1: broker root exists and is readable *)
  (try
     let reg_path = Filename.concat broker_root "registry.json" in
     if Sys.file_exists reg_path then add_check "broker_root" true "registry.json found"
     else add_check "broker_root" false "registry.json not found"
   with e ->
     add_check "broker_root" false (Printexc.to_string e));
  (* Check 2: config loading — check .c2c/config.toml in cwd *)
  (try
     let cfg = Filename.concat (Sys.getcwd ()) ".c2c" // "config.toml" in
     if Sys.file_exists cfg then add_check "config_loading" true "config.toml found"
     else add_check "config_loading" false "config.toml not found"
   with e ->
     add_check "config_loading" false (Printexc.to_string e));
  (* Check 3: CLI availability — invoke c2c --version *)
  (try
     let self_bin = Sys.executable_name in
     let ic = Unix.open_process_args_in self_bin [| self_bin; "--version" |] in
     let buf = Bytes.create 256 in
     let rec drain acc =
       match input ic buf 0 256 with
       | 0 -> close_in ic; List.rev acc
       | n -> drain (Bytes.sub buf 0 n :: acc)
     in
     let _output = drain [] |> Bytes.concat (Bytes.create 0) |> Bytes.to_string in
     let status = Unix.close_process_in ic in
     match status with
     | Unix.WEXITED 0 -> add_check "cli_mcp_availability" true "CLI --version succeeded"
     | Unix.WEXITED n -> add_check "cli_mcp_availability" false ("CLI --version exited " ^ string_of_int n)
     | _ -> add_check "cli_mcp_availability" false "CLI --version killed or stopped"
   with e ->
     add_check "cli_mcp_availability" false (Printexc.to_string e));
  (* Check 4: inbox polling — non-destructive read via broker *)
  (try
     let session_id = match C2c_mcp.session_id_from_env () with
       | Some s -> s | None -> "batch-smoke-session" in
     let msgs = C2c_mcp.Broker.read_inbox broker ~session_id in
     add_check "inbox_polling" true (Printf.sprintf "read successfully (%d messages)" (List.length msgs))
   with e ->
     add_check "inbox_polling" false (Printexc.to_string e));
  (* Check 5: render-model build — check gui dist/ and src-tauri/target exist *)
  (try
     let git_dir = match Git_helpers.git_common_dir () with
       | Some d -> d | None -> raise (Failure "no git common dir") in
     let repo_root = Filename.dirname git_dir in
     let gui_dist = repo_root // "gui" // "dist" in
     let gui_tauri = repo_root // "gui" // "src-tauri" // "target" in
     if Sys.file_exists gui_dist || Sys.file_exists gui_tauri
     then add_check "render_model" true "gui assets found"
     else add_check "render_model" false "gui dist/ or src-tauri/target/ not found"
   with e ->
     add_check "render_model" false (Printexc.to_string e));
  (* Check 6: peer discovery — collect peer records *)
  (try
     let regs = C2c_mcp.Broker.list_registrations broker in
     let alive = List.filter (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive) regs in
     peers_json := `List (List.map registration_to_json regs);
     add_check "peer_discovery" true
       (Printf.sprintf "%d total, %d alive" (List.length regs) (List.length alive))
   with e ->
     add_check "peer_discovery" false (Printexc.to_string e));
  (* Check 7: room list — collect room records *)
  (try
     let rooms = C2c_mcp.Broker.list_rooms broker in
     rooms_json := `List (List.map room_to_json rooms);
     add_check "room_list" true
       (Printf.sprintf "%d rooms" (List.length rooms))
   with e ->
     add_check "room_list" false (Printexc.to_string e));
  (* Check 8: pending permissions — read pending_permissions.json directly *)
  (try
     let path = Filename.concat broker_root "pending_permissions.json" in
     if not (Sys.file_exists path) then begin
       pending_perms_json := `List [];
       add_check "pending_permissions" true "no pending_permissions.json (none active)"
     end else begin
       let json = Yojson.Safe.from_file path in
       let open Yojson.Safe.Util in
       match json with
       | `List items ->
           let now = Unix.gettimeofday () in
           let active =
             List.filter_map
               (fun item ->
                 match item with
                 | `Assoc _ ->
                     (match member "expires_at" item with
                      | `Float f when f > now ->
                          Some (`Assoc
                            [ ("perm_id", member "perm_id" item)
                            ; ("kind", member "kind" item)
                            ; ("requester_alias", member "requester_alias" item)
                            ; ("supervisors", member "supervisors" item)
                            ; ("expires_at", member "expires_at" item)
                            ])
                      | _ -> None)
                 | _ -> None)
               items
           in
           pending_perms_json := `List active;
           add_check "pending_permissions" true
             (Printf.sprintf "%d active pending" (List.length active))
       | _ ->
           pending_perms_json := `List [];
           add_check "pending_permissions" true "pending_permissions.json empty"
     end
   with e ->
     pending_perms_json := `List [];
     add_check "pending_permissions" false (Printexc.to_string e));
  (* Assemble JSON output matching DRAFT-gui-requirements lines 160-162:
     snapshot of current swarm state: peers, rooms, and pending permissions *)
  let all_ok = List.for_all (fun c -> c.ok) !checks in
  let json =
    `Assoc
      [ ("ok", `Bool all_ok)
      ; ("ts", `Float (Unix.gettimeofday ()))
      ; ("snapshot",
          `Assoc
            [ ("peers", !peers_json)
            ; ("rooms", !rooms_json)
            ; ("pending_permissions", !pending_perms_json)
            ])
      ; ("checks", `List (List.map (fun c ->
          `Assoc
            [ ("name", `String c.name)
            ; ("ok", `Bool c.ok)
            ; ("detail", `String c.detail)
            ]) !checks))
      ]
  in
  output_string stderr (Yojson.Safe.to_string json ^ "\n");
  flush stderr;
  exit (if all_ok then 0 else 1)

let gui_cmd =
  let detach =
    Cmdliner.Arg.(value & flag & info [ "detach"; "d" ] ~doc:"Detach from terminal (run in background).")
  in
  let batch =
    Cmdliner.Arg.(value & flag & info [ "batch"; "b" ]
      ~doc:"Headless smoke test: verify broker, peers, and rooms. Outputs JSON to stderr and exits.")
  in
  let+ detach = detach
  and+ batch = batch in
  if batch then gui_batch ()
  else
    match find_gui_binary () with
    | None ->
        Printf.eprintf "c2c gui: c2c-gui binary not found.\n";
        Printf.eprintf "  Build it with: cd gui && cargo tauri build\n";
        Printf.eprintf "  Or install the .deb/.rpm from gui/src-tauri/target/release/bundle/\n";
        exit 1
    | Some bin ->
        if detach then begin
          (match Unix.fork () with
          | 0 ->
              Unix.setsid () |> ignore;
              Unix.execv bin [| bin |]
          | _ -> exit 0)
        end else begin
          let pid = Unix.create_process bin [| bin |] Unix.stdin Unix.stdout Unix.stderr in
          let _, status = Unix.waitpid [] pid in
          exit (match status with
            | Unix.WEXITED code -> code
            | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 1)
        end

let gui = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "gui"
     ~doc:"Launch the c2c desktop GUI, or run a headless smoke test."
     ~man:[ `S "DESCRIPTION"
          ; `P "With no flags, launches the c2c-gui Tauri desktop application. \
                Searches for the c2c-gui binary in PATH and alongside the c2c binary. \
                Use $(b,--detach) to run it in the background."
          ; `P "$(b,c2c gui --batch) runs a headless smoke test that verifies the \
                broker is reachable and exercises peer discovery and room listing. \
                Outputs a JSON snapshot to stderr and exits 0 on success, non-zero on failure. \
                Suitable for CI and operator inspection without a display."
          ])
  gui_cmd

(* --- subcommand: stop ----------------------------------------------------- *)

let stop_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to stop.")
  in
  let+ json = json_flag
  and+ name = name in
  let output_mode = if json then Json else Human in
  let self_check =
    match Sys.getenv_opt "C2C_INSTANCE_NAME" with
    | Some self_name when self_name = name ->
        Some "cannot stop your own session"
    | _ -> None
  in
  if self_check <> None then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Option.value self_check ~default:"")) ])
     | Human -> Printf.eprintf "error: %s\n%!" (Option.value self_check ~default:""));
    exit 1
  end;
  let inst_path = instances_dir () // name in
  if not (Sys.file_exists inst_path) then begin
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String (Printf.sprintf "instance '%s' not found" name)) ])
     | Human -> Printf.eprintf "error: instance '%s' not found.\n%!" name);
    exit 1
  end;
  let outer_pid_path = inst_path // "outer.pid" in
  let result =
    if Sys.file_exists outer_pid_path then begin
      let pid_s =
        let ic = open_in outer_pid_path in
        Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
          let s = input_line ic in String.trim s)
      in
      match int_of_string_opt pid_s with
      | Some pid ->
          (try
             Unix.kill pid Sys.sigterm;
             let stopped = ref false in
             for _ = 1 to 10 do
               if not !stopped then begin
                 (try ignore (Unix.kill pid 0) with Unix.Unix_error _ -> stopped := true);
                 if not !stopped then Unix.sleepf 0.5
               end
             done;
             if not !stopped then
               (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
             "stopped"
           with Unix.Unix_error _ -> "stopped")
      | None -> "no pid found"
    end else "not running"
  in
  match output_mode with
  | Json ->
      print_json (`Assoc [ ("ok", `Bool true); ("name", `String name); ("status", `String result) ])
  | Human ->
      Printf.printf "Instance '%s': %s\n" name result

let stop = Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop a managed c2c instance.") stop_cmd

let restart_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to restart.")
  in
  let timeout =
    Cmdliner.Arg.(value & opt (some float) None & info [ "timeout" ]
      ~docv:"SECONDS"
      ~doc:"Seconds to wait for outer process to exit before spawning restart (default: 5).")
  in
  let+ name = name
  and+ timeout = timeout in
  let timeout_s = Option.value timeout ~default:5.0 in
  exit (C2c_start.cmd_restart name ~timeout_s)

let restart = Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart" ~doc:"Restart a managed c2c instance.") restart_cmd

let reset_thread_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name to reset.")
  in
  let thread_id =
    Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"THREAD" ~doc:"Exact Codex thread/session target to resume.")
  in
  let+ name = name
  and+ thread_id = thread_id in
  exit (C2c_start.cmd_reset_thread name thread_id)

let reset_thread =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "reset-thread"
       ~doc:"Restart a managed codex/codex-headless instance onto a specific thread.")
    reset_thread_cmd

let restart_self_cmd =
  let name =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name (default: \\$C2C_MCP_SESSION_ID).")
  in
  let+ name = name in
  exit (C2c_start.cmd_restart_self ?name ())

let restart_self = Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart-self" ~doc:"Signal our own managed inner client so the outer loop relaunches it. Intended for agents to reload themselves after a binary update; name falls back to \\$C2C_MCP_SESSION_ID.") restart_self_cmd

(* --- help subcommand ------------------------------------------------------- *)

(* `c2c help [COMMAND...]` is a plain-English alias for `c2c [COMMAND...] --help`.
   Re-exec ourselves with `--help` appended so we get Cmdliner's full rendering
   (man-page layout, pager, and the sanitize_help_env fix) without having to
   reach into Cmdliner internals. *)
let help_cmd =
  let args =
    Cmdliner.Arg.(
      value & pos_all string []
      & info [] ~docv:"COMMAND"
          ~doc:"Subcommand path to show help for. With no args, shows top-level help.")
  in
  let+ args = args in
  let self = if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c" in
  let new_argv = Array.of_list (self :: args @ [ "--help" ]) in
  (try Unix.execvp self new_argv
   with Unix.Unix_error (err, _, _) ->
     prerr_endline ("c2c help: " ^ Unix.error_message err);
     exit 125)

let help =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "help"
       ~doc:"Show help for c2c or a subcommand (alias for --help)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P "Prints the same help as $(b,--help). With no arguments, shows the \
               top-level c2c help. Arguments are treated as a subcommand path, \
               so $(b,c2c help install) is equivalent to $(b,c2c install --help), \
               and $(b,c2c help rooms list) mirrors $(b,c2c rooms list --help)."
         ])
    help_cmd

(* --- keycode parsing for inject ------------------------------------------- *)

(** [inject_keycode s] parses a keycode literal and returns the expanded string.
    Supported keycodes:
      :enter  -> "\r"
      :esc    -> "\x1b"
      :ctrlc  -> "\x03"
      :ctrlz  -> "\x1a"
      :up     -> "\x1b[A"
      :down   -> "\x1b[B"
      :left   -> "\x1b[D"
      :right  -> "\x1b[C"
      :tab    -> "\x09"
      :backspace -> "\x7f"
    Plain text is returned as-is. Unknown :xxx forms cause an error. *)
let inject_keycode (s : string) : string =
  match s with
  | ":enter" -> "\r"
  | ":esc" -> "\x1b"
  | ":ctrlc" -> "\x03"
  | ":ctrlz" -> "\x1a"
  | ":up" -> "\x1b[A"
  | ":down" -> "\x1b[B"
  | ":left" -> "\x1b[D"
  | ":right" -> "\x1b[C"
  | ":tab" -> "\x09"
  | ":backspace" -> "\x7f"
  | other ->
      if String.length other > 0 && other.[0] = ':' then (
        Printf.eprintf "error: unknown keycode %S. Known: :enter, :esc, :ctrlc, :ctrlz, :up, :down, :left, :right, :tab, :backspace\n%!" other;
        exit 1)
      else other

(* --- UUID and timestamp helpers for history injection --- *)

(** Generate a random UUID v4 string. *)
let uuid_v4 () =
  let hex_char n =
    let hex_chars = "0123456789abcdef" in
    hex_chars.[n land 0xf]
  in
  let segment n = String.init n (fun _ -> hex_char (Random.int 16)) in
  let segments = Array.init 5 (fun i ->
    match i with
    | 0 -> segment 8
    | 1 -> segment 4
    | 2 -> "4" ^ segment 3
    | 3 -> String.make 1 "abcdef".[Random.int 6] ^ segment 3
    | 4 -> segment 12
    | _ -> segment 8)  (* should not happen *)
  in
  Printf.sprintf "%s-%s-%s-%s-%s" segments.(0) segments.(1) segments.(2) segments.(3) segments.(4)

(** Return current UTC timestamp as ISO 8601 string. *)
let timestamp_utc () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

(** Slugify a path for Claude project directory naming.
    "/home/xertrov/foo" -> "-home-xertrov-foo" *)
let slugify_path (path : string) : string =
  String.map (fun c -> if c = '/' then '-' else c) path

(* --- session resolution for inject (pure OCaml) --- *)

(** Read a session JSON file and return session data as an assoc list.
    Returns None if the file doesn't exist or is invalid JSON. *)
let read_session_json (path : string) : (string * Yojson.Safe.t) list option =
  try
    let json = Yojson.Safe.from_file path in
    Some (Yojson.Safe.Util.to_assoc json)
  with _ -> None

(** Find a session by session_id or PID in a session JSON file.
    Returns Some (sessionId, cwd, pid) if found. *)
let find_session_in_file (path : string) (identifier : string) :
    (string * string * int) option =
  match read_session_json path with
  | None -> None
  | Some fields ->
      let get_string key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_string) with _ -> None
      in
      let get_int key =
        try Some (List.assoc key fields |> Yojson.Safe.Util.to_int) with _ -> None
      in
      let session_id = get_string "sessionId" in
      let name = get_string "name" in
      let pid = get_int "pid" in
      let cwd = get_string "cwd" in
      let matches =
        (match session_id with Some s when s = identifier -> true | _ -> false) ||
        (match name with Some n when n = identifier -> true | _ -> false) ||
        (match pid with Some p when string_of_int p = identifier -> true | _ -> false)
      in
      if matches then
        match session_id, cwd, pid with
        | Some sid, Some c, Some p -> Some (sid, c, p)
        | _ -> None
      else None

(** Iterate over session directories looking for a matching session.
    Returns Some (session_id, cwd, pid) if found. *)
let find_session_by_identifier (identifier : string) :
    (string * string * int) option =
  let session_dirs = [
    (Sys.getenv "HOME") ^ "/.claude/sessions";
    (Sys.getenv "HOME") ^ "/.claude-p/sessions";
    (Sys.getenv "HOME") ^ "/.claude-w/sessions";
  ] in
  let rec walk_dirs dirs =
    match dirs with
    | [] -> None
    | dir :: rest ->
        if Sys.is_directory dir then
          let entries =
            try Array.to_list (Sys.readdir dir)
            with Sys_error _ -> []
          in
          let rec check_entries entries =
            match entries with
            | [] -> walk_dirs rest
            | entry :: rest_entries ->
                let path = Filename.concat dir entry in
                (match find_session_in_file path identifier with
                 | Some result -> Some result
                 | None -> check_entries rest_entries)
          in
          check_entries entries
        else walk_dirs rest
  in
  walk_dirs session_dirs

(** Find the transcript path for a session.
    Searches in ~/.claude/projects/ for a file named <session_id>.jsonl.
    Also tries the slugified cwd path. *)
let find_transcript_path (session_id : string) (cwd : string option) : string option =
  let home = Sys.getenv "HOME" in
  let projects_dir = Filename.concat home ".claude/projects" in
  if Sys.is_directory projects_dir then
    let entries =
      try Array.to_list (Sys.readdir projects_dir)
      with Sys_error _ -> []
    in
    let rec check entries =
      match entries with
      | [] -> None
      | entry :: rest ->
          let jsonl_path = Filename.concat projects_dir (Filename.concat entry (session_id ^ ".jsonl")) in
          if Sys.file_exists jsonl_path then Some jsonl_path
          else check rest
    in
    check entries
  else None

(* --- history injection (pure OCaml) --- *)

(** Inject a message by appending a user entry to the session's history.jsonl.
    Returns the transcript path used on success, or None on failure. *)
let inject_via_history (session_id : string) (cwd : string option) (message : string) : string option =
  let transcript_path =
    match cwd with
    | Some c ->
        (* Try slugified cwd path first *)
        let slug = slugify_path c in
        let home = Sys.getenv "HOME" in
        let path = Filename.concat home (Printf.sprintf ".claude/projects/%s/%s.jsonl" slug session_id) in
        if Sys.file_exists path then Some path else None
    | None -> None
  in
  let transcript_path =
    match transcript_path with
    | Some p -> Some p
    | None ->
        (* Try to find by scanning projects dir *)
        find_transcript_path session_id cwd
  in
  match transcript_path with
  | None -> None
  | Some path ->
      let parent_uuid = uuid_v4 () in
      let entry = `Assoc [
        ("parentUuid", `String parent_uuid);
        ("isSidechain", `Bool false);
        ("promptId", `String (uuid_v4 ()));
        ("type", `String "user");
        ("message", `Assoc [
            ("role", `String "user");
            ("content", `String message)
          ]);
        ("uuid", `String (uuid_v4 ()));
        ("timestamp", `String (timestamp_utc ()));
        ("userType", `String "external");
        ("entrypoint", `String "cli");
        ("cwd", `String (Option.value cwd ~default:"/home/xertrov"));
        ("sessionId", `String session_id);
        ("version", `String "2.1.109");
        ("gitBranch", `String "HEAD")
      ] in
      (try
         let oc = open_out_gen [Open_creat; Open_append] 0o644 path in
         Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
           output_string oc (Yojson.Safe.to_string entry ^ "\n"));
         Some path
       with Sys_error _ -> None)

let c2c_config_path () =
  Filename.concat (Sys.getcwd ()) (Filename.concat ".c2c" "config.toml")

let config_read () : (string * string) list =
  let path = c2c_config_path () in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) @@ fun () ->
      let rec loop acc =
        match try Some (input_line ic) with End_of_file -> None with
        | None -> List.rev acc
        | Some line ->
          let trimmed = String.trim line in
          if trimmed = "" || String.length trimmed > 0 && trimmed.[0] = '#' then loop acc
          else match String.index_opt trimmed '=' with
            | None -> loop acc
            | Some i ->
              let k = String.trim (String.sub trimmed 0 i) in
              let v_raw = String.trim (String.sub trimmed (i+1) (String.length trimmed - i - 1)) in
              let v =
                let n = String.length v_raw in
                if n >= 2 && v_raw.[0] = '"' && v_raw.[n-1] = '"' then String.sub v_raw 1 (n-2)
                else v_raw
              in
              loop ((k, v) :: acc)
      in
      loop []

let config_write (entries : (string * string) list) : unit =
  let path = c2c_config_path () in
  let dir = Filename.dirname path in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc "# c2c per-repo config (.c2c/config.toml)\n";
    output_string oc "# Generated/edited by `c2c config ...`.\n\n";
    List.iter (fun (k, v) ->
      Printf.fprintf oc "%s = \"%s\"\n" k v
    ) entries
  );
  Unix.rename tmp path

let config_set (key : string) (value : string) : unit =
  let existing = config_read () in
  let without = List.filter (fun (k, _) -> k <> key) existing in
  let updated = without @ [(key, value)] in
  config_write updated

let valid_generation_clients = ["claude"; "opencode"; "codex"]

let config_show_term =
  let+ () = Cmdliner.Term.const () in
  let entries = config_read () in
  if entries = [] then Printf.printf "(no config set — %s)\n" (c2c_config_path ())
  else List.iter (fun (k, v) -> Printf.printf "%s = %s\n" k v) entries

let config_generation_client_term =
  let value =
    Cmdliner.Arg.(value & pos 0 (some string) None & info [] ~docv:"CLIENT"
      ~doc:("Set generation_client to one of: " ^ String.concat ", " valid_generation_clients ^
            ". Omit to show current value."))
  in
  let+ value = value in
  match value with
  | None ->
    (match List.assoc_opt "generation_client" (config_read ()) with
     | Some v -> print_endline v
     | None -> Printf.printf "(unset — default would be opencode when needed)\n")
  | Some v ->
    if not (List.mem v valid_generation_clients) then begin
      Printf.eprintf "error: '%s' not one of %s\n%!" v (String.concat ", " valid_generation_clients);
      exit 1
    end;
    config_set "generation_client" v;
    Printf.printf "generation_client = %s\n  written: %s\n" v (c2c_config_path ())

let config_show_cmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "show" ~doc:"Show current c2c config values.") config_show_term
let config_generation_client_cmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "generation-client"
    ~doc:"Show or set the generation_client preference — which client handles code generation in multi-agent workflows (claude|opencode|codex).")
  config_generation_client_term

let config_group =
  Cmdliner.Cmd.group ~default:config_show_term
    (Cmdliner.Cmd.info "config" ~doc:"Manage .c2c/config.toml — per-repo c2c configuration.")
    [config_show_cmd; config_generation_client_cmd]

(* --- PTY injection (shell out to pty_inject helper) --- *)

(** Path to the pty_inject helper binary. *)
let pty_inject_path () =
  match Sys.getenv_opt "C2C_PTY_INJECT" with
  | Some p -> p
  | None -> "/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject"

(** Inject via PTY using the pty_inject helper.
    Writes bracketed paste sequence then Enter after submit_delay seconds. *)
let inject_via_pty (terminal_pid : int) (pts_num : string) (message : string)
    ~(submit_delay : float) : bool =
  let inject_bin = pty_inject_path () in
  if not (Sys.file_exists inject_bin) then (
    Printf.eprintf "error: pty_inject helper not found at %s\n%!" inject_bin;
    false
  ) else
    let cmd = Printf.sprintf "%s %d %s '%s' %.3f"
      inject_bin terminal_pid pts_num
      (String.escaped message) submit_delay
    in
    let rc = Sys.command cmd in
    rc = 0

(* --- PTY helpers (shared by inject and screen) --- *)

(** Extract pts number from a /dev/pts/N path string. *)
let extract_pts (path : string) : string option =
  let prefix = "/dev/pts/" in
  if String.length path > String.length prefix
     && String.sub path 0 (String.length prefix) = prefix
  then
    Some (String.sub path (String.length prefix)
            (String.length path - String.length prefix))
  else None

(** Read the tty symlink target for a given fd of a process. *)
let read_tty_link (pid : int) (fd : string) : string option =
  try
    let path = Printf.sprintf "/proc/%d/fd/%s" pid fd in
    Some (Unix.readlink path)
  with _ -> None

(** Read a file's contents as a string. *)
let read_file (path : string) : string =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    really_input_string ic n)

(** Find the pts number for a given PID by checking its stdio fds. *)
let resolve_pts_from_pid (pid : int) : string option =
  List.fold_left (fun acc fd ->
    match acc with
    | Some _ -> acc
    | None ->
        (match read_tty_link pid fd with
         | Some path -> extract_pts path
         | None -> None)
  ) None ["0"; "1"; "2"]

(** Check if a process has a given pts as a master tty-index.
    Returns true if the fdinfo for any fd contains "tty-index:\t<PTS>\n"
    and the fd links to /dev/ptmx. *)
let is_terminal_owner_for_pts (pid : int) (pts_num : string) : bool =
  try
    let fdinfo_dir = Printf.sprintf "/proc/%d/fdinfo" pid in
    if not (Sys.is_directory fdinfo_dir) then false
    else
      let entries = Sys.readdir fdinfo_dir in
      let result = ref false in
      Array.iter (fun entry ->
        if not !result then
          (try
             let fdinfo_path = Filename.concat fdinfo_dir entry in
             let content = read_file fdinfo_path in
             let needle = Printf.sprintf "tty-index:\t%s\n" pts_num in
             if String.length content >= String.length needle
                && String.sub content 0 (String.length needle) = needle
             then
               (try
                  let fd_path = Printf.sprintf "/proc/%d/fd/%s" pid entry in
                  let link = Unix.readlink fd_path in
                  if link = "/dev/ptmx" then result := true
                with _ -> ())
           with _ -> ())
      ) entries;
      !result
  with _ -> false

(** Walk the parent chain of a process looking for one that owns the given pts.
    Returns the terminal owner's PID if found. *)
let find_terminal_owner (session_pid : int) (pts_num : string) : int option =
  let rec walk (pid : int) (seen : int list) =
    if List.mem pid seen then None
    else
      (try
         if is_terminal_owner_for_pts pid pts_num then Some pid
         else
           let ppid =
             try
               let status_path = Printf.sprintf "/proc/%d/status" pid in
               let content = read_file status_path in
               let rec find_ppid lines =
                 match lines with
                 | [] -> None
                 | line :: rest ->
                     if String.length line >= 6
                        && String.sub line 0 6 = "PPid:\t"
                     then
                       (try Some (int_of_string (String.sub line 6 (String.length line - 6)))
                        with _ -> None)
                     else find_ppid rest
               in
               find_ppid (String.split_on_char '\n' content)
             with _ -> None
           in
           match ppid with
           | Some parent when parent > 0 -> walk parent (pid :: seen)
           | _ -> None
      with _ -> None)
  in
  walk session_pid []

(* --- inject target resolution (pure OCaml) --- *)

(** Result of resolving an injection target. *)
type inject_target = {
  terminal_pid : int;  (* 0 if not available (SSH session) *)
  pts_num : string;
  session_id : string option;
  cwd : string option;
  has_terminal_owner : bool;
}

(** Resolve an injection target from claude session identifier, PID, or explicit coords.
    For SSH sessions (no terminal owner), terminal_pid=0 but pts_num is still returned. *)
let resolve_inject_target
    (claude_session : string option)
    (pid : int option)
    (terminal_pid : int option)
    (pts : string option) : inject_target =
  match claude_session, pid, (terminal_pid, pts) with
  | Some session, None, (None, None) -> (
      (* Resolve by session identifier *)
      match find_session_by_identifier session with
      | None ->
          Printf.eprintf "error: session %S not found\n%!" session;
          exit 1
      | Some (session_id, cwd, proc_pid) ->
          let pts_num =
            match resolve_pts_from_pid proc_pid with
            | Some p -> p
            | None -> (
                (* Try with the session id directly as a PID hint *)
                match int_of_string_opt session with
                | Some p when p > 0 ->
                    (match resolve_pts_from_pid p with
                     | Some p -> p
                     | None -> "0")
                | _ -> "0"
              )
          in
          let tp, has_tp =
            match find_terminal_owner proc_pid pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = Some session_id; cwd = Some cwd;
            has_terminal_owner = has_tp }
    )
  | None, Some p, (None, None) -> (
      (* Resolve by PID *)
      match resolve_pts_from_pid p with
      | None ->
          Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" p;
          exit 1
      | Some pts_num ->
          let tp, has_tp =
            match find_terminal_owner p pts_num with
            | Some t -> (t, true)
            | None -> (0, false)
          in
          { terminal_pid = tp; pts_num; session_id = None; cwd = None;
            has_terminal_owner = has_tp }
    )
  | _, _, (Some tp, Some pn) ->
      (* Explicit coordinates *)
      { terminal_pid = tp; pts_num = pn; session_id = None; cwd = None;
        has_terminal_owner = tp > 0 }
  | _ ->
      Printf.eprintf "error: must specify --claude-session, --pid, or --terminal-pid + --pts\n%!";
      exit 1

(* --- subcommand: inject claude -------------------------------------------- *)

(** Escape a string for XML attribute values. *)
let xml_escape (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '&' -> Buffer.add_string b "&amp;"
    | '<' -> Buffer.add_string b "&lt;"
    | '>' -> Buffer.add_string b "&gt;"
    | '"' -> Buffer.add_string b "&quot;"
    | _ -> Buffer.add_char b c
  ) s;
  Buffer.contents b

(** Render a message payload as a <c2c> XML envelope. If [raw] is true,
    returns the message unchanged. *)
let render_payload (message : string) (event : string) (sender : string)
    (alias : string) (raw : bool) : string =
  if raw || String.length message > 0 && message.[0] = '<' then
    message
  else
    let attrs = Printf.sprintf "event=%S from=%S"
      event (xml_escape sender)
    in
    let attrs = if alias <> "" then attrs ^ Printf.sprintf " alias=%S" (xml_escape alias) else attrs in
    let attrs = attrs ^ " source=\"pty\" source_tool=\"c2c_inject\" action_after=\"continue\"" in
    Printf.sprintf "<c2c %s>\n%s\n</c2c>" attrs message

(** The submit delay for Kimi clients (in seconds). *)
let kimi_submit_delay = 1.5

(** Effective submit delay for a given client. Returns the explicit delay or
    the client-specific default. *)
let effective_submit_delay (client : string) (explicit_delay : float option) : float =
  match explicit_delay with
  | Some d -> d
  | None ->
      if client = "kimi" then kimi_submit_delay
      else 0.2

(** Inject command: one-shot message/keycode injection into a Claude/Codex session. *)
let inject_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "claude-session" ] ~docv:"NAME_OR_ID"
      ~doc:"Target Claude session by name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "pid" ] ~docv:"PID"
      ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None &
      info [ "terminal-pid" ] ~docv:"PID"
      ~doc:"Terminal emulator PID (use with --pts).")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "pts" ] ~docv:"N"
      ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let client =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "client" ] ~docv:"CLIENT"
      ~doc:"Client label: claude, codex, opencode, kimi, generic (default: generic).")
  in
  let event =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "event" ] ~docv:"EVENT"
      ~doc:"Event tag (default: message).")
  in
  let sender =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "from" ] ~docv:"SENDER"
      ~doc:"Sender name (default: c2c-inject).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "alias" ] ~docv:"ALIAS"
      ~doc:"Sender alias.")
  in
  let raw =
    Cmdliner.Arg.(value & flag &
      info [ "raw" ]
      ~doc:"Do not wrap message in <c2c> XML envelope.")
  in
  let delay =
    Cmdliner.Arg.(value & opt (some float) None &
      info [ "delay" ] ~docv:"MS"
      ~doc:"Delay between parts in milliseconds (default: 500).")
  in
  let method_ =
    Cmdliner.Arg.(value & opt (some string) None &
      info [ "method" ] ~docv:"METHOD"
      ~doc:"Injection method: pty, history, auto (default: auto).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag &
      info [ "dry-run" ]
      ~doc:"Show what would be injected without sending.")
  in
  let json =
    Cmdliner.Arg.(value & flag &
      info [ "json" ]
      ~doc:"Output JSON result.")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts
  and+ client = client
  and+ event = event
  and+ sender = sender
  and+ alias = alias
  and+ raw = raw
  and+ delay = delay
  and+ method_ = method_
  and+ dry_run = dry_run
  and+ json = json
  and+ msg_tokens = Cmdliner.Arg.(non_empty & pos_all string [] & info [] ~docv:"MESSAGE" ~doc:"Message text or keycode (:enter, :esc, :ctrlc, etc.)")
  in
  (* Parse tokens: keycodes (:enter etc.) and plain text *)
  let parts : (string * string) list =
    List.map (fun token ->
      if String.length token > 0 && token.[0] = ':' then
        (token, inject_keycode token)
      else
        (token, token)
    ) msg_tokens
  in
  let full_text = String.concat " " (List.map snd parts) in
  let event_str = Option.value event ~default:"message" in
  let sender_str = Option.value sender ~default:"c2c-inject" in
  let alias_str = Option.value alias ~default:"" in
  let client_str = Option.value client ~default:"generic" in
  let method_str = Option.value method_ ~default:"auto" in
  let delay_ms = Option.value delay ~default:500.0 in
  let delay_s = delay_ms /. 1000.0 in
  let submit_delay = effective_submit_delay client_str (Some delay_s) in
  let payload = render_payload full_text event_str sender_str alias_str raw in
  if dry_run then (
    let action = "would inject" in
    let method_desc = if method_str <> "auto" then Printf.sprintf " via %s" method_str else "" in
    let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
    print_endline (Printf.sprintf "%s into %s%s: %s" action client_str method_desc text_preview);
    exit 0
  );
  (* Resolve target *)
  let target = resolve_inject_target claude_session pid terminal_pid pts in
  let method_used = ref None in
  (* Try PTY injection if method is pty or auto *)
  if !method_used = None && (method_str = "pty" || method_str = "auto") then
    if target.terminal_pid > 0 then (
      let ok = inject_via_pty target.terminal_pid target.pts_num payload ~submit_delay in
      if ok then method_used := Some "pty"
    );
  (* Try history injection if method is history or auto *)
  if !method_used = None && (method_str = "history" || method_str = "auto") then
    match target.session_id with
    | None ->
        Printf.eprintf "error: history injection requires --claude-session (session ID unknown for --pid/--terminal-pid)\n%!";
        exit 1
    | Some session_id ->
        match inject_via_history session_id target.cwd full_text with
        | None ->
            Printf.eprintf "error: history injection failed (transcript not found)\n%!";
            exit 1
        | Some _path ->
            method_used := Some "history"
  ;
  (match !method_used with
   | None ->
       Printf.eprintf "error: injection failed (tried pty and history)\n%!";
       exit 1
   | Some m ->
       if json then (
         let result = `Assoc [
           ("ok", `Bool true);
           ("client", `String client_str);
           ("method", `String m);
           ("terminal_pid", `Int target.terminal_pid);
           ("pts", `String target.pts_num);
           ("payload", `String (String.sub payload 0 (min (String.length payload) 200)));
           ("dry_run", `Bool false);
           ("submit_delay", `Float submit_delay);
         ] in
         print_endline (Yojson.Safe.pretty_to_string result)
       ) else (
         let text_preview = if String.length full_text > 50 then String.sub full_text 0 50 ^ "..." else full_text in
         print_endline (Printf.sprintf "injected into %s via %s: %s" client_str m text_preview)
       )
  );
  exit 0

let inject = Cmdliner.Cmd.v (Cmdliner.Cmd.info "inject" ~doc:"Inject messages or keycodes into a live session.") inject_cmd

(* --- subcommand group: wire-daemon ---------------------------------------- *)

let wire_daemon_start_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID for the wire daemon (used as pidfile key).")
  in
  let alias =
    Cmdliner.Arg.(value & opt (some string) None & info ["alias"] ~docv:"ALIAS"
                    ~doc:"Alias to register (defaults to session-id).")
  in
  let command =
    Cmdliner.Arg.(value & opt string "kimi" & info ["command"] ~docv:"CMD"
                    ~doc:"kimi binary to invoke (default: kimi).")
  in
  let work_dir =
    Cmdliner.Arg.(value & opt string "." & info ["work-dir"] ~docv:"DIR"
                    ~doc:"Working directory for kimi --wire (default: .).")
  in
  let interval =
    Cmdliner.Arg.(value & opt float 5.0 & info ["interval"] ~docv:"SEC"
                    ~doc:"Seconds between inbox polls (default: 5.0).")
  in
  let+ json = json_flag
  and+ session_id = session_id
  and+ alias_opt = alias
  and+ command = command
  and+ work_dir = work_dir
  and+ interval = interval in
  let alias = Option.value alias_opt ~default:session_id in
  let broker_root = resolve_broker_root () in
  let (st, action) =
    C2c_wire_daemon.start_daemon
      ~session_id ~alias ~broker_root ~command ~work_dir ~interval
  in
  (match action with
   | `Already_running ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("already_running", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else
         Printf.printf "wire-daemon already running for %s (pid %s)\n"
           session_id (Option.fold ~none:"?" ~some:string_of_int st.pid)
   | `Started ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("started", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else begin
         if st.running then
           Printf.printf "wire-daemon started for %s (pid %s)\n"
             session_id (Option.fold ~none:"?" ~some:string_of_int st.pid)
         else
           Printf.printf "wire-daemon fork failed for %s\n" session_id
       end)

let wire_daemon_stop_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID of the daemon to stop.")
  in
  let+ json = json_flag
  and+ session_id = session_id in
  let (st, action) = C2c_wire_daemon.stop_daemon session_id in
  (match action with
   | `Not_running ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("not_running", `Bool true) ])
       else
         Printf.printf "wire-daemon not running for %s\n" session_id
   | `Stopped ->
       if json then
         print_json (`Assoc [ ("ok", `Bool true); ("stopped", `Bool true);
                               ("status", C2c_wire_daemon.status_to_json st) ])
       else
         Printf.printf "wire-daemon stopped for %s\n" session_id)

let wire_daemon_status_cmd =
  let session_id =
    Cmdliner.Arg.(required & opt (some string) None & info ["session-id"] ~docv:"ID"
                    ~doc:"Session ID to query.")
  in
  let+ json = json_flag
  and+ session_id = session_id in
  let st = C2c_wire_daemon.get_status session_id in
  if json then
    print_json (C2c_wire_daemon.status_to_json st)
  else begin
    Printf.printf "session_id: %s\n" st.session_id;
    Printf.printf "running:    %s\n" (string_of_bool st.running);
    (match st.pid with
     | Some p -> Printf.printf "pid:        %d\n" p
     | None   -> Printf.printf "pid:        (none)\n");
    Printf.printf "pidfile:    %s\n" st.pidfile;
    (match st.logfile with
     | Some l -> Printf.printf "log:        %s\n" l
     | None   -> ())
  end

let wire_daemon_list_cmd =
  let+ json = json_flag in
  let daemons = C2c_wire_daemon.list_daemons () in
  if json then
    print_json (`List (List.map C2c_wire_daemon.status_to_json daemons))
  else begin
    if daemons = [] then
      Printf.printf "no wire daemons found\n"
    else
      List.iter (fun (st : C2c_wire_daemon.daemon_status) ->
          let pid_str = Option.fold ~none:"(none)" ~some:string_of_int st.pid in
          Printf.printf "%s  pid=%-8s  %s\n"
            st.session_id pid_str
            (if st.running then "running" else "stopped"))
        daemons
  end

let wire_daemon_format_prompt_cmd =
  let json_messages =
    Cmdliner.Arg.(required & opt (some string) None & info [ "json-messages" ] ~docv:"JSON"
      ~doc:"JSON array of {from_alias,to_alias,content} message objects.")
  in
  let+ json_messages = json_messages in
  let msgs_json = Yojson.Safe.from_string json_messages in
  let msgs = match msgs_json with
    | `List items -> List.filter_map (function
        | `Assoc _ as obj ->
            let get_str key = match List.assoc_opt key (match obj with `Assoc f -> f | _ -> []) with
              | Some (`String s) -> s | _ -> "" in
            Some C2c_mcp.{ from_alias = get_str "from_alias"
                          ; to_alias   = get_str "to_alias"
                          ; content    = get_str "content"
                          ; deferrable = false
                          ; reply_via = None
                          ; enc_status = None
                          ; ts = 0.0; ephemeral = false }
        | _ -> None) items
    | _ -> []
  in
  print_string (C2c_wire_bridge.format_prompt msgs)

let wire_daemon_spool_write_cmd =
  let spool_path_arg =
    Cmdliner.Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to spool file.")
  in
  let json_messages =
    Cmdliner.Arg.(required & opt (some string) None & info [ "json-messages" ] ~docv:"JSON"
      ~doc:"JSON array of {from_alias,to_alias,content} message objects.")
  in
  let+ spool_path = spool_path_arg and+ json_messages = json_messages in
  let msgs_json = Yojson.Safe.from_string json_messages in
  let msgs = match msgs_json with
    | `List items -> List.filter_map (function
        | `Assoc _ as obj ->
            let get_str key = match List.assoc_opt key (match obj with `Assoc f -> f | _ -> []) with
              | Some (`String s) -> s | _ -> "" in
            Some C2c_mcp.{ from_alias = get_str "from_alias"
                          ; to_alias   = get_str "to_alias"
                          ; content    = get_str "content"
                          ; deferrable = false
                          ; reply_via = None
                          ; enc_status = None
                          ; ts = 0.0; ephemeral = false }
        | _ -> None) items
    | _ -> []
  in
  let sp = C2c_wire_bridge.spool_of_path spool_path in
  C2c_wire_bridge.spool_write sp msgs

let wire_daemon_spool_read_cmd =
  let spool_path_arg =
    Cmdliner.Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to spool file.")
  in
  let+ spool_path = spool_path_arg in
  let sp = C2c_wire_bridge.spool_of_path spool_path in
  let msgs = C2c_wire_bridge.spool_read sp in
  let items = List.map (fun (m : C2c_mcp.message) ->
      `Assoc [ ("from_alias", `String m.from_alias)
             ; ("to_alias",   `String m.to_alias)
             ; ("content",    `String m.content) ]) msgs in
  print_json (`List items)

let wire_daemon_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "wire-daemon"
       ~doc:"Manage Kimi Wire bridge daemon lifecycle (start/stop/status/list).")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "start"  ~doc:"Start a wire-daemon for a session.") wire_daemon_start_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop"   ~doc:"Stop a running wire-daemon.") wire_daemon_stop_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "status" ~doc:"Show status of a wire-daemon.") wire_daemon_status_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "list"   ~doc:"List all wire-daemon state files.") wire_daemon_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "format-prompt" ~doc:"[diagnostic] Format broker messages as Wire prompt text.") wire_daemon_format_prompt_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "spool-write" ~doc:"[diagnostic] Write messages to a spool file.") wire_daemon_spool_write_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "spool-read"  ~doc:"[diagnostic] Read messages from a spool file as JSON.") wire_daemon_spool_read_cmd
    ]

(* --- subcommand group: repo ------------------------------------------------ *)

let repo_set_supervisor_cmd =
  let aliases_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"ALIAS[,ALIAS2,...]"
                    ~doc:"Supervisor alias or comma-separated list.")
  in
  let strategy_arg =
    Cmdliner.Arg.(value & opt (some string) None & info ["strategy"; "s"] ~docv:"STRATEGY"
                    ~doc:"Dispatch strategy: first-alive (default), round-robin, broadcast.")
  in
  let+ aliases_str = aliases_arg
  and+ strategy_opt = strategy_arg
  and+ json = json_flag in
  let aliases = List.filter (fun s -> s <> "") (String.split_on_char ',' aliases_str) in
  if aliases = [] then (
    Printf.eprintf "error: at least one alias required\n%!";
    exit 1
  );
  (match strategy_opt with
   | Some s when not (List.mem s valid_strategies) ->
       Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!" s (String.concat ", " valid_strategies);
       exit 1
   | _ -> ());
  let config = load_repo_config () in
  let fields = match config with `Assoc f -> f | _ -> [] in
  let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
  let fields' = ref
    (("supervisors", supervisor_val)
     :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors" && k <> "supervisor_strategy") fields)
  in
  (match strategy_opt with
   | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
   | None -> ());
  save_repo_config (`Assoc !fields');
  let output_mode = if json then Json else Human in
  let strategy_str = match strategy_opt with Some s -> s | None -> "first-alive (default)" in
  (match output_mode with
   | Json ->
       let out = [ ("ok", `Bool true); ("supervisors", supervisor_val); ("config", `String (repo_config_path ())) ] in
       let out = match strategy_opt with Some s -> ("supervisor_strategy", `String s) :: out | None -> out in
       print_json (`Assoc out)
   | Human ->
       Printf.printf "Supervisor set: %s\n" (String.concat ", " aliases);
       Printf.printf "Strategy:      %s\n" strategy_str;
       Printf.printf "Config:        %s\n" (repo_config_path ());
       Printf.printf "Override:      C2C_PERMISSION_SUPERVISOR=alias or C2C_SUPERVISORS=a,b\n")

let repo_show_cmd =
  let+ json = json_flag in
  let config = load_repo_config () in
  let output_mode = if json then Json else Human in
  (match output_mode with
   | Json -> print_json config
   | Human ->
       let path = repo_config_path () in
       if not (Sys.file_exists path) then (
         Printf.printf "No repo config (.c2c/repo.json) — using defaults.\n";
         Printf.printf "  Run: c2c repo set supervisor <alias> to configure.\n"
       ) else (
         Printf.printf "Repo config: %s\n" path;
         let fields = match config with `Assoc f -> f | _ -> [] in
         (match List.assoc_opt "supervisors" fields with
          | Some (`List aliases) ->
              let names = List.filter_map (function `String s -> Some s | _ -> None) aliases in
              Printf.printf "  supervisors: %s\n" (String.concat ", " names)
          | _ ->
              Printf.printf "  supervisors: (not set — default: coordinator1)\n");
         let shown = [ "supervisors"; "permission_supervisors" ] in
         List.iter (fun (k, v) ->
           if not (List.mem k shown) then
             let vstr = match v with `String s -> s | _ -> Yojson.Safe.to_string v in
             Printf.printf "  %s: %s\n" k vstr
         ) fields
       ))

let repo_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "repo"
       ~doc:"Per-repository c2c configuration (supervisors, defaults).")
    [ Cmdliner.Cmd.group
        (Cmdliner.Cmd.info "set" ~doc:"Set a per-repo config value.")
        [ Cmdliner.Cmd.v
            (Cmdliner.Cmd.info "supervisor"
               ~doc:"Set permission supervisor alias(es) for this repo."
               ~man:[ `S "DESCRIPTION"
                    ; `P "Sets the alias(es) that receive permission.ask notifications \
                          when OpenCode needs approval. Stored in .c2c/repo.json."
                    ; `S "EXAMPLES"
                    ; `P "$(b,c2c repo set supervisor coordinator1)"
                    ; `P "$(b,c2c repo set supervisor coordinator1,planner1)  — round-robin"
                    ])
            repo_set_supervisor_cmd
        ]
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "show" ~doc:"Show current repo config.")
        repo_show_cmd
    ]

(* --- subcommand: screen ---------------------------------------------------- *)

(** Resolve a pts number from a Claude session identifier using pure OCaml.
    Returns (terminal_pid, pts_num). For SSH sessions where terminal_pid is empty, returns (0, pts_num).
    Uses session JSON files to find the PID, then reads /proc/<pid>/fd/0 for the current pts. *)
let resolve_claude_session (session : string) : (int * string) =
  match find_session_by_identifier session with
  | None ->
      Printf.eprintf "error: session %S not found\n%!" session;
      exit 1
  | Some (session_id, _cwd, proc_pid) ->
      let pts_num =
        match resolve_pts_from_pid proc_pid with
        | Some p -> p
        | None ->
            (* Session found but process has no pts — try using session_id directly as PID hint *)
            (match int_of_string_opt session with
             | Some p when p > 0 ->
                 (match resolve_pts_from_pid p with
                  | Some p -> p
                  | None -> "0")
             | _ -> "0")
      in
      let tp, has_tp =
        match find_terminal_owner proc_pid pts_num with
        | Some t -> (t, true)
        | None -> (0, false)
      in
      (if tp = 0 && has_tp then () else ());  (* suppress unused warning *)
      (tp, pts_num)

(** Resolve (terminal_pid, pts_num) from a raw process PID.
    We read the pts from /proc/<pid>/fd/{0,1,2} then optionally find the terminal owner
    by walking the parent chain and scanning fdinfos.
    Returns (0, pts_num) if terminal owner cannot be found (e.g., SSH sessions). *)
let resolve_pid_target (pid : int) : (int * string) =
  match resolve_pts_from_pid pid with
  | None ->
      Printf.eprintf "error: pid %d has no /dev/pts on fds 0/1/2\n%!" pid;
      exit 1
  | Some pts_num -> (
      match find_terminal_owner pid pts_num with
      | None ->
          (* Terminal owner not found (e.g., SSH session). Still return pts for screen reading. *)
          (0, pts_num)
      | Some tp -> (tp, pts_num)
    )

let screen_cmd =
  let claude_session =
    Cmdliner.Arg.(value & opt (some string) None & info [ "claude-session" ] ~docv:"NAME_OR_ID" ~doc:"Resolve target by Claude session name, session ID, or PID.")
  in
  let pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "pid" ] ~docv:"PID" ~doc:"Target any process by PID.")
  in
  let terminal_pid =
    Cmdliner.Arg.(value & opt (some int) None & info [ "terminal-pid" ] ~docv:"PID" ~doc:"Terminal emulator PID.")
  in
  let pts =
    Cmdliner.Arg.(value & opt (some string) None & info [ "pts" ] ~docv:"N" ~doc:"PTY slave number (required with --terminal-pid).")
  in
  let+ claude_session = claude_session
  and+ pid = pid
  and+ terminal_pid = terminal_pid
  and+ pts = pts in
  let (_ : int), pts_num =
    match claude_session, pid, (terminal_pid, pts) with
    | Some session, None, (None, None) ->
        (* Resolve via claude_list_sessions.py *)
        resolve_claude_session session
    | None, Some p, (None, None) ->
        (* Resolve via /proc walk *)
        resolve_pid_target p
    | _, _, (Some _tp, Some pn) ->
        (* Explicit coordinates — pts provided directly, terminal_pid not used *)
        (0, pn)
    | _ ->
        Printf.eprintf "error: must specify one of --claude-session, --pid, or --terminal-pid + --pts\n%!";
        exit 1
  in
  let pts_dev = Printf.sprintf "/dev/pts/%s" pts_num in
  if not (Sys.file_exists pts_dev) then (
    Printf.eprintf "error: %s does not exist\n%!" pts_dev;
    exit 1);
  (* Read from the PTY slave — for terminal emulators this gives scrollback buffer.
     For SSH sessions this may block, so we use dd with a short read limit. *)
  let ic = Unix.open_process_in (Printf.sprintf "timeout 1 dd if=%s bs=4096 count=256 2>/dev/null" pts_dev) in
  Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic)) (fun () ->
    let buf = Buffer.create 16384 in
    (try while true do
         let chunk = Bytes.create 4096 in
         let n = input ic chunk 0 4096 in
         if n > 0 then Buffer.add_subbytes buf chunk 0 n else raise End_of_file
       done with End_of_file -> ());
    let content = Buffer.contents buf in
    print_string content;
    if String.length content > 0 && content.[String.length content - 1] <> '\n' then print_newline ()
  )

let screen = Cmdliner.Cmd.v (Cmdliner.Cmd.info "screen" ~doc:"Capture PTY screen content as text.") screen_cmd

(* --- c2c statefile --------------------------------------------------------- *)
(* Read or tail the oc-plugin state snapshot written by stream-write-statefile.
   Path resolution order (same as the sink):
     1. --instance NAME  → ~/.local/share/c2c/instances/<NAME>/oc-plugin-state.json
     2. $C2C_INSTANCE_NAME
     3. ~/.local/share/c2c/oc-plugin-state.json (fallback) *)

let statefile_cmd =
  let open Cmdliner in
  let tail_flag =
    Arg.(value & flag & info ["tail"; "t"] ~doc:"Watch for updates; print each new snapshot as it arrives (like tail -f).")
  in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name (same as C2C_INSTANCE_NAME). Selects the per-instance statefile.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"] ~doc:"Pretty-print the JSON payload (default: compact single line).")
  in
  Term.(const (fun tail instance json_pretty () ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let statefile =
      match name with
      | Some n -> Filename.concat (Filename.concat (Filename.concat base_dir "instances") n) "oc-plugin-state.json"
      | None   -> Filename.concat base_dir "oc-plugin-state.json"
    in
    let format_json raw =
      if json_pretty then
        match (try Some (Yojson.Safe.from_string raw) with _ -> None) with
        | Some j -> Yojson.Safe.pretty_to_string j
        | None   -> raw
      else
        match (try Some (Yojson.Safe.from_string raw) with _ -> None) with
        | Some j -> Yojson.Safe.to_string j
        | None   -> raw
    in
    let print_file () =
      match (try Some (In_channel.input_all (open_in statefile)) with _ -> None) with
      | None     -> Printf.eprintf "statefile not found: %s\n%!" statefile; exit 1
      | Some raw -> print_string (format_json (String.trim raw)); print_newline ()
    in
    if not tail then
      print_file ()
    else begin
      (* Tail mode: poll the file and print on change.
         We use mtime polling (inotifywait not always available). *)
      let last_mtime = ref 0.0 in
      let last_content = ref "" in
      Printf.eprintf "Watching %s (Ctrl-C to stop)\n%!" statefile;
      while true do
        (try
          let st = Unix.stat statefile in
          let mt = st.Unix.st_mtime in
          if mt <> !last_mtime then begin
            last_mtime := mt;
            let raw =
              try String.trim (In_channel.input_all (open_in statefile))
              with _ -> ""
            in
            if raw <> "" && raw <> !last_content then begin
              last_content := raw;
              print_string (format_json raw);
              print_newline ();
              flush stdout
            end
          end
        with _ -> ());
        Unix.sleepf 0.25
      done
    end) $ tail_flag $ instance_arg $ json_flag $ Term.const ())

let statefile_top =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "statefile"
       ~doc:"Read or watch the OpenCode plugin state snapshot."
       ~man:[ `S "DESCRIPTION";
              `P "Reads the JSON state snapshot written by the c2c OpenCode plugin \
                  ($(b,.opencode/plugins/c2c.ts)) via $(b,c2c oc-plugin stream-write-statefile).";
              `P "Without $(b,--tail), prints the current snapshot and exits.";
              `P "With $(b,--tail), watches the file and prints each new snapshot as the \
                  plugin updates it (approximately every agent step).";
              `P "Use $(b,--instance NAME) or $(b,C2C_INSTANCE_NAME) to select the \
                  per-instance statefile (written by managed sessions started with \
                  $(b,c2c start opencode))."; ])
    statefile_cmd

(* --- debug: statefile debug log -------------------------------------------- *)

let debug_statefile_log_cmd =
  let open Cmdliner in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name. Selects the per-instance debug log.")
  in
  let limit_arg =
    Arg.(value & opt int 50 & info ["limit"; "n"] ~docv:"N"
           ~doc:"Maximum number of entries to print (default: 50).")
  in
  let checkpoint_filter_arg =
    Arg.(value & opt (some string) None & info ["checkpoint"; "c"] ~docv:"NAME"
           ~doc:"Only show entries for a specific named checkpoint.")
  in
  Term.(const (fun instance limit checkpoint_filter () ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let log_path =
      match name with
      | Some n -> Filename.concat (Filename.concat base_dir "instances") n // "statefile-debug.jsonl"
      | None   -> Filename.concat base_dir "statefile-debug.jsonl"
    in
    if not (Sys.file_exists log_path) then
      (Printf.eprintf "debug log not found: %s\n%!" log_path; exit 1)
    else ();
    (try
      let ic = open_in log_path in
      let lines = ref [] in
      (try while true do lines := input_line ic :: !lines done with End_of_file -> ());
      close_in ic;
      let all_rev = !lines in
      let filtered =
        match checkpoint_filter with
        | Some cf ->
            List.filter (fun line ->
              match Yojson.Safe.from_string line with
              | `Assoc fields ->
                  (match List.assoc_opt "checkpoint" fields with
                   | Some (`String cp) -> cp = cf
                   | _ -> false)
              | _ -> false) all_rev
        | None -> all_rev
      in
      let to_print =
        let rec take n lst = match n with 0 -> [] | _ -> match lst with [] -> [] | h :: t -> h :: take (n-1) t in
        List.rev (take limit (List.rev filtered))
      in
      List.iter (fun l ->
        match Yojson.Safe.from_string l with
        | `Assoc fields ->
            let ts = match List.assoc_opt "ts" fields with Some (`String s) -> s | _ -> "?" in
            let event = match List.assoc_opt "event" fields with Some (`String e) -> e | _ -> "?" in
            let cp = match List.assoc_opt "checkpoint" fields with Some (`String c) when c <> "" -> " [" ^ c ^ "]" | _ -> "" in
            Printf.printf "%s  %s%s\n%!" ts event cp
        | _ -> print_endline l) to_print;
      (match checkpoint_filter with
       | Some checkpoint when List.length to_print = 0 ->
           Printf.eprintf "no entries found for checkpoint %S\n%!" checkpoint
       | _ -> ())
    with e -> prerr_endline (Printexc.to_string e); exit 1)
  ) $ instance_arg $ limit_arg $ checkpoint_filter_arg $ Term.const ())

let debug_statefile_checkpoint_cmd =
  let open Cmdliner in
  let instance_arg =
    Arg.(value & opt (some string) None & info ["instance"; "i"] ~docv:"NAME"
           ~doc:"Instance name. Selects the per-instance debug log.")
  in
  Term.(const (fun instance checkpoint_name () ->
    if String.trim checkpoint_name = "" then
      (Printf.eprintf "error: checkpoint name cannot be empty\n%!"; exit 1);
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let name =
      match instance with
      | Some n when String.trim n <> "" -> Some (String.trim n)
      | _ -> (match Sys.getenv_opt "C2C_INSTANCE_NAME" with
              | Some n when String.trim n <> "" -> Some (String.trim n)
              | _ -> None)
    in
    let log_path =
      match name with
      | Some n -> Filename.concat (Filename.concat base_dir "instances") n // "statefile-debug.jsonl"
      | None   -> Filename.concat base_dir "statefile-debug.jsonl"
    in
    let now =
      let t = Unix.gettimeofday () in
      let tm = Unix.gmtime t in
      let ms = int_of_float ((t -. Float.round t) *. 1000.0) |> abs in
      Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec ms
    in
    let entry =
      `Assoc
        [ ("ts", `String now)
        ; ("event", `String "named.checkpoint")
        ; ("checkpoint", `String (String.trim checkpoint_name))
        ; ("state", `Null)
        ]
      |> Yojson.Safe.to_string
    in
    try
      let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 log_path in
      output_string oc entry;
      output_char oc '\n';
      close_out oc;
      Printf.printf "checkpoint '%s' written at %s\n%!" (String.trim checkpoint_name) now
    with e -> prerr_endline (Printexc.to_string e); exit 1
  ) $ instance_arg
    $ Arg.(required & pos 0 (some string) None
         & info [] ~docv:"NAME"
             ~doc:"Checkpoint name (e.g. 'pre-compact', 'post-compact').")
    $ Term.const ())

let debug_group =
  let open Cmdliner in
  Cmd.group (Cmd.info "debug" ~doc:"Debug tools for c2c statefile and broker.")
    [ Cmd.v (Cmd.info "statefile-log" ~doc:"Print the high-resolution statefile debug log (JSONL).")
        debug_statefile_log_cmd
    ; Cmd.v (Cmd.info "statefile-checkpoint" ~doc:"Create a named checkpoint entry in the statefile debug log.")
        debug_statefile_checkpoint_cmd
    ]

(* --- subcommand group: oc-plugin ------------------------------------------ *)
(* Sink commands for the OpenCode TypeScript plugin (c2c.ts).
   The plugin pipes state snapshots via stdin; these commands persist them
   at discoverable paths so external tools (GUI observer, c2c status, etc.)
   can read current OpenCode agent state without querying the plugin directly. *)

let oc_plugin_stream_write_statefile_cmd =
  Cmdliner.Term.(const (fun () ->
    (* Statefile path:
       - $C2C_INSTANCE_NAME set  → ~/.local/share/c2c/instances/<name>/oc-plugin-state.json
       - else                    → ~/.local/share/c2c/oc-plugin-state.json          *)
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let mkdir_p dir =
      let parts = String.split_on_char '/' dir in
      let _ = List.fold_left (fun acc part ->
        if part = "" then acc
        else
          let p = if acc = "" then "/" ^ part else acc ^ "/" ^ part in
          (try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          p
      ) "" parts in ()
    in
    let statefile =
      match Sys.getenv_opt "C2C_INSTANCE_NAME" with
      | Some name when String.trim name <> "" ->
          let inst_dir = Filename.concat (Filename.concat base_dir "instances") (String.trim name) in
          mkdir_p inst_dir;
          Filename.concat inst_dir "oc-plugin-state.json"
      | _ ->
          mkdir_p base_dir;
          Filename.concat base_dir "oc-plugin-state.json"
    in
    (* Atomic write helper *)
    let write_json j =
      let payload = Yojson.Safe.to_string j in
      let tmp = statefile ^ ".tmp" in
      (try
        let oc = open_out tmp in
        output_string oc payload;
        output_char oc '\n';
        close_out oc;
        Unix.rename tmp statefile
      with _ -> ())
    in
    (* Read existing statefile JSON (for patch merging). *)
    let read_existing () =
      try
        let ic = open_in statefile in
        let raw = In_channel.input_all ic in
        close_in ic;
        (match Yojson.Safe.from_string (String.trim raw) with
         | `Assoc _ as j -> Some j
         | _ -> None)
      with _ -> None
    in
    (* Deep-merge patch into existing state.snapshot envelope.
       Only top-level `state` fields are patched; nested merging is one level deep. *)
    let apply_patch existing_env patch_fields =
      match existing_env with
      | `Assoc env_fields ->
          let existing_state =
            match List.assoc_opt "state" env_fields with
            | Some (`Assoc sf) -> sf
            | _ -> []
          in
          (* Merge: for each field in patch, if both are Assoc, merge one level deep *)
          let merged_state = List.fold_left (fun acc (k, v) ->
            let existing_v = List.assoc_opt k acc in
            let merged_v = match existing_v, v with
              | Some (`Assoc old_fields), `Assoc new_fields ->
                  (* One level deep merge *)
                  let merged = List.fold_left (fun a (kk, vv) ->
                    (kk, vv) :: List.filter (fun (x, _) -> x <> kk) a
                  ) old_fields new_fields in
                  `Assoc merged
              | _ -> v
            in
            (k, merged_v) :: List.filter (fun (x, _) -> x <> k) acc
          ) existing_state patch_fields in
          `Assoc (List.map (fun (k, v) ->
            if k = "state" then (k, `Assoc merged_state) else (k, v)
          ) env_fields)
      | _ -> existing_env
    in
    (* Persistent loop: read one JSON line per iteration until EOF. *)
    (try
      while true do
        let line = input_line stdin in
        let trimmed = String.trim line in
        if trimmed <> "" then begin
          match (try Some (Yojson.Safe.from_string trimmed) with _ -> None) with
          | None -> () (* malformed line — silently skip *)
          | Some (`Assoc fields as j) ->
              let event_type =
                match List.assoc_opt "event" fields with
                | Some (`String s) -> s
                | _ -> ""
              in
              (match event_type with
               | "state.snapshot" -> write_json j
               | "state.patch" ->
                   let patch_fields =
                     match List.assoc_opt "patch" fields with
                     | Some (`Assoc pf) -> pf
                     | _ -> []
                   in
                   if patch_fields = [] then ()
                   else begin
                     let merged = match read_existing () with
                       | Some existing -> apply_patch existing patch_fields
                       | None -> j (* no existing state — write patch as-is *)
                     in
                     write_json merged
                   end
               | _ -> () (* unknown event type — ignore *)
              )
          | Some _ -> () (* not an object — ignore *)
        end
      done
    with End_of_file | Sys_error _ -> ())) $ Cmdliner.Term.const ())

let oc_plugin_message_json (msg : C2c_mcp.message) =
  `Assoc
    [ ("from_alias", `String msg.from_alias)
    ; ("to_alias", `String msg.to_alias)
    ; ("content", `String msg.content)
    ]

let oc_plugin_drain_inbox_to_spool_cmd =
  let open Cmdliner in
  let spool_path_arg =
    Arg.(required & opt (some string) None & info [ "spool-path" ] ~docv:"PATH"
      ~doc:"Path to the durable OpenCode plugin spool JSON file.")
  in
  let broker_root_arg =
    Arg.(value & opt (some string) None & info [ "broker-root" ] ~docv:"DIR"
      ~doc:"Broker root override. Defaults to C2C_MCP_BROKER_ROOT or repo-local broker root.")
  in
  let session_id_arg =
    Arg.(value & opt (some string) None & info [ "session-id" ] ~docv:"ID"
      ~doc:"Session ID override. Defaults to C2C_MCP_SESSION_ID / alias-resolved inbox session.")
  in
  let+ spool_path = spool_path_arg
  and+ broker_root_opt = broker_root_arg
  and+ session_id_opt = session_id_arg
  and+ json = json_flag in
  let output_mode = if json then Json else Human in
  let broker_root =
    match broker_root_opt with
    | Some root when String.trim root <> "" -> String.trim root
    | _ -> resolve_broker_root ()
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let session_id =
    match session_id_opt with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ -> resolve_session_id_for_inbox broker
  in
  let spool = C2c_wire_bridge.spool_of_path spool_path in
  let inbox_path = broker_root // (session_id ^ ".inbox.json") in
  let handle_error msg =
    Printf.eprintf "error: %s\n%!" msg;
    (match output_mode with
     | Json -> print_json (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
     | Human -> ());
    exit 1
  in
  try
    let pending =
      let queued = C2c_wire_bridge.spool_read spool in
      C2c_mcp.Broker.with_inbox_lock broker ~session_id (fun () ->
        let fresh = C2c_mcp.Broker.read_inbox broker ~session_id in
        match fresh with
        | [] -> queued
        | _ ->
            let combined = queued @ fresh in
            C2c_wire_bridge.spool_write spool combined;
            C2c_mcp.Broker.append_archive broker ~session_id ~messages:fresh;
            C2c_setup.json_write_file inbox_path (`List []);
            combined)
    in
    match output_mode with
    | Json ->
        print_json (`Assoc
          [ ("ok", `Bool true)
          ; ("session_id", `String session_id)
          ; ("spool_path", `String spool_path)
          ; ("count", `Int (List.length pending))
          ; ("messages", `List (List.map oc_plugin_message_json pending))
          ])
    | Human ->
        Printf.printf "staged %d OpenCode message(s) into %s\n"
          (List.length pending) spool_path
  with exn ->
    handle_error (Printexc.to_string exn)

let oc_plugin_group =
  Cmdliner.Cmd.group
     (Cmdliner.Cmd.info "oc-plugin"
        ~doc:"OpenCode plugin sink commands (called by the OpenCode c2c plugin).")
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "stream-write-statefile"
           ~doc:"Read a JSON state snapshot from stdin and write it atomically \
                 to the instance statefile. Path: \
                 ~/.local/share/c2c/instances/NAME/oc-plugin-state.json when \
                 C2C_INSTANCE_NAME is set, else ~/.local/share/c2c/oc-plugin-state.json.")
        oc_plugin_stream_write_statefile_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "drain-inbox-to-spool"
           ~doc:"Drain broker inbox messages into the OpenCode spool file before delivery.")
        oc_plugin_drain_inbox_to_spool_cmd
    ]

(* --- subcommand group: cc-plugin ------------------------------------------ *)
(* Claude Code plugin sink commands. The PostToolUse inbox hook writes
   statefile state automatically; this group exposes the write path for
   future hooks or scripts that need to emit explicit state (e.g. idle signal). *)

let cc_plugin_write_statefile_cmd =
  Cmdliner.Term.(const (fun () ->
    (* Same path logic as oc-plugin: prefer $C2C_INSTANCE_NAME, else base dir. *)
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
    let base_dir = Filename.concat home ".local/share/c2c" in
    let mkdir_p dir =
      let parts = String.split_on_char '/' dir in
      ignore (List.fold_left (fun acc part ->
        if part = "" then acc
        else
          let p = if acc = "" then "/" ^ part else acc ^ "/" ^ part in
          (try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          p
      ) "" parts)
    in
    let statefile =
      match Sys.getenv_opt "C2C_INSTANCE_NAME" with
      | Some name when String.trim name <> "" ->
          let inst_dir = Filename.concat (Filename.concat base_dir "instances") (String.trim name) in
          mkdir_p inst_dir;
          Filename.concat inst_dir "oc-plugin-state.json"
      | _ ->
          mkdir_p base_dir;
          Filename.concat base_dir "oc-plugin-state.json"
    in
    let line = try input_line stdin with End_of_file -> "" in
    if String.trim line = "" then ()
    else begin
      let json = try Some (Yojson.Safe.from_string line) with _ -> None in
      match json with
      | None -> ()
      | Some j ->
          let payload = Yojson.Safe.to_string j in
          let tmp = statefile ^ ".tmp" in
          (try
            let oc = open_out tmp in
            output_string oc payload;
            output_char oc '\n';
            close_out oc;
            Unix.rename tmp statefile
          with _ -> ())
    end) $ Cmdliner.Term.const ())

let cc_plugin_group =
  Cmdliner.Cmd.group
     (Cmdliner.Cmd.info "cc-plugin"
        ~doc:"Claude Code plugin sink commands (called by the PostToolUse hook, \
              PreCompact/PostCompact hooks, and any Claude Code statefile emitters).")
    [ Cmdliner.Cmd.v
         (Cmdliner.Cmd.info "write-statefile"
            ~doc:"Write a JSON state snapshot received on stdin atomically \
                  to the instance statefile (same path as oc-plugin). Called by \
                  hooks or scripts that need to emit explicit Claude Code state.")
        cc_plugin_write_statefile_cmd ]

(* --- main entry point ----------------------------------------------------- *)

(* Cmdliner renders help through groff/grotty, which emits ANSI SGR escapes,
   then pipes through $MANPAGER (or $PAGER, or `less`). A MANPAGER that runs
   the output through `col -b*` (e.g. "sh -c 'col -bx | bat -l man -p'") strips
   the ESC byte from every SGR sequence but leaves the payload, producing
   visible garbage like "[4mNAME[0m" in the rendered help. Detect that case
   and swap in a safe pager so `c2c <cmd> --help` stays readable regardless
   of the user's shell setup. *)
let sanitize_help_env () =
  let contains_substr haystack needle =
    let nl = String.length needle and hl = String.length haystack in
    nl <= hl
    && (let rec loop i =
          i <= hl - nl
          && (String.sub haystack i nl = needle || loop (i + 1))
        in
        loop 0)
  in
  let esc_stripping v =
    (* `col -b` / `col -bx` drop control chars (including ESC) from input. *)
    contains_substr v "col -b" || contains_substr v "col\t-b"
  in
  let fix var =
    match Sys.getenv_opt var with
    | Some v when esc_stripping v -> Unix.putenv var "less -R"
    | _ -> ()
  in
  fix "MANPAGER";
  fix "PAGER"

(* Enriched landing for bare `c2c` (no subcommand). Shows detection status
   and suggested next commands — doubles as a "where am I?" report. *)
let print_enriched_landing () =
  let version = version_string () in
  let (self, clients) = C2c_setup.detect_installation () in
  let self_path = C2c_setup.self_installed_path () in
  let broker_root = try resolve_broker_root () with _ -> "(unresolved)" in
  Printf.printf "c2c %s — peer-to-peer messaging for AI agents\n" version;
  let format_binary_status path build_rel_path =
    match path with
    | None -> "not installed"
    | Some p ->
        let p_mtime = try Some (Unix.stat p).Unix.st_mtime with _ -> None in
        let build_path =
          match git_repo_toplevel () with
          | Some root -> Some (root // build_rel_path)
          | None -> None
        in
        let build_mtime =
          match build_path with
          | Some bp when Sys.file_exists bp ->
              (try Some (Unix.stat bp).Unix.st_mtime with _ -> None)
          | _ -> None
        in
        (match p_mtime, build_mtime with
         | Some pt, Some bt when bt > pt +. 1.0 ->
             let age_min = int_of_float ((bt -. pt) /. 60.0) in
             Printf.sprintf "%s  (STALE — newer build %dm ahead; `cp %s %s`)"
               p age_min (Option.value ~default:"?" build_path) p
         | _ -> p)
  in
  Printf.printf "\n";
  Printf.printf "Status\n";
  Printf.printf "  c2c on PATH:      %s\n"
    (format_binary_status self_path "_build/default/ocaml/cli/c2c.exe");
  let mcp_server_path = C2c_setup.which_binary "c2c-mcp-server" in
  Printf.printf "  c2c-mcp-server:   %s\n"
    (format_binary_status mcp_server_path
       "_build/default/ocaml/server/c2c_mcp_server.exe");
  Printf.printf "  broker root:      %s\n" broker_root;
  let broker_live =
    try
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let regs = C2c_mcp.Broker.list_registrations broker in
      let alive =
        List.filter C2c_mcp.Broker.registration_is_alive regs |> List.length
      in
      Some (List.length regs, alive)
    with _ -> None
  in
  (match broker_live with
   | Some (total, alive) ->
       Printf.printf "  peers:            %d registered (%d alive)\n" total alive
   | None ->
       Printf.printf "  peers:            (broker not initialised — try `c2c init`)\n");
  (match check_pty_inject_capability () with
   | `Ok -> ()
   | `Unknown -> ()
   | `Missing_cap py ->
        Printf.printf
          "  pty-inject:       MISSING cap_sys_ptrace — Codex PTY notify daemon will fail\n";
        Printf.printf
          "                    fix: sudo setcap cap_sys_ptrace=ep %s\n" py;
        Printf.printf
          "                    (OpenCode + Kimi use non-PTY delivery — cap not required for them)\n");
  Printf.printf "\nClients\n";
  List.iter (fun (c, on_path, configured) ->
    let status =
      match on_path, configured with
      | false, _ -> "not on PATH"
      | true, true -> "configured (c2c MCP ready)"
      | true, false -> "on PATH, not configured — run 'c2c install' to set up"
    in
    Printf.printf "  %-10s %s\n" c status
  ) clients;
  let missing_clients =
    List.filter_map (fun (c, on_path, configured) ->
      if on_path && not configured then Some c else None) clients
  in
  let suggestions =
    let buf = Buffer.create 256 in
    if not self then
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s install the c2c binary to ~/.local/bin\n" "self");
    List.iter (fun c ->
      Buffer.add_string buf (Printf.sprintf "  c2c install %-16s configure %s for c2c\n" c c)
    ) missing_clients;
    Buffer.contents buf
  in
  if suggestions <> "" then begin
    Printf.printf "\nSuggested next steps\n";
    print_string suggestions;
    Printf.printf "  c2c install %-16s interactive installer (TUI)\n" ""
  end else begin
    Printf.printf "\nEverything looks configured. Some useful commands:\n";
    Printf.printf "  %-28s list registered peers\n" "c2c list";
    Printf.printf "  %-28s send a message\n" "c2c send ALIAS MSG";
    Printf.printf "  %-28s read pending messages\n" "c2c poll-inbox";
    Printf.printf "  %-28s list rooms you're in\n" "c2c rooms list"
  end;
  Printf.printf "\nRun `c2c help` or `c2c --help` for the full command list.\n"

let default_term =
  let+ () = Cmdliner.Term.const () in
  print_enriched_landing ()

(* --- subcommand group: supervisor ----------------------------------------- *)
(* Human-friendly wrappers for replying to question.asked / permission.asked
   sentinels without crafting raw protocol strings by hand. *)

let supervisor_send ~to_alias ~content =
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:None broker in
  (try
     C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content ();
     Printf.printf "ok -> %s (from %s)\n" to_alias from_alias
   with Invalid_argument msg ->
     Printf.eprintf "error: %s\n%!" msg; exit 1)

let supervisor_answer_cmd =
  let open Cmdliner.Term in
  const (fun peer qid answer ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "question:%s:answer:%s" qid answer))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Question request ID (from the DM notification).")
  $ Cmdliner.Arg.(required & pos 2 (some string) None & info [] ~docv:"ANSWER" ~doc:"Free-text answer or selected option.")

let supervisor_reject_question_cmd =
  let open Cmdliner.Term in
  const (fun peer qid ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "question:%s:reject" qid))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Question request ID.")

let supervisor_approve_cmd =
  let open Cmdliner.Term in
  let always_flag = Cmdliner.Arg.(value & flag & info ["always"] ~doc:"Grant permanent approval (approve-always) instead of once.") in
  const (fun peer permid always ->
    let decision = if always then "approve-always" else "approve-once" in
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "permission:%s:%s" permid decision))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER"   ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"     ~doc:"Permission request ID (from the DM notification).")
  $ always_flag

let supervisor_reject_permission_cmd =
  let open Cmdliner.Term in
  const (fun peer permid ->
    supervisor_send ~to_alias:peer
      ~content:(Printf.sprintf "permission:%s:reject" permid))
  $ Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"PEER" ~doc:"Agent alias to reply to.")
  $ Cmdliner.Arg.(required & pos 1 (some string) None & info [] ~docv:"ID"   ~doc:"Permission request ID.")

let supervisor_group =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "supervisor"
       ~doc:"Human-friendly replies to agent permission and question requests."
       ~man:[ `S "DESCRIPTION"
            ; `P "Wrappers that send structured reply sentinels to an agent's \
                  inbox without requiring you to craft the raw protocol strings."
            ; `S "EXAMPLES"
            ; `P "$(b,c2c supervisor answer oc-coder1 abc123 \"yes\")"
            ; `P "$(b,c2c supervisor question-reject oc-coder1 abc123)"
            ; `P "$(b,c2c supervisor approve oc-coder1 perm456)"
            ; `P "$(b,c2c supervisor approve --always oc-coder1 perm456)"
            ; `P "$(b,c2c supervisor reject oc-coder1 perm456)"
            ])
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "answer"
           ~doc:"Answer a question request (question.asked). Sends question:<ID>:answer:<ANSWER>.")
        supervisor_answer_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "question-reject"
           ~doc:"Reject a question request. Sends question:<ID>:reject.")
        supervisor_reject_question_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "approve"
           ~doc:"Approve a permission request (permission.asked). Use --always for permanent approval.")
        supervisor_approve_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "reject"
           ~doc:"Reject a permission request. Sends permission:<ID>:reject.")
        supervisor_reject_permission_cmd
    ]

(* Build tier-grouped COMMANDS man page text *)
let commands_man is_agent =
  if is_agent then
    [ `S "COMMANDS"
    ; `P "TIER LEGEND: Tier 1 = routine use, Tier 2 = lifecycle/setup (use with care), Tier 3 = system (hidden from agents), Tier 4 = internal plumbing."
    ; `P "== TIER 1: SAFE (messaging and queries) =="
    ; `P "$(b,send) $(b,list) $(b,whoami) $(b,poll-inbox) $(b,peek-inbox) \
         $(b,send-all) $(b,history) $(b,health) $(b,dead-letter) \
         $(b,tail-log) $(b,my-rooms) $(b,prune-rooms) \
         $(b,set-compact) $(b,clear-compact) \
         $(b,open-pending-reply) $(b,check-pending-reply) \
         $(b,rooms) $(b,register) $(b,refresh-peer) \
         $(b,instances) $(b,doctor) $(b,verify) $(b,status) \
         $(b,monitor) $(b,screen)"
    ; `P "== TIER 2: LIFECYCLE AND SETUP (use with care) =="
    ; `P "$(b,start) $(b,stop) $(b,restart) $(b,reset-thread) — manage c2c instances"
    ; `P "$(b,c2c rooms) $(b,send|join|leave|list|members|history|invite|visibility|delete)"
    ; `P "$(b,c2c agent) $(b,c2c roles) $(b,compile|validate) — role file management"
    ; `P "$(b,c2c config) $(b,show|generation-client)"
    ; `P "$(b,c2c wire-daemon) $(b,start|stop|status|list)"
    ; `P "$(b,init) $(b,repo)"
    ; `P "$(b,Tier 3 and 4 commands hidden when running as an agent.)"
    ]
  else
    [ `S "COMMANDS"
    ; `P "TIER LEGEND: Tier 1 = routine use, Tier 2 = lifecycle/setup (use with care), Tier 3 = system infrastructure (do NOT run inside an agent), Tier 4 = internal plumbing."
    ; `P "== TIER 1: SAFE (agents can use freely) =="
    ; `P "$(b,send), $(b,list), $(b,whoami), $(b,poll-inbox), $(b,peek-inbox), \
         $(b,send-all), $(b,history), $(b,health), $(b,status), $(b,verify), \
         $(b,register), $(b,refresh-peer), $(b,tail-log), $(b,my-rooms), \
         $(b,dead-letter), $(b,prune-rooms), $(b,set-compact), $(b,clear-compact), \
         $(b,open-pending-reply), $(b,check-pending-reply), \
         $(b,instances), $(b,doctor), $(b,rooms), $(b,monitor), $(b,screen)"
    ; `P "== TIER 2: LIFECYCLE AND SETUP (safe with care) =="
    ; `P "$(b,start), $(b,stop), $(b,restart), $(b,reset-thread), $(b,init), $(b,install), \
         $(b,agent), $(b,roles), $(b,compile), $(b,roles-validate), \
          $(b,config), $(b,config-show), $(b,generation-client), \
         $(b,wire-daemon), $(b,wire-daemon-list), $(b,wire-daemon-status), \
         $(b,repo)"
    ; `P "== TIER 3: SYSTEM (do NOT run from inside an agent) =="
    ; `P "$(b,restart-self) — signals the inner client; running inside a managed \
         session kills the supervisor and loses your session. Use /exit + external \
         'c2c start' to restart instead."
    ; `P "$(b,relay), $(b,relay-serve), $(b,relay-gc), $(b,relay-setup), \
         $(b,relay-connect), $(b,relay-register), $(b,relay-dm), \
          $(b,relay-status), $(b,relay-list), $(b,relay-rooms), $(b,relay-poll-inbox) — relay infrastructure"
    ; `P "$(b,setcap) — grants PTY injection capability (requires sudo)"
    ; `P "$(b,smoke-test), $(b,diag), $(b,install), $(b,gui) — system operations"
    ; `P "== TIER 4: INTERNAL (plumbing, never shown in agent help) =="
    ; `P "$(b,serve), $(b,mcp), $(b,hook), $(b,inject), $(b,oc-plugin), \
         $(b,cc-plugin), $(b,state-read), $(b,state-write), \
         $(b,wire-daemon-start), $(b,wire-daemon-stop), \
         $(b,wire-daemon-format-prompt), $(b,wire-daemon-spool-write), \
         $(b,wire-daemon-spool-read), $(b,supervisor)"
    ]

let () =
  sanitize_help_env ();
  for i = 0 to Array.length Sys.argv - 1 do
    if Sys.argv.(i) = "-h" then Sys.argv.(i) <- "--help"
  done;
  let is_agent = is_agent_session () in
  let tier_grouped_man = commands_man is_agent in
  let all_cmds =
    [ send; list; whoami; set_compact; clear_compact; open_pending_reply; check_pending_reply; poll_inbox; peek_inbox; send_all; sweep
    ; sweep_dryrun; migrate_broker; history; health; setcap; status; verify; git; register; refresh_peer; C2c_coord.coord_cherry_pick_cmd
    ; tail_log; server_info; my_rooms; dead_letter; prune_rooms; get_tmux_location; smoke_test; init; install; completion_cmd
    ; serve; mcp; start; C2c_agent.agent_group; config_group; C2c_agent.roles_group; gui; stop; restart; reset_thread; restart_self; instances; diag; doctor; stats; C2c_sitrep.sitrep_group; C2c_rooms.rooms_group; C2c_rooms.room_group; relay_group; skills_group; C2c_stickers.sticker_group; C2c_memory.memory_group; C2c_peer_pass.peer_pass_group; C2c_worktree.worktree_group; monitor; hook; inject; wire_daemon_group; repo_group; screen; statefile_top; debug_group; oc_plugin_group; cc_plugin_group; supervisor_group; commands_by_safety; help ]
  in
  let visible_cmds = filter_commands ~cmds:all_cmds in
  exit
    (Cmdliner.Cmd.eval
       (Cmdliner.Cmd.group ~default:default_term
          (Cmdliner.Cmd.info "c2c"
             ~version:(version_string ())
             ~doc:"c2c — peer-to-peer messaging for AI agents"
             ~man:
                ([ `S "GETTING STARTED"
                ; `P "New to c2c? Run $(b,c2c init) to configure your client, register, and join the swarm-lounge room in one step."
                ; `P "Then try: $(b,c2c list) to see peers, $(b,c2c send ALIAS MSG) to message someone, or $(b,c2c rooms) to join a room."
                ; `P "For full command reference see COMMANDS below."
                ; `S "DESCRIPTION"
                ; `P "c2c is a peer-to-peer messaging broker between AI coding sessions. Use subcommands to interact with the broker."
                ; `S "EXIT CODES"
                ; `P "c2c uses standard exit codes:"
                ; `Noblank; `P "123 — operational error (e.g., relay unreachable, broker unreachable, or registration failed)"
                ; `Noblank; `P "124 — bad command-line flag or argument — check your syntax"
                ; `Noblank; `P "125 — bug in c2c — please report at https://github.com/anomalyco/c2c/issues"
                ] @ tier_grouped_man))
             visible_cmds))
