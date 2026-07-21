(* c2c_doctor_cmd — doctor subcommands.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

(* --- subcommand: doctor --------------------------------------------------- *)

let doctor_cmd =
  let summary =
    Cmdliner.Arg.(value & flag & info [ "summary" ]
      ~doc:"Compact ACTION REQUIRED output with FIX NOW / COORDINATOR / ALL CLEAR sections.")
  in
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ]
      ~doc:"Output machine-readable JSON.")
  in
  let relay =
    Cmdliner.Arg.(value & flag & info [ "relay" ]
      ~doc:"Run relay-side checks (configured, reachable, lease, connector, outbox, \
            capabilities) with stable check_ids, copy-pasteable fix commands, and a \
            non-zero exit on FAIL (B093).")
  in
  let check_rebase_base =
    Cmdliner.Arg.(value & flag & info [ "check-rebase-base" ]
      ~doc:"Check if HEAD is based on origin/master (exit 0 = OK, exit 1 = STALE).")
  in
  let install_freshness =
    Cmdliner.Arg.(value & flag & info [ "install-freshness" ]
      ~doc:"Check if HEAD is fresh vs origin/master (exit 0 = FRESH, exit 1 = BEHIND). Pattern 18.")
  in
  let+ summary = summary
  and+ json = json
  and+ relay = relay
  and+ check_rebase_base = check_rebase_base
  and+ install_freshness = install_freshness in
  if relay then begin
    (* B093: relay checks run inline (OCaml) regardless of repo context, so
       `c2c doctor --relay` works outside the c2c git repo too. Exits non-zero
       when any check FAILs. *)
    exit (C2c_doctor_relay.run ~json)
  end else if check_rebase_base then begin
    let git_dir = match git_repo_toplevel () with
      | None ->
          Printf.eprintf "error: must run from inside the c2c git repo.\n%!";
          exit 1
      | Some d -> d
    in
    let git cmd = Sys.command (Printf.sprintf "git -C %s %s" (Filename.quote git_dir) cmd) in
    let fetch_rc = git "fetch origin master" in
    if fetch_rc <> 0 then begin
      Printf.eprintf "warning: git fetch origin master returned %d (assuming origin is up-to-date)\n%!" fetch_rc
    end;
    let merge_base_rc = git "merge-base --is-ancestor origin/master HEAD" in
    if merge_base_rc = 0 then begin
      Printf.printf "BASE OK\n%!";
      exit 0
    end else begin
      Printf.printf "STALE — run: git rebase origin/master\n%!";
      exit 1
    end
  end else if install_freshness then begin
    (* Pattern 18: check if origin/master has commits HEAD is missing.
       Skip check if on master or origin/master (canonical branch = always current). *)
    let branch_name = match C2c_worktree.current_branch () with
      | None ->
          Printf.eprintf "error: cannot determine current branch (detached HEAD?)\n%!";
          exit 1
      | Some b -> b
    in
    if branch_name = "master" || branch_name = "origin/master" then begin
      Printf.printf "FRESH (on %s — always current with origin)\n%!" branch_name;
      exit 0
    end;
    let fetch_rc = Sys.command "git fetch origin master" in
    if fetch_rc <> 0 then
      Printf.eprintf "warning: git fetch origin master returned %d (assuming origin is up-to-date)\n%!" fetch_rc;
    let behind_count =
      try
        let ic = Unix.open_process_in "git rev-list --count HEAD..origin/master" in
        let count_s = input_line ic in
        let () = close_in ic in
        int_of_string (String.trim count_s)
      with _ -> 0
    in
    if behind_count > 0 then begin
      Printf.printf "BEHIND — origin/master is %d commit(s) ahead of HEAD.\n%!" behind_count;
      exit 1
    end else begin
      Printf.printf "FRESH\n%!";
      exit 0
    end
  end else
    let args = [] |> (if summary then fun l -> "--summary" :: l else Fun.id)
                |> (if json then fun l -> "--json" :: l else Fun.id) in
    match git_repo_toplevel () with
    | None ->
        (* Outside a c2c git repo: run what we can without repo context.
           Honor --json: emit a single valid JSON document describing the
           sub-checks that work without a repo (B021). *)
        let broker_root_str = C2c_utils.resolve_broker_root () in
        let alias_opt = C2c_utils.alias_from_env_only () in
        let sched_r =
          match alias_opt with
          | Some alias -> Some (C2c_doctor_schedule.scan_schedules_dir alias)
          | None -> None
        in
        let hooks_r = C2c_doctor_hooks.check () in
        let codex_delivery_r = C2c_doctor_hooks.codex_delivery_report () in
        (* B268: cache-only "newer release available" for degraded doctor. *)
        let update_latest =
          try C2c_changelog.latest_known_newer ~broker_root:broker_root_str ()
          with _ -> None
        in
        if json then begin
          let update_fields =
            C2c_changelog.update_status_json ~broker_root:broker_root_str ()
          in
          print_json
            (`Assoc ([
              ("degraded", `Bool true);
              ("reason", `String "not in c2c git repo");
              ("broker_root", `String broker_root_str);
              ("alias", match alias_opt with Some a -> `String a | None -> `Null);
              ("schedules",
                (match sched_r with
                 | Some r -> C2c_doctor_schedule.to_json r
                 | None -> `Null));
              ("hooks", C2c_doctor_hooks.to_json hooks_r);
              ("codex_delivery",
               C2c_doctor_hooks.codex_delivery_report_to_json codex_delivery_r);
            ] @ update_fields))
        end else begin
          Printf.printf "c2c doctor (degraded — not in c2c git repo)\n\n";
          Printf.printf "  broker root: %s\n" broker_root_str;
          (match alias_opt with
           | Some a -> Printf.printf "  alias: %s\n" a
           | None -> Printf.printf "  alias: (not set — C2C_MCP_AUTO_REGISTER_ALIAS not found)\n");
          (match update_latest with
           | Some latest ->
               Printf.printf
                 "  update: newer release %s available (you're on %s) — run `c2c self-update`\n"
                 latest Version.version
           | None -> ());
          Printf.printf "\n";
          (* Schedule check — works without repo *)
          (match sched_r with
           | Some r -> C2c_doctor_schedule.pp_human r
           | None ->
               Printf.printf "=== Schedule check ===\n\nSkipped (no alias set).\n\n");
          (* Hooks check — works without repo *)
          C2c_doctor_hooks.pp_human hooks_r;
          (* Codex delivery-mode classification (T005) — works without repo *)
          C2c_doctor_hooks.pp_codex_delivery_human codex_delivery_r;
          Printf.printf "\nNote: repo-specific checks (push-pending, worktree status, binary staleness, docs drift)\n";
          Printf.printf "are skipped outside the c2c source repo. Run 'c2c doctor' from within the repo for full output.\n"
        end;
    | Some toplevel ->
        let script = toplevel // "scripts" // "c2c-doctor.sh" in
        if not (Sys.file_exists script) then begin
          Printf.eprintf "error: scripts/c2c-doctor.sh not found.\n%!";
          exit 1
        end;
        Unix.execvp "bash" (Array.of_list (["bash"; script] @ args))

let doctor_docs_drift = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "docs-drift"
       ~doc:"Audit CLAUDE.md for stale repo paths, unregistered c2c \
             commands, wrong GitHub org URLs, and deprecated Python script \
             references. Use --warn-only inside `c2c doctor` rollups.")
    C2c_docs_drift.docs_drift_cmd

(* --- subcommand: doctor monitor-leak (Phase C #288) --- *)
let monitor_leak_cmd =
  let open Cmdliner in
  let threshold =
    Arg.(value & opt int 1 & info ["threshold"; "t"]
           ~docv:"N"
           ~doc:"Warn if any alias has more than N monitor processes (default: 1).")
  in
  let json = Arg.(value & flag & info ["json"] ~doc:"Output machine-readable JSON.") in
  let+ threshold = threshold
  and+ json = json in
  let broker_root = resolve_broker_root () in
  let lock_dir = broker_root // ".monitor-locks" in
  let get_lock_aliases () =
    if not (Sys.file_exists lock_dir) then []
    else
      try
        Array.to_list (Sys.readdir lock_dir)
        |> List.filter (fun f -> Filename.check_suffix f ".lock")
        |> List.map (fun f -> String.sub f 0 (String.length f - 5)) (* strip .lock *)
      with _ -> []
  in
  let lock_aliases = get_lock_aliases () in
  (* For each lock, also check if the monitor process is actually alive.
     A stale lock (crash/kill) means the process is gone — report it. *)
  let cmd = Printf.sprintf "pgrep -af 'c2c monitor --alias' 2>/dev/null | grep -v pgrep || true" in
  let ic = Unix.open_process_in cmd in
  let raw =
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec read_lines acc =
        try read_lines ((input_line ic) :: acc)
        with End_of_file -> List.rev acc
      in read_lines [])
  in
  (* Parse pgrep output: "PID /path/to/c2c monitor --alias alias". Count per alias. *)
  let count_per_alias =
    let counts : (string, int ref) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun line ->
      let parts = String.split_on_char ' ' line in
      (* last non-empty part is the alias *)
      let alias = List.filter ((<>) "") parts |> List.rev |> function
        | alias :: _ -> alias
        | [] -> ""
      in
      if alias <> "" then begin
        let r = try Hashtbl.find counts alias with Not_found ->
          let r = ref 0 in Hashtbl.add counts alias r; r
        in
        incr r
      end
    ) raw;
    counts
  in
  let threshold_exceeded =
    List.filter (fun alias ->
      let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
      count > threshold
    ) lock_aliases
  in
  if json then begin
    let obj = `Assoc [
      "monitor_leak", `Bool (List.length threshold_exceeded > 0);
      "threshold", `Int threshold;
      "lock_aliases", `List (List.map (fun a -> `String a) lock_aliases);
      "counts", `Assoc (
        Hashtbl.fold (fun alias count acc ->
          (alias, `Int !count) :: acc
        ) count_per_alias []);
      "exceeded", `List (List.map (fun a -> `String a) threshold_exceeded);
    ] in
    print_string (Yojson.Safe.to_string obj);
    print_newline ()
  end else begin
    if List.length lock_aliases = 0 then
      Printf.printf "✓ No monitor locks found (no active monitors with circuit-breaker protection)\n"
    else begin
      Printf.printf "Monitor locks active for %d alias(es):\n" (List.length lock_aliases);
      List.iter (fun alias ->
        let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
        let status = if count > threshold then "⚠ LEAK" else "✓" in
        Printf.printf "  %s alias=%s process_count=%d lock_exists=true\n" status alias count
      ) lock_aliases;
      if List.length threshold_exceeded > 0 then begin
        Printf.eprintf "\n⚠ WARNING: %d alias(es) exceeded threshold (count > %d):\n" (List.length threshold_exceeded) threshold;
        List.iter (fun alias ->
          let count = !(try Hashtbl.find count_per_alias alias with Not_found -> ref 0) in
          Printf.eprintf "  - %s: %d processes (threshold=%d)\n" alias count threshold
        ) threshold_exceeded;
        Printf.eprintf "  Run: pkill -f 'c2c monitor --alias <alias>'\n"
      end
    end
  end;
  exit (if List.length threshold_exceeded > 0 then 1 else 0)

