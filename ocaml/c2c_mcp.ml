type compacting = { started_at : float; reason : string option }
type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  ; registered_at : float option
  ; canonical_alias : string option
  (** Fully-qualified form: "<alias>#<repo>@<host>". None for registrations
      created before this field was added (Phase 0 compatibility). *)
  ; dnd : bool
  (** Do-Not-Disturb: when true, channel-push delivery is suppressed.
      poll_inbox is never gated — the agent can always explicitly drain. *)
  ; dnd_since : float option  (** When DND was last enabled. *)
  ; dnd_until : float option  (** Auto-expire epoch (None = manual off only). *)
  ; client_type : string option
   (** "human" exempts from provisional sweep; None = agent (default). *)
   ; plugin_version : string option
   (** Version string of the c2c plugin/hook running this session.
       Used to detect stale plugins that may have known bugs. *)
    ; confirmed_at : float option
   (** Epoch of first poll_inbox call. None = session registered but never
       drained — still "provisional". Provisional + pid=None sessions are
       eligible for sweep after C2C_PROVISIONAL_SWEEP_TIMEOUT seconds. *)
   ; enc_pubkey : string option
   (** X25519 public key (base64url, 32 bytes) for E2E encryption.
       Published in the registry so recipients can encrypt DMs.
       The matching secret lives in ~/.c2c/keys/<session_id>.x25519 mode 0600.
       Known v1 limitation (M1 threat model): mode 0600 does not protect against
       other processes running as the same Unix user (including child agents).
       OS keyring integration deferred to M3. *)
   ; compacting : compacting option
  (** Set when the agent is actively compacting/summarizing. Send-side
      checks this and returns a warning; message is still queued. *)
  ; last_activity_ts : float option
  (** Epoch of the session's most recent broker interaction (poll_inbox,
      send, register). None = session predates this field (Phase 0 compat).
      Updated by [touch_session]. *)
  ; role : string option
  (** Sender role for envelope attribution (coordinator, reviewer, agent, user).
      Set explicitly via register tool. None = no role. *)
  ; compaction_count : int
  (** Cumulative count of compacting→idle transitions for this session.
      Incremented by clear_compacting and clear_stale_compacting.
      Defaults to 0 for sessions predating this field. *)
  }
type message = { from_alias : string; to_alias : string; content : string; deferrable : bool; reply_via : string option; enc_status : string option; ts : float }
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }
type room_visibility = Public | Invite_only
type room_meta = { visibility : room_visibility; invited_members : string list }

(** Pending reply tracking for alias-hijack mitigation (M2/M4).
    Ephemeral entries with TTL — entries older than TTL are ignored on access. *)
type pending_kind = Permission | Question
type pending_permission =
  { perm_id : string
  ; kind : pending_kind
  ; requester_session_id : string
  ; requester_alias : string
  ; supervisors : string list
  ; created_at : float
  ; expires_at : float
  }

let pending_kind_to_string = function Permission -> "permission" | Question -> "question"
let pending_kind_of_string = function "question" -> Question | _ -> Permission

