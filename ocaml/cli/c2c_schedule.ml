(* c2c_schedule — per-agent schedule CLI commands
 *
 * S1: CLI set/list/rm/enable/disable schedule entries.
 * Storage: .c2c/schedules/<alias>/  (in repo root)
 * Format: TOML key-value (no library, hand-parsed)
 *   [schedule]
 *   name = "wake"
 *   interval_s = 246.0
 *   align = ""
 *   message = "wake — poll inbox, advance work"
 *   only_when_idle = true
 *   idle_threshold_s = 246.0
 *   enabled = true
 *   created_at = "2026-05-02T07:00:00Z"
 *   updated_at = "2026-05-02T07:00:00Z"
 *)

open Cmdliner.Term.Syntax

(* --- path helpers ---------------------------------------------------------- *)

(* Delegate to C2c_mcp which hosts the canonical single source of truth for
   schedule path resolution (honors C2C_SCHEDULE_ROOT_OVERRIDE for tests). *)
let schedules_base_dir alias = C2c_mcp.schedule_base_dir alias

let schedule_file_path alias name = C2c_mcp.schedule_entry_path alias name

let ensure_schedules_dir alias =
  let dir = schedules_base_dir alias in
  C2c_mcp.mkdir_p dir;
  dir

(* --- current alias --------------------------------------------------------- *)

let current_alias_or_die () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
      Printf.eprintf "error: set C2C_MCP_AUTO_REGISTER_ALIAS to identify the current agent\n%!";
      exit 1

(* --- TOML helpers ---------------------------------------------------------- *)

(* Escape a string value for embedding inside TOML double-quoted strings.
   Backslash is escaped to double-backslash; double-quote is escaped to
   backslash-double-quote, per the TOML basic string spec. *)
let escape_toml_string s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"'  -> Buffer.add_string buf "\\\""
    | c    -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(* Hand-write a schedule entry to TOML. No library needed — the format is
   simple key-value pairs. String fields are escaped via escape_toml_string
   so values containing '"' or '\' produce valid TOML. *)
let render_schedule ~name ~interval_s ~align ~message ~only_when_idle
    ~idle_threshold_s ~enabled ~created_at ~updated_at () =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "[schedule]\n";
  Buffer.add_string buf (Printf.sprintf "name = \"%s\"\n" (escape_toml_string name));
  Buffer.add_string buf (Printf.sprintf "interval_s = %.6g\n" interval_s);
  Buffer.add_string buf (Printf.sprintf "align = \"%s\"\n" (escape_toml_string align));
  Buffer.add_string buf (Printf.sprintf "message = \"%s\"\n" (escape_toml_string message));
  Buffer.add_string buf (Printf.sprintf "only_when_idle = %b\n" only_when_idle);
  Buffer.add_string buf (Printf.sprintf "idle_threshold_s = %.6g\n" idle_threshold_s);
  Buffer.add_string buf (Printf.sprintf "enabled = %b\n" enabled);
  Buffer.add_string buf (Printf.sprintf "created_at = \"%s\"\n" (escape_toml_string created_at));
  Buffer.add_string buf (Printf.sprintf "updated_at = \"%s\"\n" (escape_toml_string updated_at));
  Buffer.contents buf

(* Schedule entry type and parsing are now in the library (C2c_mcp).
   Re-export for local use. *)
type schedule_entry = C2c_mcp.schedule_entry = {
  s_name : string;
  s_interval_s : float;
  s_align : string;
  s_message : string;
  s_only_when_idle : bool;
  s_idle_threshold_s : float;
  s_enabled : bool;
  s_created_at : string;
  s_updated_at : string;
}

let parse_schedule = C2c_mcp.parse_schedule

(* --- file I/O -------------------------------------------------------------- *)

let read_file path =
  C2c_io.read_file_opt path

let write_file path content =
  C2c_io.write_file path content

(* List .toml files in a schedules dir, sorted by filename. *)
let list_schedule_files dir =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun n ->
        String.length n > 5
        && String.sub n (String.length n - 5) 5 = ".toml")
    |> List.sort String.compare
  with
  | Sys_error _ -> []
  | Unix.Unix_error _ -> []

(* --- flags ----------------------------------------------------------------- *)

let json_flag =
  let doc = "Emit JSON output." in
  Cmdliner.Arg.(value & flag & info [ "json" ] ~doc)

