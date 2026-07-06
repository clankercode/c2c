(* c2c_migrate_cmd - migrate-broker command assembly.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers
open C2c_utils

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

(** Default migration source when --from is not given:
    1. the legacy <git-common-dir>/c2c/mcp path, if it exists;
    2. otherwise an orphaned XDG-profile broker
       ($XDG_STATE_HOME/c2c/repos/<fp>/broker) that the resolver no longer
       selects (#9 split-brain) — so a bare `c2c migrate-broker` fixes both
       known migration cases. *)
let default_migrate_source () =
  let legacy = legacy_broker_root () in
  if legacy <> "" && Sys.file_exists legacy then legacy
  else
    match C2c_repo_fp.xdg_split_brain_broker () with
    | Some xdg -> xdg
    | None -> legacy

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
  let from = Option.value from_path ~default:(default_migrate_source ()) in
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
      ; "source_removed", `Bool outcome.source_removed
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
           ~doc:"Source broker root (default: the legacy .git/c2c/mcp path if \
                 it exists, else an orphaned \\$XDG_STATE_HOME/c2c/repos/<fp>/broker \
                 profile broker)")
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

let migrate_broker : unit Cmdliner.Cmd.t =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "migrate-broker"
       ~doc:"Migrate broker data from the legacy .git/c2c/mcp path to the new per-repo path."
       ~man:[ `S "DESCRIPTION"
            ; `P "Migrates broker state from the legacy $(b,.git/c2c/mcp) path — or \
                  from an orphaned XDG-profile broker \
                  ($(b,\\$XDG_STATE_HOME/c2c/repos/<fp>/broker), no longer selected \
                  by the resolver) — to the canonical per-repo path \
                  ($(b,\\$C2C_STATE_HOME/c2c/repos/<fp>/broker) if set, else \
                  $(b,\\$HOME/.c2c/repos/<fp>/broker))."
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
