(** DeliveryEndpoint hybrid seam (P3 C1 / architecture C1).

    [probe] / [deliver] / [drain_policy] per client adapter. Registry starts
    with kimi; Mode_* fan-out remains for legacy arms until ≥2 adapters. *)

type probe_result =
  [ `Live
  | `Dead of string
  | `Unknown
  ]

type drain_policy =
  | After_push
  | Hooks_own_drain
  | Never

type endpoint = {
  kind : string;
  broker_root : string;
  session_id : string;
  alias : string;
  workdir : string option;
}

module type S = sig
  val kind : string
  val probe : endpoint -> probe_result
  val deliver : endpoint -> C2c_mcp.message -> (unit, string) result
  val drain_policy : drain_policy
end

type adapter = (module S)

val register : adapter -> unit
val find : string -> adapter option
val list_kinds : unit -> string list

val endpoint_of_kimi_reg :
  broker_root:string -> C2c_mcp.registration -> endpoint option

module Kimi : S
module Agy : S

val endpoint_of_agy_reg :
  broker_root:string -> C2c_mcp.registration -> endpoint option

val drain_policy_to_string : drain_policy -> string
val probe_to_string : probe_result -> string
