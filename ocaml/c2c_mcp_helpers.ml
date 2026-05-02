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
       The matching secret lives in ~/.config/c2c/keys/<alias>.x25519 mode 0600.
       Known v1 limitation (M1 threat model): mode 0600 does not protect against
       other processes running as the same Unix user (including child agents).
       OS keyring integration deferred to M3. *)
   ; ed25519_pubkey : string option
   (** Ed25519 public key (base64url, 32 bytes) for message signing.
       Published in the registry so recipients can verify envelope sigs.
       The matching secret lives in <broker_root>/keys/<alias>.ed25519 mode 0600.
       Proves the owner holds the matching private key via [pubkey_sig]. *)
   ; pubkey_signed_at : float option
   (** Epoch when [pubkey_sig] was computed (Unix.gettimeofday at sign time).
       Used to detect stale pubkeys and for replay-window checks. *)
   ; pubkey_sig : string option
   (** Ed25519 sig over canonical blob:
       alias || ed25519_pk || x25519_pk || pubkey_signed_at
       (joined with ASCII 0x1F unit separator).
       Signed by the Ed25519 private key. Proves the owner holds both private keys. *)
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
  ; automated_delivery : bool option
   (** [Some true] = client negotiated [experimental.claude/channel] in
       MCP initialize and receives messages via push (no manual poll
       needed). [Some false] = explicitly negotiated without channel
       support. [None] = unknown (pre-Phase compat or the session has
       not yet handshaked). Set in the initialize handler; consumers
       treat [None] conservatively as "not push-capable". *)
    ; tmux_location : string option
    (** Tmux session:window.pane target for the pane running this session.
        Captured at registration time for managed sessions (c2c start);
        None for unmanaged / foreign MCP clients. Format: "session:window.pane". *)
    ; cwd : string option
    (** Working directory of the session at registration time.
        Captured via Sys.getcwd () at register time. Used by Hardening B
        (shell-launch-location guard) to detect when a session's shell cwd
        differs from its registered worktree — a signal of main-tree
        branch contamination (Pattern 6/13/14). *)
    }
type message = { from_alias : string; to_alias : string; content : string; deferrable : bool; reply_via : string option; enc_status : string option; ts : float; ephemeral : bool; message_id : string option }
(** [message_id] is set when the message arrived via the relay (which assigns
    a UUID to every sent message). It is used to anchor sticker reactions:
    a reaction references the original message via its [message_id]. *)
