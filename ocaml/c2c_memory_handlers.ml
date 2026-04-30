(* #450 Slice 1: per-agent memory MCP handlers (memory_list / memory_read /
   memory_write) hoisted out of [c2c_mcp.ml]. The original
   [module Memory_handlers = struct ... end] block is preserved as an alias
   in [c2c_mcp.ml] so external callers continue to use [Memory_handlers.X]
   inside that module's scope. *)

open C2c_mcp_helpers
open C2c_mcp_helpers_post_broker
module Broker = C2c_broker

let parse_frontmatter content =
  let lines = String.split_on_char '\n' content in
  let rec parse lines in_fm name desc shared shared_with acc =
    match lines with
    | [] -> (name, desc, shared, shared_with, List.rev acc)
    | line :: rest ->
        let line = String.trim line in
        if line = "---" then parse rest (not in_fm) name desc shared shared_with acc
        else if in_fm then
          if 0 = String.length line then parse rest in_fm name desc shared shared_with acc
          else if Str.string_match (Str.regexp "^name:[ ]*\\(.+\\)$") line 0
          then parse rest in_fm (Some (Str.matched_group 1 line)) desc shared shared_with acc
          else if Str.string_match (Str.regexp "^description:[ ]*\\(.+\\)$") line 0
          then parse rest in_fm name (Some (Str.matched_group 1 line)) shared shared_with acc
          else if Str.string_match (Str.regexp "^shared:[ ]*\\(true\\|false\\)$") line 0
          then parse rest in_fm name desc (Str.matched_group 1 line = "true") shared_with acc
          else if Str.string_match (Str.regexp "^shared_with:[ ]*\\(.+\\)$") line 0
          then parse rest in_fm name desc shared (parse_alias_list (Str.matched_group 1 line)) acc
          else parse rest in_fm name desc shared shared_with acc
        else parse rest in_fm name desc shared shared_with (line :: acc)
  in
  parse lines false None None false [] []

