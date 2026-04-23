type t =
  | Claude_channel
  | Opencode_plugin
  | Opencode_plugin_active
  | Pty_inject
  | Kimi_wire
  | Codex_xml_fd
  | Codex_headless_thread_id_fd

let to_string = function
  | Claude_channel -> "claude_channel"
  | Opencode_plugin -> "opencode_plugin"
  | Opencode_plugin_active -> "opencode_plugin_active"
  | Pty_inject -> "pty_inject"
  | Kimi_wire -> "kimi_wire"
  | Codex_xml_fd -> "codex_xml_fd"
  | Codex_headless_thread_id_fd -> "codex_headless_thread_id_fd"

let all =
  [ Claude_channel
  ; Opencode_plugin
  ; Opencode_plugin_active
  ; Pty_inject
  ; Kimi_wire
  ; Codex_xml_fd
  ; Codex_headless_thread_id_fd
  ]

let of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "claude_channel" -> Some Claude_channel
  | "opencode_plugin" -> Some Opencode_plugin
  | "opencode_plugin_active" -> Some Opencode_plugin_active
  | "pty_inject" -> Some Pty_inject
  | "kimi_wire" -> Some Kimi_wire
  | "codex_xml_fd" -> Some Codex_xml_fd
  | "codex_headless_thread_id_fd" -> Some Codex_headless_thread_id_fd
  | _ -> None

let missing_required ~required ~available =
  let mem value = List.mem value available in
  List.filter
    (fun name ->
      match of_string name with
      | Some known -> not (mem (to_string known))
      | None -> true)
    required

let has available capability =
  List.mem (to_string capability) available

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match assoc_opt name json with Some (`String value) -> Some value | _ -> None

let initialize_has_claude_channel request =
  let channel_capability =
    match assoc_opt "params" request with
    | None -> None
    | Some params -> (
        match assoc_opt "capabilities" params with
        | None -> None
        | Some capabilities -> (
            match assoc_opt "experimental" capabilities with
            | None -> None
            | Some experimental -> assoc_opt "claude/channel" experimental))
  in
  match channel_capability with
  | Some (`Bool false) | Some `Null | None -> false
  | Some _ -> true

let negotiated_in_initialize ~current request =
  match string_field "method" request with
  | Some "initialize" ->
      if initialize_has_claude_channel request then
        let cap = to_string Claude_channel in
        if List.mem cap current then current else current @ [ cap ]
      else
        List.filter ((<>) (to_string Claude_channel)) current
  | _ -> current
