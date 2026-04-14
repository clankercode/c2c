type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  ; registered_at : float option
  }
type message = { from_alias : string; to_alias : string; content : string }
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }
type room_visibility = Public | Invite_only
type room_meta = { visibility : room_visibility; invited_members : string list }

let server_version = "0.6.9"

let server_features =
  [ "liveness"
  ; "pid_start_time"
  ; "registered_at"
  ; "registry_lock"
  ; "inbox_lock"
  ; "alias_dedupe"
  ; "sweep"
  ; "dead_letter"
  ; "dead_letter_redelivery"
  ; "poll_inbox"
  ; "send_all"
  ; "inbox_migration_on_register"
  ; "registry_locked_enqueue"
  ; "list_alive_tristate"
  ; "atomic_write"
  ; "broker_files_mode_0600"
  ; "rooms"
  ; "startup_auto_register"
  ; "send_room_alias_fallback"
  ; "inbox_archive_on_drain"
  ; "history_tool"
  ; "join_room_history_backfill"
  ; "my_rooms_tool"
  ; "peek_inbox_tool"
  ; "join_leave_from_alias_fallback"
  ; "rpc_audit_log"
  ; "tail_log_tool"
  ; "current_session_alias_binding"
  ; "register_alias_hijack_guard"
  ; "send_alias_impersonation_guard"
  ; "missing_sender_alias_errors"
  ; "prune_rooms_tool"
  ; "room_join_system_broadcast"
  ; "room_invite"
  ; "room_visibility"
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

(* Property schema helpers for tool inputSchema declarations *)
let prop name description =
  (name, `Assoc [("type", `String "string"); ("description", `String description)])

let int_prop name description =
  (name, `Assoc [("type", `String "integer"); ("description", `String description)])

let arr_prop name description =
  ( name,
    `Assoc
      [ ("type", `String "array")
      ; ("items", `Assoc [ ("type", `String "string") ])
      ; ("description", `String description)
      ] )

let tool_definition ~name ~description ~required ~properties =
  `Assoc
    [ ("name", `String name)
    ; ("description", `String description)
    ; ( "inputSchema",
        `Assoc
          [ ("type", `String "object")
          ; ("properties", `Assoc properties)
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

  let registration_to_json { session_id; alias; pid; pid_start_time; registered_at } =
    let base =
      [ ("session_id", `String session_id); ("alias", `String alias) ]
    in
    let with_pid =
      match pid with
      | Some n -> base @ [ ("pid", `Int n) ]
      | None -> base
    in
    let with_pst =
      match pid_start_time with
      | Some n -> with_pid @ [ ("pid_start_time", `Int n) ]
      | None -> with_pid
    in
    let fields =
      match registered_at with
      | Some ts -> with_pst @ [ ("registered_at", `Float ts) ]
      | None -> with_pst
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

  let float_opt_member name json =
    let open Yojson.Safe.Util in
    try
      match json |> member name with
      | `Null -> None
      | `Float f -> Some f
      | `Int n -> Some (float_of_int n)
      | _ -> None
    with _ -> None

  let registration_of_json json =
    let open Yojson.Safe.Util in
    { session_id = json |> member "session_id" |> to_string
    ; alias = json |> member "alias" |> to_string
    ; pid = int_opt_member "pid" json
    ; pid_start_time = int_opt_member "pid_start_time" json
    ; registered_at = float_opt_member "registered_at" json
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
  let root t = t.root

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
        (* Split registrations into:
           - conflicting: entries with our NEW alias held by a DIFFERENT session
             (alias conflict — must evict to claim the alias)
           - rest: everything else (our own prior entry if any, other sessions)
           We do NOT use a single partition with `||` because that wrongly
           evicts our own prior entry when renaming within the same session,
           which causes duplicate registry entries for the same session_id.
           See: same-session re-registration must update in-place, not evict+add. *)
        let conflicting, rest =
          List.partition
            (fun reg -> reg.alias = alias && reg.session_id <> session_id)
            regs
        in
        (* Same-session re-registration (alias changed or pid/registered_at
           refresh): update in-place by replacing the old entry in [rest]. *)
        let new_reg = { session_id; alias; pid; pid_start_time
                      ; registered_at = Some (Unix.gettimeofday ()) }
        in
        let kept =
          match
            List.partition (fun reg -> reg.session_id = session_id) rest
          with
          | [], others ->
              (* no prior entry for this session — fresh registration: add new one *)
              new_reg :: others
          | [ _old_reg ], others ->
              (* prior entry found — update alias/pid/start_time in place *)
              new_reg :: others
          | multiple, others ->
              (* edge case: same session had multiple entries (shouldn't happen
                 with the fixed logic, but guard defensively) — keep first, drop rest *)
              new_reg :: others
        in
        save_registrations t kept;
        (* Migrate undrained inbox messages from any evicted conflicting reg.
           Done WHILE holding the registry lock so a concurrent enqueue cannot
           resolve the alias to the stale session_id and write to the
           about-to-be-deleted inbox file. Inbox locks are taken sequentially
           under the registry lock — never nested — and always
           old-then-new, so two concurrent re-registers serialize cleanly
           through the registry mutex. *)
        List.iter
          (fun reg ->
            (* conflicting only contains entries with alias=alias &&
               session_id<>session_id, so this condition is always true;
               kept for clarity and safety *)
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
          conflicting)

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

  (* ---------- inbox archive (drain is append-only, not destructive) ----------
     Every message drained via poll_inbox is appended to
     <root>/archive/<session_id>.jsonl BEFORE the live inbox is cleared.
     This means drained messages become part of a per-session, append-only
     history that tools like `history` can read back. If the archive append
     fails (disk full, permission, etc.) we do NOT clear the inbox, so the
     "drained messages are never deleted" invariant holds atomically under
     the per-inbox lock. *)

  let archive_dir t = Filename.concat t.root "archive"

  let archive_path t ~session_id =
    Filename.concat (archive_dir t) (session_id ^ ".jsonl")

  let archive_lock_path t ~session_id =
    Filename.concat (archive_dir t) (session_id ^ ".lock")

  let ensure_archive_dir t =
    ensure_root t;
    let d = archive_dir t in
    if not (Sys.file_exists d) then Unix.mkdir d 0o700

  (* POSIX fcntl lock on a per-session sidecar file. Scoped per session so
     a drain by one session never blocks drains by another. Same pattern
     as the inbox lock. *)
  let with_archive_lock t ~session_id f =
    ensure_archive_dir t;
    let fd =
      Unix.openfile (archive_lock_path t ~session_id)
        [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let append_archive t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_archive_lock t ~session_id (fun () ->
            (* Mode 0o600: archive records carry DM content, must not be
               world-readable. *)
            let oc =
              open_out_gen
                [ Open_wronly; Open_append; Open_creat ]
                0o600 (archive_path t ~session_id)
            in
            Fun.protect
              ~finally:(fun () -> try close_out oc with _ -> ())
              (fun () ->
                let ts = Unix.gettimeofday () in
                List.iter
                  (fun ({ from_alias; to_alias; content } : message) ->
                    let record =
                      `Assoc
                        [ ("drained_at", `Float ts)
                        ; ("session_id", `String session_id)
                        ; ("from_alias", `String from_alias)
                        ; ("to_alias", `String to_alias)
                        ; ("content", `String content)
                        ]
                    in
                    output_string oc (Yojson.Safe.to_string record);
                    output_char oc '\n')
                  messages))

  type archive_entry =
    { ae_drained_at : float
    ; ae_from_alias : string
    ; ae_to_alias : string
    ; ae_content : string
    }

  let archive_entry_of_json json =
    let open Yojson.Safe.Util in
    { ae_drained_at =
        (match json |> member "drained_at" with
         | `Float f -> f
         | `Int i -> float_of_int i
         | _ -> 0.0)
    ; ae_from_alias =
        (try json |> member "from_alias" |> to_string with _ -> "")
    ; ae_to_alias =
        (try json |> member "to_alias" |> to_string with _ -> "")
    ; ae_content =
        (try json |> member "content" |> to_string with _ -> "")
    }

  (* Return up to [limit] most-recent archive entries for [session_id],
     newest first. Reads the per-session jsonl file under the archive
     lock so concurrent appends can't interleave. Missing file => []. *)
  let read_archive t ~session_id ~limit =
    if limit <= 0 then []
    else
      with_archive_lock t ~session_id (fun () ->
          let path = archive_path t ~session_id in
          if not (Sys.file_exists path) then []
          else
            let ic = open_in path in
            Fun.protect
              ~finally:(fun () -> try close_in ic with _ -> ())
              (fun () ->
                let rec loop acc =
                  match input_line ic with
                  | exception End_of_file -> List.rev acc
                  | line ->
                      let line = String.trim line in
                      if line = "" then loop acc
                      else
                        let entry =
                          try
                            Some (archive_entry_of_json
                                    (Yojson.Safe.from_string line))
                          with _ -> None
                        in
                        (match entry with
                         | Some e -> loop (e :: acc)
                         | None -> loop acc)
                in
                let all = loop [] in
                (* [all] is now oldest-first. Take the last [limit] and
                   reverse to get newest-first. *)
                let total = List.length all in
                let drop = max 0 (total - limit) in
                let rec drop_n n = function
                  | [] -> []
                  | _ :: rest when n > 0 -> drop_n (n - 1) rest
                  | xs -> xs
                in
                List.rev (drop_n drop all)))

  (* Skip the file write when the inbox is already empty. This keeps
     close_write events out of inotify streams — every tool call that
     auto-drains would otherwise fire a noisy event on an idle inbox,
     swamping agent-visibility monitors with meaningless drain churn.
     Semantic is unchanged: callers still get [] for an empty inbox.

     Drained messages are appended to the per-session archive file
     BEFORE the live inbox is cleared. If the archive append raises
     (disk full, permission, IO error), we let the exception propagate
     WITHOUT clearing the inbox — the drain fails atomically under the
     inbox lock, so the caller will see the error and the messages
     remain in the live inbox for retry. This upholds the "drained
     messages are never deleted, only archived" invariant even in the
     failure case. *)
  let drain_inbox t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        (match messages with
         | [] -> ()
         | _ ->
             append_archive t ~session_id ~messages;
             save_inbox t ~session_id []);
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

  (* Scan dead-letter.jsonl for records belonging to this session and return
     them for redelivery, removing matched records from the file.
     Called on re-registration so a session that was swept between outer-loop
     iterations automatically recovers messages that were queued while it was
     offline.  Returns [] when the dead-letter file doesn't exist or has no
     matching records.

     Matching rules (OR):
     1. from_session_id == session_id   — exact match; covers managed sessions
        with a stable C2C_MCP_SESSION_ID (kimi-local, opencode-local, codex).
     2. message.to_alias == alias       — alias match; covers Claude Code which
        keeps a stable alias but gets a fresh CLAUDE_SESSION_ID on every restart. *)
  let drain_dead_letter_for_session t ~session_id ~alias =
    let path = dead_letter_path t in
    (* Fast path: no file → nothing to do *)
    let exists = (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false) in
    if not exists then []
    else
      with_dead_letter_lock t (fun () ->
        let all_lines =
          try
            let ic = open_in path in
            Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let buf = ref [] in
              (try while true do buf := input_line ic :: !buf done
               with End_of_file -> ());
              List.rev !buf)
          with _ -> []
        in
        let to_redeliver = ref [] in
        let to_keep = ref [] in
        List.iter (fun line ->
          let trimmed = String.trim line in
          if trimmed = "" then ()
          else
            let keep =
              try
                let json = Yojson.Safe.from_string trimmed in
                let msg_json = Yojson.Safe.Util.member "message" json in
                let sid_json = Yojson.Safe.Util.member "from_session_id" json in
                let to_alias_json = Yojson.Safe.Util.member "to_alias" msg_json in
                let matches =
                  (match sid_json with
                   | `String sid -> sid = session_id
                   | _ -> false)
                  ||
                  (match to_alias_json with
                   | `String ta -> ta = alias
                   | _ -> false)
                in
                if matches then
                  (try
                     let msg = message_of_json msg_json in
                     to_redeliver := msg :: !to_redeliver;
                     false
                   with _ ->
                     (* If a matching record is malformed, keep it in
                        dead-letter instead of silently dropping content we
                        failed to redeliver. *)
                     true)
                else true
              with _ -> true
            in
            if keep then to_keep := line :: !to_keep
        ) all_lines;
        (* Rewrite the file with only the kept records *)
        (try
          let oc = open_out path in
          Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
            List.iter (fun line ->
              output_string oc line;
              output_char oc '\n'
            ) (List.rev !to_keep))
        with _ -> ());
        List.rev !to_redeliver)

  (* Enqueue a list of messages directly into a session's inbox by session_id,
     bypassing alias resolution.  Used for dead-letter redelivery where the
     session may have re-registered with a different alias. *)
  let enqueue_by_session_id t ~session_id ~messages =
    match messages with
    | [] -> ()
    | _ ->
        with_inbox_lock t ~session_id (fun () ->
          let current = load_inbox t ~session_id in
          save_inbox t ~session_id (current @ messages))

  let redeliver_dead_letter_for_session t ~session_id ~alias =
    let msgs = drain_dead_letter_for_session t ~session_id ~alias in
    if msgs <> [] then enqueue_by_session_id t ~session_id ~messages:msgs;
    List.length msgs

  (* ---------- N:N rooms (phase 2) ---------- *)

  let valid_room_id room_id =
    room_id <> ""
    && String.for_all
         (fun c ->
           (c >= 'a' && c <= 'z')
           || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9')
           || c = '-' || c = '_')
         room_id

  let rooms_dir t = Filename.concat t.root "rooms"

  let room_dir t ~room_id = Filename.concat (rooms_dir t) room_id

  let room_members_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "members.json"

  let room_history_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "history.jsonl"

  let room_members_lock_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "members.lock"

  let room_history_lock_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "history.lock"

  let ensure_room_dir t ~room_id =
    ensure_root t;
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then Unix.mkdir rd 0o755;
    let d = room_dir t ~room_id in
    if not (Sys.file_exists d) then Unix.mkdir d 0o755

  let with_room_members_lock t ~room_id f =
    ensure_room_dir t ~room_id;
    let fd =
      Unix.openfile (room_members_lock_path t ~room_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let with_room_history_lock t ~room_id f =
    ensure_room_dir t ~room_id;
    let fd =
      Unix.openfile (room_history_lock_path t ~room_id) [ O_RDWR; O_CREAT ] 0o644
    in
    Fun.protect
      ~finally:(fun () ->
        (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ());
        (try Unix.close fd with _ -> ()))
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        f ())

  let room_member_to_json { rm_alias; rm_session_id; joined_at } =
    `Assoc
      [ ("alias", `String rm_alias)
      ; ("session_id", `String rm_session_id)
      ; ("joined_at", `Float joined_at)
      ]

  let room_member_of_json json =
    let open Yojson.Safe.Util in
    { rm_alias = json |> member "alias" |> to_string
    ; rm_session_id = json |> member "session_id" |> to_string
    ; joined_at = json |> member "joined_at" |> to_number
    }

  let load_room_members t ~room_id =
    ensure_room_dir t ~room_id;
    match read_json_file (room_members_path t ~room_id) ~default:(`List []) with
    | `List items -> List.map room_member_of_json items
    | _ -> []

  let save_room_members t ~room_id members =
    ensure_room_dir t ~room_id;
    write_json_file (room_members_path t ~room_id)
      (`List (List.map room_member_to_json members))

  let room_meta_path t ~room_id =
    Filename.concat (room_dir t ~room_id) "meta.json"

  let room_visibility_to_json = function
    | Public -> `String "public"
    | Invite_only -> `String "invite_only"

  let room_visibility_of_json json =
    match json with
    | `String "invite_only" -> Invite_only
    | _ -> Public

  let room_meta_to_json { visibility; invited_members } =
    `Assoc
      [ ("visibility", room_visibility_to_json visibility)
      ; ("invited_members", `List (List.map (fun s -> `String s) invited_members))
      ]

  let room_meta_of_json json =
    let open Yojson.Safe.Util in
    { visibility =
        (try room_visibility_of_json (member "visibility" json) with _ -> Public)
    ; invited_members =
        (try
           match member "invited_members" json with
           | `List items ->
               List.filter_map
                 (function `String s -> Some s | _ -> None)
                 items
           | _ -> []
         with _ -> [])
    }

  let load_room_meta t ~room_id =
    ensure_room_dir t ~room_id;
    match read_json_file (room_meta_path t ~room_id) ~default:(`Assoc []) with
    | `Assoc _ as json -> room_meta_of_json json
    | _ -> { visibility = Public; invited_members = [] }

  let save_room_meta t ~room_id meta =
    ensure_room_dir t ~room_id;
    write_json_file (room_meta_path t ~room_id) (room_meta_to_json meta)

  let room_system_alias = "c2c-system"

  let room_join_content ~alias ~room_id = alias ^ " joined room " ^ room_id

  let append_room_history_unchecked t ~room_id ~from_alias ~content =
    let ts = Unix.gettimeofday () in
    with_room_history_lock t ~room_id (fun () ->
        let oc =
          open_out_gen
            [ Open_wronly; Open_append; Open_creat ]
            0o600 (room_history_path t ~room_id)
        in
        Fun.protect
          ~finally:(fun () -> try close_out oc with _ -> ())
          (fun () ->
            let record =
              `Assoc
                [ ("ts", `Float ts)
                ; ("from_alias", `String from_alias)
                ; ("content", `String content)
                ]
            in
            output_string oc (Yojson.Safe.to_string record);
            output_char oc '\n'));
    ts

  let fan_out_room_message t ~room_id ~from_alias ~content =
    let members =
      with_room_members_lock t ~room_id (fun () ->
          load_room_members t ~room_id)
    in
    let delivered = ref [] in
    let skipped = ref [] in
    List.iter
      (fun m ->
        if m.rm_alias = from_alias then ()
        else begin
          let tagged_to = m.rm_alias ^ "@" ^ room_id in
          try
            with_registry_lock t (fun () ->
                match resolve_live_session_id_by_alias t m.rm_alias with
                | Resolved session_id ->
                    with_inbox_lock t ~session_id (fun () ->
                        let current = load_inbox t ~session_id in
                        let next =
                          current @ [ { from_alias; to_alias = tagged_to; content } ]
                        in
                        save_inbox t ~session_id next);
                    delivered := m.rm_alias :: !delivered
                | All_recipients_dead | Unknown_alias ->
                    skipped := m.rm_alias :: !skipped)
          with _ ->
            skipped := m.rm_alias :: !skipped
        end)
      members;
    (List.rev !delivered, List.rev !skipped)

  let broadcast_room_join t ~room_id ~alias =
    let content = room_join_content ~alias ~room_id in
    ignore (append_room_history_unchecked t ~room_id ~from_alias:room_system_alias ~content);
    ignore (fan_out_room_message t ~room_id ~from_alias:room_system_alias ~content)

  let join_room t ~room_id ~alias ~session_id =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let meta = load_room_meta t ~room_id in
    let current_members = load_room_members t ~room_id in
    let already_member =
      List.exists
        (fun m -> m.rm_alias = alias || m.rm_session_id = session_id)
        current_members
    in
    if meta.visibility = Invite_only && not already_member then
      if not (List.mem alias meta.invited_members) then
        invalid_arg
          ("join_room rejected: room '" ^ room_id ^ "' is invite-only and '" ^ alias ^ "' is not on the invite list");
    let updated, should_broadcast =
      with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        (* Same alias with a new session_id is a restart. Same session_id with
           a new alias is a rename. In both cases there must be only one member
           row, otherwise room fanout and social presence duplicate the peer. *)
        let existing =
          List.find_opt
            (fun m -> m.rm_alias = alias || m.rm_session_id = session_id)
            members
        in
        let exact_existing =
          match existing with
          | Some m when m.rm_alias = alias && m.rm_session_id = session_id ->
              true
          | _ -> false
        in
        let joined_at =
          match existing with
          | Some m -> m.joined_at
          | None -> Unix.gettimeofday ()
        in
        let member = { rm_alias = alias; rm_session_id = session_id; joined_at } in
        if exact_existing then (members, false)
        else
          let rec replace inserted = function
            | [] -> if inserted then [] else [ member ]
            | m :: rest
              when m.rm_alias = alias || m.rm_session_id = session_id ->
                if inserted then replace true rest
                else member :: replace true rest
            | m :: rest -> m :: replace inserted rest
          in
          let updated = replace false members in
          if updated <> members then save_room_members t ~room_id updated;
          (updated, updated <> members))
    in
    if should_broadcast then broadcast_room_join t ~room_id ~alias;
    updated

  let leave_room t ~room_id ~alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        let updated = List.filter (fun m -> m.rm_alias <> alias) members in
        save_room_members t ~room_id updated;
        updated)

  let send_room_invite t ~room_id ~from_alias ~invitee_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    let is_member = List.exists (fun m -> m.rm_alias = from_alias) members in
    if not is_member then
      invalid_arg ("send_room_invite rejected: only room members can invite");
    let meta = load_room_meta t ~room_id in
    if not (List.mem invitee_alias meta.invited_members) then
      save_room_meta t ~room_id
        { meta with invited_members = meta.invited_members @ [ invitee_alias ] }

  let set_room_visibility t ~room_id ~from_alias ~visibility =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let members = load_room_members t ~room_id in
    let is_member = List.exists (fun m -> m.rm_alias = from_alias) members in
    if not is_member then
      invalid_arg ("set_room_visibility rejected: only room members can change visibility");
    let meta = load_room_meta t ~room_id in
    save_room_meta t ~room_id { meta with visibility }

  let rename_room_member_alias t ~room_id ~session_id ~new_alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        match List.find_opt (fun m -> m.rm_session_id = session_id) members with
        | None -> members
        | Some existing ->
            let renamed = { existing with rm_alias = new_alias } in
            let without_session =
              List.filter (fun m -> m.rm_session_id <> session_id) members
            in
            let updated = without_session @ [ renamed ] in
            save_room_members t ~room_id updated;
            updated)

  (* Evict dead sessions from all room member lists.  Called as part of
     the sweep tool so dead sessions don't linger as room members after
     their registration is dropped.  Sessions with a live outer loop
     re-join automatically via C2C_MCP_AUTO_JOIN_ROOMS on restart.
     Returns a list of (room_id, alias) pairs that were evicted.

     Uses BOTH session_id and alias matching to handle the case where
     a room member was added with one session_id but the registration
     later re-registered with a different session_id (common with
     managed outer loops that reuse the same alias). *)
  let evict_dead_from_rooms t ~dead_session_ids ~dead_aliases =
    let dead_keys = dead_session_ids in
    let should_evict m =
      List.mem m.rm_session_id dead_keys
      || List.mem m.rm_alias dead_aliases
    in
    if dead_session_ids = [] && dead_aliases = [] then []
    else begin
      let rd = rooms_dir t in
      if not (Sys.file_exists rd) then []
      else begin
        let room_names =
          try
            Array.to_list (Sys.readdir rd)
            |> List.filter (fun name ->
                   Sys.is_directory (Filename.concat rd name))
          with _ -> []
        in
        let evicted = ref [] in
        List.iter (fun room_id ->
          with_room_members_lock t ~room_id (fun () ->
            let members = load_room_members t ~room_id in
            let kept, removed =
              List.partition (fun m -> not (should_evict m)) members
            in
            if removed <> [] then begin
              save_room_members t ~room_id kept;
              List.iter
                (fun m -> evicted := (room_id, m.rm_alias) :: !evicted)
                removed
            end))
          room_names;
        !evicted
      end
    end

  let orphan_room_members t regs =
    let has_registration member =
      List.exists
        (fun reg ->
          reg.session_id = member.rm_session_id || reg.alias = member.rm_alias)
        regs
    in
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else
      let room_names =
        try
          Array.to_list (Sys.readdir rd)
          |> List.filter (fun name ->
                 Sys.is_directory (Filename.concat rd name))
        with _ -> []
      in
      room_names
      |> List.concat_map (fun room_id ->
             load_room_members t ~room_id
             |> List.filter (fun member -> not (has_registration member)))

  (* Evict dead members from rooms without touching registrations or inboxes.
     Safe to call while outer loops are running (unlike sweep). *)
  let prune_rooms t =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      (* Use tristate liveness: treat Unknown (pid=None, no /proc check possible)
         the same as Dead for eviction purposes.  registration_is_alive collapses
         Unknown→Alive for backward-compat with sweep/enqueue, but in prune_rooms
         we want to clear out pidless zombie room members too — they cannot be
         verified alive and their inboxes accumulate dead fan-out messages. *)
      let dead_regs =
        regs
        |> List.filter (fun r ->
               match registration_liveness_state r with
               | Alive -> false
               | Dead | Unknown -> true)
      in
      let orphan_members = orphan_room_members t regs in
      let dead_sids =
        List.map (fun r -> r.session_id) dead_regs
        @ List.map (fun m -> m.rm_session_id) orphan_members
      in
      let dead_aliases =
        List.map (fun r -> r.alias) dead_regs
        @ List.map (fun m -> m.rm_alias) orphan_members
      in
      evict_dead_from_rooms t ~dead_session_ids:dead_sids ~dead_aliases)

  (* Public alias for tests and external callers. *)
  let read_room_members = load_room_members

  let append_room_history t ~room_id ~from_alias ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    append_room_history_unchecked t ~room_id ~from_alias ~content

  let read_room_history t ~room_id ~limit =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let path = room_history_path t ~room_id in
    if not (Sys.file_exists path) then []
    else begin
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> try close_in ic with _ -> ())
        (fun () ->
          let lines = ref [] in
          (try
             while true do
               let line = input_line ic in
               if line <> "" then
                 lines := line :: !lines
             done
           with End_of_file -> ());
          let all = List.rev !lines in
          let n = List.length all in
          let to_take = if limit <= 0 then n else min limit n in
          let start = n - to_take in
          let taken =
            List.filteri (fun i _ -> i >= start) all
          in
          List.map
            (fun line ->
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              { rm_from_alias = json |> member "from_alias" |> to_string
              ; rm_room_id = room_id
              ; rm_content = json |> member "content" |> to_string
              ; rm_ts = json |> member "ts" |> to_number
              })
            taken)
    end

  type send_room_result =
    { sr_delivered_to : string list
    ; sr_skipped : string list
    ; sr_ts : float
    }

  (* Suppress byte-identical repeat messages from the same sender within this window. *)
  let room_send_dedup_window_s = 60.0

  let send_room t ~from_alias ~room_id ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    (* Dedup: skip if the same sender just sent the same content within the window. *)
    let now = Unix.gettimeofday () in
    let recent = read_room_history t ~room_id ~limit:20 in
    let is_dup =
      List.exists
        (fun m ->
          m.rm_from_alias = from_alias
          && m.rm_content = content
          && now -. m.rm_ts < room_send_dedup_window_s)
        recent
    in
    if is_dup then
      { sr_delivered_to = []; sr_skipped = []; sr_ts = now }
    else begin
    (* Step 1: append to history (under history lock, released before fan-out) *)
    let ts = append_room_history_unchecked t ~room_id ~from_alias ~content in
    (* Step 2: fan out to each member except sender. For each recipient,
       take registry_lock -> inbox_lock (existing lock order) and enqueue
       with to_alias tagged as "<alias>@<room_id>" so the recipient can
       distinguish room messages from direct messages. *)
    let delivered, skipped =
      fan_out_room_message t ~room_id ~from_alias ~content
    in
    { sr_delivered_to = delivered
    ; sr_skipped = skipped
    ; sr_ts = ts
    }
    end

  type room_info =
    { ri_room_id : string
    ; ri_member_count : int
    ; ri_members : string list
    ; ri_alive_member_count : int
    ; ri_dead_member_count : int
    ; ri_unknown_member_count : int
    ; ri_member_details : room_member_info list
    ; ri_visibility : room_visibility
    ; ri_invited_members : string list
    }
  and room_member_info =
    { rmi_alias : string
    ; rmi_session_id : string
    ; rmi_alive : bool option
    }

  let room_member_liveness t members =
    let regs = list_registrations t in
    let find_reg member =
      match
        List.find_opt
          (fun reg -> reg.session_id = member.rm_session_id)
          regs
      with
      | Some reg -> Some reg
      | None -> List.find_opt (fun reg -> reg.alias = member.rm_alias) regs
    in
    List.map
      (fun member ->
        let alive =
          match find_reg member with
          | None -> Some false
          | Some reg ->
              (match reg.pid with
               | None -> None
               | Some _ -> Some (registration_is_alive reg))
        in
        { rmi_alias = member.rm_alias
        ; rmi_session_id = member.rm_session_id
        ; rmi_alive = alive
        })
      members

  let room_info_of_members t ~room_id members =
    let meta = load_room_meta t ~room_id in
    let details = room_member_liveness t members in
    let count_by predicate =
      List.fold_left
        (fun count detail -> if predicate detail.rmi_alive then count + 1 else count)
        0 details
    in
    { ri_room_id = room_id
    ; ri_member_count = List.length members
    ; ri_members = List.map (fun m -> m.rm_alias) members
    ; ri_alive_member_count = count_by (( = ) (Some true))
    ; ri_dead_member_count = count_by (( = ) (Some false))
    ; ri_unknown_member_count = count_by (( = ) None)
    ; ri_member_details = details
    ; ri_visibility = meta.visibility
    ; ri_invited_members = meta.invited_members
    }

  let list_rooms t =
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else begin
      let entries =
        try Sys.readdir rd with Sys_error _ -> [||]
      in
      Array.fold_left
        (fun acc name ->
          let dir_path = Filename.concat rd name in
          if Sys.is_directory dir_path then begin
            let members =
              try load_room_members t ~room_id:name
              with _ -> []
            in
            room_info_of_members t ~room_id:name members :: acc
          end else acc)
        []
        entries
      |> List.rev
    end

  (* Rooms where [session_id] is a member. Keyed on session_id (not alias)
     so a rename stays tracking the same session. Returns the same
     [room_info] shape as [list_rooms], plus the caller's own alias in
     each room they're currently a member of (useful when the caller
     has joined the same room under two aliases via different
     sessions, or when the alias has changed). *)
  let my_rooms t ~session_id =
    let rd = rooms_dir t in
    if not (Sys.file_exists rd) then []
    else begin
      let entries =
        try Sys.readdir rd with Sys_error _ -> [||]
      in
      Array.fold_left
        (fun acc name ->
          let dir_path = Filename.concat rd name in
          if Sys.is_directory dir_path then begin
            let members =
              try load_room_members t ~room_id:name
              with _ -> []
            in
            if List.exists (fun m -> m.rm_session_id = session_id) members
            then
              room_info_of_members t ~room_id:name members :: acc
            else acc
          end else acc)
        []
        entries
      |> List.rev
    end
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