let handle_memory_list ~(broker : Broker.t) ~session_id_override ~arguments =
  let shared_with_me =
    try match arguments |> Yojson.Safe.Util.member "shared_with_me" with `Bool b -> b | _ -> false
    with _ -> false
  in
  let read_file = C2c_io.read_file_opt in
  let list_md_entries dir =
    try
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun n -> String.length n > 3 && String.sub n (String.length n - 3) 3 = ".md")
      |> List.sort String.compare
    with Sys_error _ -> []
  in
  let render_item alias mname desc shared shared_with =
    `Assoc (
      ("alias", `String alias)
      :: ("name", match mname with Some n -> `String n | None -> `Null)
      :: ("description", match desc with Some d -> `String d | None -> `Null)
      :: ("shared", `Bool shared)
      :: ("shared_with", `List (List.map (fun a -> `String a) shared_with))
      :: [])
  in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "memory_list")
   | Some alias ->
       let items =
         if shared_with_me then begin
           let root = Filename.dirname (memory_base_dir alias) in
           let aliases =
             try
               Array.to_list (Sys.readdir root)
               |> List.filter (fun n ->
                   let p = Filename.concat root n in
                   try Sys.is_directory p with Sys_error _ -> false)
               |> List.sort String.compare
             with Sys_error _ -> []
           in
           List.concat_map (fun a ->
             if a = alias then []
             else
               let dir = Filename.concat root a in
               List.filter_map (fun fname ->
                 let path = Filename.concat dir fname in
                 let (mname, desc, shared, shared_with, _) =
                   parse_frontmatter (read_file path) in
                 if List.mem alias shared_with
                 then Some (render_item a mname desc shared shared_with)
                 else None)
               (list_md_entries dir))
             aliases
         end else begin
           let dir = memory_base_dir alias in
           List.map (fun name ->
             let path = Filename.concat dir name in
             let (mname, desc, shared, shared_with, _) =
               parse_frontmatter (read_file path) in
             render_item alias mname desc shared shared_with)
             (list_md_entries dir)
         end
       in
        Lwt.return (tool_ok (`List items |> Yojson.Safe.to_string)))

let handle_memory_read ~(broker : Broker.t) ~session_id_override ~arguments =
  let entry_path = memory_entry_path in
  let name = string_member "name" arguments in
  let caller_alias =
    match current_registered_alias ?session_id_override:session_id_override broker with
    | Some a -> Some a
    | None -> auto_register_alias ()
  in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "memory_read")
   | Some alias ->
       let path = entry_path alias name in
       if not (Sys.file_exists path) then
         Lwt.return (tool_err ("memory entry not found: " ^ name))
       else
         let content =
           try
             let ic = open_in path in
             Fun.protect ~finally:(fun () -> close_in ic)
               (fun () -> really_input_string ic (in_channel_length ic))
           with _ -> ""
         in
         if content = "" then
           Lwt.return (tool_err ("error reading memory entry: " ^ name))
         else
           let (mname, desc, shared, shared_with, body) = parse_frontmatter content in
           let is_self =
             match caller_alias with
             | Some a -> a = alias
             | None -> false
           in
           let in_shared_with =
             match caller_alias with
             | Some a -> List.mem a shared_with
             | None -> false
           in
            if (not is_self) && (not shared) && (not in_shared_with) then
              Lwt.return (tool_err (Printf.sprintf
                "memory entry '%s' in alias '%s' is private. \
                 Cross-agent reads require shared:true or the caller's \
                 alias in shared_with."
                name alias))
           else
             let result = `Assoc [
               ("alias", `String alias);
               ("name", match mname with Some n -> `String n | None -> `Null);
               ("description", match desc with Some d -> `String d | None -> `Null);
               ("shared", `Bool shared);
               ("shared_with", `List (List.map (fun a -> `String a) shared_with));
               ("content", `String (String.concat "\n" body))
             ] |> Yojson.Safe.to_string in
             Lwt.return (tool_ok result))

let handle_memory_write ~(broker : Broker.t) ~session_id_override ~arguments =
  let entry_path = memory_entry_path in
  let name = string_member "name" arguments in
  let desc = optional_string_member "description" arguments in
  let shared =
    try match arguments |> Yojson.Safe.Util.member "shared" with `Bool b -> b | _ -> false
    with _ -> false
  in
  let shared_with =
    let raw =
      match arguments |> Yojson.Safe.Util.member "shared_with" with
      | `String s -> s
      | `List xs ->
          List.filter_map (fun j ->
            match j with `String s -> Some s | _ -> None) xs
          |> String.concat ","
      | _ -> ""
    in
    String.split_on_char ',' raw
    |> List.map String.trim
    |> List.filter (fun a -> a <> "")
  in
  let body_content = string_member "content" arguments in
  (match alias_for_current_session_or_argument ?session_id_override:session_id_override broker arguments with
   | None -> Lwt.return (missing_member_alias_result "memory_write")
   | Some alias ->
       let dir = memory_base_dir alias in
       mkdir_p dir;
       let path = entry_path alias name in
       let shared_with_line =
         match shared_with with
         | [] -> ""
         | xs -> Printf.sprintf "shared_with: [%s]\n" (String.concat ", " xs)
       in
       let fm_content =
         Printf.sprintf "---\nname: %s\ndescription: %s\nshared: %b\n%s---\n%s\n"
           name (Option.value desc ~default:"") shared shared_with_line body_content
       in
       try
         let oc = open_out path in
         Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
           output_string oc fm_content);
         let notified =
           notify_shared_with_recipients
             ~broker ~from_alias:alias ~name ?description:desc
             ~shared ~shared_with ()
         in
         let result =
           `Assoc [
             ("saved", `String name)
           ; ("notified", `List (List.map (fun a -> `String a) notified))
           ] |> Yojson.Safe.to_string
         in
         Lwt.return (tool_ok result)
       with _ ->
         Lwt.return (tool_err ("error writing memory entry: " ^ name)))
