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

(* List/sessions command island moved to c2c_list_cmd.ml. *)

(* Whoami command island moved to c2c_whoami_cmd.ml. *)

(* Inbox/compact/pending command island moved to c2c_inbox_cmd.ml. *)

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

(* Health, connect, verify, host-id subcommands extracted to c2c_health_cmd.ml *)

(* Register/deregister command island moved to c2c_register_cmd.ml. *)

(* Monitor subcommand extracted to c2c_monitor_cmd.ml *)


(* Relay subcommands extracted to c2c_relay_cmd.ml *)
(* Mesh subcommands extracted to c2c_mesh_cmd.ml *)

(* --- main entry point ----------------------------------------------------- *)

let send = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send" ~doc:"Send a message to a registered peer alias or session ID.") send_cmd
(* List/sessions commands extracted to c2c_list_cmd.ml. *)
(* Whoami command extracted to c2c_whoami_cmd.ml. *)
(* Inbox/compact/pending commands extracted to c2c_inbox_cmd.ml. *)

(* Approval subcommands extracted to c2c_approval_cmd.ml *)

let send_all = Cmdliner.Cmd.v (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.") send_all_cmd
(* Register/deregister commands extracted to c2c_register_cmd.ml. *)

(* Phase 1 split: install/setup code moved to c2c_setup.ml *)

(* Init/setup command island moved to c2c_init_cmd.ml. *)

(* MCP stdio command island moved to c2c_serve_cmd.ml. *)

(* Managed-instance commands moved to c2c_instances_cmd.ml. *)

(* --- doctor command group moved to c2c_doctor_cmd.ml --------------------- *)

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
        C2c_commands_cmd.fast_path_commands ()
    | "server-info" ->
        let json = ref false in
        let unknown = ref false in
        for i = 2 to n - 1 do
          match argv.(i) with
          | "--json" | "-j" -> json := true
          | _ -> unknown := true
        done;
        if not !unknown then begin
          fast_path_server_info ~json:!json ();
          exit 0
        end
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
             if not !unknown then C2c_skills_cmd.fast_path_skills_list ~json:!json ()
         | "serve" when n >= 4 ->
             C2c_skills_cmd.fast_path_skills_serve argv.(3)
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
  let tier3_subs = [ C2c_instances_cmd.diag; C2c_managed_cmd.restart_self; C2c_host_cmd.smoke_test; C2c_inject_cmd.inject ] in
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
    (deprecation_wrap ~old_name:"smoke-test" ~new_path:"dev smoke-test" C2c_host_cmd.smoke_test_cmd)

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
  let tier_grouped_man = C2c_commands_cmd.commands_man is_agent in
  let all_cmds =
    [ send; C2c_list_cmd.list; C2c_list_cmd.sessions; C2c_whoami_cmd.whoami; C2c_inbox_cmd.set_compact; C2c_inbox_cmd.clear_compact; C2c_inbox_cmd.open_pending_reply; C2c_inbox_cmd.check_pending_reply; C2c_inbox_cmd.poll_inbox; C2c_inbox_cmd.peek_inbox; C2c_approval_cmd.await_reply; C2c_approval_cmd.approval_reply; C2c_approval_cmd.authorize; C2c_approval_cmd.approval_pending_write; C2c_approval_cmd.approval_list; C2c_approval_cmd.approval_show; C2c_approval_cmd.approval_gc; C2c_approval_cmd.resolve_authorizer; send_all; C2c_sweep_cmd.sweep; C2c_sweep_cmd.registry_prune
    ; C2c_sweep_cmd.sweep_dryrun; C2c_migrate_cmd.migrate_broker; C2c_history_cmd.history; C2c_health_cmd.health; C2c_health_cmd.connect; C2c_host_cmd.setcap; C2c_health_cmd.status; C2c_health_cmd.verify; C2c_health_cmd.host_id; C2c_git_cmd.git; C2c_register_cmd.register; C2c_register_cmd.deregister; C2c_refresh_peer_cmd.refresh_peer; C2c_coord.coord_cherry_pick_cmd; C2c_coord.coord_group
    ; C2c_broker_cmd.tail_log; C2c_broker_cmd.server_info; C2c_broker_cmd.my_rooms; C2c_broker_cmd.dead_letter; C2c_broker_cmd.prune_rooms; C2c_broker_cmd.get_tmux_location; smoke_test_deprecated; C2c_init_cmd.init; C2c_init_cmd.install; C2c_init_cmd.self_update; C2c_init_cmd.update_alias; C2c_init_cmd.upgrade_alias; C2c_uninstall.uninstall_subcmd; C2c_init_cmd.completion_cmd; C2c_glyphs_cmd.list_glyphs
    ; C2c_serve_cmd.serve; C2c_serve_cmd.mcp; C2c_managed_cmd.start; C2c_agent.agent_group; C2c_config_cmd.config_group; C2c_agent.roles_group; C2c_gui_cmd.gui; C2c_managed_cmd.stop; C2c_managed_cmd.restart; C2c_managed_cmd.reset_thread; restart_self_deprecated; C2c_instances_cmd.instances_deprecated; diag_deprecated; dev_group; C2c_doctor_cmd.doctor; C2c_stats_cmd.stats; C2c_rooms.rooms_group; C2c_rooms.room_group    ; C2c_relay_cmd.relay_group; C2c_relay_pins_cmd.relay_pins; C2c_mesh_cmd.mesh_group; C2c_skills_cmd.skills_group; C2c_stickers.sticker_group; C2c_memory.memory_group; C2c_schedule.schedule_group; C2c_monitor_cmd.monitor; C2c_hook_cmd.hook; inject_deprecated; C2c_config_cmd.repo_group; C2c_inject_cmd.screen; C2c_statefile_cmd.statefile_top; C2c_statefile_cmd.debug_group; C2c_statefile_cmd.oc_plugin_group; C2c_statefile_cmd.cc_plugin_group; C2c_supervisor_cmd.supervisor_group; C2c_deliver_watch.deliver_group; C2c_commands_cmd.commands_by_safety; C2c_agent_help.agent_help; C2c_watch.watch_cmd; help ]
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
