type t =
  | Claude_channel
  | Codex_xml_fd
  | Codex_headless_thread_id_fd

let to_string = function
  | Claude_channel -> "claude_channel"
  | Codex_xml_fd -> "codex_xml_fd"
  | Codex_headless_thread_id_fd -> "codex_headless_thread_id_fd"

let all = [ Claude_channel; Codex_xml_fd; Codex_headless_thread_id_fd ]

let of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "claude_channel" -> Some Claude_channel
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
