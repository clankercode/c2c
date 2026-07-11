(** [C2c_schema_v1] — the canonical *lean v1* c2c message/event JSON schema.

    This module is the shared, hermetic definition of the versioned wire
    shape that send / poll / peek / monitor / MCP results will converge on
    (I002, friction rows A033-A034/A041/A047/A050; B009-B011/B035/B052/B214/
    B216/B232). It is intentionally ADDITIVE: J1 only publishes the schema,
    the field-key contract, and conformance vectors. It does NOT migrate any
    existing output surface — that is the job of the follow-up slices
    (J2 CLI, J3 monitor NDJSON, J4 MCP).

    Design (per the authoritative I002 idea, "trusted-swarm-first, keep v1
    lean"): v1 ships only the fields emitted today plus a canonical
    [delivery.state]. Trust/identity fields ([identity_pk], [verified],
    [trust_tier]) and [priority] are DEFERRED to a future v2 (I003/I008),
    and the [read] delivery state is deferred to receipts (I004). Note the
    distinction: reserved v2 KEYS (enumerated in {!reserved_v2_keys} /
    {!reserved_v2_from_keys}) are IGNORED by {!validate} (forward-compat,
    never rejected), whereas reserved enum VALUES for existing fields —
    e.g. [delivery.state = "read"] — are REJECTED by {!validate} until v2
    defines them. [schema_version] is carried from day one so v2 is
    non-breaking.

    Purely functional: depends only on [yojson]. No I/O, no environment. *)

val schema_version : int
(** The wire schema version this module implements: [1]. *)

(** Message type discriminator (the [type] wire field). *)
type msg_type =
  | Dm
  | Room
  | System

(** Delivery lifecycle state. Lean v1 stops at [Delivered] plus the
    offline-durable queue state [Queued_offline] (B127); a [read]
    receipt state is deferred to I004 and is therefore NOT accepted as a
    valid v1 delivery state. *)
type delivery_state =
  | Queued
  | Queued_offline
  | Accepted
  | Delivered

(** Transport source of the message. *)
type source =
  | Local
  | Relay

(** Sender address. Lean v1 carries only routing identity; the
    trust/identity fields ([identity_pk], [verified], [trust_tier]) are
    reserved for v2 (see {!reserved_v2_from_keys}) and ignored on parse. *)
type from_addr =
  { alias : string             (** required *)
  ; host_id : string option    (** optional *)
  ; address : string option    (** optional; canonically [alias@host_id] *)
  }

(** A canonical v1 message/event record. *)
type t =
  { schema_version : int              (** required; must equal {!schema_version} *)
  ; msg_type : msg_type               (** required *)
  ; message_id : string option        (** optional *)
  ; ts : float option                 (** optional; epoch seconds *)
  ; from : from_addr                  (** required (with required [alias]) *)
  ; to_ : string                      (** required; alias or room *)
  ; source : source option            (** optional; defaults to [Local] semantics *)
  ; content : string                  (** required; UNTRUSTED external text *)
  ; in_reply_to : string option       (** optional; threading pointer *)
  ; delivery_state : delivery_state option  (** optional *)
  }

(** {2 Stable field-key contract}

    Consumers (J2/J3/J4) MUST reference these constants rather than
    hard-coding literals, so a rename is a one-line, type-checked change. *)

val key_schema_version : string
val key_type : string
val key_message_id : string
val key_ts : string
val key_from : string
val key_from_alias : string
val key_from_host_id : string
val key_from_address : string
val key_to : string
val key_source : string
val key_content : string
val key_in_reply_to : string
val key_delivery : string
val key_delivery_state : string

val required_top_level_keys : string list
(** The keys {!validate} requires at the top level. *)

val reserved_v2_from_keys : string list
(** [from]-object keys reserved for a future v2 (identity/trust). Ignored
    by {!validate}. *)

val reserved_v2_keys : string list
(** Top-level keys reserved for a future v2 (e.g. [priority]). Ignored by
    {!validate}. *)

(** {2 Enum <-> string} *)

val string_of_msg_type : msg_type -> string
val msg_type_of_string : string -> msg_type option
val string_of_delivery_state : delivery_state -> string
val delivery_state_of_string : string -> delivery_state option
val string_of_source : source -> string
val source_of_string : string -> source option

(** {2 Serialize / validate} *)

val serialize : t -> Yojson.Safe.t
(** Render a record to canonical v1 JSON. Optional [None] fields are
    omitted (optionality is represented by absence, never by [null]). *)

val to_string : t -> string
(** [serialize] then compact-print. *)

val serialize_with_legacy :
  ?delivery_extra:(string * Yojson.Safe.t) list ->
  t -> legacy:(string * Yojson.Safe.t) list -> Yojson.Safe.t
(** [serialize] the v1 document, then append the [legacy] key/value pairs
    after the canonical fields. This is the single supported way for
    migrating surfaces (J2 CLI / J4 MCP; the J3 monitor keeps its own
    shaping in [C2c_monitor_ndjson] because it prepends
    [event_type]/[monitor_ts] BEFORE the v1 fields) to keep legacy
    duplicate keys (e.g. [from_alias], [to_alias], [queued]) alongside
    the v1 fields during the compatibility window.

    Dedup guarantee (J5 unification of the J2 CLI helper onto this one):
    any [legacy] key already emitted by the v1 serialization is skipped,
    so the result never contains a duplicate JSON key. For colliding keys
    (e.g. [content], [ts]) callers must only pass legacy values identical
    to the v1-emitted ones, since the v1 rendering wins.

    [delivery_extra] pairs are merged INSIDE the [delivery] object (only
    when the record carries a delivery state; keys already present in the
    object are skipped). Extra delivery keys are tolerated-unknown per
    the v1 forward-compat contract — used by the CLI send receipt to
    carry the legacy [delivery.warning] (B088) beside [delivery.state]. *)

val validate : Yojson.Safe.t -> (t, string) result
(** Parse and check a JSON value against the v1 schema.

    Rejects (with a human-readable reason): a non-object; a missing or
    non-integer [schema_version]; a [schema_version] other than
    {!schema_version}; a missing/invalid [type]; a missing/empty
    [from.alias]; a missing [to] or [content]; and any present-but-invalid
    enum value for [type], [source], or [delivery.state].

    Tolerates (forward-compat): unknown top-level keys, unknown [from] keys,
    and unknown [delivery] keys — including every name in {!reserved_v2_keys}
    and {!reserved_v2_from_keys}. Absent optional fields are fine. *)

val of_string : string -> (t, string) result
(** Parse a JSON string then {!validate}. Parse errors are returned as
    [Error] (never raised). *)
