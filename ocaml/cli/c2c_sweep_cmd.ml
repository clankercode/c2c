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