let monitor_leak = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "monitor-leak"
       ~doc:"Check for duplicate c2c monitor processes per alias (Phase C #288). \
             Exits 1 if any alias has more than --threshold monitor processes.")
    monitor_leak_cmd

(* --- subcommand: doctor relay-mesh (#330 V2) ---

   Diagnostic for cross-host relay-mesh state. Reports:
     - Local relay-name configuration (env vars + recommendation if unset).
     - Sender/session env vars relevant to cross-host send path.
     - Recent broker.log entries that reference cross-host outcomes
       (peer_pass_reject / handoff_attempt / cross_host_*; surfaced
       as raw JSON lines for the operator to scan).
     - If `--relay-url URL` is passed (or `C2C_RELAY_URL` env is set),
       hits the relay's `/health` endpoint and surfaces relay-side fields.
     - Recommendations when self_host is unset locally.

   Companion to galaxy-coder's #310 mesh test compose and cedar's #330 V1
   relay-forwarder unit tests; this V2 surface is the operator-side
   visibility for the same topology. *)

let relay_mesh_cmd =
  let open Cmdliner in
  let relay_url_flag =
    Arg.(value & opt (some string) None & info ["relay-url"] ~docv:"URL"
           ~doc:"Optional relay HTTP URL. When set, doctor will hit \
                 <URL>/health and surface relay-side fields (self_host, \
                 storage backend). Defaults to C2C_RELAY_URL env var.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output a single JSON object instead of human-readable text.")
  in
  let log_lines_flag =
    Arg.(value & opt int 50 & info ["log-lines"] ~docv:"N"
           ~doc:"Tail this many lines from broker.log when scanning for \
                 cross-host events (default 50, max 500).")
  in
  let+ relay_url = relay_url_flag
  and+ as_json = json_flag
  and+ log_lines = log_lines_flag in
  let log_lines = max 1 (min 500 log_lines) in
  (* --- gather local state --- *)
  let env_or_dash k =
    match Sys.getenv_opt k with
    | Some v when String.trim v <> "" -> String.trim v
    | _ -> ""
  in
  let relay_name_local = env_or_dash "C2C_RELAY_NAME" in
  let relay_url_resolved =
    match relay_url with
    | Some u -> Some u
    | None ->
      let v = env_or_dash "C2C_RELAY_URL" in
      if v = "" then None else Some v
  in
  let sender_alias = env_or_dash "C2C_MCP_AUTO_REGISTER_ALIAS" in
  let session_id = env_or_dash "C2C_MCP_SESSION_ID" in
  let broker_root =
    try C2c_utils.resolve_broker_root () with _ -> "<unresolved>"
  in
  let log_path = Filename.concat broker_root "broker.log" in
  (* Tail last N lines and filter for cross-host hints. *)
  let tail_lines path n =
    if not (Sys.file_exists path) then []
    else
      try
        let ic = open_in path in
        let all = ref [] in
        (try
           while true do
             all := input_line ic :: !all
           done
         with End_of_file -> ());
        close_in_noerr ic;
        (* [!all] is newest-first (each line cons'd onto head). Take the
           first [n] elements — those are the [n] newest. Then reverse
           to chronological order for human display. Pre-#330-V2-fix
           this used a buggy [drop_n drop (List.rev (List.rev !all))]
           that returned the OLDEST n lines instead — slate's review
           caught it on a >50-line broker.log repro. *)
        let rec take k xs = match xs, k with
          | _, 0 | [], _ -> []
          | x :: tl, k -> x :: take (k - 1) tl
        in
        List.rev (take n !all)
      with _ -> []
  in
  let recent = tail_lines log_path log_lines in
  let cross_host_hits =
    List.filter (fun line ->
      let l = String.lowercase_ascii line in
      let contains s =
        let rec scan i =
          if i + String.length s > String.length l then false
          else if String.sub l i (String.length s) = s then true
          else scan (i + 1)
        in scan 0
      in
      contains "cross_host" || contains "cross-host"
      || contains "remote_outbox" || contains "alias@"
    ) recent
  in
  (* --- optional relay /health probe --- *)
  let relay_health =
    match relay_url_resolved with
    | None -> None
    | Some url ->
      try
        let client = Relay.Relay_client.make url in
        Some (Lwt_main.run (Relay.Relay_client.health client))
      with _ -> None
  in
  (* --- emit --- *)
  if as_json then begin
    let kv = [
      ("ok", `Bool true);
      ("relay_name_local", `String relay_name_local);
      ("relay_url", (match relay_url_resolved with Some s -> `String s | None -> `Null));
      ("sender_alias", `String sender_alias);
      ("session_id", `String session_id);
      ("broker_root", `String broker_root);
      ("broker_log_exists", `Bool (Sys.file_exists log_path));
      ("cross_host_log_hits", `Int (List.length cross_host_hits));
      ("cross_host_recent", `List (List.map (fun s -> `String s) cross_host_hits));
      ("relay_health", (match relay_health with Some j -> j | None -> `Null));
      ("self_host_unset_recommendation",
       `Bool (relay_name_local = "" &&
              (match relay_health with
               | Some (`Assoc fs) ->
                 (match List.assoc_opt "self_host" fs with
                  | Some (`String s) -> String.trim s = ""
                  | _ -> true)
               | _ -> true)));
    ] in
    print_endline (Yojson.Safe.to_string (`Assoc kv));
    exit 0
  end;
  (* Human output *)
  Printf.printf "c2c doctor relay-mesh (#330 V2)\n\n";
  Printf.printf "Local broker:\n";
  Printf.printf "  broker_root           = %s\n" broker_root;
  Printf.printf "  broker.log present    = %s\n" (if Sys.file_exists log_path then "yes" else "no (broker has not logged yet)");
  Printf.printf "\nLocal env:\n";
  Printf.printf "  C2C_RELAY_NAME        = %s\n"
    (if relay_name_local = "" then "(unset)" else relay_name_local);
  Printf.printf "  C2C_RELAY_URL         = %s\n"
    (match relay_url_resolved with Some s -> s | None -> "(unset)");
  Printf.printf "  C2C_MCP_AUTO_REGISTER_ALIAS = %s\n"
    (if sender_alias = "" then "(unset)" else sender_alias);
  Printf.printf "  C2C_MCP_SESSION_ID    = %s\n"
    (if session_id = "" then "(unset)" else session_id);
  (match relay_health with
   | None ->
     Printf.printf "\nRelay health probe:\n  skipped (no --relay-url; set C2C_RELAY_URL or pass --relay-url URL)\n"
   | Some j ->
     Printf.printf "\nRelay health probe:\n  %s\n" (Yojson.Safe.pretty_to_string j));
  Printf.printf "\nCross-host activity in broker.log (last %d lines):\n" log_lines;
  if cross_host_hits = [] then
    Printf.printf "  (no entries matching cross_host / cross-host / remote_outbox / alias@)\n"
  else
    List.iter (fun s -> Printf.printf "  %s\n" s) cross_host_hits;
  Printf.printf "\nRecommendations:\n";
  let any_rec = ref false in
  if relay_name_local = "" then begin
    any_rec := true;
    Printf.printf "  * C2C_RELAY_NAME is unset locally. The relay's --relay-name flag\n";
    Printf.printf "    is set at `c2c relay serve` startup, not in broker env. To verify\n";
    Printf.printf "    the live relay's self_host, run:\n";
    Printf.printf "      c2c relay status --relay-url <URL>\n"
  end;
  (match relay_url_resolved, relay_health with
   | Some url, None ->
     any_rec := true;
     Printf.printf "  * --relay-url=%s is set but /health probe failed. Check the relay\n" url;
     Printf.printf "    is running and the URL is reachable.\n"
   | _ -> ());
  if cross_host_hits = [] && Sys.file_exists log_path then begin
    Printf.printf "  * No cross-host events in last %d log lines — either no cross-host\n" log_lines;
    Printf.printf "    activity yet, or broker.log rotated past them. Bump --log-lines if needed.\n"
  end;
  if not !any_rec then Printf.printf "  (none — everything looks plausible)\n";
  exit 0

let relay_mesh = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "relay-mesh"
       ~doc:"Diagnose cross-host relay-mesh state (#330 V2). Reports local \
             relay-name config, sender/session env, recent cross-host \
             broker.log entries, and optionally probes a relay /health URL.")
    relay_mesh_cmd

(* --- subcommand: doctor relay-pin-status -----------------------------------

   Operator visibility into the broker's TOFU pin store
   ([<broker_root>/relay_pins.json]). One flat row per alias with the
   pinned Ed25519 (CRIT-1 Slice B), pinned X25519, and pinned
   min-observed-envelope-version (Slice B-min-version). Supports
   `--alias <a>` to filter and `--json` for machine consumption.

   This is read-only — no write surface; the only way to mutate the pin
   store is through the broker's existing pin paths (operator-attested
   `pin_rotate`, `pin_x25519_sync` / `pin_ed25519_sync` on receive,
   nuclear delete-relay-pins.json). *)

let relay_pin_status_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Filter to a single alias.")
  in
  let json_flag =
    Arg.(value & flag & info ["json"]
           ~doc:"Output JSON instead of a flat ASCII table.")
  in
  let truncate_flag =
    Arg.(value & opt int 14 & info ["truncate"] ~docv:"N"
           ~doc:"Truncate b64 pubkeys to N chars in the table (default 14). \
                 Set 0 to disable truncation. Ignored under --json (full b64 \
                 always emitted).")
  in
  let+ alias_filter = alias_flag
  and+ as_json = json_flag
  and+ truncate = truncate_flag in
  let truncate = max 0 truncate in
  let broker_root =
    try C2c_utils.resolve_broker_root () with _ -> "<unresolved>"
  in
  let pins_path = Filename.concat broker_root "relay_pins.json" in
  let json =
    if not (Sys.file_exists pins_path) then `Assoc []
    else
      try Yojson.Safe.from_file pins_path
      with Yojson.Json_error _ -> `Assoc []
  in
  let section name =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some (`Assoc entries) -> entries
       | _ -> [])
    | _ -> []
  in
  let ed25519 = section "ed25519" in
  let x25519 = section "x25519" in
  let min_versions = section "min_observed_envelope_versions" in
  (* Union of aliases across all three sections. *)
  let aliases =
    let collect acc xs = List.fold_left (fun a (k, _) -> k :: a) acc xs in
    let raw = collect (collect (collect [] ed25519) x25519) min_versions in
    List.sort_uniq String.compare raw
  in
  let aliases = match alias_filter with
    | None -> aliases
    | Some target -> List.filter (fun a -> a = target) aliases
  in
  let lookup_str entries k =
    match List.assoc_opt k entries with
    | Some (`String s) -> Some s
    | _ -> None
  in
  let lookup_int entries k =
    match List.assoc_opt k entries with
    | Some (`Int n) -> Some n
    | Some (`Intlit s) -> (try Some (int_of_string s) with _ -> None)
    | _ -> None
  in
  let truncate_b64 s =
    if truncate = 0 || String.length s <= truncate then s
    else (String.sub s 0 truncate) ^ "+"
  in
  let dash_or s = match s with Some v -> v | None -> "-" in
  if as_json then begin
    let rows =
      List.map (fun a ->
        let ed = lookup_str ed25519 a in
        let x = lookup_str x25519 a in
        let mv = lookup_int min_versions a in
        `Assoc [
          ("alias", `String a);
          ("ed25519_b64", (match ed with Some s -> `String s | None -> `Null));
          ("x25519_b64", (match x with Some s -> `String s | None -> `Null));
          ("min_observed_envelope_version",
            (match mv with Some n -> `Int n | None -> `Null));
        ]) aliases
    in
    let envelope = `Assoc [
      ("broker_root", `String broker_root);
      ("relay_pins_path", `String pins_path);
      ("relay_pins_exists", `Bool (Sys.file_exists pins_path));
      ("alias_count", `Int (List.length aliases));
      ("pins", `List rows);
    ] in
    print_endline (Yojson.Safe.pretty_to_string envelope);
    exit 0
  end else begin
    Printf.printf "c2c doctor relay-pin-status\n\n";
    Printf.printf "broker_root: %s\n" broker_root;
    Printf.printf "relay_pins:  %s%s\n\n" pins_path
      (if Sys.file_exists pins_path then "" else "  (file missing — empty store)");
    if aliases = [] then begin
      (match alias_filter with
       | Some a -> Printf.printf "  no pins for alias %s\n" a
       | None -> Printf.printf "  no pins recorded yet\n");
      exit 0
    end;
    (* Column widths *)
    let alias_w =
      List.fold_left (fun w a -> max w (String.length a)) 5 aliases
    in
    let pubkey_w = if truncate = 0 then 44 else truncate + 1 in
    Printf.printf "%-*s  %-*s  %-*s  %5s\n"
      alias_w "ALIAS" pubkey_w "ED25519" pubkey_w "X25519" "MIN_V";
    Printf.printf "%s\n"
      (String.make (alias_w + pubkey_w + pubkey_w + 5 + 6) '-');
    List.iter (fun a ->
      let ed = lookup_str ed25519 a in
      let x = lookup_str x25519 a in
      let mv = lookup_int min_versions a in
      let ed_str = match ed with Some s -> truncate_b64 s | None -> "-" in
      let x_str = match x with Some s -> truncate_b64 s | None -> "-" in
      let mv_str = match mv with Some n -> string_of_int n | None -> "-" in
      Printf.printf "%-*s  %-*s  %-*s  %5s\n"
        alias_w a pubkey_w ed_str pubkey_w x_str (dash_or (Some mv_str))
    ) aliases;
    Printf.printf "\n%d alias%s pinned.\n"
      (List.length aliases)
      (if List.length aliases = 1 then "" else "es");
    Printf.printf "(Use --truncate 0 for full b64 pubkeys, or --json for machine output.)\n";
    exit 0
  end

