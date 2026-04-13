type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  }
type message = { from_alias : string; to_alias : string; content : string }

let server_version = "0.5.0"

let server_features =
  [ "liveness"
  ; "pid_start_time"
  ; "registry_lock"
  ; "inbox_lock"
  ; "alias_dedupe"
  ; "sweep"
  ; "dead_letter"
  ; "poll_inbox"
  ; "send_all"
  ; "inbox_migration_on_register"
  ; "registry_locked_enqueue"
  ; "list_alive_tristate"
  ; "atomic_write"
  ; "broker_files_mode_0600"
  ]

let server_info =
  `Assoc
    [ ("name", `String "c2c")
    ; ("version", `String server_version)
    ; ("features", `List (List.map (fun f -> `String f) server_features))
    ]

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
    (* Atomic write via temp+rename. A truncate-in-place writer that
       gets SIGKILLed (OOM, parent process exit, kill -9) between
       truncate and full write leaves a partial JSON file that the
       next reader will fail to parse. Writing to a per-pid sidecar
       and then Unix.rename'ing into place gives readers an
       all-or-nothing view: they always see either the old content
       or the new content, never partial. The rename is atomic on
       POSIX as long as src and dst are on the same filesystem,
       which they are by construction (sidecar lives next to the
       target). The 0o600 mode policy is preserved on the temp file,
       which becomes the destination inode after rename. *)
    let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    let oc =
      open_out_gen
        [ Open_wronly; Open_creat; Open_trunc; Open_text ]
        0o600 tmp
    in
    let cleanup_tmp () = try Unix.unlink tmp with _ -> () in
    (try
       Fun.protect
         ~finally:(fun () -> try close_out oc with _ -> ())
         (fun () -> Yojson.Safe.to_channel oc json)
     with e ->
       cleanup_tmp ();
       raise e);
    try Unix.rename tmp path
    with e ->
      cleanup_tmp ();
      raise e

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

  (* Tristate liveness for the list tool: distinguishes "we cannot
     tell" (legacy pidless row) from "we checked and the kernel says
     alive" / "we checked and the pid is dead or pid-reused". The
     legacy `registration_is_alive` collapses Unknown into Alive for
     backward-compat with sweep / enqueue, but operators consuming
     the list tool benefit from seeing the unknown case explicitly so
     they can identify pidless zombie rows. *)
  type liveness_state = Alive | Dead | Unknown

  let registration_liveness_state reg =
    match reg.pid with
    | None -> Unknown
    | Some pid ->
        if not (Sys.file_exists ("/proc/" ^ string_of_int pid)) then Dead
        else
          (match reg.pid_start_time with
           | None -> Alive
           | Some stored ->
               (match read_pid_start_time pid with
                | Some current -> if current = stored then Alive else Dead
                | None -> Dead))

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

  (* register, enqueue_message, and send_all all take the registry lock
     before touching inbox state. Lock order is consistently
     registry → inbox (matches sweep). Without this, a sender that resolved
     the registry snapshot before a re-register can write to a now-orphan
     inbox file because resolution is unsynchronized with eviction. *)

  let register t ~session_id ~alias ~pid ~pid_start_time =
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let evicted_regs, kept =
          List.partition
            (fun reg -> reg.session_id = session_id || reg.alias = alias)
            regs
        in
        save_registrations t
          ({ session_id; alias; pid; pid_start_time } :: kept);
        (* Migrate undrained inbox messages from any evicted reg whose
           session_id differs from the new one. Done WHILE holding the
           registry lock so a concurrent enqueue cannot resolve the alias
           to the stale session_id and write to the about-to-be-deleted
           inbox file. Inbox locks are taken sequentially under the
           registry lock — never nested — and always old-then-new, so two
           concurrent re-registers serialize cleanly through the registry
           mutex. *)
        List.iter
          (fun reg ->
            if reg.session_id <> session_id then begin
              let migrated =
                with_inbox_lock t ~session_id:reg.session_id (fun () ->
                    let msgs = load_inbox t ~session_id:reg.session_id in
                    if msgs <> [] then
                      save_inbox t ~session_id:reg.session_id [];
                    (try Unix.unlink
                           (inbox_path t ~session_id:reg.session_id)
                     with Unix.Unix_error _ -> ());
                    msgs)
              in
              if migrated <> [] then
                with_inbox_lock t ~session_id (fun () ->
                    let current = load_inbox t ~session_id in
                    save_inbox t ~session_id (current @ migrated))
            end)
          evicted_regs)

  let enqueue_message t ~from_alias ~to_alias ~content =
    with_registry_lock t (fun () ->
        match resolve_live_session_id_by_alias t to_alias with
        | Unknown_alias -> invalid_arg ("unknown alias: " ^ to_alias)
        | All_recipients_dead ->
            invalid_arg ("recipient is not alive: " ^ to_alias)
        | Resolved session_id ->
            with_inbox_lock t ~session_id (fun () ->
                let current = load_inbox t ~session_id in
                let next =
                  current @ [ { from_alias; to_alias; content } ]
                in
                save_inbox t ~session_id next))

  type send_all_result =
    { sent_to : string list
    ; skipped : (string * string) list
    }

  (* 1:N broadcast primitive. Fan out [content] to every unique alias in
     the registry except the sender and any alias in [exclude_aliases].
     A recipient whose registrations are all dead is skipped with reason
     "not_alive" rather than raising — partial failure is the normal case
     for broadcast. Per-recipient enqueue reuses [with_inbox_lock] so this
     interlocks with concurrent 1:1 sends on the same inbox. *)
  let send_all t ~from_alias ~content ~exclude_aliases =
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
        let sent = ref [] in
        let skipped = ref [] in
        List.iter
          (fun reg ->
            if Hashtbl.mem seen reg.alias then ()
            else begin
              Hashtbl.add seen reg.alias ();
              if reg.alias = from_alias then ()
              else if List.mem reg.alias exclude_aliases then ()
              else
                match resolve_live_session_id_by_alias t reg.alias with
                | Resolved session_id ->
                    with_inbox_lock t ~session_id (fun () ->
                        let current = load_inbox t ~session_id in
                        let next =
                          current
                          @ [ { from_alias; to_alias = reg.alias; content } ]
                        in
                        save_inbox t ~session_id next);
                    sent := reg.alias :: !sent
                | All_recipients_dead ->
                    skipped := (reg.alias, "not_alive") :: !skipped
                | Unknown_alias -> ()
            end)
          regs;
        { sent_to = List.rev !sent; skipped = List.rev !skipped })

  let read_inbox t ~session_id = load_inbox t ~session_id

  (* Skip the file write when the inbox is already empty. This keeps
     close_write events out of inotify streams — every tool call that
     auto-drains would otherwise fire a noisy event on an idle inbox,
     swamping agent-visibility monitors with meaningless drain churn.
     Semantic is unchanged: callers still get [] for an empty inbox. *)
  let drain_inbox t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        (match messages with
         | [] -> ()
         | _ -> save_inbox t ~session_id []);
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
            (* Mode 0o600: dead-letter records carry the same envelope
               content as live inbox files (which Python writers create
               at 0o600), so this file must not be world-readable. *)
            let oc =
              open_out_gen
                [ Open_wronly; Open_append; Open_creat ]
                0o600 (dead_letter_path t)
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
  ; tool_definition ~name:"send_all" ~description:"Fan out a message to every currently-registered peer except the sender (and any alias in the optional `exclude_aliases` array). Non-live recipients are skipped with reason \"not_alive\" rather than raising, so partial failure does not abort the broadcast. Per-recipient enqueue takes the same per-inbox lock used by `send`. Returns JSON {sent_to:[alias], skipped:[{alias, reason}]}." ~required:[ "from_alias"; "content" ]
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
             (fun reg ->
               let { session_id; alias; pid; pid_start_time = _ } = reg in
               let base =
                 [ ("session_id", `String session_id); ("alias", `String alias) ]
               in
               let with_pid =
                 match pid with
                 | Some n -> base @ [ ("pid", `Int n) ]
                 | None -> base
               in
               (* Tristate `alive`: Bool true / Bool false / Null for
                  legacy pidless rows. Operators can filter on this
                  to identify zombie peers before broadcasting. *)
               let alive_field =
                 match Broker.registration_liveness_state reg with
                 | Broker.Alive -> `Bool true
                 | Broker.Dead -> `Bool false
                 | Broker.Unknown -> `Null
               in
               `Assoc (with_pid @ [ ("alive", alive_field) ]))
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
  | "send_all" ->
      let from_alias = string_member "from_alias" arguments in
      let content = string_member "content" arguments in
      let exclude_aliases =
        let open Yojson.Safe.Util in
        try
          match arguments |> member "exclude_aliases" with
          | `List items ->
              List.filter_map
                (fun item ->
                  match item with `String s -> Some s | _ -> None)
                items
          | _ -> []
        with _ -> []
      in
      let { Broker.sent_to; skipped } =
        Broker.send_all broker ~from_alias ~content ~exclude_aliases
      in
      let result_json =
        `Assoc
          [ ( "sent_to",
              `List (List.map (fun alias -> `String alias) sent_to) )
          ; ( "skipped",
              `List
                (List.map
                   (fun (alias, reason) ->
                     `Assoc
                       [ ("alias", `String alias)
                       ; ("reason", `String reason)
                       ])
                   skipped) )
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content:result_json ~is_error:false)
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
