(* c2c_memory — per-agent memory CLI commands
 *
 * Phase 1: CLI list/read/write/delete/share/unshare memory entries.
 * Storage: .c2c/memory/<alias>/  (in repo root, git-tracked)
 * Format: markdown with YAML frontmatter (matching Claude auto-memory shape)
 *   ---
 *   name: <human readable>
 *   description: <one-liner>
 *   type: <feedback|reference|note|...>
 *   shared: <true|false>
 *   ---
 *   <body>
 * Index: .c2c/memory/<alias>/MEMORY.md (deferred — write_index helper here,
 *   wired up only when Phase 3 auto-injection lands)
 *)

open Cmdliner.Term.Syntax
open Str

let json_flag =
  let doc = "Emit JSON output." in
  Cmdliner.Arg.(value & flag & info [ "json" ] ~doc)

let print_json json =
  print_endline (Yojson.Safe.to_string ~std:false json)

(* --- path helpers ---------------------------------------------------------- *)

(* C2C_MEMORY_ROOT_OVERRIDE: test hook — when set, replaces .c2c/memory as the
   memory root. Production agents never set this; the in-repo path is canonical. *)
let memory_root () =
  match Sys.getenv_opt "C2C_MEMORY_ROOT_OVERRIDE" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
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
      Filename.concat (Filename.concat base ".c2c") "memory"

let memory_base_dir alias =
  Filename.concat (memory_root ()) alias

let ensure_memory_dir alias =
  let dir = memory_base_dir alias in
  let rec mkdir_p d =
    if not (Sys.file_exists d) then (
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p dir;
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
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  with
  | Sys_error _ -> ""
  | End_of_file -> ""

let write_file path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

type entry = {
  name : string option;
  description : string option;
  type_ : string option;
  shared : bool;
  shared_with : string list;
  (* Aliases explicitly granted read access to this entry. Empty list = not
     shared-with-specific-aliases. Distinct from [shared:true] (global) — an
     entry with [shared_with = ["bob"]] is visible to bob but NOT to the
     general swarm. If both [shared:true] and [shared_with] are set,
     [shared:true] wins (entry is globally readable). *)
  body : string;
}

(* Parse a YAML-flow list value (e.g. "[alice, bob]" or "[]") into a string
   list. Also accepts a bare comma-separated form ("alice, bob") for
   resilience. Whitespace and surrounding quotes are stripped. *)
let parse_alias_list raw =
  let s = String.trim raw in
  let stripped =
    if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']'
    then String.sub s 1 (String.length s - 2)
    else s
  in
  String.split_on_char ',' stripped
  |> List.map String.trim
  |> List.map (fun a ->
       let n = String.length a in
       if n >= 2
          && ((a.[0] = '"' && a.[n-1] = '"')
              || (a.[0] = '\'' && a.[n-1] = '\''))
       then String.sub a 1 (n - 2)
       else a)
  |> List.filter (fun a -> a <> "")

let parse_frontmatter content =
  let lines = String.split_on_char '\n' content in
  let rec parse lines in_frontmatter name desc type_ shared shared_with acc =
    match lines with
    | [] -> { name; description = desc; type_; shared; shared_with;
              body = String.concat "\n" (List.rev acc) }
    | line :: rest ->
        let tline = String.trim line in
        if tline = "---" then
          parse rest (not in_frontmatter) name desc type_ shared shared_with acc
        else if in_frontmatter then
          if 0 = String.length tline then parse rest in_frontmatter name desc type_ shared shared_with acc
          else if Str.string_match (Str.regexp "^name:[ ]*\\(.+\\)$") tline 0
          then parse rest in_frontmatter (Some (Str.matched_group 1 tline)) desc type_ shared shared_with acc
          else if Str.string_match (Str.regexp "^description:[ ]*\\(.+\\)$") tline 0
          then parse rest in_frontmatter name (Some (Str.matched_group 1 tline)) type_ shared shared_with acc
          else if Str.string_match (Str.regexp "^type:[ ]*\\(.+\\)$") tline 0
          then parse rest in_frontmatter name desc (Some (Str.matched_group 1 tline)) shared shared_with acc
          else if Str.string_match (Str.regexp "^shared:[ ]*\\(true\\|false\\)$") tline 0
          then parse rest in_frontmatter name desc type_ (Str.matched_group 1 tline = "true") shared_with acc
          else if Str.string_match (Str.regexp "^shared_with:[ ]*\\(.+\\)$") tline 0
          then parse rest in_frontmatter name desc type_ shared (parse_alias_list (Str.matched_group 1 tline)) acc
          else parse rest in_frontmatter name desc type_ shared shared_with acc
        else parse rest in_frontmatter name desc type_ shared shared_with (line :: acc)
  in
  parse lines false None None None false [] []

let render_entry ~name ?description ?type_ ~shared ?(shared_with=[]) ~body () =
  let buf = Buffer.create 256 in
  Buffer.add_string buf "---\n";
  Buffer.add_string buf (Printf.sprintf "name: %s\n" name);
  (match description with
   | Some d -> Buffer.add_string buf (Printf.sprintf "description: %s\n" d)
   | None -> ());
  (match type_ with
   | Some t -> Buffer.add_string buf (Printf.sprintf "type: %s\n" t)
   | None -> ());
  Buffer.add_string buf (Printf.sprintf "shared: %b\n" shared);
  (match shared_with with
   | [] -> ()
   | xs ->
       Buffer.add_string buf
         (Printf.sprintf "shared_with: [%s]\n" (String.concat ", " xs)));
  Buffer.add_string buf "---\n";
  Buffer.add_string buf body;
  if String.length body = 0 || body.[String.length body - 1] <> '\n'
  then Buffer.add_char buf '\n';
  Buffer.contents buf

let current_alias_or_die () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some a when String.trim a <> "" -> String.trim a
  | _ ->
      Printf.eprintf "error: set C2C_MCP_AUTO_REGISTER_ALIAS to identify the current agent\n%!";
      exit 1

let resolve_alias_arg = function
  | Some a when String.trim a <> "" -> String.trim a
  | _ -> current_alias_or_die ()

(* List markdown entries in a memory dir, sorted by filename. Excludes the
   MEMORY.md index file. *)
let list_entry_files dir =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun n ->
        n <> "MEMORY.md"
        && String.length n > 3
        && String.sub n (String.length n - 3) 3 = ".md")
    |> List.sort String.compare
  with
  | Sys_error _ -> []
  | Unix.Unix_error _ -> []

