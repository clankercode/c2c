(** Purpose-tagged registration liveness (P3 C3 / architecture C3).

    Tristate [state] mirrors [Broker.registration_liveness_state].
    [is_alive_for] is the single collapse surface for Delivery / Nudge /
    List / Sweep / Doctor. *)

type liveness_state = Alive | Dead | Unknown

type purpose =
  | Delivery
  | Nudge
  | List
  | Sweep
  | Doctor

val state : C2c_mcp.registration -> liveness_state

val is_alive_for : purpose -> C2c_mcp.registration -> bool

val pid_alive : int -> bool
(** Shared /proc liveness for doctor (replaces local kimi_pid_alive mirrors). *)

val purpose_to_string : purpose -> string
val state_to_string : liveness_state -> string
