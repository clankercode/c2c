type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  }
type message = { from_alias : string; to_alias : string; content : string }
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }

let server_version = "0.6.3"

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

  let join_room t ~room_id ~alias ~session_id =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        let already =
          List.exists
            (fun m -> m.rm_alias = alias && m.rm_session_id = session_id)
            members
        in
        if already then members
        else begin
          let now = Unix.gettimeofday () in
          let member = { rm_alias = alias; rm_session_id = session_id; joined_at = now } in
          let updated = members @ [ member ] in
          save_room_members t ~room_id updated;
          updated
        end)

  let leave_room t ~room_id ~alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    with_room_members_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        let updated = List.filter (fun m -> m.rm_alias <> alias) members in
        save_room_members t ~room_id updated;
        updated)

  let append_room_history t ~room_id ~from_alias ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
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

  let send_room t ~from_alias ~room_id ~content =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    (* Step 1: append to history (under history lock, released before fan-out) *)
    let ts = append_room_history t ~room_id ~from_alias ~content in
    (* Step 2: load current members snapshot *)
    let members =
      with_room_members_lock t ~room_id (fun () ->
          load_room_members t ~room_id)
    in
    (* Step 3: fan out to each member except sender. For each recipient,
       take registry_lock -> inbox_lock (existing lock order) and enqueue
       with to_alias tagged as "<alias>@<room_id>" so the recipient can
       distinguish room messages from direct messages. *)
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
    { sr_delivered_to = List.rev !delivered
    ; sr_skipped = List.rev !skipped
    ; sr_ts = ts
    }

  type room_info =
    { ri_room_id : string
    ; ri_member_count : int
    ; ri_members : string list
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
            { ri_room_id = name
            ; ri_member_count = List.length members
            ; ri_members = List.map (fun m -> m.rm_alias) members
            } :: acc
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
              { ri_room_id = name
              ; ri_member_count = List.length members
              ; ri_members = List.map (fun m -> m.rm_alias) members
              } :: acc
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

let tool_definitions =
  [ tool_definition ~name:"register" ~description:"Register a C2C alias for the current session." ~required:[ "alias" ]
  ; tool_definition ~name:"list" ~description:"List registered C2C peers." ~required:[]
  ; tool_definition ~name:"send" ~description:"Send a C2C message to a registered peer alias. Returns JSON {queued:true, ts:<epoch-seconds>, to_alias:<string>} on success. ts is when the message landed in the recipient's inbox; to_alias confirms the resolved recipient." ~required:[ "from_alias"; "to_alias"; "content" ]
  ; tool_definition ~name:"whoami" ~description:"Resolve the current C2C session registration." ~required:[]
  ; tool_definition ~name:"poll_inbox" ~description:"Drain queued C2C messages for the current session. Returns a JSON array of {from_alias,to_alias,content} objects; call this at the start of each turn and after each send to reliably receive messages regardless of whether the client surfaces notifications/claude/channel." ~required:[]
  ; tool_definition ~name:"peek_inbox" ~description:"Non-draining inbox check for the current session. Returns the same JSON array as `poll_inbox` but leaves the messages in the inbox so a subsequent `poll_inbox` still sees them. Useful for 'any mail?' checks without losing messages on error paths. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation." ~required:[]
  ; tool_definition ~name:"sweep" ~description:"Remove dead registrations (whose parent process has exited) and delete orphan inbox files that belong to no current registration. Any non-empty orphan inbox content is appended to dead-letter.jsonl inside the broker directory before the inbox file is deleted, so cleanup is non-destructive to operator signal. Returns JSON {dropped_regs:[{session_id,alias}], deleted_inboxes:[session_id], preserved_messages: int}." ~required:[]
  ; tool_definition ~name:"send_all" ~description:"Fan out a message to every currently-registered peer except the sender (and any alias in the optional `exclude_aliases` array). Non-live recipients are skipped with reason \"not_alive\" rather than raising, so partial failure does not abort the broadcast. Per-recipient enqueue takes the same per-inbox lock used by `send`. Returns JSON {sent_to:[alias], skipped:[{alias, reason}]}." ~required:[ "from_alias"; "content" ]
  ; tool_definition ~name:"join_room" ~description:"Join a persistent N:N room. Creates the room if it does not exist. Idempotent per (alias, session_id). Room IDs must be alphanumeric + hyphens + underscores. Returns JSON {room_id, members, history} where `history` is the most recent messages from the room's append-only log so a newly-joined member can catch up on context without a separate `room_history` call. Optional `history_limit` (default 20, max 200) controls how many history entries to include; pass 0 to skip history backfill. Accepts `from_alias` as a synonym for `alias` to match the send-side schema; either works." ~required:[ "room_id"; "alias" ]
  ; tool_definition ~name:"leave_room" ~description:"Leave a persistent N:N room. Returns the member list after leave. Accepts `from_alias` as a synonym for `alias` to match the send-side schema; either works." ~required:[ "room_id"; "alias" ]
  ; tool_definition ~name:"send_room" ~description:"Send a message to a persistent N:N room. Appends to room history and fans out to every member's inbox except the sender, with to_alias tagged as '<alias>@<room_id>'. Returns JSON {delivered_to, skipped, ts}." ~required:[ "from_alias"; "room_id"; "content" ]
  ; tool_definition ~name:"list_rooms" ~description:"List all persistent rooms with member counts and member aliases. Returns a JSON array of {room_id, member_count, members}." ~required:[]
  ; tool_definition ~name:"my_rooms" ~description:"List rooms where your current session is a member. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only see your own memberships. Same row shape as list_rooms: JSON array of {room_id, member_count, members}." ~required:[]
  ; tool_definition ~name:"room_history" ~description:"Return the last `limit` (default 50) messages from a room's append-only history. Read-only." ~required:[ "room_id" ]
  ; tool_definition ~name:"history" ~description:"Return your own archived inbox messages, newest first. Every message drained via poll_inbox is archived to a per-session append-only log before the live inbox is cleared, so this tool gives you a durable record of everything you've ever received. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only read your own history. Optional `limit` (default 50). Returns a JSON array of {drained_at, from_alias, to_alias, content} objects." ~required:[]
  ; tool_definition ~name:"tail_log" ~description:"Return the last N lines from the broker RPC audit log (broker.log). Each line is a JSON object {ts, tool, ok}. Useful for verifying that your sends and polls actually reached the broker, without needing to read the file directly. Content fields are not logged — only tool names and success/fail status. Optional `limit` (default 50, max 500). Returns a JSON array of log entries, oldest first." ~required:[]
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
      if trimmed = "" then None else (try Some (int_of_string trimmed) with _ -> None)
  | None -> None

let auto_register_startup ~broker_root =
  match (auto_register_alias (), current_session_id ()) with
  | Some alias, Some session_id ->
      let broker = Broker.create ~root:broker_root in
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let pid_start_time = Broker.capture_pid_start_time pid in
      Broker.register broker ~session_id ~alias ~pid ~pid_start_time
  | _ -> ()

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
      let from_alias = string_member_any [ "from_alias"; "alias" ] arguments in
      let to_alias = string_member "to_alias" arguments in
      let content = string_member "content" arguments in
      Broker.enqueue_message broker ~from_alias ~to_alias ~content;
      let ts = Unix.gettimeofday () in
      let receipt =
        `Assoc
          [ ("queued", `Bool true)
          ; ("ts", `Float ts)
          ; ("to_alias", `String to_alias)
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content:receipt ~is_error:false)
  | "send_all" ->
      let from_alias = string_member_any [ "from_alias"; "alias" ] arguments in
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
  | "join_room" ->
      let room_id = string_member "room_id" arguments in
      let alias = string_member_any [ "alias"; "from_alias" ] arguments in
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
      Lwt.return (tool_result ~content ~is_error:false)
  | "leave_room" ->
      let room_id = string_member "room_id" arguments in
      let alias = string_member_any [ "alias"; "from_alias" ] arguments in
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
      Lwt.return (tool_result ~content ~is_error:false)
  | "send_room" ->
      let from_alias = string_member_any [ "from_alias"; "alias" ] arguments in
      let room_id = string_member "room_id" arguments in
      let content = string_member "content" arguments in
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
      Lwt.return (tool_result ~content:result_json ~is_error:false)
  | "list_rooms" ->
      let rooms = Broker.list_rooms broker in
      let content =
        `List
          (List.map
             (fun (r : Broker.room_info) ->
               `Assoc
                 [ ("room_id", `String r.ri_room_id)
                 ; ("member_count", `Int r.ri_member_count)
                 ; ("members",
                    `List (List.map (fun a -> `String a) r.ri_members))
                 ])
             rooms)
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
               (List.map
                  (fun (r : Broker.room_info) ->
                    `Assoc
                      [ ("room_id", `String r.ri_room_id)
                      ; ("member_count", `Int r.ri_member_count)
                      ; ("members",
                         `List (List.map (fun a -> `String a) r.ri_members))
                      ])
                  rooms)
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
