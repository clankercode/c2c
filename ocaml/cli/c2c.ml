(* c2c CLI — human-friendly command-line interface to the c2c broker.
   When invoked with no arguments, shows help.
   Otherwise dispatches to CLI subcommands. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_types
open C2c_commands
open C2c_utils
open C2c_agent

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
    ("list", "List registered c2c peers");
    ("sessions", "List registered sessions (session_id, alias, client_type, liveness)");
    ("whoami", "Show current c2c identity");
    ("poll-inbox", "Drain (or peek at) your inbox");
    ("peek-inbox", "Peek at your inbox without draining");
    ("send", "Send a message to a registered peer alias or session ID");
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

(* --- cross-broker alias resolution --------------------------------------- *)

(** Scan all known broker roots (per-repo + sessions broker) to find which
    broker(s) contain a registration matching [alias] (case-insensitive).
    Returns [(broker_root, registration)] pairs. Excludes [exclude_root]
    (the primary broker that was already checked).
    Also scans C2C_BROKER_SCAN_DIRS (colon-separated extra broker root dirs). *)
let find_alias_in_all_broots ~exclude_root alias =
  let target = String.lowercase_ascii alias in
  let seen = Hashtbl.create 8 in
  let results = ref [] in
  let scan_root root =
    if root = exclude_root then ()
    else if Hashtbl.mem seen root then ()
    else begin
      Hashtbl.add seen root ();
      try
        let broker = C2c_mcp.Broker.create ~root in
        let regs = C2c_mcp.Broker.list_registrations broker in
        let matches =
          List.filter
            (fun (r : C2c_mcp.registration) ->
              String.lowercase_ascii r.alias = target)
            regs
        in
        List.iter (fun r -> results := (root, r) :: !results) matches
      with _ -> ()  (* skip brokers we can't read *)
    end
  in
  (* Scan the cross-repo sessions broker *)
  (try scan_root (Repo_fp.resolve_sessions_broker_root ()) with _ -> ());
  (* Scan per-repo brokers under ~/.c2c/repos/*/broker and XDG *)
  (try
     List.iter (fun (_fp, root) -> scan_root root)
       (C2c_repo_fp.list_all_broker_roots ())
   with _ -> ());
  (* Scan C2C_BROKER_SCAN_DIRS env (colon-separated extra broker root paths) *)
  (match Sys.getenv_opt "C2C_BROKER_SCAN_DIRS" with
   | Some dirs when String.trim dirs <> "" ->
       String.split_on_char ':' (String.trim dirs)
       |> List.iter (fun d -> let d = String.trim d in if d <> "" then scan_root d)
   | _ -> ());
  (* Also scan sibling broker dirs: if primary broker is under a repos/ layout,
     scan siblings. If it's an arbitrary path, scan its parent for subdirs
     containing registry.json — this handles temp broker dirs in tests. *)
  (try
     let parent = Filename.dirname exclude_root in
     if Sys.file_exists parent && Sys.is_directory parent then
       Array.iter (fun entry ->
         let candidate = Filename.concat parent entry in
         if candidate <> exclude_root
            && Sys.is_directory candidate
            && Sys.file_exists (Filename.concat candidate "registry.json")
         then scan_root candidate
       ) (Sys.readdir parent)
   with _ -> ());
  List.rev !results

(** Same as above but also check the sessions broker root explicitly
    (it may already be in the list but this ensures coverage). *)
let find_alias_in_all_brokers ~primary_root alias =
  find_alias_in_all_broots ~exclude_root:primary_root alias

(* --- subcommand: send ----------------------------------------------------- *)

let send_cmd =
  let args =
    Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"TARGET MSG" ~doc:"Recipient alias followed by message body, or message body when --session is set.")
  in
  let session_target =
    Cmdliner.Arg.(value & opt (some string) None & info [ "session" ] ~docv:"SESSION_ID" ~doc:"Deliver directly to this session ID via the global sessions broker instead of resolving a recipient alias.")
  in
  let bad_usage msg =
    Printf.eprintf "error: %s\n%!" msg;
    exit 2
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
  (* #392: visual-marker tags. Mutually exclusive flags that prepend a
     body prefix (🔴 FAIL: / ⛔ BLOCKING: / ⚠️ URGENT:) so the recipient
     spots the tag inline in the agent's transcript. *)
  let fail_flag =
    Cmdliner.Arg.(value & flag & info [ "fail" ]
      ~doc:"Mark as a FAIL message. Prepends '🔴 FAIL: ' to the body so the recipient spots the verdict inline in their transcript. Mutex with --blocking and --urgent.")
  in
  let blocking_flag =
    Cmdliner.Arg.(value & flag & info [ "blocking" ]
      ~doc:"Mark as a BLOCKING message. Prepends '⛔ BLOCKING: ' to the body. Use when downstream work cannot proceed until this is resolved. Mutex with --fail and --urgent.")
  in
  let urgent_flag =
    Cmdliner.Arg.(value & flag & info [ "urgent" ]
      ~doc:"Mark as an URGENT message. Prepends '⚠️ URGENT: ' to the body. Use for time-sensitive but not-fully-blocking attention asks. Mutex with --fail and --blocking.")
  in
  let broker_root_opt =
    Cmdliner.Arg.(value & opt (some string) None & info ["broker-root";"root"] ~docv:"DIR"
           ~doc:"Broker root dir (default: auto-resolve via env/git). Overrides --cross-repo.")
  in
  let+ json = json_flag
  and+ args = args
  and+ session_target = session_target
  and+ from_override = from_override
  and+ no_warn_substitution = no_warn_substitution
  and+ ephemeral = ephemeral_flag
  and+ fail = fail_flag
  and+ blocking = blocking_flag
  and+ urgent = urgent_flag
  and+ cross_repo = cross_repo_flag
  and+ broker_root_opt = broker_root_opt in
  mcp_nudge_if_needed ~cmd:"send";
  let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~explicit_root:broker_root_opt ~cross_repo ()) in
  let target, content =
    match session_target, args with
    | Some sid, tokens ->
        let sid =
          match C2c_mcp.validate_session_id sid with
          | Ok sid -> sid
          | Error msg -> bad_usage msg
        in
        if tokens = [] then bad_usage "--session requires a message body";
        (`Session sid, String.concat " " tokens)
    | None, to_alias :: msg_tokens ->
        if msg_tokens = [] then bad_usage "send requires a recipient alias and message body";
        (`Alias to_alias, String.concat " " msg_tokens)
    | None, [] ->
        bad_usage "send requires a recipient alias and message body"
  in
  let from_alias =
    match target with
    | `Alias _ -> resolve_alias ~override:from_override broker
    | `Session _ ->
        (match from_override with
         | Some a when String.trim a <> "" ->
             let r = String.trim a in
             validate_from_override broker
               ~caller_session_id:(env_session_id ())
               ~from_alias:r;
             r
         | _ ->
             (match env_session_id () with
              | Some sid ->
                  let regs = C2c_mcp.Broker.list_registrations broker in
                  (match List.find_opt
                           (fun (r : C2c_mcp.registration) -> r.session_id = sid)
                           regs
                   with
                   | Some r -> r.alias
                   | None -> Option.value (env_auto_alias ()) ~default:"c2c-cli")
              | None -> Option.value (env_auto_alias ()) ~default:"c2c-cli"))
  in
  (* B044: Warn when --from aliases a different identity than the caller's own.
     The recipient cannot reply to a sender that isn't the caller's registered
     alias — this is an operator/impersonation footgun. Non-fatal: the send
     still goes through since --from is intentional for operator use. *)
  let () =
    match from_override with
    | Some override_str when String.trim override_str <> "" ->
        let override_cf =
          C2c_mcp.Broker.alias_casefold (String.trim override_str)
        in
        let own_alias_opt =
          match env_session_id () with
          | Some sid ->
              let regs = C2c_mcp.Broker.list_registrations broker in
              (match List.find_opt
                       (fun (r : C2c_mcp.registration) -> r.session_id = sid)
                       regs
               with Some r -> Some r.alias | None -> None)
          | None -> None
        in
        (match own_alias_opt with
         | Some own when
             C2c_mcp.Broker.alias_casefold own <> override_cf ->
             Printf.eprintf
               "warning: --from %s is not your own alias (%s); \
                the recipient will NOT be able to reply to this sender.\n%!"
               (String.trim override_str) own
         | _ -> ())
    | _ -> ()
  in
  (* #392: enforce mutual exclusion + apply body prefix. *)
  let tag_count =
    (if fail then 1 else 0) + (if blocking then 1 else 0) + (if urgent then 1 else 0)
  in
  if tag_count > 1 then begin
    Printf.eprintf
      "error: --fail, --blocking, and --urgent are mutually exclusive (got %d).\n%!"
      tag_count;
    exit 2
  end;
  let tag_str =
    if fail then Some "fail"
    else if blocking then Some "blocking"
    else if urgent then Some "urgent"
    else None
  in
  let content = (C2c_mcp.tag_to_body_prefix tag_str) ^ content in
  (* B045: Stderr-only informational hint for human operators.
     Body is data, never shell-eval'd — this never blocks or fails a send.
     --no-warn-substitution suppresses even this hint. *)
  let _ =
    if (not no_warn_substitution) && likes_shell_substitution content
    then Printf.eprintf
      "hint: message body contains $(...) or backticks (sent as-is).\n%!"
    else ()
  in
  let output_mode = if json then Json else Human in
  (try
     let ts = Unix.gettimeofday () in
     let primary_root =
       try C2c_mcp.Broker.root broker
       with _ -> "<unknown>"
     in
     let compacting_warning, json_target_fields, human_target =
       match target with
       | `Alias to_alias ->
           if from_alias = to_alias then (
             Printf.eprintf "error: cannot send a message to yourself (%s)\n%!" from_alias;
             exit 1
           );
           if debug_enabled then Printf.eprintf "[DEBUG send_cmd] calling enqueue_message from=%s to=%s\n%!" from_alias to_alias;
           flush stderr;
           (* B039: try primary broker first, then cross-broker fallback *)
           (try
              C2c_mcp.Broker.enqueue_message broker ~from_alias ~to_alias ~content ~ephemeral ();
              if debug_enabled then Printf.eprintf "[DEBUG send_cmd] enqueue_message returned\n%!";
              flush stderr
            with Invalid_argument _msg
              when not (String.contains to_alias '@') ->
              (* Primary broker doesn't have this alias — scan other brokers *)
              let matches = find_alias_in_all_brokers ~primary_root to_alias in
              match matches with
              | (alt_root, _reg) :: _ ->
                  (* Found in another broker — route there *)
                  if debug_enabled then Printf.eprintf
                    "[DEBUG send_cmd] cross-broker routing: %s found in %s\n%!" to_alias alt_root;
                  let alt_broker = C2c_mcp.Broker.create ~root:alt_root in
                  C2c_mcp.Broker.enqueue_message alt_broker
                    ~from_alias ~to_alias ~content ~ephemeral ();
                  if debug_enabled then Printf.eprintf "[DEBUG send_cmd] cross-broker enqueue_message returned\n%!"
              | [] ->
                  (* Not found anywhere — provide actionable error *)
                  let is_room =
                    (try
                       let rooms = C2c_mcp.Broker.list_rooms broker in
                       List.exists (fun r -> r.C2c_mcp.Broker.ri_room_id = to_alias) rooms
                     with _ -> false)
                  in
                  if is_room then begin
                    Printf.eprintf "error: '%s' is a room, not a peer alias.\n" to_alias;
                    Printf.eprintf "hint:  use `c2c room send %s <message>` to send to a room.\n%!" to_alias
                  end else begin
                    Printf.eprintf "error: alias '%s' is not registered.\n" to_alias;
                    Printf.eprintf "  Primary broker: %s\n" primary_root;
                    Printf.eprintf "  Also scanned: sessions broker, per-repo brokers, C2C_BROKER_SCAN_DIRS, sibling dirs.\n";
                    Printf.eprintf "  hint: pass --root <broker-root> to target a specific broker,\n";
                    Printf.eprintf "  or use `c2c list --global` to see all registered peers across brokers.\n%!"
                  end;
                  exit 1);
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
           ( compacting_warning
           , [ ("to_alias", `String to_alias) ]
           , to_alias )
       | `Session session_id ->
           let sessions_broker =
             C2c_mcp.Broker.create
               ~root:(Repo_fp.resolve_sessions_broker_root ())
           in
           C2c_mcp.Broker.enqueue_session_message sessions_broker
             ~from_alias ~session_id ~content ~ephemeral ();
           ( None
           , [ ("target_session_id", `String session_id) ]
           , "session " ^ session_id )
     in
     match output_mode with
     | Json ->
         let fields =
           [ ("queued", `Bool true)
           ; ("ts", `Float ts)
           ; ("from_alias", `String from_alias)
           ]
           @ json_target_fields
         in
         let fields = match compacting_warning with Some w -> fields @ [("compacting_warning", `String w)] | None -> fields in
         print_json (`Assoc fields)
     | Human ->
         Printf.printf "ok -> %s (from %s)" human_target from_alias;
         (match compacting_warning with Some w -> Printf.printf " [%s]" w | None -> ());
         print_newline ()
   with Invalid_argument msg ->
     (* Catch-all for errors from Session sends or other paths. *)
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

(* --- subcommand: list ----------------------------------------------------- *)

(* lookup_role_info: best-effort load of .c2c/roles/<alias>.md for enriched listing.
   Returns (role_class, description) defaulting to ("","") when the role file is absent
   or unparseable. Tolerant to malformed files — discoverability is informational, not
   load-bearing. *)
let lookup_role_info (alias : string) : string * string =
  let path = C2c_role.canonical_roles_dir () // (alias ^ ".md") in
  if not (Sys.file_exists path) then ("", "")
  else
    try
      let r = C2c_role.parse_file path in
      let role_class = Option.value r.C2c_role.role_class ~default:"" in
      (role_class, r.C2c_role.description)
    with _ -> ("", "")

(* truncate a string to n graphemes (approximate via bytes, safe for ASCII descriptions). *)
let truncate_str (s : string) (n : int) : string =
  let s = String.trim s in
  if String.length s <= n then s
  else if n <= 1 then String.sub s 0 (max 0 n)
  else String.sub s 0 (n - 1) ^ "…"

(* relative-time: render a registered_at timestamp as "active now" / "5m ago" / "2h ago" / etc. *)
let format_last_seen (registered_at : float option) : string =
  match registered_at with
  | None -> "—"
  | Some ts ->
      let now = Unix.gettimeofday () in
      let delta = now -. ts in
      if delta < 0.0 then "future?"
      else if delta < 120.0 then "active now"
      else if delta < 3600.0 then Printf.sprintf "%dm ago" (int_of_float (delta /. 60.0))
      else if delta < 86400.0 then Printf.sprintf "%dh ago" (int_of_float (delta /. 3600.0))
      else Printf.sprintf "%dd ago" (int_of_float (delta /. 86400.0))

let list_cmd =
  let all =
    Cmdliner.Arg.(value & flag & info [ "all"; "a" ] ~doc:"Show extended info (session ID, registered time).")
  in
  let enriched =
    Cmdliner.Arg.(value & flag & info [ "enriched"; "e" ]
      ~doc:"Show role-class + description + last-seen for each peer (looked up from .c2c/roles/<alias>.md). Useful for new agents orienting on who's who in the swarm.")
  in
  let global =
    Cmdliner.Arg.(value & flag & info [ "global"; "g" ]
      ~doc:"Scan all known broker roots (across all repos) and list every registered session system-wide. Each session is annotated with its repo fingerprint and path. Use this to find sessions started in other repos or on other brokers.")
  in
  let alive_only =
    Cmdliner.Arg.(value & flag & info [ "alive"; "A" ]
      ~doc:"Show only alive sessions. By default, dead sessions (those whose PID has exited) are listed with a 'dead' state annotation. Use this flag to suppress them from the output.")
  in
  let+ json = json_flag
  and+ all = all
  and+ enriched = enriched
  and+ global = global
  and+ alive_only = alive_only
  and+ cross_repo = cross_repo_flag in
  mcp_nudge_if_needed ~cmd:"list";

  if global && cross_repo then begin
    Printf.eprintf "error: --global (scan per-repo brokers) and --cross-repo (sessions broker) are mutually exclusive.\n%!";
    exit 2
  end;

  let is_alive r = C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive in
  let regs_filter = if alive_only then List.filter is_alive else Fun.id in

  (* --- helpers shared between single-broker and global modes --- *)
  let registration_to_json ?(repo_fp="") ?(repo_path="") ~(enriched:bool) (r : C2c_mcp.registration) =
    let base : (string * Yojson.Safe.t) list =
      [ ("session_id", `String r.session_id)
      ; ("alias", `String r.alias)
      ]
    in
    let with_repo = if repo_fp <> "" then base @ [ ("repo_fp", `String repo_fp); ("repo_path", `String repo_path) ] else base in
    let with_pid =
      match r.pid with
      | Some n -> with_repo @ [ ("pid", `Int n) ]
      | None -> with_repo
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
      match r.tmux_location with
      | Some loc -> fields @ [ ("tmux_location", `String loc) ]
      | None -> fields
    in
    let fields =
      match r.compacting with
      | Some c ->
          let reason_json = match c.reason with Some r -> `String r | None -> `Null in
          fields @ [ ("compacting", `Assoc [ ("started_at", `Float c.started_at); ("reason", reason_json) ]) ]
      | None -> fields
    in
    let fields =
      if enriched then
        let (role_class, description) = lookup_role_info r.alias in
        fields @ [
          ("role_class", `String role_class);
          ("description", `String description);
          ("last_seen", `String (format_last_seen r.registered_at));
        ]
      else fields
    in
    `Assoc fields
  in

  let output_mode = if json then Json else Human in

  if global then
    (* --global: scan all known broker roots *)
    let all_roots = C2c_repo_fp.list_all_broker_roots () in
    if all_roots = [] then (
      match output_mode with
      | Json -> print_json (`List [])
      | Human -> Printf.printf "No broker roots found.\n")
    else
      let all_regs =
        List.fold_left (fun acc (fp, root) ->
          try
            let broker = C2c_mcp.Broker.create ~root in
            let regs = C2c_mcp.Broker.list_registrations broker |> regs_filter in
            List.map (fun r -> (fp, root, r)) regs @ acc
          with _ -> acc
        ) [] all_roots
      in
      match output_mode with
      | Json ->
          let json_regs = List.map (fun (fp, root, r) -> registration_to_json ~repo_fp:fp ~repo_path:root ~enriched r) all_regs in
          print_json (`List json_regs)
      | Human ->
          if all_regs = [] then Printf.printf "No registered peers across %d broker root(s).\n" (List.length all_roots)
          else begin
            (* Group registrations by (fp, root) for human output *)
            let by_broker : (string * string, C2c_mcp.registration list) Hashtbl.t = Hashtbl.create 16 in
            List.iter (fun (fp, root, r) ->
              let key = (fp, root) in
              let existing = try Hashtbl.find by_broker key with Not_found -> [] in
              Hashtbl.replace by_broker key (r :: existing)
            ) all_regs;
            (* Print one broker section at a time *)
            List.iter (fun (fp, root) ->
              let regs = try Hashtbl.find by_broker (fp, root) with Not_found -> [] in
              Printf.printf "\n[%s]\n  repo: %s\n  root: %s\n"
                (if enriched then "enriched" else "sessions")
                fp root;
              List.iter (fun r ->
                let alive_str =
                  match C2c_mcp.Broker.registration_liveness_state r with
                  | C2c_mcp.Broker.Alive -> "alive"
                  | C2c_mcp.Broker.Dead -> "dead "
                  | C2c_mcp.Broker.Unknown -> "??? (unknown client_type)"
                in
                let pid_str = match r.pid with Some p -> Printf.sprintf " pid=%d" p | None -> "" in
                if enriched then
                  let (role_class, description) = lookup_role_info r.alias in
                  let role_class = if role_class = "" then "—" else role_class in
                  let description = if description = "" then "—" else description in
                  let last_seen = format_last_seen r.registered_at in
                  Printf.printf "  %-20s %-13s %-40s %-12s %s%s\n"
                    (truncate_str r.alias 20)
                    (truncate_str role_class 13)
                    (truncate_str description 40)
                    last_seen
                    alive_str pid_str
                else if all then
                  let session_short = let s = r.session_id in if String.length s > 12 then String.sub s 0 12 ^ "..." else s in
                  let time_str = match r.registered_at with None -> "" | Some ts ->
                    let t = Unix.gmtime ts in Printf.sprintf " %04d-%02d-%02d %02d:%02d" (1900+t.tm_year) (1+t.tm_mon) t.tm_mday t.tm_hour t.tm_min
                  in
                  let tmux_str = match r.tmux_location with Some s -> " ["^s^"]" | _ -> "" in
                  Printf.printf "  %-20s %s%s  %s%s%s\n" r.alias alive_str pid_str session_short time_str tmux_str
                else begin
                  let tmux_str = match r.tmux_location with Some s -> " ["^s^"]" | _ -> "" in
                  Printf.printf "  %-20s %s%s%s\n" r.alias alive_str pid_str tmux_str
                end
              ) regs
            ) all_roots
          end
  else
    (* single-broker (default or --cross-repo): use effective broker root *)
    let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
    let regs = C2c_mcp.Broker.list_registrations broker |> regs_filter in
    if regs = [] then (
      match output_mode with
      | Json -> print_json (`List [])
      | Human ->
          if cross_repo then Printf.printf "No registered peers on the sessions broker.\n"
          else begin
            let n_alive =
              try
                let sb = C2c_mcp.Broker.create ~root:(Repo_fp.resolve_sessions_broker_root ()) in
                C2c_mcp.Broker.list_registrations sb
                |> List.filter (fun r -> C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
                |> List.length
              with _ -> 0
            in
            if n_alive > 0 then
              Printf.printf "No peers in this repo; %d alive on the sessions broker — try `c2c list --cross-repo`.\n" n_alive
            else
              Printf.printf "No registered peers.\n"
          end)
    else
      match output_mode with
      | Json ->
          let json_regs = List.map (fun r -> registration_to_json ~enriched r) regs in
          print_json (`List json_regs)
      | Human ->
          if enriched then begin
            Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
              "ALIAS" "ROLE" "DESCRIPTION" "LAST-SEEN" "STATE";
            Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
              (String.make 20 '-') (String.make 13 '-') (String.make 40 '-')
              (String.make 12 '-') (String.make 5 '-');
            List.iter
              (fun (r : C2c_mcp.registration) ->
                let alive_str =
                  match C2c_mcp.Broker.registration_liveness_state r with
                  | C2c_mcp.Broker.Alive -> "alive"
                  | C2c_mcp.Broker.Dead -> "dead"
                  | C2c_mcp.Broker.Unknown -> "?"
                in
                let (role_class, description) = lookup_role_info r.alias in
                let role_class = if role_class = "" then "—" else role_class in
                let description = if description = "" then "—" else description in
                let last_seen = format_last_seen r.registered_at in
                Printf.printf "  %-20s %-13s %-40s %-12s %s\n"
                  (truncate_str r.alias 20)
                  (truncate_str role_class 13)
                  (truncate_str description 40)
                  last_seen
                  alive_str)
              regs
          end else
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
                  let tmux_str = match r.tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
                  Printf.printf "  %-20s %s%s  %s%s%s\n" r.alias alive_str pid_str session_short time_str tmux_str
                else
                  let tmux_str = match r.tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
                  Printf.printf "  %-20s %s%s%s\n" r.alias alive_str pid_str tmux_str)
               regs

(* --- subcommand: sessions ------------------------------------------------- *)

let sessions_cmd =
  let+ json = json_flag in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let regs = C2c_mcp.Broker.list_registrations broker in
  if json then
    print_json (C2c_sessions_format.sessions_to_json regs)
  else
    print_string (C2c_sessions_format.format_human regs)

(* --- subcommand: whoami --------------------------------------------------- *)

let whoami_cmd =
  let keys =
    Cmdliner.Arg.(value & flag & info [ "keys"; "K" ]
      ~doc:"Also show the per-alias Ed25519 public key and fingerprint (from <broker-root>/keys/<alias>.ed25519).")
  in
  let+ json = json_flag
  and+ keys = keys in
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
          print_json (`Assoc with_keys)
      | Human ->
          Printf.printf "alias:     %s\nsession_id: %s\n"
            (Option.value alias ~default:"(not registered)")
            sid;
          (match identity_data with
           | None -> ()
           | Some id ->
               let pk_b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet id.Relay_identity.public_key in
               Printf.printf "public_key: %s\nfingerprint: %s\nalg:        %s\n"
                 pk_b64 id.Relay_identity.fingerprint id.Relay_identity.alg)

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
    ; created_at = now; expires_at = now +. ttl_seconds
    ; fallthrough_fired_at = []; resolved_at = None; verdict = None }
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
      (* #alias-casefold: supervisor list is the authoritative target;
         compare both sides folded so a supervisor whose stored alias
         differs in case from [reply_from] is not falsely rejected. *)
      if List.exists
           (fun s ->
             C2c_mcp.Broker.alias_casefold s
             = C2c_mcp.Broker.alias_casefold reply_from)
           pending.supervisors
      then
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
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Alias whose inbox to drain. Useful for unmanaged CLI peers; mutually exclusive with --session-id.")
  in
  let+ json = json_flag
  and+ peek = peek
  and+ session_id_opt = session_id_flag
  and+ alias_opt = alias_flag
  and+ cross_repo = cross_repo_flag in
  mcp_nudge_if_needed ~cmd:"poll-inbox";
  (match session_id_opt, alias_opt with
   | Some _, Some _ -> Printf.eprintf "error: --session-id and --alias are mutually exclusive.\n%!"; exit 1
   | _ -> ());
  (try
    let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
    let session_id = match session_id_opt with
      | Some sid -> sid
      | None -> resolve_session_id_for_inbox ?alias:alias_opt broker
    in
    let messages =
      if peek then
        C2c_mcp.Broker.read_inbox broker ~session_id
      else
        C2c_mcp.Broker.drain_inbox ~drained_by:"cli_poll" broker ~session_id
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
  with
  | Unix.Unix_error (code, fn, path) when code = Unix.EROFS || code = Unix.EACCES ->
      let msg = Printf.sprintf
        "broker root is not writable in this sandbox (path: %s, error: %s). \
         Set C2C_MCP_BROKER_ROOT to a writable path or run from a managed session."
        path (Unix.error_message code)
      in
      if json then
        print_json (`Assoc [ ("error", `String msg); ("code", `String (match code with Unix.EROFS -> "EROFS" | Unix.EACCES -> "EACCES" | _ -> "unknown")) ])
      else
        Printf.eprintf "error: %s\n%!" msg;
      exit 1
  )

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
  (* #392: visual-marker tags. Mutually exclusive flags that prepend a
     body prefix (🔴 FAIL: / ⛔ BLOCKING: / ⚠️ URGENT:) so the recipient
     spots the tag inline in the agent's transcript. *)
  let fail_flag =
    Cmdliner.Arg.(value & flag & info [ "fail" ]
      ~doc:"Mark as a FAIL message. Prepends '🔴 FAIL: ' to the body so the recipient spots the verdict inline in their transcript. Mutex with --blocking and --urgent.")
  in
  let blocking_flag =
    Cmdliner.Arg.(value & flag & info [ "blocking" ]
      ~doc:"Mark as a BLOCKING message. Prepends '⛔ BLOCKING: ' to the body. Use when downstream work cannot proceed until this is resolved. Mutex with --fail and --urgent.")
  in
  let urgent_flag =
    Cmdliner.Arg.(value & flag & info [ "urgent" ]
      ~doc:"Mark as an URGENT message. Prepends '⚠️ URGENT: ' to the body. Use for time-sensitive but not-fully-blocking attention asks. Mutex with --fail and --blocking.")
  in
  let+ json = json_flag
  and+ exclude = exclude
  and+ message = message
  and+ from_override = from_override
  and+ fail = fail_flag
  and+ blocking = blocking_flag
  and+ urgent = urgent_flag in
  (* #392: enforce mutual exclusion + apply body prefix. *)
  let tag_count =
    (if fail then 1 else 0) + (if blocking then 1 else 0) + (if urgent then 1 else 0)
  in
  if tag_count > 1 then begin
    Printf.eprintf
      "error: --fail, --blocking, and --urgent are mutually exclusive (got %d).\n%!"
      tag_count;
    exit 2
  end;
  let tag_str =
    if fail then Some "fail"
    else if blocking then Some "blocking"
    else if urgent then Some "urgent"
    else None
  in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let from_alias = resolve_alias ~override:from_override broker in
  let content = String.concat " " message in
  let broker_raw = C2c_broker.create ~root:(resolve_broker_root ()) in
  let result =
    C2c_send_handlers.broadcast_to_all ~broker:broker_raw ~from_alias ~content ~exclude_aliases:exclude ~tag_arg:tag_str
  in
  let output_mode = if json then Json else Human in
  match result with
  | Error msg ->
      Printf.eprintf "error: %s\n%!" msg;
      exit 1
  | Ok result_json ->
  match output_mode with
  | Json ->
      print_json result_json
  | Human ->
      (* Extract sent_to and skipped from the JSON for human display *)
      let sent_to = match result_json with
        | `Assoc l -> (match List.assoc_opt "sent_to" l with
            | Some (`List aliases) -> List.filter_map (function `String s -> Some s | _ -> None) aliases
            | _ -> [])
        | _ -> []
      in
      let skipped = match result_json with
        | `Assoc l -> (match List.assoc_opt "skipped" l with
            | Some (`List items) -> List.filter_map (function
                | `Assoc kv -> (match List.assoc_opt "alias" kv, List.assoc_opt "reason" kv with
                    | Some (`String a), Some (`String r) -> Some (a, r)
                    | _ -> None)
                | _ -> None) items
            | _ -> [])
        | _ -> []
      in
      Printf.printf "Sent to: %s\n"
        (match sent_to with [] -> "(none)" | l -> String.concat ", " l);
      if skipped <> [] then
        List.iter
          (fun (a, r) -> Printf.printf "  skipped %s (%s)\n" a r)
          skipped

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

(* --- subcommand: registry-prune -------------------------------------------- *)

(** Default test-alias prefixes to prune when no explicit patterns given.
    Covers known test/ephemeral alias generators across the codebase:
    - "eph-" from c2c_agent.ml ephemeral instance naming
    - "heal-" from legacy test harness
    - "mon-" from monitoring/test harnesses
    - "test-" from ad-hoc test registrations *)
let default_prune_patterns = ["eph-"; "heal-"; "mon-"; "test-"; "tmp-"; "zombie-"]

let registry_prune_cmd =
  let+ patterns =
    Cmdliner.Arg.(value & opt (list string) default_prune_patterns
      & info ["pattern"; "p"]
        ~docv:"PREFIX"
        ~doc:"Alias prefix to consider for pruning. Can be passed multiple times. \
              Default: eph-, heal-, mon-, test-, tmp-, zombie-. \
              Only registrations matching one of these prefixes AND \
              that are dead (no live PID, provisional expired) are pruned.")
  and+ json = json_flag
  and+ dry_run =
    Cmdliner.Arg.(value & flag & info ["dry-run"; "n"]
      ~doc:"Show what would be pruned without actually removing anything. \
            This is the default when --force is not passed.")
  and+ force =
    Cmdliner.Arg.(value & flag & info ["force"; "f"]
      ~doc:"Actually remove the matching registrations. Without this flag, \
            the command runs in dry-run mode and exits 0 if there are matches.")
  in
  let patterns = if patterns = [] then default_prune_patterns else patterns in
  let managed_sids = c2c_start_session_ids () in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  (* Read-only preview: load all regs, classify without saving. *)
  let candidate_pruned = C2c_mcp.Broker.registry_prune_preview broker
    ~managed_session_ids:managed_sids ~patterns
  in
  if candidate_pruned = [] then
    Printf.printf "No stale test registrations to prune.\n"
  else if not force then
    (* Dry-run (default): show what would be pruned, don't modify. *)
    let output_mode = if json then Json else Human in
    match output_mode with
    | Json ->
        print_json
          (`Assoc [ "pruned", `List (List.map (fun (r : C2c_mcp.registration) ->
              `Assoc [ ("session_id", `String r.session_id); ("alias", `String r.alias) ])
              candidate_pruned) ])
    | Human ->
        Printf.printf "Would prune %d stale registration(s) (dry-run):\n" (List.length candidate_pruned);
        List.iter (fun (r : C2c_mcp.registration) ->
          Printf.printf "  %s (%s)\n" r.alias r.session_id) candidate_pruned;
        Printf.printf "Run with --force to actually remove them.\n"
  else
    (* --force: actually prune. *)
    let pruned = C2c_mcp.Broker.registry_prune broker
      ~managed_session_ids:managed_sids ~patterns
    in
    let output_mode = if json then Json else Human in
    match output_mode with
    | Json ->
        print_json
          (`Assoc [ "pruned", `List (List.map (fun (r : C2c_mcp.registration) ->
              `Assoc [ ("session_id", `String r.session_id); ("alias", `String r.alias) ])
              pruned) ])
    | Human ->
        Printf.printf "Pruned %d stale registration(s):\n" (List.length pruned);
        List.iter (fun (r : C2c_mcp.registration) ->
          Printf.printf "  %s (%s)\n" r.alias r.session_id) pruned;
        Printf.printf "Note: orphan inboxes still exist. Run 'c2c sweep --force' to clean those up.\n"

let force_flag =
  Cmdliner.Arg.(value & flag & info [ "force"; "f" ]
    ~doc:"Skip the alive-registration safety check and run sweep anyway.\
          Use this only when you have verified no live sessions are present.")

let sweep_cmd =
  let+ json = json_flag
  and+ force = force_flag in
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
  (* Safety guard: refuse to sweep if any alive non-managed registrations exist. *)
  let alive_nonmanaged_regs =
    let all_regs = C2c_mcp.Broker.list_registrations broker in
    List.filter (fun (r : C2c_mcp.registration) ->
      not (List.mem r.session_id c2c_start_sids)
      && C2c_mcp.Broker.registration_is_alive r
    ) all_regs
  in
  if alive_nonmanaged_regs <> [] && not force then begin
    Printf.eprintf "error: %d alive registration(s) would be dropped by sweep.\n"
      (List.length alive_nonmanaged_regs);
    List.iter (fun (r : C2c_mcp.registration) ->
      Printf.eprintf "  alive: %s (%s)\n" r.alias r.session_id
    ) alive_nonmanaged_regs;
    Printf.eprintf "  Use --force to override this safety check.\n%!";
    exit 1
  end;
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

(** #507: rewrite .opencode/c2c-plugin.json with the post-migration broker_root
    and current fingerprint, preserving session_id and alias for continuity. *)
let sync_sidecar_for_migration ~new_root ~json =
  let sidecar_path = Sys.getcwd () // ".opencode" // "c2c-plugin.json" in
  if not (Sys.file_exists sidecar_path) then begin
    if json then print_json (`Assoc ["sidecar_sync", `String "skipped_no_sidecar"])
    else Printf.printf "[sidecar sync] skipped: no .opencode/c2c-plugin.json in cwd\n";
    ()
  end else begin
    let old = try Yojson.Safe.from_file sidecar_path with _ -> `Assoc [] in
    let session_id = match Yojson.Safe.Util.member "session_id" old with
      | `String s -> s | _ -> "unknown"
    in
    let alias = match Yojson.Safe.Util.member "alias" old with
      | `String a -> a | _ -> ""
    in
    let fp = try Repo_fp.repo_fingerprint () with _ -> "" in
    let new_sidecar = `Assoc [
      ("session_id", `String session_id);
      ("alias", `String alias);
      ("broker_root", `String new_root);
      ("broker_root_fingerprint", `String fp);
    ]
    in
    if json then print_json (`Assoc ["sidecar_sync", `String "updated"])
    else Printf.printf "[sidecar sync] updated %s with new broker_root=%s\n" sidecar_path new_root;
    Yojson.Safe.to_file sidecar_path new_sidecar
  end

let mcp_config_rewriter_run ~legacy ~default ~dry_run ~print_line =
  let repo_root =
    match Git_helpers.git_repo_toplevel () with
    | Some t -> t
    | None -> Sys.getcwd ()
  in
  let paths = C2c_mcp_config_rewriter.default_scan_paths ~repo_root in
  print_line "";
  print_line "--- mcp-config rewriter -----------------------------------";
  C2c_mcp_config_rewriter.run ~legacy ~default ~paths ~dry_run ~print_line

let suggest_shell_export_run ~stale_broker_root ~canonical =
  let stale = Option.value stale_broker_root ~default:"" in
  let stale = String.trim stale in
  if stale = "" then
    Printf.printf "C2C_MCP_BROKER_ROOT is not set — no shell export needed.\n\
                    The canonical broker root resolver is already active.\n"
  else if stale = canonical then
    Printf.printf "C2C_MCP_BROKER_ROOT is already set to the canonical path — no action needed.\n\
                    Current value: %s\n"
      stale
  else begin
    Printf.printf "C2C_MCP_BROKER_ROOT is pointing to a stale path:\n";
    Printf.printf "  current:  %s\n" stale;
    Printf.printf "  canonical: %s\n" canonical;
    Printf.printf "\n\
After running 'c2c migrate-broker', run this command to stop the warning:\n\
\n\
  unset C2C_MCP_BROKER_ROOT\n\
\n\
To find and remove the export from your shell config, try:\n\
  grep -r 'C2C_MCP_BROKER_ROOT' ~/.bashrc ~/.bash_profile ~/.zshrc ~/.profile 2>/dev/null\n\
\n\
Canonical broker root: %s\n%!"
      canonical
  end

let migrate_broker_run ~from_path ~to_path ~dry_run ~json ~sync_sidecar ~rewrite_mcp_configs ~suggest_shell_export =
  let from = Option.value from_path ~default:(legacy_broker_root ()) in
  let to_ = Option.value to_path ~default:(resolve_broker_root ()) in
  let do_rewrite ~print_line =
    if rewrite_mcp_configs then
      let _ : C2c_mcp_config_rewriter.outcome =
        mcp_config_rewriter_run ~legacy:from ~default:to_ ~dry_run ~print_line
      in
      ()
  in
  (* Standalone mode: --suggest-shell-export shows the operator what to put in
     their shell config to stop the stale-broker-root warning, without running
     any migration. Works even when no broker data exists. *)
  if suggest_shell_export then begin
    let stale = Sys.getenv_opt "C2C_MCP_BROKER_ROOT" in
    let canonical = C2c_repo_fp.resolve_broker_root_canonical () in
    suggest_shell_export_run ~stale_broker_root:stale ~canonical;
    exit 0
  end;
  (* Standalone mode: --rewrite-mcp-configs without a usable broker source.
     Run only the rewriter; skip broker-data migration. *)
  if rewrite_mcp_configs && not (Sys.file_exists from) then begin
    let buf = Buffer.create 1024 in
    let print_line s =
      if json then begin Buffer.add_string buf s; Buffer.add_char buf '\n' end
      else print_endline s
    in
    do_rewrite ~print_line;
    if json then
      print_json (`Assoc ["ok", `Bool true; "log", `String (Buffer.contents buf)
                         ; "rewrite_mcp_configs", `Bool true
                         ; "broker_data_skipped", `Bool true ]);
    exit 0
  end;
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
  let buf = Buffer.create 4096 in
  let print_line s =
    if json then begin Buffer.add_string buf s; Buffer.add_char buf '\n' end
    else print_endline s
  in
  if not json then begin
    Printf.printf "Migrating broker data:\n";
    Printf.printf "  from: %s\n" from;
    Printf.printf "  to:   %s\n" to_;
    if dry_run then Printf.printf "  mode: DRY RUN (no files will be written)\n"
    else Printf.printf "  mode: LIVE (files will be written)\n";
    if sync_sidecar then Printf.printf "  sidecar sync: enabled\n"
  end;
  let outcome =
    C2c_migrate.run ~src_root:from ~dest_root:to_ ~dry_run ~print_line
  in
  do_rewrite ~print_line;
  if json then begin
    let assoc =
      [ "ok", `Bool outcome.ok
      ; "from", `String from
      ; "to", `String to_
      ; "dry_run", `Bool dry_run
      ; "copied", `List (List.map (fun s -> `String s) outcome.copied)
      ; "skipped_already_at_canonical",
          `List (List.map (fun s -> `String s) outcome.skipped_already)
      ; "denied_process_local",
          `List (List.map (fun (p, r) ->
            `Assoc ["path", `String p; "reason", `String r]) outcome.denied)
      ; "unknown",
          `List (List.map (fun (p, r) ->
            `Assoc ["path", `String p; "reason", `String r]) outcome.unknown)
      ; "log", `String (Buffer.contents buf)
      ]
    in
    let assoc = match outcome.error with
      | Some e -> ("error", `String e) :: assoc
      | None -> assoc
    in
    print_json (`Assoc assoc)
  end;
  if not outcome.ok then exit 1;
  (* #507: after successful live migration, sync the opencode sidecar so the
     plugin sees the new broker_root and current fingerprint without a restart. *)
  if sync_sidecar && not dry_run then sync_sidecar_for_migration ~new_root:to_ ~json

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
  let sync_sidecar =
    Arg.(value & flag & info ["sync-sidecar"; "s"]
           ~doc:"After a successful migration, update .opencode/c2c-plugin.json with the new broker_root and current fingerprint so the OpenCode plugin picks up the new broker without a restart. Only applies to live (non-dry-run) migrations.")
  in
  let rewrite_mcp_configs =
    Arg.(value & flag & info ["rewrite-mcp-configs"]
           ~doc:"Also strip stale C2C_MCP_BROKER_ROOT env entries from \
                 .mcp.json files (project root + $(b,.worktrees/*)) when their \
                 value matches the legacy path or the current resolver default. \
                 Operator overrides are preserved (logged [KEEP]). \
                 Compatible with --dry-run.")
  in
  let suggest_shell_export =
    Arg.(value & flag & info ["suggest-shell-export"]
           ~doc:"Print shell commands to permanently unset C2C_MCP_BROKER_ROOT \
                 after migration, so the canonical resolver takes over and the \
                 stale-broker-root warning stops appearing. Can be used alone \
                 (without --from/--to) to check the current env-var state. \
                 Does not perform any file operations.")
  in
  let json = json_flag in
  let+ from_path = from
  and+ to_path = to_
  and+ dry_run = dry_run
  and+ sync_sidecar = sync_sidecar
  and+ rewrite_mcp_configs = rewrite_mcp_configs
  and+ suggest_shell_export = suggest_shell_export
  and+ json = json in
  migrate_broker_run ~from_path ~to_path ~dry_run ~json ~sync_sidecar
    ~rewrite_mcp_configs ~suggest_shell_export

let migrate_broker =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "migrate-broker"
       ~doc:"Migrate broker data from the legacy .git/c2c/mcp path to the new per-repo path."
       ~man:[ `S "DESCRIPTION"
            ; `P "Migrates broker state from the legacy $(b,.git/c2c/mcp) path to the \
                  canonical per-repo path ($(b,\\$XDG_STATE_HOME/c2c/repos/<fp>/broker) \
                  or $(b,\\$HOME/.c2c/repos/<fp>/broker))."
            ; `P "Run $(b,--dry-run) first to preview the action plan."
            ; `S "TWO-PHASE COMMIT"
            ; `P "The migration is a two-phase commit: (1) COPY every eligible entry to \
                  the destination and verify the copy succeeded, then (2) REMOVE the \
                  legacy tree only after every copy is confirmed. If any step aborts or \
                  fails, the legacy tree is preserved untouched and the command exits \
                  with status 1 — re-running after a fix is safe."
            ; `S "COPY-SET SEMANTICS"
            ; `P "Default policy is COPY-by-default: every entry under the legacy root \
                  is copied unless it matches the deny-list."
            ; `P "Deny-list (NOT copied): $(b,*.pid) files (live-PID-bound state, \
                  meaningless across migrations) and top-level $(b,*.lock) files \
                  (fcntl/flock sidecars; recreated on demand)."
            ; `S "FAIL-LOUD ON UNKNOWN"
            ; `P "Unknown filesystem entries (FIFOs, sockets, character devices, block \
                  devices, or any non-regular/non-directory/non-symlink type) abort the \
                  migration BEFORE any copy is performed. The legacy tree is left \
                  intact; resolve or remove the offending entry, then re-run."
            ; `S "MCP-CONFIG REWRITER"
            ; `P "With $(b,--rewrite-mcp-configs), additionally scan \
                  $(b,.mcp.json) files (project root + $(b,.worktrees/*)) and \
                  strip $(b,C2C_MCP_BROKER_ROOT) entries whose value matches \
                  either the legacy path or the current resolver default. \
                  Operator-overridden values are preserved with a $(b,[KEEP]) \
                  log line. Compatible with $(b,--dry-run). Default off."
             ; `S "SHELL EXPORT SUGGESTION (#581 S3)"
             ; `P "After a migration, your shell may still have $(b,C2C_MCP_BROKER_ROOT) \
                   pointing to the old (now-empty) path, causing 'stale broker root' \
                   warnings on every $(b,c2c start). Run $(b,--suggest-shell-export) \
                   to print the exact $(b,unset C2C_MCP_BROKER_ROOT) command and \
                   grep commands to find the stale export in your shell config files. \
                   Can be used standalone without --from/--to."
             ; `S "DRY-RUN OUTPUT LEGEND"
            ; `P "$(b,[WILL COPY])             — entry is in the copy-set and will be \
                  written to the destination."
            ; `P "$(b,[WILL DENY])             — entry matches the deny-list and will \
                  be skipped (e.g. $(b,*.pid), top-level $(b,*.lock))."
            ; `P "$(b,[ALREADY AT CANONICAL]) — entry already exists at the destination \
                  with matching content; no-op."
            ; `P "$(b,[UNKNOWN])               — entry has an unrecognized file type; \
                  migration will abort with exit 1 if run without $(b,--dry-run)."
             ; `S "SIDE CAR SYNC (#507)"
             ; `P "Use $(b,--sync-sidecar) after a live migration to rewrite \
                   $(b,.opencode/c2c-plugin.json) with the new broker_root and \
                   current fingerprint. The OpenCode plugin detects the stale \
                   fingerprint on its next poll and rereads the sidecar without \
                   requiring a session restart. This flag has no effect during \
                   dry-runs."
             ; `S "EXIT STATUS"
             ; `P "0 on successful migration (or clean dry-run). 1 on abort/failure — \
                   the legacy tree is preserved so the operator can investigate and \
                   retry."
             ])
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
  let no_headers_flag =
    Cmdliner.Arg.(value & flag & info [ "no-headers" ]
      ~doc:"Suppress per-message header lines (timestamp + from -> to). \
            Default emits a header before each body so messages are \
            distinguishable; pass this to restore the legacy bare-body \
            output for grep-friendly scripts. Has no effect with --json.")
  in
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Look up session ID by alias and read that session's archive. \
Mutually exclusive with --session-id.")
  in
  let+ json = json_flag
  and+ limit = limit
  and+ session_id_opt = session_id_flag
  and+ no_headers = no_headers_flag
  and+ alias_opt = alias_flag in
  let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
  let session_id =
    match session_id_opt, alias_opt with
    | Some _, Some _ ->
        Printf.eprintf "error: --session-id and --alias are mutually exclusive.\n%!";
        exit 1
    | Some sid, None -> sid
    | None, Some alias ->
        let regs = C2c_mcp.Broker.list_registrations broker in
        let matches = List.filter (fun (r : C2c_mcp.registration) -> r.alias = alias) regs in
        (match matches with
         | [] ->
             Printf.eprintf "error: alias '%s' not found in registry.\n%!" alias;
             exit 1
         | [ r ] -> r.session_id
         | _ ->
             Printf.eprintf "error: alias '%s' matches multiple sessions.\n%!" alias;
             exit 1)
    | None, None -> resolve_session_id_for_inbox broker
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
      let headers = not no_headers in
      List.iter print_endline (C2c_history.format_human ~headers entries)

(* Health, connect, verify, host-id subcommands extracted to c2c_health_cmd.ml *)

(* --- subcommand: list-glyphs --------------------------------------------- *)
(* .collab/design/2026-06-26-c2c-list-glyphs-registry.md — emit the canonical
   c2c TUI glyph registry (message direction, broker route, liveness,
   subagent-registration vocabulary + ascii fallbacks + semantic colors +
   action tokens + message-sources) as JSON so clients (pi-c2c today) can
   fetch the vocabulary at launch instead of hardcoding it.

   HARD CONSTRAINT: this command MUST be always-runnable in any session.
   pi-c2c invokes it with the host session env (which may set a session-id
   var that flips `is_agent_session ()` true). It is therefore classified
   Tier1 in command_tier_map so `filter_commands` never drops it from the
   dispatchable cmdliner group. "Hidden from help by default" is handled in
   the help-text layer via `hidden_unless_dev` + the global `--dev` flag,
   NOT via the tier filter (which would make it unrunnable). *)
let list_glyphs_cmd =
  let compact =
    Cmdliner.Arg.(value & flag & info [ "compact" ]
      ~doc:"Emit single-line JSON instead of pretty-printed.")
  in
  let+ compact = compact in
  let json = Glyphs.to_json () in
  if compact then print_endline (Yojson.Safe.to_string json)
  else print_json json

let list_glyphs =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list-glyphs"
      ~doc:"(dev) emit the canonical c2c TUI glyph registry as JSON")
    list_glyphs_cmd

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
  let parent_env = Unix.environment () in
  (* #367: only inject GIT_AUTHOR_{NAME,EMAIL} defaults when the parent env
     hasn't already set them — operators must be able to override the alias
     attribution from inside a managed session without bypassing the shim. *)
  let env_array = match env with
    | None -> [||]
    | Some (name, email) ->
        C2c_git_shim.build_author_overlay ~parent_env ~name ~email
  in
  Unix.execve git_path argv (Array.append env_array parent_env)

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
  (* Prefer C2C_MCP_CLIENT_PID (set by managed launchers to the outer loop PID)
     over getppid(), so `c2c register` from inside a managed session pins
     liveness to the durable outer process rather than a transient shell. *)
  let pid =
    match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
    | Some s -> (match int_of_string_opt (String.trim s) with Some p -> Some p | None -> Some (Unix.getppid ()))
    | None -> Some (Unix.getppid ())
  in
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

(* --- subcommand: deregister ---------------------------------------------- *)

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

(* --- subcommand: get-tmux-location ---------------------------------------- *)

let get_tmux_location_cmd =
  let+ json = json_flag in
  (* #418: prefer $TMUX_PANE (pane-bound, race-free) over server-active pane. *)
  let pane_id = Sys.getenv_opt "TMUX_PANE" in
  let tmux_set = Sys.getenv_opt "TMUX" in
  match pane_id, tmux_set with
  | None, None ->
      (* Neither TMUX nor TMUX_PANE is set — definitely not in tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | Some _, None ->
      (* TMUX_PANE survived env -u TMUX (orphaned pane var from a dead session).
         TMUX is not set so tmux commands will fail. Treat as non-tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | _, Some _ ->
      let cmd = match pane_id with
        | Some p when String.trim p <> "" ->
            Printf.sprintf "tmux display-message -t %s -p '#S:#I.#P'"
              (Filename.quote p)
        | _ -> "tmux display-message -p '#S:#I.#P'"
      in
      let capture cmd =
        try
          let ic = Unix.open_process_in cmd in
          Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> Some (input_line ic))
        with _ -> None
      in
      match capture cmd with
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
  let info = C2c_mcp.server_info () in
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
                       | C2c_mcp.Unlisted -> "unlisted"
                       | C2c_mcp.Gated -> "gated"
                       | C2c_mcp.Private -> "private"))
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

(* Monitor subcommand extracted to c2c_monitor_cmd.ml *)


(* --- subcommand: hook (PostToolUse inbox hook) ----------------------------- *)

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

let hook_post_tool = Cmdliner.Cmd.v (Cmdliner.Cmd.info "post-tool" ~doc:"PostToolUse hook: drain inbox and emit messages.") hook_post_tool_cmd

(* --- subcommand: hook stop (Stop hook for text-only turn delivery) --- *)

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

let hook_stop = Cmdliner.Cmd.v (Cmdliner.Cmd.info "stop" ~doc:"Stop hook: deliver queued messages on text-only turns (blocks stop to inject messages).") hook_stop_cmd

let hook =
  let info = Cmdliner.Cmd.info "hook"
    ~doc:"Hook subcommands for Claude Code integration. Use 'post-tool' for PostToolUse (drain inbox) and 'stop' for Stop (text-only turn delivery)."
  in
  (* Default to post-tool for backward compat: `c2c hook` (no subcommand) behaves
     as the PostToolUse hook, same as before the hook group refactor. *)
  Cmdliner.Cmd.group ~default:hook_post_tool_cmd info [ hook_post_tool; hook_stop ]

(* Relay subcommands extracted to c2c_relay_cmd.ml *)

(* --- mesh ------------------------------------------------------------------- *)

let mesh_status_cmd =
  let open Cmdliner in
  let relay_url_flag =
    Arg.(value & opt (some string) None & info ["relay-url"] ~docv:"URL"
           ~doc:"Relay HTTP URL. Defaults to C2C_RELAY_URL env var.")
  in
  let include_dead =
    Arg.(value & flag & info ["include-dead"; "a"]
           ~doc:"Include reserved offline aliases in the peer list.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output raw JSON instead of a human-readable table.")
  in
  let+ relay_url = relay_url_flag
  and+ include_dead = include_dead
  and+ as_json = json_flag in
  match C2c_relay_cmd.resolve_relay_url relay_url with
  | None ->
      Printf.eprintf "%s%!" C2c_relay_cmd.relay_url_required_error;
      exit 1
  | Some url ->
      let client = Relay.Relay_client.make url in
      (* Fetch peers — signed if identity exists and --include-dead not set. *)
      let peers_result = (
        match Relay_identity.load (), include_dead with
        | Ok id, false ->
            let alias = Option.value ~default:"anon" (env_auto_alias ()) in
            let auth = Relay_signed_ops.sign_request id ~alias
              ~meth:"GET" ~path:"/list" ~body_str:"" () in
            Lwt_main.run (Relay.Relay_client.list_peers_signed client ~auth_header:auth ())
        | _ ->
            Lwt_main.run (Relay.Relay_client.list_peers client ~include_dead ())
      ) in
      (* Fetch rooms. *)
      let rooms_result = Lwt_main.run (Relay.Relay_client.list_rooms client) in
      if as_json then begin
        let now_ts = Unix.gettimeofday () in
        let format_time t =
          let tm = Unix.gmtime t in
          Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
            (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
            tm.tm_hour tm.tm_min tm.tm_sec
        in
        (* Relay token status: signed when identity exists and include_dead not requested. *)
        let relay_token_status = match Relay_identity.load (), include_dead with
          | Ok _, false -> "signed"
          | Ok _, true -> "unsigned" (* signed auth excluded dead peers *)
          | Error _, _ -> "unsigned"
        in
        let peers_raw = (match peers_result with
          | `Assoc fields ->
              (match List.assoc_opt "peers" fields with
               | Some (`List ps) -> ps
               | _ -> [])
          | _ -> []) in
        let alive_peers = List.filter (fun p ->
          match p with `Assoc fs ->
            (match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false)
          | _ -> false) peers_raw in
        let dead_peers = List.filter (fun p ->
          match p with `Assoc fs ->
            (match List.assoc_opt "alive" fs with Some (`Bool a) -> not a | _ -> false)
          | _ -> false) peers_raw in
        let peers_json = `List (List.map (fun p ->
          match p with `Assoc fs ->
            let alive = match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false in
            let last_seen = match List.assoc_opt "last_seen" fs with Some (`Float t) -> t | _ -> 0.0 in
            let ttl = match List.assoc_opt "ttl" fs with Some (`Float t) -> t | _ -> 0.0 in
            let ttl_remaining = if alive then max 0.0 (last_seen +. ttl -. now_ts) else 0.0 in
            let extra = [
              ("last_seen_iso8601", `String (format_time last_seen));
              ("ttl_remaining_seconds", `Float ttl_remaining);
            ] in
            `Assoc (fs @ extra)
          | _ -> p) peers_raw) in
        let rooms_raw = (match rooms_result with
          | `Assoc fields ->
              (match List.assoc_opt "rooms" fields with
               | Some (`List rs) -> rs
               | _ -> [])
          | _ -> []) in
        let rooms_json = `List (List.map (fun r ->
          match r with `Assoc fs ->
            let member_count = match List.assoc_opt "member_count" fs with
              | Some (`Int n) -> `Int n
              | _ -> `Int 0
            in
            `Assoc (fs @ [("member_count_int", member_count)])
          | _ -> r) rooms_raw) in
        let kv = [
          ("ok", `Bool true);
          ("relay_url", `String url);
          ("relay_token_status", `String relay_token_status);
          ("queried_at_iso8601", `String (format_time now_ts));
          ("peers_count", `Int (List.length peers_raw));
          ("alive_count", `Int (List.length alive_peers));
          ("dead_count", `Int (List.length dead_peers));
          ("peers", peers_json);
          ("rooms_count", `Int (List.length rooms_raw));
          ("rooms", rooms_json);
        ] in
        print_endline (Yojson.Safe.to_string (`Assoc kv));
        exit 0
      end;
      (* Human-readable output. *)
      let peers = (match peers_result with
        | `Assoc fields ->
            (match List.assoc_opt "peers" fields with
             | Some (`List ps) -> ps
             | _ -> [])
        | _ -> []) in
      let alive_peers = List.filter (fun p ->
        match p with `Assoc fs ->
          (match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false)
        | _ -> false) peers in
      let dead_peers = List.filter (fun p ->
        match p with `Assoc fs ->
          (match List.assoc_opt "alive" fs with Some (`Bool a) -> not a | _ -> false)
        | _ -> false) peers in
      let format_time t =
        let tm = Unix.gmtime t in
        Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
          (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
          tm.tm_hour tm.tm_min tm.tm_sec
      in
      let print_peer p =
        match p with
        | `Assoc fs ->
            let alias = match List.assoc_opt "alias" fs with Some (`String s) -> s | _ -> "?" in
            let session_id = match List.assoc_opt "session_id" fs with
              | Some (`String s) -> if String.length s >= 12 then String.sub s 0 12 else s
              | _ -> "?" in
            let client_type = match List.assoc_opt "client_type" fs with Some (`String s) -> s | _ -> "?" in
            let last_seen = match List.assoc_opt "last_seen" fs with Some (`Float t) -> format_time t | _ -> "?" in
            let ttl = match List.assoc_opt "ttl" fs with Some (`Float t) -> Printf.sprintf "%.0fs" t | _ -> "?" in
            let alive = match List.assoc_opt "alive" fs with Some (`Bool a) -> a | _ -> false in
            Printf.printf "  %-18s %-14s %-10s %-22s %-6s  %s\n"
              alias session_id client_type last_seen ttl (if alive then "ALIVE" else "DEAD")
        | _ -> ()
      in
      let rooms = (match rooms_result with
        | `Assoc fields ->
            (match List.assoc_opt "rooms" fields with
             | Some (`List rs) -> rs
             | _ -> [])
        | _ -> []) in
      let total_rooms = List.length rooms in
      Printf.printf "c2c mesh status — relay=%s\n\n" url;
      let dead_count = List.length dead_peers in
      let dead_suffix = if dead_count > 0 then Printf.sprintf ", %d reserved offline" dead_count else "" in
      let hint_suffix =
        if dead_count > 0 && not include_dead then "; use --include-dead to show reserved offline aliases"
        else if dead_count = 0 && include_dead then "; (no reserved offline aliases)"
        else ""
      in
      Printf.printf "Peers (%d alive%s%s):\n"
        (List.length alive_peers) dead_suffix hint_suffix;
      if not include_dead && dead_peers <> [] then
        Printf.printf "  (omitting %d reserved offline aliases; use --include-dead to show)\n"
          (List.length dead_peers);
      Printf.printf "  %-18s %-14s %-10s %-22s %-6s  %s\n"
        "ALIAS" "SESSION_ID" "TYPE" "LAST_SEEN" "TTL" "STATUS";
      Printf.printf "  %s\n"
        (String.make 82 '-');
      List.iter print_peer (if include_dead then peers else alive_peers);
      Printf.printf "\nRooms on relay (%d):\n" total_rooms;
      if rooms = [] then
        Printf.printf "  (none)\n"
      else
        List.iter (fun r ->
          match r with
          | `Assoc fs ->
              let room_id = match List.assoc_opt "room_id" fs with Some (`String s) -> s | _ -> "?" in
              let member_count = match List.assoc_opt "member_count" fs with Some (`Int n) -> n | _ -> 0 in
              Printf.printf "  %-24s  (%d members)\n" room_id member_count
          | _ -> ()) rooms;
      exit 0

let mesh_status = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "status"
       ~doc:"Show peer topology of a remote relay in human-readable format.")
    mesh_status_cmd

let mesh_group =
  Cmdliner.Cmd.group
    ~default:mesh_status_cmd
    (Cmdliner.Cmd.info "mesh"
       ~doc:"Inspect the peer mesh connected to a remote relay."
       ~man:[ `S "DESCRIPTION"
            ; `P "Reports who is connected to a relay and which rooms exist."
            ; `P "Use $(b,c2c mesh status --relay-url URL) to see peers and rooms on a relay."
            ; `P "This is a read-only diagnostic command — it does not modify any state."
            ])
    [ mesh_status ]

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

let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a registered peer alias or session ID.") send_cmd
let list = Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List registered C2C peers.") list_cmd
let sessions = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sessions" ~doc:"List registered sessions with session_id, alias, client_type, cwd, and liveness.") sessions_cmd
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
  let alias_flag =
    Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
      ~doc:"Alias whose inbox to peek. Useful for unmanaged CLI peers; mutually exclusive with --session-id.")
  in
  let+ json = json_flag
  and+ session_id_opt = session_id_flag
  and+ alias_opt = alias_flag
  and+ cross_repo = cross_repo_flag in
  mcp_nudge_if_needed ~cmd:"peek-inbox";
  (match session_id_opt, alias_opt with
   | Some _, Some _ -> Printf.eprintf "error: --session-id and --alias are mutually exclusive.\n%!"; exit 1
   | _ -> ());
  let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
  let session_id = match session_id_opt with
    | Some sid -> sid
    | None -> resolve_session_id_for_inbox ?alias:alias_opt broker
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

let peek_inbox = Cmdliner.Cmd.v (Cmdliner.Cmd.info "peek-inbox" ~doc:"Peek at your inbox without draining.") peek_inbox_cmd

(* Approval subcommands extracted to c2c_approval_cmd.ml *)

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

let send_all = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.") send_all_cmd
let sweep = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sweep" ~doc:"Remove dead registrations and orphan inboxes.") sweep_cmd
let registry_prune = Cmdliner.Cmd.v (Cmdliner.Cmd.info "registry-prune" ~doc:"Remove dead test registrations matching prefix patterns (dry-run by default; --force to actually prune).") registry_prune_cmd
let history = Cmdliner.Cmd.v (Cmdliner.Cmd.info "history" ~doc:"Show archived inbox messages.") history_cmd
let register = Cmdliner.Cmd.v (Cmdliner.Cmd.info "register" ~doc:"Register an alias for the current session.") register_cmd
let deregister = Cmdliner.Cmd.v (Cmdliner.Cmd.info "deregister" ~doc:"Remove a registration from the broker.") deregister_cmd
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

(* Init/setup command island moved to c2c_init_cmd.ml. *)

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
  let rec loop ~negotiated_capabilities =
    let* msg = read_message () in
    match msg with
    | None -> Lwt.return_unit
    | Some line ->
        let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
        match json with
        | Error () ->
            let* () = write_message (Json_util.jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
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
                  let queued = C2c_mcp.Broker.drain_inbox_push ~drained_by:"watcher" broker ~session_id:sid in
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

(* Managed-instance commands moved to c2c_instances_cmd.ml. *)

(* --- doctor command group moved to c2c_doctor_cmd.ml --------------------- *)

(* --- subcommand: relay-pins delete ---------------------------------------- *)

let relay_pins_delete_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(required & pos 0 (some string) None & info []
           ~docv:"ALIAS" ~doc:"Target alias whose pins to delete.")
  in
  let ed25519_flag =
    Arg.(value & flag & info ["ed25519"]
           ~doc:"Delete the Ed25519 pin for the alias.")
  in
  let x25519_flag =
    Arg.(value & flag & info ["x25519"]
           ~doc:"Delete the X25519 pin for the alias.")
  in
  let min_version_flag =
    Arg.(value & flag & info ["min-version"]
           ~doc:"Delete the min-observed-envelope-version pin for the alias.")
  in
  let all_flag =
    Arg.(value & flag & info ["all"]
           ~doc:"Delete all three pin types for the alias (default if no axis flag is given).")
  in
  let+ alias = alias_flag
  and+ delete_ed25519 = ed25519_flag
  and+ delete_x25519 = x25519_flag
  and+ delete_min_version = min_version_flag
  and+ delete_all = all_flag in
  let axes =
    if delete_all || (not delete_ed25519 && not delete_x25519 && not delete_min_version) then
      ["ed25519"; "x25519"; "min_observed_envelope_version"]
    else
      (if delete_ed25519 then ["ed25519"] else [])
      @ (if delete_x25519 then ["x25519"] else [])
      @ (if delete_min_version then ["min_observed_envelope_version"] else [])
  in
  if axes = [] then
    (Printf.eprintf "Error: no pin axis specified. Use --all or at least one of --ed25519, --x25519, --min-version.\n%!";
     exit 1);
  let broker_root = C2c_utils.resolve_broker_root () in
  C2c_mcp.Broker.relay_pin_delete ~broker_root ~alias ~axes;
  let axes_str = String.concat ", " axes in
  Printf.printf "Deleted %s pins for alias %s.\n" axes_str alias;
  Printf.printf "Audit event written to broker.log.\n";
  exit 0

let relay_pins_delete =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "delete"
       ~doc:"Delete one or more TOFU pins for an alias.")
    relay_pins_delete_cmd

(* --- subcommand: relay-pins rotate ---------------------------------------- *)

let relay_pins_rotate_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(required & pos 0 (some string) None & info []
           ~docv:"ALIAS" ~doc:"Target alias whose pins to rotate.")
  in
  let+ alias = alias_flag in
  let broker_root = C2c_utils.resolve_broker_root () in
  let epoch = C2c_mcp.Broker.relay_pin_rotate ~broker_root ~alias in
  Printf.printf "Rotated all pins for alias %s (rotation_epoch=%d).\n" alias epoch;
  Printf.printf "Next first-contact from this alias will be logged as expected (TOFU first-seen).\n";
  Printf.printf "Audit event written to broker.log.\n";
  exit 0

let relay_pins_rotate =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "rotate"
       ~doc:"Rotate all TOFU pins for an alias (clears keys and bumps rotation epoch).")
    relay_pins_rotate_cmd

(* --- subcommand: relay-pins list ----------------------------------------- *)

let relay_pins_list_cmd =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "list"
       ~doc:"List all pinned aliases and their key fingerprints + min-observed-envelope-version. Alias for relay-pin-status.")
    C2c_doctor_cmd.relay_pin_status_cmd

(* --- relay-pins command group --------------------------------------------- *)

let relay_pins =
  Cmdliner.Cmd.group
    ~default:C2c_doctor_cmd.relay_pin_status_cmd
    (Cmdliner.Cmd.info "relay-pins"
       ~doc:"Inspect and manage broker TOFU pins (relay_pins.json).")
    [ relay_pins_list_cmd; C2c_doctor_cmd.relay_pin_status; relay_pins_delete; relay_pins_rotate ]

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
  let with_tmux = match r.tmux_location with
    | Some loc -> with_dnd @ [("tmux_location", `String loc)]
    | None -> with_dnd
  in
  let with_cwd = match r.cwd with
    | Some c -> with_tmux @ [("cwd", `String c)]
    | None -> with_tmux
  in
  `Assoc with_cwd

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
  C2c_utils.mkdir_p dir;
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
   | Some s when not (List.mem s C2c_init_cmd.valid_strategies) ->
       Printf.eprintf "error: unknown strategy '%s'. Use: %s\n%!" s (String.concat ", " C2c_init_cmd.valid_strategies);
       exit 1
   | _ -> ());
  let config = C2c_init_cmd.load_repo_config () in
  let fields = match config with `Assoc f -> f | _ -> [] in
  let supervisor_val = `List (List.map (fun a -> `String a) aliases) in
  let fields' = ref
    (("supervisors", supervisor_val)
     :: List.filter (fun (k, _) -> k <> "supervisors" && k <> "permission_supervisors" && k <> "supervisor_strategy") fields)
  in
  (match strategy_opt with
   | Some s -> fields' := ("supervisor_strategy", `String s) :: !fields'
   | None -> ());
  C2c_init_cmd.save_repo_config (`Assoc !fields');
  let output_mode = if json then Json else Human in
  let strategy_str = match strategy_opt with Some s -> s | None -> "first-alive (default)" in
  (match output_mode with
   | Json ->
       let out = [ ("ok", `Bool true); ("supervisors", supervisor_val); ("config", `String (C2c_init_cmd.repo_config_path ())) ] in
       let out = match strategy_opt with Some s -> ("supervisor_strategy", `String s) :: out | None -> out in
       print_json (`Assoc out)
   | Human ->
       Printf.printf "Supervisor set: %s\n" (String.concat ", " aliases);
       Printf.printf "Strategy:      %s\n" strategy_str;
       Printf.printf "Config:        %s\n" (C2c_init_cmd.repo_config_path ());
       Printf.printf "Override:      C2C_PERMISSION_SUPERVISOR=alias or C2C_SUPERVISORS=a,b\n")

let repo_show_cmd =
  let+ json = json_flag in
  let config = C2c_init_cmd.load_repo_config () in
  let output_mode = if json then Json else Human in
  (match output_mode with
   | Json -> print_json config
   | Human ->
       let path = C2c_init_cmd.repo_config_path () in
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
    let now = C2c_time.iso8601_utc_ms (Unix.gettimeofday ())
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
    let mkdir_p dir = C2c_mcp.mkdir_p ~mode:0o700 dir in
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
            C2c_mcp.Broker.append_archive ~drained_by:"oc_plugin" broker ~session_id ~messages:fresh;
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
    let mkdir_p dir = C2c_mcp.mkdir_p ~mode:0o700 dir in
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
  (* B048: pi is not in known_clients (not a `c2c install` target — pi agents
     use the npm:pi-c2c extension). Append a synthetic display entry so pi
     still appears in the landing Clients section. *)
  let pi_on_path = C2c_setup.which_binary "pi" <> None in
  let clients = clients @ [ ("pi", pi_on_path, false) ] in
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
  (match C2c_health_cmd.check_pty_inject_capability () with
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
      if c = "pi" then
        if on_path then "on PATH — uses npm:pi-c2c (see pi.dev)"
        else "not on PATH — see pi.dev"
      else
        match on_path, configured with
        | false, _ -> "not on PATH"
        | true, true -> "configured (c2c MCP ready)"
        | true, false -> "on PATH, not configured — run 'c2c install' to set up"
    in
    Printf.printf "  %-10s %s\n" c status
  ) clients;
  let missing_clients =
    List.filter_map (fun (c, on_path, configured) ->
      if c <> "pi" && on_path && not configured then Some c else None) clients
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
    Printf.printf "  %-28s list rooms you're in\n" "c2c rooms list";
    Printf.printf "\n  If you just installed, restart your CLI client (or run /reload-plugins\n  in Claude Code) and resume — this activates push-based delivery.\n"
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

(* Fast-path dispatch (#418): handle a small set of subcommands BEFORE
   the heavy Cmdliner setup (~1.5s) that builds the manpage for ~50 cmds.
   These commands have no broker/registry dependency, so we short-circuit
   them with a direct argv scan + lean handler.

   Race fix (#418): get-tmux-location used to call `tmux display-message -p`
   without `-t "$TMUX_PANE"`, which returns the tmux *server's* active pane
   — racy under concurrent invocation across panes. Reading $TMUX_PANE
   directly (set per-pane by tmux at fork) is the canonical zero-cost
   pane-bound answer; we normalize via `tmux display-message -t "$TMUX_PANE"`
   only when callers want the human-readable session:window.pane form. *)
let fast_path_get_tmux_location ?(json = false) () =
  let pane_id = Sys.getenv_opt "TMUX_PANE" in
  let tmux_set = Sys.getenv_opt "TMUX" in
  match pane_id, tmux_set with
  | None, None ->
      (* Neither TMUX nor TMUX_PANE is set — definitely not in tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | Some _, None ->
      (* TMUX_PANE survived env -u TMUX (orphaned pane var from a dead session).
         TMUX is not set so tmux commands will fail. Treat as non-tmux. *)
      Printf.eprintf "error: not running inside a tmux session (TMUX is not set).\n%!";
      exit 1
  | _, Some _ ->
      (* TMUX is set — we are in a tmux session. Pin to our own pane. *)
      let cmd = match pane_id with
        | Some p when String.trim p <> "" ->
            (* shell-quote the pane id (tmux pane ids look like %42 — safe but be defensive) *)
            Printf.sprintf "tmux display-message -t %s -p '#S:#I.#P'"
              (Filename.quote p)
        | _ ->
            (* No $TMUX_PANE but $TMUX is set — last-resort active-pane fallback. *)
            "tmux display-message -p '#S:#I.#P'"
      in
      let capture cmd =
        try
          let ic = Unix.open_process_in cmd in
          Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
            (fun () -> Some (input_line ic))
        with _ -> None
      in
      (match capture cmd with
       | None ->
           Printf.eprintf "error: tmux display-message failed. Is tmux running?\n%!";
           exit 1
       | Some addr ->
           if json then Printf.printf "%s\n" (Printf.sprintf "%S" addr)
           else Printf.printf "%s\n" addr;
           exit 0)

(* --- fast-path helpers for IO-free subcommands --------------------------- *)

let fast_path_help () =
  (* c2c help [subcommand-path...] → execvp self [self, args..., --help] *)
  let self = if Array.length Sys.argv > 0 then Sys.argv.(0) else "c2c" in
  (* Collect positional args only (skip subcommand name itself at argv.(1)) *)
  let args =
    let n = Array.length Sys.argv in
    let rec go i acc =
      if i >= n then List.rev acc
      else go (i + 1) (Sys.argv.(i) :: acc)
    in
    go 2 []  (* skip argv[0]="c2c" and argv[1]="help" *)
  in
  let new_argv = Array.of_list (self :: args @ [ "--help" ]) in
  try Unix.execvp self new_argv
  with Unix.Unix_error (err, _, _) ->
    prerr_endline ("c2c help: " ^ Unix.error_message err);
    exit 125

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
    ("list", "List registered c2c peers");
    ("sessions", "List registered sessions (session_id, alias, client_type, liveness)");
    ("whoami", "Show current c2c identity");
    ("poll-inbox", "Drain (or peek at) your inbox");
    ("peek-inbox", "Peek at your inbox without draining");
    ("send", "Send a message to a registered peer alias or session ID");
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

let fast_path_server_info ~json () =
  let info = C2c_mcp.server_info () in
  if json then
    print_json info
  else
    match info with
    | `Assoc fields ->
        List.iter (fun (k, v) ->
          match v with
          | `String s -> Printf.printf "%s: %s\n" k s
          | `List l -> Printf.printf "%s:\n" k; List.iter (fun item -> Printf.printf "  - %s\n" (Yojson.Safe.to_string item)) l
          | _ -> Printf.printf "%s: %s\n" k (Yojson.Safe.to_string v))
          fields
    | _ -> print_json info

let fast_path_completion () =
  let n = Array.length Sys.argv in
  let help_requested =
    let rec loop i =
      i < n
      && (Sys.argv.(i) = "--help"
          || Sys.argv.(i) = "-h"
          || (String.length Sys.argv.(i) > 7
              && String.sub Sys.argv.(i) 0 7 = "--help=")
          || Sys.argv.(i) = "--version"
          || loop (i + 1))
    in
    loop 2
  in
  if help_requested then ()
  else begin
    let shell = ref None in
    for i = 2 to n - 1 do
      if Sys.argv.(i) = "--shell" && i + 1 < n then
        shell := Some (String.lowercase_ascii (String.trim Sys.argv.(i + 1)))
      else if String.length Sys.argv.(i) >= 7 && String.sub Sys.argv.(i) 0 7 = "--shell=" then
        shell := Some (String.lowercase_ascii (String.sub Sys.argv.(i) 7 (String.length Sys.argv.(i) - 7)))
    done;
    let shell = !shell in
    let shell = match shell with
      | Some s -> Some s
      | None ->
          (try
            let sh = Sys.getenv "SHELL" in
            if Filename.check_suffix sh "bash" then Some "bash"
            else if Filename.check_suffix sh "zsh" then Some "zsh"
            else if Filename.check_suffix sh "pwsh" || Filename.check_suffix sh "powershell" then Some "pwsh"
            else None
          with Not_found -> None)
    in
    match shell with
    | Some s when List.mem s ["bash"; "zsh"; "pwsh"] ->
        let cmdliner_bin () =
          try
            let opam_prefix = Sys.getenv "OPAM_SWITCH_PREFIX" in
            Filename.concat opam_prefix "bin" // "cmdliner"
          with Not_found ->
            let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
            Filename.concat home ".opam/c2c/bin/cmdliner"
        in
        let cmd = Printf.sprintf "%s tool-completion --standalone-completion %s c2c"
          (cmdliner_bin ()) s
        in
        let ic = Unix.open_process_in cmd in
        let rec copy_all () =
          try print_endline (input_line ic); copy_all ()
          with End_of_file -> ()
        in
        copy_all ();
        (match Unix.close_process_in ic with
         | Unix.WEXITED 0 -> exit 0
         | Unix.WEXITED n ->
             Printf.eprintf "error: cmdliner exited with code %d\n%!" n;
             exit 1
         | _ ->
             Printf.eprintf "error: cmdliner terminated unexpectedly\n%!";
             exit 1)
    | Some s ->
        Printf.eprintf "error: unknown shell '%s'. Supported: bash, zsh, pwsh\n%!" s;
        exit 1
    | None ->
        Printf.eprintf "error: could not detect shell. Please specify --shell explicitly\n%!";
        exit 1
  end

let fast_path_skills_list ~json () =
  let dir = Sys.getcwd () // ".opencode" // "skills" in
  let names =
    try
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun name ->
        let path = dir // name in
        try Sys.is_directory path with _ -> false)
    with _ -> []
  in
  if json then
    let skills = List.map (fun name ->
      let skill_md = dir // name // "SKILL.md" in
      let lines =
        (try
          let ic = open_in skill_md in
          Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
            let rec go acc n =
              if n <= 0 then List.rev acc
              else
                match input_line ic with
                | line -> go (line :: acc) (n - 1)
                | exception End_of_file -> List.rev acc
            in
            go [] 10)
        with _ -> [])
      in
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
      `Assoc ([ ("id", `String name) ]
        @ (match !name_ref with Some n -> [ ("name", `String n) ] | None -> [])
        @ (match !desc_ref with Some d -> [ ("description", `String d) ] | None -> []))
    ) names in
    print_json (`List skills)
  else
    List.iter (fun name ->
      let skill_md = dir // name // "SKILL.md" in
      let lines =
        (try
          let ic = open_in skill_md in
          Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
            let rec go acc n =
              if n <= 0 then List.rev acc
              else
                match input_line ic with
                | line -> go (line :: acc) (n - 1)
                | exception End_of_file -> List.rev acc
            in
            go [] 10)
        with _ -> [])
      in
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
      Printf.printf "%s\n" name;
      (match !name_ref with Some n -> Printf.printf "  name: %s\n" n | None -> ());
      (match !desc_ref with Some d -> Printf.printf "  description: %s\n" d | None -> ());
      print_newline ()
    ) names

let fast_path_skills_serve name =
  let dir = Sys.getcwd () // ".opencode" // "skills" in
  let skill_md = dir // name // "SKILL.md" in
  try
    let ic = open_in skill_md in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec copy_all () =
        try
          print_endline (input_line ic);
          copy_all ()
        with End_of_file -> ()
      in
      copy_all ())
  with _ ->
    Printf.eprintf "error: skill '%s' not found in %s\n%!" name dir;
    exit 1

let try_fast_path () =
  (* Skip fast-path if any flag we don't recognize appears, so cmdliner
     can produce its standard error. We only handle the trivial shape:
       c2c help [args...]
       c2c commands [--all]
       c2c server-info [--json]
       c2c completion [--shell SHELL]
       c2c skills list [--json]
       c2c skills serve <name>
       c2c get-tmux-location [--json]
      and bare `c2c --version`. *)

  let argv = Sys.argv in
  let n = Array.length argv in
  if n >= 2 then begin
    match argv.(1) with
    | "help" ->
        (* Accept only positional args (no flags we don't handle).
           `c2c help` alone → top-level help. `c2c help rooms` → `c2c rooms --help`. *)
        fast_path_help ()
    | "commands" ->
        fast_path_commands ()
    | "server-info" ->
        let json = ref false in
        let unknown = ref false in
        for i = 2 to n - 1 do
          match argv.(i) with
          | "--json" | "-j" -> json := true
          | _ -> unknown := true
        done;
        if not !unknown then fast_path_server_info ~json:!json ()
    | "completion" ->
        fast_path_completion ()
    | "skills" when n >= 3 ->
        (match argv.(2) with
         | "list" ->
             let json = ref false in
             let unknown = ref false in
             for i = 3 to n - 1 do
               match argv.(i) with
               | "--json" | "-j" -> json := true
               | _ -> unknown := true
             done;
             if not !unknown then fast_path_skills_list ~json:!json ()
         | "serve" when n >= 4 ->
             fast_path_skills_serve argv.(3)
         | _ -> ())
    | "get-tmux-location" ->
        let json = ref false in
        let unknown = ref false in
        for i = 2 to n - 1 do
          match argv.(i) with
          | "--json" -> json := true
          | _ -> unknown := true
        done;
        if not !unknown then fast_path_get_tmux_location ~json:!json ()
    | "--version" when n = 2 ->
        Printf.printf "%s\n" (version_string ());
        exit 0
    | _ -> ()
  end

let dev_group =
  let info = Cmdliner.Cmd.info "dev"
    ~doc:"Developer/operator commands for c2c swarm internals."
  in
  (* Tier-aware subcommand filtering: Tier 2 subcommands (instances, worktree,
     sitrep, peer-pass, status) are always visible. Tier 3/4 subcommands (diag,
     restart-self, smoke-test, inject) are hidden in agent sessions. *)
  let tier2_subs =
    [ C2c_instances_cmd.dev_instances_sub
    ; C2c_worktree.worktree_group; C2c_sitrep.sitrep_group
    ; C2c_peer_pass.peer_pass_group ]
  in
  let tier3_subs = [ C2c_instances_cmd.diag; C2c_managed_cmd.restart_self; smoke_test; C2c_inject_cmd.inject ] in
  let visible_subs =
    if is_agent_session () then tier2_subs
    else tier2_subs @ tier3_subs
  in
  Cmdliner.Cmd.group info ~default:C2c_instances_cmd.dev_instances_cmd visible_subs

(* Deprecated top-level aliases — warn on stderr BEFORE execution.
   We prepend a side-effecting term via `and+` that fires during argument
   evaluation (before the command body), using Cmdliner.Term.const with
   a thunk forced by map. *)
let deprecation_wrap ~old_name ~new_path (cmd_term : unit Cmdliner.Term.t) : unit Cmdliner.Term.t =
  let open Cmdliner.Term in
  let warn_term =
    const () |> map (fun () ->
      Printf.eprintf "[DEPRECATED] c2c %s is now c2c %s. Updating in 2 releases.\n%!" old_name new_path)
  in
  let+ () = warn_term and+ () = cmd_term in
  ()

let diag_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "diag" ~doc:"[DEPRECATED: use c2c dev diag]")
    (deprecation_wrap ~old_name:"diag" ~new_path:"dev diag" C2c_instances_cmd.diag_cmd)

let restart_self_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "restart-self" ~doc:"[DEPRECATED: use c2c dev restart-self]")
    (deprecation_wrap ~old_name:"restart-self" ~new_path:"dev restart-self" C2c_managed_cmd.restart_self_cmd)

let smoke_test_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "smoke-test" ~doc:"[DEPRECATED: use c2c dev smoke-test]")
    (deprecation_wrap ~old_name:"smoke-test" ~new_path:"dev smoke-test" smoke_test_cmd)

let inject_deprecated =
  Cmdliner.Cmd.v (Cmdliner.Cmd.info "inject" ~doc:"[DEPRECATED: use c2c dev inject]")
    (deprecation_wrap ~old_name:"inject" ~new_path:"dev inject" C2c_inject_cmd.inject_cmd)

let () =
  try_fast_path ();
  sanitize_help_env ();
  for i = 0 to Array.length Sys.argv - 1 do
    if Sys.argv.(i) = "-h" then Sys.argv.(i) <- "--help"
  done;
  let is_agent = is_agent_session () in
  let tier_grouped_man = commands_man is_agent in
  let all_cmds =
    [ send; list; sessions; whoami; set_compact; clear_compact; open_pending_reply; check_pending_reply; poll_inbox; peek_inbox; C2c_approval_cmd.await_reply; C2c_approval_cmd.approval_reply; C2c_approval_cmd.authorize; C2c_approval_cmd.approval_pending_write; C2c_approval_cmd.approval_list; C2c_approval_cmd.approval_show; C2c_approval_cmd.approval_gc; C2c_approval_cmd.resolve_authorizer; send_all; sweep; registry_prune
    ; sweep_dryrun; migrate_broker; history; C2c_health_cmd.health; C2c_health_cmd.connect; setcap; C2c_health_cmd.status; C2c_health_cmd.verify; C2c_health_cmd.host_id; git; register; deregister; refresh_peer; C2c_coord.coord_cherry_pick_cmd; C2c_coord.coord_group
    ; tail_log; server_info; my_rooms; dead_letter; prune_rooms; get_tmux_location; smoke_test_deprecated; C2c_init_cmd.init; C2c_init_cmd.install; C2c_init_cmd.self_update; C2c_init_cmd.update_alias; C2c_init_cmd.upgrade_alias; C2c_uninstall.uninstall_subcmd; C2c_init_cmd.completion_cmd; list_glyphs
    ; serve; mcp; C2c_managed_cmd.start; C2c_agent.agent_group; config_group; C2c_agent.roles_group; gui; C2c_managed_cmd.stop; C2c_managed_cmd.restart; C2c_managed_cmd.reset_thread; restart_self_deprecated; C2c_instances_cmd.instances_deprecated; diag_deprecated; dev_group; C2c_doctor_cmd.doctor; stats; C2c_rooms.rooms_group; C2c_rooms.room_group    ; C2c_relay_cmd.relay_group; relay_pins; mesh_group; skills_group; C2c_stickers.sticker_group; C2c_memory.memory_group; C2c_schedule.schedule_group; C2c_monitor_cmd.monitor; hook; inject_deprecated; repo_group; C2c_inject_cmd.screen; statefile_top; debug_group; oc_plugin_group; cc_plugin_group; supervisor_group; C2c_deliver_watch.deliver_group; commands_by_safety; C2c_agent_help.agent_help; C2c_watch.watch_cmd; help ]
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
                ; `Noblank; `P "125 — bug in c2c — please report at https://github.com/clankercode/c2c/issues"
                ] @ tier_grouped_man))
             visible_cmds))
