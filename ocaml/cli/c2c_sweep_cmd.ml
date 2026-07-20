(* c2c_sweep_cmd - sweep and registry-prune subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers
open C2c_types

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
    ~doc:"Skip the active/recent-registration safety check and run sweep anyway.\
          Use this only when you have verified no live sessions are present.")

(* --- subcommand: gc-inboxes (#53) ----------------------------------------- *)

(* Reclaim inbox files that have NO registration row at all. Dry-run by
   default; deletion requires --apply. See Broker.gc_inboxes for the safety
   invariant (no-row AND age; fails closed on an unreadable registry). *)

let gc_default_older_than = "7d"

let humanize_age ~now (mtime : float) : string =
  let secs = now -. mtime in
  if secs < 0. then "future"
  else
    let days = secs /. 86400. in
    if days >= 1. then Printf.sprintf "%.1fd" days
    else Printf.sprintf "%.1fh" (secs /. 3600.)

(* Aggregate by-sender counts across all candidate inboxes, sorted desc. *)
let gc_aggregate_by_sender (cands : C2c_mcp.Broker.gc_inbox_candidate list) =
  let tbl = Hashtbl.create 16 in
  List.iter (fun (c : C2c_mcp.Broker.gc_inbox_candidate) ->
    List.iter (fun (sender, n) ->
      let cur = try Hashtbl.find tbl sender with Not_found -> 0 in
      Hashtbl.replace tbl sender (cur + n))
      c.gc_by_sender)
    cands;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (_, a) (_, b) -> compare (b : int) a)

(* Bucket candidate ages (by file mtime) into human-readable ranges. *)
let gc_age_buckets ~now (cands : C2c_mcp.Broker.gc_inbox_candidate list) =
  let b_7_14 = ref 0 and b_14_30 = ref 0 and b_30_90 = ref 0 and b_90 = ref 0 in
  List.iter (fun (c : C2c_mcp.Broker.gc_inbox_candidate) ->
    let days = (now -. c.gc_mtime) /. 86400. in
    if days < 14. then incr b_7_14
    else if days < 30. then incr b_14_30
    else if days < 90. then incr b_30_90
    else incr b_90)
    cands;
  [ ("7-14d", !b_7_14); ("14-30d", !b_14_30); ("30-90d", !b_30_90); ("90d+", !b_90) ]

let gc_inboxes_run ~json ~apply ~older_than ~cross_repo ~explicit_root =
  match C2c_stats.parse_duration older_than with
  | None ->
      Printf.eprintf
        "error: --older-than must be a duration like 7d, 24h, or 30m (got %s).\n%!"
        older_than;
      exit 124
  | Some older_than_s ->
      let broker_root =
        resolve_effective_broker_root ~explicit_root ~cross_repo ()
      in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      let result = C2c_mcp.Broker.gc_inboxes broker ~older_than_s ~apply in
      let now = Unix.gettimeofday () in
      let open C2c_mcp.Broker in
      let total_msgs =
        List.fold_left (fun a c -> a + c.gc_message_count) 0 result.gc_candidates
      in
      let by_sender = gc_aggregate_by_sender result.gc_candidates in
      let output_mode = if json then Json else Human in
      (match output_mode with
       | Json ->
           print_json
             (`Assoc
               [ ("root", `String result.gc_root)
               ; ("registry_readable", `Bool result.gc_registry_readable)
               ; ("older_than_s", `Float older_than_s)
               ; ("apply", `Bool result.gc_applied)
               ; ("inbox_files", `Int result.gc_inbox_files)
               ; ("orphans_total", `Int result.gc_orphans_total)
               ; ("skipped_recent", `Int result.gc_skipped_recent)
               ; ("candidates", `Int (List.length result.gc_candidates))
               ; ("candidate_messages", `Int total_msgs)
               ; ("deleted", `List (List.map (fun s -> `String s) result.gc_deleted))
               ; ("deleted_messages", `Int result.gc_deleted_messages)
               ; ( "by_sender"
                 , `Assoc (List.map (fun (s, n) -> (s, `Int n)) by_sender) )
               ; ( "candidate_inboxes"
                 , `List
                     (List.map
                        (fun c ->
                          `Assoc
                            [ ("session_id", `String c.gc_session_id)
                            ; ("messages", `Int c.gc_message_count)
                            ; ( "newest_ts"
                              , match c.gc_newest_ts with
                                | None -> `Null
                                | Some t -> `Float t )
                            ; ("mtime", `Float c.gc_mtime)
                            ]) result.gc_candidates) )
               ])
       | Human ->
           if not result.gc_registry_readable then begin
             Printf.eprintf
               "error: registry at %s is missing or unreadable — reclaiming \
                NOTHING (fail closed).\n\
               \  If you truly have zero registrations, write `[]` to \
                registry.json to opt in.\n%!"
               (Filename.concat broker_root "registry.json");
             exit 123
           end;
           Printf.printf "broker root: %s\n" result.gc_root;
           Printf.printf "inbox files on disk    %d\n" result.gc_inbox_files;
           Printf.printf "orphan inboxes (no row) %d\n" result.gc_orphans_total;
           Printf.printf "  too recent (kept)     %d\n" result.gc_skipped_recent;
           Printf.printf "  eligible (>%s)        %d  (%d messages)\n"
             older_than (List.length result.gc_candidates) total_msgs;
           if result.gc_candidates <> [] then begin
             Printf.printf "\nage distribution (by mtime):\n";
             List.iter (fun (label, n) ->
               if n > 0 then Printf.printf "  %-8s %d\n" label n)
               (gc_age_buckets ~now result.gc_candidates);
             Printf.printf "\nby sender:\n";
             List.iter (fun (sender, n) ->
               Printf.printf "  %-24s %d\n" sender n) by_sender
           end;
           if result.gc_applied then begin
             Printf.printf "\nDELETED %d inbox(es), %d messages reclaimed.\n"
               (List.length result.gc_deleted) result.gc_deleted_messages
           end
           else if result.gc_candidates <> [] then
             Printf.printf
               "\nDry-run: nothing deleted. Re-run with --apply to reclaim \
                the %d eligible inbox(es).\n"
               (List.length result.gc_candidates)
           else
             Printf.printf "\nNothing to reclaim.\n")

