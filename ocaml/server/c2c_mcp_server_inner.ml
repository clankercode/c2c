(* c2c_mcp_server_inner — shared MCP server implementation.
    Used by both the standalone c2c-mcp-inner binary and as the basis
    for the c2c-mcp-server binary in Slice B (outer proxy).

    This module contains the full-featured server logic:
    - auto-register + orphan replay on startup
    - nudge scheduler
    - inbox watcher with channel-notification delivery
    - initialize replay hooks for inner restart (Slice B/C)
 *)

let debug_enabled () =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let nudge_cadence_minutes () =
  match Sys.getenv_opt "C2C_NUDGE_CADENCE_MINUTES" with
  | Some v ->
      (try float_of_string (String.trim v) with _ -> 30.0)
  | None -> 30.0

let nudge_idle_minutes () =
  match Sys.getenv_opt "C2C_NUDGE_IDLE_MINUTES" with
  | Some v ->
      (try float_of_string (String.trim v) with _ -> 25.0)
  | None -> 25.0

let debug_log_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let base = Filename.concat home ".local/share/c2c" in
  let sid =
    match C2c_mcp.session_id_from_env () with
    | Some s when String.trim s <> "" -> String.trim s
    | _ -> "no-session"
  in
  let dir = Filename.concat base "mcp-debug" in
  C2c_io.mkdir_p ~mode:0o700 dir;
  Filename.concat dir (sid ^ ".log")

let debug_log msg =
  if debug_enabled () then
    try
      let path = debug_log_path () in
      let ts = C2c_time.iso8601_utc_ms (Unix.gettimeofday ()) in
      let oc = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 path in
      Printf.fprintf oc "%s [%d] %s\n%!" ts (Unix.getpid ()) msg;
      close_out oc
    with _ -> ()

let session_id () =
  C2c_mcp.session_id_from_env ()

let channel_delivery_enabled () =
  match Sys.getenv_opt "C2C_MCP_CHANNEL_DELIVERY" with
  | Some value ->
      let normalized = String.lowercase_ascii (String.trim value) in
      not (List.mem normalized [ "0"; "false"; "no"; "off" ])
  | None -> true (* default: ON *)

let force_capabilities_from_env () =
  match Sys.getenv_opt "C2C_MCP_FORCE_CAPABILITIES" with
  | None -> []
  | Some "" -> []
  | Some value ->
      value
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter ((<>) "")
      |> List.filter_map C2c_capability.of_string
      |> List.map C2c_capability.to_string