(** [ephemeral=true] messages are delivered normally but skipped on the
    archive append in [drain_inbox] / [drain_inbox_push]. The recipient's
    in-memory channel notification + transcript are the only persistent
    trace post-delivery. Default false (#284). *)
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }
type room_visibility = Public | Invite_only
type room_meta =
  { visibility : room_visibility
  ; invited_members : string list
  ; created_by : string
    (** Alias of the room creator. Empty string for legacy rooms whose
        meta.json predates the field; legacy rooms can only be deleted
        with [~force:true] (#H3 rooms-acl audit). #394 creates rooms
        with [created_by] populated; legacy continues to read as "". *)
  }

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
  (* slice/coord-backup-fallthrough: per-tier fire timestamps. Indexed
     parallel to the chain-effective supervisors list (see
     Coord_fallthrough). [Some _] → that tier already fired (used to
     prevent double-fire across scheduler ticks); [None] → tier is
     still eligible. Length is independent of supervisors length —
     scheduler reads coord_chain config at tick time. Persisted as
     null-or-float in JSON; absent in legacy entries → []. *)
  ; fallthrough_fired_at : float option list
  (* slice/coord-backup-fallthrough: when a supervisor's
     check_pending_reply landed valid=true, the broker stamps this so
     later fallthrough ticks skip the entry. Late primary reply →
     stamp; early backup reply → stamp. First valid reply wins. *)
  ; resolved_at : float option
  }

(** Recursive idempotent mkdir. Creates [d] and all missing parents.
    Tolerates EEXIST races (concurrent creators). Canonical filesystem
    helper reused by [Broker.ensure_root], the MCP [memory_write] handler,
    and [C2c_memory.ensure_memory_dir] (#396 dedup of #332 peer-PASS note). *)
let rec mkdir_p d =
  if d = "" || d = "/" || d = "." then ()
  else if Sys.file_exists d then ()
  else begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let pending_kind_to_string = function Permission -> "permission" | Question -> "question"
let pending_kind_of_string = function "question" -> Question | _ -> Permission

let float_opt_to_json = function
  | None -> `Null
  | Some f -> `Float f

let json_to_float_opt = function
  | `Null -> None
  | `Float f -> Some f
  | `Int i -> Some (float_of_int i)
  | _ -> None

let pending_permission_to_json p =
  `Assoc
    [ ("perm_id", `String p.perm_id)
    ; ("kind", `String (pending_kind_to_string p.kind))
    ; ("requester_session_id", `String p.requester_session_id)
    ; ("requester_alias", `String p.requester_alias)
    ; ("supervisors", `List (List.map (fun s -> `String s) p.supervisors))
    ; ("created_at", `Float p.created_at)
    ; ("expires_at", `Float p.expires_at)
    ; ("fallthrough_fired_at",
        `List (List.map float_opt_to_json p.fallthrough_fired_at))
    ; ("resolved_at", float_opt_to_json p.resolved_at)
    ]

let pending_permission_of_json json =
  let open Yojson.Safe.Util in
  let fallthrough_fired_at =
    (* slice/coord-backup-fallthrough: backward-compat — legacy entries
       written before this slice have no field. Default to []. *)
    match member "fallthrough_fired_at" json with
    | `Null -> []
    | `List xs -> List.map json_to_float_opt xs
    | _ -> []
  in
  let resolved_at =
    match member "resolved_at" json with
    | `Null -> None
    | other -> json_to_float_opt other
  in
  { perm_id = json |> member "perm_id" |> to_string
  ; kind = json |> member "kind" |> to_string |> pending_kind_of_string
  ; requester_session_id = json |> member "requester_session_id" |> to_string
  ; requester_alias = json |> member "requester_alias" |> to_string
  ; supervisors = json |> member "supervisors" |> to_list |> List.map Yojson.Safe.Util.to_string
  ; created_at = json |> member "created_at" |> to_float
  ; expires_at = json |> member "expires_at" |> to_float
  ; fallthrough_fired_at
  ; resolved_at
  }

(* Debug output — gated by C2C_MCP_DEBUG env var *)
let debug_enabled =
  match Sys.getenv_opt "C2C_MCP_DEBUG" with
  | Some v ->
      let n = String.lowercase_ascii (String.trim v) in
      not (List.mem n [ "0"; "false"; "no"; "" ])
  | None -> false

let server_version = Version.version

(* #429a: replace the ~796ms shell-out at module-load with the
   compile-time-baked SHA from #420. The previous body forked
   `git rev-parse --short HEAD` every time c2c_mcp.ml was linked
   (which is every CLI invocation, not just MCP). Per the #429
   init-cost investigation, this single binding was the largest
   single contributor to `c2c --version` wall-clock — ~796ms for
   a value that's already embedded in the binary at build time
   via the Version_git_sha dune rule.

   Behavior preserved: RAILWAY_GIT_COMMIT_SHA env override still
   wins for prod-build identification when set; otherwise
   Version.git_sha (8-char compile-time hash) is used. The
   "unknown" fallback now propagates from Version_git_sha when
   the build itself couldn't get a hash (source tarballs, sandboxed
   builds without git, etc). *)
let server_git_hash =
  match Sys.getenv_opt "RAILWAY_GIT_COMMIT_SHA" with
  | Some sha when String.length sha >= 7 -> String.sub sha 0 7
  | _ -> Version.git_sha

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

let server_started_at = Unix.gettimeofday ()

let best_effort_server_executable () =
  match Unix.readlink "/proc/self/exe" with
  | path -> path
  | exception _ ->
      if Array.length Sys.argv > 0 && Sys.argv.(0) <> "" then Sys.argv.(0)
      else "unknown"

let best_effort_file_sha256 path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        really_input_string ic len
        |> Digestif.SHA256.digest_string
        |> Digestif.SHA256.to_hex)
  with _ -> "unknown"

(* #429b: lazy-wrap server_runtime_identity. The SHA-256 of the c2c
   binary (~23 MB) takes ~690ms CPU at module-load time. Per the
   #429 init-cost investigation, this was the second-largest single
   contributor to `c2c --version` wall-clock — a value used ONLY by
   the MCP server_info tool (mcp__c2c__server_info / initialize),
   never by any CLI subcommand.

   Wrapping in `lazy` defers the SHA-256 computation until first
   reference. The MCP handler forces it on the first server_info
   call (i.e. immediately after `initialize`), so MCP startup pays
   the cost once, but every CLI invocation skips it.

   Behavior preserved post-force: identical JSON shape, same fields,
   same values. Pre-force (e.g. on the CLI fast-path), the value is
   never observed and the cost is never paid. *)
let server_runtime_identity_lazy = lazy (
  let executable = best_effort_server_executable () in
  let executable_mtime =
    try `Float (Unix.stat executable).st_mtime with _ -> `Null
  in
  `Assoc
    [ ("schema", `Int 1)
    ; ("pid", `Int (Unix.getpid ()))
    ; ("started_at", `Float server_started_at)
    ; ("executable", `String executable)
    ; ("executable_mtime", executable_mtime)
    ; ("executable_sha256", `String (best_effort_file_sha256 executable))
    ]
)

