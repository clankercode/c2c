(* c2c_codex_autoturn — safe auto-turn dispatcher for eligible local c2c mail on
   an app-server-managed Codex session (P1.M1.E1.T007).

   Sits ON TOP of the T003 passive-ingress adapter ({!C2c_codex_ingress}). One
   {!deliver_pass}:
   1. persist-first + inject eligible mail as model-visible DATA (via T003),
   2. for LOCAL-broker-provenance mail only, DND off, session active, and no turn
      already in flight, starts at most ONE batched Codex `turn/start` so the
      agent acts/responds.

   Design decision (coordinator/Max, backed by T004): composer-state gating was
   intentionally DROPPED. T004 proved live (codex 0.144.1) that an app-server
   turn CANNOT touch the operator's composer draft (frontend-only state the
   app-server never sees). There is no composer-empty signal in the protocol and
   none is needed; auto-turn does not depend on composer state.

   Turn lifecycle facts this module is built on (T004, codex 0.144.1):
   - NO `turn/started` notification is emitted; the turn id is in the `turn/start`
     RESPONSE (`result.turn.id`).
   - Lifecycle is observed via `thread/status`(read) idle<->active.
   - The app-server does NOT self-serialize: a concurrent `turn/start` is accepted
     as a distinct turn — so THIS module owns the queue-if-active gate.

   Invariants (each fixture-tested): persist-first; local-provenance-only turn
   trigger; per-recipient serialization; DND honored; B098 approval isolation
   (the turn only surfaces DATA — a message literally containing `allow`/`deny`
   can never write a verdict); acknowledged-path exactly-once + held (never
   blindly replayed) ambiguous-ack. Metrics/logs expose queued reason, batch and
   message ids, redacted recipient — never bodies, credentials, or composer. *)

module Ep = C2c_codex_app_server
module Ingress = C2c_codex_ingress

(* ------------------------------ provenance -------------------------------- *)

type provenance = [ `Local | `Remote ]

val provenance_to_string : provenance -> string

(** Default provenance: [`Remote] iff [from_alias] carries an `@host` relay
    marker (relay-forwarded mail), else [`Local]. Overridable in {!config} so a
    future trust policy can widen what counts as auto-turn-eligible. *)
val default_provenance : C2c_mcp.message -> provenance

(* ------------------------------ turn client ------------------------------- *)

type thread_status = [ `Idle | `Active | `Unknown ]

val thread_status_to_string : thread_status -> string

(** Outcome of one `turn/start`. The turn id is captured from the RESPONSE (no
    `turn/started` notification exists on codex 0.144.1). [Turn_ambiguous] = the
    request was written but the response was lost — the batch is HELD, never
    blindly replayed. *)
type turn_start_outcome =
  | Turn_started of string
  | Turn_ambiguous of string
  | Turn_recoverable of Ingress.recoverable
  | Turn_unsupported of string
  | Turn_rejected of string

val turn_start_outcome_to_string : turn_start_outcome -> string

type history_probe = [ `Present | `Absent | `Unknown ]

(** Effect seam for turn control. Tests script it (no live socket);
    {!real_turn_client} is the production synchronous WS JSON-RPC client. The raw
    token is pulled per-call from {!Ingress.config.token_provider}, never held. *)
type turn_client = {
  thread_status :
    endpoint:Ep.endpoint -> token:string -> thread_id:string -> thread_status;
  start_turn :
    endpoint:Ep.endpoint ->
    token:string ->
    thread_id:string ->
    batch_key:string ->
    items:Yojson.Safe.t list ->
    turn_start_outcome;
  turn_in_history :
    (endpoint:Ep.endpoint ->
     token:string ->
     thread_id:string ->
     batch_key:string ->
     history_probe)
    option;
}

val real_turn_client : unit -> turn_client
(** Production client: one authenticated WS connection per call (`initialize`
    then `turn/start` or `thread/read`). Gated by [C2C_CODEX_INGRESS_LIVE=1]
    (shared with the T003 real client) — otherwise it refuses to touch a
    socket, so tests must inject a scripted client. *)

(* ------------------------------ batch state ------------------------------- *)

type batch_state =
  | Batch_claimed
  | Turn_running of string
  | Turn_ambiguous_held of string
  | Turn_done
  | Turn_failed

val batch_state_to_string : batch_state -> string

(* --------------------------------- config --------------------------------- *)

type config = {
  ingress_cfg : Ingress.config;
  turn_client : turn_client;
  session_active : unit -> bool;
  is_dnd : unit -> bool;
  provenance : C2c_mcp.message -> provenance;
  now : unit -> float;
  max_turn_batch : int;
  backoff_base_s : float;
  backoff_max_s : float;
}

(** Build a config reusing a T003 {!Ingress.config} (broker root, session id,
    managed identity, endpoint, thread id, token provider, inject client).
    [session_active]/[is_dnd] are injectable gate seams (production wires them to
    the app-server handle liveness + broker DND). *)
val default_config :
  ingress_cfg:Ingress.config ->
  turn_client:turn_client ->
  session_active:(unit -> bool) ->
  is_dnd:(unit -> bool) ->
  config

(* --------------------------------- ledger --------------------------------- *)

val turn_ledger_path : broker_root:string -> session_id:string -> string
val batch_state : config -> batch_key:string -> batch_state option
val active_batch_key : config -> string option

(** Stable batch/idempotency key from (thread_id, ordered message_ids). *)
val batch_key_of : config -> message_ids:string list -> string

val build_turn_nudge : batch_key:string -> count:int -> Yojson.Safe.t
(** Neutral, content-free DATA turn input. Role ["developer"] (never operator
    ["user"]) — carries only a count + batch key, NO message body/credential, so
    B098 stays airtight. *)

(* -------------------------------- outcome --------------------------------- *)

type queued_reason =
  | Q_offline
  | Q_dnd
  | Q_active_turn
  | Q_ambiguous_held
  | Q_no_eligible
  | Q_remote_only
  | Q_turn_recoverable of Ingress.recoverable
  | Q_turn_failed

val queued_reason_to_string : queued_reason -> string

type pass_outcome = {
  po_queued_reason : queued_reason option;
      (** [None] iff a turn was started this pass. *)
  po_turn_started : string option;
  po_batch_key : string option;
  po_batch_message_ids : string list;
  po_completed_batch : string option;
  po_reconciled_batch : string option;
  po_eligible_pending : int;
  po_remote_pending : int;
  po_injected_count : int;
  po_recipient : string;   (** redacted — never the raw managed identity *)
}

val pass_outcome_to_json : pass_outcome -> Yojson.Safe.t
(** Structured metrics/log line: queued reason, batch/message ids, trigger and
    reconcile outcome, redacted recipient. Contains NO message content, NO
    credential, NO composer state. *)

(* --------------------------------- driver --------------------------------- *)

val deliver_pass : config -> pass_outcome
(** One non-blocking pass. Gates (offline / DND) short-circuit before any inject
    or turn. Otherwise: persist-first + inject via T003, advance/reconcile any
    active batch, then — if local-provenance mail is pending and no turn is in
    flight — claim + start at most ONE batched turn (write-ahead persisted before
    the request). Idempotent + serialized across passes. Never turn/steer,
    never turn/interrupt, never touches an approval verdict. *)
