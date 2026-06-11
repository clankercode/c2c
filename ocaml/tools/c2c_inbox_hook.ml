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

let print_additional_context ~extra_contexts messages_text =
  match messages_text, extra_contexts with
  | "", [] -> ()
  | _ ->
      let buf = Buffer.create 256 in
      if messages_text <> "" then Buffer.add_string buf messages_text;
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
  let session_id =
    match C2c_hook_lib.resolve_session_id () with
    | Ok "" -> exit 0
    | Ok sid -> sid
    | Error msg -> prerr_endline msg; exit 1
  in
  let broker_root =
    Option.value (C2c_hook_lib.env_nonempty "C2C_MCP_BROKER_ROOT") ~default:""
  in

  let now = iso8601_now () in
  (* PPID is the Claude Code process that spawned this hook *)
  let client_pid = Unix.getppid () in

  try
    let repo_broker, messages, alias =
      C2c_hook_lib.drain_all_messages ~session_id ~broker_root
    in

    (* Write statefile with current state (non-fatal) *)
    if broker_root <> "" then write_statefile ~session_id ~alias ~client_pid ~now;

    (* Format messages as c2c envelope text *)
    let messages_text = C2c_hook_lib.format_messages_as_text ~repo_broker messages in

    (* Cold-boot context (once per session) *)
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
    print_additional_context ~extra_contexts messages_text;

    (* Deliberately no min-runtime sleep: P0 removes the ECHILD-race floor.
       Restore a small runtime floor here if Claude hook reaping regresses. *)

    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
