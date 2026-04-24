let debug_enabled () =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let debug_log_path () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let base = Filename.concat home ".local/share/c2c" in
  let sid =
    match C2c_mcp.session_id_from_env () with
    | Some s when String.trim s <> "" -> String.trim s
    | _ -> "no-session"
  in
  let dir = Filename.concat base "mcp-debug" in
  (try ignore (Unix.mkdir dir 0o700) with Unix.Unix_error _ -> ());
  Filename.concat dir (sid ^ ".log")

let debug_log msg =
  if debug_enabled () then
    try
      let path = debug_log_path () in
      let now = Unix.gettimeofday () in
      let tm = Unix.gmtime now in
      let ms = int_of_float ((now -. Float.round now) *. 1000.0) |> abs in
      let ts = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
        tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec ms
      in
      let oc = open_out_gen [Open_wronly; Open_creat; Open_append] 0o644 path in
      Printf.fprintf oc "%s [%d] %s\n%!" ts (Unix.getpid ()) msg;
      close_out oc
    with _ -> ()

let broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> path
  | _ -> Filename.concat (Filename.get_temp_dir_name ()) "c2c-mcp-broker"

let session_id () =
  C2c_mcp.session_id_from_env ()

let channel_delivery_enabled () =
  match Sys.getenv_opt "C2C_MCP_CHANNEL_DELIVERY" with
  | Some value ->
      let normalized = String.lowercase_ascii (String.trim value) in
      not (List.mem normalized [ "0"; "false"; "no"; "off" ])
  | None -> true (* default: ON *)

let auto_drain_channel_enabled () =
  match Sys.getenv_opt "C2C_MCP_AUTO_DRAIN_CHANNEL" with
  | Some value ->
      let normalized = String.lowercase_ascii (String.trim value) in
      not (List.mem normalized [ "0"; "false"; "no"; "off" ])
  | None -> channel_delivery_enabled ()

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

let jsonrpc_error ~id ~code ~message =
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("id", id)
    ; ("error", `Assoc [ ("code", `Int code); ("message", `String message) ])
    ]

(* Continuous inbox delivery: background thread that watches the inbox file and emits
   notifications for new messages while the session runs. The watcher only drains
   when channel_capable_ref is true — i.e. the client negotiated
   experimental.claude/channel in its initialize request. This prevents the
   background watcher from silently draining messages for clients (e.g. Claude Code
   standard) that do not support the notifications/claude/channel notification
   method, which would otherwise cause messages to vanish from the agent's
   perspective. *)
let start_inbox_watcher ~broker_root ~session_id ~emit_notification
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
              else C2c_mcp.Broker.drain_inbox_push broker ~session_id
            in
            let rec emit_all = function
              | [] -> Lwt.return_unit
              | msg :: rest ->
                  let* () = emit_notification ~session_id msg in
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
  loop (stat_size ())

let emit_notification ~session_id msg =
  debug_log ("emit_notification -> " ^ session_id);
  let decrypted_msg = C2c_mcp.decrypt_message_for_push msg ~session_id in
  write_message (C2c_mcp.channel_notification decrypted_msg)

let emit_notifications ?(inter_message_delay = 0.0) ~session_id messages =
  let open Lwt.Syntax in
  let rec loop = function
    | [] -> Lwt.return_unit
    | msg :: rest ->
        let* () = emit_notification ~session_id msg in
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
          let* () = write_message (jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
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
                  else C2c_mcp.Broker.drain_inbox_push broker ~session_id:sid
                in
                let* () = emit_notifications ~session_id:sid queued in
                (* Emit channel test notification if code exists *)
                (match C2c_mcp.pop_channel_test_code () with
                 | Some code ->
                     let test_msg = { C2c_mcp.from_alias = "c2c-system";
                                      to_alias = sid;
                                      content = Printf.sprintf "<c2c event=\"channel-test\" code=\"%s\"/>" code;
                                      deferrable = false; reply_via = None; enc_status = None } in
                     emit_notification ~session_id:sid test_msg
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
                let queued = C2c_mcp.Broker.drain_inbox broker ~session_id:sid in
                emit_notifications ~session_id:sid queued
          in
          loop ~broker_root ~negotiated_capabilities_ref)

let server_banner () =
  Version.banner ~role:"mcp-server" ~git_hash:C2c_mcp.server_git_hash

let () =
  server_banner ();
  debug_log ("starting pid=" ^ string_of_int (Unix.getpid ()));
  (match session_id () with Some s -> debug_log ("session_id=" ^ s) | None -> debug_log "no session_id");
  debug_log ("channel_delivery=" ^ string_of_bool (channel_delivery_enabled ()));
  let root = broker_root () in
  debug_log ("broker_root=" ^ root);
  C2c_mcp.auto_register_startup ~broker_root:root;
  C2c_mcp.auto_join_rooms_startup ~broker_root:root;
  let negotiated_capabilities_ref = ref [] in
  (match (channel_delivery_enabled (), session_id ()) with
   | true, Some sid -> debug_log ("starting inbox watcher for " ^ sid); Lwt.async (fun () ->
         start_inbox_watcher ~broker_root:root ~session_id:sid
           ~emit_notification ~negotiated_capabilities_ref)
   | _, _ -> ());
  try
    Lwt_main.run (loop ~broker_root:root ~negotiated_capabilities_ref);
    debug_log "normal exit"
  with exn ->
    debug_log ("FATAL: " ^ Printexc.to_string exn ^ "\n" ^ Printexc.get_backtrace ());
    raise exn