(* List all alias subdirs under the memory root. Used by global --shared scan. *)
let list_all_aliases () =
  let root = memory_root () in
  try
    Array.to_list (Sys.readdir root)
    |> List.filter (fun n ->
        let p = Filename.concat root n in
        try Sys.is_directory p with Sys_error _ -> false)
    |> List.sort String.compare
  with
  | Sys_error _ -> []
  | Unix.Unix_error _ -> []

(* --- memory list ----------------------------------------------------------- *)

let alias_arg =
  let doc = "Operate against another agent's memory dir. For read, only shared entries are visible cross-agent. For list, shows that alias's entries (or with --shared, just the shared ones). Defaults to the current agent." in
  Cmdliner.Arg.(value & opt (some string) None & info [ "alias"; "a" ] ~docv:"ALIAS" ~doc)

let shared_filter_flag =
  let doc = "Show only entries with shared:true. Without --alias, scans every agent's memory dir for shared entries (cross-agent discovery)." in
  Cmdliner.Arg.(value & flag & info [ "shared" ] ~doc)

let shared_with_me_flag =
  let doc = "Receiver-side filter: show entries (across every alias dir) whose shared_with list contains the current alias. Implies a global scan." in
  Cmdliner.Arg.(value & flag & info [ "shared-with-me" ] ~doc)

