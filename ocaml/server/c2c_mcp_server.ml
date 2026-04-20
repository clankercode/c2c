let broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> path
  | _ -> Filename.concat (Filename.get_temp_dir_name ()) "c2c-mcp-broker"

let session_id () =
  match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

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
  | None -> 30.0

let assoc_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field name json =
  match assoc_opt name json with Some (`String value) -> Some value | _ -> None

let client_supports_claude_channel request =
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

let next_channel_capability ~current request =
  match string_field "method" request with
  | Some "initialize" -> client_supports_claude_channel request
  | _ -> current

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
   notifications for new messages while the session runs. *)
let start_inbox_watcher ~broker_root ~session_id ~emit_notification =
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
          let broker = C2c_mcp.Broker.create ~root:broker_root in
          let messages = C2c_mcp.Broker.drain_inbox broker ~session_id in
          let rec emit_all = function
            | [] -> Lwt.return_unit
            | msg :: rest ->
                let* () = emit_notification msg in
                emit_all rest
          in
          let* () = emit_all messages in
          (* Use post-drain file size, not pre-drain — avoids missing shorter
             subsequent messages when the previous batch was larger. *)
          let post_drain_size = stat_size () in
          loop post_drain_size
        else
          loop current_size)
      (fun exn ->
        let* () =
          Lwt_io.eprintlf "c2c inbox watcher: %s" (Printexc.to_string exn)
        in
        (* Continue watching after transient errors *)
        loop last_size)
  in
  loop (stat_size ())

let emit_notification msg =
  write_message (C2c_mcp.channel_notification msg)

let rec loop ~broker_root ~channel_capable =
  let open Lwt.Syntax in
  let* msg = read_message () in
  match msg with
  | None -> Lwt.return_unit
  | Some line -> (
      let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
      match json with
      | Error () ->
          let* () = write_message (jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
          loop ~broker_root ~channel_capable
      | Ok request ->
          let channel_capable = next_channel_capability ~current:channel_capable request in
          let* response = C2c_mcp.handle_request ~broker_root request in
          let* () = match response with None -> Lwt.return_unit | Some resp -> write_message resp in
          let* () =
            match (auto_drain_channel_enabled (), channel_capable, session_id ()) with
            | false, _, _ -> Lwt.return_unit
            | true, false, _ -> Lwt.return_unit
            | true, true, None -> Lwt.return_unit
            | true, true, Some sid ->
                let broker = C2c_mcp.Broker.create ~root:broker_root in
                let queued = C2c_mcp.Broker.drain_inbox broker ~session_id:sid in
                let rec emit = function
                  | [] -> Lwt.return_unit
                  | message :: rest ->
                      let* () = emit_notification message in
                      emit rest
                in
                emit queued
          in
          loop ~broker_root ~channel_capable)

let server_banner () =
  Printf.eprintf "c2c mcp-server v%s  build=%s\n%!" C2c_mcp.server_version Version.build_date

let () =
  server_banner ();
  let root = broker_root () in
  C2c_mcp.auto_register_startup ~broker_root:root;
  C2c_mcp.auto_join_rooms_startup ~broker_root:root;
  (* Start background inbox watcher if channel delivery is enabled and we have a session_id *)
  (match (channel_delivery_enabled (), session_id ()) with
   | true, Some sid ->
       Lwt.async (fun () -> start_inbox_watcher ~broker_root:root ~session_id:sid ~emit_notification)
   | _, _ -> ());
  Lwt_main.run (loop ~broker_root:root ~channel_capable:false)