let gc_inboxes_cmd =
  let+ json = json_flag
  and+ apply =
    Cmdliner.Arg.(value & flag & info [ "apply" ]
      ~doc:"Actually delete the eligible orphan inboxes. Without this flag \
            the command is a DRY RUN and touches nothing on disk.")
  and+ older_than =
    Cmdliner.Arg.(value & opt string gc_default_older_than
      & info [ "older-than" ] ~docv:"DURATION"
        ~doc:"Only reclaim an orphan whose inbox mtime AND newest message \
              timestamp are older than this (e.g. 7d, 24h, 30m). This is the \
              race guard: an inbox written just before its registration is \
              never reclaimed. Default: 7d.")
  and+ cross_repo = cross_repo_flag
  and+ explicit_root =
    Cmdliner.Arg.(value & opt (some string) None
      & info [ "root"; "broker-root" ] ~docv:"DIR"
        ~doc:"Operate on the broker at DIR instead of this repo's broker. \
              Wins over --cross-repo.")
  in
  gc_inboxes_run ~json ~apply ~older_than ~cross_repo ~explicit_root

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
  (* Use the same bounded predicate as Broker.sweep.  The general delivery
     liveness predicate intentionally treats pidless registrations as alive,
     but doing so here made old CLI registrations block sweep forever even
     after Broker.sweep classified them as reappable. *)
  let protected_nonmanaged_regs =
    let all_regs = C2c_mcp.Broker.list_registrations broker in
    List.filter (fun (r : C2c_mcp.registration) ->
      not (List.mem r.session_id c2c_start_sids)
      && C2c_mcp.Broker.is_sweep_keepable r
    ) all_regs
  in
  if protected_nonmanaged_regs <> [] && not force then begin
    Printf.eprintf "error: refusing sweep while %d active/recent registration(s) are present.\n"
      (List.length protected_nonmanaged_regs);
    List.iter (fun (r : C2c_mcp.registration) ->
      Printf.eprintf "  protected: %s (%s)\n" r.alias r.session_id
    ) protected_nonmanaged_regs;
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
  let preview = C2c_mcp.Broker.sweep_preview broker in
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
  let nonempty_at_risk = List.filter_map (fun sid ->
    match inbox_count sid with
    | Some n when n > 0 -> Some (sid, n)
    | _ -> None
  ) preview.deleted_inboxes in
  let risk = List.length nonempty_at_risk in
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
            ; ("would_drop_if_swept", `Int (List.length preview.dropped_regs + List.length preview.deleted_inboxes))
            ; ("nonempty_content_at_risk", `Int risk)
            ])
        ; ("live_regs", `List (List.map json_reg !live_regs))
        ; ("legacy_pidless_regs", `List (List.map json_reg !legacy_regs))
        ; ("dead_regs", `List (List.map json_reg !dead_regs))
        ; ("would_drop_regs", `List (List.map json_reg preview.dropped_regs))
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
      Printf.printf "  would drop if swept    %d\n"
        (List.length preview.dropped_regs + List.length preview.deleted_inboxes);
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
      if preview.dropped_regs <> [] then begin
        Printf.printf "\nregistrations sweep would drop:\n";
        List.iter (fun (r : C2c_mcp.registration) ->
          let suffix = match inbox_count r.session_id with
            | Some n when n > 0 -> Printf.sprintf "  [%d pending msgs]" n
            | _ -> ""
          in
          Printf.printf "  %-20s %s  pid=%s%s\n" r.alias r.session_id
            (match r.pid with None -> "None" | Some p -> string_of_int p)
            suffix
        ) preview.dropped_regs
      end;
      if nonempty_at_risk <> [] then begin
        Printf.printf "\nNON-EMPTY content that sweep would delete:\n";
        List.iter (fun (sid, n) ->
          Printf.printf "  %s  (%d msgs)\n" sid n
        ) nonempty_at_risk;
        Printf.printf "  -> consider draining these before running sweep.\n"
      end

