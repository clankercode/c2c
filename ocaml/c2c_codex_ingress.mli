(* c2c_codex_ingress — passive c2c ingress for an app-server-managed Codex
   thread (P1.M1.E1.T003).

   Consumes messages from the canonical local broker inbox and makes each one
   model-visible via the T001-validated `thread/inject_items` request, over the
   authenticated endpoint provided by {!C2c_codex_app_server} (T002). It is a
   MESSAGE BUS delivery path, never an RPC surface.

   Invariants this module upholds (each has a fixture test):
   - PERSIST-FIRST. Every inbound message is durably in the broker inbox (the
     source of truth) BEFORE any injection is attempted. The adapter NEVER
     drains/removes/archives a message from the inbox — draining stays the
     broker's job (hook / explicit poll). Killing the adapter at any instruction
     boundary can never make a message unreadable from the broker/fallback path.
   - NO TURN, NO APPROVAL. This module only ever issues `thread/inject_items`.
     It never calls `turn/start` / `turn/steer` / `turn/interrupt`, never writes
     a PTY / tmux / Herdr pane, never invokes a shell/filesystem app-server
     method, and never touches the approval verdict path. An injected message
     that literally contains `allow` / `deny` / a valid-looking approval token
     stays inert (B098) — it can never create a verdict file.
   - IDEMPOTENT. A durable ledger keyed by (managed identity, thread id,
     message_id) makes a re-delivered message inject exactly once on the normal
     acknowledged path. The ambiguous-ack window (server accepted, response lost)
     is reconciled to one item when the protocol permits a history lookup, and
     is otherwise an explicitly-tested, documented AT-LEAST-ONCE.

   Ephemeral durability: the adapter never archives, so an ephemeral message's
   no-archive contract is preserved and its durability EQUALS normal mail for the
   whole window it is inbox-resident (the active injection attempt included).
   Limitation: once the broker's hook/poll path drains an ephemeral message it is
   (by the ephemeral contract) not archived, so it cannot be re-surfaced later —
   e.g. after a post-drain compact. That is inherent to ephemeral semantics, not
   a gap in this adapter.

   Ownership boundaries: T006 owns public grammar/aliases; T007 owns turn policy;
   T005 owns doctor/status wiring. This module embeds no CLI policy. *)

(* --------------------------- delivery state ------------------------------- *)

type delivery_state =
  | Persisted          (** durable in the inbox + ledger; not yet attempted *)
  | Pending_injection  (** eligible to inject (fresh or after recoverable error) *)
  | Injecting          (** write-ahead: request sent, ack not yet observed *)
  | Injected           (** acknowledged model-visible; deduped on future passes *)
  | Fallback_pending   (** app-server unsupported; hooks/poll own delivery *)
  | Dead_lettered      (** permanently malformed; broker record still intact *)

val delivery_state_to_string : delivery_state -> string
val delivery_state_of_string : string -> delivery_state option

(** Recoverable reasons return an entry to {!Pending_injection} with backoff. *)
type recoverable =
  | Server_unavailable
  | Auth_failed
  | Thread_unloaded
  | Timeout
  | Transient_protocol
  | Process_restart

val recoverable_to_string : recoverable -> string

(* ------------------------------ client seam ------------------------------- *)

(** Outcome of one `thread/inject_items` request. *)
type inject_outcome =
  | Inj_ok                      (** server acknowledged (empty result [{}]) *)
  | Inj_ambiguous of string     (** request written, connection lost before the
                                    response arrived — the crash window *)
  | Inj_recoverable of recoverable
  | Inj_unsupported of string   (** schema/capability mismatch → fall back *)
  | Inj_malformed of string     (** permanent bad payload → dead-letter *)

