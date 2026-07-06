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
  let list_registration_to_json ?(repo_fp="") ?(repo_path="") ~(enriched:bool) (r : C2c_mcp.registration) =
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
          let json_regs = List.map (fun (fp, root, r) -> list_registration_to_json ~repo_fp:fp ~repo_path:root ~enriched r) all_regs in
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
          let json_regs = List.map (fun r -> list_registration_to_json ~enriched r) regs in
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

(* Health, connect, verify, host-id subcommands extracted to c2c_health_cmd.ml *)

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


(* Relay subcommands extracted to c2c_relay_cmd.ml *)
(* Mesh subcommands extracted to c2c_mesh_cmd.ml *)

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
  let tier_grouped_man = C2c_commands_cmd.commands_man is_agent in
  let all_cmds =
    [ send; list; sessions; whoami; set_compact; clear_compact; open_pending_reply; check_pending_reply; poll_inbox; peek_inbox; C2c_approval_cmd.await_reply; C2c_approval_cmd.approval_reply; C2c_approval_cmd.authorize; C2c_approval_cmd.approval_pending_write; C2c_approval_cmd.approval_list; C2c_approval_cmd.approval_show; C2c_approval_cmd.approval_gc; C2c_approval_cmd.resolve_authorizer; send_all; C2c_sweep_cmd.sweep; C2c_sweep_cmd.registry_prune
    ; C2c_sweep_cmd.sweep_dryrun; C2c_migrate_cmd.migrate_broker; C2c_history_cmd.history; C2c_health_cmd.health; C2c_health_cmd.connect; setcap; C2c_health_cmd.status; C2c_health_cmd.verify; C2c_health_cmd.host_id; git; register; deregister; refresh_peer; C2c_coord.coord_cherry_pick_cmd; C2c_coord.coord_group
    ; tail_log; server_info; my_rooms; dead_letter; prune_rooms; get_tmux_location; smoke_test_deprecated; C2c_init_cmd.init; C2c_init_cmd.install; C2c_init_cmd.self_update; C2c_init_cmd.update_alias; C2c_init_cmd.upgrade_alias; C2c_uninstall.uninstall_subcmd; C2c_init_cmd.completion_cmd; C2c_glyphs_cmd.list_glyphs
    ; serve; mcp; C2c_managed_cmd.start; C2c_agent.agent_group; C2c_config_cmd.config_group; C2c_agent.roles_group; C2c_gui_cmd.gui; C2c_managed_cmd.stop; C2c_managed_cmd.restart; C2c_managed_cmd.reset_thread; restart_self_deprecated; C2c_instances_cmd.instances_deprecated; diag_deprecated; dev_group; C2c_doctor_cmd.doctor; C2c_stats_cmd.stats; C2c_rooms.rooms_group; C2c_rooms.room_group    ; C2c_relay_cmd.relay_group; relay_pins; C2c_mesh_cmd.mesh_group; C2c_skills_cmd.skills_group; C2c_stickers.sticker_group; C2c_memory.memory_group; C2c_schedule.schedule_group; C2c_monitor_cmd.monitor; C2c_hook_cmd.hook; inject_deprecated; C2c_config_cmd.repo_group; C2c_inject_cmd.screen; C2c_statefile_cmd.statefile_top; C2c_statefile_cmd.debug_group; C2c_statefile_cmd.oc_plugin_group; C2c_statefile_cmd.cc_plugin_group; C2c_supervisor_cmd.supervisor_group; C2c_deliver_watch.deliver_group; C2c_commands_cmd.commands_by_safety; C2c_agent_help.agent_help; C2c_watch.watch_cmd; help ]
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