let name_arg =
  Cmdliner.Arg.(required & pos 0 (some string) None
    & info [] ~docv:"NAME" ~doc:"Schedule name (stored as <name>.toml).")

let default_message = "Session heartbeat — pick up the next slice"

(* --- schedule set ---------------------------------------------------------- *)

let schedule_set_cmd =
  let interval_arg =
    let doc = "Interval duration, e.g. 4.1m, 1h, 30s, 240 (seconds)." in
    Cmdliner.Arg.(required & opt (some string) None
      & info ["interval"; "i"] ~docv:"DURATION" ~doc)
  in
  let align_arg =
    let doc = "Wall-clock alignment spec, e.g. @1h+7m." in
    Cmdliner.Arg.(value & opt string ""
      & info ["align"] ~docv:"SPEC" ~doc)
  in
  let message_arg =
    let doc = Printf.sprintf "Message text (default: \"%s\")." default_message in
    Cmdliner.Arg.(value & opt string default_message
      & info ["message"; "m"] ~docv:"TEXT" ~doc)
  in
  let only_when_idle_arg =
    Cmdliner.Arg.(value & vflag true
      [ (true,  info ["only-when-idle"]    ~doc:"Only fire when the agent is idle (default).")
      ; (false, info ["no-only-when-idle"] ~doc:"Fire even when the agent is busy.")
      ])
  in
  let idle_threshold_arg =
    let doc = "Idle threshold duration (default: same as --interval)." in
    Cmdliner.Arg.(value & opt (some string) None
      & info ["idle-threshold"] ~docv:"DURATION" ~doc)
  in
  let enabled_arg =
    Cmdliner.Arg.(value & vflag true
      [ (true,  info ["enabled"]  ~doc:"Create schedule as enabled (default).")
      ; (false, info ["disabled"] ~doc:"Create schedule as disabled.")
      ])
  in
  let+ json = json_flag
  and+ name = name_arg
  and+ interval_raw = interval_arg
  and+ align_raw = align_arg
  and+ message = message_arg
  and+ only_when_idle = only_when_idle_arg
  and+ idle_threshold_raw = idle_threshold_arg
  and+ enabled = enabled_arg in
  let alias = current_alias_or_die () in
  (* Parse interval *)
  let interval_s = match C2c_start.parse_heartbeat_duration_s interval_raw with
    | Ok s -> s
    | Error e ->
        Printf.eprintf "error: --interval: %s\n%!" e;
        exit 1
  in
  (* Parse align spec — extract align string (store as raw string for S2 loader) *)
  let align =
    if align_raw = "" then ""
    else match C2c_start.parse_heartbeat_schedule align_raw with
    | Ok _ -> align_raw
    | Error e ->
        Printf.eprintf "error: --align: %s\n%!" e;
        exit 1
  in
  (* Parse idle threshold — default to interval *)
  let idle_threshold_s = match idle_threshold_raw with
    | None -> interval_s
    | Some raw -> match C2c_start.parse_heartbeat_duration_s raw with
      | Ok s -> s
      | Error e ->
          Printf.eprintf "error: --idle-threshold: %s\n%!" e;
          exit 1
  in
  let _ = ensure_schedules_dir alias in
  let path = schedule_file_path alias name in
  let now_ts = C2c_time.now_iso8601_utc () in
  (* If file exists, preserve created_at *)
  let created_at =
    if Sys.file_exists path then
      let existing = parse_schedule (read_file path) in
      if existing.s_created_at <> "" then existing.s_created_at else now_ts
    else now_ts
  in
  let content = render_schedule ~name ~interval_s ~align ~message
    ~only_when_idle ~idle_threshold_s ~enabled ~created_at
    ~updated_at:now_ts ()
  in
  write_file path content;
  if json then
    print_endline (Yojson.Safe.to_string ~std:false (`Assoc [
      ("saved", `String name)
    ; ("alias", `String alias)
    ; ("interval_s", `Float interval_s)
    ; ("enabled", `Bool enabled)
    ]))
  else
    Printf.printf "saved: %s (interval=%.6gs, enabled=%b)\n" name interval_s enabled

(* --- schedule list --------------------------------------------------------- *)

let schedule_list_cmd =
  let+ json = json_flag in
  let alias = current_alias_or_die () in
  let dir = schedules_base_dir alias in
  let files = list_schedule_files dir in
  let entries = List.map (fun fname ->
    let path = Filename.concat dir fname in
    let e = parse_schedule (read_file path) in
    (fname, e))
    files
  in
  if json then begin
    let items = List.map (fun (fname, e) ->
      `Assoc [
        ("file", `String fname)
      ; ("name", `String e.s_name)
      ; ("interval_s", `Float e.s_interval_s)
      ; ("align", `String e.s_align)
      ; ("message", `String e.s_message)
      ; ("only_when_idle", `Bool e.s_only_when_idle)
      ; ("idle_threshold_s", `Float e.s_idle_threshold_s)
      ; ("enabled", `Bool e.s_enabled)
      ; ("created_at", `String e.s_created_at)
      ; ("updated_at", `String e.s_updated_at)
      ]) entries
    in
    print_endline (Yojson.Safe.to_string ~std:false (`List items))
  end else if entries = [] then
    print_endline "(no schedules)"
  else begin
    Printf.printf "%-20s  %-12s  %-6s  %s\n" "NAME" "INTERVAL(s)" "ENABLED" "MESSAGE";
    Printf.printf "%s\n" (String.make 72 '-');
    List.iter (fun (_fname, e) ->
      Printf.printf "%-20s  %-12.6g  %-6b  %s\n"
        e.s_name e.s_interval_s e.s_enabled
        (if String.length e.s_message > 40
         then String.sub e.s_message 0 37 ^ "..."
         else e.s_message)
    ) entries
  end

(* --- schedule rm ----------------------------------------------------------- *)

let schedule_rm_cmd =
  let+ json = json_flag
  and+ name = name_arg in
  let alias = current_alias_or_die () in
  let path = schedule_file_path alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: schedule '%s' not found\n%!" name;
    exit 1);
  (try Sys.remove path with Sys_error _ -> ());
  if json then
    print_endline (Yojson.Safe.to_string ~std:false (`Assoc [("deleted", `String name)]))
  else
    Printf.printf "deleted: %s\n" name

(* --- schedule enable / disable --------------------------------------------- *)

let set_enabled_flag ~name ~enabled =
  let alias = current_alias_or_die () in
  let path = schedule_file_path alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: schedule '%s' not found\n%!" name;
    exit 1);
  let e = parse_schedule (read_file path) in
  let now_ts = C2c_time.now_iso8601_utc () in
  let content = render_schedule ~name:e.s_name ~interval_s:e.s_interval_s
    ~align:e.s_align ~message:e.s_message ~only_when_idle:e.s_only_when_idle
    ~idle_threshold_s:e.s_idle_threshold_s ~enabled
    ~created_at:e.s_created_at ~updated_at:now_ts ()
  in
  write_file path content

let schedule_enable_cmd =
  let+ json = json_flag
  and+ name = name_arg in
  set_enabled_flag ~name ~enabled:true;
  if json then
    print_endline (Yojson.Safe.to_string ~std:false (`Assoc [("enabled", `String name)]))
  else
    Printf.printf "enabled: %s\n" name

let schedule_disable_cmd =
  let+ json = json_flag
  and+ name = name_arg in
  set_enabled_flag ~name ~enabled:false;
  if json then
    print_endline (Yojson.Safe.to_string ~std:false (`Assoc [("disabled", `String name)]))
  else
    Printf.printf "disabled: %s\n" name

(* --- group ----------------------------------------------------------------- *)

let schedule_group =
  Cmdliner.Cmd.group ~default:schedule_list_cmd
    (Cmdliner.Cmd.info "schedule"
       ~doc:"Manage per-agent wake schedules. Stored in .c2c/schedules/<alias>/.")
    [ Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "set"
           ~doc:"Create or update a schedule entry.")
        schedule_set_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "list"
           ~doc:"List schedule entries for the current agent.")
        schedule_list_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "rm"
           ~doc:"Remove a schedule entry.")
        schedule_rm_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "enable"
           ~doc:"Enable a schedule entry.")
        schedule_enable_cmd
    ; Cmdliner.Cmd.v
        (Cmdliner.Cmd.info "disable"
           ~doc:"Disable a schedule entry.")
        schedule_disable_cmd
    ]
