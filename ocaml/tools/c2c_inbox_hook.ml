(* c2c_inbox_hook — PostToolUse hook for c2c auto-delivery in Claude Code
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
 *   C2C_SESSIONS_BROKER_ROOT — optional test/global sessions broker override
 *   C2C_INSTANCE_NAME    — instance name (set by c2c start); selects statefile path
 *
 * Statefile:
 *   Written on each hook invocation to the per-instance statefile so that
 *   `c2c statefile` and the GUI can see Claude Code session state.
 *   Path: ~/.local/share/c2c/instances/<C2C_INSTANCE_NAME>/oc-plugin-state.json
 *         (or ~/.local/share/c2c/oc-plugin-state.json when no instance name)
 *
 * Exit codes:
 *   0 — success (even if no messages)
 *   1 — error (missing env, file error, etc.)
 *)

let iso8601_now () = C2c_time.iso8601_utc_ms (Unix.gettimeofday ())

let mkdir_p = C2c_mcp.mkdir_p ~mode:0o700

let statefile_path () =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
  let base = Filename.concat home ".local/share/c2c" in
  match Sys.getenv_opt "C2C_INSTANCE_NAME" with
  | Some name when String.trim name <> "" ->
      let inst_dir = Filename.concat (Filename.concat base "instances") (String.trim name) in
      mkdir_p inst_dir;
      Filename.concat inst_dir "oc-plugin-state.json"
  | _ ->
      mkdir_p base;
      Filename.concat base "oc-plugin-state.json"

let debug_log_path () =
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp" in
  let base = Filename.concat home ".local/share/c2c" in
  match Sys.getenv_opt "C2C_INSTANCE_NAME" with
  | Some name when String.trim name <> "" ->
      let inst_dir = Filename.concat (Filename.concat base "instances") (String.trim name) in
      mkdir_p inst_dir;
      Filename.concat inst_dir "statefile-debug.jsonl"
  | _ ->
      mkdir_p base;
      Filename.concat base "statefile-debug.jsonl"

(* Read existing statefile JSON if present. *)
let read_existing_state path =
  try
    let ic = open_in path in
    let content = In_channel.input_all ic in
    close_in ic;
    match Yojson.Safe.from_string (String.trim content) with
    | `Assoc fields -> Some fields
    | _ -> None
  with _ -> None

let int_field_or fields name default =
  match List.assoc_opt name fields with
  | Some (`Int n) -> n
  | _ -> default

