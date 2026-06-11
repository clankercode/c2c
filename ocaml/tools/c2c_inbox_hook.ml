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

let read_stdin_payload () =
  try
    let raw = In_channel.input_all stdin |> String.trim in
    if raw = "" then None else Some (Yojson.Safe.from_string raw)
  with _ -> None

let session_id_of_payload = function
  | Some (`Assoc fields) ->
      (match List.assoc_opt "session_id" fields with
       | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
       | _ -> None)
  | _ -> None

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

let print_additional_context ~lookup_role messages =
  match messages with
  | [] -> ()
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
    match session_id_of_payload (read_stdin_payload ()) with
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
    print_additional_context ~lookup_role messages;

    (* Deliberately no min-runtime sleep: P0 removes the ECHILD-race floor.
       Restore a small runtime floor here if Claude hook reaping regresses. *)

    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
