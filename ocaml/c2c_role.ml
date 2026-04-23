(* c2c_role — canonical role file parser and client renderers *)

type t = {
  description : string;
  role : string;
  model : string option;
  (* pmodel: optional per-role-file provider:model override. Wins over the
     class-level [pmodel] table in .c2c/config.toml when set. Format is the
     same as the config.toml values: "provider:model", or with a leading
     ':' prefix char if the model itself contains colons.
     Example frontmatter: pmodel: ":groq:openai/gpt-oss-120b" *)
  pmodel : string option;
  (* role_class: explicit declaration of which class-level pmodel bucket this
     role falls into (coder, coordinator, orchestrator, reviewer, researcher,
     release, qa, gui, …). When unset, resolvers fall back to "default". *)
  role_class : string option;
  c2c_alias : string option;
  c2c_auto_join_rooms : string list;
  include_ : string list;
  compatible_clients : string list;
  required_capabilities : string list;
  opencode : (string * string) list;
  claude : (string * string) list;
  codex : (string * string) list;
  kimi : (string * string) list;
  body : string;
}

let empty = {
  description = "";
  role = "subagent";
  model = None;
  pmodel = None;
  role_class = None;
  c2c_alias = None;
  c2c_auto_join_rooms = [];
  include_ = [];
  compatible_clients = [];
  required_capabilities = [];
  opencode = [];
  claude = [];
  codex = [];
  kimi = [];
  body = "";
}

let trim_quotes s =
  let s = String.trim s in
  if String.length s >= 2 then
    if (s.[0] = '"' && s.[String.length s - 1] = '"') ||
       (s.[0] = '\'' && s.[String.length s - 1] = '\'') then
      String.sub s 1 (String.length s - 2)
    else s
  else s

let parse_list s =
  let s = String.trim s in
  if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']' then
    let inner = String.sub s 1 (String.length s - 2) in
    let items = String.split_on_char ',' inner in
    List.filter (fun x -> String.trim x <> "") (List.map (fun item -> trim_quotes (String.trim item)) items)
  else [trim_quotes s]

let split_frontmatter content =
  let lines = String.split_on_char '\n' content in
  let rec skip_leading_empty = function
    | [] -> []
    | "" :: rest -> skip_leading_empty rest
    | l :: _ as all -> all
  in
  let lines = skip_leading_empty lines in
  let rec find_end acc = function
    | [] -> (List.rev acc, [])
    | line :: rest ->
        if String.trim line = "---" then (List.rev acc, rest)
        else find_end (line :: acc) rest
  in
  match lines with
  | [] -> ([], [])
  | line :: rest when String.trim line = "---" -> find_end [] rest
  | _ -> ([], lines)

let starts_with s c =
  String.length s > 0 && s.[0] = c

let is_section_key fm_lines idx =
  let n = List.length fm_lines in
  let rec skip_empty acc =
    if acc >= n then None
    else let line = List.nth fm_lines acc in
         if line = "" || starts_with (String.trim line) '#' then skip_empty (acc + 1)
         else Some line
  in
  match skip_empty (idx + 1) with
  | None -> false
  | Some next -> starts_with next ' ' || starts_with next '\t'

let is_list_section_key fm_lines idx =
  let n = List.length fm_lines in
  let rec skip_empty acc =
    if acc >= n then None
    else let line = List.nth fm_lines acc in
         if line = "" || starts_with (String.trim line) '#' then skip_empty (acc + 1)
         else Some line
  in
  match skip_empty (idx + 1) with
  | None -> false
  | Some next -> starts_with (String.trim next) '-' 