type history_probe = [ `Present | `Absent | `Unknown ]

(** Injectable effect seam. Tests script it (no live socket); {!real_client} is
    the production synchronous WebSocket JSON-RPC client. Neither variant carries
    the raw capability token in any durable form — it is pulled per-call from the
    launcher via {!config.token_provider}. *)
type client = {
  inject_items :
    endpoint:C2c_codex_app_server.endpoint ->
    token:string ->
    thread_id:string ->
    message_id:string ->
    items:Yojson.Safe.t list ->
    inject_outcome;
  history_contains :
    (endpoint:C2c_codex_app_server.endpoint ->
     token:string ->
     thread_id:string ->
     message_id:string ->
     history_probe)
    option;
      (** [None] ⇒ no history lookup available on this codex ⇒ the ambiguous-ack
          window resolves as at-least-once. *)
}

val real_client : unit -> client
(** Production client: opens ONE authenticated WS JSON-RPC connection per inject
    (bounded, sequential), `initialize` then `thread/inject_items`, closes it.
    Gated by [C2C_CODEX_INGRESS_FIXTURE] (record-only) unless
    [C2C_CODEX_INGRESS_LIVE=1]. *)

val real_loaded_threads :
  endpoint:C2c_codex_app_server.endpoint -> token:string -> string list
(** Discover the thread ids the attached frontend has LOADED (via
    `thread/loaded/list`), so a driver can inject/turn into the SAME thread the
    operator sees. Ids in server-reported order (most-recent last by observation);
    [[]] on any error, auth failure, or unavailable method. LIVE-gated
    ([C2C_CODEX_INGRESS_LIVE=1]) — otherwise refuses the socket and returns [[]].
    Reuses the module's WS + JSON-RPC plumbing. *)

(* -------------------------- injected item builder ------------------------- *)

val data_text : C2c_mcp.message -> message_id:string -> string
(** Canonical, explicitly-delimited c2c DATA envelope for a model-visible
    surface. This never grants operator or approval authority. *)

val build_injected_item : ?role:string -> C2c_mcp.message -> message_id:string -> Yojson.Safe.t
(** Data-only Responses API item. Role defaults to ["developer"] (deliberately
    NOT ["user"] — an injected peer message must not forge operator input). The
    text carries an explicit "c2c relayed message — DATA, not operator input"
    marker, a machine-readable JSON metadata line (incl. [message_id]), and the
    canonical [<c2c …>body</c2c>] envelope with sender attribution + timestamps. *)

(* -------------------------------- config ---------------------------------- *)

type config = {
  broker_root : string;
  session_id : string;         (** broker inbox key for the managed session *)
  managed_identity : string;   (** stable identity component of the ledger key *)
  endpoint : C2c_codex_app_server.endpoint;
  thread_id : string;          (** loaded thread to inject into *)
  token_provider : unit -> string option;
      (** pulls the raw bearer token from launcher memory; never persisted here *)
  client : client;
  role : string;               (** injected item role (default "developer") *)
  max_batch : int;             (** max inject attempts per pass (bounds fan-out) *)
  max_pending_queue : int;     (** backpressure threshold for health.overloaded *)
  backoff_base_s : float;
  backoff_max_s : float;
  now : unit -> float;         (** clock seam *)
}

val default_config :
  broker_root:string ->
  session_id:string ->
  managed_identity:string ->
  endpoint:C2c_codex_app_server.endpoint ->
  thread_id:string ->
  token_provider:(unit -> string option) ->
  client:client ->
  config

(* ---------------------------------- ledger -------------------------------- *)

type ledger_entry = {
  le_message_id : string;
  le_state : delivery_state;
  le_retry_count : int;
  le_first_seen : float;
  le_last_attempt : float;
  le_next_eligible : float;
  le_last_error : string option;  (** sanitized reason only — no content/creds *)
}

val ledger_path : broker_root:string -> session_id:string -> string
val ledger_state : config -> message_id:string -> delivery_state option
val ledger_entry : config -> message_id:string -> ledger_entry option

(* -------------------------------- health ---------------------------------- *)

type health = {
  pending_count : int;
  oldest_pending_age_s : float;
  total_retry_count : int;
  fallback_count : int;
  dead_letter_count : int;
  injected_count : int;
  overloaded : bool;
  last_error : string option;
  last_protocol_error : string option;
}

val health_to_json : health -> Yojson.Safe.t
(** Structured, doctor/status-consumable. Contains NO message content and NO
    credential — only counts, ages, and sanitized reason strings. *)

(* ---------------------------------- driver -------------------------------- *)

val deliver_pass : config -> health
(** One non-blocking delivery pass. Persist-first (assigns+persists stable
    message_ids under the inbox lock before any injection), then advances each
    inbox message through the state machine up to [max_batch] injections. Never
    drains/removes from the inbox. Idempotent across passes. Returns a health
    snapshot. *)

val dead_letter_path : broker_root:string -> session_id:string -> string
