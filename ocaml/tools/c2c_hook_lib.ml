(* c2c_hook_lib — shared stdin-parsing + inbox-drain logic for Claude hooks
 *
 * Used by both c2c_inbox_hook (PostToolUse) and c2c_stop_hook (Stop).
 * Factored to avoid duplication and ensure consistent session_id parsing.
 *)

let env_nonempty name =
  match Sys.getenv_opt name with
  | Some s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

(* Nudge state for PostToolUse hook debounce logic.
   Persisted to a per-session JSON file in the broker root.
   Format: { "last_nudge_ts": float, "first_waiting_ts": float }
   Both timestamps are Unix epoch seconds. *)
type nudge_state =
  { last_nudge_ts : float
  ; first_waiting_ts : float
  }

let default_nudge_state =
  { last_nudge_ts = 0.0
  ; first_waiting_ts = 0.0
  }

(* Get the path to the nudge state file for a session.
   Location: <broker_root>/<session_id>.nudge.state.json
   Falls back to a temp dir if broker_root is empty. *)
let nudge_state_path ~broker_root ~session_id =
  let root =
    if broker_root <> "" then broker_root
    else
      (* Check C2C_SESSIONS_BROKER_ROOT first (for testing) *)
      match env_nonempty "C2C_SESSIONS_BROKER_ROOT" with
      | Some root -> root
      | None ->
          (* Fallback to home directory *)
          let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
          Filename.concat home ".local/share/c2c"
  in
  Filename.concat root (session_id ^ ".nudge.state.json")

(* Read nudge state from file. Returns default state if file doesn't exist or is invalid. *)
let read_nudge_state ~broker_root ~session_id =
  let path = nudge_state_path ~broker_root ~session_id in
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    match Yojson.Safe.from_string (String.trim content) with
    | `Assoc fields ->
        let last_nudge_ts =
          match List.assoc_opt "last_nudge_ts" fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> float_of_int n
          | _ -> 0.0
        in
        let first_waiting_ts =
          match List.assoc_opt "first_waiting_ts" fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> float_of_int n
          | _ -> 0.0
        in
        { last_nudge_ts; first_waiting_ts }
    | _ -> default_nudge_state
  with _ -> default_nudge_state

(* Write nudge state to file atomically (temp + rename).
   Non-fatal on any error. *)
let write_nudge_state ~broker_root ~session_id state =
  let path = nudge_state_path ~broker_root ~session_id in
  try
    (* Ensure the directory exists *)
    let dir = Filename.dirname path in
    C2c_mcp.mkdir_p ~mode:0o700 dir;
    let json : Yojson.Safe.t =
      `Assoc
        [ ("last_nudge_ts", `Float state.last_nudge_ts)
        ; ("first_waiting_ts", `Float state.first_waiting_ts)
        ]
    in
    let payload = Yojson.Safe.to_string json in
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    output_string oc payload;
    output_char oc '\n';
    close_out oc;
    Unix.rename tmp path
  with _ -> ()

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

(* B042: detect subagent/silent context. When C2C_NO_AUTO_REGISTER=1 is set,
   the session is a spawned subagent that should not auto-register or drain
   inbox messages. Hooks should exit early when this returns true. *)
let is_subagent_quiet () =
  match Sys.getenv_opt "C2C_NO_AUTO_REGISTER" with
  | Some v when String.trim v = "1" -> true
  | _ -> false
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

(* Check if there are messages waiting in the inbox without draining.
   Returns the count of messages waiting. *)
let count_waiting_messages ~broker_root ~session_id =
  let count_repo () =
    match broker_root with
    | "" -> 0
    | root ->
        let broker = C2c_mcp.Broker.create ~root in
        let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
        List.length messages
  in
  let count_global () =
    let root = C2c_repo_fp.resolve_sessions_broker_root () in
    if global_inbox_exists ~root ~session_id then
      let broker = C2c_mcp.Broker.create ~root in
      let messages = C2c_mcp.Broker.read_inbox broker ~session_id in
      List.length messages
    else 0
  in
  count_repo () + count_global ()

(* Format a nudge line for the agent. Short and non-disruptive. *)
let format_nudge_line ~count =
  Printf.sprintf "c2c: %d message(s) waiting (drain via c2c poll-inbox or wait for turn end)" count

(* Resolve session_id from stdin JSON payload, falling back to env var.
   Returns:
     Ok ""        — no session_id found (caller should exit silently)
     Ok sid       — validated session_id
     Error msg    — session_id present but invalid (caller decides exit code) *)
let resolve_session_id () =
  let raw_session_id =
    match read_stdin_session_id () with
    | Some sid -> sid
    | None -> Option.value (env_nonempty "C2C_MCP_SESSION_ID") ~default:""
  in
  if raw_session_id = "" then Ok ""
  else
    match C2c_mcp.validate_session_id raw_session_id with
    | Ok sid -> Ok sid
    | Error msg -> Error msg

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
              ~with_reply_hint:true
              ~content:m.content
              ()
          in
          Buffer.add_string buf envelope;
          Buffer.add_char buf '\n')
        messages;
      Buffer.contents buf
