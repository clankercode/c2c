(* c2c_instances_cmd — managed-instance listing, cleanup, and diagnostics. *)

open C2c_cli_helpers
open Cmdliner.Term.Syntax
open C2c_types
open C2c_commands
open C2c_utils

(* --- subcommand: instances ------------------------------------------------ *)

let instances_dir () = C2c_start.instances_dir

(* Relative-time formatter, shared between instances_cmd and dev_status_cmd *)
let age_of ~now (ts : float) =
  let delta = now -. ts in
  if delta < 0.0 then "just now"
  else if delta < 60.0 then Printf.sprintf "%.0fs ago" delta
  else if delta < 3600.0 then Printf.sprintf "%.0fm ago" (delta /. 60.0)
  else if delta < 86400.0 then Printf.sprintf "%.0fh ago" (delta /. 3600.0)
  else Printf.sprintf "%.0fd ago" (delta /. 86400.0)

let list_instance_dirs () =
  let base = instances_dir () in
  if not (Sys.file_exists base) then []
  else begin
    let dirs = Sys.readdir base in
    Array.fold_left (fun acc name ->
      let full = base // name in
      if Sys.is_directory full && Sys.file_exists (full // "config.json") then
        full :: acc
      else acc
    ) [] dirs
  end

type agy_instance_details =
  { ai_session_id : string
  ; ai_ls_address : string option
  ; ai_conversation_id : string option
  ; ai_deliver_watch_status : string
  ; ai_deliver_watch_pid : int option
  }

(* ANTIGRAVITY_LS_ADDRESS is normally a loopback host/port, but treat the
   persisted value as potentially sensitive input. Fail closed: operators
   only need a scheme plus host:port (or host:port alone), never a partially
   stripped malformed URL that might retain a credential. *)
let sanitize_agy_ls_address raw =
  let value = String.trim raw in
  let all_chars predicate string =
    try
      String.iter (fun ch -> if not (predicate ch) then raise Exit) string;
      true
    with Exit -> false
  in
  let is_alnum = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | _ -> false
  in
  let safe_scheme scheme =
    String.length scheme > 0
    && is_alnum scheme.[0]
    && all_chars (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '+' | '-' | '.' -> true
        | _ -> false) scheme
  in
  let safe_host host =
    let safe_label label =
      let length = String.length label in
      length > 0
      && is_alnum label.[0]
      && is_alnum label.[length - 1]
      && all_chars (fun ch -> is_alnum ch || ch = '-') label
    in
    host <> "" && List.for_all safe_label (String.split_on_char '.' host)
  in
  let safe_port port =
    String.length port > 0
    && all_chars (function '0' .. '9' -> true | _ -> false) port
    && match int_of_string_opt port with
       | Some number -> number > 0 && number <= 65535
       | None -> false
  in
  let safe_authority authority =
    let length = String.length authority in
    match String.rindex_opt authority ':' with
    | None -> false
    | Some colon when colon = 0 || colon + 1 >= length -> false
    | Some colon ->
        let host = String.sub authority 0 colon in
        let port = String.sub authority (colon + 1) (length - colon - 1) in
        safe_host host && safe_port port
  in
  let has_forbidden_char =
    not (all_chars (fun ch -> Char.code ch >= 0x20 && Char.code ch <> 0x7f
                             && ch <> '\\') raw)
  in
  if has_forbidden_char || value = "" then None
  else
    match String.index_opt value ':' with
    | Some colon
      when colon + 2 < String.length value
           && String.sub value colon 3 = "://" ->
        let scheme = String.sub value 0 colon in
        let authority =
          String.sub value (colon + 3) (String.length value - colon - 3)
        in
        if safe_scheme scheme && safe_authority authority then Some value else None
    | _ -> if safe_authority value then Some value else None

let read_pid_file path =
  if not (Sys.file_exists path) then None
  else
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        int_of_string_opt (String.trim (input_line ic)))
    with _ -> None

