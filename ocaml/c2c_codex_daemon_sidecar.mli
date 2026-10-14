(* Exclusive delivery owner for one Codex machine-daemon thread (I6).

   A lease is keyed by canonical control-socket identity + Codex thread id —
   never by a c2c session/alias, so two aliases cannot both inject into the
   same thread. Live holders are detected with {!C2c_pid_identity}; a lease
   without an exact process generation is unverifiable and remains blocking
   until an explicit safe stale cleanup. Message idempotency stays in the T003 ingress ledger
   (message_id), independent of daemon generation. *)

type lease = {
  socket_identity : string;
  thread_id : string;
  sidecar_pid : int;
  sidecar_pid_start_time : int option;
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
  | Claim_uncertain of string

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
  ?sidecar_pid_start_time:int ->
  ?now:float ->
  ?holder_live:(lease -> bool) ->
  unit ->
  claim_result
(** [holder_live] defaults to the claim-arbitration predicate. New leases use
    the exact persisted process generation; legacy leases fail closed and keep
    blocking a second owner until explicitly cleaned up. *)

val lease_live : lease -> bool
(** Exact liveness check for a lease. New leases compare the recorded process
    start-time generation. Legacy leases without a generation are false because
    they cannot prove which process owns the numeric PID. *)

val heartbeat :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  sidecar_pid:int ->
  sidecar_pid_start_time:int ->
  alias:string ->
  broker_session_id:string ->
  ?now:float ->
  unit ->
  lease option
(** Refresh [heartbeat_at] only when the lease filename, exact process
    generation, alias, and broker session identity all match. *)

val release :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  sidecar_pid:int ->
  ?sidecar_pid_start_time:int ->
  unit ->
  bool
(** Drop the lease only when this pid and its exact generation hold it. Returns
    [true] only after the exact lease file is confirmed absent. Lock, unlink,
    mismatch, and missing-generation failures return [false] and retain the
    ownership record for retry. *)

val release_before_cleanup : release:(unit -> bool) -> cleanup:(unit -> bool) -> bool
(** Run [cleanup] only after [release] confirms exact lease removal.  A
    release or cleanup exception is reported as [false], leaving callers free
    to retain their dependent durable state for retry. *)

val peek :
  owners_dir:string ->
  socket_identity:string ->
  thread_id:string ->
  lease option

val default_owners_dir : unit -> string
val control_socket_path : codex_home:string -> string
(** [control_socket_path ~codex_home] returns Codex's canonical managed daemon
    control socket path for that CODEX_HOME. *)

val default_control_socket : unit -> string option
(** Absolute path of the machine daemon control socket when it exists. The
    explicit [C2C_CODEX_DAEMON_SOCK] override wins; otherwise [CODEX_HOME] is
    used, with [$HOME/.codex] as the default. *)

val unix_endpoint : string -> C2c_codex_app_server.endpoint option
(** [{transport="unix"; host=realpath; port=0}] when [path] exists. *)

val socket_available : string -> bool
(** True when the private Unix daemon socket accepts a WebSocket handshake. *)

val select_owned_thread : hint:string -> loaded:string list -> string option
(** [Some hint] iff [hint] is in [loaded]. Never picks a different loaded
    thread. *)

type arm_result =
  | Armed of { child_pid : int }
  | Already_running of lease
  | Socket_unavailable
  | Claim_held of lease
  | Arm_failed of string
  | Arm_failed_ownership_retained of string

val arm :
  thread_id:string ->
  alias:string ->
  broker_session_id:string ->
  broker_root:string ->
  ?instance_name:string ->
  ?owners_dir:string ->
  ?socket_path:string ->
  ?arm_wait_s:float ->
  ?alias_from_auto_gen:bool ->
  unit ->
  arm_result
(** Fork+setsid a sidecar. The child waits until [thread_id] appears in
    [thread/loaded/list], then claims that Codex thread (never a different
    loaded thread) and drives {!C2c_codex_deliver_loop} pinned to it.
    Fail-closed if a live other owner holds the thread or the hint never
    loads. *)

val refresh_managed_registration :
  broker_root:string ->
  broker_session_id:string ->
  alias:string ->
  pid:int ->
  pid_start_time:int option ->
  ?alias_from_auto_gen:bool ->
  unit -> unit
(** Refresh the sidecar's authoritative broker registration while retaining
    existing registration metadata owned by the same session. *)

val arm_wait_budget_s : float
(** Default parent-side arm wait. It leaves headroom under the Codex hook's
    eight-second hard timeout. *)

val arm_failed_after_pending_cleanup :
  stopped:bool -> lease_released:bool -> registration_cleared:bool ->
  sidecar_pid_cleared:bool -> arm_result
(** Classify failure cleanup after a child became operational but its pending
    arm records could not be removed. Fallback is safe only after the exact
    child, lease, broker registration, and instance pid/generation pair are
    all gone. *)

val registration_is_live :
  broker_root:string ->
  broker_session_id:string ->
  alias:string ->
  pid:int ->
  pid_start_time:int ->
  bool
(** Read-back seam used by [arm]: registration must identify the live child
    exactly before the parent reports [Armed]. *)

val stop_pid : ?sidecar_pid_start_time:int -> int -> bool
(** Terminate a sidecar process and escalate to SIGKILL after a short grace
   period through an owner-bound pidfd. Returns false when the generation is
   unverifiable or pidfd signalling is unavailable. *)

val leases_for_session : owners_dir:string -> broker_session_id:string -> lease list
(** Enumerate leases owned by one c2c session. *)

val leases_for_thread : owners_dir:string -> thread_id:string -> lease list
(** Enumerate leases bound to one exact Codex thread. *)

val stop_lease : owners_dir:string -> lease -> bool
(** Validate the lease's recorded PID generation, stop it, confirm that the
    exact process is gone, then release it. Unverifiable or failed stops retain
    the lease and report the failure. *)

val stop_for_session : owners_dir:string -> broker_session_id:string -> bool
(** Stop only live sidecars whose lease names [broker_session_id], then release
    each lease with its exact PID. *)

val stop_for_thread : owners_dir:string -> thread_id:string -> bool
(** Stop only live sidecars whose lease names [thread_id], then release each
    lease with its exact PID generation. *)