let sweep_dryrun_cmd =
  let+ json = json_flag in
  sweep_dryrun_run json

let sweep =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "sweep" ~doc:"Remove dead registrations and orphan inboxes.")
    sweep_cmd

let registry_prune =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "registry-prune" ~doc:"Remove dead test registrations matching prefix patterns (dry-run by default; --force to actually prune).")
    registry_prune_cmd

let sweep_dryrun =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "sweep-dryrun" ~doc:"Read-only preview of what sweep would drop (safe during active swarm).")
    sweep_dryrun_cmd

let gc_inboxes =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "gc-inboxes"
       ~doc:"Reclaim inbox files that have NO registration row (dry-run by default; --apply to delete)."
       ~man:
         [ `S "DESCRIPTION"
         ; `P "Deletes orphan inbox files — an inbox whose session_id has NO \
                registration row at all (not dead, not pidless: absent). Dead \
                and pidless rows are reachable and are always preserved (that \
                is $(b,c2c sweep)'s territory, and #51/#59's)."
         ; `P "An inbox is eligible only when it is BOTH row-less AND older \
                than $(b,--older-than) (its file mtime and newest message \
                timestamp both precede the cutoff — the race guard). The \
                command fails closed and reclaims nothing if the registry \
                cannot be read as a JSON list."
         ; `P "Dry-run by default: it prints what it WOULD reclaim (count, \
                messages, age distribution, by-sender) and changes nothing. \
                Pass $(b,--apply) to actually delete."
         ])
    gc_inboxes_cmd
