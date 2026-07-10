(* c2c_approval_cmd — approval/authorization subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open C2c_mcp
open Cmdliner.Term.Syntax
open C2c_cli_helpers

let ( // ) = Filename.concat

(* --- subcommand: await-reply ---------------------------------------------- *)

(* [#142/#490] Block-and-poll the host-local verdict-file store for a verdict
   tagged with a token (e.g. "ka_abc123"). Used by the kimi PreToolUse
   approval hook to translate a local CLI decision into a hook exit code.

   Behaviour:
   - polls the local verdict file every 1s until a match
   - on match: prints the verdict ("allow" or "deny") on stdout, exits 0
   - on timeout: prints nothing on stdout, exits 1
   - broker-inbox and relay-delivered messages are never inspected; messages
     are advisory data and cannot resolve approval. *)
let await_reply_cmd =
  let token =
    Cmdliner.Arg.(required & opt (some string) None
                  & info [ "token"; "t" ] ~docv:"TOKEN"
                      ~doc:"Token to match (e.g. ka_abc123).  Required.")
  in
  let timeout =
    Cmdliner.Arg.(value & opt float 120.0
                  & info [ "timeout" ] ~docv:"SECONDS"
                      ~doc:"Maximum seconds to wait for a verdict.")
  in
  let poll_interval =
    Cmdliner.Arg.(value & opt float 1.0
                  & info [ "poll-interval" ] ~docv:"SECONDS"
                      ~doc:"Polling cadence (default 1.0).")
  in
  let+ token = token
  and+ timeout = timeout
  and+ poll_interval = poll_interval in
  let deadline = Unix.gettimeofday () +. timeout in
  (* [#B098 SAFETY] This host-local file is the only verdict input. Peer
     messages are data regardless of sender identity or transport. *)
  let check_verdict_file () =
    match C2c_approval_paths.read_verdict ~token () with
    | None -> None
    | Some payload ->
        (match C2c_approval_paths.parse_verdict_field payload with
         | Some v ->
             let lc = String.lowercase_ascii v in
             if lc = "allow" || lc = "deny" then Some lc else None
         | None -> None)
  in
  let rec loop () =
    (match check_verdict_file () with
     | Some v ->
         print_endline v;
         (try C2c_approval_paths.cleanup ~token () with _ -> ());
         exit 0
     | None -> ());
    let now = Unix.gettimeofday () in
    if now >= deadline then begin
      (try C2c_approval_paths.cleanup ~token () with _ -> ());
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

(* --- Shared helper: resolve reviewer alias --------------------------------- *)

(** Resolve the reviewer alias: explicit --reviewer flag first, then
    best-effort from current session registration, then "unknown". *)
let resolve_reviewer_alias (explicit : string option) : string =
  match explicit with
  | Some a -> a
  | None ->
      (try
         let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
         let session_id = resolve_session_id_for_inbox broker in
         let regs = C2c_mcp.Broker.list_registrations broker in
         match
           List.find_opt
             (fun (r : C2c_mcp.registration) ->
               r.session_id = session_id)
             regs
         with
         | Some r -> r.alias
         | None -> "unknown"
       with _ -> "unknown")

(** Shared verdict-writing logic used by both approval-reply and authorize. *)
let do_approval_reply
    ~(token : string)
    ~(verdict_lc : string)
    ~(reason : string)
    ~(reviewer_alias : string)
    ~(override_root : string option)
    ~(json : bool)
    ~(cmd_name : string)
  : unit =
  (* #484: MCP-strengthening — validate reviewer via pending-reply system *)
  let broker_root = match override_root with
    | Some r -> r
    | None -> resolve_broker_root ()
  in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  (match C2c_mcp.Broker.find_pending_permission broker token with
   | Some pending ->
       if not (List.exists
                 (fun s ->
                   C2c_mcp.Broker.alias_casefold s
                   = C2c_mcp.Broker.alias_casefold reviewer_alias)
                 pending.supervisors)
       then begin
         Printf.eprintf
           "%s: reviewer %s is not in supervisors list for token %s; rejecting\n%!"
           cmd_name reviewer_alias token;
         exit 1
       end
   | None ->
       (* Backward compat: no pending entry means either old-style token
          (open-pending-reply was never called) or entry expired.
          Warn but allow. *)
       Printf.eprintf
         "%s: note: no pending-reply entry for token %s (old-style or expired); proceeding without auth check\n%!"
         cmd_name token);
  C2c_approval_paths.ensure_dirs ?override_root ();
  let ts = int_of_float (Unix.gettimeofday ()) in
  let payload =
    C2c_approval_paths.make_verdict_payload
      ~token ~verdict:verdict_lc ~reason ~reviewer_alias ~ts
  in
  let path =
    try C2c_approval_paths.write_verdict ?override_root ~token ~payload () with
    | Sys_error msg ->
        Printf.eprintf "%s: write failed: %s\n%!" cmd_name msg;
        exit 2
    | exn ->
        Printf.eprintf "%s: write failed: %s\n%!"
          cmd_name (Printexc.to_string exn);
        exit 2
  in
  (* #484: Mark the pending permission as resolved so broker stops fallthrough *)
  let _resolved = C2c_mcp.Broker.mark_pending_resolved broker ~perm_id:token ~ts:(float_of_int ts) () in
  if json then
    Printf.printf
      "{\"ok\":true,\"verdict\":\"%s\",\"token\":\"%s\",\"path\":\"%s\",\"reviewer_alias\":\"%s\"}\n%!"
      verdict_lc token path reviewer_alias
  else
    Printf.printf
      "%s: %s recorded for %s (file=%s, reviewer=%s)\n%!"
      cmd_name verdict_lc token path reviewer_alias;
  exit 0

(* --- subcommand: approval-reply -------------------------------------------- *)

(* [#490 slice 5a] Reviewer-side counterpart to `c2c await-reply`. Writes
   a JSON verdict file at <broker_root>/approval-verdict/<token>.json
   which `c2c await-reply` (running inside the kimi PreToolUse hook)
   watches. Unlike the legacy `c2c send <kimi> "<token> allow"` path,
   this does NOT race the notifier-daemon drain and does NOT inject
   verdict text into the recipient agent's user-input queue.

   See .collab/design/2026-04-30-142-approval-side-channel-stanza.md
   (Option A) for the design rationale. *)
let approval_reply_cmd =
  let token =
    Cmdliner.Arg.(required & pos 0 (some string) None
                  & info [] ~docv:"TOKEN"
                      ~doc:"Approval token from the awareness DM (e.g. ka_abc123).")
  in
  let verdict =
    Cmdliner.Arg.(required & pos 1 (some string) None
                  & info [] ~docv:"VERDICT"
                      ~doc:"Verdict: 'allow' or 'deny' (case-insensitive).")
  in
  let reason_words =
    Cmdliner.Arg.(value & pos_right 1 string []
                  & info [] ~docv:"REASON"
                      ~doc:"Optional free-text reason (concatenated; for 'deny' it shows up in the agent's stderr).")
  in
  let reviewer_alias_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "reviewer"; "as" ] ~docv:"ALIAS"
                      ~doc:"Reviewer alias to record in the verdict file. Defaults to current session's alias if resolvable; falls back to 'unknown'.")
  in
  let broker_root_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "broker-root" ] ~docv:"PATH"
                      ~doc:"Override the broker root for the verdict file write. When the hook ran from a worktree while the reviewer runs from a different directory, pass the broker_root value shown by 'approval-show' so the verdict lands in the same directory the hook watches.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Print machine-readable JSON.")
  in
  let+ token = token
  and+ verdict = verdict
  and+ reason_words = reason_words
  and+ reviewer_alias_flag = reviewer_alias_flag
  and+ broker_root_flag = broker_root_flag
  and+ json = json in
  let verdict_lc = String.lowercase_ascii (String.trim verdict) in
  if verdict_lc <> "allow" && verdict_lc <> "deny" then begin
    Printf.eprintf
      "approval-reply: VERDICT must be 'allow' or 'deny' (got %S)\n%!" verdict;
    exit 2
  end;
  let reason =
    let raw = String.concat " " reason_words in
    let raw = String.trim raw in
    if String.length raw >= 8
       && String.lowercase_ascii (String.sub raw 0 8) = "because "
    then String.sub raw 8 (String.length raw - 8) |> String.trim
    else raw
  in
  let reviewer_alias = resolve_reviewer_alias reviewer_alias_flag in
  do_approval_reply
    ~token ~verdict_lc ~reason ~reviewer_alias
    ~override_root:broker_root_flag ~json
    ~cmd_name:"approval-reply"

(* --- subcommand: authorize (#511 Slice 5) ------------------------------- *)

(* Ergonomic shortcut for approval-reply. Identical semantics, different
   command name: `c2c authorize <token> allow|deny [because <reason>]`.
   Saves reviewers from remembering the longer approval-reply name.
   See .collab/design/2026-05-01-prompt-forwarding-fallback-authorizers.md §4 S5. *)
let authorize_cmd =
  let token =
    Cmdliner.Arg.(required & pos 0 (some string) None
                  & info [] ~docv:"TOKEN"
                      ~doc:"Approval token (e.g. ka_abc123).")
  in
  let verdict =
    Cmdliner.Arg.(required & pos 1 (some string) None
                  & info [] ~docv:"VERDICT"
                      ~doc:"Verdict: 'allow' or 'deny' (case-insensitive).")
  in
  let reason_words =
    Cmdliner.Arg.(value & pos_right 1 string []
                  & info [] ~docv:"REASON"
                      ~doc:"Optional free-text reason (concatenated; for 'deny' it shows up in the agent's stderr).")
  in
  let reviewer_alias_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "reviewer"; "as" ] ~docv:"ALIAS"
                      ~doc:"Reviewer alias to record in the verdict file. Defaults to current session's alias if resolvable.")
  in
  let broker_root_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "broker-root" ] ~docv:"PATH"
                      ~doc:"Override the broker root for the verdict file write.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Print machine-readable JSON.")
  in
  let+ token = token
  and+ verdict = verdict
  and+ reason_words = reason_words
  and+ reviewer_alias_flag = reviewer_alias_flag
  and+ broker_root_flag = broker_root_flag
  and+ json = json in
  let verdict_lc = String.lowercase_ascii (String.trim verdict) in
  if verdict_lc <> "allow" && verdict_lc <> "deny" then begin
    Printf.eprintf
      "authorize: VERDICT must be 'allow' or 'deny' (got %S)\n%!" verdict;
    exit 2
  end;
  let reason =
    let raw = String.concat " " reason_words in
    let raw = String.trim raw in
    if String.length raw >= 8
       && String.lowercase_ascii (String.sub raw 0 8) = "because "
    then String.sub raw 8 (String.length raw - 8) |> String.trim
    else raw
  in
  let reviewer_alias = resolve_reviewer_alias reviewer_alias_flag in
  do_approval_reply
    ~token ~verdict_lc ~reason ~reviewer_alias
    ~override_root:broker_root_flag ~json
    ~cmd_name:"authorize"

(* --- subcommand: resolve-authorizer ----------------------------------------
   #511: resolve the first live/DnD-clear/idle-clear authorizer from the
   ordered authorizers[] list in ~/.c2c/repo.json.  Exits 0 and prints the
   alias if one qualifies; exits 1 and prints nothing if the list is empty
   or no candidate is currently available.  The hook script (Slice 2) uses
   this to determine where to send the first permission-request DM. *)

let resolve_authorizer_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable output.")
  in
  let+ json = json in
  match C2c_authorizers.resolve_first_authorizer () with
  | None ->
      if json then
        Printf.printf "{\"ok\":false,\"authorizer\":null}\n%!"
      else
        Printf.eprintf "resolve-authorizer: no live authorizer found\n%!";
      exit 1
  | Some authorizer ->
      if json then
        Printf.printf "{\"ok\":true,\"authorizer\":\"%s\"}\n%!" authorizer
      else
        Printf.printf "%s\n%!" authorizer;
      exit 0

(* --- subcommand: approval-pending-write ------------------------------------ *)

(* [#490 slice 5b] Bash-callable companion to approval-reply: lets the
   embedded kimi PreToolUse hook record what's pending before the
   awareness DM goes out. Reviewers can then run `c2c approval-list`
   independently of receiving the DM. Failure here is non-fatal because the
   advisory DM can still deliver the awareness body; it cannot carry a
   verdict. *)
let approval_pending_write_cmd =
  let token =
    Cmdliner.Arg.(required & opt (some string) None
                  & info [ "token"; "t" ] ~docv:"TOKEN" ~doc:"Approval token (e.g. ka_abc123).")
  in
  let tool_name =
    Cmdliner.Arg.(value & opt string ""
                  & info [ "tool-name" ] ~docv:"NAME" ~doc:"Tool kimi was about to call (e.g. Shell).")
  in
  let tool_input =
    Cmdliner.Arg.(value & opt string "{}"
                  & info [ "tool-input" ] ~docv:"JSON"
                      ~doc:"Tool-input JSON (verbatim; pass `jq -c .` output).")
  in
  let reviewer =
    Cmdliner.Arg.(value & opt string "coordinator1"
                  & info [ "reviewer" ] ~docv:"ALIAS" ~doc:"Reviewer alias.")
  in
  let timeout =
    Cmdliner.Arg.(value & opt int 120
                  & info [ "timeout" ] ~docv:"SECONDS" ~doc:"Hook fall-closed timeout.")
  in
  let agent_alias_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "agent-alias" ] ~docv:"ALIAS"
                      ~doc:"Agent (kimi) alias whose hook fired. Defaults to current session alias.")
  in
  (* #511 Slice 4: fallback authorizer chain + update-authorizer flag. *)
  let authorizers_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "authorizers" ] ~docv:"ALIAS1,ALIAS2,..."
                      ~doc:"Comma-separated ordered list of reviewer aliases (the fallback chain). Written into the pending record. Omit when using --update-authorizer.")
  in
  let primary_authorizer_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "primary-authorizer" ] ~docv:"ALIAS"
                      ~doc:"First (current) authorizer in the chain. Written into the pending record. Omit when using --update-authorizer.")
  in
  let update_authorizer_flag =
    Cmdliner.Arg.(value & opt (some string) None
                  & info [ "update-authorizer" ] ~docv:"ALIAS"
                      ~doc:"Instead of creating a new pending record, update the primary_authorizer field of an existing one. Use this to advance the chain as each authorizer is tried.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable output.")
  in
  let+ token = token
  and+ tool_name = tool_name
  and+ tool_input = tool_input
  and+ reviewer = reviewer
  and+ timeout = timeout
  and+ agent_alias_flag = agent_alias_flag
  and+ authorizers_flag = authorizers_flag
  and+ primary_authorizer_flag = primary_authorizer_flag
  and+ update_authorizer_flag = update_authorizer_flag
  and+ json = json in
  (* --update-authorizer: in-place update of primary_authorizer field only. *)
  (match update_authorizer_flag with
   | Some new_authorizer ->
       let ok = C2c_approval_paths.update_primary_authorizer_in_file ~token ~new_authorizer () in
       if json then
         Printf.printf "{\"ok\":%b,\"token\":\"%s\",\"updated_primary_authorizer\":\"%s\"}\n%!" ok token new_authorizer
       else
         Printf.printf "approval-pending-write: %supdated primary_authorizer=%s for token=%s\n%!"
           (if ok then "" else "FAILED to ") new_authorizer token;
       exit (if ok then 0 else 1)
   | None -> ());
  let agent_alias =
    match agent_alias_flag with
    | Some a -> a
    | None ->
        (try
           let broker = C2c_mcp.Broker.create ~root:(resolve_broker_root ()) in
           let session_id = resolve_session_id_for_inbox broker in
           let regs = C2c_mcp.Broker.list_registrations broker in
           match
             List.find_opt
               (fun (r : C2c_mcp.registration) -> r.session_id = session_id)
               regs
           with
           | Some r -> r.alias
           | None -> "unknown"
         with _ -> "unknown")
  in
  let authorizers =
    match authorizers_flag with
    | Some s ->
        s |> String.split_on_char ','
          |> List.filter (fun s -> String.trim s <> "")
          |> List.map String.trim
    | None -> []
  in
  let primary_authorizer =
    match primary_authorizer_flag with
    | Some a -> a | None -> ""
  in
  C2c_approval_paths.ensure_dirs ();
  let timeout_at = int_of_float (Unix.gettimeofday ()) + timeout in
  let broker_root = resolve_broker_root () in
  let payload =
    C2c_approval_paths.make_pending_payload
      ~token ~agent_alias ~tool_name ~tool_input ~timeout_at
      ~reviewer_alias:reviewer ~broker_root
      ~authorizers ~primary_authorizer
  in
  let path =
    try C2c_approval_paths.write_pending ~token ~payload () with
    | exn ->
        Printf.eprintf "approval-pending-write: %s\n%!" (Printexc.to_string exn);
        exit 2
  in
  if json then
    Printf.printf
      "{\"ok\":true,\"token\":\"%s\",\"path\":\"%s\",\"agent_alias\":\"%s\",\"reviewer\":\"%s\",\"timeout_at\":%d}\n%!"
      token path agent_alias reviewer timeout_at
  else
    Printf.printf
      "approval-pending-write: %s recorded (file=%s, agent=%s, reviewer=%s, timeout_at=%d, authorizers=%d, primary_authorizer=%s)\n%!"
      token path agent_alias reviewer timeout_at
      (List.length authorizers)
      (if primary_authorizer = "" then "(none)" else primary_authorizer);
  exit 0