let auto_drain_channel_enabled () =
  (* Default is ON (#346 flip). `c2c install` writes "0" explicitly for all managed
     clients; this default only matters for fresh installs that skip the install step
     or for direct broker invocations. Auto-drain remains gated by client capability
     declaration ([experimental.claude/channel]) even when the env var is set, so
     this default-flip is safe: standard Claude Code (no channel capability) is
     unaffected; only clients that explicitly declare channel support get auto-drain. *)
  match Sys.getenv_opt "C2C_MCP_AUTO_DRAIN_CHANNEL" with
  | Some value ->
      let normalized = String.lowercase_ascii (String.trim value) in
      not (List.mem normalized [ "0"; "false"; "no"; "off" ])
  | None -> true

let schedule_timer_enabled () =
  match Sys.getenv_opt "C2C_MCP_SCHEDULE_TIMER" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      List.mem n ["1"; "true"; "yes"; "on"]
  | None -> false

let inbox_watcher_delay_seconds () =
  match Sys.getenv_opt "C2C_MCP_INBOX_WATCHER_DELAY" with
  | Some value -> (
      match float_of_string_opt (String.trim value) with
      | Some n -> n
      | None -> 30.0)
  | None -> 2.0

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let starts_with_ci ~prefix s =
  let p = String.lowercase_ascii prefix in
  let v = String.lowercase_ascii s in
  String.length v >= String.length p && String.sub v 0 (String.length p) = p

let parse_content_length line =
  match String.index_opt line ':' with
  | None -> None
  | Some i ->
      let n = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
      int_of_string_opt n

let rec read_until_blank () =
  let open Lwt.Syntax in
  let* line = Lwt_io.read_line_opt Lwt_io.stdin in
  match line with
  | None -> Lwt.return_unit
  | Some l -> if String.trim l = "" then Lwt.return_unit else read_until_blank ()

let rec read_message () =
  let open Lwt.Syntax in
  let* first = Lwt_io.read_line_opt Lwt_io.stdin in
  match first with
  | None -> Lwt.return_none
  | Some line ->
      let trimmed = String.trim line in
      if trimmed = "" then read_message ()
      else if starts_with_ci ~prefix:"Content-Length:" trimmed then
        match parse_content_length trimmed with
        | None -> Lwt.return_none
        | Some len ->
            let* () = read_until_blank () in
            let* body = Lwt_io.read ~count:len Lwt_io.stdin in
            if String.length body = len then Lwt.return_some body else Lwt.return_none
      else Lwt.return_some line

let write_message json =
  let open Lwt.Syntax in
  let body = Yojson.Safe.to_string json in
  let* () = Lwt_io.write_line Lwt_io.stdout body in
  Lwt_io.flush Lwt_io.stdout

(* Continuous inbox delivery: background thread that watches the inbox file and emits
   notifications for new messages while the session runs. The watcher only drains
   when channel_capable_ref is true — i.e. the client negotiated
   experimental.claude/channel in its initialize request. This prevents the
   background watcher from silently draining messages for clients (e.g. Claude Code
   standard) that do not support the notifications/claude/channel notification
   method, which would otherwise cause messages to vanish from the agent's
   perspective. *)
let start_inbox_watcher ~broker_root ~session_id ~emit_notification_fn
    ~negotiated_capabilities_ref =
  let open Lwt.Syntax in
  let inbox_path = Filename.concat broker_root (session_id ^ ".inbox.json") in
  let stat_size () =
    try (Unix.stat inbox_path).Unix.st_size with Unix.Unix_error _ -> 0
  in
  let delay = inbox_watcher_delay_seconds () in
  let rec loop last_size =
    let* () = Lwt_unix.sleep 1.0 in
    Lwt.catch
      (fun () ->
        let current_size = stat_size () in
        if current_size > last_size then
          (* New content detected. Sleep before draining so preferred delivery
             paths (e.g. PostToolUse hook on Claude Code) can drain first.
             If the hook already drained, drain_inbox returns [] and we emit
             nothing. *)
          let* () = if delay > 0.0 then Lwt_unix.sleep delay else Lwt.return_unit in
          (* Only drain when the client can actually receive channel notifications.
             For non-channel-capable clients (e.g. standard Claude Code), leaving
             messages in the inbox is correct — they will be retrieved via
             poll_inbox or the PostToolUse hook on the next tool call. *)
           if C2c_capability.has !negotiated_capabilities_ref
                C2c_capability.Claude_channel then
             let broker = C2c_mcp.Broker.create ~root:broker_root in
            let messages =
              if C2c_mcp.Broker.is_dnd broker ~session_id then []
              else C2c_mcp.Broker.drain_inbox_push ~drained_by:"watcher" broker ~session_id
            in
            let rec emit_all = function
              | [] -> Lwt.return_unit
              | msg :: rest ->
                  let* () = emit_notification_fn msg in
                  let* () = Lwt_unix.sleep 0.01 in
                  emit_all rest
            in
            let* () = emit_all messages in
            let post_drain_size = stat_size () in
            loop post_drain_size
          else
            loop current_size
        else
          loop current_size)
      (fun exn ->
        debug_log ("inbox_watcher error: " ^ Printexc.to_string exn);
        let* () =
          Lwt_io.eprintlf "c2c inbox watcher: %s" (Printexc.to_string exn)
        in
        loop last_size)
  in
  loop 0

let lookup_sender_role ~broker_root from_alias =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  match C2c_mcp.Broker.list_registrations broker
        |> List.find_opt (fun r -> r.C2c_mcp.alias = from_alias) with
  | Some reg -> reg.C2c_mcp.role
  | None     -> None

let emit_notification ~broker_root ~session_id msg =
  debug_log ("emit_notification -> " ^ session_id);
  let decrypted_msg = C2c_mcp.decrypt_message_for_push msg ~alias:msg.C2c_mcp.to_alias in
  let role = lookup_sender_role ~broker_root msg.C2c_mcp.from_alias in
  write_message (C2c_mcp.channel_notification ~role decrypted_msg)

let emit_notifications ~broker_root ?(inter_message_delay = 0.0) ~session_id messages =
  let open Lwt.Syntax in
  let rec loop = function
    | [] -> Lwt.return_unit
    | msg :: rest ->
        let* () = emit_notification ~broker_root ~session_id msg in
        let* () =
          if inter_message_delay > 0.0 then
            Lwt_unix.sleep inter_message_delay
          else
            Lwt.return_unit
        in
        loop rest
  in
  loop messages

let rec loop ~broker_root ~negotiated_capabilities_ref =
  let open Lwt.Syntax in
  let* msg = read_message () in
  match msg with
  | None -> debug_log "stdin EOF — exiting"; Lwt.return_unit
  | Some line -> (debug_log ("recv: " ^ String.sub line 0 (min (String.length line) 200));
      let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
      match json with
      | Error () ->
          debug_log "parse error";
          let* () = write_message (Json_util.jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
          loop ~broker_root ~negotiated_capabilities_ref
      | Ok request ->
          let method_name =
            match assoc_opt "method" request with
            | Some (`String value) -> (debug_log ("method: " ^ value); Some value)
            | _ -> None
          in
          let was_capable =
            C2c_capability.has !negotiated_capabilities_ref
              C2c_capability.Claude_channel
          in
          let new_capabilities =
            C2c_capability.negotiated_in_initialize
              ~current:!negotiated_capabilities_ref request
          in
          negotiated_capabilities_ref := new_capabilities;
          let new_capable =
            C2c_capability.has new_capabilities C2c_capability.Claude_channel
          in
          (* Persist push-delivery capability to the broker registry on
             every initialize. The flag drives push-aware heartbeat
             content selection (see C2c_start.heartbeat_body_for_alias). *)
          (match method_name, session_id () with
           | Some "initialize", Some sid ->
               let broker = C2c_mcp.Broker.create ~root:broker_root in
               C2c_mcp.Broker.set_automated_delivery broker
                 ~session_id:sid ~automated_delivery:new_capable
           | _ -> ());
          let* response = C2c_mcp.handle_request ~broker_root request in
          let* () = match response with
            | None -> debug_log "send: (no response)"; Lwt.return_unit
            | Some resp -> debug_log ("send: " ^ String.sub (Yojson.Safe.to_string resp) 0 (min (String.length (Yojson.Safe.to_string resp)) 200)); write_message resp
          in
          let* () =
            match (method_name, was_capable, new_capable, session_id ()) with
            | Some "initialize", false, true, Some sid ->
                let broker = C2c_mcp.Broker.create ~root:broker_root in
                let queued =
                  if C2c_mcp.Broker.is_dnd broker ~session_id:sid then []
                  else C2c_mcp.Broker.drain_inbox_push ~drained_by:"watcher" broker ~session_id:sid
                in
                let* () = emit_notifications ~broker_root ~session_id:sid queued in
                (* Emit channel test notification if code exists *)
                (match C2c_mcp.pop_channel_test_code () with
                 | Some code ->
                      let test_msg = { C2c_mcp.from_alias = "c2c-system";
                                       to_alias = sid;
                                       content = Printf.sprintf "<c2c event=\"channel-test\" code=\"%s\"/>" code;
                                       deferrable = false; reply_via = None; enc_status = None; ts = Unix.gettimeofday (); ephemeral = false; message_id = None } in
                     emit_notification ~broker_root ~session_id:sid test_msg
                 | None -> Lwt.return_unit)
            | _ -> Lwt.return_unit
          in
          let* () =
            match (auto_drain_channel_enabled (), new_capable, session_id ()) with
            | false, _, _ -> Lwt.return_unit
            | true, false, _ -> Lwt.return_unit
            | true, true, None -> Lwt.return_unit
            | true, true, Some sid ->
                let broker = C2c_mcp.Broker.create ~root:broker_root in
                let queued = C2c_mcp.Broker.drain_inbox_push ~drained_by:"watcher" broker ~session_id:sid in
                emit_notifications ~broker_root ~session_id:sid queued
          in
          loop ~broker_root ~negotiated_capabilities_ref)

(* S6b: compute_next_fire — given current time and a schedule_entry,
   return the next wall-clock fire timestamp.
   For aligned schedules (s_align <> ""), parse the alignment spec using
   C2c_start.parse_heartbeat_schedule and compute the next aligned time.
   For non-aligned: now + s_interval_s. *)
let compute_next_fire (now : float) (entry : C2c_mcp.schedule_entry) : float =
  if entry.s_align <> "" then
    match C2c_start.parse_heartbeat_schedule entry.s_align with
    | Ok (C2c_start.Aligned_interval { interval_s; offset_s }) ->
        let shifted = now -. offset_s in
        let slots = floor (shifted /. interval_s) +. 1.0 in
        (slots *. interval_s) +. offset_s
    | Ok (C2c_start.Interval n) ->
        (* parse returned a plain interval from the align field — treat as non-aligned *)
        now +. n
    | Error _ ->
        (* Unparseable align string — fall back to interval *)
        now +. entry.s_interval_s
  else
    now +. entry.s_interval_s

(* S6b: Lwt background loop that reads .c2c/schedules/<alias>/*.toml,
   hot-reloads on directory changes (via mtime), and fires due schedules
   as self-DMs via C2c_schedule_fire.enqueue_heartbeat.

   State: Hashtbl of (filename -> (schedule_entry * file_mtime * next_fire_at)).
   Every 5s tick:
     1. Stat the schedule dir — if dir mtime changed, re-scan files.
     2. For each tracked entry: if now >= next_fire_at AND should_fire,
        fire and advance next_fire_at. *)
let start_schedule_timer ~(broker_root : string) ~(alias : string) =
  let open Lwt.Syntax in
  let poll_interval = 5.0 in
  let sched_dir = C2c_mcp.schedule_base_dir alias in
  (* filename -> (schedule_entry, file_mtime, next_fire_at) *)
  let entries : (string, C2c_mcp.schedule_entry * float * float) Hashtbl.t =
    Hashtbl.create 16
  in
  let last_dir_mtime = ref 0.0 in
  let reload_schedules () =
    let dir_mtime =
      try (Unix.stat sched_dir).Unix.st_mtime
      with Unix.Unix_error _ -> 0.0
    in
    if dir_mtime <> !last_dir_mtime then begin
      last_dir_mtime := dir_mtime;
      let now = Unix.gettimeofday () in
      let current_files =
        try
          Array.to_list (Sys.readdir sched_dir)
          |> List.filter (fun n ->
              String.length n > 5
              && String.sub n (String.length n - 5) 5 = ".toml")
        with Sys_error _ | Unix.Unix_error _ -> []
      in
      (* Add or update entries *)
      List.iter (fun fname ->
        let path = Filename.concat sched_dir fname in
        let file_mtime =
          try (Unix.stat path).Unix.st_mtime
          with Unix.Unix_error _ -> 0.0
        in
        let needs_update =
          match Hashtbl.find_opt entries fname with
          | None -> true
          | Some (_, cached_mtime, _) -> file_mtime <> cached_mtime
        in
        if needs_update then begin
          let content =
            try C2c_io.read_file_opt path
            with _ -> ""
          in
          if content <> "" then begin
            let entry = C2c_mcp.parse_schedule content in
            if entry.s_name <> "" && entry.s_enabled then begin
              let next_fire = compute_next_fire now entry in
              debug_log (Printf.sprintf "schedule_timer: loaded %s, next_fire in %.1fs"
                fname (next_fire -. now));
              Hashtbl.replace entries fname (entry, file_mtime, next_fire)
            end else
              (* Disabled or unnamed — remove if previously tracked *)
              Hashtbl.remove entries fname
          end else
            Hashtbl.remove entries fname
        end
      ) current_files;
      (* Remove entries for deleted files *)
      let to_remove = Hashtbl.fold (fun fname _ acc ->
        if List.mem fname current_files then acc else fname :: acc
      ) entries [] in
      List.iter (fun fname ->
        debug_log (Printf.sprintf "schedule_timer: removed deleted schedule %s" fname);
        Hashtbl.remove entries fname
      ) to_remove
    end
  in
  let check_and_fire () =
    let now = Unix.gettimeofday () in
    Hashtbl.iter (fun fname (entry, file_mtime, next_fire) ->
      if now >= next_fire then begin
        if C2c_schedule_fire.should_fire ~broker_root ~alias entry then begin
          debug_log (Printf.sprintf "schedule_timer: firing %s (%s)"
            fname entry.s_name);
          (try
            C2c_schedule_fire.enqueue_heartbeat ~broker_root ~alias
              ~content:entry.s_message
          with exn ->
            debug_log (Printf.sprintf "schedule_timer: fire error for %s: %s"
              fname (Printexc.to_string exn)))
        end else
          debug_log (Printf.sprintf "schedule_timer: skipping %s (idle gate)"
            fname);
        (* Advance next_fire_at regardless of whether we fired —
           prevents re-firing every 5s if idle gate blocks *)
        let next = compute_next_fire now entry in
        Hashtbl.replace entries fname (entry, file_mtime, next)
      end
    ) entries
  in
  let rec loop () =
    let* () = Lwt_unix.sleep poll_interval in
    Lwt.catch
      (fun () ->
        reload_schedules ();
        check_and_fire ();
        loop ())
      (fun exn ->
        debug_log ("schedule_timer error: " ^ Printexc.to_string exn);
        loop ())
  in
  loop ()

(* #514: stale broker-root detection.
   The parent process (c2c start, kimi, opencode plugin) passes C2C_MCP_BROKER_ROOT
   to the MCP server child. If the parent's git context differs from the child's
   (e.g. remote.origin.url changed, or a nested c2c start with different repo),
   the child writes to a broker directory that doesn't match peers — split-brain.
   Detection: compare the inherited value against what we would compute fresh.
   Exit 42 signals the parent to re-launch with the correct (canonical) value. *)
let check_stale_broker_root ~(broker_root : string) : (_, _) result =
  let canonical = C2c_repo_fp.resolve_broker_root () in
  let from_env = Sys.getenv_opt "C2C_MCP_BROKER_ROOT" in
  let inherited = Option.value from_env ~default:"" in
  if inherited = "" then
    (* No env value passed — parent used canonical resolution (or no parent).
       No staleness possible. *)
    Ok ()
  else if inherited = canonical then
    (* Inherited matches canonical — fresh and correct. *)
    Ok ()
  else
    (* Stale: parent passed a value that doesn't match what we'd compute fresh.
       Exit 42 so the parent can re-launch us with the correct value. *)
    Error (inherited, canonical)

(* run_inner_server — the full-featured MCP server loop.
   Called by:
   - c2c-mcp-inner binary (Slice A)
   - c2c-mcp-server binary (Slice B, after refactor)
   - c2c mcp-inner CLI command (Slice A) *)
let run_inner_server ~broker_root =
  let open Lwt.Syntax in
  (* #514: bail early if broker_root is stale. *)
  (match check_stale_broker_root ~broker_root with
   | Error (inherited, canonical) ->
       debug_log (Printf.sprintf
         "ERROR: stale broker_root detected: inherited=%s canonical=%s — exiting 42 (restart with correct broker root)"
         inherited canonical);
       print_endline "[c2c] stale broker_root detected; restart with correct broker root";
       exit 42
   | Ok () -> ());
  debug_log ("run_inner_server starting, broker_root=" ^ broker_root);
  C2c_mcp.auto_register_startup ~broker_root;
  (* Replay any orphan messages that arrived during the restart gap
     (between old outer-loop exit and new registration). *)
  (match session_id () with
   | Some sid ->
       let broker = C2c_mcp.Broker.create ~root:broker_root in
       let replayed = C2c_mcp.Broker.replay_pending_orphan_inbox broker ~session_id:sid in
       if replayed > 0 then debug_log ("replayed " ^ string_of_int replayed ^ " orphan messages")
   | None -> ());
  C2c_mcp.auto_join_rooms_startup ~broker_root;
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  Relay_nudge.start_nudge_scheduler
    ~broker_root
    ~broker
    ~cadence_minutes:(nudge_cadence_minutes ())
    ~idle_minutes:(nudge_idle_minutes ())
    ();
  (* slice/coord-backup-fallthrough: dedicated 60s-tick scheduler that
     escalates pending-permission DMs through the configured
     [swarm].coord_chain when the primary doesn't ack. Reads config
     via thunks on every tick — empty chain (default) means the loop
     runs but every tick is a no-op. *)
  Coord_fallthrough.start_scheduler ~broker_root ~broker ();
  let negotiated_capabilities_ref = ref (force_capabilities_from_env ()) in
  let emit_notification_fn msg =
    emit_notification ~broker_root ~session_id:(match session_id () with Some s -> s | None -> "") msg
  in
  (match (channel_delivery_enabled (), session_id ()) with
   | true, Some sid -> debug_log ("starting inbox watcher for " ^ sid); Lwt.async (fun () ->
         start_inbox_watcher ~broker_root ~session_id:sid
           ~emit_notification_fn ~negotiated_capabilities_ref)
   | _, _ -> ());
  (* S6b: MCP-server-side schedule timer *)
  (match (schedule_timer_enabled (), session_id ()) with
   | true, Some sid ->
       let alias = match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
         | Some a when String.trim a <> "" -> String.trim a
         | _ -> sid
       in
       debug_log ("starting schedule timer for " ^ alias);
       Lwt.async (fun () -> start_schedule_timer ~broker_root ~alias)
   | _, _ -> ());
  try
    Lwt_main.run (loop ~broker_root ~negotiated_capabilities_ref);
    debug_log "run_inner_server: normal exit"
  with exn ->
    debug_log ("run_inner_server FATAL: " ^ Printexc.to_string exn ^ "\n" ^ Printexc.get_backtrace ());
    raise exn
