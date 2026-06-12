(* c2c_doctor_hooks.ml — `c2c doctor hooks` implementation.

   Detects dangling Claude hook scripts referenced by settings.json /
   settings.local.json. A typical failure mode is a profile-share migration
   that symlinks ~/.claude/hooks -> ~/.claude-shared/hooks but leaves the
   shared directory empty: the PostToolUse hook entry still points at an
   absolute path under ~/.claude/hooks that no longer resolves.

   The check is read-only and never raises: missing or unparseable config
   files are counted as skipped. *)

open Cmdliner.Term.Syntax

let ( // ) = Filename.concat

(* --- types ---------------------------------------------------------------- *)

type dangling = {
  config_file : string;
  event : string;
  command_path : string;
}

type dir_result = {
  dir : string;
  referenced : int;
  dangling : dangling list;
  skipped : int;
}

type result = {
  dirs : dir_result list;
  total_referenced : int;
  total_dangling : int;
  total_skipped : int;
}

(* --- pure helpers --------------------------------------------------------- *)

let contains s sub =
  let ls = String.length s and lsub = String.length sub in
  if lsub = 0 then true
  else if lsub > ls then false
  else
    let rec check i =
      if i + lsub > ls then false
      else if String.sub s i lsub = sub then true
      else check (i + 1)
    in
    check 0

let first_token s =
  let s = String.trim s in
  if s = "" then ""
  else
    let n = String.length s in
    let rec find_ws i =
      if i >= n then n
      else match s.[i] with
        | ' ' | '\t' | '\n' | '\r' -> i
        | _ -> find_ws (i + 1)
    in
    let end_pos = find_ws 0 in
    if end_pos = n then s else String.sub s 0 end_pos

let is_dangling_command cmd =
  let token = first_token cmd in
  if token = "" then false
  else if Filename.is_relative token then false
  else if not (contains token "c2c") then false
  else not (Sys.file_exists token)

(* --- JSON walk ------------------------------------------------------------ *)

let commands_from_hook_group event hook_group acc =
  match hook_group with
  | `Assoc fields ->
      (match List.assoc_opt "hooks" fields with
       | Some (`List hooks) ->
           List.fold_left (fun acc' hook ->
             match hook with
             | `Assoc hfields ->
                 (match List.assoc_opt "command" hfields with
                  | Some (`String cmd) -> (event, cmd) :: acc'
                  | _ -> acc')
             | _ -> acc') acc hooks
       | _ -> acc)
  | _ -> acc

