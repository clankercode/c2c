let broker_root () =
  match Sys.getenv_opt "C2C_MCP_BROKER_ROOT" with
  | Some path when String.trim path <> "" -> path
  | _ -> Filename.concat (Filename.get_temp_dir_name ()) "c2c-mcp-broker"

let session_id () =
  match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let auto_drain_channel_enabled () =
  match Sys.getenv_opt "C2C_MCP_AUTO_DRAIN_CHANNEL" with
  | Some value ->
      let normalized = String.lowercase_ascii (String.trim value) in
      not (List.mem normalized [ "0"; "false"; "no"; "off" ])
  | None -> false

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

let rec loop ~broker_root =
  let open Lwt.Syntax in
  let* msg = read_message () in
  match msg with
  | None -> Lwt.return_unit
  | Some line -> (
      let json = try Ok (Yojson.Safe.from_string line) with _ -> Error () in
      match json with
      | Error () ->
          let* () = write_message (jsonrpc_error ~id:`Null ~code:(-32700) ~message:"Parse error") in
          loop ~broker_root
      | Ok request ->
          let* response = C2c_mcp.handle_request ~broker_root request in
          let* () = match response with None -> Lwt.return_unit | Some resp -> write_message resp in
          let* () =
            match (auto_drain_channel_enabled (), session_id ()) with
            | false, _ -> Lwt.return_unit
            | true, None -> Lwt.return_unit
            | true, Some session_id ->
                let broker = C2c_mcp.Broker.create ~root:broker_root in
                let queued = C2c_mcp.Broker.drain_inbox broker ~session_id in
                let rec emit = function
                  | [] -> Lwt.return_unit
                  | message :: rest ->
                      let* () = write_message (C2c_mcp.channel_notification message) in
                      emit rest
                in
                emit queued
          in
          loop ~broker_root)

let () =
  let root = broker_root () in
  C2c_mcp.auto_register_startup ~broker_root:root;
  Lwt_main.run (loop ~broker_root:root)