let agy_instance_details name =
  let env = C2c_agy_deliver.read_agy_env name in
  (* Unix.kill 0 and negative PIDs target process groups. A pidfile is an
     individual-process record, so discard those values before liveness is
     checked. *)
  let deliver_watch_pid =
    match read_pid_file (C2c_start.deliver_pid_path name) with
    | Some pid when pid > 0 -> Some pid
    | Some _ | None -> None
  in
  let deliver_watch_status =
    match deliver_watch_pid with
    | Some pid when C2c_start.pid_alive pid -> "running"
    | Some _ -> "stopped"
    | None -> "not-found"
  in
  { ai_session_id = name
  ; ai_ls_address =
      (match env with
       | Some (env : C2c_agy_deliver.agy_env) ->
           sanitize_agy_ls_address env.ls_address
       | None -> None)
  ; ai_conversation_id =
      (match env with
       | Some (env : C2c_agy_deliver.agy_env) -> Some env.conversation_id
       | None -> None)
  ; ai_deliver_watch_status = deliver_watch_status
  ; ai_deliver_watch_pid = deliver_watch_pid
  }

let agy_details_to_json details =
  `Assoc
    [ ("session_id", `String details.ai_session_id)
    ; ("ls_address",
       match details.ai_ls_address with Some s -> `String s | None -> `Null)
    ; ("conversation_id",
       match details.ai_conversation_id with Some s -> `String s | None -> `Null)
    ; ("deliver_watch",
       `Assoc
         [ ("status", `String details.ai_deliver_watch_status)
         ; ("pid",
            match details.ai_deliver_watch_pid with
            | Some pid -> `Int pid
            | None -> `Null)
         ])
    ]

