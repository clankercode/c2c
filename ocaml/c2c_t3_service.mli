(** Discovery and routing ownership for a c2c connector serving an unmodified
    T3 Code instance.

    This module deliberately keeps enumeration/reconciliation separate from
    the later message worker. T3 list results are snapshots: a complete scan
    is required before a missing binding may be retired, and a missing bound
    thread is point-read before that decision. State is persisted before the
    corresponding broker registration is published. *)

type thread = {
  project_id : string;
  thread_id : string;
  title : string;
  parent_thread_id : string option;
  parent_known : bool;
  lifecycle_known : bool;
  archived : bool;
  settled : bool;
  deleted : bool;
  runtime_mode : string option;
  updated_at : string option;
}

val thread_of_json :
  project_id:string -> require_lifecycle:bool -> Yojson.Safe.t -> (thread, string) result
(** Decode one [t3_thread_list] or thread-detail object. A missing lineage
    parent is rejected because routing a fork as a root is unsafe. List rows
    may omit [archived], while detail rows must provide it. *)

val thread_of_activity :
  project_id:string -> C2c_t3_client.activity -> (thread, string) result
(** Decode the authoritative thread detail returned by [t3_thread_read]. *)

val is_open_root : thread -> bool
(** True only for an undeleted, unarchived, unsettled thread with an explicit
    null parentThreadId. *)

type eligibility =
  | Routable
  | Permission_ineligible of string
  | Retired of string

val eligibility : credential_access:string option -> thread -> eligibility
(** The connector's [auto] access token cannot operate a [full-access] root;
    such a root is retained as unroutable until its state changes. *)

type scan = {
  listed : thread list;
  project_ids : string list;
  complete : bool;
  errors : string list;
}

val discover : C2c_t3_client.client -> (scan, C2c_t3_client.error) result Lwt.t
(** Enumerate every project and every thread page with
    [includeSubagents=false]. Calls are serialized by the client and a failed
    project/page marks the scan incomplete. Incomplete scans never authorize
    retirement. *)

type discovery_operations = {
  list_projects : unit -> (C2c_t3_client.page, C2c_t3_client.error) result Lwt.t;
  list_threads :
    project_id:string -> include_subagents:bool -> unit ->
    (C2c_t3_client.page, C2c_t3_client.error) result Lwt.t;
  read_activity :
    thread_id:string -> (C2c_t3_client.activity, C2c_t3_client.error) result Lwt.t;
}

val discover_with :
  operations:discovery_operations -> (scan, C2c_t3_client.error) result Lwt.t
(** Testable discovery seam. The production {!discover} supplies the native
    client operations; callers must still pass [include_subagents=false]. *)

val missing_bound_thread_ids :
  scan:scan -> mappings:C2c_t3_state.mapping list -> string list
(** Active, non-tombstoned mappings absent from a completed list snapshot.
    Callers must point-read each returned id before planning retirement. The
    result is empty for an incomplete scan. *)

type point_read =
  | Present of thread
  | Not_found_same_environment
  | Failed of string

val read_bound_thread :
  C2c_t3_client.client -> thread_id:string -> (point_read, C2c_t3_client.error) result Lwt.t
(** Point-read a previously bound thread. Only the narrow, explicit T3
    not-found codes become [Not_found_same_environment]; authentication,
    transport and all other tool failures remain [Failed]. *)

val read_bound_thread_with :
  read_activity:(thread_id:string ->
    (C2c_t3_client.activity, C2c_t3_client.error) result Lwt.t) ->
  thread_id:string -> (point_read, C2c_t3_client.error) result Lwt.t
(** Testable point-read seam used by {!read_bound_thread}. *)

val error_is_same_environment_not_found : C2c_t3_client.error -> bool
(** Exact external MCP contract code used by [read_bound_thread]. *)

type candidate = { thread : thread; mapping : C2c_t3_state.mapping option }

type plan = {
  routable : candidate list;
  unroutable : (candidate * string) list;
  retire : (C2c_t3_state.mapping * string) list;
  degraded : string list;
}

val plan_reconciliation :
  ?credential_access:string option ->
  scan:scan ->
  mappings:C2c_t3_state.mapping list ->
  point_reads:(string * point_read) list ->
  unit -> plan
(** Build a deterministic lifecycle plan. [point_reads] is required for every
    previously bound id absent from a complete list; failed/missing reads keep
    the mapping and degrade health. A partial scan cannot retire anything. *)

type owner = {
  environment_id : string;
  broker : C2c_mcp.Broker.t;
  pid : int option;
  pid_start_time : int option;
  cwd : string option;
  opaque_host_id : string option;
}