let pending_permission_to_json p =
  `Assoc
    [ ("perm_id", `String p.perm_id)
    ; ("kind", `String (pending_kind_to_string p.kind))
    ; ("requester_session_id", `String p.requester_session_id)
    ; ("requester_alias", `String p.requester_alias)
    ; ("supervisors", `List (List.map (fun s -> `String s) p.supervisors))
    ; ("created_at", `Float p.created_at)
    ; ("expires_at", `Float p.expires_at)
    ]

let pending_permission_of_json json =
  let open Yojson.Safe.Util in
  { perm_id = json |> member "perm_id" |> to_string
  ; kind = json |> member "kind" |> to_string |> pending_kind_of_string
  ; requester_session_id = json |> member "requester_session_id" |> to_string
  ; requester_alias = json |> member "requester_alias" |> to_string
  ; supervisors = json |> member "supervisors" |> to_list |> List.map Yojson.Safe.Util.to_string
  ; created_at = json |> member "created_at" |> to_float
  ; expires_at = json |> member "expires_at" |> to_float
  }

let server_version = Version.version

let server_git_hash =
  match Sys.getenv_opt "RAILWAY_GIT_COMMIT_SHA" with
  | Some sha when String.length sha >= 7 -> String.sub sha 0 7
  | _ ->
    (try
      let ic = Unix.open_process_in "git rev-parse --short HEAD 2>/dev/null" in
      let line = input_line ic in
      ignore (Unix.close_process_in ic);
      String.trim line
    with _ -> "unknown")

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
  ; "dnd"
  ; "deferrable"
  ; "provisional_registration"
  ; "client_type"
  ]
  @ if Build_flags.mcp_debug_tool_enabled then [ "mcp_debug_tool" ] else []

let server_info =
  `Assoc
    [ ("name", `String "c2c")
    ; ("version", `String server_version)
    ; ("git_hash", `String server_git_hash)
    ; ("features", `List (List.map (fun f -> `String f) server_features))
    ]

let supported_protocol_version = "2024-11-05"
let capabilities =
  `Assoc
    [ ("tools", `Assoc [])
    ; ("prompts", `Assoc [])
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

let float_prop name description =
  (name, `Assoc [("type", `String "number"); ("description", `String description)])

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

module Relay = Relay

module Broker = struct
  type t = { root : string }

  let registry_path t = Filename.concat t.root "registry.json"
  let inbox_path t ~session_id = Filename.concat t.root (session_id ^ ".inbox.json")

  let ensure_root t =
    let rec mkdir_p d =
      if d = "" || d = "/" || d = "." then ()
      else if Sys.file_exists d then ()
      else begin
        mkdir_p (Filename.dirname d);
        try Unix.mkdir d 0o755
        with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      end
    in
    mkdir_p t.root

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

  let registration_to_json { session_id; alias; pid; pid_start_time; registered_at; canonical_alias; dnd; dnd_since; dnd_until; client_type; plugin_version; confirmed_at; enc_pubkey; compacting; last_activity_ts; role; compaction_count } =
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
    let with_ra =
      match registered_at with
      | Some ts -> with_pst @ [ ("registered_at", `Float ts) ]
      | None -> with_pst
    in
    let with_ca =
      match canonical_alias with
      | Some ca -> with_ra @ [ ("canonical_alias", `String ca) ]
      | None -> with_ra
    in
    (* Only persist DND when enabled — keeps registry compact for normal case. *)
    let with_dnd =
      if dnd then with_ca @ [ ("dnd", `Bool true) ]
      else with_ca
    in
    let with_dnd_since =
      match dnd_since with
      | Some ts when dnd -> with_dnd @ [ ("dnd_since", `Float ts) ]
      | _ -> with_dnd
    in
    let with_dnd_until =
      match dnd_until with
      | Some ts when dnd -> with_dnd_since @ [ ("dnd_until", `Float ts) ]
      | _ -> with_dnd_since
    in
    let with_client_type =
      match client_type with
      | Some ct -> with_dnd_until @ [ ("client_type", `String ct) ]
      | None -> with_dnd_until
    in
    let with_plugin_version =
      match plugin_version with
      | Some pv -> with_client_type @ [ ("plugin_version", `String pv) ]
      | None -> with_client_type
    in
    let with_confirmed =
      match confirmed_at with
      | Some ts -> with_plugin_version @ [ ("confirmed_at", `Float ts) ]
      | None -> with_plugin_version
    in
    let with_enc_pubkey =
      match enc_pubkey with
      | Some pk -> with_confirmed @ [ ("enc_pubkey", `String pk) ]
      | None -> with_confirmed
    in
    let fields =
      match compacting with
      | Some c ->
          let reason_json = match c.reason with Some r -> `String r | None -> `Null in
          with_enc_pubkey @ [ ("compacting", `Assoc [ ("started_at", `Float c.started_at); ("reason", reason_json) ]) ]
      | None -> with_enc_pubkey
    in
    let with_last_activity_ts =
      match last_activity_ts with
      | Some ts -> fields @ [ ("last_activity_ts", `Float ts) ]
      | None -> fields
    in
    let with_role =
      match role with
      | Some r -> with_last_activity_ts @ [ ("role", `String r) ]
      | None -> with_last_activity_ts
    in
    let with_compaction_count =
      if compaction_count > 0 then with_role @ [ ("compaction_count", `Int compaction_count) ]
      else with_role
    in
    `Assoc with_compaction_count

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
    let str_opt name j =
      try match j |> member name with `String s -> Some s | _ -> None
      with _ -> None
    in
    let bool_member_default name j default =
      try match j |> member name with `Bool b -> b | _ -> default
      with _ -> default
    in
    let compacting_of_json j =
      match j |> member "compacting" with
      | `Null -> None
      | `Assoc _ ->
          Some { started_at = j |> member "compacting" |> member "started_at" |> to_float;
                 reason = str_opt "reason" (j |> member "compacting") }
      | _ -> None
    in
    { session_id = json |> member "session_id" |> to_string
    ; alias = json |> member "alias" |> to_string
    ; pid = int_opt_member "pid" json
    ; pid_start_time = int_opt_member "pid_start_time" json
    ; registered_at = float_opt_member "registered_at" json
    ; canonical_alias = str_opt "canonical_alias" json
    ; dnd = bool_member_default "dnd" json false
    ; dnd_since = float_opt_member "dnd_since" json
    ; dnd_until = float_opt_member "dnd_until" json
    ; client_type = str_opt "client_type" json
    ; plugin_version = str_opt "plugin_version" json
    ; confirmed_at = float_opt_member "confirmed_at" json
    ; enc_pubkey = str_opt "enc_pubkey" json
    ; compacting = compacting_of_json json
    ; last_activity_ts = float_opt_member "last_activity_ts" json
    ; role = str_opt "role" json
    ; compaction_count = (match json |> member "compaction_count" with `Int n -> n | _ -> 0)
    }

  let message_to_json { from_alias; to_alias; content; deferrable; reply_via; enc_status; ts } =
    let base =
      [ ("from_alias", `String from_alias)
      ; ("to_alias", `String to_alias)
      ; ("content", `String content)
      ; ("ts", `Float ts)
      ]
    in
    let with_deferrable = if deferrable then base @ [("deferrable", `Bool true)] else base in
    let with_reply_via = match reply_via with None -> with_deferrable | Some rv -> with_deferrable @ [("reply_via", `String rv)] in
    match enc_status with
    | None -> `Assoc with_reply_via
    | Some es -> `Assoc (with_reply_via @ [("enc_status", `String es)])

  let message_of_json json =
    let open Yojson.Safe.Util in
    { from_alias = json |> member "from_alias" |> to_string
    ; to_alias = json |> member "to_alias" |> to_string
    ; content = json |> member "content" |> to_string
    ; deferrable =
        (match json |> member "deferrable" with
         | `Bool b -> b
         | _ -> false)
    ; reply_via =
        (match json |> member "reply_via" with
         | `String s -> Some s
         | _ -> None)
    ; enc_status =
        (match json |> member "enc_status" with
         | `String s -> Some s
         | _ -> None)
    ; ts =
        (match json |> member "ts" with
         | `Float f -> f
         | `Int i -> float_of_int i
         | _ -> 0.0)
    }

  let load_registrations t =
    ensure_root t;
    match read_json_file (registry_path t) ~default:(`List []) with
    | `List items -> List.map registration_of_json items
    | _ -> []

  let save_registrations t regs =
    ensure_root t;
    write_json_file (registry_path t) (`List (List.map registration_to_json regs))

  let pending_permissions_path t = Filename.concat t.root "pending_permissions.json"

  let load_pending_permissions t =
    ensure_root t;
    match read_json_file (pending_permissions_path t) ~default:(`List []) with
    | `List items -> List.map pending_permission_of_json items
    | _ -> []

  let save_pending_permissions t entries =
    ensure_root t;
    write_json_file (pending_permissions_path t)
      (`List (List.map pending_permission_to_json entries))

  (** Remove expired entries on every access (lazy eviction). Callers get a clean list. *)
  let get_active_pending_permissions t =
    let now = Unix.gettimeofday () in
    List.filter (fun p -> p.expires_at > now) (load_pending_permissions t)

  (** Persist a new pending permission entry. Callers must hold registry lock. *)
  let open_pending_permission t p =
    let entries = get_active_pending_permissions t in
    save_pending_permissions t (p :: entries)

  (** Find a pending permission by perm_id. Returns None if not found or expired. *)
  let find_pending_permission t perm_id =
    let now = Unix.gettimeofday () in
    List.find_opt (fun p -> p.perm_id = perm_id && p.expires_at > now)
      (load_pending_permissions t)

  (** Remove a pending permission by perm_id. No-op if not found. *)
  let remove_pending_permission t perm_id =
    let entries = List.filter (fun p -> p.perm_id <> perm_id)
      (get_active_pending_permissions t) in
    save_pending_permissions t entries

  (** Check if any active pending permission exists for a given alias.
      Used by M4 alias-reuse guard. *)
  let pending_permission_exists_for_alias t alias =
    let now = Unix.gettimeofday () in
    List.exists (fun p -> p.requester_alias = alias && p.expires_at > now)
      (load_pending_permissions t)

  let create ~root = { root }
  let root t = t.root

  let tofu_mutex : (string, Lwt_mutex.t) Hashtbl.t = Hashtbl.create 64

  let get_tofu_mutex alias =
    match Hashtbl.find_opt tofu_mutex alias with
    | Some m -> m
    | None ->
      let m = Lwt_mutex.create () in
      Hashtbl.add tofu_mutex alias m;
      m

  let known_keys_ed25519 : (string, string) Hashtbl.t = Hashtbl.create 64
  let known_keys_x25519 : (string, string) Hashtbl.t = Hashtbl.create 64
  let downgrade_states : (string, Relay_e2e.downgrade_state) Hashtbl.t = Hashtbl.create 64

  let get_pinned_ed25519 alias = Hashtbl.find_opt known_keys_ed25519 alias
  let set_pinned_ed25519 alias pk = Hashtbl.replace known_keys_ed25519 alias pk
  let get_pinned_x25519 alias = Hashtbl.find_opt known_keys_x25519 alias
  let set_pinned_x25519 alias pk = Hashtbl.replace known_keys_x25519 alias pk
  let get_downgrade_state from_alias =
    match Hashtbl.find_opt downgrade_states from_alias with
    | Some ds -> ds
    | None -> Relay_e2e.make_downgrade_state ()
  let set_downgrade_state from_alias ds = Hashtbl.replace downgrade_states from_alias ds

  let pin_x25519_if_unknown ~alias ~pk =
    let m = get_tofu_mutex alias in
    Lwt_mutex.with_lock m (fun () ->
      match Hashtbl.find_opt known_keys_x25519 alias with
      | Some existing when existing <> pk -> Lwt.return `Mismatch
      | Some _ -> Lwt.return `Already_pinned
      | None ->
        Hashtbl.replace known_keys_x25519 alias pk;
        Lwt.return `New_pin)

  let pin_ed25519_if_unknown ~alias ~pk =
    let m = get_tofu_mutex alias in
    Lwt_mutex.with_lock m (fun () ->
      match Hashtbl.find_opt known_keys_ed25519 alias with
      | Some existing when existing <> pk -> Lwt.return `Mismatch
      | Some _ -> Lwt.return `Already_pinned
      | None ->
        Hashtbl.replace known_keys_ed25519 alias pk;
        Lwt.return `New_pin)

  let tofu_sync_mutex = Mutex.create ()

  let pin_x25519_sync ~alias ~pk =
    Mutex.lock tofu_sync_mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock tofu_sync_mutex) (fun () ->
      match Hashtbl.find_opt known_keys_x25519 alias with
      | Some existing when existing <> pk -> `Mismatch
      | Some _ -> `Already_pinned
      | None ->
        Hashtbl.replace known_keys_x25519 alias pk;
        `New_pin)

  let pin_ed25519_sync ~alias ~pk =
    Mutex.lock tofu_sync_mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock tofu_sync_mutex) (fun () ->
      match Hashtbl.find_opt known_keys_ed25519 alias with
      | Some existing when existing <> pk -> `Mismatch
      | Some _ -> `Already_pinned
      | None ->
        Hashtbl.replace known_keys_ed25519 alias pk;
        `New_pin)

  let load_or_create_ed25519_identity () =
    match Relay_identity.load () with
    | Ok id -> id
    | Error _ ->
      let id = Relay_identity.generate () in
      match Relay_identity.save id with
      | Ok () -> id
      | Error e -> failwith ("relay_identity save: " ^ e)

  let write_allowed_signers_entry t ~alias =
    let keys_dir = Filename.concat t.root "keys" in
    let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
    let signers_path = Filename.concat t.root "allowed_signers" in
    try
      let mkdir_p d =
        let rec aux p =
          if p = "" || p = "/" || p = "." then ()
          else if Sys.file_exists p then ()
          else begin aux (Filename.dirname p); try Unix.mkdir p 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> () end
        in
        aux d
      in
      mkdir_p keys_dir;
      let id = Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias in
      let ssh_priv_path = priv_path ^ ".ssh" in
      let ssh_pub_path = ssh_priv_path ^ ".pub" in
      if not (Sys.file_exists ssh_pub_path) then
        failwith (Printf.sprintf "ssh key not found at %s (run load_or_create_at first)" ssh_pub_path);
      let ic = open_in ssh_pub_path in
      let len = in_channel_length ic in
      let ssh_pub_content = really_input_string ic len in
      close_in ic;
      let b64_key =
        match (let parts = List.filter ((<>) "") (String.split_on_char ' ' ssh_pub_content) in List.nth_opt parts 1) with
        | Some b64 -> String.trim b64
        | None -> failwith (Printf.sprintf "could not parse ssh pub key from %s" ssh_pub_path)
      in
      let now = Unix.gmtime (Unix.time ()) in
      let date_str =
        Printf.sprintf "%04d-%02d-%02d"
          (now.Unix.tm_year + 1900) (now.Unix.tm_mon + 1) now.Unix.tm_mday
      in
      let line = Printf.sprintf "%s@c2c.im ssh-ed25519 %s # added %s\n"
        alias b64_key date_str
      in
      let oc = open_out_gen [Open_append; Open_creat] 0o644 signers_path in
      Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
        output_string oc line)
    with e ->
      Printf.eprintf "[allowed_signers] warning: could not write entry for %s: %s\n%!" alias (Printexc.to_string e)

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
           | None -> Unknown
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

  (* A provisional registration has no confirmed PID-based liveness yet AND
     has never drained its inbox (confirmed_at = None). Human sessions are
     exempt. Provisional sessions with no PID are eligible for sweep after
     C2C_PROVISIONAL_SWEEP_TIMEOUT seconds (default 1800). *)
  let is_provisional reg =
    match reg.client_type with
    | Some "human" -> false
    | _ ->
        reg.pid = None && reg.confirmed_at = None

  (* True for any non-human session that has never called poll_inbox (confirmed_at=None).
     Used to gate noisy social broadcasts (peer_register, room-join) so they fire
     only when a session is confirmed alive, not speculatively on startup.
     Broader than is_provisional: includes sessions that have a PID but haven't
     polled yet (e.g. opencode started via c2c start but not yet interactive). *)
  let is_unconfirmed reg =
    match reg.client_type with
    | Some "human" -> false
    | _ -> reg.confirmed_at = None

  let provisional_sweep_timeout () =
    match Sys.getenv_opt "C2C_PROVISIONAL_SWEEP_TIMEOUT" with
    | Some v -> (try float_of_string v with _ -> 1800.0)
    | None -> 1800.0

  let is_provisional_expired reg =
    if not (is_provisional reg) then false
    else
      match reg.registered_at with
      | None -> false  (* legacy rows predate registered_at — never provisional-expired *)
      | Some ra ->
          Unix.gettimeofday () -. ra > provisional_sweep_timeout ()

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

  let reserved_system_aliases = ["c2c"; "c2c-system"]

  (* --- canonical alias helpers ----------------------------------------------- *)

  (* Derive repo slug from broker_root path:
     broker_root = .../repo/.git/c2c/mcp → "repo" *)
  let repo_slug_of_broker_root broker_root =
    try
      let git_dir = Filename.dirname (Filename.dirname broker_root) in
      let repo_root = Filename.dirname git_dir in
      let slug = Filename.basename repo_root in
      if slug = "" || slug = "." || slug = "/" then "unknown" else slug
    with _ -> "unknown"

  let short_hostname () =
    try
      let h = Unix.gethostname () in
      match String.split_on_char '.' h with
      | s :: _ when s <> "" -> s
      | _ -> h
    with _ -> "unknown"

  let compute_canonical_alias ~alias ~broker_root =
    Printf.sprintf "%s#%s@%s" alias
      (repo_slug_of_broker_root broker_root)
      (short_hostname ())

  (* Primes for alias disambiguation *)
  let small_primes = [| 2; 3; 5; 7; 11; 13; 17; 19; 23; 29; 31; 37; 41; 43; 47 |]

  let next_prime_after n =
    let is_prime p =
      if p < 2 then false
      else
        let rec check d = d * d > p || (p mod d <> 0 && check (d + 1)) in
        check 2
    in
    let rec find p = if is_prime p then p else find (p + 1) in
    find (n + 1)

  (** Check whether *session_id* is currently in DND mode (considering auto-expire). *)
  let is_dnd t ~session_id =
    let now = Unix.gettimeofday () in
    match List.find_opt (fun r -> r.session_id = session_id) (list_registrations t) with
    | None -> false
    | Some r ->
        if not r.dnd then false
        else begin
          (* Auto-expire check: if dnd_until is set and has passed, DND is cleared. *)
          match r.dnd_until with
          | Some until when now >= until -> false
          | _ -> true
        end

  (** Set or clear DND for *session_id*. Returns the new dnd state, or None if
      the session is not registered. When [until] is given, DND auto-expires at
      that epoch. [until = None] means no auto-expire (manual off only). *)
  let set_dnd t ~session_id ~dnd ?until () =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> None
      | Some existing ->
          let now = Unix.gettimeofday () in
          let updated = { existing with
            dnd
          ; dnd_since = (if dnd then Some now else None)
          ; dnd_until  = (if dnd then until else None)
          } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          Some dnd)

  let compacting_stale_after = 300.0

  let is_compacting t ~session_id =
    let now = Unix.gettimeofday () in
    match List.find_opt (fun r -> r.session_id = session_id) (list_registrations t) with
    | None -> None
    | Some r ->
        match r.compacting with
        | None -> None
        | Some c ->
            if now -. c.started_at > compacting_stale_after then None
            else Some c

  let set_compacting t ~session_id ?reason () =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> None
      | Some existing ->
          let now = Unix.gettimeofday () in
          let updated = { existing with compacting = Some { started_at = now; reason } } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          Some { started_at = now; reason })

  let clear_compacting t ~session_id =
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | None -> false
      | Some existing ->
          let updated = { existing with compacting = None
                        ; compaction_count = existing.compaction_count + 1 } in
          let new_regs =
            List.map (fun r -> if r.session_id = session_id then updated else r) regs
          in
          save_registrations t new_regs;
          true)

  let clear_stale_compacting t =
    let now = Unix.gettimeofday () in
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let to_clear, to_keep =
        List.partition (fun r ->
          match r.compacting with
          | None -> false
          | Some c -> now -. c.started_at > compacting_stale_after) regs
      in
      if to_clear = [] then 0
      else begin
        let cleared = List.map (fun r -> { r with compacting = None
                                         ; compaction_count = r.compaction_count + 1 }) to_clear in
        save_registrations t (cleared @ to_keep);
        List.length cleared
      end)

  (* Suggest a free alias by appending the next prime suffix.
     Runs under the registry lock (regs is already loaded).
     Returns Some candidate on success, None when all max_tries primes are taken
     (ALIAS_COLLISION_EXHAUSTED). max_tries defaults to 5 (primes 2,3,5,7,11). *)
  let suggest_alias_prime ?(max_tries = 5) regs ~base_alias =
    let alive = List.filter_map (fun reg ->
      if registration_is_alive reg then Some reg.alias else None) regs in
    if not (List.mem base_alias alive) then Some base_alias
    else begin
      let n = Array.length small_primes in
      let rec try_idx i =
        if i >= max_tries then None
        else begin
          let p =
            if i < n then small_primes.(i)
            else next_prime_after small_primes.(n - 1)
          in
          let candidate = Printf.sprintf "%s-%d" base_alias p in
          if not (List.mem candidate alive) then Some candidate
          else try_idx (i + 1)
        end
      in
      try_idx 0
    end

  (* Public wrapper: reads registry and suggests disambiguated alias.
     Returns Some alias on success, None when ALIAS_COLLISION_EXHAUSTED. *)
  let suggest_alias_for_alias t ~alias =
    with_registry_lock t (fun () ->
      suggest_alias_prime (load_registrations t) ~base_alias:alias)

  let register t ~session_id ~alias ~pid ~pid_start_time ?(client_type = None) ?(plugin_version = None) ?(enc_pubkey = None) ?(role = None) () =
    if List.mem alias reserved_system_aliases then
      invalid_arg (Printf.sprintf
        "register rejected: '%s' is a reserved system alias" alias);
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
        (* Look up old entry to preserve DND state + confirmed_at + client_type + plugin_version + compacting + role
           across re-registration. *)
        let old_state =
          match List.find_opt (fun reg -> reg.session_id = session_id) rest with
          | Some r -> (r.dnd, r.dnd_since, r.dnd_until, r.confirmed_at, r.client_type, r.plugin_version, r.compacting, r.enc_pubkey, r.last_activity_ts, r.role, r.compaction_count)
          | None -> (false, None, None, None, client_type, None, None, enc_pubkey, None, role, 0)
        in
        let new_reg =
          let (dnd, dnd_since, dnd_until, old_confirmed_at, old_client_type, old_plugin_version, old_compacting, old_enc_pubkey, old_last_activity_ts, old_role, old_compaction_count) = old_state in
          let effective_client_type = match client_type with
            | Some _ -> client_type
            | None -> old_client_type
          in
          let effective_plugin_version = match plugin_version with
            | Some _ -> plugin_version
            | None -> old_plugin_version
          in
          let effective_enc_pubkey = match enc_pubkey with
            | Some _ -> enc_pubkey
            | None -> old_enc_pubkey
          in
          let effective_role = match role with
            | Some _ -> role
            | None -> old_role
          in
          { session_id; alias; pid; pid_start_time
          ; registered_at = Some (Unix.gettimeofday ())
          ; canonical_alias = Some (compute_canonical_alias ~alias ~broker_root:(root t))
          ; dnd; dnd_since; dnd_until
          ; client_type = effective_client_type
          ; plugin_version = effective_plugin_version
          ; confirmed_at = old_confirmed_at
          ; enc_pubkey = effective_enc_pubkey
          ; compacting = old_compacting
          ; last_activity_ts = old_last_activity_ts
          ; role = effective_role
          ; compaction_count = old_compaction_count }
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

  (** True if [alias] contains '@' — indicating a remote alias that cannot be
      resolved via the local registry and must be sent via the relay outbox. *)
  let is_remote_alias alias =
    String.exists (fun c -> c = '@') alias

  let enqueue_message t ~from_alias ~to_alias ~content ?(deferrable = false) () =
    (* Reject messages claiming a reserved system from_alias — prevents spoofing. *)
    if List.mem from_alias reserved_system_aliases then
      invalid_arg (Printf.sprintf
        "send rejected: from_alias '%s' is a reserved system alias" from_alias)
    else if is_remote_alias to_alias then
      (* Remote alias: append to relay outbox for async forwarding by sync loop. *)
      C2c_relay_connector.append_outbox_entry t.root ~from_alias ~to_alias ~content ()
    else
    with_registry_lock t (fun () ->
        match resolve_live_session_id_by_alias t to_alias with
        | Unknown_alias -> invalid_arg ("unknown alias: " ^ to_alias)
        | All_recipients_dead ->
            invalid_arg ("recipient is not alive: " ^ to_alias)
        | Resolved session_id ->
            with_inbox_lock t ~session_id (fun () ->
                let current = load_inbox t ~session_id in
                let next =
                  current @ [ { from_alias; to_alias; content; deferrable; reply_via = None; enc_status = None; ts = Unix.gettimeofday () } ]
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
                          @ [ { from_alias; to_alias = reg.alias; content; deferrable = false; reply_via = None; enc_status = None; ts = Unix.gettimeofday () } ]
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
                  (fun ({ from_alias; to_alias; content; deferrable } : message) ->
                    let base =
                      [ ("drained_at", `Float ts)
                      ; ("session_id", `String session_id)
                      ; ("from_alias", `String from_alias)
                      ; ("to_alias", `String to_alias)
                      ; ("content", `String content)
                      ]
                    in
                    let record = `Assoc
                      (if deferrable then base @ [("deferrable", `Bool true)] else base)
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

  (* Like drain_inbox but only drains non-deferrable messages.  Deferrable
     messages stay in the inbox for the next explicit poll or idle-flush.
     Used by push paths (channel notification watcher, PostToolUse hook) to
     suppress low-priority messages that the sender marked as non-urgent. *)
  let drain_inbox_push t ~session_id =
    with_inbox_lock t ~session_id (fun () ->
        let messages = load_inbox t ~session_id in
        let to_push = List.filter (fun m -> not m.deferrable) messages in
        let to_keep = List.filter (fun m -> m.deferrable) messages in
        (match to_push with
         | [] -> ()
         | _ ->
             append_archive t ~session_id ~messages:to_push;
             save_inbox t ~session_id to_keep);
        to_push)

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
        (* Dead: PID-based liveness check failed OR provisional registration
           that has never been confirmed and has timed out. *)
        let alive, dead =
          List.partition
            (fun reg -> registration_is_alive reg && not (is_provisional_expired reg))
            regs
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

  (* Read orphan inbox messages for a session without deleting.
     Returns [] when the orphan inbox does not exist or is empty.
     The orphan inbox is the session's inbox file — it is an "orphan" when
     the session has no live registration (e.g. between c2c restart's old
     outer-loop exit and new outer-loop registration). *)
  let read_orphan_inbox_messages t ~session_id =
    let path = inbox_path t ~session_id in
    let exists =
      (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false)
    in
    if not exists then []
    else with_inbox_lock t ~session_id (fun () -> load_inbox t ~session_id)

  (* Atomically read and delete the orphan inbox for a session.
     Used by cmd_restart to capture orphan messages: holds the inbox lock
     across read+delete so a concurrent enqueue cannot race between them. *)
  let read_and_delete_orphan_inbox t ~session_id =
    let path = inbox_path t ~session_id in
    let exists =
      (try ignore (Unix.stat path); true with Unix.Unix_error _ -> false)
    in
    if not exists then []
    else
      with_inbox_lock t ~session_id (fun () ->
        let msgs = load_inbox t ~session_id in
        ignore (try_unlink path);
        msgs)

  (* Capture orphan inbox messages for restart: atomically read the orphan inbox,
     write a pending replay file, and delete the orphan — all under the inbox
     lock.  The pending file is written BEFORE the inbox is deleted, so a write
     failure leaves the orphan intact (not partially-captured).  Holds the
     inbox lock across all three steps (read, write, delete) to prevent any
     concurrent enqueue from racing.
     Returns the number of messages captured, or 0 if no orphan existed. *)
  let capture_orphan_for_restart t ~session_id =
    let inbox_path = inbox_path t ~session_id in
    let pending_path =
      Filename.concat t.root ("pending-orphan-replay." ^ session_id ^ ".json")
    in
    let orphan_exists =
      (try ignore (Unix.stat inbox_path); true with Unix.Unix_error _ -> false)
    in
    if not orphan_exists then 0
    else
      with_inbox_lock t ~session_id (fun () ->
        let msgs = load_inbox t ~session_id in
        if msgs = [] then (
          (* Empty orphan — delete it so it doesn't persist across restarts *)
          ignore (try_unlink inbox_path);
          0
        ) else (
          (* Write pending replay file BEFORE deleting the orphan.
             Atomic write: write to tmp, fsync, rename. *)
          let tmp = pending_path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
          let oc = open_out_gen
            [Open_wronly; Open_creat; Open_trunc; Open_text] 0o600 tmp
          in
           (try
             Fun.protect
               ~finally:(fun () -> try close_out oc with _ -> ())
               (fun () -> Yojson.Safe.to_channel oc (`List (List.map (fun m ->
                 `Assoc [
                   ("from_alias", `String m.from_alias);
                   ("to_alias", `String m.to_alias);
                   ("content", `String m.content);
                   ("deferrable", `Bool m.deferrable);
                   ("reply_via", match m.reply_via with None -> `Null | Some s -> `String s);
                   ("enc_status", match m.enc_status with None -> `Null | Some s -> `String s);
                 ]) msgs)))
            with e ->
              ignore (try_unlink tmp);
              raise e);
          (try Unix.rename tmp pending_path
           with e ->
             ignore (try_unlink tmp);
             raise e);
          ignore (try_unlink inbox_path);
          List.length msgs
        ))

  (* Replay captured orphan messages into the new session's inbox.
     Called in the MCP server after auto_register_startup completes, so
     messages queued during the restart gap (between old outer-loop exit and
     new registration) are delivered to the new session.
     The pending replay file is at broker_root/pending-orphan-replay.<session_id>.json. *)
  let replay_pending_orphan_inbox t ~session_id =
    let pending_path =
      Filename.concat t.root ("pending-orphan-replay." ^ session_id ^ ".json")
    in
    if not (Sys.file_exists pending_path) then 0
    else
      let pending_json =
        try Yojson.Safe.from_file pending_path with _ -> `List []
      in
      let msgs =
        match pending_json with
        | `List items ->
            List.map (fun json ->
              let open Yojson.Safe.Util in
              { from_alias = json |> member "from_alias" |> to_string
              ; to_alias = json |> member "to_alias" |> to_string
              ; content = json |> member "content" |> to_string
              ; deferrable =
                  (match json |> member "deferrable" with `Bool b -> b | _ -> false)
              ; reply_via =
                  (match json |> member "reply_via" with `String s -> Some s | _ -> None)
              ; enc_status =
                  (match json |> member "enc_status" with `String s -> Some s | _ -> None)
              ; ts =
                  (match json |> member "ts" with
                   | `Float f -> f | `Int i -> float_of_int i | _ -> 0.0)
              }) items
        | _ -> []
      in
      if msgs = [] then begin
        (try Unix.unlink pending_path with _ -> ());
        0
      end else begin
        (* Hold the inbox lock across read+save so a concurrent enqueue
           during MCP startup cannot overwrite our appended messages. *)
        with_inbox_lock t ~session_id (fun () ->
          let current = read_inbox t ~session_id in
          save_inbox t ~session_id (current @ msgs));
        (try Unix.unlink pending_path with _ -> ());
        List.length msgs
      end

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
  let room_leave_content ~alias ~room_id = alias ^ " left room " ^ room_id

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
          let tagged_to = m.rm_alias ^ "#" ^ room_id in
          try
            with_registry_lock t (fun () ->
                match resolve_live_session_id_by_alias t m.rm_alias with
                | Resolved session_id ->
                    with_inbox_lock t ~session_id (fun () ->
                        let current = load_inbox t ~session_id in
                        let next =
                          current @ [ { from_alias; to_alias = tagged_to; content; deferrable = false; reply_via = None; enc_status = None; ts = Unix.gettimeofday () } ]
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

  let broadcast_room_leave t ~room_id ~alias =
    let content = room_leave_content ~alias ~room_id in
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
    let unconfirmed =
      let regs = load_registrations t in
      match List.find_opt (fun r -> r.session_id = session_id) regs with
      | Some reg -> is_unconfirmed reg
      | None -> false
    in
    if should_broadcast && not unconfirmed then broadcast_room_join t ~room_id ~alias;
    updated

  let leave_room t ~room_id ~alias =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let should_broadcast, updated =
      with_room_members_lock t ~room_id (fun () ->
          let members = load_room_members t ~room_id in
          let updated = List.filter (fun m -> m.rm_alias <> alias) members in
          save_room_members t ~room_id updated;
          (updated <> members, updated))
    in
    if should_broadcast then broadcast_room_leave t ~room_id ~alias;
    updated

  (* Delete a room entirely. Fails if the room has any members. *)
  let delete_room t ~room_id =
    if not (valid_room_id room_id) then
      invalid_arg ("invalid room_id: " ^ room_id);
    let dir = room_dir t ~room_id in
    if not (Sys.file_exists dir) then
      invalid_arg ("room does not exist: " ^ room_id);
    (* Hold both locks while checking members and deleting the directory. *)
    with_room_members_lock t ~room_id (fun () ->
      with_room_history_lock t ~room_id (fun () ->
        let members = load_room_members t ~room_id in
        if members <> [] then
          invalid_arg ("cannot delete room with members: " ^ room_id);
        (* Delete all files in the room directory, then the directory itself. *)
        let files = Sys.readdir dir in
        Array.iter
          (fun f ->
            try Unix.unlink (Filename.concat dir f) with Unix.Unix_error _ -> ())
          files;
        try Unix.rmdir dir with Unix.Unix_error _ -> ()))

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
      (* Use tristate liveness: treat Unknown as Dead for pidless rows (pid=None),
         since they cannot be verified alive and accumulate dead fan-out messages.
         However, Unknown rows with a set PID (pid_start_time missing but process
         may exist) are treated conservatively — do NOT evict, since the process
         might still be alive. registration_is_alive collapses Unknown→Alive for
         backward-compat with sweep/enqueue delivery. *)
      let dead_regs =
        regs
        |> List.filter (fun r ->
               match registration_liveness_state r with
               | Alive -> false
               | Dead -> true
               | Unknown -> Option.is_none r.pid)
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

  let read_room_history t ~room_id ~limit ?(since = 0.0) () =
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
          (* Filter by timestamp before applying limit *)
          let filtered =
            if since <= 0.0 then all
            else List.filter (fun line ->
              try
                let json = Yojson.Safe.from_string line in
                let ts = Yojson.Safe.Util.(json |> member "ts" |> to_number) in
                ts >= since
              with _ -> true
            ) all
          in
          let n = List.length filtered in
          let to_take = if limit <= 0 then n else min limit n in
          let start = n - to_take in
          let taken =
            List.filteri (fun i _ -> i >= start) filtered
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
    let recent = read_room_history t ~room_id ~limit:20 () in
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
       with to_alias tagged as "<alias>#<room_id>" so the recipient can
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

  (* Promote an unconfirmed registration to confirmed on first poll_inbox call.
     If the session was previously unconfirmed (confirmed_at=None, non-human),
     emits the deferred peer_register broadcast and any room-join broadcasts that
     were suppressed at register/join time. No-op for already-confirmed sessions.
     Defined after my_rooms, send_room, broadcast_room_join to avoid forward refs. *)
  let confirm_registration t ~session_id =
    let was_unconfirmed = ref false in
    let promo_alias = ref "" in
    with_registry_lock t (fun () ->
        let regs = load_registrations t in
        let changed = ref false in
        let regs' =
          List.map
            (fun reg ->
              if reg.session_id = session_id && reg.confirmed_at = None then begin
                changed := true;
                if is_unconfirmed reg then begin
                  was_unconfirmed := true;
                  promo_alias := reg.alias
                end;
                { reg with confirmed_at = Some (Unix.gettimeofday ()) }
              end else
                reg)
            regs
        in
        if !changed then save_registrations t regs');
    if !was_unconfirmed then begin
      let alias = !promo_alias in
      let social_rooms =
        let auto_rooms =
          match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
          | Some v ->
              String.split_on_char ',' v
              |> List.map String.trim
              |> List.filter (fun s -> s <> "" && valid_room_id s)
          | None -> []
        in
        List.sort_uniq String.compare ("swarm-lounge" :: auto_rooms)
      in
      let peer_reg_content =
        Printf.sprintf
          "%s registered {\"type\":\"peer_register\",\"alias\":\"%s\"}"
          alias alias
      in
      List.iter
        (fun room_id ->
          try ignore (send_room t ~from_alias:room_system_alias ~room_id ~content:peer_reg_content)
          with _ -> ())
        social_rooms;
      let joined = my_rooms t ~session_id in
      List.iter
        (fun ri ->
          try broadcast_room_join t ~room_id:ri.ri_room_id ~alias
          with _ -> ())
        joined
    end

  let touch_session t ~session_id =
    let now = Unix.gettimeofday () in
    with_registry_lock t (fun () ->
      let regs = load_registrations t in
      let changed = ref false in
      let regs' =
        List.map
          (fun reg ->
            if reg.session_id = session_id then begin
              match reg.last_activity_ts with
              | Some ts when ts >= now -> reg
              | _ ->
                changed := true;
                { reg with last_activity_ts = Some now }
            end else reg)
          regs
      in
      if !changed then save_registrations t regs')
end

let channel_notification ?(role : string option = None) ({ from_alias; to_alias; content; deferrable = _ } : message) =
  let meta =
    let base = [ ("from_alias", `String from_alias); ("to_alias", `String to_alias) ] in
    match role with
    | Some r -> base @ [ ("role", `String r) ]
    | None   -> base
  in
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("method", `String "notifications/claude/channel")
    ; ( "params",
        `Assoc
          [ ("content", `String content)
          ; ("meta", `Assoc meta)
          ] )
    ]

let decrypt_message_for_push (msg : message) ~session_id =
  let our_x25519 = match Relay_enc.load_or_generate ~session_id () with Ok k -> Some k | Error _ -> None in
  let our_ed25519 = Some (Broker.load_or_create_ed25519_identity ()) in
  let { from_alias; to_alias; content; deferrable; reply_via; enc_status = _ } = msg in
  let decrypted_content =
    match Yojson.Safe.from_string content with
    | exception _ -> content
    | env_json ->
      match Relay_e2e.envelope_of_json env_json with
      | exception _ -> content
      | env ->
        let ds = Broker.get_downgrade_state env.from_ in
        let (status, ds) = Relay_e2e.decide_enc_status ds env in
        Broker.set_downgrade_state env.from_ ds;
        match env.enc with
        | "plain" ->
          (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
           | Some r -> r.ciphertext
           | None -> content)
        | "box-x25519-v1" ->
          (match our_x25519, our_ed25519 with
           | Some x25519, Some _ed25519 ->
             (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
              | None -> content
              | Some recipient ->
                (match recipient.nonce with
                 | None -> content
                 | Some nonce_b64 ->
                   let sender_x25519_pk = env.from_x25519 in
                   (match Relay_e2e.decrypt_for_me
                     ~ct_b64:recipient.ciphertext
                     ~nonce_b64
                     ~sender_pk_b64:(match sender_x25519_pk with Some pk -> pk | None -> "")
                     ~our_sk_seed:x25519.private_key_seed with
                    | None ->
                      (match sender_x25519_pk with
                       | Some pk ->
                         let pinned = Broker.get_pinned_x25519 env.from_ in
                         if pinned <> None && pinned <> Some pk then content
                         else content
                       | None -> content)
                    | Some pt ->
                      let sender_ed25519_pk_opt = Broker.get_pinned_ed25519 env.from_ in
                      (match sender_ed25519_pk_opt with
                       | None -> content
                       | Some pk ->
                         let sig_ok = Relay_e2e.verify_envelope_sig ~pk env in
                         if not sig_ok then content
                         else (
                           (match sender_x25519_pk with
                            | Some pk -> Broker.pin_x25519_sync ~alias:env.from_ ~pk |> ignore
                            | None -> ());
                           pt))))
           | _ -> content)
        | _ -> content)
  in
  { msg with content = decrypted_content }

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

let debug_tool_definition =
  tool_definition ~name:"debug"
    ~description:"Dev-build-only debug surface for controlled broker diagnostics. `action` selects the operation; unknown actions are rejected. `send_msg_to_self` enqueues a JSON-wrapped self-message; `send_raw_to_self` enqueues a self-message whose content is the raw `payload` string (skips the c2c_debug JSON wrapper, body goes verbatim through the channel-notification path); `get_env` lists C2C_*-prefixed env vars."
    ~required:["action"]
    ~properties:
      [ prop "action" "Debug action name (send_msg_to_self | send_raw_to_self | get_env)."
      ; ("payload", `Assoc [ ("type", `String "object"); ("description", `String "Optional arbitrary JSON payload (object/string/etc.) for the debug action. For send_raw_to_self this MUST be a string and is delivered verbatim.") ])
      ]

let base_tool_definitions =
  [ tool_definition ~name:"register"
      ~description:"Register a C2C alias for the current session. `alias` is optional: if omitted the server falls back to the C2C_MCP_AUTO_REGISTER_ALIAS environment variable. Calling register with no arguments is a safe way to refresh your registration (e.g. after a process restart that changed your PID)."
      ~required:[]
      ~properties:
        [ prop "alias" "New alias to register for this session. Pass a different alias to rename without changing env vars."
        ; prop "session_id" "Optional session id override; defaults to the current MCP session."
        ; prop "role" "Optional sender role for envelope attribution (coordinator, reviewer, agent, user)."
        ]
  ; tool_definition ~name:"list"
      ~description:"List registered C2C peers."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"send"
      ~description:"Send a C2C message to a registered peer alias. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback for non-session callers. Optional `deferrable:true` marks the message as low-priority: push paths (channel notification, PostToolUse hook) skip it — recipient reads it on next explicit poll_inbox or idle flush. Returns JSON {queued:true, ts:<epoch-seconds>, from_alias:<string>, to_alias:<string>} on success."
      ~required:["to_alias"; "content"]
      ~properties:[ prop "to_alias" "Target peer alias."; prop "from_alias" "Legacy fallback sender alias (deprecated)."; prop "content" "Message body."; prop "deferrable" "Optional bool. When true, marks the message as low-priority — push delivery is suppressed; recipient reads it on next poll_inbox or idle flush." ]
  ; tool_definition ~name:"whoami"
      ~description:"Resolve the current C2C session registration."
      ~required:[]
      ~properties:
        [ prop "session_id" "Optional session id override; defaults to the current MCP session." ]
  ; tool_definition ~name:"poll_inbox"
      ~description:"Drain queued C2C messages for the current session. Returns a JSON array of {from_alias,to_alias,content} objects; call this at the start of each turn and after each send to reliably receive messages regardless of whether the client surfaces notifications/claude/channel. The session_id argument (if provided) must match the caller's MCP session — cross-session drain attempts are rejected."
      ~required:[]
      ~properties:
        [ prop "session_id" "Must match caller's MCP session (C2C_MCP_SESSION_ID); rejected if mismatched." ]
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
  ; tool_definition ~name:"delete_room"
      ~description:"Delete a room entirely. Only succeeds when the room has zero members. Returns JSON {room_id, deleted} on success."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room to delete." ]
  ; tool_definition ~name:"send_room"
      ~description:"Send a message to a persistent N:N room. Appends to room history and fans out to every member's inbox except the sender, with to_alias tagged as '<alias>#<room_id>'. The sender alias is resolved from the current MCP session when possible; `from_alias` remains a legacy fallback. Returns JSON {delivered_to, skipped, ts}."
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
      ~description:"Return the last `limit` (default 50) messages from a room's append-only history. Pass `since` as a Unix epoch float to get only messages newer than that timestamp — useful for incremental polling without re-reading old history. Read-only."
      ~required:["room_id"]
      ~properties:[ prop "room_id" "Room whose history to retrieve."; int_prop "limit" "Max messages to return (default 50)."; float_prop "since" "Only return messages with ts > since (Unix epoch float, optional)." ]
  ; tool_definition ~name:"history"
      ~description:"Return your own archived inbox messages, newest first. Every message drained via poll_inbox is archived to a per-session append-only log before the live inbox is cleared, so this tool gives you a durable record of everything you've ever received. Caller's session_id is always resolved from the MCP env (C2C_MCP_SESSION_ID); passing a session_id argument is ignored for isolation — you can only read your own history. Optional `limit` (default 50). Returns a JSON array of {drained_at, from_alias, to_alias, content} objects."
      ~required:[]
      ~properties:[ int_prop "limit" "Max messages to return (default 50)." ]
  ; tool_definition ~name:"tail_log"
      ~description:"Return the last N lines from the broker RPC audit log (broker.log). Each line is a JSON object {ts, tool, ok}. Useful for verifying that your sends and polls actually reached the broker, without needing to read the file directly. Content fields are not logged — only tool names and success/fail status. Optional `limit` (default 50, max 500). Returns a JSON array of log entries, oldest first."
      ~required:[]
      ~properties:[ int_prop "limit" "Max log entries (default 50, max 500)." ]
  ; tool_definition ~name:"server_info"
      ~description:"Return c2c client/broker version, git SHA, and feature flags. Useful for diagnostics and for checking which capabilities are available in the current session."
      ~required:[]
      ~properties:[]
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
  ; tool_definition ~name:"set_dnd"
      ~description:"Enable or disable Do-Not-Disturb for this session. When DND is on, channel-push delivery (notifications/claude/channel) is suppressed — inbox still accumulates messages, poll_inbox always works. Optional `until_epoch` sets an auto-expire Unix timestamp; omit for manual-off only. Returns JSON {ok:true,dnd:bool}."
      ~required:["on"]
      ~properties:
        [ prop "on" "true to enable DND, false to disable."
        ; prop "until_epoch" "Optional float Unix timestamp to auto-expire DND (e.g. Unix.gettimeofday()+3600 for 1h)."
        ]
  ; tool_definition ~name:"dnd_status"
      ~description:"Check current Do-Not-Disturb status for this session. Returns JSON {dnd:bool, dnd_since?:float, dnd_until?:float}."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"open_pending_reply"
      ~description:"Open a pending reply tracking entry when sending a permission or question request to supervisors. Records the perm_id, kind (permission/question), supervisors list, and TTL for validation when replies arrive."
      ~required:["perm_id"; "kind"; "supervisors"]
      ~properties:
        [ prop "perm_id" "Unique permission/request ID."
        ; prop "kind" "Type: 'permission' or 'question'."
        ; arr_prop "supervisors" "List of supervisor aliases that can answer."
        ]
  ; tool_definition ~name:"check_pending_reply"
      ~description:"Validate that a received reply is authorized for a pending permission/request."
      ~required:["perm_id"; "reply_from_alias"]
      ~properties:
        [ prop "perm_id" "Permission/request ID from the reply."
        ; prop "reply_from_alias" "Alias the reply claims to be from."
        ]
  ; tool_definition ~name:"set_compact"
      ~description:"Mark this session as compacting (context summarization in progress). Set by PreCompact hooks so senders receive a warning. Returns {compacting: {started_at, reason}}."
      ~required:[]
      ~properties:
        [ prop "reason" "Optional human-readable reason for compaction (e.g. 'context-limit-near')."
        ]
  ; tool_definition ~name:"clear_compact"
      ~description:"Clear the compacting flag for this session. Called by PostCompact hooks after context summarization completes."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"stop_self"
      ~description:"Ephemeral agents: stop this managed session cleanly. Confirm with your caller that your job is complete BEFORE calling this. Looks up the managed-instance name from the current session's registered alias and sends SIGTERM to the outer loop. Returns {ok, name, reason}."
      ~required:[]
      ~properties:
        [ prop "reason" "Optional short reason logged in the stop report (e.g. 'task complete')." ]
  ; tool_definition ~name:"memory_list"
      ~description:"List the current agent's memory entries. Returns a JSON array of {name, description, shared} objects."
      ~required:[]
      ~properties:[]
  ; tool_definition ~name:"memory_read"
      ~description:"Read a memory entry by name. Returns {name, description, shared, content} on success."
      ~required:["name"]
      ~properties:[ prop "name" "Memory entry name (without .md extension)." ]
  ; tool_definition ~name:"memory_write"
      ~description:"Write a memory entry. Creates or overwrites. Returns {saved: name}."
      ~required:["name"; "content"]
      ~properties:
        [ prop "name" "Memory entry name."
        ; prop "description" "Short description (optional)."
        ; prop "shared" "Mark as shared with other agents (optional, default false)."
        ; prop "content" "Memory body text." ]
  ]

let tool_definitions =
  if Build_flags.mcp_debug_tool_enabled
  then base_tool_definitions @ [ debug_tool_definition ]
  else base_tool_definitions

let string_member name json =
  let open Yojson.Safe.Util in
  match json |> member name with
  | `String s -> s
  | `Null ->
      invalid_arg
        (Printf.sprintf "missing required string argument '%s'" name)
  | other ->
      invalid_arg
        (Printf.sprintf
           "argument '%s' must be a string, got %s"
           name
           (match other with
            | `Int _ -> "int"
            | `Float _ -> "float"
            | `Bool _ -> "bool"
            | `List _ -> "array"
            | `Assoc _ -> "object"
            | `Null -> "null"
            | _ -> "other"))

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
        (match names with
         | [] -> invalid_arg "string_member_any: no candidate names"
         | [ first ] ->
             invalid_arg
               (Printf.sprintf "missing required string argument '%s'" first)
         | first :: rest ->
             invalid_arg
               (Printf.sprintf
                  "missing required string argument '%s' (or alternatives: %s)"
                  first
                  (String.concat ", " rest)))
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

let optional_member name json =
  let open Yojson.Safe.Util in
  try
    match json |> member name with
    | `Null -> None
    | value -> Some value
  with _ -> None

let first_nonempty_env keys =
  let rec loop = function
    | [] -> None
    | key :: rest ->
        (match Sys.getenv_opt key with
         | Some value ->
             let trimmed = String.trim value in
             if trimmed = "" then loop rest else Some trimmed
         | None -> loop rest)
  in
  loop keys

let native_session_id_env_keys = function
  | "claude" -> [ "CLAUDE_SESSION_ID" ]
  | "codex" -> [ "CODEX_THREAD_ID" ]
  | "opencode" -> [ "C2C_OPENCODE_SESSION_ID" ]
  | "kimi" | "crush" | "codex-headless" -> []
  | _ -> []

let inferred_client_type_from_env () =
  match first_nonempty_env [ "C2C_MCP_CLIENT_TYPE" ] with
  | Some client_type -> Some client_type
  | None ->
      if first_nonempty_env [ "CODEX_THREAD_ID" ] <> None then Some "codex"
      else if first_nonempty_env [ "CLAUDE_SESSION_ID" ] <> None then Some "claude"
      else if first_nonempty_env [ "C2C_OPENCODE_SESSION_ID" ] <> None then Some "opencode"
      else None

let session_id_from_env ?client_type () =
  match first_nonempty_env [ "C2C_MCP_SESSION_ID" ] with
  | Some session_id -> Some session_id
  | None ->
      let resolved_client_type =
        match client_type with
        | Some kind when String.trim kind <> "" -> Some (String.trim kind)
        | _ -> inferred_client_type_from_env ()
      in
      let fallback_keys =
        match resolved_client_type with
        | Some kind -> native_session_id_env_keys kind
        | None -> []
      in
      first_nonempty_env fallback_keys

let current_session_id () =
  session_id_from_env ()

let managed_instances_dir () =
  match Sys.getenv_opt "C2C_INSTANCES_DIR" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
      let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
      Filename.concat home ".local/share/c2c/instances"

let managed_session_id_from_codex_thread ~broker_root ~thread_id =
  let instances_dir = managed_instances_dir () in
  if not (Sys.file_exists instances_dir && Sys.is_directory instances_dir) then None
  else
    let entries = try Array.to_list (Sys.readdir instances_dir) with _ -> [] in
    let matches =
      List.filter_map
        (fun name ->
          let config_path =
            Filename.concat (Filename.concat instances_dir name) "config.json"
          in
          if not (Sys.file_exists config_path) then None
          else
            try
              let json = Yojson.Safe.from_file config_path in
              let fields = match json with `Assoc assoc -> assoc | _ -> [] in
              let string_field key =
                match List.assoc_opt key fields with
                | Some (`String value) when String.trim value <> "" ->
                    Some (String.trim value)
                | _ -> None
              in
              let is_codex_family =
                match string_field "client" with
                | Some ("codex" | "codex-headless") -> true
                | _ -> false
              in
              let broker_matches =
                match string_field "broker_root" with
                | Some root -> String.equal root broker_root
                | None -> false
              in
              let thread_matches =
                (match string_field "resume_session_id" with
                 | Some value -> String.equal value thread_id
                 | None -> false)
                || (match string_field "codex_resume_target" with
                    | Some value -> String.equal value thread_id
                    | None -> false)
              in
              if is_codex_family && broker_matches && thread_matches
              then string_field "session_id"
              else None
            with _ -> None)
        entries
    in
    match matches with
    | session_id :: _ -> Some session_id
    | [] -> None

let codex_turn_metadata_session_id params =
  let open Yojson.Safe.Util in
  try
    match params |> member "_meta" |> member "x-codex-turn-metadata" |> member "session_id" with
    | `String value when String.trim value <> "" -> Some (String.trim value)
    | _ -> None
  with _ -> None

let request_session_id_override ~broker_root ~tool_name ~params =
  match tool_name with
  | "register" | "whoami" | "debug" | "poll_inbox" | "peek_inbox" | "history" | "my_rooms"
  | "send" | "send_all" | "send_room" | "join_room" | "leave_room" | "send_room_invite" | "set_room_visibility"
  | "open_pending_reply" | "check_pending_reply" | "set_compact" | "clear_compact"
  | "stop_self" ->
      (* Codex does not reliably pass parent env through to MCP subprocesses,
         but it does attach the real thread id on each tools/call request.
         For managed sessions we map that native thread id back to the stable
         c2c instance session_id; otherwise we fall back to the raw thread id. *)
      (match codex_turn_metadata_session_id params with
       | Some thread_id ->
           (match managed_session_id_from_codex_thread ~broker_root ~thread_id with
            | Some session_id -> Some session_id
            | None -> Some thread_id)
       | None -> None)
  | _ -> None

(* Derive a session_id from the alias when C2C_MCP_SESSION_ID is not set.
   Uses alias as-is so the plugin (which reads the same alias from the
   sidecar or env) passes a consistent session_id in MCP tool calls.
   Managed sessions (c2c start) always inherit C2C_MCP_SESSION_ID via env,
   so this fallback only fires for plain opencode runs without that env var. *)
let derived_session_id_from_alias alias = alias

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

let current_client_type () =
  match Sys.getenv_opt "C2C_MCP_CLIENT_TYPE" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let current_plugin_version () =
  match Sys.getenv_opt "C2C_MCP_PLUGIN_VERSION" with
  | Some value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let pending_channel_test_code : string option ref = ref None

let pop_channel_test_code () =
  let value = !pending_channel_test_code in
  pending_channel_test_code := None;
  value

let auto_register_impl ~broker_root ?session_id_override () =
  match auto_register_alias () with
  | None -> ()
  | Some alias ->
  let session_id =
    match session_id_override with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ ->
        (match current_session_id () with
         | Some sid -> sid
         | None -> derived_session_id_from_alias alias)
  in
  begin
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
         dead by the time the new process starts.
         IMPORTANT: exclude pid=None entries. After c2c start cleans up,
         clear_registration_pid strips the PID so the entry has pid=None.
         registration_is_alive returns true for pid=None (legacy compat), so
         without this exclusion Guard 3 would block re-registration on resume
         (None != Some new_pid triggers the guard incorrectly). A no-pid row
         cannot "own" an alias — treat it as an empty slot. *)
      let same_session_alive_different_pid =
        List.exists
          (fun reg ->
             reg.session_id = session_id
             && reg.alias = alias
             && reg.pid <> None
             && Broker.registration_is_alive reg
             && reg.pid <> pid)
          existing
      in
      (* Guard 4: if an alive registration already exists with the SAME pid
         but a DIFFERENT session_id and DIFFERENT alias, skip — prevents
         child processes launched inside a managed session (e.g. OpenCode
         from Codex) from inheriting the same C2C_MCP_CLIENT_PID and
         creating a permanent ghost alias that accumulates messages. *)
      let same_pid_alive_different_session =
        List.exists
          (fun reg ->
             reg.session_id <> session_id
             && reg.alias <> alias
             && Broker.registration_is_alive reg
             && reg.pid = pid)
          existing
      in
      if not hijack_guard && not alias_occupied_guard && not same_session_alive_different_pid
         && not same_pid_alive_different_session
      then begin
        let pid_start_time = Broker.capture_pid_start_time pid in
        let client_type = current_client_type () in
        let plugin_version = current_plugin_version () in
        let enc_pubkey =
          match Relay_enc.load_or_generate ~session_id () with
          | Ok enc -> Some (Relay_enc.public_key_b64 enc)
          | Error e ->
              Printf.eprintf "[auto_register_startup] warning: could not load X25519 key: %s\n%!" e;
              None
        in
        Broker.register broker ~session_id ~alias ~pid ~pid_start_time ~client_type ~plugin_version ~enc_pubkey ();
        ignore (Broker.redeliver_dead_letter_for_session broker ~session_id ~alias)
      end else begin
        (* Log which guard triggered and by which registration, for debugging. *)
        (match List.find_opt (fun reg -> reg.session_id = session_id && reg.alias <> alias && Broker.registration_is_alive reg) existing with
         | Some reg -> Printf.eprintf "[auto_register_startup] hijack_guard: skipping — found alive registration alias=%S session_id=%S pid=%s\n%!"
           reg.alias reg.session_id (match reg.pid with None -> "none" | Some p -> string_of_int p)
         | None -> ());
        (match List.find_opt (fun reg -> reg.alias = alias && reg.session_id <> session_id && reg.pid <> pid && Broker.registration_is_alive reg) existing with
         | Some reg -> Printf.eprintf "[auto_register_startup] alias_occupied_guard: skipping — alias=%S already held by session_id=%S pid=%s\n%!"
           alias reg.session_id (match reg.pid with None -> "none" | Some p -> string_of_int p)
         | None -> ());
        (match List.find_opt (fun reg -> reg.session_id = session_id && reg.alias = alias && reg.pid <> None && reg.pid <> pid && Broker.registration_is_alive reg) existing with
         | Some reg -> Printf.eprintf "[auto_register_startup] same_session_alive_different_pid: skipping — session_id=%S alias=%S pid=%s\n%!"
           reg.session_id reg.alias (match reg.pid with None -> "none" | Some p -> string_of_int p)
         | None -> ());
        (match List.find_opt (fun reg -> reg.pid = pid && reg.session_id <> session_id && reg.alias <> alias && Broker.registration_is_alive reg) existing with
         | Some reg -> Printf.eprintf "[auto_register_startup] same_pid_alive_different_session: skipping — pid=%s has alive registration alias=%S session_id=%S\n%!"
           (match pid with None -> "none" | Some p -> string_of_int p) reg.alias reg.session_id
         | None -> ());
        ()
      end
  end

let auto_register_startup ~broker_root = auto_register_impl ~broker_root ()

(** Auto-join rooms listed in C2C_MCP_AUTO_JOIN_ROOMS (comma-separated) on
    server startup. Only runs when auto-registration is also configured (both
    C2C_MCP_AUTO_REGISTER_ALIAS must be set; C2C_MCP_SESSION_ID is optional
    (derived from alias+ppid when absent). This is
    the social-layer entry point: operators set
      C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge
    in the MCP env so every agent session joins the persistent social channel
    automatically on first startup. Idempotent — joining the same room twice
    is a no-op on the broker side. *)
let auto_join_rooms_impl ~broker_root ?session_id_override () =
  match auto_register_alias () with
  | None -> ()
  | Some alias ->
  let session_id =
    match session_id_override with
    | Some sid when String.trim sid <> "" -> String.trim sid
    | _ ->
        (match current_session_id () with
         | Some sid -> sid
         | None -> derived_session_id_from_alias alias)
  in
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

let auto_join_rooms_startup ~broker_root = auto_join_rooms_impl ~broker_root ()

let ensure_request_session_bootstrap ~broker_root ?session_id_override () =
  match session_id_override, auto_register_alias () with
  | Some _, Some _ ->
      auto_register_impl ~broker_root ?session_id_override ();
      auto_join_rooms_impl ~broker_root ?session_id_override ()
  | _ -> ()

let resolve_session_id ?session_id_override arguments =
  match optional_string_member "session_id" arguments with
  | Some session_id when session_id <> "" -> session_id
  | _ ->
      (match session_id_override with
       | Some session_id -> session_id
       | None ->
           (match current_session_id () with
            | Some session_id -> session_id
            | None -> invalid_arg "missing session_id"))

let current_registered_alias ?session_id_override broker =
  match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
  | None -> None
  | Some session_id ->
      Broker.list_registrations broker
      |> List.find_opt
           (fun reg -> reg.session_id = session_id)
      |> Option.map (fun reg -> reg.alias)

let alias_for_current_session_or_argument ?session_id_override broker arguments =
  match current_registered_alias ?session_id_override broker with
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
let send_alias_impersonation_check ?session_id_override broker from_alias =
  match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
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

(** Self-PASS detector strictness: "warn" (default) adds warning to receipt,
    "strict" rejects the message. *)
let self_pass_detector_strictness () =
  match Sys.getenv_opt "C2C_SELF_PASS_DETECTOR" with
  | Some "strict" -> `Strict
  | Some "warn" | None -> `Warn
  | Some _ -> `Warn

(** Extract the alias identifier that follows "peer-PASS by " in content.
    Aliases are alphanumeric with hyphens/underscores, case-insensitive.
    Returns the alias if found after the marker (skipping whitespace, delimited by whitespace/punct),
    or None if no valid alias follows. *)
let extract_alias_after_peer_pass content start_pos =
  let len = String.length content in
  let rec skip_whitespace i =
    if i >= len then None
    else
      let c = content.[i] in
      if c = ' ' || c = '\n' || c = '\t' || c = '\r' || c = '.' || c = ',' || c = ':'
      then skip_whitespace (i + 1)
      else Some i
  in
  match skip_whitespace start_pos with
  | None -> None
  | Some pos ->
      let rec read_alias acc i =
        if i >= len then Some (acc, i)
        else
          let c = content.[i] in
          if c = ' ' || c = '\n' || c = '\t' || c = '\r' || c = '.' || c = ',' || c = ':'
          then Some (acc, i)
          else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c = '-' || c = '_'
          then read_alias (acc ^ String.make 1 c) (i + 1)
          else None
      in
      read_alias "" pos

(** Detect "peer-PASS by <alias>" self-review violation in message content.
    Returns Some warning_message if sender's own alias appears in that pattern,
    None otherwise. Case-insensitive alias comparison. *)
let check_self_pass_content ~from_alias content =
  let needle = String.lowercase_ascii "peer-PASS by" in
  let needle_len = String.length needle in
  let lc = String.lowercase_ascii content in
  let lc_from_alias = String.lowercase_ascii from_alias in
  let rec search pos =
    match String.index_from_opt lc pos needle.[0] with
    | None -> None
    | Some i ->
        if i + needle_len <= String.length lc
           && String.sub lc i needle_len = needle
        then
          match extract_alias_after_peer_pass content (i + needle_len) with
          | Some (claimed_alias, _) ->
              if String.lowercase_ascii claimed_alias = lc_from_alias
              then Some (Printf.sprintf "self-review-via-skill violation: 'peer-PASS by %s' detected in message content (your own alias)" from_alias)
              else search (i + 1)
          | None -> search (i + 1)
        else search (i + 1)
  in
  search 0

let handle_tool_call ~(broker : Broker.t) ?session_id_override ~tool_name ~arguments =
  match tool_name with
  | "register" ->
      let session_id = resolve_session_id ?session_id_override arguments in
      let alias =
        match optional_string_member "alias" arguments with
        | Some a -> a
        | None ->
            (match auto_register_alias () with
             | Some a -> a
             | None -> invalid_arg "alias is required (pass {\"alias\":\"your-name\"} or set C2C_MCP_AUTO_REGISTER_ALIAS)")
      in
      (* Reserved aliases — always blocked. *)
      if List.mem alias Broker.reserved_system_aliases then
        Lwt.return (tool_result
          ~content:(Printf.sprintf
            "register rejected: '%s' is a reserved system alias and cannot be registered" alias)
          ~is_error:true)
      else if not (C2c_name.is_valid alias) then
        Lwt.return (tool_result
          ~content:(Printf.sprintf "register rejected: %s"
            (C2c_name.error_message "alias" alias))
          ~is_error:true)
      else
      let pid =
        match current_client_pid () with
        | Some pid -> Some pid
        | None -> Some (Unix.getppid ())
      in
      let client_type = optional_string_member "client_type" arguments in
      (* Detect whether this is a brand-new registration (no existing row for
         this session_id). Used below to emit peer_register broadcast. *)
      let is_new_registration =
        not (List.exists (fun r -> r.session_id = session_id)
               (Broker.list_registrations broker))
      in
      (* Detect alias rename before registering so we can notify rooms.
         A rename is genuine when the same process (matched by PID) re-registers
         under a new alias.  When both the old and new registration have a real
         PID set, they must agree — a differing PID means a new process reused
         the same session_id (common with `c2c start`), not an intentional rename.
         When the old registration has pid=None (legacy / no-PID registration),
         we allow the rename so that pre-PID entries are not permanently frozen. *)
      let old_alias_opt =
        let existing =
          List.find_opt
            (fun reg ->
              reg.session_id = session_id
              && reg.alias <> alias
              && (match reg.pid, pid with
                  | Some old_pid, Some new_pid -> old_pid = new_pid
                  | None, _ -> true   (* legacy no-PID row — allow rename *)
                  | Some _, None -> false))   (* new has no pid — can't confirm same process *)
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
      (* Guard: refuse to evict a CONFIRMED-alive registration that owns this alias
         under a different session_id. An agent re-registering its own alias (same
         session_id, e.g. after a PID change) is always allowed. This prevents
         confused or malicious agents from hijacking another agent's alias.
         Use registration_liveness_state (tristate) so that pidless/Unknown entries
         do NOT block — registration_is_alive returns true for pid=None, which would
         permanently strand an alias held by a stale pidless row. We also block when
         pid is set and process exists but pid_start_time is missing (conservative:
         can't verify PID reuse, so protect the alias). *)
      let alias_hijack_conflict =
        List.find_opt
          (fun reg ->
            reg.alias = alias
            && reg.session_id <> session_id
            && Option.is_some reg.pid
            && Broker.registration_is_alive reg)
          (Broker.list_registrations broker)
      in
      (match alias_hijack_conflict with
       | Some conflict ->
           let suggested_opt = Broker.suggest_alias_for_alias broker ~alias in
           let content =
             match suggested_opt with
             | Some suggested ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s'. Suggested free alias: '%s'. \
                              Options: (1) register with {\"alias\":\"%s\"}, \
                              (2) wait for the current holder's process to exit, \
                              (3) call list to see all current registrations."
                             alias conflict.session_id suggested suggested))
                     ; ("collision", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ; ("suggested_alias", `String suggested)
                     ])
             | None ->
                 Yojson.Safe.to_string
                   (`Assoc
                     [ ("error", `String
                          (Printf.sprintf
                             "register rejected: alias '%s' is currently held by \
                              an alive session '%s', and all prime-suffixed \
                              candidates are also taken. Choose a different base alias."
                             alias conflict.session_id))
                     ; ("collision", `Bool true)
                     ; ("collision_exhausted", `Bool true)
                     ; ("contested_alias", `String alias)
                     ; ("holder_session_id", `String conflict.session_id)
                     ])
           in
            Lwt.return (tool_result ~content ~is_error:true)
         | None ->
             let prior_owner_has_pending =
               Broker.pending_permission_exists_for_alias broker alias
             in
             if prior_owner_has_pending then
               Lwt.return (tool_result
                 ~content:(Printf.sprintf
                   "register rejected: alias '%s' has pending permission state \
                    from a prior owner. \
                    Wait for the pending reply to arrive or for it to timeout before claiming this alias."
                   alias)
                ~is_error:true)
            else begin
              let plugin_version = optional_string_member "plugin_version" arguments in
              let role = optional_string_member "role" arguments in
              let enc_pubkey =
                match Relay_enc.load_or_generate ~session_id () with
                | Ok enc -> Some (Relay_enc.public_key_b64 enc)
                | Error e ->
                    Printf.eprintf "[register] warning: could not load X25519 key: %s\n%!" e;
                    None
              in
              Broker.register broker ~session_id ~alias ~pid ~pid_start_time
                ~client_type ~plugin_version ~enc_pubkey ~role ();
              Broker.touch_session broker ~session_id;
              List.iter
                (fun room_id ->
                  try
                    ignore
                      (Broker.rename_room_member_alias broker ~room_id ~session_id
                         ~new_alias:alias)
                  with _ -> ())
                rooms_to_notify;
              (match old_alias_opt with
               | None -> ()
               | Some old_alias ->
                   let content =
                     Printf.sprintf
                       "%s renamed to %s {\"type\":\"peer_renamed\",\"old_alias\":\"%s\",\"new_alias\":\"%s\"}"
                       old_alias alias old_alias alias
                   in
                   List.iter
                     (fun room_id ->
                       (try
                          ignore
                            (Broker.send_room broker ~from_alias:"c2c-system"
                               ~room_id ~content)
                        with _ -> ()))
                     rooms_to_notify);
              let new_reg_unconfirmed =
                match List.find_opt (fun r -> r.session_id = session_id)
                        (Broker.list_registrations broker) with
                | Some reg -> Broker.is_unconfirmed reg
                | None -> false
              in
              (if is_new_registration && not new_reg_unconfirmed then begin
                let social_rooms =
                  let auto_rooms =
                    match Sys.getenv_opt "C2C_MCP_AUTO_JOIN_ROOMS" with
                    | Some v ->
                        String.split_on_char ',' v
                        |> List.map String.trim
                        |> List.filter (fun s -> s <> "" && Broker.valid_room_id s)
                    | None -> []
                  in
                  List.sort_uniq String.compare ("swarm-lounge" :: auto_rooms)
                in
                let content =
                  Printf.sprintf
                    "%s registered {\"type\":\"peer_register\",\"alias\":\"%s\"}"
                    alias alias
                in
                List.iter
                  (fun room_id ->
                    try ignore (Broker.send_room broker ~from_alias:"c2c-system" ~room_id ~content)
                    with _ -> ())
                  social_rooms
              end);
              let redelivered =
                Broker.redeliver_dead_letter_for_session broker ~session_id ~alias
              in
              Broker.write_allowed_signers_entry broker ~alias;
              let response_content =
                if redelivered > 0 then
                  Printf.sprintf "registered %s (redelivered %d dead-letter message%s)"
                    alias redelivered (if redelivered = 1 then "" else "s")
                else
                  "registered " ^ alias
              in
              Lwt.return (tool_result ~content:response_content ~is_error:false)
            end)
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
               let with_ra =
                 match registered_at with
                 | Some ts -> with_alive @ [ ("registered_at", `Float ts) ]
                 | None -> with_alive
               in
               let fields =
                 match reg.canonical_alias with
                 | Some ca -> with_ra @ [ ("canonical_alias", `String ca) ]
                 | None -> with_ra
               in
               `Assoc fields)
             registrations)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "send" ->
      let to_alias = string_member_any [ "to_alias"; "alias" ] arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None ->
           Lwt.return (missing_sender_alias_result "send")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override broker from_alias with
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
                 if from_alias = to_alias then
                   Lwt.return (tool_result ~content:"error: cannot send a message to yourself" ~is_error:true)
                 else
                 let deferrable =
                   try match Yojson.Safe.Util.member "deferrable" arguments with
                     | `Bool b -> b | _ -> false
                   with _ -> false
                 in
let ts = Unix.gettimeofday () in
                  let effective_content =
                    let recipient_reg =
                      Broker.list_registrations broker
                      |> List.find_opt (fun r -> r.alias = to_alias)
                    in
                    match recipient_reg with
                    | Some _ -> `Plain content
                    | None ->
                      let recipient_reg =
                        Broker.list_registrations broker
                        |> List.find_opt (fun r -> r.alias = to_alias && r.enc_pubkey <> None)
                      in
                      match recipient_reg with
                      | None -> `Plain content
                      | Some reg ->
                        match reg.enc_pubkey with
                        | None -> `Plain content
                        | Some recipient_pk_b64 ->
                          (match Broker.get_pinned_x25519 to_alias with
                        | Some pinned when pinned <> recipient_pk_b64 ->
                          `Key_changed to_alias
                        | _ ->
                          let session_id =
                            match session_id_override with
                            | Some sid -> sid
                            | None ->
                                (match current_session_id () with
                                 | Some sid -> sid
                                 | None -> from_alias)
                          in
                          (match Relay_enc.load_or_generate ~session_id () with
                            | Error e ->
                              Printf.eprintf "send: load_or_generate x25519 failed: %s\n" e;
                              `Plain content
                             | Ok our_x25519 ->
                              let sender_pk_b64 = Relay_enc.b64url_encode our_x25519.public_key in
                              Broker.pin_x25519_sync ~alias:to_alias ~pk:recipient_pk_b64 |> ignore;
                              let our_ed25519 = Broker.load_or_create_ed25519_identity () in
                              let our_ed_pubkey_b64 = Relay_enc.b64url_encode our_ed25519.public_key in
                              Broker.pin_ed25519_sync ~alias:from_alias ~pk:our_ed_pubkey_b64 |> ignore;
                              let sk_seed = our_x25519.private_key_seed in
                             match Relay_e2e.encrypt_for_recipient
                                     ~pt:content
                                     ~recipient_pk_b64:recipient_pk_b64
                                     ~our_sk_seed:sk_seed with
                             | None -> `Plain content
                             | Some (ct_b64, nonce_b64) ->
                               let recipient_entry = Relay_e2e.make_recipient
                                 ~alias:to_alias ~ct_b64 ~nonce:nonce_b64
                               in
                               let envelope : Relay_e2e.envelope = {
                                 from_ = from_alias;
                                 from_x25519 = Some sender_pk_b64;
                                 to_ = Some to_alias;
                                 room = None;
                                 ts = Int64.of_float ts;
                                 enc = "box-x25519-v1";
                                 recipients = [ recipient_entry ];
                                 sig_b64 = "";
                               } in
                               let signed = Relay_e2e.set_sig envelope ~sk_seed:our_ed25519.private_key_seed in
                               `Encrypted (Yojson.Safe.to_string (Relay_e2e.envelope_to_json signed))))
                 in
                 match effective_content with
                 | `Key_changed alias ->
                   let err = Printf.sprintf "send rejected: enc_status:key-changed — %s's x25519 key differs from known pin (possible relay tamper). Re-send after trust --repin %s." alias alias in
                   Lwt.return (tool_result ~content:err ~is_error:true)
                  | `Plain s | `Encrypted s ->
                    let self_pass_warning =
                      match check_self_pass_content ~from_alias content with
                      | Some msg when self_pass_detector_strictness () = `Strict -> Some (`Reject msg)
                      | Some msg -> Some (`Warn msg)
                      | None -> None
                    in
                    let peer_pass_verification =
                      match Peer_review.claim_of_content content with
                      | None -> None
                      | Some (alias, sha) ->
                          match Peer_review.verify_claim ~alias ~sha with
                          | Peer_review.Claim_valid msg -> Some (`Ok msg)
                          | Peer_review.Claim_missing m -> Some (`Missing m)
                          | Peer_review.Claim_invalid m -> Some (`Invalid m)
                    in
                    match self_pass_warning with
                    | Some (`Reject msg) ->
                        Lwt.return (tool_result ~content:("send rejected: " ^ msg) ~is_error:true)
                    | Some (`Warn _) | None ->
                        Broker.enqueue_message broker ~from_alias ~to_alias ~content:s ~deferrable ();
                        (match session_id_override with
                         | Some sid -> Broker.touch_session broker ~session_id:sid
                         | None ->
                           (match current_session_id () with
                            | Some sid -> Broker.touch_session broker ~session_id:sid
                            | None -> ()));
                        let ts = Unix.gettimeofday () in
                        let recipient_dnd =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> r.alias = to_alias) with
                          | Some r -> Broker.is_dnd broker ~session_id:r.session_id
                          | None -> false
                        in
                        let recipient_compacting =
                          match Broker.list_registrations broker
                                |> List.find_opt (fun r -> r.alias = to_alias) with
                          | Some r ->
                              (match Broker.is_compacting broker ~session_id:r.session_id with
                               | Some c ->
                                   let dur = Unix.gettimeofday () -. c.started_at in
                                   Some (dur, c.reason)
                               | None -> None)
                          | None -> None
                        in
                        let receipt_fields =
                          [ ("queued", `Bool true)
                          ; ("ts", `Float ts)
                          ; ("from_alias", `String from_alias)
                          ; ("to_alias", `String to_alias)
                          ]
                        in
                        let receipt_fields =
                          match self_pass_warning with
                          | Some (`Warn msg) -> receipt_fields @ [("self_pass_warning", `String msg)]
                          | _ -> receipt_fields
                        in
                        let receipt_fields =
                          match peer_pass_verification with
                          | Some (`Ok msg) -> receipt_fields @ [("peer_pass_verification", `String msg)]
                          | Some (`Missing m) -> receipt_fields @ [("peer_pass_verification", `String ("missing: " ^ m))]
                          | Some (`Invalid m) -> receipt_fields @ [("peer_pass_verification", `String ("invalid: " ^ m))]
                          | None -> receipt_fields
                        in
                        let receipt_fields =
                          if recipient_dnd then receipt_fields @ [("recipient_dnd", `Bool true)]
                          else receipt_fields
                        in
                        let receipt_fields =
                          match recipient_compacting with
                          | Some (dur, reason) ->
                              let reason_str = match reason with Some r -> " (" ^ r ^ ")" | None -> "" in
                              let warning = Printf.sprintf "recipient compacting for %.0fs%s" dur reason_str in
                              receipt_fields @ [("compacting_warning", `String warning)]
                          | None -> receipt_fields
                        in
                        let receipt_fields =
                          if deferrable then receipt_fields @ [("deferrable", `Bool true)]
                          else receipt_fields
                        in
                        let receipt = `Assoc receipt_fields |> Yojson.Safe.to_string in
                        Lwt.return (tool_result ~content:receipt ~is_error:false)))
  | "send_all" ->
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_all")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override broker from_alias with
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
                (match session_id_override with Some sid -> Broker.touch_session broker ~session_id:sid | None -> (match current_session_id () with Some sid -> Broker.touch_session broker ~session_id:sid | None -> ()));
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
      let session_id = resolve_session_id ?session_id_override arguments in
      let reg_opt =
        Broker.list_registrations broker
        |> List.find_opt (fun reg -> reg.session_id = session_id)
      in
      let content =
        match reg_opt with
        | None -> ""
        | Some reg ->
            (match reg.canonical_alias with
             | Some ca ->
                 `Assoc [ ("alias", `String reg.alias); ("canonical_alias", `String ca) ]
                 |> Yojson.Safe.to_string
             | None -> reg.alias)
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "debug" ->
      let action = string_member "action" arguments in
      if not Build_flags.mcp_debug_tool_enabled then
        Lwt.return (tool_result ~content:"unknown tool" ~is_error:true)
      else
        (match action with
         | "send_msg_to_self" ->
             let session_id = resolve_session_id ?session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_msg_to_self: current session is not registered"))
             in
             let payload_json =
               optional_member "payload" arguments |> Option.value ~default:`Null
             in
             let content =
               `Assoc
                 [ ("kind", `String "c2c_debug")
                 ; ("action", `String action)
                 ; ("payload", payload_json)
                 ; ("ts", `Float (Unix.gettimeofday ()))
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ]
               |> Yojson.Safe.to_string
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content ();
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("content_preview", `String content)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_result ~content:result_json ~is_error:false)
         | "send_raw_to_self" ->
             (* Like send_msg_to_self, but content is the payload string verbatim
                — no JSON wrapping, no c2c_debug envelope. The body that arrives in
                the channel notification is exactly the payload. Use case: probe
                whether a Claude harness treats raw channel body as user input
                (e.g. payload="/compact" to test slash-command firing). *)
             let session_id = resolve_session_id ?session_id_override arguments in
             let sender_alias =
               match current_registered_alias ?session_id_override broker with
               | Some alias -> alias
               | None ->
                   (match auto_register_alias () with
                    | Some alias -> alias
                    | None ->
                        raise
                          (Invalid_argument
                             "debug.send_raw_to_self: current session is not registered"))
             in
             let payload =
               match optional_member "payload" arguments with
               | Some (`String s) -> s
               | Some _ ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload must be a string")
               | None ->
                   raise
                     (Invalid_argument
                        "debug.send_raw_to_self: payload is required")
             in
             Broker.enqueue_message broker ~from_alias:sender_alias
               ~to_alias:sender_alias ~content:payload ();
             let preview =
               if String.length payload <= 200 then payload
               else String.sub payload 0 200 ^ "…"
             in
             let result_json =
               `Assoc
                 [ ("ok", `Bool true)
                 ; ("action", `String action)
                 ; ("session_id", `String session_id)
                 ; ("alias", `String sender_alias)
                 ; ("delivered_to", `String sender_alias)
                 ; ("payload_length", `Int (String.length payload))
                 ; ("content_preview", `String preview)
                 ]
               |> Yojson.Safe.to_string
             in
             Lwt.return (tool_result ~content:result_json ~is_error:false)
          | "get_env" ->
              let prefix =
                match optional_string_member "prefix" arguments with
                | Some p -> p
                | None -> "C2C_"
              in
              let env_vars =
                Array.to_list (Unix.environment ())
                |> List.filter (fun entry ->
                  String.length entry > String.length prefix
                  && String.sub entry 0 (String.length prefix) = prefix)
                |> List.map (fun entry ->
                  match String.index_opt entry '=' with
                  | Some i ->
                      let key = String.sub entry 0 i in
                      let value = String.sub entry (i + 1) (String.length entry - i - 1) in
                      (key, value)
                  | None -> (entry, ""))
                |> List.sort (fun (k1,_) (k2,_) -> String.compare k1 k2)
              in
              let result_json =
                `Assoc (
                  ("ok", `Bool true)
                  :: ("action", `String "get_env")
                  :: ("prefix", `String prefix)
                  :: ("count", `Int (List.length env_vars))
                  :: (List.map (fun (k,v) -> (k, `String v)) env_vars)
                )
                |> Yojson.Safe.to_string
              in
              Lwt.return (tool_result ~content:result_json ~is_error:false)
          | _ ->
              Lwt.return
                (tool_result
                   ~content:(Printf.sprintf "debug: unknown action '%s'" action)
                   ~is_error:true))
  | "poll_inbox" ->
      let req_sid = optional_string_member "session_id" arguments in
      let caller_sid =
        match session_id_override with
        | Some sid -> Some sid
        | None -> current_session_id ()
      in
      if req_sid <> None && caller_sid <> None && req_sid <> caller_sid then
        Lwt.return (tool_result
          ~content:"poll_inbox: session_id argument does not match caller's MCP session (C2C_MCP_SESSION_ID)"
          ~is_error:true)
      else begin
      let session_id = resolve_session_id ?session_id_override arguments in
      Broker.confirm_registration broker ~session_id;
      Broker.touch_session broker ~session_id;
      let messages = Broker.drain_inbox broker ~session_id in
      let sid =
        match session_id_override with
        | Some sid -> sid
        | None -> (match current_session_id () with Some s -> s | None -> "unknown")
      in
      let our_x25519 = match Relay_enc.load_or_generate ~session_id:sid () with Ok k -> Some k | Error _ -> None in
      let our_ed25519 = Some (Broker.load_or_create_ed25519_identity ()) in
      let process_msg ({ from_alias; to_alias; content; deferrable } : message) =
        let (decrypted, enc_status) =
          match Yojson.Safe.from_string content with
          | exception _ -> content, None
          | env_json ->
            match Relay_e2e.envelope_of_json env_json with
            | exception _ -> content, None
            | env ->
              let ds = Broker.get_downgrade_state env.from_ in
              let (status, ds) = Relay_e2e.decide_enc_status ds env in
              Broker.set_downgrade_state env.from_ ds;
              match env.enc with
              | "plain" ->
                (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
                 | Some r -> r.ciphertext, Some (Relay_e2e.enc_status_to_string status)
                 | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Not_for_me))
              | "box-x25519-v1" ->
                (match our_x25519, our_ed25519 with
                 | Some x25519, Some ed25519 ->
                    (match Relay_e2e.find_my_recipient ~my_alias:to_alias env.recipients with
                     | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Not_for_me)
                     | Some recipient ->
                       (match recipient.nonce with
                        | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                        | Some nonce_b64 ->
                          let sender_x25519_pk = env.from_x25519 in
                          (match Relay_e2e.decrypt_for_me
                            ~ct_b64:recipient.ciphertext
                            ~nonce_b64
                            ~sender_pk_b64:(match sender_x25519_pk with Some pk -> pk | None -> "")
                            ~our_sk_seed:x25519.private_key_seed with
                           | None ->
                             (match sender_x25519_pk with
                              | Some pk ->
                                let pinned = Broker.get_pinned_x25519 env.from_ in
                                if pinned <> None && pinned <> Some pk then
                                  content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Key_changed)
                                else
                                  content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                              | None -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed))
                           | Some pt ->
                              let sender_ed25519_pk_opt = Broker.get_pinned_ed25519 env.from_ in
                              (match sender_ed25519_pk_opt with
                               | None ->
                                 content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed)
                               | Some pk ->
                                 let sig_ok = Relay_e2e.verify_envelope_sig ~pk env in
                                 if not sig_ok then
                                   content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Key_changed)
                                 else (
                                   (match sender_x25519_pk with
                                    | Some pk -> Broker.pin_x25519_sync ~alias:env.from_ ~pk |> ignore
                                    | None -> ());
                                   pt, Some (Relay_e2e.enc_status_to_string status)))))
                 | _ -> content, Some (Relay_e2e.enc_status_to_string Relay_e2e.Failed))
              | _ -> content, None)
        in
        let base = [ ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String decrypted) ] in
        let base = if deferrable then base @ [("deferrable", `Bool true)] else base in
        let base = match enc_status with None -> base | Some es -> base @ [("enc_status", `String es)] in
        `Assoc base
      in
      let content = `List (List.map process_msg messages) |> Yojson.Safe.to_string in
      Lwt.return (tool_result ~content ~is_error:false)
      end
  | "peek_inbox" ->
      (* Like poll_inbox but does not drain. Resolves session_id from
         env only (ignores argument overrides) — same isolation contract
         as `history` and `my_rooms`. *)
      (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
       | None ->
           Lwt.return
             (tool_result
                ~content:"peek_inbox: no session_id in env (set C2C_MCP_SESSION_ID)"
                ~is_error:true)
       | Some session_id ->
           Broker.touch_session broker ~session_id;
           let messages =
             Broker.with_inbox_lock broker ~session_id (fun () ->
                 Broker.read_inbox broker ~session_id)
           in
           let content =
             `List
               (List.map
                  (fun ({ from_alias; to_alias; content; deferrable } : message) ->
                    let base =
                      [ ("from_alias", `String from_alias)
                      ; ("to_alias", `String to_alias)
                      ; ("content", `String content)
                      ]
                    in
                    `Assoc (if deferrable then base @ [("deferrable", `Bool true)] else base))
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
      (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
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
  | "server_info" ->
      let content = Yojson.Safe.to_string server_info in
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
  | "set_dnd" ->
      let session_id = resolve_session_id ?session_id_override arguments in
      let on =
        try
          match Yojson.Safe.Util.member "on" arguments with
          | `Bool b -> b
          | _ -> false
        with _ -> false
      in
      let until_epoch =
        try
          match Yojson.Safe.Util.member "until_epoch" arguments with
          | `Float f -> Some f
          | `Int i -> Some (float_of_int i)
          | _ -> None
        with _ -> None
      in
      Broker.touch_session broker ~session_id;
      let new_dnd = Broker.set_dnd broker ~session_id ~dnd:on ?until:until_epoch () in
      let content =
        (match new_dnd with
         | None ->
             `Assoc [ ("ok", `Bool false); ("error", `String "session not registered") ]
         | Some dnd_val ->
             `Assoc [ ("ok", `Bool true); ("dnd", `Bool dnd_val) ])
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "dnd_status" ->
      let session_id = resolve_session_id ?session_id_override arguments in
      Broker.touch_session broker ~session_id;
      let reg_opt =
        Broker.list_registrations broker
        |> List.find_opt (fun r -> r.session_id = session_id)
      in
      let content =
        (match reg_opt with
         | None ->
             `Assoc [ ("dnd", `Bool false) ]
         | Some reg ->
             let dnd_active = Broker.is_dnd broker ~session_id in
             let fields = [ ("dnd", `Bool dnd_active) ] in
             let fields =
               match reg.dnd_since with
               | Some ts when dnd_active -> fields @ [ ("dnd_since", `Float ts) ]
               | _ -> fields
             in
             let fields =
               match reg.dnd_until with
               | Some ts when dnd_active -> fields @ [ ("dnd_until", `Float ts) ]
               | _ -> fields
             in
             `Assoc fields)
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "join_room" ->
      let room_id = string_member "room_id" arguments in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_member_alias_result "join_room")
       | Some alias ->
           let session_id = resolve_session_id ?session_id_override arguments in
           Broker.touch_session broker ~session_id;
           let members = Broker.join_room broker ~room_id ~alias ~session_id in
           let history_limit =
             match Broker.int_opt_member "history_limit" arguments with
             | Some n when n < 0 -> 0
             | Some n -> min n 200
             | None -> 20
           in
           let history =
             if history_limit = 0 then []
             else Broker.read_room_history broker ~room_id ~limit:history_limit ()
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
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_member_alias_result "leave_room")
       | Some alias ->
           let session_id = resolve_session_id ?session_id_override arguments in
           Broker.touch_session broker ~session_id;
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
  | "delete_room" ->
      let room_id = string_member "room_id" arguments in
      (try
         Broker.delete_room broker ~room_id;
         let content =
           `Assoc [ ("room_id", `String room_id); ("deleted", `Bool true) ]
           |> Yojson.Safe.to_string
         in
         Lwt.return (tool_result ~content ~is_error:false)
       with Invalid_argument msg ->
         let content = `Assoc [ ("error", `String msg) ] |> Yojson.Safe.to_string in
         Lwt.return (tool_result ~content ~is_error:true))
  | "send_room" ->
      let room_id = string_member "room_id" arguments in
      let content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_room")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override broker from_alias with
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
                let session_id = resolve_session_id ?session_id_override arguments in
                Broker.touch_session broker ~session_id;
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
      (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
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
      let since = Broker.float_opt_member "since" arguments |> Option.value ~default:0.0 in
      let history = Broker.read_room_history broker ~room_id ~limit ~since () in
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
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "send_room_invite")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override broker from_alias with
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
                let session_id = resolve_session_id ?session_id_override arguments in
                Broker.touch_session broker ~session_id;
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
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "set_room_visibility")
       | Some from_alias ->
           (match send_alias_impersonation_check ?session_id_override broker from_alias with
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
  | "open_pending_reply" ->
      let perm_id = string_member "perm_id" arguments in
      let kind_str = string_member "kind" arguments in
      let kind = pending_kind_of_string kind_str in
      let supervisors =
        let open Yojson.Safe.Util in
        match arguments |> member "supervisors" with
        | `List items ->
            List.filter_map
              (fun item -> match item with `String s -> Some s | _ -> None)
              items
        | _ -> []
      in
      let session_id = resolve_session_id ?session_id_override arguments in
      Broker.touch_session broker ~session_id;
      let alias =
        match List.find_opt (fun r -> r.session_id = session_id)
                (Broker.list_registrations broker) with
        | Some reg -> reg.alias
        | None -> ""
      in
      let ttl_seconds =
        match Sys.getenv_opt "C2C_PERMISSION_TTL" with
        | Some v ->
            (try float_of_string v with _ -> 600.0)
        | None -> 600.0
      in
      let now = Unix.gettimeofday () in
      let pending : pending_permission =
        { perm_id; kind; requester_session_id = session_id
        ; requester_alias = alias; supervisors
        ; created_at = now; expires_at = now +. ttl_seconds }
      in
      Broker.open_pending_permission broker pending;
      let content =
        `Assoc
          [ ("ok", `Bool true)
          ; ("perm_id", `String perm_id)
          ; ("kind", `String (pending_kind_to_string kind))
          ; ("ttl_seconds", `Float ttl_seconds)
          ; ("expires_at", `Float pending.expires_at)
          ]
        |> Yojson.Safe.to_string
      in
      Lwt.return (tool_result ~content ~is_error:false)
  | "check_pending_reply" ->
      let perm_id = string_member "perm_id" arguments in
      let reply_from_alias = string_member "reply_from_alias" arguments in
      (match Broker.find_pending_permission broker perm_id with
      | None ->
          let content =
            `Assoc
              [ ("valid", `Bool false)
              ; ("requester_session_id", `Null)
              ; ("error", `String "unknown permission ID")
              ]
            |> Yojson.Safe.to_string
          in
          Lwt.return (tool_result ~content ~is_error:false)
      | Some pending ->
          if List.mem reply_from_alias pending.supervisors then
            let content =
              `Assoc
                [ ("valid", `Bool true)
                ; ("requester_session_id", `String pending.requester_session_id)
                ; ("error", `Null)
                ]
              |> Yojson.Safe.to_string
            in
            Lwt.return (tool_result ~content ~is_error:false)
          else
            let content =
              `Assoc
                [ ("valid", `Bool false)
                ; ("requester_session_id", `Null)
                ; ("error", `String ("reply from non-supervisor: " ^ reply_from_alias))
                ]
            |> Yojson.Safe.to_string
            in
            Lwt.return (tool_result ~content ~is_error:false))
  | "set_compact" ->
      (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
       | None ->
           Lwt.return (tool_result ~content:"{\"error\": \"no session ID; set C2C_MCP_SESSION_ID\"}" ~is_error:true)
       | Some session_id ->
           let reason = optional_string_member "reason" arguments in
           let compacting = Broker.set_compacting broker ~session_id ?reason () in
           let content =
             match compacting with
             | None ->
                 `Assoc [ ("compacting", `Null) ]
                 |> Yojson.Safe.to_string
             | Some c ->
                 `Assoc
                   [ ("compacting",
                      `Assoc
                        [ ("started_at", `Float c.started_at)
                        ; ("reason", match c.reason with Some r -> `String r | None -> `Null)
                        ])
                   ]
                 |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "clear_compact" ->
      (match (match session_id_override with Some sid -> Some sid | None -> current_session_id ()) with
       | None ->
           Lwt.return (tool_result ~content:"{\"error\": \"no session ID; set C2C_MCP_SESSION_ID\"}" ~is_error:true)
       | Some session_id ->
           let ok = Broker.clear_compacting broker ~session_id in
           let content =
             `Assoc [ ("ok", `Bool ok) ]
             |> Yojson.Safe.to_string
           in
           Lwt.return (tool_result ~content ~is_error:false))
  | "stop_self" ->
      let reason = match optional_string_member "reason" arguments with Some r -> r | None -> "" in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_sender_alias_result "stop_self")
       | Some name ->
           (* Reconstruct outer.pid path without creating a C2c_start dep cycle. *)
           let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
           let instances_dir =
             match Sys.getenv_opt "C2C_INSTANCES_DIR" with
             | Some d when String.trim d <> "" -> String.trim d
             | _ -> Filename.concat home ".local/share/c2c/instances"
           in
           let pid_path = Filename.concat (Filename.concat instances_dir name) "outer.pid" in
           let ok =
             if not (Sys.file_exists pid_path) then false
             else
               try
                 let ic = open_in pid_path in
                 let line = try input_line ic with End_of_file -> "" in
                 close_in_noerr ic;
                 match int_of_string_opt (String.trim line) with
                 | Some pid ->
                   (try Unix.kill pid Sys.sigterm; true
                    with Unix.Unix_error _ -> false)
                 | None -> false
               with _ -> false
           in
           let content =
             `Assoc [ ("ok", `Bool ok); ("name", `String name); ("reason", `String reason);
                      ("pid_path", `String pid_path) ]
             |> Yojson.Safe.to_string
           in
            Lwt.return (tool_result ~content ~is_error:(not ok)))
  | "memory_list" ->
      let memory_base_dir alias =
        let git_dir =
          let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
          try
            let line = input_line ic in
            ignore (Unix.close_process_in ic);
            Some line
          with _ -> ignore (Unix.close_process_in ic); None
        in
        let base = match git_dir with
          | Some d -> Filename.dirname d
          | None -> Sys.getcwd ()
        in
        Filename.concat (Filename.concat base ".c2c") "memory" |> fun d -> Filename.concat d alias
      in
      let entry_path alias name =
        let safe = Stdlib.String.map (fun c ->
          match c with
          | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
          | _ -> let code = Char.code c in
                 if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code = 95 || code = 45
                 then c else '_')
          name
        in
        Filename.concat (memory_base_dir alias) (safe ^ ".md")
      in
      let parse_frontmatter content =
        let lines = String.split_on_char '\n' content in
        let rec parse lines in_fm name desc shared acc =
          match lines with
          | [] -> (name, desc, shared, List.rev acc)
          | line :: rest ->
              let line = String.trim line in
              if line = "---" then parse rest (not in_fm) name desc shared acc
              else if in_fm then
                if 0 = String.length line then parse rest in_fm name desc shared acc
                else if Str.string_match (Str.regexp "^name:[ ]*\\(.+\\)$") line 0
                then parse rest in_fm (Some (Str.matched_group 1 line)) desc shared acc
                else if Str.string_match (Str.regexp "^description:[ ]*\\(.+\\)$") line 0
                then parse rest in_fm name (Some (Str.matched_group 1 line)) shared acc
                else if Str.string_match (Str.regexp "^shared:[ ]*\\(true\\|false\\)$") line 0
                then parse rest in_fm name desc (Str.matched_group 1 line = "true") acc
                else parse rest in_fm name desc shared acc
              else parse rest in_fm name desc shared (line :: acc)
        in
        parse lines false None None false []
      in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_member_alias_result "memory_list")
       | Some alias ->
           let dir = memory_base_dir alias in
           let entries =
             try
               Array.to_list (Sys.readdir dir)
               |> List.filter (fun n -> String.length n > 3 && String.sub n (String.length n - 3) 3 = ".md")
               |> List.sort String.compare
             with Sys_error _ -> []
           in
           let items = List.map (fun name ->
             let path = Filename.concat dir name in
             let content =
               try
                 let ic = open_in path in
                 Fun.protect ~finally:(fun () -> close_in ic)
                   (fun () -> really_input_string ic (in_channel_length ic))
               with _ -> ""
             in
             let (mname, desc, shared, _) = parse_frontmatter content in
             `Assoc (
               ("name", match mname with Some n -> `String n | None -> `Null)
               :: ("description", match desc with Some d -> `String d | None -> `Null)
               :: ("shared", `Bool shared)
               :: []))
             entries
           in
           Lwt.return (tool_result ~content:(`List items |> Yojson.Safe.to_string) ~is_error:false))
  | "memory_read" ->
      let memory_base_dir alias =
        let git_dir =
          let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
          try
            let line = input_line ic in
            ignore (Unix.close_process_in ic);
            Some line
          with _ -> ignore (Unix.close_process_in ic); None
        in
        let base = match git_dir with
          | Some d -> Filename.dirname d
          | None -> Sys.getcwd ()
        in
        Filename.concat (Filename.concat base ".c2c") "memory" |> fun d -> Filename.concat d alias
      in
      let entry_path alias name =
        let safe = Stdlib.String.map (fun c ->
          match c with
          | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
          | _ -> let code = Char.code c in
                 if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code = 95 || code = 45
                 then c else '_')
          name
        in
        Filename.concat (memory_base_dir alias) (safe ^ ".md")
      in
      let parse_frontmatter content =
        let lines = String.split_on_char '\n' content in
        let rec parse lines in_fm name desc shared acc =
          match lines with
          | [] -> (name, desc, shared, List.rev acc)
          | line :: rest ->
              let line = String.trim line in
              if line = "---" then parse rest (not in_fm) name desc shared acc
              else if in_fm then
                if 0 = String.length line then parse rest in_fm name desc shared acc
                else if Str.string_match (Str.regexp "^name:[ ]*\\(.+\\)$") line 0
                then parse rest in_fm (Some (Str.matched_group 1 line)) desc shared acc
                else if Str.string_match (Str.regexp "^description:[ ]*\\(.+\\)$") line 0
                then parse rest in_fm name (Some (Str.matched_group 1 line)) shared acc
                else if Str.string_match (Str.regexp "^shared:[ ]*\\(true\\|false\\)$") line 0
                then parse rest in_fm name desc (Str.matched_group 1 line = "true") acc
                else parse rest in_fm name desc shared acc
              else parse rest in_fm name desc shared (line :: acc)
        in
        parse lines false None None false []
      in
      let name = string_member "name" arguments in
      (* Caller's own registered alias for the current session. Required to
         enforce the cross-agent privacy guard below — without a current alias
         we cannot tell whether a read is "self" or "other". *)
      let caller_alias =
        match current_registered_alias ?session_id_override broker with
        | Some a -> Some a
        | None -> auto_register_alias ()
      in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_member_alias_result "memory_read")
       | Some alias ->
           let path = entry_path alias name in
           if not (Sys.file_exists path) then
             Lwt.return (tool_result ~content:("memory entry not found: " ^ name) ~is_error:true)
           else
             let content =
               try
                 let ic = open_in path in
                 Fun.protect ~finally:(fun () -> close_in ic)
                   (fun () -> really_input_string ic (in_channel_length ic))
               with _ -> ""
             in
             if content = "" then
               Lwt.return (tool_result ~content:("error reading memory entry: " ^ name) ~is_error:true)
             else
               let (mname, desc, shared, body) = parse_frontmatter content in
               (* Privacy guard: cross-agent reads of private (shared:false)
                  entries are refused. Self-reads bypass. If we cannot resolve
                  the caller's alias and the target is not shared, refuse — the
                  fail-closed default is safer than leaking. *)
               let is_self =
                 match caller_alias with
                 | Some a -> a = alias
                 | None -> false
               in
               if (not is_self) && (not shared) then
                 Lwt.return (tool_result
                   ~content:(Printf.sprintf
                     "memory entry '%s' in alias '%s' is private (shared: false). \
                      Cross-agent reads require shared:true."
                     name alias)
                   ~is_error:true)
               else
                 let result = `Assoc [
                   ("alias", `String alias);
                   ("name", match mname with Some n -> `String n | None -> `Null);
                   ("description", match desc with Some d -> `String d | None -> `Null);
                   ("shared", `Bool shared);
                   ("content", `String (String.concat "\n" body))
                 ] |> Yojson.Safe.to_string in
                 Lwt.return (tool_result ~content:result ~is_error:false))
  | "memory_write" ->
      let memory_base_dir alias =
        let git_dir =
          let ic = Unix.open_process_in "git rev-parse --git-common-dir 2>/dev/null" in
          try
            let line = input_line ic in
            ignore (Unix.close_process_in ic);
            Some line
          with _ -> ignore (Unix.close_process_in ic); None
        in
        let base = match git_dir with
          | Some d -> Filename.dirname d
          | None -> Sys.getcwd ()
        in
        Filename.concat (Filename.concat base ".c2c") "memory" |> fun d -> Filename.concat d alias
      in
      let entry_path alias name =
        let safe = Stdlib.String.map (fun c ->
          match c with
          | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
          | _ -> let code = Char.code c in
                 if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code = 95 || code = 45
                 then c else '_')
          name
        in
        Filename.concat (memory_base_dir alias) (safe ^ ".md")
      in
      let name = string_member "name" arguments in
      let desc = optional_string_member "description" arguments in
      let shared =
        try match arguments |> Yojson.Safe.Util.member "shared" with `Bool b -> b | _ -> false
        with _ -> false
      in
      let body_content = string_member "content" arguments in
      (match alias_for_current_session_or_argument ?session_id_override broker arguments with
       | None -> Lwt.return (missing_member_alias_result "memory_write")
       | Some alias ->
           let dir = memory_base_dir alias in
           let rec mkdir_p d =
             if not (Sys.file_exists d) then (
               (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
               mkdir_p (Filename.dirname d))
           in
           mkdir_p (Filename.dirname dir);
           if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
           let path = entry_path alias name in
           let fm_content = Printf.sprintf "---\nname: %s\ndescription: %s\nshared: %b\n---\n%s\n"
             name (Option.value desc ~default:"") shared body_content in
           try
             let oc = open_out path in
             Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
               output_string oc fm_content);
             let result = `Assoc [("saved", `String name)] |> Yojson.Safe.to_string in
             Lwt.return (tool_result ~content:result ~is_error:false)
           with _ ->
             Lwt.return (tool_result ~content:("error writing memory entry: " ^ name) ~is_error:true))
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

(* --- prompts/list and prompts/get helpers ---------------------------------

   Frontmatter (YAML between --- markers) is always at the top of SKILL.md.
   20 lines is sufficient to capture name + description from any skill file.
   SKILL.md bodies start after the second --- which is well within this limit.
*)

let skills_dir () =
  let top = match Git_helpers.git_common_dir_parent () with
    | Some t -> t
    | None -> Sys.getcwd ()
  in
  Filename.concat (Filename.concat top ".opencode") "skills"

let list_skills () =
  let dir = skills_dir () in
  try
    Array.to_list (Sys.readdir dir)
    |> List.filter (fun name ->
      let path = Filename.concat dir name in
      try Sys.is_directory path with _ -> false)
  with _ -> []

let parse_skill_frontmatter dir name =
  let skill_md = Filename.concat dir (Filename.concat name "SKILL.md") in
  try
    let ic = open_in skill_md in
    let lines = ref [] in
    let in_frontmatter = ref false in
    let name_ref = ref None in
    let desc_ref = ref None in
    let strip_quotes s =
      let len = String.length s in
      if len >= 2 && s.[0] = '"' && s.[len - 1] = '"'
      then String.sub s 1 (len - 2)
      else s
    in
    (try
       for _i = 1 to 20 do
         match input_line ic with
         | line ->
             let line = String.trim line in
             if line = "---" then in_frontmatter := not !in_frontmatter
             else if !in_frontmatter then
               (if Str.string_match (Str.regexp "^name:[ ]*\\([^ ].*\\)$") line 0
                then name_ref := Some (Str.matched_group 1 line)
                else if Str.string_match (Str.regexp "^description:[ ]*\\(\".*\"\\)$") line 0
                then desc_ref := Some (strip_quotes (Str.matched_group 1 line))
                else if Str.string_match (Str.regexp "^description:[ ]*\\([^ ].*\\)$") line 0
                then desc_ref := Some (Str.matched_group 1 line));
             lines := line :: !lines
         | exception End_of_file -> ()
       done;
     with _ -> ());
    close_in_noerr ic;
    (!name_ref, !desc_ref)
  with _ -> (None, None)

let get_skill_content dir name =
  let skill_md = Filename.concat dir (Filename.concat name "SKILL.md") in
  try
    let ic = open_in skill_md in
    let content = ref "" in
    (try
       while true do
         content := !content ^ input_line ic ^ "\n"
       done
     with End_of_file -> close_in ic | _ -> close_in_noerr ic);
    String.trim !content
  with _ -> ""

let list_skills_as_prompts () =
  let dir = skills_dir () in
  let names = list_skills () in
  List.map (fun name ->
    let (_, desc) = parse_skill_frontmatter dir name in
    `Assoc
      (("name", `String name)
       :: (match desc with Some d -> [("description", `String d)] | None -> []))
  ) names

let get_skill name =
  let dir = skills_dir () in
  let names = list_skills () in
  if not (List.mem name names) then None
  else
    let (_, desc) = parse_skill_frontmatter dir name in
    let content = get_skill_content dir name in
    let description = match desc with Some d -> d | None -> name in
    Some (description, content)

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
      let session_id_override =
        request_session_id_override ~broker_root ~tool_name ~params
      in
      ensure_request_session_bootstrap ~broker_root ?session_id_override ();
      let open Lwt.Syntax in
      let* result =
        Lwt.catch
          (fun () ->
            handle_tool_call ~broker ?session_id_override ~tool_name ~arguments)
          (fun exn ->
            let msg =
              match exn with
              | Invalid_argument m -> m
              | Yojson.Safe.Util.Type_error (m, _) ->
                  Printf.sprintf "argument type error: %s" m
              | _ -> Printexc.to_string exn
            in
            Lwt.return (tool_result ~content:msg ~is_error:true))
      in
      let is_error =
        (try Yojson.Safe.Util.(result |> member "isError" |> to_bool) with _ -> false)
      in
      log_rpc ~broker_root ~tool_name ~is_error;
      Lwt.return_some (jsonrpc_response ~id result)
  | Some id, "prompts/list" ->
      let prompts = list_skills_as_prompts () in
      Lwt.return_some (jsonrpc_response ~id (`Assoc [("prompts", `List prompts)]))
  | Some id, "prompts/get" ->
      let name = try params |> member "name" |> to_string with _ -> "" in
      (match get_skill name with
       | Some (description, content) ->
           let prompt_msg = `Assoc [("role", `String "user"); ("content", `Assoc [("type", `String "text"); ("text", `String content)])] in
           Lwt.return_some (jsonrpc_response ~id (`Assoc [("description", `String description); ("messages", `List [prompt_msg])]))
       | None ->
           Lwt.return_some (jsonrpc_error ~id ~code:(-32602) ~message:("Unknown skill: " ^ name)))
  | Some id, "ping" ->
      (* MCP protocol keepalive — must respond with empty result, not an error.
         Claude Code sends periodic pings; an error response triggers "server unhealthy"
         and causes the 3-5min disconnect cycle observed in coder2-expert's session. *)
      Lwt.return_some (jsonrpc_response ~id (`Assoc []))
  | Some id, _ ->
      Lwt.return_some (jsonrpc_error ~id ~code:(-32601) ~message:("Unknown method: " ^ method_))
