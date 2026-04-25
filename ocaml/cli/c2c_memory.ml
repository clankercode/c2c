(* c2c_memory — per-agent memory CLI commands
 *
 * Phase 1: CLI only — list/read/write/delete memory entries.
 * Storage: .c2c/memory/<alias>/  (in repo root, git-tracked)
 * Format: markdown with YAML frontmatter (matching Claude auto-memory shape)
 * Index: .c2c/memory/<alias>/MEMORY.md
 *)

open Cmdliner.Term.Syntax
open Str

let json_flag =
  let doc = "Emit JSON output." in
  Cmdliner.Arg.(value & flag & info [ "json" ] ~doc)

let print_json json =
  print_endline (Yojson.Safe.to_string ~std:false json)

(* --- path helpers ---------------------------------------------------------- *)

let memory_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let base = Filename.concat home ".local/share/c2c" in
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ -> base

let resolve_alias_for_memory () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
    (try Sys.getenv "USER" with Not_found -> "anonymous")
    ^ "-memory"

let memory_base_dir alias =
  (* Use git_common_dir_parent to get main repo root, not worktree root *)
  let git_dir =
    let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
    try
      let line = input_line ic in
      ignore (Unix.close_process_in ic);
      Some line
    with _ -> ignore (Unix.close_process_in ic); None
  in
  let base = match git_dir with
    | Some d -> Filename.dirname d
    | None -> Sys.getcwd ()
  in
  Filename.concat (Filename.concat (Filename.concat base ".c2c") "memory") alias

let ensure_memory_dir alias =
  let dir = memory_base_dir alias in
  let rec mkdir_p d =
    if not (Sys.file_exists d) then (
      (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      mkdir_p (Filename.dirname d))
  in
  mkdir_p (Filename.dirname dir);
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  dir

(* --- entry file helpers ---------------------------------------------------- *)

let entry_filename alias name =
  let safe = String.map (fun c ->
    match c with
    | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
    | _ ->
        let code = Char.code c in
        if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code = 95 || code = 45
        then c else '_')
    name in
  Filename.concat (memory_base_dir alias) (safe ^ ".md")

let read_file path =
  try
    let ic = open_in path in
    let content = really_input_string ic (in_channel_length ic) in
    close_in ic;
    content
  with _ -> ""

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let parse_frontmatter content =
  let lines = String.split_on_char '\n' content in
  let rec parse lines in_frontmatter name desc shared acc =
    match lines with
    | [] -> (name, desc, shared, List.rev acc)
    | line :: rest ->
        let line = String.trim line in
        if line = "---" then
          parse rest (not in_frontmatter) name desc shared acc
        else if in_frontmatter then
          if 0 = String.length line then parse rest in_frontmatter name desc shared acc
          else if Str.string_match (Str.regexp "^name:[ ]*\\(.+\\)$") line 0
          then parse rest in_frontmatter (Some (Str.matched_group 1 line)) desc shared acc
          else if Str.string_match (Str.regexp "^description:[ ]*\\(.+\\)$") line 0
          then parse rest in_frontmatter name (Some (Str.matched_group 1 line)) shared acc
          else if Str.string_match (Str.regexp "^shared:[ ]*\\(true\\|false\\)$") line 0
          then parse rest in_frontmatter name desc (Str.matched_group 1 line = "true") acc
          else parse rest in_frontmatter name desc shared acc
        else parse rest in_frontmatter name desc shared (line :: acc)
  in
  parse lines false None None false []

(* --- memory list ----------------------------------------------------------- *)

let memory_list_cmd =
  let+ json = json_flag in
  let alias = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a -> a | None -> ""
  in
  let dir = memory_base_dir alias in
  let entries =
    try
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun n -> n <> "MEMORY.md" && String.length n > 3 && String.sub n (String.length n - 3) 3 = ".md")
      |> List.sort String.compare
    with _ -> []
  in
  if json then
    let items = List.map (fun name ->
      let path = Filename.concat dir name in
      let content = read_file path in
      let (mname, desc, shared, _) = parse_frontmatter content in
      `Assoc (
        ("file", `String name)
        :: ("name", match mname with Some n -> `String n | None -> `Null)
        :: ("description", match desc with Some d -> `String d | None -> `Null)
        :: ("shared", `Bool shared)
        :: [])
    ) entries in
    print_json (`List items)
  else
    if entries = [] then print_endline "(no memory entries)"
    else List.iter (fun name ->
      let path = Filename.concat dir name in
      let content = read_file path in
      let (mname, desc, shared, _) = parse_frontmatter content in
      Printf.printf "%s%s\n" name (match mname with Some n -> " — " ^ n | None -> "");
      (match desc with Some d -> Printf.printf "  %s\n" d | None -> ());
      if shared then Printf.printf "  [shared]\n" else ();
      print_endline ""
    ) entries

(* --- memory read ----------------------------------------------------------- *)

let memory_read_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Entry name (filename without .md)")
  in
  let+ json = json_flag
  and+ name = name in
  let alias = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a -> a | None -> ""
  in
  let path = entry_filename alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: memory entry '%s' not found\n%!" name;
    exit 1);
  let content = read_file path in
  if json then
    let (mname, desc, shared, body) = parse_frontmatter content in
    print_json (`Assoc [
      ("name", match mname with Some n -> `String n | None -> `Null);
      ("description", match desc with Some d -> `String d | None -> `Null);
      ("shared", `Bool shared);
      ("content", `String (String.concat "\n" body))
    ])
  else
    print_string content

(* --- memory write ---------------------------------------------------------- *)

let memory_write_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Entry name (will be stored as <name>.md)")
  in
  let desc =
    let doc = "Short description of this memory." in
    Cmdliner.Arg.(value & opt (some string) None & info [ "description"; "d" ] ~docv:"DESC" ~doc)
  in
  let shared =
    let doc = "Mark this entry as shared (visible to other agents via list --shared)." in
    Cmdliner.Arg.(value & flag & info [ "shared"; "s" ] ~doc)
  in
  let body =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"CONTENT" ~doc:"Memory body text (remaining args joined with newlines).")
  in
  let+ name = name
  and+ desc = desc
  and+ shared = shared
  and+ body = body in
  let alias = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a -> a | None -> ""
  in
  if alias = "" then (
    Printf.eprintf "error: set C2C_MCP_AUTO_REGISTER_ALIAS to write memory\n%!";
    exit 1);
  let dir = ensure_memory_dir alias in
  let path = entry_filename alias name in
  let content = Printf.sprintf "---\nname: %s\ndescription: %s\nshared: %b\n---\n%s\n"
    name (Option.value desc ~default:"") shared (String.concat "\n" body)
  in
  write_file path content;
  Printf.printf "saved: %s\n" name

(* --- memory delete --------------------------------------------------------- *)

let memory_delete_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Entry name to delete")
  in
  let+ name = name in
  let alias = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
    | Some a -> a | None -> ""
  in
  let path = entry_filename alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: memory entry '%s' not found\n%!" name;
    exit 1);
  Sys.remove path;
  Printf.printf "deleted: %s\n" name

(* --- group ----------------------------------------------------------------- *)

let memory_default = memory_list_cmd

let memory_group =
  Cmdliner.Cmd.group ~default:memory_default
    (Cmdliner.Cmd.info "memory" ~doc:"Manage per-agent memory entries.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List memory entries.") memory_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "read" ~doc:"Read a memory entry.") memory_read_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "write" ~doc:"Write a memory entry.") memory_write_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "delete" ~doc:"Delete a memory entry.") memory_delete_cmd ]
