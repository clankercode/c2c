(* c2c_doctor_schedule.ml — `c2c doctor schedule` implementation.

   Reports schedule status for the current agent:
   - Whether .c2c/schedules/<alias>/ exists
   - Whether each .toml file is parseable (valid [schedule] + non-empty name)
   - Whether enabled = true for each

   Output modes: human, JSON, --compact rollup. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* --- types ---------------------------------------------------------------- *)

type schedule_status = {
  file_name : string;
  parseable : bool;
  enabled : bool;
  reason : string option;  (* why unparseable, if any *)
  interval_s : float;
  align : string;
}

type result = {
  alias : string;
  schedules_dir : string;
  dir_exists : bool;
  schedules : schedule_status list;
  total : int;
  enabled_count : int;
  parseable_count : int;
}

(* --- TOML parseability check ----------------------------------------------- *)

(* True when a TOML schedule file is parseable:
   - [schedule] section header present
   - name field is non-empty after quote stripping
   parse_schedule never raises; we use the name field as our validity proxy. *)
let is_parseable content =
  let entry = C2c_mcp.parse_schedule content in
  String.trim entry.C2c_mcp.s_name <> ""

(* --- scan one schedules dir ------------------------------------------------ *)

let scan_schedules_dir alias =
  let dir = C2c_mcp.schedule_base_dir alias in
  let dir_exists = Sys.file_exists dir && Sys.is_directory dir in
  if not dir_exists then
    { alias; schedules_dir = dir; dir_exists = false;
      schedules = []; total = 0; enabled_count = 0; parseable_count = 0 }
  else begin
    let files =
      try
        Array.to_list (Sys.readdir dir)
        |> List.filter (fun n -> String.length n > 5 && String.sub n (String.length n - 5) 5 = ".toml")
        |> List.sort String.compare
      with Sys_error _ | Unix.Unix_error _ -> []
    in
    let schedules =
      List.map (fun fname ->
        let path = dir // fname in
        let content = C2c_io.read_file_opt path in
        if content = "" then
          { file_name = fname; parseable = false; enabled = false;
            reason = Some "could not read file"; interval_s = 0.0; align = "" }
        else
          let parseable = is_parseable content in
          let entry = C2c_mcp.parse_schedule content in
          let reason = if parseable then None else Some "malformed TOML (missing [schedule] or empty name)" in
          { file_name = fname; parseable; enabled = entry.C2c_mcp.s_enabled;
            reason; interval_s = entry.C2c_mcp.s_interval_s;
            align = entry.C2c_mcp.s_align }
      ) files
    in
    let total = List.length schedules in
    let enabled_count = List.length (List.filter (fun s -> s.enabled) schedules) in
    let parseable_count = List.length (List.filter (fun s -> s.parseable) schedules) in
    { alias; schedules_dir = dir; dir_exists = true; schedules; total; enabled_count; parseable_count }
  end

(* --- output formatters ---------------------------------------------------- *)

let pp_human r =
  Printf.printf "=== schedule status for %s ===\n\n" r.alias;
  if not r.dir_exists then begin
    Printf.printf "schedules dir: %s  [NOT FOUND]\n" r.schedules_dir;
    Printf.printf "No schedules configured. Run 'c2c schedule set' to create one.\n"
  end else if r.schedules = [] then begin
    Printf.printf "schedules dir: %s  (empty — no .toml files)\n" r.schedules_dir;
    Printf.printf "No schedules configured. Run 'c2c schedule set' to create one.\n"
  end else begin
    Printf.printf "schedules dir: %s\n" r.schedules_dir;
    List.iter (fun s ->
      let parseable_mark = if s.parseable then "✓" else "✗" in
      let enabled_mark = if s.enabled then "enabled=true" else "enabled=false" in
      let extra =
        if s.parseable then
          Printf.sprintf "  %s  %s  interval=%.0fs  align=%S"
            parseable_mark enabled_mark s.interval_s s.align
        else
          Printf.sprintf "  %s  unparseable  (%s)"
            parseable_mark (Option.value s.reason ~default:"unknown")
      in
      Printf.printf "  %s%s\n" s.file_name extra
    ) r.schedules;
    Printf.printf "\n";
    let unparseable = List.filter (fun s -> not s.parseable) r.schedules in
    if unparseable <> [] then
      Printf.printf "Summary: %d schedule(s), %d enabled, %d unparseable\n"
        r.total r.enabled_count (List.length unparseable)
    else
      Printf.printf "Summary: %d schedule(s), %d enabled\n" r.total r.enabled_count
  end

let pp_json r =
  let schedule_to_json s =
    let base = [
      ("file", `String s.file_name);
      ("parseable", `Bool s.parseable);
      ("enabled", `Bool s.enabled);
      ("interval_s", `Float s.interval_s);
      ("align", `String s.align);
    ] in
    let base = match s.reason with Some r -> base @ [("reason", `String r)] | None -> base in
    `Assoc base
  in
  let json = `Assoc [
    ("alias", `String r.alias);
    ("schedules_dir", `String r.schedules_dir);
    ("schedules_dir_exists", `Bool r.dir_exists);
    ("schedules", `List (List.map schedule_to_json r.schedules));
    ("total", `Int r.total);
    ("enabled_count", `Int r.enabled_count);
    ("parseable_count", `Int r.parseable_count);
  ] in
  print_endline (Yojson.Safe.to_string json)

let pp_compact r =
  if not r.dir_exists || r.schedules = [] then
    Printf.printf "Schedule: no schedules configured\n"
  else
    let unparseable = List.length (List.filter (fun s -> not s.parseable) r.schedules) in
    if unparseable > 0 then
      Printf.printf "Schedule: %d file(s), %d enabled, %d unparseable — run 'c2c doctor schedule' for details\n"
        r.total r.enabled_count unparseable
    else
      Printf.printf "Schedule: %d file(s), %d enabled — run 'c2c doctor schedule' for details\n"
        r.total r.enabled_count

(* --- current alias --------------------------------------------------------- *)

let current_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
      Printf.eprintf "error: set C2C_MCP_AUTO_REGISTER_ALIAS to identify the current agent\n%!";
      exit 1

(* --- CLI ------------------------------------------------------------------ *)

let c2c_doctor_schedule_cmd =
  let json =
    Cmdliner.Arg.(value & flag & info [ "json" ] ~doc:"Output machine-readable JSON.")
  in
  let compact =
    Cmdliner.Arg.(value & flag & info [ "compact" ]
      ~doc:"Single-line summary suitable for 'c2c doctor' rollup.")
  in
  let cmd =
    let+ json = json
    and+ compact = compact in
    let alias = current_alias () in
    let r = scan_schedules_dir alias in
    if json then pp_json r
    else if compact then pp_compact r
    else pp_human r
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "schedule"
       ~doc:"Check schedule TOML files for parseability and enabled state.")
    cmd