let room_member_detail_json (detail : Broker.room_member_info) =
  `Assoc
    [ ("alias", `String detail.rmi_alias)
    ; ("session_id", `String detail.rmi_session_id)
    ; ( "alive",
        match detail.rmi_alive with
        | Some value -> `Bool value
        | None -> `Null )
    ]

let room_info_json (r : Broker.room_info) =
  `Assoc
    [ ("room_id", `String r.ri_room_id)
    ; ("member_count", `Int r.ri_member_count)
    ; ("members", `List (List.map (fun a -> `String a) r.ri_members))
    ; ("alive_member_count", `Int r.ri_alive_member_count)
    ; ("dead_member_count", `Int r.ri_dead_member_count)
    ; ("unknown_member_count", `Int r.ri_unknown_member_count)
    ; ("member_details", `List (List.map room_member_detail_json r.ri_member_details))
    ; ("visibility",
        match r.ri_visibility with
        | Public -> `String "public"
        | Invite_only -> `String "invite_only")
    ; ("invited_members", `List (List.map (fun a -> `String a) r.ri_invited_members))
    ]

let tool_definitions =
  [ tool_definition ~name:"register"
      ~description:"Register a C2C alias for the current session. `alias` is optional: if omitted the server falls back to the C2C_MCP_AUTO_REGISTER_ALIAS environment variable. Calling register with no arguments is a safe way to refresh your registration (e.g. after a process restart that changed your PID)."
      ~required:[]
      ~properties:
        [ prop "alias" "New alias to register for this session. Pass a different alias to rename without changing env vars."
        ; prop "session_id" "Optional session id override; defaults to the current MCP session."
        ]
  ; tool_definition ~name:"list"
      ~description:"List registered C2C peers."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send"
      ~description:"Send a C2C message to a registered peer alias. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback for non-session callers. Returns JSON {queued:true, ts:<epoch-seconds>, from_alias:<string>, to_alias:<string>} on success."
      ~required:["to_alias"; "content"]
      ~properties:[ prop "to_alias" "Target peer alias."; prop "from_alias" "Legacy fallback sender alias (deprecated)."; prop "content" "Message body." ]
  ; tool_definition ~name:"whoami"
      ~description:"Resolve the current C2C session registration."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override; defaults to the current MCP session." ]
  ; tool_definition ~name:"poll_inbox"
      ~description:"Drain queued C2C messages for the current session. Returns a JSON array of {from_alias,to_alias,content} objects; call this at the start of each turn and after each send to reliably receive messages regardless of whether the client surfaces notifications/claude/channel."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override for compatible clients." ]
  ; tool_definition ~name:"peek_inbox"
      ~description:"Non-draining inbox check for the current session. Returns the same JSON array as `poll_inbox` but leaves the messages in the inbox so a subsequent `poll_inbox` still sees them. Useful for 'any mail?' checks without losing messages on error paths. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override for compatible clients." ]
  ; tool_definition ~name:"sweep"
      ~description:"Remove dead registrations (whose parent process has exited) and delete orphan inbox files that belong to no current registration. Any non-empty orphan inbox content is appended to dead-letter.jsonl inside the broker directory before the inbox file is deleted, so cleanup is non-destructive to operator signal. Dead sessions are also evicted from all room member lists. Returns JSON {dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id], preserved_messages: int, evicted_room_members:[{room_id,alias}]}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send_all"
      ~description:"Fan out a message to every currently-registered peer except the sender (and any alias in the optional `exclude_aliases` array). The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback. Non-live recipients are skipped with reason \"not_alive\" rather than raising, so partial failure does not abort the broadcast. Per-recipient enqueue takes the same per-inbox lock used by `send`. Returns JSON {sent_to:[alias], skipped:[{alias, reason}]}."
      ~required:["content"]
      ~properties:[ prop "content" "Message body to broadcast."; arr_prop "exclude_aliases" "Array of aliases to skip." ]
  ; tool_definition ~name:"join_room"
      ~description:"Join a persistent N:N room. Creates the room if it does not exist. Idempotent per (alias, session_id). Room IDs must be alphanumeric + hyphens + underscores. Returns JSON {room_id, members, history} where `history` is the most recent messages from the room's append-only log so a newly-joined member can catch up on context without a separate `room_history` call. Optional `history_limit` (default 20, max 200) controls how many history entries to include; pass 0 to skip history backfill. The member alias is resolved from the current MCP session when possible; `alias`/`from_alias` remain legacy fallbacks."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Unique room identifier (alphanumeric, hyphens, underscores)."; prop "alias" "Legacy fallback member alias (deprecated)."; int_prop "history_limit" "Max history entries on join (default 20, max 200, 0 to skip)." ]
  ; tool_definition ~name:"leave_room"
      ~description:"Leave a persistent N:N room. Returns the member list after leave. The member alias is resolved from the current MCP session when possible; `alias`/`from_alias` remain legacy fallbacks."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room to leave."; prop "alias" "Legacy fallback member alias (deprecated)." ]
  ; tool_definition ~name:"send_room"
      ~description:"Send a message to a persistent N:N room. Appends to room history and fans out to every member's inbox except the sender, with to_alias tagged as '<alias>@<room_id>'. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback. Returns JSON {delivered_to, skipped, ts}."
      ~required:["room_id"; "content"]
      ~properties:[ prop "room_id" "Target room."; prop "content" "Message body."; prop "alias" "Legacy fallback sender alias (deprecated)." ]
  ; tool_definition ~name:"list_rooms"
      ~description:"List all persistent rooms with member counts and member aliases. Returns a JSON array of {room_id, member_count, members}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"my_rooms"
      ~description:"List rooms where your current session is a member. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only see your own memberships. Same row shape as list_rooms: JSON array of {room_id, member_count, members}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"room_history"
      ~description:"Return the last `limit` (default 50) messages from a room's append-only history. Read-only."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room whose history to retrieve."; int_prop "limit" "Max messages to return (default 50)." ]
  ; tool_definition ~name:"history"
      ~description:"Return your own archived inbox messages, newest first. Every message drained via poll_inbox is archived to a per-session append-only log before the live inbox is cleared, so this tool gives you a durable record of everything you've ever received. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only read your own history. Optional `limit` (default 50). Returns a JSON array of {drained_at, from_alias, to_alias, content} objects."
      ~required:[]
      ~properties:[ int_prop "limit" "Max messages to return (default 50)." ]
  ; tool_definition ~name:"tail_log"
      ~description:"Return the last N lines from the broker RPC audit log (broker.log). Each line is a JSON object {ts, tool, ok}. Useful for verifying that your sends and polls actually reached the broker, without needing to read the file directly. Content fields are not logged — only tool names and success/fail status. Optional `limit` (default 50, max 500). Returns a JSON array of log entries, oldest first."
      ~required:[]
      ~properties:[ int_prop "limit" "Max log entries (default 50, max 500)." ]
  ; tool_definition ~name:"prune_rooms"
      ~description:"Evict dead members from all room member lists without touching registrations or inboxes. Safe to call while outer loops are running (unlike `sweep`, which also drops registrations and deletes inboxes). Returns JSON {evicted_room_members:[{room_id,alias}]}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send_room_invite"
      ~description:"Invite an alias to a room. Only existing room members can send invites. For invite-only rooms, the invitee will be allowed to join."
      ~required:["room_id"; "invitee_alias"]
      ~properties:[ prop "room_id" "Room to invite to."; prop "invitee_alias" "Alias to invite."; prop "alias" "Legacy fallback sender alias (deprecated)." ]
  ; tool_definition ~name:"set_room_visibility"
      ~description:"Change a room's visibility mode. public = anyone can join; invite_only = only invited aliases can join. Only existing room members can change visibility."
      ~required:["room_id"; "visibility"]
      ~properties:[ prop "room_id" "Room to modify."; prop "visibility" "Either 'public' or 'invite_only'."; prop "alias" "Legacy fallback sender alias (deprecated)." ]
  ]

