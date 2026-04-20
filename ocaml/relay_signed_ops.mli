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
    (and /invite_room, /uninvite_room, /set_room_visibility — they
    share the same blob shape). Uses a fresh ts/nonce.

    [ctx] is one of [Relay.room_join_sign_ctx],
    [Relay.room_leave_sign_ctx], etc. *)
val sign_room_op :
  Relay_identity.t -> ctx:string -> room_id:string -> alias:string
  -> signed_proof

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