let parse_yaml_entries fm_lines =
  let entries = ref [] in
  let current_section = ref "" in
  let current_list_key = ref "" in
  let list_items = ref [] in
  let flush_list () =
    if !current_list_key <> "" && !list_items <> [] then
      entries := (!current_list_key, "[" ^ String.concat ", " (List.rev !list_items) ^ "]") :: !entries;
    current_list_key := "";
    list_items := []
  in
  let n = List.length fm_lines in
  for i = 0 to n - 1 do
    let raw_line = List.nth fm_lines i in
    let line = String.trim raw_line in
    if line = "" || starts_with line '#' then ()
    else if starts_with line '-' then (
      let item = String.sub raw_line 1 (String.length raw_line - 1) |> String.trim in
      list_items := item :: !list_items
    ) else
      match String.index_opt line ':' with
      | None -> ()
      | Some colon_pos ->
          flush_list ();
          let key = String.sub line 0 colon_pos in
          let rest_trimmed = String.trim (String.sub line (colon_pos + 1) (String.length line - colon_pos - 1)) in
          let is_root = raw_line.[0] <> ' ' && raw_line.[0] <> '\t' in
          if is_root && not (is_list_section_key fm_lines i) then current_section := "";
          let full_key = if !current_section = "" then key else !current_section ^ "." ^ key in
          if rest_trimmed = "" && is_section_key fm_lines i && not (is_list_section_key fm_lines i) then
            current_section := full_key
          else if rest_trimmed = "" then
            entries := (full_key, "") :: !entries
          else if starts_with rest_trimmed '[' then
            let vals = parse_list rest_trimmed in
            entries := (full_key, "[" ^ String.concat ", " vals ^ "]") :: !entries
          else
            entries := (full_key, trim_quotes rest_trimmed) :: !entries
  done;
  flush_list ();
  List.rev !entries

let assoc_find k alist = try Some (List.assoc k alist) with Not_found -> None

let load_snippet snippets_dir name =
  let path = Filename.concat snippets_dir (name ^ ".md") in
  if Sys.file_exists path then
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  else
    ""

let resolve_includes t snippets_dir =
  if t.include_ = [] then t
  else
    let snippet_bodies = List.map (load_snippet snippets_dir) t.include_ in
    let combined_snippets = String.concat "\n\n" (List.filter ((<>) "") snippet_bodies) in
    let new_body = if combined_snippets = "" then t.body
                   else if t.body = "" then combined_snippets
                   else combined_snippets ^ "\n\n" ^ t.body in
    { t with body = new_body }

let lint_body_injection (body : string) ~(filename : string) =
  let open_tag = "<c2c " in
  let close_tag = "</c2c>" in
  let rec scan line_num lines =
    match lines with
    | [] -> ()
    | line :: rest ->
        let trimmed = String.trim line in
        if String.length trimmed >= String.length open_tag &&
           String.sub trimmed 0 (String.length open_tag) = open_tag then
          Printf.eprintf "warning: %s:%d: possible c2c event injection detected\n%!"
            filename line_num
        else if String.length trimmed >= String.length close_tag &&
                String.sub trimmed 0 (String.length close_tag) = close_tag then
          Printf.eprintf "warning: %s:%d: possible c2c event injection detected (closing tag)\n%!"
            filename line_num;
        scan (line_num + 1) rest
  in
  scan 1 (String.split_on_char '\n' body)

let parse_string ?(snippets_dir = ".c2c/snippets") ?(filename = "(string)") content =
  let fm_lines, body_lines = split_frontmatter content in
  let entries = parse_yaml_entries fm_lines in
  let find k = assoc_find k entries in
  let find_section sec =
    List.filter (fun (k, _) -> String.length k > String.length sec + 1 &&
                               String.sub k 0 (String.length sec + 1) = sec ^ ".") entries
    |> List.map (fun (k, v) -> (k, v))
  in
  let body = String.concat "\n" body_lines |> String.trim in
  lint_body_injection body ~filename;
  let t = {
    description = (match find "description" with Some v -> v | None -> "");
    role = (match find "role" with Some v -> v | None -> "subagent");
    model = find "model";
    pmodel = find "pmodel";
    role_class = find "role_class";
    c2c_alias = find "c2c.alias";
    c2c_auto_join_rooms =
      (match find "c2c.auto_join_rooms" with Some v -> parse_list v | None -> []);
    include_ = (match find "include" with Some v -> parse_list v | None -> []);
    compatible_clients =
      (match find "compatible_clients" with Some v -> parse_list v | None -> []);
    required_capabilities =
      (match find "required_capabilities" with Some v -> parse_list v | None -> []);
    opencode = find_section "opencode";
    claude = find_section "claude";
    codex = find_section "codex";
    kimi = find_section "kimi";
    body;
  } in
  resolve_includes t snippets_dir

