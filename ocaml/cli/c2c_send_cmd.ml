open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_mcp
open C2c_types
open C2c_utils

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

let env_truthy name =
  match Sys.getenv_opt name with
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      v <> "" && not (List.mem v [ "0"; "false"; "no" ])
  | None -> false

let has_nonempty_env name =
  match Sys.getenv_opt name with
  | Some v -> String.trim v <> ""
  | None -> false

let infer_send_auto_register_client ~session_id =
  match env_client_type () with
  | Some client -> client
  | None ->
      let sid = String.lowercase_ascii session_id in
      if has_nonempty_env "CODEX_THREAD_ID"
         || String.starts_with ~prefix:"codex" sid
      then "codex"
      else if has_nonempty_env "CLAUDE_CODE_SESSION_ID"
              || has_nonempty_env "CLAUDE_SESSION_ID"
              || String.starts_with ~prefix:"claude" sid
      then "claude"
      else if has_nonempty_env "C2C_OPENCODE_SESSION_ID"
              || String.starts_with ~prefix:"opencode" sid
      then "opencode"
      else if has_nonempty_env "KIMI_SESSION_ID"
              || String.starts_with ~prefix:"kimi" sid
      then "kimi"
      else "agent"

let maybe_auto_register_sender broker ~from_override =
  match from_override with
  | Some a when String.trim a <> "" -> ()
  | _ ->
      match env_session_id () with
      | None -> ()
      | Some session_id ->
          let already_registered =
            C2c_mcp.Broker.list_registrations broker
            |> List.exists
                 (fun (r : C2c_mcp.registration) -> r.session_id = session_id)
          in
          if not already_registered then
            try
              if env_truthy "C2C_SEND_AUTOREGISTER_FAIL_FIXTURE" then
                failwith "fixture: send auto-registration failure";
              let client = infer_send_auto_register_client ~session_id in
              let alias = C2c_setup.default_alias_for_client client in
              let pid = resolve_registration_pid ~session_id () in
              let pid_start_time =
                C2c_mcp.Broker.capture_pid_start_time pid
              in
              C2c_mcp.Broker.register broker ~session_id ~alias ~pid
                ~pid_start_time ~client_type:(Some client)
                ~from_auto_gen:true ();
              Printf.eprintf
                "auto-registered as %s (replies will reach you: c2c wait-inbox)\n%!"
                alias
            with _ ->
              ()

(** B088: honest delivery reporting for remote [alias@host] targets.

    [c2c send alias@host] only ever appends to the local relay outbox — the
    relay connector (a separate async process) ships it later. Printing a
    blanket [ok ->] for that read as success when nothing was delivered,
    so agents truthfully-but-wrongly reported "sent" and moved on. These
    helpers classify the delivery state and produce an honest warning so the
    text never implies delivery for a remote-only-queued message. Local
    same-broker targets still deliver synchronously and legitimately report
    [ok]/[delivered]. *)
let relay_connector_running_best_effort () =
  (* Best-effort liveness probe. Detects a managed [relay-connect] daemon via
     its instance dir + [outer.pid] ([Unix.kill pid 0]). A foreground
     [c2c relay connect] run directly in a terminal/tmux is NOT detected —
     in that case the warning falls back to the generic "no relay connector
     detected" guidance, which is still accurate (we have no evidence one is
     running). Fails closed to [false] on any read error so sends never break. *)
  try
    C2c_health_cmd.read_managed_instances ()
    |> List.exists (fun (i : managed_instance_view) ->
         i.mi_client = "relay-connect" && i.mi_status = "running")
  with _ -> false

let remote_queued_warning () =
  if relay_connector_running_best_effort () then
    "queued locally for the relay outbox; a managed relay-connect daemon is \
     running, but delivery is async and not confirmed here. Use \
     `c2c relay dm send` for a synchronous relay send."
  else
    "queued locally; no relay connector detected — run `c2c relay connect` \
     (or `c2c managed start relay-connect`) or use `c2c relay dm send` to \
     ship it."

