(** Durable routing state for the T3 connector (P9.M1.E1.T003).

    One state directory holds a single private [state.json] (mode 0600, owned
    by the effective uid, inside a 0700 directory) and is guarded by a
    cross-process singleton lock ({!C2c_singleton_lock}). The file carries:

    - the T3 thread id -> c2c alias mapping, with tombstones;
    - a bounded journal of inbound / recovery entries that have been accepted
      but not yet acknowledged (persist-first: append before delivering, ack
      after);
    - a bounded ring of acknowledged keys so a re-delivered T3 event is
      deduplicated rather than delivered twice.

    All writes go through {!C2c_io.write_file_atomic} with [~perm:0o600]. A
    failed write leaves the in-memory state unchanged. Nothing is ever dropped
    silently: a full journal rejects the append with an error instead of
    evicting unacknowledged entries. *)

type t

type open_error =
  | Already_running  (** another live owner holds the singleton lock *)
  | Unsafe of string (** ownership / mode / symlink check failed; nothing was changed *)
  | Corrupt of string (** [state.json] exists but cannot be parsed; not overwritten *)
  | Io of string

val open_error_to_string : open_error -> string

val default_max_journal : int
val default_max_payload_bytes : int
val default_max_tombstones : int
val default_max_acked : int

val open_state :
  ?clock:(unit -> float) ->
  ?max_journal:int ->
  ?max_payload_bytes:int ->
  ?max_tombstones:int ->
  ?max_acked:int ->
  dir:string ->
  unit ->
  (t, open_error) result
(** Create (0700) or validate [dir], take the singleton lock, then load
    [state.json]. The lock is held until {!close} or process exit. A second
    [open_state] on the same [dir], in this process or another, returns
    [Already_running]. *)

val close : t -> unit
(** Release the singleton lock. Idempotent. The handle must not be used after. *)

val dir : t -> string
val state_path : t -> string

(** {1 Alias mapping} *)

val alias_of_thread_id : string -> string
(** Stable alias ["t3-" ^ first 12 hex chars of SHA-256(thread_id)]. Pure. *)

type tombstone = { tombstoned_at : float; reason : string }

type mapping = {
  thread_id : string;
  alias : string;
  created_at : float;
  tombstone : tombstone option;
}

val ensure_mapping : t -> thread_id:string -> (mapping, string) result
(** Find or create the mapping for [thread_id]. Errors if the thread is
    tombstoned, the id is empty, or the alias collides with a different
    thread id. *)

val find_by_thread : t -> thread_id:string -> mapping option
val find_by_alias : t -> alias:string -> mapping option
val mappings : t -> mapping list

val tombstone : t -> thread_id:string -> reason:string -> (unit, string) result
(** Mark a mapping dead. Idempotent for an already-tombstoned thread (the
    original tombstone is kept). Errors if the thread is unknown. The oldest
    tombstoned mappings beyond [max_tombstones] are evicted. *)

(** {1 Journal} *)

type kind = Inbound | Recovery

type entry = {
  seq : int;
  kind : kind;
  key : string;  (** dedup key, e.g. the T3 event/message id *)
  at : float;
  payload : Yojson.Safe.t;
}

type append_result =
  | Appended of entry
  | Duplicate  (** [(kind, key)] is already pending or was recently acked *)

val journal_append :
  t -> kind:kind -> key:string -> payload:Yojson.Safe.t -> (append_result, string) result
(** Durably record an entry. Errors if the journal is full
    ([max_journal] pending entries) or the serialized payload exceeds
    [max_payload_bytes]. *)

val journal_pending : ?kind:kind -> t -> entry list
(** Unacknowledged entries, oldest first. *)

val journal_ack : t -> seq:int -> (bool, string) result
(** Remove entry [seq] and remember its key for dedup. [Ok false] if no such
    entry is pending. *)