let parse_file path =
  let ic = open_in path in
  let content = Fun.protect ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
  in
  let role_dir = Filename.dirname path in
  let snippets_dir =
    if Filename.basename role_dir = "roles" then
      Filename.concat (Filename.dirname role_dir) "snippets"
    else
      Filename.concat role_dir ".c2c/snippets"
  in
  parse_string ~snippets_dir ~filename:path content

(* Resolve the effective provider:model pmodel for this role.
   Resolution chain (highest → lowest precedence):
     1. Role file frontmatter `pmodel: "..."` (t.pmodel)
     2. [pmodel] table in .c2c/config.toml keyed by role_class
        (t.role_class, looked up via class_lookup)
     3. [pmodel] default key in .c2c/config.toml (class_lookup "default")
     4. None (caller decides the built-in fallback).
   `class_lookup` is typically `C2c_start.repo_config_pmodel_lookup` — passed
   in as a callback so this module has no dependency on c2c_start. The
   return values are raw pmodel strings (provider:model form, possibly with
   leading ':'), just like the role-file field — parsing is the caller's job
   (use C2c_start.parse_pmodel). *)
let resolve_pmodel (t : t) ~(class_lookup : string -> string option) : string option =
  match t.pmodel with
  | Some _ as m -> m
  | None ->
    let from_class = match t.role_class with
      | Some rc -> class_lookup rc
      | None -> None
    in
    (match from_class with
     | Some _ as m -> m
     | None -> class_lookup "default")

(* Renderers *)

let yaml_scalar s =
  if s = "" || String.length s > 0 && (String.contains s ':' || String.contains s '#' ||
     String.contains s '"' || String.contains s '\'') then
    "\"" ^ String.escaped s ^ "\""
  else s

module OpenCode_renderer = struct
  let render r =
    let lines = ref [] in
    lines := ("description: " ^ yaml_scalar r.description) :: !lines;
    lines := ("role: " ^ r.role) :: !lines;
    (match r.model with Some m -> lines := ("model: " ^ m) :: !lines | None -> ());
    if r.c2c_alias <> None || r.c2c_auto_join_rooms <> [] then begin
      lines := "c2c:" :: !lines;
      (match r.c2c_alias with Some a -> lines := ("  alias: " ^ a) :: !lines | None -> ());
      if r.c2c_auto_join_rooms <> [] then
        lines := ("  auto_join_rooms: [" ^ String.concat ", " r.c2c_auto_join_rooms ^ "]") :: !lines;
    end;
    let rec emit_entries current_section entries =
      match entries with
      | [] -> ()
      | (k, v) :: rest ->
          let dot_idx = String.index_opt k '.' in
          let section = match dot_idx with Some i -> String.sub k 0 i | None -> k in
          if section <> current_section then (
            lines := (section ^ ":") :: !lines;
            emit_entries section ((k, v) :: rest)
          ) else (
            let field_name = match dot_idx with Some i -> String.sub k (i + 1) (String.length k - i - 1) | None -> k in
            lines := ("  " ^ field_name ^ ": " ^ yaml_scalar v) :: !lines;
            emit_entries current_section rest
          )
    in
    let has_steps = List.mem ("opencode.steps", "") r.opencode
      || List.exists (fun (k, _) -> k = "opencode.steps") r.opencode in
    let opencode_with_default =
      if has_steps then r.opencode
      else r.opencode @ [("opencode.steps", "9999")]
    in
    let all_entries = opencode_with_default @ r.claude @ r.codex @ r.kimi in
    emit_entries "" all_entries;
    let fm = String.concat "\n" (List.rev !lines) in
    "---\n" ^ fm ^ "\n---\n\n" ^ r.body
