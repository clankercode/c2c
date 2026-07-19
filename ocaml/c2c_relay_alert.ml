(** B010: pure decision logic for surfacing relay-originated "degrading
    events" to local agents.

    The relay can raise PoW difficulty under load, rate-limit a connector,
    fail to satisfy a PoW challenge, or permanently dead-letter an outbound
    message. This module turns observed relay conditions into severity-tagged
    {b emissions}. Sender-actionable failures are enqueued as messages from
    the reserved [c2c-system] alias; connector-wide difficulty changes are
    written only to the connector log so routine load changes cannot wake an
    otherwise-idle agent.

    {b Design constraints (locked, B010):}
    - Surface only {e degrading} events: difficulty INCREASE (warn),
      [pow_retry_failed] (err), DLQ/undeliverable (err), rate-limit
      rejection (warn). Difficulty {e decrease}/recovery is a light [info]
      edge. Routine connect/heartbeat/lease noise is never surfaced.
      #62 adds [inbound_contract] (err): relay-served inbound rows this host
      could not deliver. Local-policy drops are NOT surfaced — those are our
      own configured filtering working as intended.
    - {b Edge-triggered dedup}: emit ONLY on a state transition. A sustained
      high-difficulty plateau, or a connector that stays rate-limited across
      many syncs, must NOT re-alert every sync. Last-state lives in {!state}
      and is threaded by the connector across sync passes.
    - {b Routing}: sender-specific events (a dead-lettered outbox entry or
      outbound-send rate limit) DM the originating sender alias. Connector-wide
      rate limits and difficulty changes are connector-log-only.

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
  | Connector_log    (** connector log only; never a local inbox *)

let target_to_string = function
  | Broadcast -> "broadcast"
  | Dm alias -> "dm:" ^ alias
  | Connector_log -> "connector-log"

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
  rate_limited : bool;    (** currently inside a connector-wide plateau *)
  rate_limited_senders : string list;
    (** sender aliases currently inside sender-attributable plateaus *)
  pow_failing : bool;     (** currently inside a pow_retry_failed plateau *)
  inbound_contract_aliases : string list;
    (** #62: recipient aliases currently inside a relay-contract-drop plateau *)
}

let initial_state = {
  last_difficulty = 0;
  rate_limited = false;
  rate_limited_senders = [];
  pow_failing = false;
  inbound_contract_aliases = [];
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
  obs_rate_limited : bool;
    (** any connector-wide register/heartbeat/poll rate limit this sync *)
  obs_rate_limited_senders : string list;
    (** every originating sender alias whose outbox send was rate-limited this
        sync, in observation order *)
  obs_pow_retry_failed : bool;    (** any pow_retry_failed this sync *)
  obs_pow_retry_sender : string option;
    (** originating sender alias for the pow_retry_failed, if it occurred on a
        specific outbox send; [None] for connector-wide (register) failures *)
  obs_dlqs : dlq_event list;      (** discrete DLQ events this sync *)
  obs_inbound_contract_aliases : string list;
    (** #62: every recipient alias for which the relay served at least one
        inbound row that failed the broker-inbox contract, or that was
        addressed to a different recipient, in observation order *)
}

let empty_observation = {
  obs_difficulty = None;
  obs_rate_limited = false;
  obs_rate_limited_senders = [];
  obs_pow_retry_failed = false;
  obs_pow_retry_sender = None;
  obs_dlqs = [];
  obs_inbound_contract_aliases = [];
}

let format_body sev s =
  Printf.sprintf "[c2c-relay %s] %s" (severity_to_string sev) s

(* --- per-concern deciders ------------------------------------------------ *)

(** Difficulty edge: increase → warn (connector log), decrease → light info
    (connector log), plateau → nothing. Only an explicitly observed value moves
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
        ([ { severity = Warn; target = Connector_log;
             kind = "difficulty_increase"; body } ],
         { state with last_difficulty = d })
      else if d < state.last_difficulty then
        let body = format_body Info (Printf.sprintf
          "Relay PoW difficulty decreased to %d (was %d). Relay load has eased."
          d state.last_difficulty)
        in
        ([ { severity = Info; target = Connector_log;
             kind = "difficulty_decrease"; body } ],
         { state with last_difficulty = d })
      else
        ([], state)  (* plateau — no re-alert *)

(** Alias comparison follows the registry's case-insensitive contract. *)
let alias_mem alias aliases =
  let alias = String.lowercase_ascii alias in
  List.exists
    (fun candidate -> String.lowercase_ascii candidate = alias)
    aliases

let dedupe_aliases aliases =
  List.fold_left
    (fun unique alias ->
      if alias_mem alias unique then unique else unique @ [alias])
    [] aliases

(** Rate-limit edges are independent for connector-wide operations and each
    originating sender. Sustained plateaus emit nothing; an absent connector
    or sender clears only that plateau, allowing a later rejection to emit. *)
let rate_limited_emissions state ~connector_observed ~senders =
  let body = format_body Warn
    "Relay rate-limited this connector (HTTP 429 / rate_limit_exceeded). \
     Outbound messages to remote peers may be delayed. The connector aborts \
     remaining heartbeat/poll/send ops for the pass and backs off (honoring \
     retry_after when present). Shared NAT egress can exhaust a per-IP bucket \
     across hosts — do NOT restart relay-connect while throttled (B210/B244)."
  in
  let connector_emissions =
    if connector_observed && not state.rate_limited then
      [ { severity = Warn; target = Connector_log;
          kind = "rate_limited"; body } ]
    else []
  in
  let senders = dedupe_aliases senders in
  let sender_emissions =
    List.filter_map
      (fun sender ->
        if alias_mem sender state.rate_limited_senders then None
        else Some { severity = Warn; target = Dm sender;
                    kind = "rate_limited"; body })
      senders
  in
  (connector_emissions @ sender_emissions,
   { state with rate_limited = connector_observed;
                rate_limited_senders = senders })

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
      "Proof-of-work retry failed%s — the relay still required PoW after \
       every minted attempt in the client's bounded retry budget (it \
       re-mints against each fresh challenge, then stops rather than spin). \
       Affected messages remain queued and will retry; if this persists the \
       relay may be under heavy load."
      where)
    in
    let target = match sender with Some s -> Dm s | None -> Broadcast in
    ([ { severity = Err; target; kind = "pow_retry_failed"; body } ],
     { state with pow_failing = true })
  else if observed then
    ([], state)  (* sustained — no re-alert *)
  else
    ([], { state with pow_failing = false })

(** #62: the relay served inbound rows this connector could not deliver —
    either they failed the broker-inbox contract ([Inbound_schema]) or they
    were addressed to somebody else ([Inbound_recipient_mismatch]). That is
    NOT a local-policy verdict: either the relay serialized a row that cannot
    be delivered, or it routed another alias's mail here / our identity
    desynced from the address it serves.

    This has to reach the agent, because nothing else will. [poll_inbox] is
    destructive — the relay drains the row on serve and never re-offers it —
    so each dropped row is mail that is already permanently gone, and the
    connector is otherwise HEALTHY: after #62 these drops are accounting, they
    do not touch [last_error] or [last_ok_ts], so [c2c whoami] reads `ok`
    while every inbound row is being destroyed. Keeping them out of health is
    right (a restart cannot fix a bad relay); the alert is what replaces it.

    Edge-triggered per recipient alias, exactly like the rate-limit plateaus:
    a relay serving garbage on every 30s sync alerts ONCE, and can re-alert
    only after a sync in which that alias saw no contract drops. *)
let inbound_contract_emissions state ~aliases =
  let aliases = dedupe_aliases aliases in
  let emissions =
    List.filter_map
      (fun alias ->
        if alias_mem alias state.inbound_contract_aliases then None
        else
          let body = format_body Err (Printf.sprintf
            "Relay served inbound rows for %s that could not be delivered, \
             and they were DROPPED: they failed the broker-inbox contract \
             (malformed row) or were addressed to a different recipient. \
             Polling the relay is destructive, so those messages are gone \
             from the relay and will NOT be retried. This is a relay-side or \
             identity fault, not a local one — restarting the connector \
             cannot clear it. Check that your alias matches what the relay \
             routes to this host (c2c whoami, c2c init); see \
             inbound_rejected_note in connector-state.json and the \
             relay_inbound_contract_drops events in broker.log for the \
             per-reason breakdown."
            alias)
          in
          Some { severity = Err; target = Dm alias;
                 kind = "inbound_contract"; body })
      aliases
  in
  (emissions, { state with inbound_contract_aliases = aliases })

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
  let rl_em, state =
    rate_limited_emissions state ~connector_observed:obs.obs_rate_limited
      ~senders:obs.obs_rate_limited_senders
  in
  let prf_em, state =
    pow_retry_failed_emissions state
      ~observed:obs.obs_pow_retry_failed ~sender:obs.obs_pow_retry_sender
  in
  let ic_em, state =
    inbound_contract_emissions state ~aliases:obs.obs_inbound_contract_aliases
  in
  let dlq_em = List.map dlq_emission obs.obs_dlqs in
  (diff_em @ rl_em @ prf_em @ ic_em @ dlq_em, state)