let commands_from_event event groups acc =
  match groups with
  | `List gs -> List.fold_left (fun acc' g -> commands_from_hook_group event g acc') acc gs
  | _ -> acc

let extract_commands json =
  match json with
  | `Assoc top ->
      (match List.assoc_opt "hooks" top with
       | Some (`Assoc events) ->
           List.fold_left (fun acc (event, groups) ->
             commands_from_event event groups acc) [] events
       | _ -> [])
  | _ -> []

(* --- per-file / per-dir scan ---------------------------------------------- *)

let scan_file config_file =
  let content = C2c_io.read_file_opt config_file in
  if content = "" then `skipped
  else
    try
      let json = Yojson.Safe.from_string content in
      let cmds = extract_commands json in
      let referenced = ref 0 in
      let dangling = ref [] in
      List.iter (fun (event, cmd) ->
        let token = first_token cmd in
        if token <> "" && not (Filename.is_relative token) && contains token "c2c" then begin
          incr referenced;
          if not (Sys.file_exists token) then
            dangling := { config_file; event; command_path = token } :: !dangling
        end) cmds;
      `ok (!referenced, List.rev !dangling)
    with _ -> `skipped

let scan_dir dir =
  let settings = dir // "settings.json" in
  let local_settings = dir // "settings.local.json" in
  let referenced = ref 0 in
  let dangling = ref [] in
  let skipped = ref 0 in
  let process path =
    match scan_file path with
    | `skipped -> incr skipped
    | `ok (r, d) -> referenced := !referenced + r; dangling := !dangling @ d
  in
  process settings;
  process local_settings;
  { dir; referenced = !referenced; dangling = !dangling; skipped = !skipped }

(* --- public API ----------------------------------------------------------- *)

let claude_dirs () =
  match Sys.getenv_opt "C2C_DOCTOR_CLAUDE_DIRS" with
  | Some s when String.trim s <> "" ->
      String.split_on_char ':' s |> List.filter (fun d -> String.trim d <> "")
  | _ ->
      (match Sys.getenv_opt "CLAUDE_CONFIG_DIR" with
       | Some d when String.trim d <> "" -> [ String.trim d ]
       | _ ->
           let home =
             match Sys.getenv_opt "HOME" with
             | Some h -> h
             | None -> ""
           in
           if home = "" then []
           else [ home // ".claude"; home // ".claude-p"; home // ".claude-w" ])

let check ?(dirs = claude_dirs ()) () =
  let dirs = List.filter (fun d -> Sys.file_exists d && Sys.is_directory d) dirs in
  let dir_results = List.map scan_dir dirs in
  let total_referenced = List.fold_left (fun acc d -> acc + d.referenced) 0 dir_results in
  let total_dangling = List.fold_left (fun acc d -> acc + List.length d.dangling) 0 dir_results in
  let total_skipped = List.fold_left (fun acc d -> acc + d.skipped) 0 dir_results in
  { dirs = dir_results; total_referenced; total_dangling; total_skipped }

(* --- output formatters ---------------------------------------------------- *)

let pp_human r =
  Printf.printf "=== Claude hook dangle check ===\n\n";
  if r.dirs = [] then
    Printf.printf "No Claude config dirs found.\n"
  else begin
    List.iter (fun d ->
      Printf.printf "  dir: %s\n" d.dir;
      if d.referenced = 0 then
        Printf.printf "    no c2c hook commands referenced\n"
      else if d.dangling = [] then
        Printf.printf "    %d referenced hook command(s), all resolve\n" d.referenced
      else begin
        Printf.printf "    %d referenced hook command(s), %d dangling:\n"
          d.referenced (List.length d.dangling);
        List.iter (fun x ->
          Printf.printf "      %s:\n        %s\n" x.event x.command_path;
          Printf.printf "        → re-run `c2c install claude` (writes the hook script through the symlink), or restore the script into the shared hooks dir.\n"
        ) d.dangling
      end;
      if d.skipped > 0 then
        Printf.printf "    (%d config file(s) missing or unparseable — skipped)\n" d.skipped
    ) r.dirs;
    Printf.printf "\nSummary: %d referenced, %d dangling" r.total_referenced r.total_dangling;
    if r.total_skipped > 0 then
      Printf.printf " (%d skipped)" r.total_skipped;
    Printf.printf "\n"
  end

let pp_json r =
  let dangling_to_json d =
    `Assoc [
      ("config_file", `String d.config_file);
      ("event", `String d.event);
      ("command_path", `String d.command_path)
    ]
  in
  let dir_to_json d =
    `Assoc [
      ("dir", `String d.dir);
      ("referenced", `Int d.referenced);
      ("dangling", `List (List.map dangling_to_json d.dangling));
      ("skipped", `Int d.skipped)
    ]
  in
  let json = `Assoc [
    ("dirs", `List (List.map dir_to_json r.dirs));
    ("total_referenced", `Int r.total_referenced);
    ("total_dangling", `Int r.total_dangling);
    ("total_skipped", `Int r.total_skipped)
  ] in
  print_endline (Yojson.Safe.to_string json)

let pp_compact r =
  if r.total_referenced = 0 then
    Printf.printf "Claude hooks: no c2c hook commands referenced\n"
  else if r.total_dangling = 0 then
    Printf.printf "Claude hooks: all %d resolve\n" r.total_referenced
  else
    Printf.printf "Claude hooks: %d referenced, %d dangling — run 'c2c doctor hooks' for details\n"
      r.total_referenced r.total_dangling

(* --- CLI ------------------------------------------------------------------ *)

let c2c_doctor_hooks_cmd =
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
    let r = check () in
    if json then pp_json r
    else if compact then pp_compact r
    else pp_human r;
    if r.total_dangling > 0 then exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "hooks"
       ~doc:"Check Claude Code settings.json hook entries for dangling c2c scripts.")
    cmd
