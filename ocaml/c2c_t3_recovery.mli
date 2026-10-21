(** Conservative model-availability recovery for an unmodified T3 server.

    T3's external activity API deliberately exposes less failure structure than
    the in-process projection store.  This module therefore has a small,
    fail-closed policy boundary: only complete root activity with an
    unambiguous failed run and a narrow model-availability message can create
    an intent.  The intent is a normal durable [C2c_t3_state.Recovery] journal
    entry, so the ordinary serial dispatcher can submit it and retry the exact
    request identity after a response-loss or restart. *)

type failure = {
  item_id : string;
  run_id : string;
  source_thread_id : string option;
  status : string option;
  message : string option;
}

val availability_message : string -> bool
(** True only for narrow model-unavailability or temporary-capacity wording. *)

val supported_server_version : string option -> bool
(** True only for a T3 version whose external activity/error contract has been
    measured for recovery. Unknown versions fail closed. *)

val version_hold_reason : string option -> string option
(** Human-readable hold reason for an unsupported or unknown server version. *)

val failures_of_activity : thread_id:string -> C2c_t3_client.activity -> failure list
(** Extract only external [error] activity rows.  Ordinary transcript text is
    never considered evidence. *)

type candidate = {
  thread_id : string;
  run_id : string;
  error_ids : string list;
  error_fingerprint : string;
  provider_instance_id : string;
  model : string;
  request_id : string;
  key : string;
}

type decision =
  | Eligible of candidate
  | Held of string

val candidate_equal : candidate -> candidate -> bool
(** Compare all evidence and provider identity used by a durable intent. *)

val candidate_of_entry : C2c_t3_state.entry -> (candidate, string) result
(** Decode a durable recovery entry for final preflight. *)

val decide :
  environment_id:string ->
  credential_generation:int ->
  thread_id:string ->
  driver_kind:string option ->
  provider_instance_id:string option ->
  model:string option ->
  C2c_t3_client.activity ->
  C2c_t3_client.queue ->
  decision
(** Evaluate one already enrolled root.  [credential_generation] is included
    in the resulting durable intent and does not affect eligibility. *)

val enqueue :
  state:C2c_t3_state.t ->
  environment_id:string ->
  credential_generation:int ->
  now:float ->
  candidate ->
  ([ `Appended | `Duplicate ], string) result
(** Persist the immutable literal [Continue] intent before any MCP send. *)

val can_dispatch : enabled:bool -> C2c_t3_state.entry -> bool
(** Dispatcher hook: disabling recovery holds recovery intents while ordinary
    inbound messages remain eligible. *)

val hold_reason :
  state:C2c_t3_state.t -> thread_id:string -> candidate:candidate -> now:float -> string option
(** Prevents multiple outstanding recoveries for one root and enforces the
    sixty-second per-thread cool-down after a submission, including across a
    process restart. *)

type sweep_result = {
  checked : int;
  checked_at : (string * float) list;
  enqueued : candidate list;
  duplicates : candidate list;
  held : (string * string) list;
  errors : (string * string) list;
}

val sweep_diagnostics :
  enabled:bool -> thread_ids:string list -> next_due_at:float ->
  sweep_result -> Yojson.Safe.t
(** Bounded last-sweep decisions for operator diagnostics: at most 64 sorted
    threads, fixed policy reasons and no raw API errors or transcript content.
    This is observational metadata, never delivery authority. *)

type operations = {
  capabilities : unit -> (C2c_t3_client.capabilities, C2c_t3_client.error) result Lwt.t;
  read_activity : string -> (C2c_t3_client.activity, C2c_t3_client.error) result Lwt.t;
  list_queue : string -> (C2c_t3_client.queue, C2c_t3_client.error) result Lwt.t;
}

val preflight_with :
  operations:operations ->
  environment_id:string ->
  credential_generation:int ->
  candidate:candidate ->
  unit -> (unit, string) result Lwt.t
(** Re-read capabilities, the complete activity window and queue immediately
    before submission. Succeeds only when the same failed root execution,
    error evidence, provider and model are still eligible. *)

val sweep_with :
  ?enabled:bool ->
  operations:operations ->
  state:C2c_t3_state.t ->
  environment_id:string ->
  credential_generation:int ->
  thread_ids:string list ->
  clock:(unit -> float) ->
  unit -> sweep_result Lwt.t
(** Testable operation seam used by the real client-backed sweep. A complete
    eligible read can re-arm or refresh an intent only if it provably has never
    been submitted and its credential generation still matches. Obsolete unsent
    runs receive a durable cancellation acknowledgment. Submitted uncertainty
    remains held for reconciliation and continues to block another recovery. *)

val sweep :
  ?enabled:bool ->
  client:C2c_t3_client.client ->
  state:C2c_t3_state.t ->
  environment_id:string ->
  credential_generation:int ->
  thread_ids:string list ->
  clock:(unit -> float) ->
  unit -> sweep_result Lwt.t
(** One serialized sweep.  The client itself serializes MCP operations; this
    function also performs each thread's reads in series. A disabled monitor
    performs no API calls. *)

type cadence

val create_cadence : ?interval:float -> ?initial_delay:float -> clock:(unit -> float) -> unit -> cadence
val cadence_due : cadence -> now:float -> [ `Due | `Waiting of float | `Running ]
val cadence_start : cadence -> now:float -> bool
val cadence_finish : cadence -> now:float -> unit