let offline_queued_warning to_alias =
  Printf.sprintf
    "recipient '%s' is offline; message queued to durable inbox \
     (will deliver on next start/resume)"
    to_alias

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
  (* B088: opt-in strict mode. A remote [alias@host] target is only queued
     locally by [c2c send] (delivery is async via the relay connector). By
     default this still exits 0 (fire-and-forget back-compat) but prints
     [queued] + a warning. [—-fail-if-queued] flips the exit to 3 so a script
     can detect non-delivery. Local same-broker targets deliver synchronously
     and exit 0 regardless. *)
  let fail_if_queued =
    Cmdliner.Arg.(value & flag & info ["fail-if-queued"]
      ~doc:"Exit non-zero (3) when the message is only queued and not confirmed delivered to a live recipient (a remote alias@host target, or an offline local alias whose mail was durably queued). Opt-in; lets scripts detect non-delivery. Live same-broker targets deliver synchronously and still exit 0.")
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
  and+ broker_root_opt = broker_root_opt
  and+ fail_if_queued = fail_if_queued in
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
  maybe_auto_register_sender broker ~from_override;
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
     (* B127: track enqueue classification so offline durable queue reports
        [queued_offline] instead of falsely claiming live delivery. *)
     let enqueue_status : C2c_mcp.Broker.enqueue_result option ref = ref None in
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
              let result =
                C2c_mcp.Broker.enqueue_message_with_result broker ~from_alias
                  ~to_alias ~content ~ephemeral ()
              in
              enqueue_status := Some result;
              if debug_enabled then Printf.eprintf "[DEBUG send_cmd] enqueue_message returned\n%!";
              flush stderr
            with Invalid_argument msg
              when not (String.contains to_alias '@') ->
              (* B072/B127: unknown local alias still errors. Offline known
                 aliases no longer raise (they queue); reserved/spoof rejects
                 and genuine unknown rejections still land here. *)
              let unknown_alias =
                String.starts_with ~prefix:"enqueue_message rejected" msg
              in
              if not unknown_alias then begin
                (* Unrelated rejection (e.g. reserved from_alias spoof guard) —
                   report as-is rather than misdiagnosing it as routing. *)
                Printf.eprintf "error: %s\n%!" msg;
                exit 1
              end;
              (* Primary broker can't route this alias — scan other brokers.
                 Prefer a live registration elsewhere; fall back to offline
                 queue on any matching registration (B127). *)
              let all_matches = find_alias_in_all_brokers ~primary_root to_alias in
              let live_matches =
                List.filter
                  (fun (_root, r) -> C2c_mcp.Broker.registration_is_alive r)
                  all_matches
              in
              match live_matches with
              | (alt_root, _reg) :: _ ->
                  if debug_enabled then Printf.eprintf
                    "[DEBUG send_cmd] cross-broker routing: %s found in %s\n%!" to_alias alt_root;
                  let alt_broker = C2c_mcp.Broker.create ~root:alt_root in
                  let result =
                    C2c_mcp.Broker.enqueue_message_with_result alt_broker
                      ~from_alias ~to_alias ~content ~ephemeral ()
                  in
                  enqueue_status := Some result;
                  if debug_enabled then Printf.eprintf "[DEBUG send_cmd] cross-broker enqueue_message returned\n%!"
              | [] ->
                  (match all_matches with
                   | (alt_root, _reg) :: _ ->
                       (* Dead-but-known on another broker — durable offline queue. *)
                       if debug_enabled then Printf.eprintf
                         "[DEBUG send_cmd] cross-broker offline queue: %s in %s\n%!"
                         to_alias alt_root;
                       let alt_broker = C2c_mcp.Broker.create ~root:alt_root in
                       let result =
                         C2c_mcp.Broker.enqueue_message_with_result alt_broker
                           ~from_alias ~to_alias ~content ~ephemeral ()
                       in
                       enqueue_status := Some result
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
                       exit 1));
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
           enqueue_status := Some (C2c_mcp.Broker.Local_live { session_id });
           ( None
           , [ ("target_session_id", `String session_id) ]
           , "session " ^ session_id )
     in
     (* B088/B127: classify delivery.
        - remote alias@host → [queued] (relay outbox only)
        - known offline local peer → [queued_offline] (durable inbox)
        - live local / session → [delivered] *)
     let delivery_state_v1, delivery_warning_opt =
       match !enqueue_status with
       | Some (C2c_mcp.Broker.Relay_outbox) ->
           (C2c_schema_v1.Queued, Some (remote_queued_warning ()))
       | Some (C2c_mcp.Broker.Local_offline { session_id = _ }) ->
           let a =
             match target with `Alias a -> a | `Session sid -> sid
           in
           (C2c_schema_v1.Queued_offline, Some (offline_queued_warning a))
       | Some (C2c_mcp.Broker.Local_live _) | None ->
           (match target with
            | `Alias a when C2c_mcp.Broker.is_remote_alias a ->
                (C2c_schema_v1.Queued, Some (remote_queued_warning ()))
            | `Alias _ | `Session _ ->
                (C2c_schema_v1.Delivered, None))
     in
     let delivery_state =
       C2c_schema_v1.string_of_delivery_state delivery_state_v1
     in
     begin match output_mode with
     | Json ->
         (* B088/B127: delivery.state lets machine consumers tell remote-only
            [queued], offline durable [queued_offline], and synchronous local
            [delivered] apart. J2: the receipt is the canonical schema-v1
            shape; legacy keys are retained for back-compat. B127 also emits
            top-level [queued_offline:true] when applicable. *)
         let to_v1 =
           match target with `Alias a -> a | `Session sid -> sid
         in
         let legacy_target_fields =
           match delivery_state_v1 with
           | C2c_schema_v1.Queued_offline ->
               json_target_fields @ [ ("queued_offline", `Bool true) ]
           | _ -> json_target_fields
         in
         print_json
           (C2c_utils.cli_send_receipt_json ~ts ~from_alias ~to_:to_v1
              ~content ~delivery_state:delivery_state_v1
              ?delivery_warning:delivery_warning_opt
              ~legacy_target_fields
              ?compacting_warning ())
     | Human ->
         (match delivery_state with
          | "queued_offline" ->
              (* B127: known offline peer — durable local inbox write. *)
              Printf.printf "queued_offline -> %s (from %s)" human_target from_alias
          | "queued" ->
              (* B088: never print bare [ok ->] for a remote-only-queued
                 message — it implied delivery. [queued ->] is the honest
                 signal; the explanatory warning follows on stderr. *)
              Printf.printf "queued -> %s (from %s)" human_target from_alias
          | _ ->
              Printf.printf "ok -> %s (from %s)" human_target from_alias);
         (match compacting_warning with Some w -> Printf.printf " [%s]" w | None -> ());
         print_newline ();
         (match delivery_warning_opt with
          | Some w -> Printf.eprintf "warning: %s\n%!" w
          | None -> ())
     end;
     (* B088: opt-in strict exit. Default stays 0 (fire-and-forget
        back-compat) — [--fail-if-queued] turns any not-synchronously-delivered
        send into a non-zero exit so scripts can detect non-delivery.
        B127 Tests §1: an offline durable queue ([queued_offline]) is queued,
        not confirmed delivered to a live recipient, so [--fail-if-queued]
        exits 3 for it too. A plain send (no flag) still exits 0; the mail is
        durably persisted either way. *)
     if fail_if_queued
        && (delivery_state = "queued" || delivery_state = "queued_offline")
     then exit 3
   with Invalid_argument msg ->
     (* Catch-all for errors from Session sends or other paths. *)
     Printf.eprintf "error: %s\n%!" msg;
     exit 1)

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

let send =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "send"
       ~doc:"Send a message to a registered peer alias or session ID.")
    send_cmd

let send_all =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "send-all" ~doc:"Broadcast a message to all peers.")
    send_all_cmd