let string_member name json =
  let open Yojson.Safe.Util in
  json |> member name |> to_string

(* Like [string_member] but accepts a list of candidate argument names
   and picks the first one that is present and non-empty. Used for
   send / send_all / send_room where OpenCode's model frequently
   substitutes [alias] for [from_alias] because [join_room] takes
   [alias]. Keeps existing [from_alias] callers working while
   unblocking opencode round-trips. *)
let string_member_any names json =
  let open Yojson.Safe.Util in
  let rec find = function
    | [] ->
        (* fall through to the first name so the raised exception
           names the canonical key, matching the pre-existing error
           surface for missing required arguments. *)
        (match names with
         | [] -> invalid_arg "string_member_any: no candidate names"
         | first :: _ -> json |> member first |> to_string)
    | name :: rest ->
        (match json |> member name with
         | `Null -> find rest
         | value ->
             (try
                let text = to_string value in
                if String.trim text = "" then find rest else text
              with _ -> find rest))
  in
  find names

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

let auto_register_alias () =
  match Sys.getenv_opt "C2C_MCP_AUTO_REGISTER_ALIAS" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let current_client_pid () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_PID" with
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None
      else
        (try
           let pid = int_of_string trimmed in
           if pid > 0 && Sys.file_exists (Printf.sprintf "/proc/%d" pid)
           then Some pid
           else None
         with _ -> None)
  | None -> None

let auto_register_startup ~broker_root =
  match (auto_register_alias (), current_session_id ()) with
  | Some alias, Some session_id ->
      let broker = Broker.create ~root:broker_root in
      (* Safety guard: if an alive registration already exists for this
         session_id with a DIFFERENT alias, skip auto-register. This
         prevents session hijack when a child process (e.g. kimi -p) inherits
         CLAUDE_SESSION_ID from a running Claude Code session but has a
         different C2C_MCP_AUTO_REGISTER_ALIAS configured. *)
      let existing = Broker.list_registrations broker in
      (* Guard 1: if an alive registration already exists for this session_id
         with a DIFFERENT alias, skip — prevents session hijack when a child
         process inherits CLAUDE_SESSION_ID but has a different alias. *)
      let hijack_guard =
        List.exists
          (fun reg ->
            reg.session_id = session_id
            && reg.alias <> alias
            && Broker.registration_is_alive reg)
          existing
      in
      (* Guard 2: if an alive registration already exists for this ALIAS
         with a DIFFERENT session_id, skip — prevents a one-shot or probe
         process from evicting an active peer that owns this alias. A new
         session is allowed to claim the alias once the existing holder dies
         (its PID check will return false, making this guard inactive).
         The SAME pid is always allowed to re-register so session-id drift
         (e.g. after refresh-peer or outer-loop env changes) self-heals. *)
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let alias_occupied_guard =
        List.exists
          (fun reg ->
            reg.alias = alias
            && reg.session_id <> session_id
            && Broker.registration_is_alive reg
            && reg.pid <> pid)
          existing
      in
      (* Guard 3: if an alive registration already exists for this exact
         session_id + alias with a DIFFERENT pid, skip — prevents a child
         process (e.g. kimi launched from codex) from inheriting a wrong
         C2C_MCP_CLIENT_PID and clobbering the correct liveness entry.
         Legitimate restarts are still allowed because the old PID will be
         dead by the time the new process starts. *)
      let same_session_alive_different_pid =
        List.exists
          (fun reg ->
             reg.session_id = session_id
             && reg.alias = alias
             && Broker.registration_is_alive reg
             && reg.pid <> pid)
          existing
      in
      if not hijack_guard && not alias_occupied_guard && not same_session_alive_different_pid then begin
        let pid_start_time = Broker.capture_pid_start_time pid in
        Broker.register broker ~session_id ~alias ~pid ~pid_start_time;
        ignore (Broker.redeliver_dead_letter_for_session broker ~session_id ~alias)
      end
  | _ -> ()

(** Auto-join rooms listed in C2C_MCP_AUTO_JOIN_ROOMS (comma-separated) on
    server startup. Only runs when auto-registration is also configured (both
    C2C_MCP_AUTO_REGISTER_ALIAS and C2C_MCP_SESSION_ID must be set). This is
    the social-layer entry point: operators set
      C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge
    in the MCP env so every agent session joins the persistent social channel
    automatically on first startup. Idempotent — joining the same room twice
    is a no-op on the broker side. *)
let auto_join_rooms_startup ~broker_root =
  match (auto_register_alias (), current_session_id ()) with
  | Some alias, Some session_id ->
      let rooms_raw =
        match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
        | Some v -> String.trim v
        | None -> ""
      in
      if rooms_raw <> "" then begin
        let rooms =
          String.split_on_char ',' rooms_raw
          |> List.map String.trim
          |> List.filter (fun s -> s <> "")
        in
        let broker = Broker.create ~root:broker_root in
        let alias =
          match
            List.find_opt
              (fun reg -> reg.session_id = session_id)
              (Broker.list_registrations broker)
          with
          | Some reg -> reg.alias
          | None -> alias
        in
        List.iter
          (fun room_id ->
            if Broker.valid_room_id room_id then
              ignore (Broker.join_room broker ~room_id ~alias ~session_id)
            (* silently skip invalid room IDs so a misconfiguration doesn't
               crash the server *))
          rooms
      end
  | _ -> ()

let resolve_session_id arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id when session_id <> "" -> session_id
  | _ ->
      (match current_session_id () with
      | Some session_id -> session_id
      | None -> invalid_arg "missing session_id")

let current_registered_alias broker =
  match current_session_id () with
  | None -> None
  | Some session_id ->
      Broker.list_registrations broker
      |> List.find_opt
           (fun reg -> reg.session_id = session_id)
      |> Option.map (fun reg -> reg.alias)

let alias_for_current_session_or_argument broker arguments =
  match current_registered_alias broker with
  | Some alias -> Some alias
  | None ->
      (match optional_string_member "from_alias" arguments with
       | Some a -> Some a
       | None -> optional_string_member "alias" arguments)

let missing_sender_alias_result tool_name =
  tool_result
    ~content:
      (Printf.sprintf
         "%s: missing sender alias. Register this session first or pass \
          from_alias explicitly."
         tool_name)
    ~is_error:true

let missing_member_alias_result tool_name =
  tool_result
    ~content:
      (Printf.sprintf
         "%s: missing member alias. Register this session first or pass alias \
          explicitly."
         tool_name)
    ~is_error:true

(* Guard: reject send/send_all/send_room if from_alias is held by an alive
   session with a different session_id. This prevents unregistered callers (or
   callers whose session isn't bound to this alias) from impersonating live
   peers.
   - If the caller IS registered with this alias (same session_id) → None (ok).
   - If no session_id context is available → None (allow legacy / system calls).
   - Otherwise, returns Some conflict_reg if alive different-session holds alias. *)
let send_alias_impersonation_check broker from_alias =
  match current_session_id () with
  | None -> None
  | Some current_sid ->
      List.find_opt
        (fun reg ->
          reg.alias = from_alias
          && reg.session_id <> current_sid
          (* Require a real pid that /proc confirms is running. Pidless
             registrations are legacy/ambiguous — we do not block on them
             to avoid false positives in CLI tests and operator tooling
             that writes registry entries without pids. *)
          && reg.pid <> None
          && Broker.registration_is_alive reg)
        (Broker.list_registrations broker)

let handle_tool_call ~(broker : Broker.t) ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      let session_id = resolve_session_id arguments in
      let alias =
        match optional_string_member "alias" arguments with
        | Some a -> a
        | None ->
            (match auto_register_alias () with
             | Some a -> a
             | None -> invalid_arg "alias is required (pass {\"alias\":\"your-name\"} or set C2C_MCP_AUTO_REGISTER_ALIAS)")
      in
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      (* Detect alias rename before registering so we can notify rooms. *)
      let old_alias_opt =
        let existing =
          List.find_opt
            (fun reg -> reg.session_id = session_id && reg.alias <> alias)
            (Broker.list_registrations broker)
        in
        match existing with
        | Some reg -> Some reg.alias
        | None -> None
      in
      (* Capture rooms BEFORE re-registering (membership still uses old alias). *)
      let rooms_to_notify =
        match old_alias_opt with
        | None -> []
        | Some _ ->
            List.map (fun ri -> ri.Broker.ri_room_id)
              (Broker.my_rooms broker ~session_id)
      in
      let pid_start_time = Broker.capture_pid_start_time pid in
      (* Guard: refuse to evict an alive registration that owns this alias under
         a different session_id. An agent re-registering its own alias (same
         session_id, e.g. after a PID change) is always allowed. This prevents
         confused or malicious agents from hijacking another agent's alias. *)
      let alias_hijack_conflict =
        List.find_opt
          (fun reg ->
            reg.alias = alias
            && reg.session_id <> session_id
            && Broker.registration_is_alive reg)
          (Broker.list_registrations broker)
      in
      (match alias_hijack_conflict with
       | Some conflict ->
           Lwt.return
             (tool_result
                ~content:
                  (Printf.sprintf
                     "register rejected: alias '%s' is currently held by \
                      an alive session '%s'. Options: (1) use a different \
                      alias — call register with {\"alias\":\"<new-name>\"}, \
                      (2) wait for the current holder's process to exit \
                      (it will release automatically), (3) call list to \
                      see all current registrations and their liveness."
                     alias conflict.session_id)
                ~is_error:true)
       | None ->
           Broker.register broker ~session_id ~alias ~pid ~pid_start_time;
           List.iter
             (fun room_id ->
               try
                 ignore
                   (Broker.rename_room_member_alias broker ~room_id ~session_id
                      ~new_alias:alias)
               with _ -> ())
             rooms_to_notify;
           (* Fan out peer-renamed notification to rooms the session was in. *)
           (match old_alias_opt with
            | None -> ()
            | Some old_alias ->
                let content =
                  Printf.sprintf
                    {|{"type":"peer_renamed","old_alias":"%s","new_alias":"%s"}|}
                    old_alias alias
                in
                List.iter
                  (fun room_id ->
                    (try
                       ignore
                         (Broker.send_room broker ~from_alias:"c2c-system"
                            ~room_id ~content)
                     with _ -> ()))
                  rooms_to_notify);
           (* Auto-redeliver any dead-letter messages addressed to this session.
              This recovers messages that were swept while the managed harness was
              between outer-loop iterations. *)
           let redelivered =
             Broker.redeliver_dead_letter_for_session broker ~session_id ~alias
           in
           let response_content =
             if redelivered > 0 then
               Printf.sprintf "registered %s (redelivered %d dead-letter message%s)"
                 alias redelivered (if redelivered = 1 then "" else "s")
             else
               "registered " ^ alias
           in
           Lwt.return (tool_result ~content:response_content ~is_error:false))
  | "list" ->
      let registrations = Broker.list_registrations broker in
      let content =
        `List
          (List.map
             (fun reg ->
               let { session_id; alias; pid; pid_start_time = _; registered_at } = reg in
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
               let with_alive = with_pid @ [ ("alive", alive_field) ] in
               let fields =
                 match registered_at with
                 | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                 | None -> with_alive
               in
               `Assoc fields)
             registrations)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "send" ->
      let to_alias = string_member "to_alias" arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None ->
           Lwt.return (missing_sender_alias_result "send")
       | Some from_alias ->
           (match send_alias_impersonation_check broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot send as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                Broker.enqueue_message broker ~from_alias ~to_alias ~content;
                let ts = Unix.gettimeofday () in
                let receipt =
                  `Assoc
                    [ ("queued", `Bool true)
                    ; ("ts", `Float ts)
                    ; ("from_alias", `String from_alias)
                    ; ("to_alias", `String to_alias)
                    ]
                  |> Yojson.Safe.to_string
                in
                Lwt.return (tool_result ~content:receipt ~is_error:false)))
  | "send_all" ->
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_all")
       | Some from_alias ->
           (match send_alias_impersonation_check broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send_all rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot broadcast as another agent. \
                           Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
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
                Lwt.return (tool_result ~content:result_json ~is_error:false)))
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
  | "peek_inbox" ->
      (* Like poll_inbox but does not drain. Resolves session_id from
         env only (ignores argument overrides) — same isolation contract
         as `history` and `my_rooms`. *)
      (match current_session_id () with
       | None ->
           Lwt.return
             (tool_result
                ~content:"peek_inbox: no session_id in env (set C2C_MCP_SESSION_ID)"
                ~is_error:true)
       | Some session_id ->
           let messages =
             Broker.with_inbox_lock broker ~session_id (fun () ->
                 Broker.read_inbox broker ~session_id)
           in
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
           Lwt.return (tool_result ~content ~is_error:false))
  | "history" ->
      (* Deliberately bypass resolve_session_id — it would honor a
         session_id argument override, which would let the caller read
         any session's history. For `history`, the caller can only see
         their own archived messages, keyed by the MCP env session id.
         (Subagent-level isolation — preventing a forked child from
         inheriting the parent's env — is goal B, tracked separately in
         the archive-and-subagent-goals findings doc.) *)
      (match current_session_id () with
       | None ->
           Lwt.return
             (tool_result
                ~content:"history: no session_id in env (set C2C_MCP_SESSION_ID)"
                ~is_error:true)
       | Some session_id ->
           let limit =
             match Broker.int_opt_member "limit" arguments with
             | Some n -> n
             | None -> 50
           in
           let entries = Broker.read_archive broker ~session_id ~limit in
           let content =
             `List
               (List.map
                  (fun ({ Broker.ae_drained_at
                        ; ae_from_alias
                        ; ae_to_alias
                        ; ae_content
                        } : Broker.archive_entry) ->
                    `Assoc
                      [ ("drained_at", `Float ae_drained_at)
                      ; ("from_alias", `String ae_from_alias)
                      ; ("to_alias", `String ae_to_alias)
                      ; ("content", `String ae_content)
                      ])
                  entries)
             |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "tail_log" ->
      let limit =
        match Broker.int_opt_member "limit" arguments with
        | Some n when n < 1 -> 1
        | Some n -> min n 500
        | None -> 50
      in
      let log_path = Filename.concat (Broker.root broker) "broker.log" in
      let content =
        if not (Sys.file_exists log_path) then "[]"
        else begin
          (* Read all lines, take last `limit`, parse each as JSON *)
          let lines =
            let ic = open_in log_path in
            Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
              let buf = Buffer.create 4096 in
              (try while true do
                   let line = String.trim (input_line ic) in
                   if line <> "" then begin
                     Buffer.add_string buf line;
                     Buffer.add_char buf '\n'
                   end
                 done with End_of_file -> ());
              String.split_on_char '\n' (Buffer.contents buf)
              |> List.filter (fun s -> String.trim s <> ""))
          in
          let n = List.length lines in
          let tail = if n <= limit then lines
                     else
                       let drop = n - limit in
                       let rec skip i = function
                         | [] -> []
                         | _ :: rest when i > 0 -> skip (i - 1) rest
                         | lst -> lst
                       in
                       skip drop lines
          in
          let parsed =
            List.filter_map
              (fun line ->
                try Some (Yojson.Safe.from_string line)
                with _ -> None)
              tail
          in
          `List parsed |> Yojson.Safe.to_string
        end
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "sweep" ->
      let { Broker.dropped_regs; deleted_inboxes; preserved_messages } =
        Broker.sweep broker
      in
      let dead_sids =
        List.map (fun r -> r.session_id) dropped_regs
      in
      let dead_aliases =
        List.map (fun r -> r.alias) dropped_regs
      in
      let evicted_room_members =
        Broker.evict_dead_from_rooms broker ~dead_session_ids:dead_sids
          ~dead_aliases
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
          ; ( "evicted_room_members",
              `List
                (List.map
                   (fun (room_id, alias) ->
                     `Assoc
                       [ ("room_id", `String room_id)
                       ; ("alias", `String alias)
                       ])
                   evicted_room_members) )
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "prune_rooms" ->
      let evicted = Broker.prune_rooms broker in
      let content =
        `Assoc
          [ ( "evicted_room_members",
              `List
                (List.map
                   (fun (room_id, alias) ->
                     `Assoc
                       [ ("room_id", `String room_id)
                       ; ("alias", `String alias)
                       ])
                   evicted) )
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "join_room" ->
      let room_id = string_member "room_id" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_member_alias_result "join_room")
       | Some alias ->
           let session_id = resolve_session_id arguments in
           let members = Broker.join_room broker ~room_id ~alias ~session_id in
           let history_limit =
             match Broker.int_opt_member "history_limit" arguments with
             | Some n when n < 0 -> 0
             | Some n -> min n 200
             | None -> 20
           in
           let history =
             if history_limit = 0 then []
             else Broker.read_room_history broker ~room_id ~limit:history_limit
           in
           let content =
             `Assoc
               [ ("room_id", `String room_id)
               ; ("members",
                  `List (List.map (fun (m : room_member) ->
                      `Assoc
                        [ ("alias", `String m.rm_alias)
                        ; ("session_id", `String m.rm_session_id)
                        ; ("joined_at", `Float m.joined_at)
                        ]) members))
               ; ("history",
                  `List (List.map (fun (m : room_message) ->
                      `Assoc
                        [ ("ts", `Float m.rm_ts)
                        ; ("from_alias", `String m.rm_from_alias)
                        ; ("content", `String m.rm_content)
                        ]) history))
               ]
             |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "leave_room" ->
      let room_id = string_member "room_id" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_member_alias_result "leave_room")
       | Some alias ->
           let members = Broker.leave_room broker ~room_id ~alias in
           let content =
             `Assoc
               [ ("room_id", `String room_id)
               ; ("members",
                  `List (List.map (fun (m : room_member) ->
                      `Assoc
                        [ ("alias", `String m.rm_alias)
                        ; ("session_id", `String m.rm_session_id)
                        ; ("joined_at", `Float m.joined_at)
                        ]) members))
               ]
             |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "send_room" ->
      let room_id = string_member "room_id" arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_room")
       | Some from_alias ->
           (match send_alias_impersonation_check broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send_room rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot post to a room as another \
                           agent. Options: (1) register your own alias first — call \
                           register with {\"alias\":\"<new-name>\"}, \
                           (2) call whoami to see your current identity."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                let { Broker.sr_delivered_to; sr_skipped; sr_ts } =
                  Broker.send_room broker ~from_alias ~room_id ~content
                in
                let result_json =
                  `Assoc
                    [ ("delivered_to",
                       `List (List.map (fun a -> `String a) sr_delivered_to))
                    ; ("skipped",
                       `List (List.map (fun a -> `String a) sr_skipped))
                    ; ("ts", `Float sr_ts)
                    ]
                  |> Yojson.Safe.to_string
                in
                Lwt.return (tool_result ~content:result_json ~is_error:false)))
  | "list_rooms" ->
      let rooms = Broker.list_rooms broker in
      let content =
        `List
          (List.map room_info_json rooms)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "my_rooms" ->
      (* Always resolve session_id from env — same isolation contract
         as `history`. A subagent that inherits a parent session_id
         env would see the parent's rooms, which is acceptable today
         (goal B — subagent access tokens — is the follow-up slice
         that closes that gap). Argument-level override is ignored. *)
      (match current_session_id () with
       | None ->
           Lwt.return
             (tool_result
                ~content:"my_rooms: no session_id in env (set C2C_MCP_SESSION_ID)"
                ~is_error:true)
       | Some session_id ->
           let rooms = Broker.my_rooms broker ~session_id in
           let content =
             `List
               (List.map room_info_json rooms)
             |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "room_history" ->
      let room_id = string_member "room_id" arguments in
      let limit =
        match Broker.int_opt_member "limit" arguments with
        | Some n -> n
        | None -> 50
      in
      let history = Broker.read_room_history broker ~room_id ~limit in
      let content =
        `List
          (List.map
             (fun (m : room_message) ->
               `Assoc
                 [ ("ts", `Float m.rm_ts)
                 ; ("from_alias", `String m.rm_from_alias)
                 ; ("content", `String m.rm_content)
                 ])
             history)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "send_room_invite" ->
      let room_id = string_member "room_id" arguments in
      let invitee_alias = string_member "invitee_alias" arguments in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_room_invite")
       | Some from_alias ->
           (match send_alias_impersonation_check broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "send_room_invite rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot invite as another agent."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                Broker.send_room_invite broker ~room_id ~from_alias ~invitee_alias;
                let content =
                  `Assoc
                    [ ("ok", `Bool true)
                    ; ("room_id", `String room_id)
                    ; ("invitee_alias", `String invitee_alias)
                    ]
                  |> Yojson.Safe.to_string
                in
                Lwt.return (tool_result ~content ~is_error:false)))
  | "set_room_visibility" ->
      let room_id = string_member "room_id" arguments in
      let visibility_str = string_member "visibility" arguments in
      let visibility =
        match visibility_str with
        | "invite_only" -> Invite_only
        | _ -> Public
      in
      (match alias_for_current_session_or_argument broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "set_room_visibility")
       | Some from_alias ->
           (match send_alias_impersonation_check broker from_alias with
            | Some conflict ->
                Lwt.return
                  (tool_result
                     ~content:
                       (Printf.sprintf
                          "set_room_visibility rejected: from_alias '%s' is currently held by \
                           alive session '%s' — you cannot change visibility as another agent."
                          from_alias conflict.session_id)
                     ~is_error:true)
            | None ->
                Broker.set_room_visibility broker ~room_id ~from_alias ~visibility;
                let content =
                  `Assoc
                    [ ("ok", `Bool true)
                    ; ("room_id", `String room_id)
                    ; ("visibility",
                        match visibility with
                        | Public -> `String "public"
                        | Invite_only -> `String "invite_only")
                    ]
                  |> Yojson.Safe.to_string
                in
                Lwt.return (tool_result ~content ~is_error:false)))
  | _ -> Lwt.return (tool_result ~content:("unknown tool: " ^ tool_name) ~is_error:true)

(* Append one structured line to <broker_root>/broker.log for every
   tools/call RPC. Never raises — audit failures must never break the
   RPC path. Content fields are deliberately omitted to avoid leaking
   message content into a shared log file. *)
let log_rpc ~broker_root ~tool_name ~is_error =
  (try
     let path = Filename.concat broker_root "broker.log" in
     let ts = Unix.gettimeofday () in
     let line =
       `Assoc
         [ ("ts", `Float ts)
         ; ("tool", `String tool_name)
         ; ("ok", `Bool (not is_error))
         ]
       |> Yojson.Safe.to_string
     in
     let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o600 path in
     (try
        output_string oc (line ^ "\n");
        close_out oc
      with _ -> close_out_noerr oc)
   with _ -> ())

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
      let is_error =
        (try Yojson.Safe.Util.(result |> member "isError" |> to_bool) with _ -> false)
      in
      log_rpc ~broker_root ~tool_name ~is_error;
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, _ ->
      Lwt.return_some (jsonrpc_error ~id ~code:(-32601) ~message:("Unknown method: " ^ method_))
