open Cmdliner.Term.Syntax
open C2c_types
open C2c_commands
open C2c_cli_helpers

(* --- subcommand: commands (audit by safety tier) --------------------------- *)

let commands_by_safety_cmd =
  let show_all =
    Cmdliner.Arg.(value & flag & info [ "all" ] ~doc:"Include tier-4 internal commands.")
  in
  let show_dev =
    Cmdliner.Arg.(value & flag & info [ "dev" ]
      ~doc:"Reveal dev-only commands (e.g. list-glyphs) hidden from the default listing.")
  in
  let+ show_all = show_all
  and+ show_dev = show_dev in
  let reveal_dev = show_all || show_dev in
  let tier1 = [
    ("ping", "Connection status dashboard + loopback delivery probe (--verify)");
    ("list", "List registered c2c peers");
    ("find", "Find a peer by alias substring or exact session ID (alive-first)");
    ("sessions", "List registered sessions (session_id, alias, client_type, liveness)");
    ("whoami", "Show current c2c identity");
    ("poll-inbox", "Drain (or peek at) your inbox");
    ("peek-inbox", "Peek at your inbox without draining");
    ("wait-inbox", "Block until a message arrives, then drain once and exit (for clients with no push delivery)");
    ("send", "Send a message to a registered peer alias or session ID");
    ("send-all", "Broadcast a message to all peers");
    ("rooms", "Manage persistent N:N rooms (list/join/leave/send/history/tail/invite/members/visibility)");
    ("my-rooms", "List rooms you are a member of");
    ("history", "Show archived inbox messages");
    ("changelog", "Show recent c2c changelog entries (what's new + setup hints)");
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
    ("agent-help", "Show the MCP tool-call + CLI example for each capability");
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

    ("get-tmux-location", "Print the current tmux pane address (session:window.pane)");
    ("schedule", "Manage per-agent wake schedules");
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
    ("uninstall", "Remove c2c + client integrations");
    ("init", "Generate a new Ed25519 identity keypair");
    ("hook", "Hook subcommands: post-tool (PostToolUse) + stop (text-only turn delivery)");

  ] in
  let tier4 = [
    ("serve", "Run the MCP server (JSON-RPC over stdio)");
    ("mcp", "Alias for serve");
    ("oc-plugin stream-write-statefile", "[internal] Stream statefile writes");
    ("oc-plugin drain-inbox-to-spool", "[internal] Drain inbox to spool");
    ("cc-plugin write-statefile", "[internal] Write Claude Code statefile");
    ("statefile", "Read/write broker statefile");
    ("supervisor", "Supervisor subcommands");
    ("refresh-peer", "Refresh a stale broker registration");
    ("repo", "Per-repo config management");
  ] in
  let print_section title cmds =
    Printf.printf "\n== %s ==\n\n" title;
    List.iter (fun (name, desc) -> Printf.printf "  %-30s %s\n" name desc) cmds
  in
  let dev = dev_listing_entries () in
  Printf.printf "c2c commands by safety tier\n";
  print_section (safety_to_label Tier1) tier1;
  print_section (safety_to_label Tier2) tier2;
  if not (is_agent_session ()) then print_section (safety_to_label Tier3) tier3;
  if show_all then print_section (safety_to_label Tier4) tier4;
  if reveal_dev && dev <> [] then print_section "DEV (hidden without --dev)" dev

