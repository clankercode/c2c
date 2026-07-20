(* C2c_liveness — purpose-tagged registration liveness (P3 C3).

   Facade-first deepen: tristate computation remains in Broker (docker lease,
   hook TTL, pid/start-time). This module is the single place for:
   - purpose collapse rules (Delivery/Nudge/List/Sweep/Doctor)
   - shared /proc pid helpers (doctor must not reimplement)

   Callers that need "is this alive for X?" use [is_alive_for], not ad-hoc
   Unknown→bool collapses. Broker.registration_is_alive remains for back-compat
   and still defines Delivery/List/Sweep semantics.
*)

type liveness_state = Alive | Dead | Unknown

type purpose =
  | Delivery
  | Nudge
  | List
  | Sweep
  | Doctor

let state (reg : C2c_mcp.registration) : liveness_state =
  match C2c_mcp.Broker.registration_liveness_state reg with
  | C2c_mcp.Broker.Alive -> Alive
  | C2c_mcp.Broker.Dead -> Dead
  | C2c_mcp.Broker.Unknown -> Unknown

(** Purpose-tagged alive check. Preserves pre-C3 semantics:
    - Nudge / Doctor: strict Alive only (Unknown is not alive)
    - Delivery / List / Sweep: same as [Broker.registration_is_alive]
      (Unknown collapses toward "treat as alive" for enqueue/sweep compat) *)
let is_alive_for (purpose : purpose) (reg : C2c_mcp.registration) : bool =
  match purpose with
  | Nudge | Doctor -> state reg = Alive
  | Delivery | List | Sweep -> C2c_mcp.Broker.registration_is_alive reg

let pid_alive (pid : int) : bool =
  pid > 0 && Sys.file_exists (Printf.sprintf "/proc/%d" pid)

let purpose_to_string = function
  | Delivery -> "delivery"
  | Nudge -> "nudge"
  | List -> "list"
  | Sweep -> "sweep"
  | Doctor -> "doctor"

let state_to_string = function
  | Alive -> "alive"
  | Dead -> "dead"
  | Unknown -> "unknown"
