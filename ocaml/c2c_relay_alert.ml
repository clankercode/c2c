(** B010: pure decision logic for surfacing relay-originated "degrading
    events" to local agents.

    The relay can raise PoW difficulty under load, rate-limit a connector,
    fail to satisfy a PoW challenge, or permanently dead-letter an outbound
    message. Historically those conditions were invisible to the agent — the
    connector logged them to stdout and moved on. This module turns observed
    relay conditions into severity-tagged {b emissions} that the connector
    enqueues as messages from the reserved [c2c-system] alias, so they flow
    through every existing delivery surface for free (MCP poll/peek, the
    channel push, the deliver-inbox daemon).

    {b Design constraints (locked, B010):}
    - Surface only {e degrading} events: difficulty INCREASE (warn),
      [pow_retry_failed] (err), DLQ/undeliverable (err), rate-limit
      rejection (warn). Difficulty {e decrease}/recovery is a light [info]
      edge. Routine connect/heartbeat/lease noise is never surfaced.
    - {b Edge-triggered dedup}: emit ONLY on a state transition. A sustained
      high-difficulty plateau, or a connector that stays rate-limited across
      many syncs, must NOT re-alert every sync. Last-state lives in {!state}
      and is threaded by the connector across sync passes.
    - {b Routing}: sender-specific events (a dead-lettered outbox entry) DM
      the originating sender alias; global events (difficulty change,
      rate-limit) broadcast to all locally-registered sessions.

    This module is intentionally {b pure} — no IO, no network, no clock. The
    connector observes relay responses, aggregates them into an
    {!observation} for the sync pass, and calls {!step}; the connector owns
    all side effects (inbox writes). That keeps the severity/dedup/routing
    decisions unit-testable without a live relay. *)

type severity =
  | Info
  | Warn
  | Err

let severity_to_string = function
  | Info -> "INFO"
  | Warn -> "WARN"
  | Err -> "ERR"

(** Where an emission should be delivered. *)
type target =
  | Broadcast        (** every locally-registered session *)
  | Dm of string     (** a specific alias (its live sessions) *)

let target_to_string = function
  | Broadcast -> "broadcast"
  | Dm alias -> "dm:" ^ alias

type emission = {
  severity : severity;
  target : target;
  kind : string;   (** machine tag: difficulty_increase | difficulty_decrease
                       | pow_retry_failed | rate_limited | dlq *)
  body : string;   (** human-readable, severity-tagged message body *)
}

(** Edge-trigger state persisted by the connector across sync passes. *)
type state = {
  last_difficulty : int;  (** highest PoW difficulty last surfaced; 0 = none *)
  rate_limited : bool;    (** currently inside a rate-limited plateau *)
  pow_failing : bool;     (** currently inside a pow_retry_failed plateau *)
}

let initial_state = {
  last_difficulty = 0;
  rate_limited = false;
  pow_failing = false;
}

(** A single permanently-failed outbound message. Discrete (one per
    dead-lettered outbox entry) — naturally edge-triggered because the entry
    is removed from the outbox once dead-lettered, so it cannot re-fire. *)
type dlq_event = {
  dlq_sender : string;  (** originating outbox [from_alias] (local) *)
  dlq_to : string;      (** intended remote recipient *)
  dlq_reason : string;  (** unknown_alias | recipient_dead | max_attempts | max_age *)
}

(** Aggregated observations for one connector sync pass. The connector fills
    this in as it processes register/heartbeat/send/poll responses, then calls
    {!step} once. *)
type observation = {
  obs_difficulty : int option;
    (** highest PoW difficulty surfaced by any relay response this sync, if
        any. [None] means "no difficulty observed" — NOT "difficulty is 0"
        (an empty outbox surfaces nothing). A [None] therefore never triggers
        a recovery edge; recovery only fires on an explicit lower value. *)
  obs_rate_limited : bool;        (** any rate_limit_exceeded this sync *)
  obs_pow_retry_failed : bool;    (** any pow_retry_failed this sync *)
  obs_pow_retry_sender : string option;
    (** originating sender alias for the pow_retry_failed, if it occurred on a
        specific outbox send; [None] for connector-wide (register) failures *)
  obs_dlqs : dlq_event list;      (** discrete DLQ events this sync *)
}

