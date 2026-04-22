(* c2c_role — canonical role file parser and client renderers *)

type t = {
  description : string;
  role : string;
  model : string option;
  c2c_alias : string option;
  c2c_auto_join_rooms : string list;
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
  c2c_alias = None;
  c2c_auto_join_rooms = [];
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
  List.iter (fun line ->
    let line = String.trim line in
    if line = "" || starts_with line '#' then ()
    else if starts_with line '-' then (
      (* multi-line list item: accumulate under current_list_key *)
      let item = String.trim (String.sub line 1 (String.length line - 1)) in
      list_items := item :: !list_items
    ) else
      match String.index_opt line ':' with
      | None -> ()
      | Some colon_pos ->
          flush_list ();
          let key = String.sub line 0 colon_pos in
          let rest = String.trim (String.sub line (colon_pos + 1) (String.length line - colon_pos - 1)) in
          if rest = "" then
            current_section := key
          else
            let full_key = if !current_section = "" then key else !current_section ^ "." ^ key in
            if starts_with rest '[' then
              (* inline flow sequence: parse immediately and store *)
              let items = parse_list rest in
              entries := (full_key, "[" ^ String.concat ", " items ^ "]") :: !entries
            else
              entries := (full_key, trim_quotes rest) :: !entries
  ) fm_lines;
  flush_list ();
  List.rev !entries

let assoc_find k alist = try Some (List.assoc k alist) with Not_found -> None

let parse_string content =
  let fm_lines, body_lines = split_frontmatter content in
  let entries = parse_yaml_entries fm_lines in
  let find k = assoc_find k entries in
  let find_section sec =
    List.filter (fun (k, _) -> String.length k > String.length sec + 1 &&
                               String.sub k 0 (String.length sec + 1) = sec ^ ".") entries
    |> List.map (fun (k, v) -> (String.sub k (String.length sec + 1) (String.length k - String.length sec - 1), v))
  in
  {
    description = (match find "description" with Some v -> v | None -> "");
    role = (match find "role" with Some v -> v | None -> "subagent");
    model = find "model";
    c2c_alias = find "c2c.alias";
    c2c_auto_join_rooms =
      (match find "c2c.auto_join_rooms" with Some v -> parse_list v | None -> []);
    opencode = find_section "opencode";
    claude = find_section "claude";
    codex = find_section "codex";
    kimi = find_section "kimi";
    body = String.concat "\n" body_lines |> String.trim;
  }

let parse_file path =
  let ic = open_in path in
  let content = Fun.protect ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))
  in
  parse_string content

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
    if r.opencode <> [] then begin
      lines := "opencode:" :: !lines;
      List.iter (fun (k, v) ->
        lines := ("  " ^ k ^ ": " ^ yaml_scalar v) :: !lines
      ) r.opencode;
    end;
    if r.c2c_alias <> None || r.c2c_auto_join_rooms <> [] then begin
      lines := "c2c:" :: !lines;
      (match r.c2c_alias with Some a -> lines := ("  alias: " ^ a) :: !lines | None -> ());
      if r.c2c_auto_join_rooms <> [] then
        lines := ("  auto_join_rooms: [" ^ String.concat ", " r.c2c_auto_join_rooms ^ "]") :: !lines;
    end;
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
        lines := ("  " ^ k ^ ": " ^ yaml_scalar v) :: !lines
      ) r.claude;
    end;
    let fm = String.concat "\n" (List.rev !lines) in
    "---\n" ^ fm ^ "\n---\n\n" ^ r.body
end
