(* c2c_inbox_hook — PostToolUse hook for c2c auto-delivery in Claude Code
 *
 * Self-regulating runtime: if the hook exits in < MIN_RUNTIME_MS, we sleep
 * the remainder to prevent Node.js ECHILD race condition (kernel reaps
 * zombie before waitpid is called on fast-exiting children).
 *
 * Env vars:
 *   C2C_MCP_SESSION_ID   — broker session id
 *   C2C_MCP_BROKER_ROOT  — absolute path to broker root dir
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

let min_runtime_ms = 10.0

let iso8601_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  let ms = int_of_float ((t -. Float.round t) *. 1000.0) |> abs in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

let mkdir_p dir =
  let parts = String.split_on_char '/' dir in
  ignore (List.fold_left (fun acc part ->
    if part = "" then acc
    else
      let p = if acc = "" then "/" ^ part else acc ^ "/" ^ part in
      (try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      p
  ) "" parts)

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

let () =
  let session_id =
    try Sys.getenv "C2C_MCP_SESSION_ID" with Not_found -> ""
  in
  let broker_root =
    try Sys.getenv "C2C_MCP_BROKER_ROOT" with Not_found -> ""
  in
  (* Fast path: if not configured, exit silently *)
  if session_id = "" || broker_root = "" then exit 0;

  let start_time = Unix.gettimeofday () in
  let now = iso8601_now () in
  (* PPID is the Claude Code process that spawned this hook *)
  let client_pid = Unix.getppid () in

  try
    let broker = C2c_mcp.Broker.create ~root:broker_root in
    (* #387 A2: when the session is channel-capable (registry's
       [automated_delivery=true]), the MCP server's channel watcher owns
       delivery. The hook MUST NOT drain — otherwise it races the watcher
       and the message renders as a plain hook-stdout `<c2c event=...>`
       envelope instead of the styled `<channel>` notification. We still
       run the statefile write below so PostToolUse remains observable. *)
    let messages =
      if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then begin
        prerr_endline
          (Printf.sprintf
             "[hook] skipping drain — session %s is channel-capable; \
              watcher owns delivery"
             session_id);
        []
      end else
        (* Push path: drain only non-deferrable messages; deferrable stay
           in inbox for the agent to read on next explicit poll_inbox or
           idle flush. *)
        C2c_mcp.Broker.drain_inbox_push ~drained_by:"hook" broker ~session_id
    in

    (* Look up alias from registry for the statefile *)
    let alias =
      match C2c_mcp.Broker.list_registrations broker
            |> List.find_opt (fun r -> r.C2c_mcp.session_id = session_id) with
      | Some reg -> reg.C2c_mcp.alias
      | None -> ""
    in

    (* Write statefile with current state (non-fatal) *)
    write_statefile ~session_id ~alias ~client_pid ~now;

    (* Look up sender role: returns None when sender has no role set. *)
    let lookup_role from_alias =
      match C2c_mcp.Broker.list_registrations broker
            |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
      | Some reg -> reg.C2c_mcp.role
      | None     -> None
    in

    (* Output messages in c2c event envelope format *)
    List.iter
      (fun (m : C2c_mcp.message) ->
        let reply_via = Option.value m.reply_via ~default:"c2c_send" in
        let role_attr = match lookup_role m.from_alias with
          | Some r -> Printf.sprintf " role=\"%s\"" r
          | None   -> ""
        in
        Printf.printf "<c2c event=\"message\" from=\"%s\" alias=\"%s\" source=\"broker\" reply_via=\"%s\" action_after=\"continue\"%s>%s</c2c>\n"
          m.from_alias m.to_alias reply_via role_attr m.content)
      messages;

    (* Self-regulating runtime: sleep if we finished too quickly *)
    let elapsed_ms = (Unix.gettimeofday () -. start_time) *. 1000.0 in
    if elapsed_ms < min_runtime_ms then
      let remaining_ms = min_runtime_ms -. elapsed_ms in
      ignore (Lwt_main.run (Lwt_unix.sleep (remaining_ms /. 1000.0)));

    exit 0
  with e ->
    prerr_endline (Printexc.to_string e);
    exit 1
