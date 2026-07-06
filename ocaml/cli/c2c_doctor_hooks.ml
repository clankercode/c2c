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
  codex : codex_result;
}

and block_diff = {
  line : int;
  expected : string;
  actual : string;
}

and managed_block_status =
  | Not_installed
  | Current
  | Missing
  | Stale

and managed_block_result = {
  label : string;
  path : string;
  status : managed_block_status;
  reason : string;
  refresh_command : string option;
  first_diff : block_diff option;
}

and codex_result = {
  installed : bool;
  config : managed_block_result;
  agents_md : managed_block_result;
  total_issues : int;
  trust_index_drift : bool;
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

let status_label = function
  | Not_installed -> "not_installed"
  | Current -> "current"
  | Missing -> "missing"
  | Stale -> "stale"

let trim_trailing_newlines s =
  let i = ref (String.length s) in
  while !i > 0 && (s.[!i - 1] = '\n' || s.[!i - 1] = '\r') do
    decr i
  done;
  if !i = String.length s then s else String.sub s 0 !i

let first_diff expected actual =
  let exp = String.split_on_char '\n' (trim_trailing_newlines expected) in
  let act = String.split_on_char '\n' (trim_trailing_newlines actual) in
  let rec loop line exp act =
    match exp, act with
    | [], [] -> None
    | e :: es, a :: as_ when e = a -> loop (line + 1) es as_
    | e :: _, a :: _ -> Some { line; expected = e; actual = a }
    | e :: _, [] -> Some { line; expected = e; actual = "<missing>" }
    | [], a :: _ -> Some { line; expected = "<missing>"; actual = a }
  in
  loop 1 exp act

let extract_managed_blocks ~begin_marker ~end_marker content =
  let blocks = ref [] in
  let current = ref None in
  let finish acc =
    blocks := String.concat "\n" (List.rev acc) :: !blocks;
    current := None
  in
  List.iter
    (fun line ->
      let trimmed = String.trim line in
      match !current with
      | None ->
          if trimmed = begin_marker then current := Some [ line ]
      | Some acc ->
          let acc = line :: acc in
          if trimmed = end_marker then finish acc else current := Some acc)
    (String.split_on_char '\n' content);
  (match !current with
   | Some acc -> finish acc
   | None -> ());
  List.rev !blocks

let state_keys block =
  let prefix = "[hooks.state.\"" in
  let prefix_len = String.length prefix in
  String.split_on_char '\n' block
  |> List.filter_map (fun line ->
       let line = String.trim line in
       let len = String.length line in
       if len > prefix_len && String.sub line 0 prefix_len = prefix then
         try
           let rest = String.sub line prefix_len (len - prefix_len) in
           match String.index_opt rest '"' with
           | Some idx -> Some (String.sub rest 0 idx)
           | None -> None
         with _ -> None
       else None)

let same_string_set a b =
  List.sort String.compare a = List.sort String.compare b

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

(* --- Codex managed block scan --------------------------------------------- *)

let home_dir () =
  match Sys.getenv_opt "HOME" with
  | Some h when String.trim h <> "" -> h
  | _ -> ""

let codex_paths ?home () =
  let home = match home with Some h -> h | None -> home_dir () in
  let codex_dir = home // ".codex" in
  (codex_dir // "config.toml", codex_dir // "AGENTS.md")

let block_result ~label ~path ~status ~reason ?refresh_command ?first_diff () =
  { label; path; status; reason; refresh_command; first_diff }

let not_installed_block ~label ~path =
  block_result ~label ~path ~status:Not_installed
    ~reason:"c2c codex install not detected" ()

let assess_block ~label ~path ~begin_marker ~end_marker ~expected ~installed =
  let blocks = extract_managed_blocks ~begin_marker ~end_marker installed in
  match blocks with
  | [] ->
      block_result ~label ~path ~status:Missing
        ~reason:"managed block is missing"
        ~refresh_command:"c2c install codex" ()
  | [ actual ] ->
      if trim_trailing_newlines actual = trim_trailing_newlines expected then
        block_result ~label ~path ~status:Current ~reason:"managed block is current" ()
      else
        block_result ~label ~path ~status:Stale
          ~reason:"managed block differs from current c2c render"
          ~refresh_command:"c2c install codex"
          ?first_diff:(first_diff expected actual)
          ()
  | _ ->
      block_result ~label ~path ~status:Stale
        ~reason:"multiple managed blocks found"
        ~refresh_command:"c2c install codex" ()

let check_codex_managed_blocks ?home () =
  let config_path, agents_md_path = codex_paths ?home () in
  let config_exists = Sys.file_exists config_path in
  let agents_exists = Sys.file_exists agents_md_path in
  let config_content = if config_exists then C2c_io.read_file_opt config_path else "" in
  let agents_content = if agents_exists then C2c_io.read_file_opt agents_md_path else "" in
  let installed =
    config_exists
    && (contains config_content "mcp_servers.c2c"
        || contains config_content C2c_codex_hooks.config_begin_marker)
    || contains agents_content C2c_codex_hooks.agents_md_begin_marker
  in
  if not installed then
    let config = not_installed_block ~label:"codex config.toml" ~path:config_path in
    let agents_md = not_installed_block ~label:"codex AGENTS.md" ~path:agents_md_path in
    { installed = false; config; agents_md; total_issues = 0; trust_index_drift = false }
  else
    let config_stripped =
      C2c_codex_hooks.strip_managed_block
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        config_content
    in
    let expected_config =
      C2c_codex_hooks.render_hooks_block ~config_path ~existing:config_stripped
    in
    let config =
      assess_block ~label:"codex config.toml" ~path:config_path
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        ~expected:expected_config ~installed:config_content
    in
    let agents_md =
      assess_block ~label:"codex AGENTS.md" ~path:agents_md_path
        ~begin_marker:C2c_codex_hooks.agents_md_begin_marker
        ~end_marker:C2c_codex_hooks.agents_md_end_marker
        ~expected:C2c_codex_hooks.agents_md_block ~installed:agents_content
    in
    let actual_config_blocks =
      extract_managed_blocks
        ~begin_marker:C2c_codex_hooks.config_begin_marker
        ~end_marker:C2c_codex_hooks.config_end_marker
        config_content
    in
    let trust_index_drift =
      match actual_config_blocks with
      | [ actual ] ->
          let actual_keys = state_keys actual in
          let expected_keys = state_keys expected_config in
          actual_keys <> [] && expected_keys <> []
          && not (same_string_set actual_keys expected_keys)
      | _ -> false
    in
    let config =
      if trust_index_drift && config.status = Stale then
        { config with
          reason =
            "managed trust-state group indices differ from current hook positions"
        }
      else config
    in
    let issue_count b =
      match b.status with
      | Current | Not_installed -> 0
      | Missing | Stale -> 1
    in
    let total_issues = issue_count config + issue_count agents_md in
    { installed = true; config; agents_md; total_issues; trust_index_drift }

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
  let codex = check_codex_managed_blocks () in
  { dirs = dir_results; total_referenced; total_dangling; total_skipped; codex }

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
  end;
  Printf.printf "\n=== Codex managed block check ===\n\n";
  let pp_block b =
    let status = status_label b.status in
    Printf.printf "  %s: %s\n" b.label status;
    Printf.printf "    path: %s\n" b.path;
    Printf.printf "    %s\n" b.reason;
    (match b.first_diff with
     | Some d ->
         Printf.printf "    first diff line %d:\n" d.line;
         Printf.printf "      expected: %s\n" d.expected;
         Printf.printf "      actual:   %s\n" d.actual
     | None -> ());
    (match b.refresh_command with
     | Some cmd -> Printf.printf "    → refresh: %s\n" cmd
     | None -> ())
  in
  if not r.codex.installed then
    Printf.printf "Codex c2c install not detected.\n"
  else begin
    pp_block r.codex.config;
    pp_block r.codex.agents_md;
    if r.codex.trust_index_drift then
      Printf.printf
        "  trust hashes: positional group indices drifted — run `c2c install codex`.\n";
    Printf.printf "\nSummary: %d Codex managed block issue(s)\n"
      r.codex.total_issues
  end

let to_json r =
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
  let diff_to_json d =
    `Assoc [
      ("line", `Int d.line);
      ("expected", `String d.expected);
      ("actual", `String d.actual)
    ]
  in
  let block_to_json b =
    `Assoc [
      ("label", `String b.label);
      ("path", `String b.path);
      ("status", `String (status_label b.status));
      ("reason", `String b.reason);
      ("refresh_command",
       match b.refresh_command with Some c -> `String c | None -> `Null);
      ("first_diff",
       match b.first_diff with Some d -> diff_to_json d | None -> `Null)
    ]
  in
  let codex_to_json c =
    `Assoc [
      ("installed", `Bool c.installed);
      ("config", block_to_json c.config);
      ("agents_md", block_to_json c.agents_md);
      ("total_issues", `Int c.total_issues);
      ("trust_index_drift", `Bool c.trust_index_drift)
    ]
  in
  `Assoc [
    ("dirs", `List (List.map dir_to_json r.dirs));
    ("total_referenced", `Int r.total_referenced);
    ("total_dangling", `Int r.total_dangling);
    ("total_skipped", `Int r.total_skipped);
    ("codex_managed_blocks", codex_to_json r.codex);
    ("total_codex_issues", `Int r.codex.total_issues)
  ]

let pp_json r = print_endline (Yojson.Safe.to_string (to_json r))

let pp_compact r =
  (if r.total_referenced = 0 then
     Printf.printf "Claude hooks: no c2c hook commands referenced\n"
   else if r.total_dangling = 0 then
     Printf.printf "Claude hooks: all %d resolve\n" r.total_referenced
   else
     Printf.printf "Claude hooks: %d referenced, %d dangling — run 'c2c doctor hooks' for details\n"
       r.total_referenced r.total_dangling);
  if not r.codex.installed then
    Printf.printf "Codex managed blocks: not installed\n"
  else if r.codex.total_issues = 0 then
    Printf.printf "Codex managed blocks: current\n"
  else
    Printf.printf
      "Codex managed blocks: %d stale/missing — run 'c2c install codex'\n"
      r.codex.total_issues

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
    if r.total_dangling > 0 || r.codex.total_issues > 0 then exit 1
  in
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "hooks"
       ~doc:"Check Claude Code settings.json hook entries for dangling c2c scripts.")
    cmd
