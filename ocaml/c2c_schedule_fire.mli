(** Shared schedule-fire helpers.

    Extracted from {!C2c_start} so both the managed-session heartbeat loop
    and the MCP server schedule timer can reuse idle-gating and
    heartbeat-enqueue logic. *)

val agent_is_idle :
  now:float -> idle_threshold_s:float -> last_activity_ts:float option -> bool
(** Pure idle predicate. Returns [true] when the agent should be woken. *)

val last_activity_ts_for_alias :
  broker_root:string -> alias:string -> float option
(** Look up the registration for [alias], returning its [last_activity_ts]. *)

val enqueue_heartbeat :
  broker_root:string -> alias:string -> content:string -> unit
(** Enqueue a self-DM (heartbeat message). *)

val should_fire :
  broker_root:string -> alias:string -> C2c_mcp.schedule_entry -> bool
(** Decide whether a schedule entry should fire right now.
    Checks [only_when_idle] semantics against broker registration. *)
