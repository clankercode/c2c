val server_version : string
val server_git_hash : string
val server_info : unit -> Yojson.Safe.t
(** [#429b] Lazy server_info — first call forces SHA-256 of the running
    binary (~690ms) and caches the result. CLI subcommands that don't
    need server_info never pay the cost. *)

val mkdir_p : ?mode:int -> string -> unit
(** Re-export of the canonical [C2c_io.mkdir_p]. Kept for source-compat
    with #400 callers. Default mode 0o755; idempotent on EEXIST. *)

val tag_to_body_prefix : string option -> string
(** [#392] Map a tag value (or [None]) to a body prefix that surfaces
    visually in the agent's transcript. The body is the load-bearing
    channel — agents READ body text on every client surface (Claude,
    Codex, OpenCode, Kimi), whereas envelope attributes are invisible
    at the read layer. Currently:

      - [Some "fail"]     → ["🔴 FAIL: "]
      - [Some "blocking"] → ["⛔ BLOCKING: "]
      - [Some "urgent"]   → ["⚠️ URGENT: "]
      - [None] / unknown  → [""]

    Sender CLI ([c2c send --fail|--blocking|--urgent]) and MCP
    [send] tool both call this, so the prefix is captured once at
    sender-time and embedded in the broker-stored content. *)

val parse_send_tag : string option -> (string option, string) result
(** [#392] Validate a user-supplied tag value. [None] → [Ok None]
    (no tag). [Some "fail"|"blocking"|"urgent"] → [Ok (Some _)].
    Anything else → [Error msg] with a human-readable rejection. *)

val xml_escape : string -> string
(** Escape [&amp;, &lt;, &gt;, &quot;, &apos;] for XML attribute values. *)

val extract_tag_from_content : string -> string option
(** [#392b] Inverse of [tag_to_body_prefix] — recognize a known body
    prefix and return the abstract tag. *)

val format_c2c_envelope : from_alias:string -> to_alias:string -> ?tag:string -> ?role:string -> ?reply_via:string -> ?ts:float -> content:string -> unit -> string
(** [#392b] Canonical c2c message envelope formatter. Optional [tag]
    surfaces FAIL/BLOCKING/URGENT to programmatic consumers. *)

type compacting = { started_at : float; reason : string option }
type registration =
  { session_id : string
  ; alias : string
  ; pid : int option
  ; pid_start_time : int option
  ; registered_at : float option
  ; canonical_alias : string option
  (** Fully-qualified form: "<alias>#<repo>@<host>". None for pre-Phase-1 rows. *)
  ; dnd : bool
  ; dnd_since : float option
  ; dnd_until : float option
  ; client_type : string option
   (** "human" exempts from provisional sweep; None = agent (default). *)
   ; plugin_version : string option
   (** Version string of the c2c plugin/hook running this session.
       Used to detect stale plugins that may have known bugs. *)
   ; confirmed_at : float option
  (** Epoch of first poll_inbox call. None = session registered but never
      drained — still "provisional". *)
  ; enc_pubkey : string option
  (** X25519 public key (base64url, 32 bytes) for E2E encryption.
      Published in the registry so recipients can encrypt DMs.
      Secret stored in [~/.c2c/keys/<session_id>.x25519] mode 0600.
      Known v1 limitation (M1 threat model §I1): mode 0600 does not protect
      against other processes running as the same Unix user (including child
      agents). OS keyring integration deferred to M3. *)
  ; compacting : compacting option
  ; last_activity_ts : float option
  (** Epoch of the session's most recent broker interaction. None = Phase 0
      compatibility (session predates this field). *)
  ; role : string option
  (** Sender role for envelope attribution. None = no role. *)
  ; compaction_count : int
  (** Cumulative count of compacting→idle transitions. Defaults to 0. *)
  ; automated_delivery : bool option
  (** [Some true] = client negotiated [experimental.claude/channel] in
      MCP initialize and receives messages via push (no manual poll
      needed). [Some false] = explicitly negotiated without channel
      support. [None] = unknown / pre-Phase compat. Conservative
      consumers treat [None] as "not push-capable". *)
  }
type message =
  { from_alias : string
  ; to_alias : string
  ; content : string
  ; deferrable : bool
  ; reply_via : string option
  ; enc_status : string option
  ; ts : float
  ; ephemeral : bool
    (** [ephemeral=true] messages are delivered normally but skipped on the
        archive append in [drain_inbox] / [drain_inbox_push]. The recipient's
        in-memory channel notification + transcript are the only persistent
        trace post-delivery. Default false. v1 covers local delivery only;
        cross-host ephemeral over the relay is a follow-up (#284). *)
  ; message_id : string option
    (** Set when the message arrived via the relay (which assigns a UUID).
        Used to anchor sticker reactions. *)
  }
type room_member = { rm_alias : string; rm_session_id : string; joined_at : float }
type room_message = { rm_from_alias : string; rm_room_id : string; rm_content : string; rm_ts : float }
type room_visibility = Public | Invite_only
type room_meta =
  { visibility : room_visibility
  ; invited_members : string list
  ; created_by : string
    (** Alias of the room creator. Empty string for legacy rooms whose
        meta.json predates the field. Used to gate [delete_room]
        (#H3 rooms-acl audit). #394 populates on create. *)
  }

type pending_kind = | Permission | Question
val pending_kind_to_string : pending_kind -> string
val pending_kind_of_string : string -> pending_kind
type pending_permission =
  { perm_id : string
  ; kind : pending_kind
  ; requester_session_id : string
  ; requester_alias : string
  ; supervisors : string list
  ; created_at : float
  ; expires_at : float
  ; fallthrough_fired_at : float option list
    (** slice/coord-backup-fallthrough: per-tier fire timestamps.
        Indexed parallel to the coord-chain. [Some _] → tier already
        fired; [None] → still eligible. Empty list on legacy entries. *)
  ; resolved_at : float option
    (** slice/coord-backup-fallthrough: stamped by [check_pending_reply]
        when a supervisor lands a valid reply. Scheduler skips entries
        with [Some _] so backup tiers don't fire after resolution. *)
  }

val parse_alias_list : string -> string list
(** Parse a YAML-flow list value (e.g. ["[alice, bob]"] or ["[]"]) into a
    string list. Also accepts a bare comma-separated form (["alice, bob"])
    for resilience. Whitespace and surrounding quotes are stripped, empty
    entries dropped. Used by memory frontmatter parsers in CLI + MCP. *)

module Broker : sig
  type t
  val create : root:string -> t
  val root : t -> string
  val reserved_system_aliases : string list
  (** Aliases that cannot be registered by any peer: ["c2c"; "c2c-system"]. *)

  val alias_casefold : string -> string
  (** Canonical alias case-fold helper (currently [String.lowercase_ascii]).
      All alias comparisons inside the broker invariant must compare
      [alias_casefold a = alias_casefold b]. Exported so cross-file callers
      (cli/c2c.ml supervisor reply auth, cli/c2c_memory.ml privacy ACL,
      relay_e2e.ml recipient lookup, etc.) can stay aligned with the
      broker's canonical comparison rather than inlining
      [String.lowercase_ascii]. *)

  (** [#432 Slice E] Relay-e2e TOFU pin accessors. Pins are persisted to
      [<broker_root>/relay_pins.json] (atomic tmp+rename, cross-process
      flock on [relay_pins.json.lock]) so they survive broker restart.
      The in-memory Hashtbls are write-through caches; every call below
      re-reads the disk file under the lock. Exported primarily so tests
      can validate the persistence contract. *)
  val get_pinned_x25519 : string -> string option
  val get_pinned_ed25519 : string -> string option
  val pin_x25519_sync : alias:string -> pk:string -> [ `Already_pinned | `Mismatch | `New_pin ]
  val pin_ed25519_sync : alias:string -> pk:string -> [ `Already_pinned | `Mismatch | `New_pin ]

  val compute_canonical_alias : alias:string -> broker_root:string -> string
  (** [compute_canonical_alias ~alias ~broker_root] returns "<alias>#<repo>@<host>"
      where repo is derived from broker_root path and host is the short hostname. *)

  val suggest_alias_for_alias : t -> alias:string -> string option
  (** [suggest_alias_for_alias t ~alias] returns [Some alias] when [alias] is
      free, [Some "<alias>-<prime>"] when it's taken but a prime-suffixed slot
      is available (up to 5 tries: primes 2,3,5,7,11), or [None] when all
      candidates are exhausted (ALIAS_COLLISION_EXHAUSTED). *)

  val register : t -> session_id:string -> alias:string -> pid:int option -> pid_start_time:int option -> ?client_type:string option -> ?plugin_version:string option -> ?enc_pubkey:string option -> ?role:string option -> unit -> unit
  val list_registrations : t -> registration list
  val save_registrations : t -> registration list -> unit
  val with_registry_lock : t -> (unit -> 'a) -> 'a
  val registration_is_alive : registration -> bool
  val read_pid_start_time : int -> int option
  val capture_pid_start_time : int option -> int option

  val read_proc_environ : int -> (string * string) list option
  (** [read_proc_environ pid] parses /proc/<pid>/environ into a list of
      (key, value) pairs. Returns None on IO error (process gone,
      permission denied, etc). *)

  val discover_live_pid_for_session_with :
    scan_pids:(unit -> int list) ->
    read_environ:(int -> (string * string) list option) ->
    session_id:string ->
    int option
  (** Test-injectable variant of [discover_live_pid_for_session]. *)

  val discover_live_pid_for_session : session_id:string -> int option
  (** Scan /proc for a live process whose [C2C_MCP_SESSION_ID] env var
      matches [session_id]. Returns the lowest-numbered matching pid,
      or None if no match. Used by [refresh_pid_if_dead] to recover
      from TUI-respawn-under-new-pid scenarios where the MCP server's
      original [C2C_MCP_CLIENT_PID] no longer points at a live
      process. *)

  val refresh_pid_if_dead_with :
    scan_pids:(unit -> int list) ->
    read_environ:(int -> (string * string) list option) ->
    t -> session_id:string -> bool
  (** Test-injectable variant of [refresh_pid_if_dead]. *)

  val refresh_pid_if_dead : t -> session_id:string -> bool
  (** If the registration for [session_id] has a dead pid but a live
      process is discoverable via /proc/<pid>/environ matching the
      session_id, update the registration's pid + pid_start_time to
      the live pid and return true. Returns false on no-op (reg
      missing, pidless, already alive, or no replacement discoverable).
      Called automatically from [touch_session] and from
      [resolve_live_session_id_by_alias] on the All_dead branch. *)

  val set_proc_hooks_for_test :
    ?scan_pids:(unit -> int list) ->
    ?read_environ:(int -> (string * string) list option) ->
    unit ->
    unit
  (** Test seam: replace the default /proc scanners used by
      [discover_live_pid_for_session] / [refresh_pid_if_dead] /
      [resolve_live_session_id_by_alias] for the duration of a test.
      Both hooks are independently overridable. Module-global state — a
      single test at a time is the norm in this suite. Call
      [clear_proc_hooks_for_test] in a [Fun.protect] finally to undo. *)

  val clear_proc_hooks_for_test : unit -> unit
  (** Restore real-/proc behaviour for the proc-scan hooks. *)

  type resolve_result =
    | Resolved of string
    | Unknown_alias
    | All_recipients_dead

  val resolve_live_session_id_by_alias : t -> string -> resolve_result
  (** Resolve an alias to a live session_id. Case-insensitive (#432):
      [Foo-Bar] and [foo-bar] match the same registration row. On the
      [All_recipients_dead] branch, attempts pid-refresh self-heal via
      /proc scan. *)

  val enqueue_message : t -> from_alias:string -> to_alias:string -> content:string -> ?deferrable:bool -> ?ephemeral:bool -> unit -> unit
  type send_all_result = { sent_to : string list; skipped : (string * string) list }
  val send_all : t -> from_alias:string -> content:string -> exclude_aliases:string list -> send_all_result
  val read_inbox : t -> session_id:string -> message list
  val save_inbox : t -> session_id:string -> message list -> unit
  val read_orphan_inbox_messages : t -> session_id:string -> message list
  (** Read orphan inbox messages without deleting. Returns [] when the orphan
      inbox does not exist or is empty. *)
  val read_and_delete_orphan_inbox : t -> session_id:string -> message list
  (** Atomically read and delete the orphan inbox. Holds the inbox lock across
      read+delete to prevent a concurrent enqueue from racing between reading
      messages and deleting the file. Returns the messages. *)
  val capture_orphan_for_restart : t -> session_id:string -> int
  (** Atomically capture orphan inbox messages for restart: reads the orphan
      inbox, writes a pending replay file, then deletes the orphan — all under
      the inbox lock.  The pending file is written BEFORE the orphan is deleted,
      so a write failure leaves the orphan intact.  Returns the number of
      messages captured, or 0 if no orphan existed. *)
  val replay_pending_orphan_inbox : t -> session_id:string -> int
  (** Replay messages from broker_root/pending-orphan-replay.<session_id>.json
      into the live inbox. Holds the inbox lock across read+save. Deletes the
      pending file after replay. Returns the number of messages replayed. *)
  val drain_inbox : ?drained_by:string -> t -> session_id:string -> message list
  val drain_inbox_push : ?drained_by:string -> t -> session_id:string -> message list
  val is_session_channel_capable : t -> session_id:string -> bool
  (** Returns [true] iff the registration for [session_id] has its
      [automated_delivery] flag set to [Some true]. Used by inbox-hook
      paths to skip drain when the MCP server's channel watcher will own
      delivery (#387 A2). *)
  val with_inbox_lock : t -> session_id:string -> (unit -> 'a) -> 'a
  type sweep_result = { dropped_regs : registration list; deleted_inboxes : string list; preserved_messages : int }
  val sweep : t -> sweep_result
  val dead_letter_path : t -> string
  type archive_entry = { ae_drained_at : float; ae_from_alias : string; ae_to_alias : string; ae_content : string; ae_deferrable : bool; ae_drained_by : string; ae_message_id : string option }
  val archive_path : t -> session_id:string -> string
  val append_archive : ?drained_by:string -> t -> session_id:string -> messages:message list -> unit
  val read_archive : t -> session_id:string -> limit:int -> archive_entry list
  val find_message_by_id : t -> alias:string -> id_prefix:string -> (archive_entry, string) result
  (** [find_message_by_id t ~alias ~id_prefix] resolves [alias] to a session via
      the registry, then searches that session's archive for an entry whose
      [ae_message_id] starts with [id_prefix]. Returns [Ok entry] on unique
      match, or [Error msg] on ambiguity or missing. *)
  type delivery_mode_sender_count =
    { dms_alias : string
    ; dms_total : int
    ; dms_push : int
    ; dms_poll : int
    }
  type delivery_mode_histogram_result =
    { dmh_total : int
    ; dmh_push : int
    ; dmh_poll : int
    ; dmh_by_sender : delivery_mode_sender_count list
    }
  val delivery_mode_histogram :
    t -> session_id:string -> ?min_ts:float -> ?last_n:int -> unit ->
    delivery_mode_histogram_result
  (** [delivery_mode_histogram] (#307a) counts archived inbound messages
      for [session_id] by `deferrable` flag, grouped by sender alias.
      [min_ts] filters by drained_at >= ts; [last_n] caps to most-recent
      N entries. Measures sender intent, not delivery actuals. *)
  type tag_sender_count =
    { ts_alias : string
    ; ts_total : int
    ; ts_fail : int
    ; ts_blocking : int
    ; ts_urgent : int
    ; ts_untagged : int
    }
  type tag_histogram_result =
    { th_total : int
    ; th_fail : int
    ; th_blocking : int
    ; th_urgent : int
    ; th_untagged : int
    ; th_by_sender : tag_sender_count list
    }
  val tag_histogram :
    t -> session_id:string -> ?min_ts:float -> ?last_n:int -> unit ->
    tag_histogram_result
  (** [tag_histogram] (#392 slice 5) counts archived inbound messages
      for [session_id] by recovered #392 tag (fail / blocking / urgent /
      untagged), grouped by sender alias. Same window args + same
      sender-intent caveat as [delivery_mode_histogram]: tag is detected
      from the body prefix at archive-write time. Useful for "is anyone
      DOSing me with FAIL?" audits. *)
  type liveness_state = Alive | Dead | Unknown
  val registration_liveness_state : registration -> liveness_state
  val int_opt_member : string -> Yojson.Safe.t -> int option
  val valid_room_id : string -> bool
  val load_room_meta : t -> room_id:string -> room_meta
  val save_room_meta : t -> room_id:string -> room_meta -> unit
  val send_room_invite : t -> room_id:string -> from_alias:string -> invitee_alias:string -> unit
  val set_room_visibility : t -> room_id:string -> from_alias:string -> visibility:room_visibility -> unit
  type create_room_result =
    { cr_room_id : string
    ; cr_created_by : string
    ; cr_visibility : room_visibility
    ; cr_invited_members : string list
    ; cr_members : string list
    ; cr_auto_joined : bool
    }
  val create_room :
    t ->
    room_id:string ->
    caller_alias:string ->
    caller_session_id:string ->
    visibility:room_visibility ->
    invited_members:string list ->
    auto_join:bool ->
    create_room_result
  (** [create_room] (#394) atomically creates [room_id] with [caller_alias]
      recorded as [created_by]. Errors with [Invalid_argument] if the room
      already exists. When [auto_join] is true, [caller_alias]/[caller_session_id]
      are added to the member list (the only path by which an invite_only
      room gets a first member without a separate join_room call). *)
  val join_room : t -> room_id:string -> alias:string -> session_id:string -> room_member list
  val leave_room : t -> room_id:string -> alias:string -> room_member list
  val delete_room : t -> room_id:string -> ?caller_alias:string -> ?force:bool -> unit -> unit
  (** Delete an empty room. H3 rooms-acl: requires [caller_alias] to match
      [meta.created_by], OR [~force:true] when the room is legacy (no
      recorded creator). Raises [Invalid_argument] on members present,
      auth failure, or missing room. *)
  val room_history_path : t -> room_id:string -> string
  val append_room_history : t -> room_id:string -> from_alias:string -> content:string -> float
  val read_room_history : t -> room_id:string -> limit:int -> ?since:float -> unit -> room_message list
  type send_room_result = { sr_delivered_to : string list; sr_skipped : string list; sr_ts : float }
  val send_room : ?tag:string -> t -> from_alias:string -> room_id:string -> content:string -> send_room_result
  val fan_out_room_message :
       ?tag:string
    -> t
    -> room_id:string
    -> from_alias:string
    -> content:string
    -> string list * string list
  (** Enqueue [content] to every current member of [room_id] except
      [from_alias]. Returns [(delivered, skipped)] aliases. Public for
      broker-internal fan-outs (system broadcasts, coord-fallthrough
      tier). Per-recipient inbox rows are non-deferrable. *)
  (** [send_room ?tag t ~from_alias ~room_id ~content] enqueues [content]
      to every member of [room_id] except [from_alias]. When [?tag] is
      supplied (one of "fail", "blocking", "urgent" — see
      [parse_send_tag]), each recipient's inbox row content is prefixed
      with [tag_to_body_prefix] so the visual indicator surfaces in the
      transcript. History stores BARE content (no prefix) for stable
      dedup + replay semantics. (#392 slice 4) *)
  type room_info = { ri_room_id : string; ri_member_count : int; ri_members : string list; ri_alive_member_count : int; ri_dead_member_count : int; ri_unknown_member_count : int; ri_member_details : room_member_info list; ri_visibility : room_visibility; ri_invited_members : string list }
  and room_member_info = { rmi_alias : string; rmi_session_id : string; rmi_alive : bool option }
  val list_rooms : t -> room_info list
  val my_rooms : t -> session_id:string -> room_info list
  val read_room_members : t -> room_id:string -> room_member list
  val evict_dead_from_rooms : t -> dead_session_ids:string list -> dead_aliases:string list -> (string * string) list
  val prune_rooms : t -> (string * string) list
  val is_dnd : t -> session_id:string -> bool
  val set_dnd : t -> session_id:string -> dnd:bool -> ?until:float -> unit -> bool option
  val is_compacting : t -> session_id:string -> compacting option
  val set_compacting : t -> session_id:string -> ?reason:string -> unit -> compacting option
  val clear_compacting : t -> session_id:string -> bool
  val clear_stale_compacting : t -> int
  (** [clear_stale_compacting] removes compacting flags older than 5 minutes.
      Returns the number of stale flags cleared. *)
  val confirm_registration : t -> session_id:string -> unit
  (** [confirm_registration t ~session_id] sets confirmed_at to now for the
      session if it is currently None, then emits deferred social broadcasts
      (peer_register + room-join) if the session was previously unconfirmed. *)
  val touch_session : t -> session_id:string -> unit
  val set_automated_delivery :
    t -> session_id:string -> automated_delivery:bool -> unit
  (** [set_automated_delivery t ~session_id ~automated_delivery] sets the
      registration's [automated_delivery] flag to [Some automated_delivery].
      No-op if the session is not registered. Called from the MCP server's
      initialize handler after capability negotiation. *)
  (** [touch_session t ~session_id] updates last_activity_ts to now for the
      session if the stored timestamp is None or older. Call on every broker
      interaction (poll_inbox, send, register) to drive idle-nudge detection. *)
  val is_provisional : registration -> bool
  val is_provisional_expired : registration -> bool
  val is_unconfirmed : registration -> bool
  val pending_per_alias_cap : int
  val pending_global_cap : int
  exception Pending_capacity_exceeded of [`Per_alias of string | `Global]
  val open_pending_permission : t -> pending_permission -> unit
  (** May raise [Pending_capacity_exceeded] if the per-alias or global
      cap would be exceeded by the new entry (#432 Slice C). *)
  val find_pending_permission : t -> string -> pending_permission option
  val remove_pending_permission : t -> string -> unit
  val pending_permission_exists_for_alias : t -> string -> bool

  (** slice/coord-backup-fallthrough: scheduler-facing helpers. *)

  val load_pending_permissions : t -> pending_permission list
  (** Read the persisted entries WITHOUT filtering expired (the scheduler
      filters explicitly; expired-and-unresolved are not interesting to
      it, but we want to see resolved-but-not-yet-removed). Caller must
      hold [with_pending_lock] for atomicity if mutating after reading. *)

  val save_pending_permissions : t -> pending_permission list -> unit
  (** Replace the persisted list. Caller must hold [with_pending_lock]. *)

  val with_pending_lock : t -> (unit -> 'a) -> 'a
  (** Cross-process lock guarding pending_permissions.json. *)

  val mark_pending_resolved : t -> perm_id:string -> ts:float -> bool
  (** [mark_pending_resolved t ~perm_id ~ts] stamps [resolved_at = Some ts]
      on the matching entry if it exists and was not already resolved.
      Returns [true] if the field was newly set, [false] if no-op (already
      resolved, or perm_id absent). Cross-process safe via
      [with_pending_lock]. First-writer-wins: a later call with a smaller
      ts is dropped. *)

  val mark_pending_fallthrough_fired :
       t
    -> perm_id:string
    -> tier_index:int
    -> ts:float
    -> bool
  (** [mark_pending_fallthrough_fired t ~perm_id ~tier_index ~ts] stamps
      [fallthrough_fired_at] at [tier_index] (0-indexed into the chain;
      grow the list with [None] padding if needed). Returns [true] if a
      new stamp was written, [false] if that index was already stamped or
      the entry is absent. Cross-process safe via [with_pending_lock]. *)

  val write_allowed_signers_entry : t -> alias:string -> unit
end

val notify_shared_with_recipients :
  broker:Broker.t ->
  from_alias:string ->
  name:string ->
  ?description:string ->
  shared:bool ->
  shared_with:string list ->
  unit ->
  string list
(** [notify_shared_with_recipients] is the send-memory handoff (#286).
    After a memory entry with [shared_with] is written, broker-DM each
    recipient with the path. Globally-shared entries (`shared:true`)
    skip targeted handoff. Notifications are non-deferrable (#307b —
    they push immediately so the recipient sees the path on save) and
    best-effort (try/with swallows enqueue failures). Returns the list
    of aliases successfully notified; the empty list when [shared:true]
    OR [shared_with] is empty. *)

(* Native OCaml relay modules *)

val channel_notification : ?role:string option -> message -> Yojson.Safe.t
val decrypt_message_for_push : message -> alias:string -> message

val resolve_session_id :
  ?session_id_override:string -> Yojson.Safe.t -> string
(** [resolve_session_id ?session_id_override arguments] returns the session
    id from (in order) the [session_id] string field of [arguments], the
    [session_id_override] (typically the per-RPC env-derived id), or
    [current_session_id ()]. Raises [Invalid_argument "missing session_id"]
    when no source resolves. Exposed for [#432 §3] — keeps the resolution
    contract testable. *)

val with_session :
  session_id_override:string option ->
  Broker.t ->
  Yojson.Safe.t ->
  (session_id:string -> 'a) ->
  'a
(** [with_session ~session_id_override broker arguments f] resolves the
    session id (see [resolve_session_id]), stamps [last_activity_ts] via
    [Broker.touch_session], then runs [f ~session_id]. The label is
    required (option-typed) to mirror [handle_tool_call]'s shape. Pure-OCaml
    handlers and tests use this combinator; Lwt-returning handlers use
    [with_session_lwt]. [#432 §3]. *)

val with_session_lwt :
  session_id_override:string option ->
  Broker.t ->
  Yojson.Safe.t ->
  (session_id:string -> 'a Lwt.t) ->
  'a Lwt.t
(** Lwt-returning variant of [with_session]; see that function for the
    contract. The body [f] is invoked AFTER the touch has been stamped. *)

val session_id_from_env : ?client_type:string -> unit -> string option
(** Resolve the current broker session id from the ambient client env. Prefers
    explicit c2c-managed ids and falls back to harness-native ids when safe. *)
val auto_register_startup : broker_root:string -> unit
val auto_join_rooms_startup : broker_root:string -> unit
val pop_channel_test_code : unit -> string option
(** [pop_channel_test_code ()] returns and clears the pending channel-test code,
    if one was generated during registration. Returns [None] if no test is pending. *)
val handle_request : broker_root:string -> Yojson.Safe.t -> Yojson.Safe.t option Lwt.t

val log_coord_fallthrough_fired :
     broker_root:string
  -> perm_id:string
  -> tier:int
  -> primary_alias:string
  -> backup_alias:string
  -> requester_alias:string
  -> elapsed_s:float
  -> ts:float
  -> unit
(** Coord-backup fallthrough audit log
    (slice/coord-backup-fallthrough). Append one
    [event=coord_fallthrough_fired] line to [<broker_root>/broker.log]
    per fired tier. [perm_id] is hashed (16 hex chars) before write so
    the bearer token never lands plaintext in the audit log; aliases
    are plaintext (already public via [list]). [tier] is 1-indexed:
    1 = first-backup DM, N = Nth-backup DM, [tier > len(chain)-1] =
    swarm-lounge broadcast tier. Best-effort write; errors swallowed
    (failed audit must never break a working scheduler tick). *)