let empty_observation = {
  obs_difficulty = None;
  obs_rate_limited = false;
  obs_pow_retry_failed = false;
  obs_pow_retry_sender = None;
  obs_dlqs = [];
}

let format_body sev s =
  Printf.sprintf "[c2c-relay %s] %s" (severity_to_string sev) s

(* --- per-concern deciders ------------------------------------------------ *)

(** Difficulty edge: increase → warn (broadcast), decrease → light info
    (broadcast), plateau → nothing. Only an explicitly observed value moves
    [last_difficulty]; a [None] observation is a no-op. *)
let difficulty_emissions state = function
  | None -> ([], state)
  | Some d ->
      if d > state.last_difficulty then
        let body = format_body Warn (Printf.sprintf
          "Relay PoW difficulty increased to %d (was %d). Your messages now \
           require more proof-of-work to send via the relay; sends may be \
           slower or rejected while the relay is under load."
          d state.last_difficulty)
        in
        ([ { severity = Warn; target = Broadcast;
             kind = "difficulty_increase"; body } ],
         { state with last_difficulty = d })
      else if d < state.last_difficulty then
        let body = format_body Info (Printf.sprintf
          "Relay PoW difficulty decreased to %d (was %d). Relay load has eased."
          d state.last_difficulty)
        in
        ([ { severity = Info; target = Broadcast;
             kind = "difficulty_decrease"; body } ],
         { state with last_difficulty = d })
      else
        ([], state)  (* plateau — no re-alert *)

(** Rate-limit edge: first rejection → warn (broadcast); sustained → nothing;
    clears silently when no rejection is observed. *)
let rate_limited_emissions state observed =
  if observed && not state.rate_limited then
    let body = format_body Warn
      "Relay rate-limited this connector (rate_limit_exceeded). Outbound \
       messages to remote peers may be delayed; the connector will keep \
       retrying."
    in
    ([ { severity = Warn; target = Broadcast; kind = "rate_limited"; body } ],
     { state with rate_limited = true })
  else if (not observed) && state.rate_limited then
    ([], { state with rate_limited = false })  (* recovered — clear quietly *)
  else
    ([], state)

(** pow_retry_failed edge: first failure → err; sustained → nothing; clears
    when no failure is observed. Routed to the originating sender if known,
    else broadcast. *)
let pow_retry_failed_emissions state ~observed ~sender =
  if observed && not state.pow_failing then
    let where = match sender with
      | Some s -> " for a message from " ^ s
      | None -> ""
    in
    let body = format_body Err (Printf.sprintf
      "Proof-of-work retry failed%s — the relay still required PoW after a \
       minted attempt. Affected messages remain queued and will retry; if \
       this persists the relay may be under heavy load."
      where)
    in
    let target = match sender with Some s -> Dm s | None -> Broadcast in
    ([ { severity = Err; target; kind = "pow_retry_failed"; body } ],
     { state with pow_failing = true })
  else if observed then
    ([], state)  (* sustained — no re-alert *)
  else
    ([], { state with pow_failing = false })

(** DLQ: discrete, one err DM per dead-lettered entry, to the sender. *)
let dlq_emission (d : dlq_event) =
  let body = format_body Err (Printf.sprintf
    "Your message to %s could not be delivered (reason: %s) and was moved to \
     the relay dead-letter queue. It will not be retried."
    d.dlq_to d.dlq_reason)
  in
  { severity = Err; target = Dm d.dlq_sender; kind = "dlq"; body }

(** Fold a sync pass's observations into emissions + the next dedup state.
    Pure: same [(state, observation)] always yields the same result. *)
let step state obs =
  let diff_em, state = difficulty_emissions state obs.obs_difficulty in
  let rl_em, state = rate_limited_emissions state obs.obs_rate_limited in
  let prf_em, state =
    pow_retry_failed_emissions state
      ~observed:obs.obs_pow_retry_failed ~sender:obs.obs_pow_retry_sender
  in
  let dlq_em = List.map dlq_emission obs.obs_dlqs in
  (diff_em @ rl_em @ prf_em @ dlq_em, state)
