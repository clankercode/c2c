(** Coordination for relay advertisements owned by a long-lived service.

    The machine relay connector remains the sole owner of lease registration and
    heartbeat. This module only decides when a service-owned alias may publish
    or renew its advertisement, and refuses foreign leases. Retirement stops
    local publication/renewal; the relay's TTL is the remote expiry mechanism.
*)

type lease = {
  alias : string;
  host_id : string;
  session_id : string;
}

(** A service-owned advertisement intent. [eligible] is false when the service
    has retired the target, but the identity is retained for tombstone checks. *)
type intent = {
  lease : lease;
  eligible : bool;
}

type observed = {
  lease : lease;
  expires_at : float;
  public : bool;
}

type action =
  | Publish
  | Renew
  | Stop_renewal
  | Wait_for_connector
  | Keep
  | Refuse_foreign

type plan = {
  actions : action list;
  reason : string;
}

type claim_error = Foreign_owner of lease

type registry

val make_lease : alias:string -> host_id:string -> session_id:string -> lease
val remote_address : lease -> string
val same_owner : lease -> lease -> bool
val owner_key : lease -> string

val create_registry : unit -> registry
val claim : registry -> lease -> (unit, claim_error) result
val release : registry -> lease -> bool
val owner : registry -> alias:string -> lease option

val plan :
  relay_enabled:bool ->
  now:float ->
  renew_before_s:float ->
  intent option ->
  observed option ->
  plan

(** Retry delay for a bounded caller. [attempt] is zero-based. *)
val retry_delay_s : base_s:float -> max_s:float -> attempt:int -> float

val action_to_string : action -> string