(* #429b: server_info itself is also `lazy` because runtime_identity
   feeds it. Forcing server_info forces both fields. The MCP handler
   pattern is: pattern-match on Lazy.force server_info_lazy at the
   `initialize` site (or wherever server_info is consumed). *)
let server_info_lazy = lazy (
  `Assoc
    [ ("name", `String "c2c")
    ; ("version", `String server_version)
    ; ("git_hash", `String server_git_hash)
    ; ("features", `List (List.map (fun f -> `String f) server_features))
    ; ("runtime_identity", Lazy.force server_runtime_identity_lazy)
    ]
)

(* Existing readers of `server_info` (CLI server-info subcommand,
   MCP initialize, MCP server_info tool, fast-path) call this thunk
   instead of accessing a top-level JSON value. The cost moves from
   module-load to first-reference; on the CLI fast-path that's
   never paid. *)
let server_info () = Lazy.force server_info_lazy

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

let tool_result ~content ~is_error =
  `Assoc
    [ ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String content) ] ])
    ; ("isError", `Bool is_error)
    ]

(* Smart constructors for the common tool_result shapes (audit 2026-04-29 §4).
   Cuts ~50 raw [tool_result ~content:... ~is_error:...] sites down to
   one-arg helpers; messages stay readable, the boilerplate goes. *)
let tool_ok content = tool_result ~content ~is_error:false
let tool_err content = tool_result ~content ~is_error:true

(* Default TTL (seconds) for a pending permission request when
   C2C_PERMISSION_TTL is unset or unparseable. Used by the
   open_pending_reply handler. Audit 2026-04-29 §5. *)
let default_permission_ttl_s = 600.0

(* Shared memory-helpers used by memory_list / memory_read / memory_write
   handlers AND by the CLI memory commands (cli/c2c_memory.ml re-exports).
   Single source of truth for [.c2c/memory/<alias>/<name>.md] resolution.

   [C2C_MEMORY_ROOT_OVERRIDE]: test hook — when set (and non-empty after
   trim), replaces the [.c2c/memory] root. Production agents never set
    this; the in-repo path is canonical. *)
let memory_root_uncached () =
  match Sys.getenv_opt "C2C_MEMORY_ROOT_OVERRIDE" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
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
      Filename.concat (Filename.concat base ".c2c") "memory"

(* #388 Finding 2: cache the git-committed memory root at first call.
   Git root never changes at runtime for a given process, so a simple
   unconditional one-time cache is correct. OCaml's GIL-equivalent
   runtime makes the ref single-threaded-safe.

   The C2C_MEMORY_ROOT_OVERRIDE test hook is read fresh every call —
   never cached — so that tests can switch between temporary dirs.
   Only the auto-detected (git-based) root is memoised. *)
