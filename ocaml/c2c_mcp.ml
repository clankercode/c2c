type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  }
type message = { from_alias : string; to_alias : string; content : string }

let server_info = `Assoc [ ("name", `String "c2c"); ("version", `String "0.1.0") ]
let supported_protocol_version = "2024-11-05"
let capabilities =
  `Assoc
    [ ("tools", `Assoc [])
    ; ("experimental", `Assoc [ ("claude/channel", `Assoc []) ])
    ]

let instructions =
  `String
    "C2C is a peer-to-peer messaging broker between Claude sessions. To receive messages reliably, call the `poll_inbox` tool at the start of each turn (and again after any send) — it drains and returns any queued messages as a JSON array. Inbound messages are ALSO emitted as notifications/claude/channel for clients launched with --dangerously-load-development-channels server:c2c, but most sessions do not surface that custom notification method; poll_inbox is the flag-independent path. Use `register` once per session, `list` to see peers, `send` to enqueue a message to a peer alias, `whoami` to confirm your own alias."

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
    if Sys.file_exists path then
      try Yojson.Safe.from_file path with Yojson.Json_error _ -> default
    else default

  let write_json_file path json =
    Yojson.Safe.to_file path json

  let registration_to_json { session_id; alias; pid; pid_start_time } =
    let base =
      [ ("session_id", `String session_id); ("alias", `String alias) ]
    in
    let with_pid =
      match pid with
      | Some n -> base @ [ ("pid", `Int n) ]
      | None -> base
    in
    let fields =
      match pid_start_time with
      | Some n -> with_pid @ [ ("pid_start_time", `Int n) ]
      | None -> with_pid
    in
    `Assoc fields

  let int_opt_member name json =
    let open Yojson.Safe.Util in
    try
      match json |> member name with
      | `Null -> None
      | `Int n -> Some n
      | _ -> None
    with _ -> None

  let registration_of_json json =
    let open Yojson.Safe.Util in
    { session_id = json |> member "session_id" |> to_string
    ; alias = json |> member "alias" |> to_string
    ; pid = int_opt_member "pid" json
    ; pid_start_time = int_opt_member "pid_start_time" json
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

  let registry_lock_path t = Filename.concat t.root "registry.json.lock"

  let with_registry_lock t f =
    ensure_root t;
    let fd =
      Unix.openfile (registry_lock_path t) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let register t ~session_id ~alias ~pid ~pid_start_time =
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        (* Dedupe by BOTH session_id and alias. Evicting prior regs for the
           same alias matters when a session is re-launched: without this, a
           legacy pid-less row lingers at the head of the registry forever
           (because registration_is_alive treats pid=None as alive for
           backwards compatibility), and enqueue_message's first-live-match
           rule routes every new message to the dead twin's inbox. *)
        let regs =
          List.filter
            (fun reg -> reg.session_id <> session_id && reg.alias <> alias)
            regs
        in
        save_registrations t
          ({ session_id; alias; pid; pid_start_time } :: regs))

  let list_registrations t = load_registrations t

  (* /proc/<pid>/stat line layout: "<pid> (<comm>) <state> <ppid> ... <starttime> ..."
     comm can contain spaces and parens, so we split on the LAST ')'. The fields
     after comm are space-separated; starttime is field 22 in the 1-indexed man
     page, which is index 19 in the 0-indexed tail array (tail[0] = state). *)
  let read_pid_start_time pid =
    let path = Printf.sprintf "/proc/%d/stat" pid in
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let line = input_line ic in
          match String.rindex_opt line ')' with
          | None -> None
          | Some idx ->
              let tail = String.sub line (idx + 2) (String.length line - idx - 2) in
              let parts = String.split_on_char ' ' tail in
              (match List.nth_opt parts 19 with
               | Some token ->
                   (try Some (int_of_string token) with _ -> None)
               | None -> None))
    with Sys_error _ | End_of_file -> None

  let capture_pid_start_time pid =
    match pid with
    | None -> None
    | Some n -> read_pid_start_time n

  let registration_is_alive reg =
    match reg.pid with
    | None -> true
    | Some pid ->
        if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then false
        else
          (match reg.pid_start_time with
           | None -> true
           | Some stored ->
               (match read_pid_start_time pid with
                | Some current -> current = stored
                | None -> false))

  type resolve_result =
    | Resolved of string
    | Unknown_alias
    | All_recipients_dead

  let resolve_live_session_id_by_alias t alias =
    let matches =
      load_registrations t |> List.filter (fun reg -> reg.alias = alias)
    in
    match matches with
    | [] -> Unknown_alias
    | _ ->
        (match List.find_opt registration_is_alive matches with
         | Some reg -> Resolved reg.session_id
         | None -> All_recipients_dead)

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

  let inbox_lock_path t ~session_id =
    Filename.concat t.root (session_id ^ ".inbox.lock")

  (* POSIX fcntl-based exclusive lock via Unix.lockf on a sidecar file, so
     concurrent enqueue/drain/sweep don't clobber each other's read-modify-
     write window. Compatible with Python fcntl.lockf on the same sidecar,
     which matters for c2c_send.py's broker-only fallback path. *)
  let with_inbox_lock t ~session_id f =
    ensure_root t;
    let fd =
      Unix.openfile (inbox_lock_path t ~session_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let enqueue_message t ~from_alias ~to_alias ~content =
    match resolve_live_session_id_by_alias t to_alias with
    | Unknown_alias -> invalid_arg ("unknown alias: " ^ to_alias)
    | All_recipients_dead ->
        invalid_arg ("recipient is not alive: " ^ to_alias)
    | Resolved session_id ->
        with_inbox_lock t ~session_id (fun () ->
            let current = load_inbox t ~session_id in
            let next = current @ [ { from_alias; to_alias; content } ] in
            save_inbox t ~session_id next)

  let read_inbox t ~session_id = load_inbox t ~session_id

  let drain_inbox t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        save_inbox t ~session_id [];
        messages)

  type sweep_result =
    { dropped_regs : registration list
    ; deleted_inboxes : string list
    ; preserved_messages : int
    }

  let inbox_suffix = ".inbox.json"

  let dead_letter_path t = Filename.concat t.root "dead-letter.jsonl"

  let dead_letter_lock_path t =
    Filename.concat t.root "dead-letter.jsonl.lock"

  (* POSIX fcntl lock on a sidecar — serializes appends to dead-letter.jsonl
     across OCaml processes and against any Python path that also uses
     Unix.lockf/fcntl.lockf on the same sidecar. *)
  let with_dead_letter_lock t f =
    ensure_root t;
    let fd =
      Unix.openfile (dead_letter_lock_path t) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let append_dead_letter t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_dead_letter_lock t (fun () ->
            let oc =
              open_out_gen
                [ Open_wronly; Open_append; Open_creat ]
                0o644 (dead_letter_path t)
            in
            Fun.protect
              ~finally:(fun () -> try close_out oc with _ -> ())
              (fun () ->
                let ts = Unix.gettimeofday () in
                List.iter
                  (fun msg ->
                    let record =
                      `Assoc
                        [ ("deleted_at", `Float ts)
                        ; ("from_session_id", `String session_id)
                        ; ("message", message_to_json msg)
                        ]
                    in
                    output_string oc (Yojson.Safe.to_string record);
                    output_char oc '\n')
                  messages))

  let inbox_file_session_id name =
    if Filename.check_suffix name inbox_suffix then
      Some (Filename.chop_suffix name inbox_suffix)
    else None

  let list_inbox_session_ids t =
    ensure_root t;
    let entries =
      try Sys.readdir t.root with Sys_error _ -> [||]
    in
    Array.fold_left
      (fun acc name ->
        match inbox_file_session_id name with
        | Some sid -> sid :: acc
        | None -> acc)
      []
      entries

  let try_unlink path =
    try Unix.unlink path; true
    with Unix.Unix_error _ -> false

  let sweep t =
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let alive, dead =
          List.partition registration_is_alive regs
        in
        if dead <> [] then save_registrations t alive;
        let alive_sids =
          List.fold_left
            (fun acc reg -> reg.session_id :: acc)
            []
            alive
        in
        let all_inbox_sids = list_inbox_session_ids t in
        let preserved = ref 0 in
        let deleted =
          List.filter
            (fun sid ->
              if List.mem sid alive_sids then false
              else
                (* Hold the inbox lock across read+preserve+delete so a
                   concurrent enqueue can't race the unlink. Any non-empty
                   content is appended to dead-letter.jsonl before the
                   inbox file is removed, so cleanup is non-destructive to
                   operator signal. We intentionally leave the .inbox.lock
                   sidecar in place: unlinking the lock file while another
                   process holds a lockf on a separate fd for the same
                   path would open a window for a new opener to get a
                   LOCK immediately against a different inode. Sidecar
                   files are empty, so keeping them is cheap. *)
                with_inbox_lock t ~session_id:sid (fun () ->
                    let msgs = load_inbox t ~session_id:sid in
                    if msgs <> [] then begin
                      append_dead_letter t ~session_id:sid ~messages:msgs;
                      preserved := !preserved + List.length msgs
                    end;
                    try_unlink (inbox_path t ~session_id:sid)))
            all_inbox_sids
        in
        { dropped_regs = dead
        ; deleted_inboxes = deleted
        ; preserved_messages = !preserved
        })
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
  [ tool_definition ~name:"register" ~description:"Register a C2C alias for the current session." ~required:[ "alias" ]
  ; tool_definition ~name:"list" ~description:"List registered C2C peers." ~required:[]
  ; tool_definition ~name:"send" ~description:"Send a C2C message to a registered peer alias." ~required:[ "from_alias"; "to_alias"; "content" ]
  ; tool_definition ~name:"whoami" ~description:"Resolve the current C2C session registration." ~required:[]
  ; tool_definition ~name:"poll_inbox" ~description:"Drain queued C2C messages for the current session. Returns a JSON array of {from_alias,to_alias,content} objects; call this at the start of each turn and after each send to reliably receive messages regardless of whether the client surfaces notifications/claude/channel." ~required:[]
  ; tool_definition ~name:"sweep" ~description:"Remove dead registrations (whose parent process has exited) and delete orphan inbox files that belong to no current registration. Any non-empty orphan inbox content is appended to dead-letter.jsonl inside the broker directory before the inbox file is deleted, so cleanup is non-destructive to operator signal. Returns JSON {dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id], preserved_messages: int}." ~required:[]
  ]

let string_member name json =
  let open Yojson.Safe.Util in
  json |> member name |> to_string

let optional_string_member name json =
  let open Yojson.Safe.Util in
  try
    match json |> member name with
    | `Null -> None
    | value ->
        let text = to_string value in
        if String.trim text = "" then None else Some text
  with _ -> None

let current_session_id () =
  match Sys.getenv_opt "C2C_MCP_SESSION_ID" with
  | Some value when String.trim value <> "" -> Some value
  | _ -> None

let current_client_pid () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else (try Some (int_of_string trimmed) with _ -> None)
  | None -> None

let resolve_session_id arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id -> session_id
  | None ->
      (match current_session_id () with
      | Some session_id -> session_id
      | None -> invalid_arg "missing session_id")

let handle_tool_call ~(broker : Broker.t) ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      let session_id = resolve_session_id arguments in
      let alias = string_member "alias" arguments in
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let pid_start_time = Broker.capture_pid_start_time pid in
      Broker.register broker ~session_id ~alias ~pid ~pid_start_time;
      Lwt.return (tool_result ~content:("registered " ^ alias) ~is_error:false)
  | "list" ->
      let registrations = Broker.list_registrations broker in
      let content =
        `List
          (List.map
             (fun { session_id; alias; pid; pid_start_time = _ } ->
               let base =
                 [ ("session_id", `String session_id); ("alias", `String alias) ]
               in
               let fields =
                 match pid with
                 | Some n -> base @ [ ("pid", `Int n) ]
                 | None -> base
               in
               `Assoc fields)
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
      let session_id = resolve_session_id arguments in
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
  | "poll_inbox" ->
      let session_id = resolve_session_id arguments in
      let messages = Broker.drain_inbox broker ~session_id in
      let content =
        `List
          (List.map
             (fun ({ from_alias; to_alias; content } : message) ->
               `Assoc
                 [ ("from_alias", `String from_alias)
                 ; ("to_alias", `String to_alias)
                 ; ("content", `String content)
                 ])
             messages)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "sweep" ->
      let { Broker.dropped_regs; deleted_inboxes; preserved_messages } =
        Broker.sweep broker
      in
      let content =
        `Assoc
          [ ( "dropped_regs",
              `List
                (List.map
                   (fun { session_id; alias; _ } ->
                     `Assoc
                       [ ("session_id", `String session_id)
                       ; ("alias", `String alias)
                       ])
                   dropped_regs) )
          ; ( "deleted_inboxes",
              `List (List.map (fun sid -> `String sid) deleted_inboxes) )
          ; ("preserved_messages", `Int preserved_messages)
          ]
        |> Yojson.Safe.to_string
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
          [ ("protocolVersion", `String supported_protocol_version)
          ; ("serverInfo", server_info)
          ; ("instructions", instructions)
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
