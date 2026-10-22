(** File location is a leaf so activation can be used by the connector without
    importing relay-state diagnostics (which themselves inspect the connector). *)
type t =
  | Relay_config_machine of string
  | Relay_config_repo of string
  | Relay_config_explicit of string

let path_of = function
  | Relay_config_machine p | Relay_config_repo p | Relay_config_explicit p -> p
