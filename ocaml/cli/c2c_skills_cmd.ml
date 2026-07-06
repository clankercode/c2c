(* c2c_skills_cmd - skills subcommands and startup fast paths.
   Extracted from c2c.ml as part of the architecture refactoring. *)

open Cmdliner.Term.Syntax
open C2c_cli_helpers

let ( // ) = Filename.concat

let skills_dir () = Sys.getcwd () // ".opencode" // "skills"

let list_subdirs dir =
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun name ->
      let path = dir // name in
      try Sys.is_directory path with _ -> false)
  with _ -> []

let read_first_lines path n =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let lines = ref [] in
      for _i = 1 to n do
        match input_line ic with
        | line -> lines := line :: !lines
        | exception End_of_file -> ()
      done;
      List.rev !lines)
  with _ -> []

let parse_skill_frontmatter dir name =
  let skill_md = dir // name // "SKILL.md" in
  let lines = read_first_lines skill_md 10 in
  let name_ref = ref None in
  let desc_ref = ref None in
  let strip_quotes s =
    let len = String.length s in
    if len >= 2 && s.[0] = '"' && s.[len - 1] = '"'
    then String.sub s 1 (len - 2)
    else s
  in
  let in_frontmatter = ref false in
  List.iter (fun line ->
    let line = String.trim line in
    if line = "---" then in_frontmatter := not !in_frontmatter
    else if !in_frontmatter then
      if Str.string_match (Str.regexp "^name:[ ]*\\([^ ].*\\)$") line 0
      then name_ref := Some (Str.matched_group 1 line)
      else if Str.string_match (Str.regexp "^description:[ ]*\\(\".*\"\\)$") line 0
      then desc_ref := Some (strip_quotes (Str.matched_group 1 line))
      else if Str.string_match (Str.regexp "^description:[ ]*\\([^ ].*\\)$") line 0
      then desc_ref := Some (Str.matched_group 1 line)
  ) lines;
  (!name_ref, !desc_ref)

let skills_list_cmd =
  let json = json_flag in
  let+ json = json in
  let dir = skills_dir () in
  let names = list_subdirs dir in
  if json then
    let skills = List.map (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      `Assoc ([ ("id", `String name) ]
        @ (match parsed_name with Some n -> [ ("name", `String n) ] | None -> [])
        @ (match desc with Some d -> [ ("description", `String d) ] | None -> []))
    ) names in
    print_json (`List skills)
  else
    List.iter (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      Printf.printf "%s\n" name;
      (match parsed_name with Some n -> Printf.printf "  name: %s\n" n | None -> ());
      (match desc with Some d -> Printf.printf "  description: %s\n" d | None -> ());
      print_newline ()
    ) names

let skills_serve_cmd =
  let name =
    Cmdliner.Arg.(required & pos 0 (some string) None & info []
      ~docv:"SKILL" ~doc:"Skill name (directory name under .opencode/skills/)")
  in
  let+ name = name in
  let dir = skills_dir () in
  let skill_md = dir // name // "SKILL.md" in
  try
    let content = read_first_lines skill_md 10000 in
    List.iter (fun line -> Printf.printf "%s\n" line) content
  with _ ->
    Printf.eprintf "error: skill '%s' not found in %s\n%!" name dir;
    exit 1

let skills_group =
  Cmdliner.Cmd.group
    ~default:skills_list_cmd
    (Cmdliner.Cmd.info "skills" ~doc:"List and serve c2c swarm skills.")
    [ Cmdliner.Cmd.v (Cmdliner.Cmd.info "list" ~doc:"List all available skills.") skills_list_cmd
    ; Cmdliner.Cmd.v (Cmdliner.Cmd.info "serve" ~doc:"Print a skill's full content.") skills_serve_cmd ]

let fast_path_skills_list ~json () =
  let dir = skills_dir () in
  let names = list_subdirs dir in
  if json then
    let skills = List.map (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      `Assoc ([ ("id", `String name) ]
        @ (match parsed_name with Some n -> [ ("name", `String n) ] | None -> [])
        @ (match desc with Some d -> [ ("description", `String d) ] | None -> []))
    ) names in
    print_json (`List skills)
  else
    List.iter (fun name ->
      let (parsed_name, desc) = parse_skill_frontmatter dir name in
      Printf.printf "%s\n" name;
      (match parsed_name with Some n -> Printf.printf "  name: %s\n" n | None -> ());
      (match desc with Some d -> Printf.printf "  description: %s\n" d | None -> ());
      print_newline ()
    ) names

let fast_path_skills_serve name =
  let dir = skills_dir () in
  let skill_md = dir // name // "SKILL.md" in
  try
    let ic = open_in skill_md in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      let rec copy_all () =
        try
          print_endline (input_line ic);
          copy_all ()
        with End_of_file -> ()
      in
      copy_all ())
  with _ ->
    Printf.eprintf "error: skill '%s' not found in %s\n%!" name dir;
    exit 1