let memory_root =
  let cache = ref None in
  fun () ->
    match Sys.getenv_opt "C2C_MEMORY_ROOT_OVERRIDE" with
    | Some d when String.trim d <> "" -> String.trim d
    | _ ->
        match !cache with
        | Some v -> v
        | None ->
            let v = memory_root_uncached () in
            cache := Some v; v

let memory_base_dir alias =
  Filename.concat (memory_root ()) alias

let memory_entry_path alias name =
  let safe = Stdlib.String.map (fun c ->
    match c with
    | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
    | _ -> let code = Char.code c in
           if (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code = 95 || code = 45
           then c else '_')
    name
  in
  Filename.concat (memory_base_dir alias) (safe ^ ".md")

(* Shared schedule-helpers used by cli/c2c_schedule.ml.
   Single source of truth for [.c2c/schedules/<alias>/<name>.toml] resolution.

   [C2C_SCHEDULE_ROOT_OVERRIDE]: test hook — when set (and non-empty after
   trim), replaces the [.c2c/schedules] root. Production agents never set
   this; the in-repo path is canonical. *)
let schedule_root_uncached () =
  match Sys.getenv_opt "C2C_SCHEDULE_ROOT_OVERRIDE" with
  | Some d when String.trim d <> "" -> String.trim d
  | _ ->
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
      Filename.concat (Filename.concat base ".c2c") "schedules"

let schedule_root =
  let cache = ref None in
  fun () ->
    match Sys.getenv_opt "C2C_SCHEDULE_ROOT_OVERRIDE" with
    | Some d when String.trim d <> "" -> String.trim d
    | _ ->
        match !cache with
        | Some v -> v
        | None ->
            let v = schedule_root_uncached () in
            cache := Some v; v

let schedule_base_dir alias =
  Filename.concat (schedule_root ()) alias

let schedule_entry_path alias name =
  let safe = Stdlib.String.map (fun c ->
    match c with
    | ' ' | '/' | '\\' | ':' | '"' | '\'' -> '_'
    | _ -> let code = Char.code c in
           if (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
              || (code >= 97 && code <= 122) || code = 95 || code = 45
           then c else '_')
    name
  in
  Filename.concat (schedule_base_dir alias) (safe ^ ".toml")

(* Property schema helpers for tool inputSchema declarations *)
let prop name description =
  (name, `Assoc [("type", `String "string"); ("description", `String description)])

let bool_prop name description =
  (name, `Assoc [("type", `String "boolean"); ("description", `String description)])

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

(** Re-export of the canonical [mkdir_p] (lives in [C2c_io] so it is
    reachable from every module in the [c2c_mcp] library — including
    relay/relay_identity/c2c_start which compile before [c2c_mcp]).
    Kept here for source-compat with #400 callers. *)
let mkdir_p ?(mode = 0o755) dir = C2c_io.mkdir_p ~mode dir

(* #392 — body-prefix helpers for tagged DMs. Body text is the
   load-bearing channel (agents READ body text on every client surface;
   envelope attributes are invisible at the read layer). Sender CLI +
   MCP send handler both prepend the prefix at send-time so the broker-
   stored content carries the marker through every delivery surface
   without per-client rendering hooks. *)
let tag_to_body_prefix = function
  | Some "fail"     -> "\xF0\x9F\x94\xB4 FAIL: "       (* 🔴 *)
  | Some "blocking" -> "\xE2\x9B\x94 BLOCKING: "       (* ⛔ *)
  | Some "urgent"   -> "\xE2\x9A\xA0\xEF\xB8\x8F URGENT: "  (* ⚠️ *)
  | _ -> ""

(* Inverse of [tag_to_body_prefix]: detect a #392 body-prefix on an
   already-stored message and recover the tag name. Used by the
   envelope-formatter so re-delivery surfaces (PostToolUse hook,
   inbox-hook tool, wire-bridge) can carry the tag attribute even when
   the message was archived without it explicitly attached.

   Earlier draft of this function compared [String.sub content 0 5]
   against multibyte prefixes whose lengths are 11/14/15 bytes — that
   could never match. Always check against the actual byte length of
   each prefix (call [tag_to_body_prefix] and compare prefix). *)
let extract_tag_from_content content =
  let try_prefix tag =
    let prefix = tag_to_body_prefix (Some tag) in
    let plen = String.length prefix in
    if plen > 0
       && String.length content >= plen
       && String.sub content 0 plen = prefix
    then Some tag
    else None
  in
  match try_prefix "fail" with
  | Some _ as r -> r
  | None ->
    match try_prefix "blocking" with
    | Some _ as r -> r
    | None -> try_prefix "urgent"

let parse_send_tag = function
  | None -> Ok None
  | Some "" -> Ok None
  | Some ("fail" | "blocking" | "urgent" as t) -> Ok (Some t)
  | Some other ->
    Error (Printf.sprintf
             "unknown tag '%s' — must be one of: fail, blocking, urgent"
             other)

let xml_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (function
    | '&' -> Buffer.add_string buf "&amp;"
    | '<' -> Buffer.add_string buf "&lt;"
    | '>' -> Buffer.add_string buf "&gt;"
    | '"' -> Buffer.add_string buf "&quot;"
    | '\'' -> Buffer.add_string buf "&#39;"
    | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

(** Format a Unix timestamp as UTC HH:MM. Used for ts attributes and
    channel notification meta. Shared helper to prevent format drift. *)
let format_ts_hhmm (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min

let format_c2c_envelope ~from_alias ~to_alias ?tag ?role ?reply_via ?ts ~content () =
  let tag_attr = match tag with
    | Some t -> Printf.sprintf " tag=\"%s\"" (xml_escape t)
    | None -> ""
  in
  let role_attr = match role with
    | Some r -> Printf.sprintf " role=\"%s\"" (xml_escape r)
    | None -> ""
  in
  let ts_attr = match ts with
    | Some t -> Printf.sprintf " ts=\"%s\"" (format_ts_hhmm t)
    | None -> ""
  in
  let reply_via_str = xml_escape (Option.value reply_via ~default:"c2c_send") in
  Printf.sprintf
    "<c2c event=\"message\" from=\"%s\" to=\"%s\" source=\"broker\" reply_via=\"%s\" action_after=\"continue\"%s%s%s>\n%s\n</c2c>"
    (xml_escape from_alias)
    (xml_escape to_alias)
    reply_via_str
    role_attr
    tag_attr
    ts_attr
    content

(* Parse a YAML-flow list value (e.g. "[alice, bob]" or "[]") into a string
   list. Also accepts a bare comma-separated form ("alice, bob") for
   resilience. Whitespace and surrounding quotes are stripped, empties
   dropped. Used by memory frontmatter parsers in both the CLI and the
   MCP server. (#296: deduplicates three identical copies.) *)
let parse_alias_list raw =
  let s = String.trim raw in
  let stripped =
    if String.length s >= 2 && s.[0] = '[' && s.[String.length s - 1] = ']'
    then String.sub s 1 (String.length s - 2)
    else s
  in
  String.split_on_char ',' stripped
  |> List.map String.trim
  |> List.map (fun a ->
       let n = String.length a in
       if n >= 2
          && ((a.[0] = '"' && a.[n-1] = '"')
              || (a.[0] = '\'' && a.[n-1] = '\''))
       then String.sub a 1 (n - 2)
       else a)
  |> List.filter (fun a -> a <> "")

(* #388 deduplication: one shared writer for all structured broker.log
   audit lines. Each named logger delegates here instead of repeating
   the try/ts/path/Yojson/append_jsonl pattern. Best-effort: audit
   failures must never block the broker's primary path. *)
let log_broker_event ~broker_root event_name fields =
  try
    let path = Filename.concat broker_root "broker.log" in
    let line =
      `Assoc (("event", `String event_name) :: fields)
      |> Yojson.Safe.to_string
    in
    C2c_io.append_jsonl path line
  with _ -> ()