val service_registered_by : string
val service_session_id : environment_id:string -> thread_id:string -> string
val publish_mapping : owner:owner -> mapping:C2c_t3_state.mapping -> (unit, string) result
val unpublish_mapping : owner:owner -> mapping:C2c_t3_state.mapping -> (unit, string) result
(** Publish/remove only the registration bearing this service's marker and
    deterministic session id. A foreign registration is never removed. *)

type apply_result = {
  published : candidate list;
  held : (candidate * string) list;
  retired : (C2c_t3_state.mapping * string) list;
  errors : string list;
}

val apply_plan :
  owner:owner -> state:C2c_t3_state.t -> plan:plan -> apply_result
(** Apply a plan in the safe order. New/reopened mappings are persisted before
    service-owned broker registration; retirement removes the owned broker row
    before writing its tombstone so a crash cannot leave a live route with no
    durable mapping. *)

type locator_result =
  | Alias of string
  | Thread_alias of string
  | Ambiguous_thread of string
  | Unknown_thread of string

val resolve_locator :
  mappings:C2c_t3_state.mapping list -> registered_aliases:string list ->
  string -> locator_result
(** Resolve a normal alias (including [alias@host]) or local [t3.<thread-id>].
    A literal registered alias always wins; thread lookup is only used when it
    is unambiguous and the mapping is not tombstoned. *)

(** {1 Durable inbound delivery} *)

type delivery_mode = [ `Auto | `Queue | `Steer | `Restart ]

type accept_result = {
  accepted : int;
  held : (string * string) list;
  errors : string list;
}

type dispatch_step =
  | Idle
  | Waiting of float
  | Submitted of string
  | Retained of string
  | Held of string
  | Rebind_required of string

type dispatch_batch = {
  steps : dispatch_step list;
  budget_exhausted : bool;
}

type send =
  thread_id:string -> message:string -> mode:delivery_mode ->
  client_request_id:string ->
  (C2c_t3_client.receipt, C2c_t3_client.error) result Lwt.t

val format_data : ?cross_repo:bool -> C2c_mcp.message -> (string, string) result
(** Render one broker message as explicit untrusted DATA followed by one
    canonical reply route. Sender aliases are validated before interpolation;
    the body is never interpreted as a footer or shell fragment. *)

val accept_inbox :
  ?mode:delivery_mode -> ?cross_repo:bool -> owner:owner -> state:C2c_t3_state.t ->
  mapping:C2c_t3_state.mapping -> unit -> accept_result
(** Peek a service-owned inbox, persist each request, then acknowledge the
    exact broker message ID. A failure before acknowledgement leaves mail in
    the broker; a malformed message is durably held and never sent. *)

type dispatcher

val create_dispatcher :
  ?spacing:float -> ?can_send:(C2c_t3_state.entry -> bool) ->
  ?preflight:(C2c_t3_state.entry -> (unit, string) result Lwt.t) ->
  ?credential_generation:(unit -> int) ->
  ?flush_deferrable:bool ->
  state:C2c_t3_state.t -> send:send -> clock:(unit -> float) -> unit -> dispatcher
(** Create the single serial dispatcher shared by normal delivery and later
    recovery intents. The submission boundary is persisted before each MCP
    call, so restart cannot burst past [spacing]. Deferrable entries remain
    pending until [flush_deferrable] is true or {!release_deferrable} is
    called. *)

val release_deferrable : dispatcher -> unit
(** Release deferrable entries for the next dispatches. This is an explicit
    idle/turn-boundary flush; it does not alter the durable entries. *)

val hold_deferrable : dispatcher -> unit
(** Re-arm the default hold policy after a flush. *)

val error_requires_rebind : C2c_t3_client.error -> bool
(** Runtime incarnation failures are transient until the caller recreates or
    re-authorizes its client. Authentication denial is permanent here: the
    client contract requires explicit re-pairing, which is outside the
    dispatcher. *)

val dispatch_once : ?flush_deferrable:bool -> dispatcher -> dispatch_step Lwt.t
(** Submit at most one due request. The caller owns the service loop and may
    sleep for [Waiting delay]; this function never overlaps calls or sleeps.
    [Rebind_required] leaves the exact request pending and asks the caller to
    re-authorize before constructing another dispatcher. *)

val dispatch_batch :
  ?max_steps:int -> ?flush_deferrable:bool -> dispatcher -> dispatch_batch Lwt.t
(** Run at most [max_steps] serial dispatch decisions without sleeping. The
    [budget_exhausted] flag is a maintenance fairness boundary: callers must
    return to discovery/recovery/lease work before requesting another batch. *)
