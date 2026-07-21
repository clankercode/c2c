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

(* B262/B263: recipient-issued, sender-bound contact grants (design freeze:
   .collab/design/2026-07-22-b262-contact-grant-protocol.md). Shared domain
   types live here so both backends and tests agree. *)

type contact_issue_result = {
  grant_secret : string; (* 32 raw bytes; returned once to owner *)
  grant_id : string; (* base64url-nopad of SHA-256(secret); management id *)
  expires_at : float;
  generation : int;
}

type contact_grant_meta = {
  grant_id : string;
  sender_fp_prefix : string; (* short non-secret fingerprint prefix *)
  delivery_alias : string;
  expires_at : float;
  revoked_at : float option;
  generation : int;
  label : string option;
}

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
  val register : t -> node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?client_version:string -> ?client_os:string -> ?ttl:float -> ?identity_pk:string -> ?enc_pubkey:string -> ?signed_at:float -> ?sig_b64:string -> ?opaque_host_id:string option -> unit -> (string * RegistrationLease.t)
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
  (* B174: optional [opaque_host_id] heals leases that registered before the
     client started sending host ids (heartbeat-only sessions). Non-empty
     values are stored; empty/absent never clears an existing host id. *)
  val heartbeat :
    t -> node_id:string -> session_id:string -> ?opaque_host_id:string
    -> (string * RegistrationLease.t)
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
  (** Directory listing. Anonymous ([for_alias] absent): public + gated only.
      With [for_alias], also include unlisted rooms where that alias is a
      current member (B230). Private rooms stay omitted from this surface. *)
  val list_rooms : ?for_alias:string -> t -> Yojson.Safe.t list
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
  (* B147 / B174: aggregate usage stats behind GET /stats. The HTTP handlers
     record at accept time — [stats_note_message] on each accepted send
     operation (DM /send, /send_all broadcast, /send_room, inbound /forward;
     duplicates and rejects are not counted, and a fan-out counts once), and
     [stats_note_activity] on successful /register and /heartbeat.
     [stats] aggregates message counts and distinct alias / machine counts
     over the 1d/7d/28d/ever windows. Machine identity is the client
     [opaque_host_id] when present (B174) — NOT [node_id], which is often
     per-session (e.g. [cli-<alias>]) and over-counts unique machines.
     [ts]/[now] are caller-supplied so window arithmetic is testable without
     a live clock. *)
  val stats_note_message : t -> from_alias:string -> ts:float -> unit
  val stats_note_activity :
    t -> machine_id:string -> ?retire_key:string -> alias:string -> ts:float
    -> unit -> unit
  val stats : t -> now:float -> Yojson.Safe.t
  (* B149: persist one historical snapshot of the full [stats] JSON, stamped
     [now]. Sqlite appends a row to the stats_snapshots table; the memory
     backend appends a line to <persist_dir>/stats-history.jsonl (no-op
     without persist_dir). Driven hourly by the server loop. Never raises. *)
  val record_stats_snapshot : t -> now:float -> unit
  (* B262/B263: recipient-owned, sender-bound contact grants. See
     .collab/design/2026-07-22-b262-contact-grant-protocol.md.

     TRUST BOUNDARY (v1): owner-management calls below are backend operations,
     not authentication endpoints. [recipient_identity_pk] MUST come from an
     already-verified host-local/owner control plane. A future remote management
     route must authenticate alias + signing identity before calling them; do
     not pass caller-supplied public keys through directly. Delivery admission
     is separately bound to the verified request sender. *)
  val issue_contact_grant :
    t ->
    recipient_identity_pk:string ->
    delivery_alias:string ->
    sender_identity_pk:string ->
    expires_at:float ->
    ?label:string ->
    ?now:float ->
    unit ->
    (contact_issue_result, string) result
  val list_contact_grants :
    t -> recipient_identity_pk:string -> contact_grant_meta list
  val revoke_contact_grant :
    t ->
    recipient_identity_pk:string ->
    grant_id:string ->
    ?now:float ->
    unit ->
    (unit, string) result
  val rotate_contact_grant :
    t ->
    recipient_identity_pk:string ->
    grant_id:string ->
    sender_identity_pk:string ->
    expires_at:float ->
    ?label:string ->
    ?now:float ->
    unit ->
    (contact_issue_result, string) result
  val admit_contact_delivery :
    t ->
    verified_sender_alias:string ->
    verified_sender_identity_pk:string ->
    grant_secret:string ->
    message_id:string ->
    content:string ->
    ?now:float ->
    unit ->
    [ `Accepted of float | `Duplicate of float | `Rejected ]
end

(* --- B147: usage-stats window definitions shared by both backends --- *)

let stats_windows = [ ("1d", 86_400.); ("7d", 7. *. 86_400.); ("28d", 28. *. 86_400.) ]

(* B174: resolve the machine key used by unique_machines / connected.machines.
   Prefer the client-reported opaque host id (stable per physical/VM host via
   [c2c host-id]); fall back to node_id only when the host id is absent so
   older clients still contribute something rather than vanishing from the
   machine counts. *)
let stats_machine_id ~node_id ~opaque_host_id =
  match opaque_host_id with
  | Some id when id <> "" -> id
  | _ -> node_id

let stats_machine_id_of_lease (lease : RegistrationLease.t) =
  stats_machine_id
    ~node_id:(RegistrationLease.node_id lease)
    ~opaque_host_id:(RegistrationLease.opaque_host_id lease)

(* Message-event rows older than the largest window are gc-prunable; keep a
   day of slack so a windowed count near the boundary never under-reports
   because gc ran just before the query. *)
let stats_event_retention_s = 28. *. 86_400. +. 86_400.

(* Render the /stats windows object from per-window counting closures. Both
   backends funnel through this so the JSON shape cannot diverge. *)
let stats_windows_json ~now ~messages_in_window ~aliases_in_window
    ~machines_in_window ~messages_ever ~aliases_ever ~machines_ever :
    Yojson.Safe.t =
  let window_obj messages aliases machines =
    `Assoc [
      ("messages", `Int messages);
      ("unique_aliases", `Int aliases);
      ("unique_machines", `Int machines);
    ]
  in
  `Assoc
    (List.map
       (fun (name, span) ->
         let cutoff = now -. span in
         ( name,
           window_obj (messages_in_window ~cutoff) (aliases_in_window ~cutoff)
             (machines_in_window ~cutoff) ))
       stats_windows
     @ [ ("ever", window_obj messages_ever aliases_ever machines_ever) ])

(* B148: render the /stats "connected" object — aggregate liveness counts only
   (NEVER aliases, node_ids, or session ids; same privacy rule as the windows).
   Count-map keys are sorted for deterministic JSON so the landing page and
   tests can pin them, and so the two backends can't emit a different key
   order. Both backends funnel through this so the shape cannot diverge.
   B149 adds by_version / by_os from client-reported connection metadata
   (clients that predate the fields land under "unknown"). *)
let sorted_count_map (counts : (string * int) list) : Yojson.Safe.t =
  `Assoc
    (List.map
       (fun (k, v) -> (k, `Int v))
       (List.sort (fun (a, _) (b, _) -> String.compare a b) counts))

let stats_connected_json ~clients ~machines
    ~(by_client_type : (string * int) list)
    ~(by_version : (string * int) list) ~(by_os : (string * int) list) :
    Yojson.Safe.t =
  `Assoc
    [
      ("clients", `Int clients);
      ("machines", `Int machines);
      ("by_client_type", sorted_count_map by_client_type);
      ("by_version", sorted_count_map by_version);
      ("by_os", sorted_count_map by_os);
    ]

(* B148: full /stats stats object — the 1d/7d/28d/ever windows (byte-compatible
   with [stats_windows_json], which the landing page + B147 tests pin) plus a
   top-level [connected] key. Both backends call this so the combined shape is
   defined in exactly one place. *)
let stats_json ~now ~messages_in_window ~aliases_in_window ~machines_in_window
    ~messages_ever ~aliases_ever ~machines_ever ~connected : Yojson.Safe.t =
  match
    stats_windows_json ~now ~messages_in_window ~aliases_in_window
      ~machines_in_window ~messages_ever ~aliases_ever ~machines_ever
  with
  | `Assoc kvs -> `Assoc (kvs @ [ ("connected", connected) ])
  | other -> other