end

module Claude_renderer = struct
  let render r =
    let lines = ref [] in
    lines := ("description: " ^ yaml_scalar r.description) :: !lines;
    lines := ("role: " ^ r.role) :: !lines;
    (match r.model with Some m -> lines := ("model: " ^ m) :: !lines | None -> ());
    if r.c2c_alias <> None || r.c2c_auto_join_rooms <> [] then begin
      lines := "# c2c:" :: !lines;
      (match r.c2c_alias with Some a -> lines := ("#   alias: " ^ a) :: !lines | None -> ());
      if r.c2c_auto_join_rooms <> [] then
        lines := ("#   auto_join_rooms: [" ^ String.concat ", " r.c2c_auto_join_rooms ^ "]") :: !lines;
    end;
    if r.claude <> [] then begin
      lines := "claude:" :: !lines;
      List.iter (fun (k, v) ->
        let field_name = if String.length k > 7 && String.sub k 0 7 = "claude." then
                          String.sub k 7 (String.length k - 7)
                        else k in
        lines := ("  " ^ field_name ^ ": " ^ yaml_scalar v) :: !lines
      ) r.claude;
    end;
    let fm = String.concat "\n" (List.rev !lines) in
    "---\n" ^ fm ^ "\n---\n\n" ^ r.body
end

module Codex_renderer = struct
  let render r =
    let lines = ref [] in
    lines := ("description: " ^ yaml_scalar r.description) :: !lines;
    lines := ("role: " ^ r.role) :: !lines;
    (match r.model with Some m -> lines := ("model: " ^ m) :: !lines | None -> ());
    if r.c2c_alias <> None || r.c2c_auto_join_rooms <> [] then begin
      lines := "# c2c:" :: !lines;
      (match r.c2c_alias with Some a -> lines := ("#   alias: " ^ a) :: !lines | None -> ());
      if r.c2c_auto_join_rooms <> [] then
        lines := ("#   auto_join_rooms: [" ^ String.concat ", " r.c2c_auto_join_rooms ^ "]") :: !lines;
    end;
    if r.codex <> [] then begin
      lines := "codex:" :: !lines;
      List.iter (fun (k, v) ->
        let field_name = if String.length k > 6 && String.sub k 0 6 = "codex." then
                          String.sub k 6 (String.length k - 6)
                        else k in
        lines := ("  " ^ field_name ^ ": " ^ yaml_scalar v) :: !lines
      ) r.codex;
    end;
    let fm = String.concat "\n" (List.rev !lines) in
    "---\n" ^ fm ^ "\n---\n\n" ^ r.body
end

module Kimi_renderer = struct
  let render r =
    let lines = ref [] in
    lines := ("description: " ^ yaml_scalar r.description) :: !lines;
    lines := ("role: " ^ r.role) :: !lines;
    (match r.model with Some m -> lines := ("model: " ^ m) :: !lines | None -> ());
    if r.c2c_alias <> None || r.c2c_auto_join_rooms <> [] then begin
      lines := "# c2c:" :: !lines;
      (match r.c2c_alias with Some a -> lines := ("#   alias: " ^ a) :: !lines | None -> ());
      if r.c2c_auto_join_rooms <> [] then
        lines := ("#   auto_join_rooms: [" ^ String.concat ", " r.c2c_auto_join_rooms ^ "]") :: !lines;
    end;
    if r.kimi <> [] then begin
      lines := "kimi:" :: !lines;
      List.iter (fun (k, v) ->
        let field_name = if String.length k > 5 && String.sub k 0 5 = "kimi." then
                          String.sub k 5 (String.length k - 5)
                        else k in
        lines := ("  " ^ field_name ^ ": " ^ yaml_scalar v) :: !lines
      ) r.kimi;
    end;
    let fm = String.concat "\n" (List.rev !lines) in
    "---\n" ^ fm ^ "\n---\n\n" ^ r.body
end
