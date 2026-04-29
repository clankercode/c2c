(** Agent stickers — signed appreciation tokens.

    Cryptographically-signed appreciation tokens agents send each other as
    peer-to-peer recognition signals. Storage is repo-relative
    (.c2c/stickers/). Closed set v1: sticker kinds are predefined in
    registry.json, not open strings. *)

(** {1 Types} *)

(** Sticker envelope. Signed JSON stored at
    .c2c/stickers/<alias>/received/<ts>-<nonce>.json (private) or
    .c2c/stickers/public/<from>-<ts>-<nonce>.json (public).

    Schema versions:
    - v1: 8-field canonical blob — peer-addressed stickers only.
      [target_msg_id] is always [None] and is NOT included in the
      signed canonical blob.
    - v2: 9-field canonical blob — adds [target_msg_id] for reactions
      anchored to a specific message. Empty string when [None]. *)
type sticker_envelope = {
  version : int;           (** 1 = legacy peer-addressed, 2 = with target_msg_id *)
  from_ : string;          (** Sender alias *)
  to_ : string;            (** Recipient alias *)
  sticker_id : string;      (** Key into registry.json *)
  note : string option;    (** Optional free text, max 280 chars *)
  target_msg_id : string option;
    (** v2+: id of the message being reacted to. None for plain
        peer-addressed stickers. Always None on v1 envelopes. *)
  scope : scope;
  ts : string;             (** RFC3339 UTC timestamp *)
  nonce : string;          (** 16-byte random, base64url-nopad *)
  sender_pk : string;       (** Sender's public key, base64url-nopad *)
  signature : string;      (** Ed25519 signature, base64url-nopad *)
}

(** Scope determines storage path and visibility *)
and scope = [ `Public | `Private | `Both ]

(** A registry entry for a sticker kind *)
type registry_entry = {
  id : string;          (** Unique key, e.g. "brilliant" *)
  emoji : string;       (** Visual identifier, e.g. "✨" *)
  display_name : string; (** Human-readable label *)
  description : string;  (** What the sticker means *)
}

(** {1 Path helpers} *)

(** [.c2c/stickers] directory *)
val sticker_dir : unit -> string

(** [.c2c/stickers/<alias>/received] — private sticker storage *)
val received_dir : alias:string -> string

(** [.c2c/stickers/<alias>/sent] — own sent stickers *)
val sent_dir : alias:string -> string

(** [.c2c/stickers/public] — public sticker storage *)
val public_dir : unit -> string

(** {1 Registry} *)

(** Load the sticker registry from [.c2c/stickers/registry.json].
    Raises if the file is missing or malformed. *)
val load_registry : unit -> registry_entry list

(** [validate_sticker_id id] returns [Ok ()] if [id] exists in the
    registry, [Error msg] otherwise. *)
val validate_sticker_id : string -> (unit, string) result

(** {1 Signing and verification} *)

(** Build the canonical blob for signing. Format is version-switched:
    - v1: "1|<from>|<to>|<sticker_id>|<note_or_empty>|<scope>|<ts>|<nonce>"
    - v2: "2|<from>|<to>|<sticker_id>|<note_or_empty>|<scope>|<ts>|<nonce>|<target_msg_id_or_empty>"
    where scope is "public", "private" or "both". v1 envelopes on disk
    retain their original 8-field blob even after this module supports
    v2 — back-compat is permanent. *)
val canonical_blob : sticker_envelope -> string

(** [sign_envelope ~identity env] adds the Ed25519 signature to [env]
    using [identity]'s private key. Returns a new envelope with the
    [signature] field filled in. *)
val sign_envelope : identity:Relay_identity.t -> sticker_envelope -> sticker_envelope

(** [verify_envelope env] verifies the signature on [env].
    Returns [Ok true] if valid, [Error msg] if invalid or missing. *)
val verify_envelope : sticker_envelope -> (bool, string) result

(** [envelope_to_json env] serializes [env] as a JSON object. v1 envelopes
    omit the [target_msg_id] field; v2 envelopes include it when
    [Some _]. *)
val envelope_to_json : sticker_envelope -> Yojson.Safe.t

(** [envelope_of_json json] decodes an envelope. A missing
    [target_msg_id] field decodes to [None] (forward-compat for v1 files
    and v2 files written before the field was set). Missing [version]
    defaults to 1. *)
val envelope_of_json : Yojson.Safe.t -> (sticker_envelope, string) result

(** {1 Envelope construction and storage} *)

(** [create_and_store ?target_msg_id ~from_ ~to_ ~sticker_id ~note ~scope ~identity ()]
    validates the sticker_id, builds and signs an envelope, and stores it.
    Returns [Ok envelope] on success, [Error msg] on failure.

    If [target_msg_id] is [Some _] the resulting envelope is a v2 reaction
    envelope. Otherwise it is a v1 peer-addressed sticker, byte-for-byte
    compatible with envelopes created before the v2 schema landed. *)
val create_and_store :
  ?target_msg_id:string ->
  from_:string ->
  to_:string ->
  sticker_id:string ->
  note:string option ->
  scope:scope ->
  identity:Relay_identity.t ->
  unit ->
  (sticker_envelope, string) result

(** [load_stickers ~alias ?scope ()] loads stickers for [alias].
    If [scope] is provided, filters by that scope.
    Returns stickers sorted by ts descending (newest first). *)
val load_stickers : alias:string -> ?scope:scope -> unit -> sticker_envelope list

(** [format_sticker env] formats [env] for terminal display, including
    emoji and note if present. *)
val format_sticker : sticker_envelope -> string

(** {1 CLI commands} *)

val sticker_group : unit Cmdliner.Cmd.t
