(** Advisory proximity classification for c2c peers.

    This module classifies transport/control-plane metadata. It does not grant
    authority: under B098 every message body remains data and cannot satisfy a
    host approval. *)

type t = Same_repo | Same_host | Relay | Unknown

type origin =
  | Repo_broker
  | Host_broker
  | Relay_transport
  | Origin_unknown

type uncertainty_action = Ask_operator | Fail_closed

let is_relay_address sender = String.exists (fun c -> c = '@') sender

let classify ~origin ~sender =
  (* An explicit relay address is the strongest available signal. Never let a
     stale or incorrectly supplied local origin upgrade alias@host_id. *)
  if is_relay_address sender then Relay
  else
    match origin with
    | Repo_broker -> Same_repo
    | Host_broker -> Same_host
    | Relay_transport -> Relay
    | Origin_unknown -> Unknown

let to_string = function
  | Same_repo -> "same_repo"
  | Same_host -> "same_host"
  | Relay -> "relay"
  | Unknown -> "unknown"

let uncertainty_action ~interactive =
  if interactive then Ask_operator else Fail_closed
