type registration = { session_id : string; alias : string }
type message = { from_alias : string; to_alias : string; content : string }

let server_info = `Assoc [ ("name", `String "c2c"); ("version", `String "0.1.0") ]
let capabilities =
  `Assoc
    [ ("tools", `Assoc [])
    ; ("experimental", `Assoc [ ("claude/channel", `Assoc []) ])
    ]

let jsonrpc_response ~id result =
  `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]

let jsonrpc_error ~id ~code ~message =
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("id", id)
    ; ("error", `Assoc [ ("code", `Int code); ("message", `String message) ])
    ]

let tool_result ~content ~is_error =
  `Assoc
    [ ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String content) ] ])
    ; ("isError", `Bool is_error)
    ]

let tool_definition ~name ~description ~required =
  `Assoc
    [ ("name", `String name)
    ; ("description", `String description)
    ; ( "inputSchema",
        `Assoc
          [ ("type", `String "object")
          ; ("properties", `Assoc [])
          ; ("required", `List (List.map (fun key -> `String key) required))
          ] )
    ]

module Broker = struct
  type t = { root : string }

  let registry_path t = Filename.concat t.root "registry.json"
  let inbox_path t ~session_id = Filename.concat t.root (session_id ^ ".inbox.json")

  let ensure_root t =
    if not (Sys.file_exists t.root) then Unix.mkdir t.root 0o755

  let read_json_file path ~default =
    if Sys.file_exists path then Yojson.Safe.from_file path else default

  let write_json_file path json =
    Yojson.Safe.to_file path json

  let registration_to_json { session_id; alias } =
    `Assoc [ ("session_id", `String session_id); ("alias", `String alias) ]

  let registration_of_json json =
    let open Yojson.Safe.Util in
    { session_id = json |> member "session_id" |> to_string
    ; alias = json |> member "alias" |> to_string
    }

  let message_to_json { from_alias; to_alias; content } =
    `Assoc
      [ ("from_alias", `String from_alias)
      ; ("to_alias", `String to_alias)
      ; ("content", `String content)
      ]

  let message_of_json json =
    let open Yojson.Safe.Util in
    { from_alias = json |> member "from_alias" |> to_string
    ; to_alias = json |> member "to_alias" |> to_string
    ; content = json |> member "content" |> to_string
    }

  let load_registrations t =
    ensure_root t;
    match read_json_file (registry_path t) ~default:(`List []) with
    | `List items -> List.map registration_of_json items
    | _ -> []

  let save_registrations t regs =
    ensure_root t;
    write_json_file (registry_path t) (`List (List.map registration_to_json regs))

  let create ~root = { root }

  let register t ~session_id ~alias =
    let regs = load_registrations t in
    let regs = List.filter (fun reg -> reg.session_id <> session_id) regs in
    save_registrations t ({ session_id; alias } :: regs)

  let list_registrations t = load_registrations t

  let resolve_session_id_by_alias t alias =
    load_registrations t
    |> List.find_opt (fun reg -> reg.alias = alias)
    |> Option.map (fun reg -> reg.session_id)

  let load_inbox t ~session_id =
    ensure_root t;
    match read_json_file (inbox_path t ~session_id) ~default:(`List []) with
    | `List items -> List.map message_of_json items
    | _ -> []

  let save_inbox t ~session_id messages =
    ensure_root t;
    write_json_file
      (inbox_path t ~session_id)
      (`List (List.map message_to_json messages))

  let enqueue_message t ~from_alias ~to_alias ~content =
    match resolve_session_id_by_alias t to_alias with
    | None -> invalid_arg ("unknown alias: " ^ to_alias)
    | Some session_id ->
        let current = load_inbox t ~session_id in
        let next = current @ [ { from_alias; to_alias; content } ] in
        save_inbox t ~session_id next

  let read_inbox t ~session_id = load_inbox t ~session_id

  let drain_inbox t ~session_id =
    let messages = read_inbox t ~session_id in
    save_inbox t ~session_id [];
    messages
end

let channel_notification ({ from_alias; to_alias; content } : message) =
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("method", `String "notifications/claude/channel")
    ; ( "params",
        `Assoc
          [ ("content", `String content)
          ; ( "meta",
              `Assoc
                [ ("from_alias", `String from_alias)
                ; ("to_alias", `String to_alias)
                ] )
          ] )
    ]

let tool_definitions =
  [ tool_definition ~name:"register" ~description:"Register a C2C alias for the current session." ~required:[ "session_id"; "alias" ]
  ; tool_definition ~name:"list" ~description:"List registered C2C peers." ~required:[]
  ; tool_definition ~name:"send" ~description:"Send a C2C message to a registered peer alias." ~required:[ "from_alias"; "to_alias"; "content" ]
  ; tool_definition ~name:"whoami" ~description:"Resolve the current C2C session registration." ~required:[ "session_id" ]
  ]

let string_member name json =
  let open Yojson.Safe.Util in
  json |> member name |> to_string

let handle_tool_call ~(broker : Broker.t) ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      let session_id = string_member "session_id" arguments in
      let alias = string_member "alias" arguments in
      Broker.register broker ~session_id ~alias;
      Lwt.return (tool_result ~content:("registered " ^ alias) ~is_error:false)
  | "list" ->
      let registrations = Broker.list_registrations broker in
      let content =
        `List
          (List.map
             (fun { session_id; alias } ->
               `Assoc [ ("session_id", `String session_id); ("alias", `String alias) ])
             registrations)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "send" ->
      let from_alias = string_member "from_alias" arguments in
      let to_alias = string_member "to_alias" arguments in
      let content = string_member "content" arguments in
      Broker.enqueue_message broker ~from_alias ~to_alias ~content;
      Lwt.return (tool_result ~content:"queued" ~is_error:false)
  | "whoami" ->
      let session_id = string_member "session_id" arguments in
      let alias =
        Broker.list_registrations broker
        |> List.find_opt (fun reg -> reg.session_id = session_id)
        |> Option.map (fun reg -> reg.alias)
      in
      let content =
        match alias with
        | Some found -> found
        | None -> ""
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | _ -> Lwt.return (tool_result ~content:("unknown tool: " ^ tool_name) ~is_error:true)

let handle_request ~broker_root json =
  let open Yojson.Safe.Util in
  let broker = Broker.create ~root:broker_root in
  let id =
    try
      let id_json = json |> member "id" in
      if id_json = `Null then None else Some id_json
    with _ -> None
  in
  let method_ = try json |> member "method" |> to_string with _ -> "" in
  let params = try json |> member "params" with _ -> `Null in
  match (id, method_) with
  | None, _ -> Lwt.return_none
  | Some id, "initialize" ->
      let result =
        `Assoc
          [ ("protocolVersion", `String "2024-11-05")
          ; ("serverInfo", server_info)
          ; ("capabilities", capabilities)
          ]
      in
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "tools/list" ->
      let result = `Assoc [ ("tools", `List tool_definitions) ] in
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "tools/call" ->
      let tool_name = try params |> member "name" |> to_string with _ -> "" in
      let arguments = try params |> member "arguments" with _ -> `Assoc [] in
      let open Lwt.Syntax in
      let* result =
        Lwt.catch
          (fun () -> handle_tool_call ~broker ~tool_name ~arguments)
          (fun exn -> Lwt.return (tool_result ~content:(Printexc.to_string exn) ~is_error:true))
      in
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, _ ->
      Lwt.return_some (jsonrpc_error ~id ~code:(-32601) ~message:("Unknown method: " ^ method_))
