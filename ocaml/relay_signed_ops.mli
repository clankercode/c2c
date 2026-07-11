(** Layer 4 client-side signer for room operations.

    Builds the {ts, nonce, sig, identity_pk_b64} bundle a client needs
    to attach to /join_room, /leave_room, /send_room, /invite_room,
    /uninvite_room, /set_room_visibility to satisfy the server-side
    Ed25519 verify introduced in L4/1, L4/2, L4/5.

    Wire-agnostic: callers receive strings (all b64url-nopad where
    relevant) and splice them into the request body themselves. *)

type signed_proof = {
  identity_pk_b64 : string; (** 32-byte pk, base64url-nopad *)
  ts : string;              (** RFC 3339 UTC *)
  nonce : string;           (** base64url-nopad, 16 random bytes *)
  sig_b64 : string;         (** 64-byte sig, base64url-nopad *)
}

(** [now_rfc3339_utc ()] = current time as "YYYY-MM-DDTHH:MM:SSZ". *)
val now_rfc3339_utc : unit -> string

(** [random_nonce_b64 ()] = 16 fresh random bytes, base64url-nopad. *)
val random_nonce_b64 : unit -> string

(** [sign_room_op identity ~ctx ~room_id ~alias] produces a proof
    over the 5-field canonical blob used by /join_room and /leave_room
    (and /invite_room, /uninvite_room). Uses a fresh ts/nonce.
    Visibility-carrying joins and /set_room_visibility use
    [sign_room_op_with_visibility] so the stored visibility is covered.

    [ctx] is one of [Relay.room_join_sign_ctx],
    [Relay.room_leave_sign_ctx], etc. *)
(** [sign_register identity ~alias ~relay_url] produces a signed_proof
    over the canonical register blob (ctx = [Relay.register_sign_ctx]).
    relay_url is lower-cased before hashing, matching server behaviour. *)
val sign_register :
  Relay_identity.t -> alias:string -> relay_url:string -> signed_proof

val sign_room_op :
  Relay_identity.t -> ctx:string -> room_id:string -> alias:string
  -> signed_proof

(** [sign_room_op_with_visibility identity ~ctx ~room_id ~alias ~visibility]
    signs the room operation shape used by visibility-carrying room ops:
    room_id || alias || canonical_visibility || identity_pk || ts || nonce. *)
val sign_room_op_with_visibility :
  Relay_identity.t -> ctx:string -> room_id:string -> alias:string
  -> visibility:string -> signed_proof

(** [sign_room_op_with_history_public identity ~ctx ~room_id ~alias
    ~history_public] signs the B117 set_room_history_public op. The boolean is
    rendered as "true"/"false" and covered by the signature:
    room_id || alias || ("true"|"false") || identity_pk || ts || nonce. *)
val sign_room_op_with_history_public :
  Relay_identity.t -> ctx:string -> room_id:string -> alias:string
  -> history_public:bool -> signed_proof

(** [sign_room_op_with_target_pk identity ~ctx ~room_id ~alias ~target_pk]
    signs room ops whose body carries a target identity key, such as
    approve/deny knock:
    room_id || alias || target_pk || identity_pk || ts || nonce. *)
val sign_room_op_with_target_pk :
  Relay_identity.t -> ctx:string -> room_id:string -> alias:string
  -> target_pk:string -> signed_proof

(** [sign_send_room identity ~room_id ~from_alias ~content] produces
    a full §2 envelope for a v1 enc="none" room message:
    {ct=b64(content), enc="none", sender_pk, sig, ts, nonce}.

    Returns the envelope as a [Yojson.Safe.t]. *)
val sign_send_room :
  Relay_identity.t -> room_id:string -> from_alias:string
  -> content:string -> Yojson.Safe.t

(** [verify_history_envelope ~room_id ~from_alias ~content envelope]
    reconstructs the server-side canonical blob for an L4/2 send
    envelope and verifies the Ed25519 signature against [sender_pk].

    Returns [Ok ()] on valid signature, [Error reason] otherwise
    (malformed envelope, wrong enc, ct/content mismatch, bad sig).
    Time window and nonce replay are NOT re-checked here — this
    verifies authenticity of the history record, not freshness. *)
val verify_history_envelope :
  room_id:string -> from_alias:string -> content:string
  -> Yojson.Safe.t -> (unit, string) result

(** [sign_binding_revoke identity ~binding_id] produces the owner proof
    required by DELETE /binding/<binding_id> (B116). [ts] in the returned
    proof is Unix epoch seconds (6 decimal places), NOT RFC 3339. The
    signing key must be the machine or phone Ed25519 key recorded on the
    binding; the server applies the same freshness window and nonce replay
    store as signed peer requests, and requires the verified key to own
    the binding before consuming the nonce. *)
val sign_binding_revoke :
  Relay_identity.t -> binding_id:string -> signed_proof

(** [sign_request identity ~alias ~meth ~path ~body_str ()] produces the
    Authorization header value for a peer route request per spec §5.1.
    Returns: "Ed25519 alias=<a>,ts=<t>,nonce=<n>,sig=<s>".
    [ts] is Unix epoch seconds (6 decimal places); sig covers
    canonical_request_blob(meth, path, query, SHA256(body), ts, nonce). *)
val sign_request :
  Relay_identity.t -> alias:string -> meth:string -> path:string ->
  ?query:string -> body_str:string -> unit -> string

(** Sign-context constants — must match spec §3.4 *)
val request_sign_ctx : string
val register_sign_ctx : string
val receipt_sign_ctx : string
val room_send_sign_ctx : string

(** [build_registration_receipt_json ~identity ~alias ~client_identity_pk_b64
    ~nonce ~ts] builds a signed registration receipt as a JSON object.
    Signs with the relay's Ed25519 identity over the canonical receipt blob
    (alias || client_identity_pk || relay_identity_pk || ts || nonce). *)
val build_registration_receipt_json :
  identity:Relay_identity.t -> alias:string ->
  client_identity_pk_b64:string -> nonce:string -> ts:string ->
  Yojson.Safe.t

(** Build the canonical request blob per spec §5.1. *)
val canonical_request_blob :
  meth:string -> path:string -> query:string ->
  body_sha256_b64:string -> ts:string -> nonce:string -> string
