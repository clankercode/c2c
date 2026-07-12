open Relay_common

module RegistrationLease : sig
  type t
  val make : node_id:string -> session_id:string -> alias:string -> ?client_type:string -> ?registered_at:float -> ?last_seen:float -> ?ttl:float -> ?identity_pk:string -> ?enc_pubkey:string -> ?signed_at:float -> ?sig_b64:string -> ?opaque_host_id:string option -> unit -> t
  val is_alive : t -> bool
  val touch : t -> unit
  val set_last_seen : t -> float -> unit
  val to_json : t -> Yojson.Safe.t
  val node_id : t -> string
  val session_id : t -> string
  val alias : t -> string
  val client_type : t -> string
  val identity_pk : t -> string
  val enc_pubkey : t -> string
  val signed_at : t -> float
  val sig_b64 : t -> string
  val registered_at : t -> float
  val last_seen : t -> float
  val opaque_host_id : t -> string option
end = struct
  type t = {
    node_id : string;
    session_id : string;
    alias : string;
    client_type : string;
    registered_at : float;
    mutable last_seen : float;
    ttl : float;
    identity_pk : string;
    enc_pubkey : string;
    signed_at : float;
    sig_b64 : string;
    opaque_host_id : string option;
    (** Client-supplied opaque identifier for the host (12-16 hex chars,
        computed by `c2c host-id`). Slice 1 of the
        opaque_host_id design (.collab/design/2026-06-17-c2c-opaque-host-id.md):
        purely additive - None for leases registered before this field was
        added. The relay's /list handler emits the field when set; old
        consumers (no field in JSON) continue to work unchanged. *)
  }

  let make ~node_id ~session_id ~alias ?(client_type = "unknown") ?registered_at ?last_seen ?(ttl = default_lease_ttl) ?(identity_pk = "") ?(enc_pubkey = "") ?(signed_at = 0.0) ?(sig_b64 = "") ?(opaque_host_id : string option = None) () =
    let now = Unix.gettimeofday () in
    let registered_at = Option.value registered_at ~default:now in
    let last_seen = Option.value last_seen ~default:now in
    { node_id; session_id; alias; client_type; registered_at; last_seen; ttl; identity_pk; enc_pubkey; signed_at; sig_b64; opaque_host_id }

  let is_alive t =
    let now = Unix.gettimeofday () in
    (t.last_seen +. t.ttl) >= now

  let touch t =
    t.last_seen <- Unix.gettimeofday ()

  let set_last_seen t last_seen =
    t.last_seen <- last_seen

  let to_json t =
    let now = Unix.gettimeofday () in
    let base = [
      ("node_id", `String t.node_id);
      ("session_id", `String t.session_id);
      ("alias", `String t.alias);
      ("client_type", `String t.client_type);
      ("registered_at", `Float t.registered_at);
      ("last_seen", `Float t.last_seen);
      ("ttl", `Float t.ttl);
      ("alive", `Bool (is_alive t));
      ("alias_reserved", `Bool (not (alias_released ~now ~last_seen:t.last_seen)));
      ("alias_warning_since", `Float (alias_warning_since ~last_seen:t.last_seen));
      ("alias_release_at", `Float (alias_release_at ~last_seen:t.last_seen));
      ("alias_release_warning", `Bool (alias_release_warning ~now ~last_seen:t.last_seen));
    ] in
    let base =
      if t.identity_pk = "" then base
      else base @ [("identity_pk", `String (b64url_nopad_encode t.identity_pk))]
    in
    let base =
      if t.enc_pubkey = "" then base
      else base @ [("enc_pubkey", `String (b64url_nopad_encode t.enc_pubkey))]
    in
    let base =
      if t.signed_at = 0.0 then base
      else base @ [("signed_at", `Float t.signed_at)]
    in
    let base =
      if t.sig_b64 = "" then base
      else base @ [("sig_b64", `String t.sig_b64)]
    in
    let base =
      match t.opaque_host_id with
      | Some h -> base @ [("opaque_host_id", `String h)]
      | None -> base
    in
    `Assoc base

  let node_id t = t.node_id
  let session_id t = t.session_id
  let alias t = t.alias
  let client_type t = t.client_type
  let identity_pk t = t.identity_pk
  let enc_pubkey t = t.enc_pubkey
  let signed_at t = t.signed_at
  let sig_b64 t = t.sig_b64
  let registered_at t = t.registered_at
  let last_seen t = t.last_seen
  let opaque_host_id t = t.opaque_host_id
end
