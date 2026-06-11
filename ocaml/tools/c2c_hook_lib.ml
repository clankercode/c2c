(* c2c_hook_lib — shared stdin-parsing + inbox-drain logic for Claude hooks
 *
 * Used by both c2c_inbox_hook (PostToolUse) and c2c_stop_hook (Stop).
 * Factored to avoid duplication and ensure consistent session_id parsing.
 *)

let max_stdin_scan_bytes = 64 * 1024

let extract_json_string_field_prefix ~field raw =
  let len = String.length raw in
  let skip_ws i =
    let rec loop j =
      if j >= len then j
      else
        match raw.[j] with
        | ' ' | '\n' | '\r' | '\t' -> loop (j + 1)
        | _ -> j
    in
    loop i
  in
  let parse_string i =
    if i >= len || raw.[i] <> '"' then None
    else
      let b = Buffer.create 32 in
      let rec loop j =
        if j >= len then None
        else
          match raw.[j] with
          | '"' -> Some (Buffer.contents b, j + 1)
          | '\\' when j + 1 < len ->
              let c =
                match raw.[j + 1] with
                | '"' -> '"'
                | '\\' -> '\\'
                | '/' -> '/'
                | 'b' -> '\b'
                | 'f' -> '\012'
                | 'n' -> '\n'
                | 'r' -> '\r'
                | 't' -> '\t'
                | c -> c
              in
              Buffer.add_char b c;
              loop (j + 2)
          | '\\' -> None
          | c ->
              Buffer.add_char b c;
              loop (j + 1)
      in
      loop (i + 1)
  in
  let rec scan i depth =
    if i >= len then None
    else
      match raw.[i] with
      | '"' ->
          (match parse_string i with
           | None -> None
           | Some (key, next_i) ->
               if depth = 1 && key = field then
                 let colon_i = skip_ws next_i in
                 if colon_i < len && raw.[colon_i] = ':' then
                   let value_i = skip_ws (colon_i + 1) in
                   match parse_string value_i with
                   | Some (value, _) when String.trim value <> "" ->
                       Some (String.trim value)
                   | _ -> None
                 else scan next_i depth
               else scan next_i depth)
      | '{' | '[' -> scan (i + 1) (depth + 1)
      | '}' | ']' -> scan (i + 1) (max 0 (depth - 1))
      | _ -> scan (i + 1) depth
  in
  scan 0 0

let read_stdin_session_id () =
  let chunk_size = 4096 in
  let chunk = Bytes.create chunk_size in
  let buf = Buffer.create 4096 in
  let rec loop remaining =
    if remaining <= 0 then None
    else
      let want = min chunk_size remaining in
      match input stdin chunk 0 want with
      | 0 ->
          extract_json_string_field_prefix ~field:"session_id"
            (Buffer.contents buf)
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          let raw = Buffer.contents buf in
          (match extract_json_string_field_prefix ~field:"session_id" raw with
           | Some _ as found -> found
           | None -> loop (remaining - n))
  in
  try loop max_stdin_scan_bytes with _ -> None

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

let global_inbox_exists ~root ~session_id =
  Sys.file_exists (Filename.concat root (session_id ^ ".inbox.json"))

let drain_repo_messages ~broker_root ~session_id =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then begin
    prerr_endline
      (Printf.sprintf
         "[hook] skipping drain — session %s is channel-capable; \
          watcher owns delivery"
         session_id);
    (broker, [])
  end else
    ( broker
    , C2c_mcp.Broker.drain_inbox_push ~drained_by:"hook" broker ~session_id
    )

let drain_global_messages ~session_id =
  let root = C2c_repo_fp.resolve_sessions_broker_root () in
  if global_inbox_exists ~root ~session_id then
    let broker = C2c_mcp.Broker.create ~root in
    C2c_mcp.Broker.drain_inbox_push ~drained_by:"hook" broker ~session_id
  else []

(* Resolve session_id from stdin JSON payload, falling back to env var.
   Returns validated session_id or empty string. *)
let resolve_session_id () =
  let raw_session_id =
    match read_stdin_session_id () with
    | Some sid -> sid
    | None -> Option.value (env_nonempty "C2C_MCP_SESSION_ID") ~default:""
  in
  if raw_session_id = "" then ""
  else
    match C2c_mcp.validate_session_id raw_session_id with
    | Ok sid -> sid
    | Error msg ->
        prerr_endline msg;
        ""

(* Drain all messages (repo + global) for the given session_id.
   Returns (repo_broker_opt, messages, alias). *)
let drain_all_messages ~session_id ~broker_root =
  let repo_broker, repo_messages =
    match broker_root with
    | "" -> (None, [])
    | root ->
        let broker, messages = drain_repo_messages ~broker_root:root ~session_id in
        (Some broker, messages)
  in
  let global_messages = drain_global_messages ~session_id in
  let messages = repo_messages @ global_messages in
  let alias =
    match repo_broker with
    | None -> ""
    | Some broker ->
        (match C2c_mcp.Broker.list_registrations broker
               |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
         | Some reg -> reg.C2c_mcp.alias
         | None -> "")
  in
  (repo_broker, messages, alias)

(* Look up sender role from repo broker registration. *)
let lookup_role repo_broker from_alias =
  match repo_broker with
  | None -> None
  | Some broker ->
      (match C2c_mcp.Broker.list_registrations broker
             |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
       | Some reg -> reg.C2c_mcp.role
       | None     -> None)

(* Format messages as c2c envelope text. Returns empty string if no messages. *)
let format_messages_as_text ~repo_broker messages =
  match messages with
  | [] -> ""
  | _ ->
      let buf = Buffer.create 256 in
      List.iter
        (fun (m : C2c_mcp.message) ->
          let tag = C2c_mcp.extract_tag_from_content m.content in
          let role = lookup_role repo_broker m.from_alias in
          let envelope =
            C2c_mcp.format_c2c_envelope
              ~from_alias:m.from_alias
              ~to_alias:m.to_alias
              ?tag
              ?role
              ?reply_via:m.reply_via
              ~ts:m.ts
              ~content:m.content
              ()
          in
          Buffer.add_string buf envelope;
          Buffer.add_char buf '\n')
        messages;
      Buffer.contents buf