let memory_list_cmd =
  let+ json = json_flag
  and+ alias_opt = alias_arg
  and+ shared_only = shared_filter_flag
  and+ shared_with_me = shared_with_me_flag in
  (* Global shared discovery: --shared with no --alias scans every alias dir.
     The design (.collab/design/DRAFT-per-agent-memory.md §"Open Questions" #3)
     resolves this as on-demand flat enumeration. *)
  let global_scan = (shared_only && alias_opt = None) || shared_with_me in
  let me_opt =
    if shared_with_me then Some (current_alias_or_die ()) else None
  in
  let parsed =
    if global_scan then
      List.concat_map (fun alias ->
        let dir = memory_base_dir alias in
        let entries = list_entry_files dir in
        List.filter_map (fun fname ->
          let path = Filename.concat dir fname in
          let e = parse_frontmatter (read_file path) in
          let pass =
            match me_opt with
            | Some me ->
                (* shared-with-me filter: skip own dir; include if alias is
                   in shared_with. shared:true entries are intentionally NOT
                   included here — they're surfaced by --shared. *)
                alias <> me && List.mem me e.shared_with
            | None -> e.shared
          in
          if pass then Some (alias, fname, e) else None)
          entries)
        (list_all_aliases ())
    else begin
      let alias = resolve_alias_arg alias_opt in
      let dir = memory_base_dir alias in
      let entries = list_entry_files dir in
      List.filter_map (fun fname ->
        let path = Filename.concat dir fname in
        let e = parse_frontmatter (read_file path) in
        if shared_only && not e.shared then None
        else Some (alias, fname, e))
        entries
    end
  in
  if json then
    let items = List.map (fun (alias, fname, e) ->
      `Assoc (
        ("alias", `String alias)
        :: ("file", `String fname)
        :: ("name", match e.name with Some n -> `String n | None -> `Null)
        :: ("description", match e.description with Some d -> `String d | None -> `Null)
        :: ("type", match e.type_ with Some t -> `String t | None -> `Null)
        :: ("shared", `Bool e.shared)
        :: ("shared_with", `List (List.map (fun a -> `String a) e.shared_with))
        :: [])
    ) parsed in
    print_json (`List items)
  else if parsed = [] then
    print_endline
      (if shared_with_me then "(no entries shared with you)"
       else if shared_only then "(no shared memory entries)"
       else "(no memory entries)")
  else
    List.iter (fun (alias, fname, e) ->
      Printf.printf "%s/%s%s\n" alias fname
        (match e.name with Some n -> " — " ^ n | None -> "");
      (match e.description with Some d -> Printf.printf "  %s\n" d | None -> ());
      (match e.type_ with Some t -> Printf.printf "  type: %s\n" t | None -> ());
      if e.shared then print_endline "  [shared]";
      (match e.shared_with with
       | [] -> ()
       | xs -> Printf.printf "  [shared_with: %s]\n" (String.concat ", " xs));
      print_endline ""
    ) parsed

(* --- memory read ----------------------------------------------------------- *)

(* Pure privacy-guard predicate: is the caller allowed to read this entry?
   Self-reads (target == current) always pass. Cross-agent reads require:
   - [shared: true] (global), OR
   - the caller's alias appears in [shared_with].
   Returned as a boolean rather than exiting so it's testable. *)
let cross_agent_read_allowed ~target_alias ~current_alias ~entry =
  target_alias = current_alias
  || entry.shared
  || List.mem current_alias entry.shared_with

(* Read entry, then enforce privacy. Exits 1 with a helpful message on
   refusal. Caller-owned reads bypass the check entirely. *)
let read_with_privacy_check ~target_alias ~current_alias ~name path =
  let content = read_file path in
  let e = parse_frontmatter content in
  if not (cross_agent_read_allowed ~target_alias ~current_alias ~entry:e) then (
    Printf.eprintf
      "error: memory entry '%s' in alias '%s' is private. \
       Cross-agent reads require shared:true or the caller's alias \
       in shared_with. Owner can run `c2c memory share %s` to allow \
       global access, or rewrite with --shared-with %s.\n%!"
      name target_alias name current_alias;
    exit 1);
  (content, e)

let memory_read_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Entry name (filename without .md)")
  in
  let+ json = json_flag
  and+ name = name
  and+ alias_opt = alias_arg in
  let target_alias = resolve_alias_arg alias_opt in
  let current_alias = current_alias_or_die () in
  let path = entry_filename target_alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: memory entry '%s' not found in %s\n%!" name target_alias;
    exit 1);
  let (content, e) =
    read_with_privacy_check ~target_alias ~current_alias ~name path
  in
  if json then
    print_json (`Assoc [
      ("alias", `String target_alias);
      ("name", match e.name with Some n -> `String n | None -> `Null);
      ("description", match e.description with Some d -> `String d | None -> `Null);
      ("type", match e.type_ with Some t -> `String t | None -> `Null);
      ("shared", `Bool e.shared);
      ("shared_with", `List (List.map (fun a -> `String a) e.shared_with));
      ("content", `String e.body)
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
  let type_arg =
    let doc = "Memory type (e.g. feedback, reference, note). Free-form tag for grouping." in
    Cmdliner.Arg.(value & opt (some string) None & info [ "type"; "t" ] ~docv:"TYPE" ~doc)
  in
  let shared =
    let doc = "Mark this entry as globally shared (visible to all agents via list --shared)." in
    Cmdliner.Arg.(value & flag & info [ "shared"; "s" ] ~doc)
  in
  let shared_with =
    let doc = "Comma-separated list of aliases granted read access. Receivers can list their inbound entries with `c2c memory list --shared-with-me`. Implies the entry is NOT globally shared (use --shared for that)." in
    Cmdliner.Arg.(value & opt (some string) None & info [ "shared-with" ] ~docv:"ALIAS[,ALIAS...]" ~doc)
  in
  let body =
    Cmdliner.Arg.(non_empty & pos_right 0 string [] & info [] ~docv:"CONTENT" ~doc:"Memory body text (remaining args joined with newlines).")
  in
  let+ json = json_flag
  and+ name = name
  and+ desc = desc
  and+ type_ = type_arg
  and+ shared = shared
  and+ shared_with = shared_with
  and+ body = body in
  let alias = current_alias_or_die () in
  let _ = ensure_memory_dir alias in
  let path = entry_filename alias name in
  let shared_with_list = match shared_with with
    | None -> []
    | Some s ->
        String.split_on_char ',' s
        |> List.map String.trim
        |> List.filter (fun a -> a <> "")
  in
  let content = render_entry ~name ?description:desc ?type_ ~shared
    ~shared_with:shared_with_list
    ~body:(String.concat "\n" body) ()
  in
  write_file path content;
  if json then print_json (`Assoc [("saved", `String name)])
  else Printf.printf "saved: %s\n" name

(* --- memory delete --------------------------------------------------------- *)

let memory_delete_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc:"Entry name to delete")
  in
  let+ json = json_flag
  and+ name = name in
  let alias = current_alias_or_die () in
  let path = entry_filename alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: memory entry '%s' not found\n%!" name;
    exit 1);
  (try Sys.remove path with Sys_error _ -> ());
  if json then print_json (`Assoc [("deleted", `String name)])
  else Printf.printf "deleted: %s\n" name

(* --- memory share / unshare ------------------------------------------------ *)

(* Common helper: load entry, mutate shared flag, rewrite file. *)
let set_shared_flag ~name ~shared =
  let alias = current_alias_or_die () in
  let path = entry_filename alias name in
  if not (Sys.file_exists path) then (
    Printf.eprintf "error: memory entry '%s' not found\n%!" name;
    exit 1);
  let e = parse_frontmatter (read_file path) in
  let entry_name = Option.value e.name ~default:name in
  let new_content = render_entry ~name:entry_name
    ?description:e.description ?type_:e.type_ ~shared
    ~shared_with:e.shared_with ~body:e.body () in
  write_file path new_content

let memory_share_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Entry name to share with other agents.")
  in
  let+ json = json_flag
  and+ name = name in
  set_shared_flag ~name ~shared:true;
  if json then print_json (`Assoc [("shared", `String name)])
  else Printf.printf "shared: %s\n" name

let memory_unshare_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME"
      ~doc:"Entry name to revert to private.")
  in
  let+ json = json_flag
  and+ name = name in
  set_shared_flag ~name ~shared:false;
  if json then print_json (`Assoc [("unshared", `String name)])
  else Printf.printf "unshared: %s\n" name

(* --- group ----------------------------------------------------------------- *)

let memory_default = memory_list_cmd

let memory_group =
  Cmdliner.Cmd.group ~default:memory_default
    (Cmdliner.Cmd.info "memory" ~doc:"Manage per-agent memory entries.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List memory entries.") memory_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "read" ~doc:"Read a memory entry.") memory_read_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "write" ~doc:"Write a memory entry.") memory_write_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "delete" ~doc:"Delete a memory entry.") memory_delete_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "share" ~doc:"Mark a memory entry as shared.") memory_share_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "unshare" ~doc:"Revert a memory entry to private.") memory_unshare_cmd ]