(* --- subcommand: approval-list -------------------------------------------- *)

(* [#490 slice 5b] List currently-pending approval requests. Reviewers
   can run this to see what's waiting on them across all hooks in this
   repo, even before reading the awareness DM. *)
let approval_list_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable JSON array.")
  in
  let+ json = json in
  let tokens = C2c_approval_paths.list_pending_tokens () in
  if json then begin
    let items =
      List.map (fun tok ->
        let payload =
          match C2c_approval_paths.read_pending ~token:tok () with
          | Some s -> s
          | None -> "null"
        in
        let has_verdict = C2c_approval_paths.has_verdict ~token:tok () in
        Printf.sprintf
          "{\"token\":\"%s\",\"has_verdict\":%b,\"pending\":%s}"
          tok has_verdict
          (if payload = "" then "null" else String.trim payload)
      ) tokens
    in
    Printf.printf "[%s]\n%!" (String.concat "," items);
    exit 0
  end else begin
    if tokens = [] then
      print_endline "(no pending approvals)"
    else begin
      Printf.printf "%-40s  %-7s  %-20s\n" "TOKEN" "VERDICT" "CURRENT AUTHORIZER";
      List.iter (fun tok ->
        let v = if C2c_approval_paths.has_verdict ~token:tok () then "ready" else "wait" in
        let authorizer =
          match C2c_approval_paths.read_pending ~token:tok () with
          | Some s ->
              (match C2c_approval_paths.parse_string_field s "primary_authorizer" with
               | Some a -> a
               | None -> "-")
          | None -> "-"
        in
        Printf.printf "%-40s  %-7s  %-20s\n" tok v authorizer
      ) tokens
    end;
    exit 0
  end

(* --- subcommand: approval-show -------------------------------------------- *)

(* [#490 slice 5b] Show the full pending-record JSON for one token.
   Useful when the reviewer wants to inspect tool-input details before
   issuing approval-reply. Exit 1 if not found. *)
let approval_show_cmd =
  let token =
    Cmdliner.Arg.(required & pos 0 (some string) None
                  & info [] ~docv:"TOKEN" ~doc:"Approval token.")
  in
  let+ token = token in
  match C2c_approval_paths.read_pending ~token () with
  | None ->
      Printf.eprintf "approval-show: no pending record for %s\n%!" token;
      exit 1
  | Some s ->
      (* Extract and display broker_root for the reviewer's convenience. *)
      (match C2c_approval_paths.parse_string_field s "broker_root" with
       | Some br ->
           Printf.printf "[broker_root: %s]\n%!" br
       | None -> ());
      (* #511 Slice 4: also display primary_authorizer and authorizers chain. *)
      (match C2c_approval_paths.parse_string_field s "primary_authorizer" with
       | Some pa ->
           Printf.printf "[primary_authorizer: %s]\n%!" pa
       | None -> ());
      (match C2c_approval_paths.parse_string_list_field s "authorizers" with
       | Some al when al <> [] ->
           let chain = String.concat ", " al in
           Printf.printf "[authorizers: %s]\n%!" chain
       | _ -> ());
      print_string s;
      if String.length s = 0 || s.[String.length s - 1] <> '\n' then
        print_newline ();
      exit 0

(* --- subcommand: approval-gc ---------------------------------------------- *)

(* [#490 slice 5c] Sweep stale pending/verdict files. Pending files are
   removed when their `timeout_at` is in the past; verdict files are
   removed when their mtime is older than `--max-verdict-age` seconds
   (default 1 hour). Dry-run by default; --apply to actually delete. *)
let approval_gc_cmd =
  let apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
                    ~doc:"Actually delete classified-stale files (default: dry-run).")
  in
  let max_verdict_age =
    Cmdliner.Arg.(value & opt int 3600
                  & info [ "max-verdict-age" ] ~docv:"SECONDS"
                      ~doc:"Verdict files older than this many seconds are stale (default 3600).")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Machine-readable JSON output.")
  in
  let+ apply = apply
  and+ max_verdict_age = max_verdict_age
  and+ json = json in
  let now_i = int_of_float (Unix.gettimeofday ()) in
  let now_f = Unix.gettimeofday () in
  let pending_tokens = C2c_approval_paths.list_pending_tokens () in
  let verdict_tokens = C2c_approval_paths.list_verdict_tokens () in
  let pending_classifications =
    List.map (fun tok ->
      let path = C2c_approval_paths.pending_file ~token:tok () in
      match C2c_approval_paths.read_pending_timeout_at ~token:tok () with
      | Some t when t <= now_i -> (tok, path, "stale", t)
      | Some t -> (tok, path, "active", t)
      | None -> (tok, path, "unknown", 0))
      pending_tokens
  in
  let verdict_classifications =
    List.map (fun tok ->
      let path = C2c_approval_paths.verdict_file ~token:tok () in
      match C2c_approval_paths.mtime_opt path with
      | Some m when (now_f -. m) >= float_of_int max_verdict_age ->
          (tok, path, "stale", int_of_float m)
      | Some m -> (tok, path, "active", int_of_float m)
      | None -> (tok, path, "unknown", 0))
      verdict_tokens
  in
  let to_remove =
    (List.filter (fun (_, _, c, _) -> c = "stale") pending_classifications) @
    (List.filter (fun (_, _, c, _) -> c = "stale") verdict_classifications)
  in
  let removed = ref 0 in
  if apply then
    List.iter (fun (_, path, _, _) ->
      try Sys.remove path; incr removed with _ -> ()) to_remove;
  if json then begin
    let item_to_json (tok, path, cls, ts) kind =
      Printf.sprintf "{\"token\":\"%s\",\"path\":\"%s\",\"class\":\"%s\",\"ts\":%d,\"kind\":\"%s\"}"
        tok path cls ts kind
    in
    let p = List.map (fun x -> item_to_json x "pending") pending_classifications in
    let v = List.map (fun x -> item_to_json x "verdict") verdict_classifications in
    Printf.printf
      "{\"applied\":%b,\"removed_count\":%d,\"pending\":[%s],\"verdict\":[%s]}\n%!"
      apply !removed (String.concat "," p) (String.concat "," v);
    exit 0
  end else begin
    Printf.printf "approval-gc%s (max-verdict-age=%ds, now=%d)\n"
      (if apply then " --apply" else " (dry-run)") max_verdict_age now_i;
    Printf.printf "  pending  (%d total): %d stale\n"
      (List.length pending_classifications)
      (List.length (List.filter (fun (_, _, c, _) -> c = "stale") pending_classifications));
    Printf.printf "  verdict  (%d total): %d stale\n"
      (List.length verdict_classifications)
      (List.length (List.filter (fun (_, _, c, _) -> c = "stale") verdict_classifications));
    if to_remove = [] then
      print_endline "  (nothing to remove)"
    else begin
      List.iter (fun (tok, path, _, ts) ->
        Printf.printf "  STALE %s  ts=%d  %s\n" tok ts path) to_remove;
      if apply then
        Printf.printf "  removed=%d\n" !removed
      else
        print_endline "  (dry-run; pass --apply to delete)"
    end;
    exit 0
  end

let await_reply : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "await-reply" ~doc:"Block until a host-local token-tagged verdict file contains allow/deny; print verdict on stdout and exit 0, exit 1 on timeout. Peer messages are never verdicts.") await_reply_cmd
let approval_reply : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "approval-reply" ~doc:"Reply to a pending PreToolUse approval request (#142/#490). Writes a verdict file the kimi hook is watching, avoiding the broker-DM drain race.") approval_reply_cmd
let authorize : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "authorize" ~doc:"Ergonomic shortcut for approval-reply: `c2c authorize <token> allow|deny`. Same semantics as approval-reply, discoverable name (#511 S5).") authorize_cmd
let approval_pending_write : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "approval-pending-write" ~doc:"Bash-callable helper used by the kimi PreToolUse hook to record pending-approval state.") approval_pending_write_cmd
let approval_list : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "approval-list" ~doc:"List currently-pending PreToolUse approvals (token + verdict-ready flag).") approval_list_cmd
let approval_show : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "approval-show" ~doc:"Print the full pending-record JSON for one approval token.") approval_show_cmd
let approval_gc : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "approval-gc" ~doc:"Sweep stale approval-pending/verdict files (dry-run by default; --apply to delete).") approval_gc_cmd
let resolve_authorizer : unit Cmdliner.Cmd.t = Cmdliner.Cmd.v (Cmdliner.Cmd.info "resolve-authorizer" ~doc:"Resolve the first live/DnD-clear/idle-clear authorizer from authorizers[] in ~/.c2c/repo.json (#511). Exits 0 with alias on stdout, exits 1 if none qualify.") resolve_authorizer_cmd