let commands_by_safety =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "commands"
       ~doc:"List all c2c commands grouped by safety tier."
       ~man:[ `P "Useful for auditing which commands are safe to run inside an agent session." ])
    commands_by_safety_cmd

(* Build tier-grouped COMMANDS man page text *)
let commands_man is_agent =
  (* DEV section: only revealed when `--dev` is on argv (mirrors the `--all`
     pre-scan). Driven by `hidden_unless_dev` so the gate and listing can't
     drift. *)
  let dev_block =
    if argv_has_dev () then
      `P "== DEV (hidden without --dev) =="
      :: List.map
           (fun (name, desc) -> `P (Printf.sprintf "$(b,%s) — %s" name desc))
           (dev_listing_entries ())
    else []
  in
  if is_agent then
    [ `S "COMMANDS"
    ; `P "TIER LEGEND: Tier 1 = routine use, Tier 2 = lifecycle/setup (use with care), Tier 3 = system (hidden from agents), Tier 4 = internal plumbing."
    ; `P "== TIER 1: SAFE (messaging and queries) =="
    ; `P "$(b,send) $(b,list) $(b,whoami) $(b,poll-inbox) $(b,peek-inbox) \
         $(b,wait-inbox) \
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
    ; `P "$(b,init) $(b,repo)"
    ; `P "$(b,Tier 3 and 4 commands hidden when running as an agent.)"
    ]
    @ dev_block
  else
    [ `S "COMMANDS"
    ; `P "TIER LEGEND: Tier 1 = routine use, Tier 2 = lifecycle/setup (use with care), Tier 3 = system infrastructure (do NOT run inside an agent), Tier 4 = internal plumbing."
    ; `P "== TIER 1: SAFE (agents can use freely) =="
    ; `P "$(b,send), $(b,list), $(b,whoami), $(b,poll-inbox), $(b,peek-inbox), \
         $(b,wait-inbox), \
         $(b,send-all), $(b,history), $(b,health), $(b,status), $(b,verify), \
         $(b,register), $(b,refresh-peer), $(b,tail-log), $(b,my-rooms), \
         $(b,dead-letter), $(b,prune-rooms), $(b,set-compact), $(b,clear-compact), \
         $(b,open-pending-reply), $(b,check-pending-reply), \
         $(b,instances), $(b,doctor), $(b,rooms), $(b,monitor), $(b,screen)"
    ; `P "== TIER 2: LIFECYCLE AND SETUP (safe with care) =="
    ; `P "$(b,start), $(b,stop), $(b,restart), $(b,reset-thread), $(b,init), $(b,install), $(b,self-update), \
         $(b,agent), $(b,roles), $(b,compile), $(b,roles-validate), \
          $(b,config), $(b,config-show), $(b,generation-client), \
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
         $(b,supervisor)"
    ]
    @ dev_block

let fast_path_commands () =
  (* Replicates commands_by_safety_cmd without cmdliner overhead.
     Tier3 section is suppressed in agent sessions. *)
  let is_all = ref false in
  let is_dev = ref false in
  let n = Array.length Sys.argv in
  for i = 2 to n - 1 do
    if Sys.argv.(i) = "--all" then is_all := true;
    if Sys.argv.(i) = "--dev" then is_dev := true
  done;
  let is_agent = is_agent_session () in
  let tier1 = [
    ("ping", "Connection status dashboard + loopback delivery probe (--verify)");
    ("list", "List registered c2c peers");
    ("find", "Find a peer by alias substring or exact session ID (alive-first)");
    ("sessions", "List registered sessions (session_id, alias, client_type, liveness)");
    ("whoami", "Show current c2c identity");
    ("poll-inbox", "Drain (or peek at) your inbox");
    ("peek-inbox", "Peek at your inbox without draining");
    ("wait-inbox", "Block until a message arrives, then drain once and exit (for clients with no push delivery)");
    ("send", "Send a message to a registered peer alias or session ID");
    ("send-all", "Broadcast a message to all peers");
    ("rooms", "Manage persistent N:N rooms (list/join/leave/send/history/tail/invite/members/visibility)");
    ("my-rooms", "List rooms you are a member of");
    ("history", "Show archived inbox messages");
    ("changelog", "Show recent c2c changelog entries (what's new + setup hints)");
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
    ("agent-help", "Show the MCP tool-call + CLI example for each capability");
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

    ("get-tmux-location", "Print the current tmux pane address (session:window.pane)");
    ("schedule", "Manage per-agent wake schedules");
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
    ("self-update", "Update the running c2c binary to the latest release");
    ("init", "Generate a new Ed25519 identity keypair");
    ("hook", "Hook subcommands: post-tool (PostToolUse) + stop (text-only turn delivery)");

  ] in
  let tier4 = [
    ("serve", "Run the MCP server (JSON-RPC over stdio)");
    ("mcp", "Alias for serve");
    ("oc-plugin stream-write-statefile", "[internal] Stream statefile writes");
    ("oc-plugin drain-inbox-to-spool", "[internal] Drain inbox to spool");
    ("cc-plugin write-statefile", "[internal] Write Claude Code statefile");
    ("statefile", "Read/write broker statefile");
    ("supervisor", "Supervisor subcommands");
    ("refresh-peer", "Refresh a stale broker registration");
    ("repo", "Per-repo config management");
  ] in
  let print_section title cmds =
    Printf.printf "\n== %s ==\n\n" title;
    List.iter (fun (name, desc) -> Printf.printf "  %-30s %s\n" name desc) cmds
  in
  let safety_to_label t =
    match t with
    | Tier1 -> "TIER 1 — SAFE FOR AGENTS (messaging, queries)"
    | Tier2 -> "TIER 2 — SAFE WITH CARE (lifecycle, side effects)"
    | Tier3 -> "TIER 3 — UNSAFE FOR AGENTS (systemic, requires operator)"
    | Tier4 -> "TIER 4 — INTERNAL (hidden without --all)"
  in
  let dev = dev_listing_entries () in
  Printf.printf "c2c commands by safety tier\n";
  print_section (safety_to_label Tier1) tier1;
  print_section (safety_to_label Tier2) tier2;
  if not is_agent then print_section (safety_to_label Tier3) tier3;
  if !is_all then print_section (safety_to_label Tier4) tier4;
  if (!is_dev || !is_all) && dev <> [] then print_section "DEV (hidden without --dev)" dev