let relay_pin_status = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "relay-pin-status"
       ~doc:"Operator visibility into the relay TOFU pin store \
             (relay_pins.json). Flat table per alias: pinned Ed25519, \
             X25519, and min-observed-envelope-version. Read-only.")
    relay_pin_status_cmd

(* --- subcommand: doctor delivery-mode (#307a) --- *)

let delivery_mode_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Recipient alias whose archive to histogram. Defaults to the \
                 caller's MCP-session alias (C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let since_flag =
    Arg.(value & opt (some string) None & info ["since"] ~docv:"DUR"
           ~doc:"Window of time, e.g. 1h, 30m, 7d. Default: 24h when --last \
                 is also unset.")
  in
  let last_flag =
    Arg.(value & opt (some int) None & info ["last"] ~docv:"N"
           ~doc:"Window of last N most-recent messages. Combines with --since \
                 (--since wins when both bound the result).")
  in
  let json_flag = Arg.(value & flag & info ["json"]
                         ~doc:"Output machine-readable JSON.") in
  let+ alias_opt = alias_flag
  and+ since_opt = since_flag
  and+ last_opt = last_flag
  and+ json_out = json_flag in
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
        | Some a when String.trim a <> "" -> String.trim a
        | _ ->
            Printf.eprintf "error: --alias is required (no \
                            C2C_MCP_AUTO_REGISTER_ALIAS in env)\n%!";
            exit 1
  in
  let since_str_default =
    match since_opt, last_opt with
    | Some _, _ | None, Some _ -> since_opt
    | None, None -> Some "24h"
  in
  let min_ts =
    match since_str_default with
    | None -> None
    | Some s ->
        match C2c_stats.parse_duration s with
        | Some secs -> Some (Unix.gettimeofday () -. secs)
        | None ->
            Printf.eprintf "error: --since must be Nm|Nh|Nd (got %S)\n%!" s;
            exit 1
  in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let session_id =
    match C2c_mcp.Broker.list_registrations broker
          |> List.find_opt (fun r -> r.C2c_mcp.alias = alias) with
    | Some reg -> reg.C2c_mcp.session_id
    | None ->
        Printf.eprintf "error: alias %S not registered\n%!" alias;
        exit 1
  in
  let result =
    C2c_mcp.Broker.delivery_mode_histogram broker ~session_id
      ?min_ts ?last_n:last_opt ()
  in
  let total = result.C2c_mcp.Broker.dmh_total in
  let push = result.C2c_mcp.Broker.dmh_push in
  let poll = result.C2c_mcp.Broker.dmh_poll in
  let pct n =
    if total = 0 then 0.0
    else 100.0 *. float_of_int n /. float_of_int total
  in
  if json_out then begin
    let window =
      let base = [("messages", `Int total)] in
      let with_since = match since_str_default with
        | Some s -> ("since", `String s) :: base
        | None -> base
      in
      let with_last = match last_opt with
        | Some n -> ("last", `Int n) :: with_since
        | None -> with_since
      in
      `Assoc with_last
    in
    let by_sender =
      `List (List.map (fun s ->
          `Assoc
            [ ("alias", `String s.C2c_mcp.Broker.dms_alias)
            ; ("total", `Int s.dms_total)
            ; ("push", `Int s.dms_push)
            ; ("poll", `Int s.dms_poll)
            ])
          result.dmh_by_sender)
    in
    let obj = `Assoc
      [ ("alias", `String alias)
      ; ("window", window)
      ; ("counts", `Assoc
            [ ("push_intent", `Int push)
            ; ("poll_only", `Int poll)
            ])
      ; ("by_sender", by_sender)
      ; ("caveats", `List
            [ `String "sender_intent_not_actuals"
            ; `String "ephemeral_excluded"
            ])
      ]
    in
    print_endline (Yojson.Safe.to_string obj)
  end else begin
    let window_label =
      match since_str_default, last_opt with
      | Some s, Some n -> Printf.sprintf "last %s, capped to %d" s n
      | Some s, None -> Printf.sprintf "last %s" s
      | None, Some n -> Printf.sprintf "last %d messages" n
      | None, None -> "all archived"
    in
    Printf.printf "Delivery mode for %s (%s, %d archived messages)\n\n"
      alias window_label total;
    Printf.printf "Push intent (deferrable=false): %5d  (%5.1f%%)\n"
      push (pct push);
    Printf.printf "Poll-only (deferrable=true):    %5d  (%5.1f%%)\n\n"
      poll (pct poll);
    if result.dmh_by_sender = [] then
      Printf.printf "(no senders in window)\n"
    else begin
      Printf.printf "By sender:\n";
      Printf.printf "  %-22s %6s  %6s  %5s  %6s\n"
        "ALIAS" "TOTAL" "PUSH" "POLL" "POLL%";
      List.iter (fun s ->
          let p =
            if s.C2c_mcp.Broker.dms_total = 0 then 0.0
            else 100.0 *. float_of_int s.dms_poll
                 /. float_of_int s.dms_total
          in
          Printf.printf "  %-22s %6d  %6d  %5d  %5.1f%%\n"
            s.dms_alias s.dms_total s.dms_push s.dms_poll p)
        result.dmh_by_sender
    end;
    Printf.printf "\nNOTE: counts measure sender intent (deferrable flag), \
                   not which delivery path actually surfaced the message. \
                   Ephemeral messages (#284) are not archived and not \
                   counted. See #303 design doc for the deferrable contract.\n"
  end

