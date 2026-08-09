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
(** Re-export of {!C2c_pid_identity.pid_alive}.

    Answers "does a process with this number exist", NOT "is this still ours".
    Before signalling a pid that came off disk, use
    {!C2c_pid_identity.pidfile_pid_is_ours} instead (#85). *)

val purpose_to_string : purpose -> string
val state_to_string : liveness_state -> string