let instances_cmd =
  let prune_older_than =
    Cmdliner.Arg.(
      value
      & opt (some int) None
      & info [ "prune-older-than" ] ~docv:"DAYS"
          ~doc:"Prune stopped instances older than DAYS before listing." )
  in
  let all_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "all"; "a" ]
          ~doc:"Show full archive (zombies + recently-stopped). Default: alive-only.")
  in
  let alive_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "alive" ]
          ~doc:"Explicitly request alive-only view (the default). Useful in scripts that want to assert the filter is on.")
  in
  let+ json = json_flag
  and+ prune_older_than = prune_older_than
  and+ show_all = all_flag
  and+ alive_only = alive_flag in
  let _ = alive_only in (* default already filters; flag is a script-readable assertion *)
  let output_mode = if json then Json else Human in
  let instances_dir = instances_dir () in
  let all_instances = C2c_health_cmd.read_managed_instances () in
  let all_instances =
    match prune_older_than with
    | None -> all_instances
    | Some days ->
        if days < 0 then (
          Printf.eprintf "error: --prune-older-than must be >= 0\n%!";
          exit 1);
        let stale = C2c_health_cmd.prune_stopped_instances_older_than ~days ~instances_dir all_instances in
        if stale <> [] && output_mode = Human then
          Printf.eprintf
            "pruned %d stopped instance(s) older than %d day(s)\n%!"
            (List.length stale) days;
        C2c_health_cmd.read_managed_instances ()
  in
  let total = List.length all_instances in
  let alive_instances =
    List.filter (fun (inst : managed_instance_view) -> inst.mi_status = "running") all_instances
  in
  let alive_count = List.length alive_instances in
  let displayed = if show_all then all_instances else alive_instances in
  let now = Unix.gettimeofday () in
  let instance_to_json (inst : managed_instance_view) : Yojson.Safe.t =
    let fields : (string * Yojson.Safe.t) list =
      [ ("name", `String inst.mi_name)
      ; ("client", `String inst.mi_client)
      ; ("status", `String inst.mi_status)
      ; ("delivery_mode", `String inst.mi_delivery_mode)
      ; ("outer_alive", `Bool (inst.mi_status = "running"))
      ; ("outer_pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
      ; ("tmux_location", match inst.mi_tmux_location with Some s -> `String s | None -> `Null)
      ; ("expected_cwd", match inst.mi_expected_cwd with Some s -> `String s | None -> `Null)
      ]
    in
    let fields = match inst.mi_pid with
      | Some p -> fields @ [ ("pid", `Int p) ]
      | None -> fields
    in
    let fields = match inst.mi_created_at with
      | Some ts -> fields @ [ ("created_at", `String (age_of ~now ts)); ("created_unix", `Float ts) ]
      | None -> fields
    in
    let fields = match inst.mi_role with
      | Some r -> fields @ [ ("role", `String r) ]
      | None -> fields
    in
    let fields =
      if inst.mi_client = "agy" then
        fields @ [ ("agy", agy_details_to_json (agy_instance_details inst.mi_name)) ]
      else fields
    in
    (* T006: app-server-backed codex sessions expose a lifecycle status
       (starting / online-attached / offline / failed-startup) alongside the
       outer-loop status. Shared terminology with help/completions/resume.
       T005: delivery_mode (computed in C2c_health_cmd) uses the same
       vocabulary as `c2c doctor` — "app-server" ONLY while the unit is
       online-attached (healthy remote TUI); starting/failed/offline keep
       the truthful hook-boundary label ("hooks+wake" input-injecting wake /
       "hooks" / "unavailable") with the lifecycle detail in
       app_server_status. Never claim arrival-time delivery when only a hook
       boundary is available. *)
    let fields =
      match C2c_codex_session.status_of_instance
              ~instance_dir:(C2c_start.instance_dir inst.mi_name) with
      | Some st -> fields @ [ ("app_server_status", `String (C2c_codex_session.status_to_string st)) ]
      | None -> fields
    in
    `Assoc fields
  in
  let instances_json = List.map instance_to_json displayed in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
           [ ("alive", `Int alive_count)
           ; ("total", `Int total)
           ; ("filtered", `Bool (not show_all))
           ; ("instances", `List instances_json)
           ])
  | Human ->
      if total = 0 then
        Printf.printf "No managed instances.\n"
      else begin
        if show_all then
          Printf.printf "Managed instances (%d alive / %d total):\n" alive_count total
        else
          Printf.printf "Managed instances (%d alive / %d total; --all for archive):\n"
            alive_count total;
        if displayed = [] then
          Printf.printf "  (none alive — try --all to see the archive)\n"
        else
          List.iter (fun (inst : managed_instance_view) ->
            let pid_str = match inst.mi_pid with Some n -> Printf.sprintf " (pid %d)" n | None -> "" in
            let tmux_str = match inst.mi_tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
            let cwd_str = match inst.mi_expected_cwd with
              | Some c ->
                  let len = String.length c in
                  let display = if len > 18 then "..." ^ String.sub c (len - 18) 18 else c in
                  " {" ^ display ^ "}"
              | None -> ""
            in
            let created_str = match inst.mi_created_at with
              | Some ts -> " created=" ^ age_of ~now ts
              | None -> ""
            in
            let role_str = match inst.mi_role with
              | Some r -> " [" ^ r ^ "]"
              | None -> ""
            in
            let app_server_str =
              match C2c_codex_session.status_of_instance
                      ~instance_dir:(C2c_start.instance_dir inst.mi_name) with
              | Some st -> " app-server=" ^ C2c_codex_session.status_to_string st
              | None -> ""
            in
            let agy_str =
              if inst.mi_client <> "agy" then ""
              else
                let details = agy_instance_details inst.mi_name in
                let optional label = function
                  | Some value -> " " ^ label ^ "=" ^ value
                  | None -> ""
                in
                let watch =
                  match details.ai_deliver_watch_pid with
                  | Some pid ->
                      Printf.sprintf " deliver-watch=%s(pid=%d)"
                        details.ai_deliver_watch_status pid
                  | None ->
                      " deliver-watch=" ^ details.ai_deliver_watch_status
                in
                " session=" ^ details.ai_session_id
                ^ optional "conversation" details.ai_conversation_id
                ^ optional "ls" details.ai_ls_address
                ^ watch
            in
            Printf.printf "  %-20s %-10s %-12s %s%s%s%s%s%s%s%s\n"
              inst.mi_name inst.mi_client inst.mi_status inst.mi_delivery_mode
              pid_str tmux_str cwd_str created_str role_str app_server_str agy_str
          ) displayed
      end

(* --- subcommand: instances clean-stale (#333) -------------------------- *)

(* Protected aliases — the named swarm peers + coordinator + the default
   social room. Operators must opt in to clean these (not exposed in v1). *)
let clean_stale_protected_aliases =
  [ "coordinator1"
  ; "swarm-lounge"
  ; "stanza-coder"
  ; "jungle-coder"
  ; "galaxy-coder"
  ; "lyra-quill"
  ; "test-agent"
  ; "dogfood-hunter"
  ]

(* String matching helpers for ephemeral-test-alias name patterns. *)
let str_starts_with ~prefix s =
  let lp = String.length prefix and ls = String.length s in
  ls >= lp && String.sub s 0 lp = prefix

let str_contains_sub ~needle s =
  let ln = String.length needle and ls = String.length s in
  if ln = 0 then true
  else if ln > ls then false
  else
    let max_i = ls - ln in
    let rec loop i =
      if i > max_i then false
      else if String.sub s i ln = needle then true
      else loop (i + 1)
    in
    loop 0

(* Anything that looks like an ephemeral test alias.
   Mirrors the patterns called out in the #333 spec. *)
let clean_stale_matches_test_pattern name =
  str_starts_with ~prefix:"codex-reset-" name
  || str_starts_with ~prefix:"oc-bootstrap-test" name
  || str_starts_with ~prefix:"eph-review-bot-" name
  || str_starts_with ~prefix:"kimi-wire-ocaml-smoke" name
  || str_starts_with ~prefix:"dogfood-" name
  || str_contains_sub ~needle:"-smoke-" name

(* Most recent mtime among the instance dir's tracked files. We use this as
   a proxy for "last activity" since there is no first-class
   last_activity_ts field on the instance config. *)
let instance_last_activity_ts ~instances_dir name =
  let inst_path = instances_dir // name in
  let candidates =
    [ "config.json"; "outer.pid"; "stderr.log"; "stdout.log"; "tmux.json" ]
    |> List.map (fun f -> inst_path // f)
    |> List.filter Sys.file_exists
  in
  let candidates =
    if candidates = [] && Sys.file_exists inst_path then [inst_path]
    else candidates
  in
  List.fold_left
    (fun acc path ->
       try
         let st = Unix.stat path in
         max acc st.Unix.st_mtime
       with _ -> acc)
    0.0 candidates

(* Determine why an instance is removable, if at all. Returns the list of
   matched criteria (empty = not removable). *)
let clean_stale_classify ~instances_dir ~now (inst : managed_instance_view) =
  let reasons = ref [] in
  (* Criterion 1: dead PID — status reflects Unix.kill(pid, 0) result. *)
  (match inst.mi_pid with
   | Some _ when inst.mi_status <> "running" -> reasons := "dead-pid" :: !reasons
   | _ -> ());
  (* Criterion 2: no recent activity > 24h. Skip for "running" instances —
     a live PID overrides activity heuristics. *)
  if inst.mi_status <> "running" then begin
    let mtime = instance_last_activity_ts ~instances_dir inst.mi_name in
    if mtime > 0.0 && (now -. mtime) > 86400.0 then
      reasons := "no-activity-24h" :: !reasons
  end;
  (* Criterion 3: name matches a known test-alias pattern. *)
  if clean_stale_matches_test_pattern inst.mi_name then
    reasons := "matches-test-pattern" :: !reasons;
  List.rev !reasons

let clean_stale_is_protected name =
  (* #alias-casefold: protected-alias safety guard must compare
     case-insensitively so an instance dir named "Coordinator1" still
     trips the protection that "coordinator1" does. *)
  List.exists
    (fun p ->
      C2c_mcp.Broker.alias_casefold p
      = C2c_mcp.Broker.alias_casefold name)
    clean_stale_protected_aliases

let clean_stale_cmd =
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ]
      ~doc:"List candidates and the criterion each matched; remove nothing.")
  in
  let include_named =
    Cmdliner.Arg.(value & flag & info [ "include-named" ]
      ~doc:"Also consider the named swarm aliases (coordinator1, stanza-coder, …). Off by default.")
  in
  let instances_dir_override =
    Cmdliner.Arg.(
      value
      & opt (some string) None
      & info [ "instances-dir" ] ~docv:"PATH"
        ~doc:"Operate on a specific instances directory (default: ~/.local/share/c2c/instances). Useful for inspecting alternate locations without changing the default."
    )
  in
  let+ json = json_flag
  and+ dry_run = dry_run
  and+ include_named = include_named
  and+ instances_dir_override = instances_dir_override in
  let output_mode = if json then Json else Human in
  (* Override C2C_INSTANCES_DIR for the duration of this command so
     read_managed_instances uses the correct dir. *)
  let instances_dir =
    match instances_dir_override with
    | Some d ->
        Unix.putenv "C2C_INSTANCES_DIR" d;
        d
    | None -> instances_dir ()
  in
  let now = Unix.gettimeofday () in
  let all_instances = C2c_health_cmd.read_managed_instances () in
  (* Candidate = anything with a non-empty reason list AND status != running.
     status="running" is the strongest live signal; never touch it. *)
  let candidates =
    List.filter_map (fun (inst : managed_instance_view) ->
      if inst.mi_status = "running" then None
      else
        let reasons = clean_stale_classify ~instances_dir ~now inst in
        if reasons = [] then None
        else Some (inst, reasons)
    ) all_instances
  in
  let total_candidates = List.length candidates in
  let removable, protected_kept =
    List.partition (fun (inst, _reasons) ->
      include_named || not (clean_stale_is_protected inst.mi_name)
    ) candidates
  in
  let protected_count = List.length protected_kept in
  let removed_aliases =
    if dry_run then []
    else
      List.filter_map (fun ((inst : managed_instance_view), _reasons) ->
        let path = instances_dir // inst.mi_name in
        if Sys.file_exists path then begin
          (try rm_rf path with _ -> ());
          if not (Sys.file_exists path) then Some inst.mi_name
          else None
        end else Some inst.mi_name
      ) removable
  in
  let removed_count = List.length removed_aliases in
  let _removable_aliases = List.map (fun ((i : managed_instance_view), _) -> i.mi_name) removable in
  let protected_aliases = List.map (fun ((i : managed_instance_view), _) -> i.mi_name) protected_kept in
  match output_mode with
  | Json ->
      let candidate_objs =
        List.map (fun ((inst : managed_instance_view), reasons) ->
          `Assoc
            [ ("alias", `String inst.mi_name)
            ; ("status", `String inst.mi_status)
            ; ("pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
            ; ("reasons", `List (List.map (fun r -> `String r) reasons))
            ; ("protected", `Bool (clean_stale_is_protected inst.mi_name && not include_named))
            ])
          candidates
      in
      print_json
        (`Assoc
           [ ("removed", `Int removed_count)
           ; ("candidates_total", `Int total_candidates)
           ; ("protected", `Int protected_count)
           ; ("dry_run", `Bool dry_run)
           ; ("removed_aliases", `List (List.map (fun a -> `String a) removed_aliases))
           ; ("protected_aliases", `List (List.map (fun a -> `String a) protected_aliases))
           ; ("candidates", `List candidate_objs)
           ])
  | Human ->
      if total_candidates = 0 then
        Printf.printf "No stale instances found.\n"
      else begin
        if dry_run then
          Printf.printf "Stale instance candidates (dry-run, no changes):\n"
        else begin
          Printf.printf "Cleaning stale instances:\n";
          Printf.printf "  (use --dry-run first to preview)\n"
        end;
        List.iter (fun ((inst : managed_instance_view), reasons) ->
          let reason_str = String.concat " + " reasons in
          let protected_tag =
            if clean_stale_is_protected inst.mi_name && not include_named
            then "  [PROTECTED: --include-named to override]"
            else ""
          in
          Printf.printf "  %-30s %s%s\n" inst.mi_name reason_str protected_tag
        ) candidates;
        if dry_run then
          Printf.printf "\nWould remove %d of %d candidates (%d protected).\n"
            (List.length removable) total_candidates protected_count
        else
          Printf.printf "\nRemoved %d of %d candidates (%d protected).\n"
            removed_count total_candidates protected_count
      end

let clean_stale_subcmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "clean-stale"
     ~doc:"Remove stale managed-instance directories (dead PIDs, idle >24h, \
           or matching ephemeral test-name patterns). Use --dry-run to preview.")
  clean_stale_cmd

(* --- subcommand: instances gc (B031) -------------------------------------- *)

let instances_gc_cmd =
  let max_age_hours =
    Cmdliner.Arg.(
      value
      & opt int 24
      & info [ "max-age" ] ~docv:"HOURS"
          ~doc:"Remove stopped instances older than HOURS (default: 24).")
  in
  let dry_run =
    Cmdliner.Arg.(value & flag & info [ "dry-run"; "n" ]
      ~doc:"List candidates and their age; remove nothing.")
  in
  let force =
    Cmdliner.Arg.(value & flag & info [ "force"; "f" ]
      ~doc:"Skip confirmation prompt.")
  in
  let+ max_age_hours = max_age_hours
  and+ dry_run = dry_run
  and+ force = force in
  if max_age_hours < 0 then (
    Printf.eprintf "error: --max-age must be >= 0\n%!";
    exit 1);
  let instances_dir = instances_dir () in
  let now = Unix.gettimeofday () in
  let max_age_s = float_of_int max_age_hours *. 3600.0 in
  let all_instances = C2c_health_cmd.read_managed_instances () in
  (* Classify: stopped instances past the max-age threshold *)
  let candidates =
    List.filter_map (fun (inst : managed_instance_view) ->
      if inst.mi_status = "running" then None
      else
        (* Determine age: prefer created_at, fall back to dir mtime *)
        let age_s =
          match inst.mi_created_at with
          | Some created_at -> now -. created_at
          | None ->
              (* Fall back to dir mtime *)
              let inst_path = instances_dir // inst.mi_name in
              try
                let st = Unix.stat inst_path in
                now -. st.Unix.st_mtime
              with _ -> 0.0
        in
        if age_s > max_age_s then
          Some (inst, age_s)
        else None
    ) all_instances
  in
  let total_candidates = List.length candidates in
  if total_candidates = 0 then (
    Printf.printf "No stopped instances older than %dh found.\n" max_age_hours;
    exit 0);
  Printf.printf "Stopped instances older than %dh:\n\n" max_age_hours;
  List.iter (fun ((inst : managed_instance_view), age_s) ->
    let age_h = age_s /. 3600.0 in
    Printf.printf "  %-30s %-10s stopped %s ago\n"
      inst.mi_name inst.mi_client
      (if age_h < 48.0 then Printf.sprintf "%.0fh" age_h
       else Printf.sprintf "%.0fd" (age_h /. 24.0))
  ) candidates;
  Printf.printf "\n%d instance(s) to remove.\n" total_candidates;
  if dry_run then (
    Printf.printf "(dry-run — no changes made)\n";
    exit 0);
  (* Safety confirmation *)
  if not force then begin
    Printf.printf "Remove these instance directories? [y/N] %!";
    let answer = try input_line stdin with End_of_file -> "" in
    if String.lowercase_ascii (String.trim answer) <> "y" then (
      Printf.printf "Aborted.\n";
      exit 0)
  end;
  let removed =
    List.filter_map (fun ((inst : managed_instance_view), _age) ->
      let path = instances_dir // inst.mi_name in
      if Sys.file_exists path then begin
        (try rm_rf path with _ -> ());
        if not (Sys.file_exists path) then Some inst.mi_name
        else None
      end else Some inst.mi_name
    ) candidates
  in
  Printf.printf "Removed %d instance(s).\n" (List.length removed);
  exit 0

let instances_gc_subcmd = Cmdliner.Cmd.v
  (Cmdliner.Cmd.info "gc"
     ~doc:"Remove stopped instances older than a threshold (default: 24h). \
           Use --dry-run to preview; --force to skip confirmation.")
  instances_gc_cmd

let instances = Cmdliner.Cmd.group
  (Cmdliner.Cmd.info "instances"
     ~doc:"List managed c2c instances (alive-only by default; --all for full archive).")
  ~default:instances_cmd
  [ clean_stale_subcmd; instances_gc_subcmd ]

(* --- subcommand: diag ----------------------------------------------------- *)

let diag_cmd =
  let name_arg =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Instance name.")
  in
  let lines_arg =
    Cmdliner.Arg.(value & opt int 50 & info [ "lines"; "n" ] ~docv:"N" ~doc:"Number of stderr tail lines (default: 50).")
  in
  let+ name = name_arg
  and+ lines = lines_arg in
  let inst_dir = instances_dir () // name in
  if not (Sys.file_exists inst_dir) then begin
    Printf.eprintf "error: no instance dir for '%s'. Was it ever started?\n%!" name;
    exit 1
  end;
  (* Print last death record if any *)
  let broker_root = resolve_broker_root () in
  let deaths_path = broker_root // "deaths.jsonl" in
  let last_death =
    if Sys.file_exists deaths_path then
      (try
        let ic = open_in deaths_path in
        let last = ref None in
        (try while true do
          let line = String.trim (input_line ic) in
          if line <> "" then begin
            match Yojson.Safe.from_string line with
            | `Assoc fields ->
                (match List.assoc_opt "name" fields with
                 | Some (`String n) when n = name -> last := Some fields
                 | _ -> ())
            | _ -> ()
          end
        done with End_of_file -> ());
        close_in ic;
        !last
      with _ -> None)
    else None
  in
  (match last_death with
   | None -> ()
   | Some fields ->
       let exit_code = match List.assoc_opt "exit_code" fields with Some (`Int n) -> n | _ -> -1 in
       let duration_s = match List.assoc_opt "duration_s" fields with Some (`Float f) -> f | _ -> 0.0 in
       let ts = match List.assoc_opt "ts" fields with Some (`Float f) -> f | _ -> 0.0 in
       Printf.printf "last death: exit=%d  duration=%.1fs  at=%s\n" exit_code duration_s (C2c_time.iso8601_utc ts));
  (* Print stderr.log tail *)
  let log_path = inst_dir // "stderr.log" in
  if not (Sys.file_exists log_path) then
    Printf.printf "no stderr.log (instance may not have produced any stderr)\n"
  else begin
    Printf.printf "\n--- stderr.log (last %d lines) ---\n" lines;
    let ic = open_in log_path in
    let all_lines = ref [] in
    (try while true do
      all_lines := input_line ic :: !all_lines
    done with End_of_file -> ());
    close_in ic;
    let all = List.rev !all_lines in
    let n = List.length all in
    let skip = max 0 (n - lines) in
    let rec drop i lst = match lst with [] -> [] | _ :: t -> if i > 0 then drop (i-1) t else lst in
    List.iter (fun l -> print_endline l) (drop skip all)
  end

let diag = Cmdliner.Cmd.v (Cmdliner.Cmd.info "diag" ~doc:"Show diagnostic info (last death + stderr tail) for a managed instance.") diag_cmd

(* --- dev command group: c2c dev ------------------------------------------ *)

let dev_instances_cmd = instances_cmd

(* dev_status_cmd: REMOVED — consolidated into dev_instances_cmd (2026-05-06) *)
let dev_instances_sub =
  Cmdliner.Cmd.group (Cmdliner.Cmd.info "instances"
    ~doc:"List managed c2c instances (operator view; subcommands: clean-stale, gc).")
    ~default:dev_instances_cmd
    [ clean_stale_subcmd; instances_gc_subcmd ]

(* Deprecated top-level instances alias — Tier 1 so agents can still use it.
   Preserves the original {alive,total,filtered,instances} envelope for
   backward compatibility with scripts expecting the old JSON format. *)
let instances_deprecated_term =
  let prune_older_than =
    Cmdliner.Arg.(
      value
      & opt (some int) None
      & info [ "prune-older-than" ] ~docv:"DAYS"
          ~doc:"Prune stopped instances older than DAYS before listing." )
  in
  let all_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "all"; "a" ]
          ~doc:"Show full archive (zombies + recently-stopped). Default: alive-only.")
  in
  let alive_flag =
    Cmdliner.Arg.(
      value
      & flag
      & info [ "alive" ]
          ~doc:"Explicitly request alive-only view (the default). Useful in scripts that want to assert the filter is on.")
  in
  let+ json = json_flag
  and+ prune_older_than = prune_older_than
  and+ show_all = all_flag
  and+ alive_only = alive_flag in
  (* Emit deprecation warning before doing any work *)
  Printf.eprintf "[DEPRECATED] c2c instances is now c2c dev instances. Updating in 2 releases.\n%!";
  let _ = alive_only in
  let output_mode = if json then Json else Human in
  let instances_dir = instances_dir () in
  let all_instances = C2c_health_cmd.read_managed_instances () in
  let all_instances =
    match prune_older_than with
    | None -> all_instances
    | Some days ->
        if days < 0 then (
          Printf.eprintf "error: --prune-older-than must be >= 0\n%!";
          exit 1);
        let stale = C2c_health_cmd.prune_stopped_instances_older_than ~days ~instances_dir all_instances in
        if stale <> [] && output_mode = Human then
          Printf.eprintf
            "pruned %d stopped instance(s) older than %d day(s)\n%!"
            (List.length stale) days;
        C2c_health_cmd.read_managed_instances ()
  in
  let total = List.length all_instances in
  let alive_instances =
    List.filter (fun (inst : managed_instance_view) -> inst.mi_status = "running") all_instances
  in
  let alive_count = List.length alive_instances in
  let displayed = if show_all then all_instances else alive_instances in
  let instance_to_json (inst : managed_instance_view) : Yojson.Safe.t =
    let fields : (string * Yojson.Safe.t) list =
      [ ("name", `String inst.mi_name)
      ; ("client", `String inst.mi_client)
      ; ("status", `String inst.mi_status)
      ; ("delivery_mode", `String inst.mi_delivery_mode)
      ; ("outer_alive", `Bool (inst.mi_status = "running"))
      ; ("outer_pid", match inst.mi_pid with Some p -> `Int p | None -> `Null)
      ; ("tmux_location", match inst.mi_tmux_location with Some s -> `String s | None -> `Null)
      ; ("expected_cwd", match inst.mi_expected_cwd with Some s -> `String s | None -> `Null)
      ]
    in
    let fields = match inst.mi_pid with
      | Some p -> fields @ [ ("pid", `Int p) ]
      | None -> fields
    in
    `Assoc fields
  in
  let instances_json = List.map instance_to_json displayed in
  match output_mode with
  | Json ->
      print_json
        (`Assoc
           [ ("alive", `Int alive_count)
           ; ("total", `Int total)
           ; ("filtered", `Bool (not show_all))
           ; ("instances", `List instances_json)
           ])
  | Human ->
      if total = 0 then
        Printf.printf "No managed instances.\n"
      else begin
        if show_all then
          Printf.printf "Managed instances (%d alive / %d total):\n" alive_count total
        else
          Printf.printf "Managed instances (%d alive / %d total; --all for archive):\n"
            alive_count total;
        if displayed = [] then
          Printf.printf "  (none alive — try --all to see the archive)\n"
        else
          List.iter (fun (inst : managed_instance_view) ->
            let pid_str = match inst.mi_pid with Some n -> Printf.sprintf " (pid %d)" n | None -> "" in
            let tmux_str = match inst.mi_tmux_location with Some s -> " [" ^ s ^ "]" | _ -> "" in
            let cwd_str = match inst.mi_expected_cwd with
              | Some c ->
                  let len = String.length c in
                  let display = if len > 18 then "..." ^ String.sub c (len - 18) 18 else c in
                  " {" ^ display ^ "}"
              | None -> ""
            in
            let status_extra = match inst.mi_delivery_mode with
              | "plugin" when inst.mi_status = "running" -> " plugin"
              | dm -> Printf.sprintf " %s" dm
            in
            Printf.printf "  %-20s %-10s %-12s %s%s%s%s\n"
              inst.mi_name inst.mi_client inst.mi_status status_extra pid_str tmux_str cwd_str
          ) displayed
      end

let instances_deprecated =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "instances"
       ~doc:"[DEPRECATED: use c2c dev instances]")
    ~default:instances_deprecated_term
    [ clean_stale_subcmd; instances_gc_subcmd ]
