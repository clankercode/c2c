(* c2c_inbox_cmd - inbox, compaction, and pending-reply commands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_cli_helpers
open C2c_types
open Cmdliner.Term.Syntax

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

(* J2: --json rows are the canonical schema-v1 shape with the legacy row
   keys (from_alias / to_alias / content / ts) preserved additively at
   unchanged values. Drained rows carry delivery.state "delivered";
   peeked (non-drained) rows carry "queued". Human output unchanged. *)
let print_messages ~json ~delivery_state messages =
  let output_mode = if json then Json else Human in
  match output_mode with
  | Json ->
      print_json
        (`List
          (List.map (C2c_utils.inbox_message_row_json ~delivery_state) messages))
  | Human ->
      if messages = [] then
        Printf.printf "(no messages)\n"
      else
        List.iter
          (fun (m : C2c_mcp.message) -> Printf.printf "[%s] %s\n" m.from_alias m.content)
          messages

(* --- poll-inbox / wait-inbox ------------------------------------------------
   Shared flags + implementation.  `poll-inbox` keeps its historical one-shot
   drain/peek semantics; `poll-inbox --wait` (and the `wait-inbox` alias
   command, which forces wait on) turns it into a blocking one-shot receive:
   poll the inbox until >=1 message arrives (or --timeout elapses), then
   drain (or peek) once, print, and exit.  Built for clients with no
   Monitor/push delivery surface — e.g. vanilla Codex sessions — where a
   shell-friendly blocking receive is the only practical wake path.

   Exit codes in wait mode (aligned with `c2c await-reply`):
     0 = message(s) received, 1 = timeout with no messages, 2 = error. *)

let inbox_peek_flag ~verb =
  Cmdliner.Arg.(value & flag & info [ "peek"; "p" ]
    ~doc:(Printf.sprintf "Peek without draining%s." verb))

let inbox_session_id_flag ~verb =
  Cmdliner.Arg.(value & opt (some string) None & info [ "session-id"; "s" ] ~docv:"ID"
    ~doc:(Printf.sprintf "Session ID whose inbox to %s. Overrides C2C_MCP_SESSION_ID." verb))

let inbox_alias_flag ~verb =
  Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS"
    ~doc:(Printf.sprintf "Alias whose inbox to %s. Useful for unmanaged CLI peers; mutually exclusive with --session-id." verb))

let inbox_timeout_flag =
  Cmdliner.Arg.(value & opt (some string) None & info [ "timeout" ] ~docv:"DURATION"
    ~doc:"Maximum time to wait for a message, e.g. $(b,30s), $(b,2m), $(b,1h); a bare number means seconds. Default $(b,120s). Only meaningful in wait mode.")

let inbox_poll_interval_flag =
  Cmdliner.Arg.(value & opt (some float) None & info [ "poll-interval" ] ~docv:"SECONDS"
    ~doc:"Polling cadence in seconds while waiting (default 1.0). Only meaningful in wait mode.")

let inbox_from_flag =
  Cmdliner.Arg.(value & opt (some string) None & info [ "from" ] ~docv:"ALIAS"
    ~doc:"Only wait for (and drain) messages whose sender alias matches, case-insensitively. Non-matching messages neither unblock the wait nor get drained — they stay in the inbox. Only meaningful in wait mode.")

let default_wait_timeout = "120s"

(* B130 note: there is deliberately NO subagent guard on the bare CLI inbox
   commands. A dispatched Claude Code subagent and a top-level session are
   INDISTINGUISHABLE from a plain `c2c` process's point of view — both inherit
   the same C2C_MCP_SESSION_ID and the same CLAUDE_CODE_CHILD_SESSION=1 (set on
   every tool subprocess of every session), and the CLI has no hook-stdin
   `agent_id` to consult. Any env-based guard here regresses the group-goal
   "CLI: always-available fallback usable by any agent" by refusing top-level
   sessions. The subagent leak is gated where it is actually detectable: the
   hook injection path, via hook-stdin agent_id (C2c_hook_lib.stdin_is_subagent_turn). *)
let run_poll_inbox ~cmd_name ~wait ~json ~peek ~session_id_opt ~alias_opt
    ~cross_repo ~timeout_opt ~poll_interval_opt ~from_opt =
  mcp_nudge_if_needed ~cmd:cmd_name;
  (* Arg errors: exit 2 in wait mode (1 there means "timeout"); keep the
     historical exit 1 for plain poll-inbox so existing callers don't break. *)
  let arg_error_exit = if wait then 2 else 1 in
  (match session_id_opt, alias_opt with
   | Some _, Some _ ->
       Printf.eprintf "error: --session-id and --alias are mutually exclusive.\n%!";
       exit arg_error_exit
   | _ -> ());
  if not wait then
    (match timeout_opt, poll_interval_opt, from_opt with
     | None, None, None -> ()
     | _ ->
         Printf.eprintf
           "error: --timeout, --poll-interval, and --from require --wait \
            (or use `c2c wait-inbox`).\n%!";
         exit 2);
  let timeout_raw = Option.value timeout_opt ~default:default_wait_timeout in
  let timeout =
    if not wait then 0.0
    else
      match C2c_start.parse_heartbeat_duration_s timeout_raw with
      | Ok v -> v
      | Error e ->
          Printf.eprintf "error: invalid --timeout %S: %s\n%!" timeout_raw e;
          exit 2
  in
  let poll_interval = Option.value poll_interval_opt ~default:1.0 in
  if wait && poll_interval <= 0.0 then begin
    Printf.eprintf "error: --poll-interval must be positive.\n%!";
    exit 2
  end;
  let from_match (m : C2c_mcp.message) =
    match from_opt with
    | None -> true
    | Some a -> String.lowercase_ascii m.from_alias = String.lowercase_ascii a
  in
  (try
    let broker = C2c_mcp.Broker.create ~root:(resolve_effective_broker_root ~cross_repo ()) in
    let session_id = match session_id_opt with
      | Some sid -> sid
      | None -> resolve_session_id_for_inbox ?alias:alias_opt broker
    in
    (* J2: peeked rows are still queued in the inbox; drained rows were
       actually delivered to this caller. *)
    let delivery_state =
      if peek then C2c_schema_v1.Queued else C2c_schema_v1.Delivered
    in
    if not wait then
      let messages =
        if peek then
          C2c_mcp.Broker.read_inbox broker ~session_id
        else
          C2c_mcp.Broker.drain_inbox ~drained_by:"cli_poll" broker ~session_id
      in
      print_messages ~json ~delivery_state messages
    else begin
      (* One fetch attempt: returns the messages this call may deliver.
         Draining directly inside the loop (rather than read-then-drain)
         avoids the race where a concurrent drain steals the message
         between our read and our drain — an empty drain just loops. *)
      let fetch () =
        if peek then
          List.filter from_match (C2c_mcp.Broker.read_inbox broker ~session_id)
        else
          match from_opt with
          | None -> C2c_mcp.Broker.drain_inbox ~drained_by:"cli_wait" broker ~session_id
          | Some _ ->
              C2c_mcp.Broker.drain_inbox_matching ~drained_by:"cli_wait"
                broker ~session_id ~pred:from_match
      in
      let deadline = Unix.gettimeofday () +. timeout in
      let rec loop () =
        match fetch () with
        | (_ :: _) as messages ->
            print_messages ~json ~delivery_state messages;
            exit 0
        | [] ->
            let now = Unix.gettimeofday () in
            if now >= deadline then begin
              (* stdout stays clean on timeout: `[]` in JSON mode, nothing in
                 human mode; the diagnostic goes to stderr. *)
              if json then print_json (`List []);
              Printf.eprintf "(timeout: no messages after %s)\n%!" timeout_raw;
              exit 1
            end
            else begin
              let remaining = deadline -. now in
              let nap = if poll_interval < remaining then poll_interval else remaining in
              (try Unix.sleepf nap with _ -> ());
              loop ()
            end
      in
      loop ()
    end
  with
  | Unix.Unix_error (code, _fn, path) when code = Unix.EROFS || code = Unix.EACCES ->
      let msg = Printf.sprintf
        "broker root is not writable in this sandbox (path: %s, error: %s). \
         Set C2C_MCP_BROKER_ROOT to a writable path or run from a managed session."
        path (Unix.error_message code)
      in
      if json then
        print_json (`Assoc [ ("error", `String msg); ("code", `String (match code with Unix.EROFS -> "EROFS" | Unix.EACCES -> "EACCES" | _ -> "unknown")) ])
      else
        Printf.eprintf "error: %s\n%!" msg;
      (* In wait mode, exit 1 is reserved for timeout — broker errors are 2. *)
      exit arg_error_exit
  )

let poll_inbox_cmd =
  let wait_flag =
    Cmdliner.Arg.(value & flag & info [ "wait"; "w" ]
      ~doc:"Block until at least one message arrives (or --timeout elapses), then drain (or peek with --peek) once and exit. Exit codes: 0 = received, 1 = timeout, 2 = error.")
  in
  let+ json = json_flag
  and+ peek = inbox_peek_flag ~verb:""
  and+ session_id_opt = inbox_session_id_flag ~verb:"drain"
  and+ alias_opt = inbox_alias_flag ~verb:"drain"
  and+ cross_repo = cross_repo_flag
  and+ wait = wait_flag
  and+ timeout_opt = inbox_timeout_flag
  and+ poll_interval_opt = inbox_poll_interval_flag
  and+ from_opt = inbox_from_flag in
  run_poll_inbox ~cmd_name:"poll-inbox" ~wait ~json ~peek ~session_id_opt
    ~alias_opt ~cross_repo ~timeout_opt ~poll_interval_opt ~from_opt

let wait_inbox_cmd =
  let+ json = json_flag
  and+ peek = inbox_peek_flag ~verb:" once a message arrives"
  and+ session_id_opt = inbox_session_id_flag ~verb:"watch"
  and+ alias_opt = inbox_alias_flag ~verb:"watch"
  and+ cross_repo = cross_repo_flag
  and+ timeout_opt = inbox_timeout_flag
  and+ poll_interval_opt = inbox_poll_interval_flag
  and+ from_opt = inbox_from_flag in
  run_poll_inbox ~cmd_name:"wait-inbox" ~wait:true ~json ~peek ~session_id_opt
    ~alias_opt ~cross_repo ~timeout_opt ~poll_interval_opt ~from_opt

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
  (* J2: peek never drains — rows remain queued. *)
  print_messages ~json ~delivery_state:C2c_schema_v1.Queued messages

let set_compact : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "set-compact" ~doc:"Mark this session as compacting (context summarization in progress).")
    set_compact_cmd

let clear_compact : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "clear-compact" ~doc:"Clear the compacting flag for this session.")
    clear_compact_cmd

let open_pending_reply : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "open-pending-reply" ~doc:"Open a pending permission reply slot before sending a permission request to supervisors.")
    open_pending_reply_cmd

let check_pending_reply : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "check-pending-reply" ~doc:"Check if a permission reply is valid (called when receiving a reply).")
    check_pending_reply_cmd

let poll_inbox : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "poll-inbox"
       ~doc:"Drain (or peek at) your inbox. With --wait, block until a message arrives (or --timeout elapses) before draining — see also `c2c wait-inbox`.")
    poll_inbox_cmd

let wait_inbox : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "wait-inbox"
       ~doc:"Blocking one-shot receive: wait until at least one message arrives (or --timeout elapses, default 120s), then drain it once, print, and exit. Equivalent to `poll-inbox --wait`. Use wait-inbox when your client has no Monitor/push delivery (e.g. a vanilla Codex session): run it in a shell loop as an always-available receive path. Exit codes: 0 = received, 1 = timeout, 2 = error.")
    wait_inbox_cmd

let peek_inbox : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "peek-inbox" ~doc:"Peek at your inbox without draining.")
    peek_inbox_cmd

(** B183: discoverable synonym for agents that try `c2c inbox`. Non-draining
    peek (same as peek-inbox) so a casual `inbox` check never silently drops
    messages; use poll-inbox / wait-inbox to drain. *)
let inbox : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "inbox"
       ~doc:"Alias for $(b,peek-inbox) — peek without draining. Use \
             $(b,poll-inbox) / $(b,wait-inbox) to drain.")
    peek_inbox_cmd