let string_field_or fields name default =
  match List.assoc_opt name fields with
  | Some (`String s) -> s
  | _ -> default

(* Write statefile atomically. Non-fatal on any error. *)
let rec write_statefile ~session_id ~alias ~client_pid ~now =
  try
    let path = statefile_path () in
    let existing = read_existing_state path in
    let (step_count, plugin_started_at) =
      match existing with
      | Some fields ->
          let state_fields =
            match List.assoc_opt "state" fields with
            | Some (`Assoc sf) -> sf
            | _ -> []
          in
          let agent_fields =
            match List.assoc_opt "agent" state_fields with
            | Some (`Assoc af) -> af
            | _ -> []
          in
          let sc = int_field_or agent_fields "step_count" 0 in
          let psa = string_field_or state_fields "plugin_started_at" now in
          (sc + 1, psa)
      | None -> (1, now)
    in
    let state =
      `Assoc
        [ ("c2c_session_id", `String session_id)
        ; ("c2c_alias", if alias = "" then `Null else `String alias)
        ; ("root_opencode_session_id", `Null)
        ; ("client_pid", `Int client_pid)
        ; ("plugin_started_at", `String plugin_started_at)
        ; ("state_last_updated_at", `String now)
        ; ("agent",
           `Assoc
             [ ("is_idle", `Null)
             ; ("turn_count", `Int 0)
             ; ("step_count", `Int step_count)
             ; ("last_step",
                `Assoc
                  [ ("event_type", `String "posttooluse")
                  ; ("at", `String now)
                  ; ("details", `Null)
                  ])
             ; ("provider_id", `String "claude")
             ; ("model_id", `Null)
             ])
        ; ("tui_focus", `Assoc [ ("ty", `String "unknown"); ("details", `Null) ])
        ; ("prompt", `Assoc [ ("has_text", `Null) ])
        ]
    in
    let payload =
      `Assoc
        [ ("event", `String "state.snapshot")
        ; ("ts", `String now)
        ; ("checkpoint", `Null)
        ; ("state", state)
        ]
      |> Yojson.Safe.to_string
    in
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    output_string oc payload;
    output_char oc '\n';
    close_out oc;
    Unix.rename tmp path;
    append_debug_log ~now ~event:"state.snapshot" ~checkpoint:`Null ~state:(Some state)
  with _ -> ()

and append_debug_log ~now ~event ~checkpoint ~state =
  try
    let path = debug_log_path () in
    let entry =
      `Assoc
        [ ("ts", `String now)
        ; ("event", `String event)
        ; ("checkpoint", checkpoint)
        ; ("state", match state with Some s -> s | None -> `Null)
        ]
      |> Yojson.Safe.to_string
    in
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_append ] 0o644 path in
    output_string oc entry;
    output_char oc '\n';
    close_out oc;
    rotate_debug_log_if_needed path
  with _ -> ()

and rotate_debug_log_if_needed path =
  try
    let ic = open_in path in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done with End_of_file -> ());
    close_in ic;
    let one_hour_ago = Unix.gettimeofday () -. 3600.0 in
    let recent_lines =
      List.filter (fun line ->
        match Yojson.Safe.from_string line with
        | `Assoc fields ->
            (match List.assoc_opt "ts" fields with
             | Some (`String s) ->
                 (try
                    let year = int_of_string (String.sub s 0 4) in
                    let month = int_of_string (String.sub s 5 2) - 1 in
                    let day = int_of_string (String.sub s 8 2) in
                    let hour = int_of_string (String.sub s 11 2) in
                    let min = int_of_string (String.sub s 14 2) in
                    let sec = int_of_string (String.sub s 17 2) in
                    let tm_val = { Unix.tm_year = year - 1900; tm_mon = month; tm_mday = day; tm_hour = hour; tm_min = min; tm_sec = sec; tm_isdst = false; tm_yday = 0; tm_wday = 0 } in
                    let ts, _ = Unix.mktime tm_val in
                    ts > one_hour_ago
                  with _ -> false)
             | _ -> false)
        | _ -> false
      ) !lines
    in
    if List.length recent_lines < List.length !lines then begin
      let oc = open_out path in
      List.iter (fun l -> output_string oc l; output_char oc '\n') (List.rev recent_lines);
      close_out oc
    end
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

let print_additional_context ~lookup_role ~extra_contexts messages =
  match messages, extra_contexts with
  | [], [] -> ()
  | _ ->
      let buf = Buffer.create 256 in
      List.iter
        (fun (m : C2c_mcp.message) ->
          let tag = C2c_mcp.extract_tag_from_content m.content in
          let role = lookup_role m.from_alias in
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
      List.iter
        (fun context ->
          Buffer.add_string buf context;
          if context = "" || context.[String.length context - 1] <> '\n' then
            Buffer.add_char buf '\n')
        extra_contexts;
      let json : Yojson.Safe.t =
        `Assoc
          [ ( "hookSpecificOutput"
            , `Assoc
                [ ("hookEventName", `String "PostToolUse")
                ; ("additionalContext", `String (Buffer.contents buf))
                ] )
          ]
      in
      Printf.printf "%s\n" (Yojson.Safe.to_string json)

let () =
  let raw_session_id =
    match read_stdin_session_id () with
    | Some sid -> sid
    | None -> Option.value (env_nonempty "C2C_MCP_SESSION_ID") ~default:""
  in
  let broker_root =
    Option.value (env_nonempty "C2C_MCP_BROKER_ROOT") ~default:""
  in
  (* Fast path: if no session can be resolved, exit silently. *)
  if raw_session_id = "" then exit 0;
  let session_id =
    match C2c_mcp.validate_session_id raw_session_id with
    | Ok sid -> sid
    | Error msg ->
        prerr_endline msg;
        exit 1
  in

  let now = iso8601_now () in
  (* PPID is the Claude Code process that spawned this hook *)
  let client_pid = Unix.getppid () in

  try
    let repo_broker, repo_messages =
      match broker_root with
      | "" -> (None, [])
      | root ->
          let broker, messages = drain_repo_messages ~broker_root:root ~session_id in
          (Some broker, messages)
    in
    let global_messages = drain_global_messages ~session_id in
    let messages = repo_messages @ global_messages in

    (* Look up alias from registry for the statefile *)
    let alias =
      match repo_broker with
      | None -> ""
      | Some broker ->
          (match C2c_mcp.Broker.list_registrations broker
                 |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
           | Some reg -> reg.C2c_mcp.alias
           | None -> "")
    in

    (* Write statefile with current state (non-fatal) *)
    if broker_root <> "" then write_statefile ~session_id ~alias ~client_pid ~now;

    (* Look up sender role: returns None when sender has no role set. *)
    let lookup_role from_alias =
      match repo_broker with
      | None -> None
      | Some broker ->
          (match C2c_mcp.Broker.list_registrations broker
                 |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
           | Some reg -> reg.C2c_mcp.role
           | None     -> None)
    in

    (* Output messages in c2c event envelope format. Centralized via
       C2c_mcp.format_c2c_envelope (#392b convergence) so #392 tag
       attrs and xml-escaping are consistent across all surfaces
       (cli/c2c.ml monitor path, this hook). *)
    let extra_contexts =
      match broker_root with
      | "" -> []
      | root ->
          (match C2c_cold_boot_context.context_for_session
                   ~broker_root:root ~session_id
           with
           | Some context -> [ context ]
           | None -> [])
    in
    print_additional_context ~lookup_role ~extra_contexts messages;

    (* Deliberately no min-runtime sleep: P0 removes the ECHILD-race floor.
       Restore a small runtime floor here if Claude hook reaping regresses. *)

    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