let delivery_mode = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "delivery-mode"
       ~doc:"Histogram of an alias's recent inbox by deferrable flag (#307a). \
             Counts measure sender intent, not delivery actuals.")
    delivery_mode_cmd

(* --- subcommand: doctor tags (#392 slice 5) ----------------------------- *)

let tags_doctor_cmd =
  let open Cmdliner in
  let alias_flag =
    Arg.(value & opt (some string) None & info ["alias"; "a"] ~docv:"ALIAS"
           ~doc:"Recipient alias whose archive to histogram. Defaults to the \
                 caller's MCP-session alias (C2C_MCP_AUTO_REGISTER_ALIAS).")
  in
  let since_flag =
    Arg.(value & opt (some string) None & info ["since"] ~docv:"DUR"
           ~doc:"Window of time, e.g. 1h, 30m, 7d. Default: 24h when --last \
                 is also unset.")
  in
  let last_flag =
    Arg.(value & opt (some int) None & info ["last"] ~docv:"N"
           ~doc:"Window of last N most-recent messages. Combines with --since \
                 (--since wins when both bound the result).")
  in
  let json_flag = Arg.(value & flag & info ["json"]
                         ~doc:"Output machine-readable JSON.") in
  let+ alias_opt = alias_flag
  and+ since_opt = since_flag
  and+ last_opt = last_flag
  and+ json_out = json_flag in
  let alias =
    match alias_opt with
    | Some a -> a
    | None ->
        match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
        | Some a when String.trim a <> "" -> String.trim a
        | _ ->
            Printf.eprintf "error: --alias is required (no \
                            C2C_MCP_AUTO_REGISTER_ALIAS in env)\n%!";
            exit 1
  in
  let since_str_default =
    match since_opt, last_opt with
    | Some _, _ | None, Some _ -> since_opt
    | None, None -> Some "24h"
  in
  let min_ts =
    match since_str_default with
    | None -> None
    | Some s ->
        match C2c_stats.parse_duration s with
        | Some secs -> Some (Unix.gettimeofday () -. secs)
        | None ->
            Printf.eprintf "error: --since must be Nm|Nh|Nd (got %S)\n%!" s;
            exit 1
  in
  let root = resolve_broker_root () in
  let broker = C2c_mcp.Broker.create ~root in
  let session_id =
    match C2c_mcp.Broker.list_registrations broker
          |> List.find_opt (fun r -> r.C2c_mcp.alias = alias) with
    | Some reg -> reg.C2c_mcp.session_id
    | None ->
        Printf.eprintf "error: alias %S not registered\n%!" alias;
        exit 1
  in
  let result =
    C2c_mcp.Broker.tag_histogram broker ~session_id
      ?min_ts ?last_n:last_opt ()
  in
  let total = result.C2c_mcp.Broker.th_total in
  let fail = result.C2c_mcp.Broker.th_fail in
  let blocking = result.C2c_mcp.Broker.th_blocking in
  let urgent = result.C2c_mcp.Broker.th_urgent in
  let untagged = result.C2c_mcp.Broker.th_untagged in
  let pct n =
    if total = 0 then 0.0
    else 100.0 *. float_of_int n /. float_of_int total
  in
  if json_out then begin
    let window =
      let base = [("messages", `Int total)] in
      let with_since = match since_str_default with
        | Some s -> ("since", `String s) :: base
        | None -> base
      in
      let with_last = match last_opt with
        | Some n -> ("last", `Int n) :: with_since
        | None -> with_since
      in
      `Assoc with_last
    in
    let by_sender =
      `List (List.map (fun s ->
          `Assoc
            [ ("alias", `String s.C2c_mcp.Broker.ts_alias)
            ; ("total", `Int s.ts_total)
            ; ("fail", `Int s.ts_fail)
            ; ("blocking", `Int s.ts_blocking)
            ; ("urgent", `Int s.ts_urgent)
            ; ("untagged", `Int s.ts_untagged)
            ])
          result.th_by_sender)
    in
    let obj = `Assoc
      [ ("alias", `String alias)
      ; ("window", window)
      ; ("counts", `Assoc
            [ ("fail", `Int fail)
            ; ("blocking", `Int blocking)
            ; ("urgent", `Int urgent)
            ; ("untagged", `Int untagged)
            ])
      ; ("by_sender", by_sender)
      ; ("caveats", `List
            [ `String "sender_intent_not_actuals"
            ; `String "tag_recovered_from_body_prefix"
            ; `String "ephemeral_excluded"
            ])
      ]
    in
    print_endline (Yojson.Safe.to_string obj)
  end else begin
    let window_label =
      match since_str_default, last_opt with
      | Some s, Some n -> Printf.sprintf "last %s, capped to %d" s n
      | Some s, None -> Printf.sprintf "last %s" s
      | None, Some n -> Printf.sprintf "last %d messages" n
      | None, None -> "all archived"
    in
    Printf.printf "Tag histogram for %s (%s, %d archived messages)\n\n"
      alias window_label total;
    Printf.printf "🔴 FAIL:      %5d  (%5.1f%%)\n" fail (pct fail);
    Printf.printf "⛔ BLOCKING:  %5d  (%5.1f%%)\n" blocking (pct blocking);
    Printf.printf "⚠️  URGENT:    %5d  (%5.1f%%)\n" urgent (pct urgent);
    Printf.printf "untagged:    %5d  (%5.1f%%)\n\n" untagged (pct untagged);
    if result.th_by_sender = [] then
      Printf.printf "(no senders in window)\n"
    else begin
      Printf.printf "By sender:\n";
      Printf.printf "  %-22s %6s  %5s  %8s  %6s  %6s\n"
        "ALIAS" "TOTAL" "FAIL" "BLOCKING" "URGENT" "(none)";
      List.iter (fun s ->
          Printf.printf "  %-22s %6d  %5d  %8d  %6d  %6d\n"
            s.C2c_mcp.Broker.ts_alias s.ts_total s.ts_fail s.ts_blocking
            s.ts_urgent s.ts_untagged)
        result.th_by_sender
    end;
    Printf.printf "\nNOTE: counts measure sender intent (#392 body-prefix \
                   at archive-write time), not delivery actuals or \
                   recipient acknowledgement. Ephemeral messages (#284) \
                   are not archived and not counted. See #392 design doc \
                   for the tag contract.\n"
  end

let tags_doctor = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "tags"
       ~doc:"Histogram of an alias's recent inbox by #392 tag (fail / \
             blocking / urgent / untagged). Counts measure sender intent, \
             not delivery actuals. Mirror of `c2c doctor delivery-mode`.")
    tags_doctor_cmd

(* --- subcommand: doctor deliver-service (#35 phase 1 stub) --- *)
let deliver_service_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ]
      ~doc:"Machine-readable JSON (alive/dead + pid when known).")
  in
  let+ json = json in
  let status = C2c_deliver_managed.supervisor_status () in
  if json then
    print_json (C2c_deliver_managed.supervisor_status_to_json status)
  else
    C2c_deliver_managed.pp_supervisor_status_human status;
  (* Non-zero when dead so scripts can gate on it; phase 1 is informational
     only — adapters are not required yet. *)
  match status with
  | Alive _ -> ()
  | Dead _ -> exit 1

let deliver_service_doctor = Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "deliver-service"
       ~doc:"#35 phase 1: report whether the machine-wide deliver-service \
             supervisor is alive. Scaffold only — no adapter health yet.")
    deliver_service_cmd

let doctor = Cmdliner.Cmd.group
    ~default:doctor_cmd
    (Cmdliner.Cmd.info "doctor"
       ~doc:"Health snapshot + push-pending analysis (for Max / human operators).")
    [ doctor_docs_drift; monitor_leak; delivery_mode; relay_mesh; relay_pin_status; tags_doctor;
      deliver_service_doctor;
      C2c_opencode_plugin_drift.opencode_plugin_drift_cmd;
      C2c_doctor_cherry_pick_readiness.c2c_doctor_cherry_pick_readiness_cmd;
      C2c_doctor_hooks.c2c_doctor_hooks_cmd;
      C2c_doctor_schedule.c2c_doctor_schedule_cmd ]
