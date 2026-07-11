open Relay_common
open Relay_host_routing
open Relay_registration_lease

(* S5b: In-memory device-pair pending record (RFC 8628 device-login flow).
   Stored temporarily while waiting for phone to register pubkeys. *)
type device_pair_pending = {
  binding_id : string;
  machine_ed25519_pubkey : string;
  phone_ed25519_pubkey : string option;
  phone_x25519_pubkey : string option;
  created_at : float;
  expires_at : float;
  fail_count : int;
}

let get_now = fun () -> Unix.gettimeofday ()

let with_lock m f =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

(* --- RELAY signature - satisfied by both InMemoryRelay and SqliteRelay --- *)

module type RELAY = sig
  type t
  val create : ?dedup_window:int -> ?persist_dir:string -> ?self_host:string option -> ?peer_relays:(string, peer_relay_t) Hashtbl.t -> unit -> t
  (* #379: the relay's own host identity, used to validate alias@host targets. *)
  val self_host : t -> string option
  (* #330 S2: the relay's own Ed25519 identity for signing cross-relay forward requests. *)
  val relay_identity : t -> Relay_identity.t
  (* #330 S1: peer-relay table for cross-relay forwarding. *)
  val add_peer_relay : t -> peer_relay_t -> unit
  val peer_relay_of : t -> name:string -> peer_relay_t option
  val peer_relays_list : t -> peer_relay_t list
  val register : t -> node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?ttl:float -> ?identity_pk:string -> ?enc_pubkey:string -> ?signed_at:float -> ?sig_b64:string -> ?opaque_host_id:string option -> unit -> (string * RegistrationLease.t)
  val identity_pk_of : t -> alias:string -> string option
  val alias_of_identity_pk : t -> identity_pk:string -> string option
  val alias_of_session : t -> node_id:string -> session_id:string -> string option
  val query_messages_since : t -> alias:string -> since_ts:float -> Yojson.Safe.t list
  val enc_pubkey_of : t -> alias:string -> string option
  val signed_at_of : t -> alias:string -> float option
  val sig_b64_of : t -> alias:string -> string option
  (* L3/5 identity bootstrapping. *)
  val set_allowed_identity : t -> alias:string -> identity_pk_b64:string -> unit
  val allowed_identity_of : t -> alias:string -> string option
  val check_allowlist : t -> alias:string -> identity_pk_b64:string ->
    [ `Allowed | `Mismatch | `Unlisted ]
  val unbind_alias : t -> alias:string -> bool
  val check_register_nonce : t -> nonce:string -> ts:float -> (unit, string) result
  val check_request_nonce : t -> nonce:string -> ts:float -> (unit, string) result
  (** B116: consume a DELETE /binding/<id> revocation-proof nonce. Separate
      from [check_request_nonce] so the outer Ed25519 request verifier
      (which writes header nonces to the request-nonce store before
      signature verification) can never touch revoke replay state.
      Persisted by SqliteRelay; in-memory for InMemoryRelay. *)
  val check_revoke_nonce : t -> nonce:string -> ts:float -> (unit, string) result
  val heartbeat : t -> node_id:string -> session_id:string -> (string * RegistrationLease.t)
  val list_peers : t -> ?include_dead:bool -> RegistrationLease.t list
  (* [pow_difficulty]: B014 — the sender's PoW difficulty (leading-zero bits)
     at send-accept time, stored as sibling metadata on the delivered message.
     Default [-1] = not recorded (relay PoW disabled / sender identity
     unresolved); such messages carry no [pow] object on delivery. *)
  val send : t -> from_alias:string -> to_alias:string -> content:string -> ?message_id:string option -> ?pow_difficulty:int -> [> `Ok of float | `Duplicate of float | `Error of string * string]
  val poll_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t list
  val peek_inbox : t -> node_id:string -> session_id:string -> Yojson.Safe.t list
  val send_all : t -> from_alias:string -> content:string -> ?message_id:string option -> [> `Ok of float * string list * string list]
  val join_room : t -> ?visibility:string -> alias:string -> room_id:string -> unit -> [> `Ok | `Error of string * string]
  val leave_room : t -> alias:string -> room_id:string -> [> `Ok | `Error of string * string]
  val send_room : t -> from_alias:string -> room_id:string -> content:string -> ?message_id:string option -> ?envelope:Yojson.Safe.t -> unit -> [> `Ok of float * string list * string list | `Error of string * string]
  val room_history : t -> room_id:string -> ?limit:int -> Yojson.Safe.t list
  val gc : t -> [> `Ok of string list * int]
  val dead_letter : t -> Yojson.Safe.t list
  val add_dead_letter : t -> Yojson.Safe.t -> unit
  val list_rooms : t -> Yojson.Safe.t list
  val room_exists : t -> room_id:string -> bool
  val room_visibility_of : t -> room_id:string -> string
  val room_invites_of : t -> room_id:string -> string list
  val is_invited : t -> room_id:string -> identity_pk_b64:string -> bool
  val set_room_visibility : t -> room_id:string -> visibility:string -> unit
  (* B117: persisted per-room history readability policy. [history_public_of]
     returns the stored value, defaulting per visibility for legacy/absent
     rooms (public/unlisted → true, gated/private → false).
     [set_room_history_public] persists the flag; callers enforce the
     gated/private-must-be-false invariant before invoking it. *)
  val history_public_of : t -> room_id:string -> bool
  val set_room_history_public : t -> room_id:string -> history_public:bool -> unit
  val invite_to_room : t -> room_id:string -> identity_pk_b64:string -> unit
  val uninvite_from_room : t -> room_id:string -> identity_pk_b64:string -> unit
  val knock_room : t -> room_id:string -> requester_alias:string ->
    requester_pk:string -> [> `Ok of bool | `Error of string * string]
  val room_knocks_of : t -> room_id:string -> room_knock list
  val remove_room_knock : t -> room_id:string -> requester_pk:string -> room_knock option
  val is_room_member_alias : t -> room_id:string -> alias:string -> bool
  (* S5a: Pairing token management *)
  val store_pairing_token : t -> binding_id:string -> token_b64:string ->
    machine_ed25519_pubkey:string -> expires_at:float -> (unit, string) result
  val get_and_burn_pairing_token : t -> binding_id:string -> (string * string) option
  val find_pairing_token : t -> binding_id:string -> bool
    (* true if a valid (not expired) token for this binding_id already exists *)
    (* S5a: Observer binding management *)
  val add_observer_binding : t -> binding_id:string ->
    phone_ed25519_pubkey:string -> phone_x25519_pubkey:string ->
    machine_ed25519_pubkey:string -> provenance_sig:string -> unit
  val get_observer_binding : t -> binding_id:string -> (string * string * string * string) option
  (** Returns (phone_ed25519_pubkey, phone_x25519_pubkey, machine_ed25519_pubkey, provenance_sig). *)
  val remove_observer_binding : t -> binding_id:string -> unit
  (* S5b: Device-pair pending state (RFC 8628 OAuth, ephemeral, InMemoryRelay only) *)
  val get_device_pair_pending : t -> user_code:string -> device_pair_pending option
  val set_device_pair_pending : t -> user_code:string -> device_pair_pending -> unit
  val remove_device_pair_pending : t -> user_code:string -> unit
end
