(* Exclusive delivery owner for one Codex machine-daemon thread (I6).

   A lease is keyed by canonical control-socket identity + Codex thread id —
   never by a c2c session/alias, so two aliases cannot both inject into the
   same thread. Live holders are detected with {!C2c_pid_identity}; a stale
   pid is reclaimable. Message idempotency stays in the T003 ingress ledger
   (message_id), independent of daemon generation. *)

type lease = {
  socket_identity : string;
  thread_id : string;
  sidecar_pid : int;
  claimed_at : float;
  heartbeat_at : float;
  alias : string;
  broker_session_id : string;
}

type claim_result =
  | Claimed of lease
  | Already_ours of lease
  | Held_live of lease
  | Reclaimed of lease

val lease_key : socket_identity:string -> thread_id:string -> string
(** Stable filename stem (32 hex chars) for [socket_identity] + [thread_id]. *)

val lease_path :
  owners_dir:string -> socket_identity:string -> thread_id:string -> string

val try_claim :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  sidecar_pid:int ->
  alias:string ->
  broker_session_id:string ->
  ?now:float ->
  ?holder_live:(lease -> bool) ->
  unit ->
  claim_result
(** [holder_live] defaults to {!C2c_pid_identity} on [lease.sidecar_pid] with
    [Started_at claimed_at]. Unverifiable counts as live (fail closed). *)

val heartbeat :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  sidecar_pid:int ->
  ?now:float ->
  unit ->
  lease option
(** Refresh [heartbeat_at] only if this pid still holds the lease. *)

val release :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  sidecar_pid:int ->
  unit
(** Drop the lease if this pid holds it. Total otherwise. *)

val peek :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  lease option

val default_owners_dir : unit -> string
val default_control_socket : unit -> string option
(** Absolute path of the machine daemon control socket when it exists. *)

val unix_endpoint : string -> C2c_codex_app_server.endpoint option
(** [{transport="unix"; host=realpath; port=0}] when [path] exists. *)

val select_owned_thread : hint:string -> loaded:string list -> string option
(** [Some hint] iff [hint] is in [loaded]. Never picks a different loaded
    thread. *)

type arm_result =
  | Armed of { child_pid : int }
  | Already_running of lease
  | Socket_unavailable
  | Claim_held of lease

val arm :
  thread_id:string ->
  alias:string ->
  broker_session_id:string ->
  broker_root:string ->
  ?instance_name:string ->
  ?owners_dir:string ->
  ?socket_path:string ->
  unit ->
  arm_result
(** Fork+setsid a sidecar. The child waits until [thread_id] appears in
    [thread/loaded/list], then claims that Codex thread (never a different
    loaded thread) and drives {!C2c_codex_deliver_loop} pinned to it.
    Fail-closed if a live other owner holds the thread or the hint never
    loads. *)

val stop_pid : int -> unit
(** Terminate a sidecar process and escalate to SIGKILL after a short grace
    period. The pid may already have been reparented, so this is best effort. *)
