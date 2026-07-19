(* relay_state.mli — pure composite relay-state classifier (H5).

   Separates the three facts that `c2c status` / `c2c whoami` used to
   conflate under one "registered:" label (inventory A020/A027; backlog B094
   gap):

   1. the LOCAL broker alias (session identity on this machine's broker),
   2. RELAY REGISTRATION (does the relay hold a lease for this alias, and is
      that lease current or expired), and
   3. CONNECTOR state (is a broker-owned connector bridge live so relay
      traffic actually flows).

   [classify] folds those inputs into one composite state; everything here is
   a pure function of its arguments (no I/O, no clock) so the classification
   truth is hermetically testable — see test_c2c_relay_state.ml. The
   connector signal is Relay_doctor.connector_running — the same broker-owned
   signal `c2c doctor --relay` uses — so the two surfaces can never disagree
   about whether a connector is live.

   B181: process presence ≠ bridge health. [connector_info] reports process
   evidence, health class, and remediation separately from [conn_live].

   #11: (2) and (3) answer different questions — is a relay URL visible to me
   (and from which config file), vs did the machine-wide connector service's
   last sync of this repo's broker root succeed — and printed unlabelled they
   read as one contradictory statement. See [state_line] / [connector_line],
   [relay_config_location], and the [scope_*] tokens. *)

(** Evidence about this alias's registration on the configured relay. *)
type registration_evidence =
  | Reg_not_checked
      (** No live relay query was performed (the offline-default path:
          status/whoami without [--relay]). *)
  | Reg_absent
      (** The relay answered and our alias is not in its lease table. *)
  | Reg_lease of { alive : bool; reserved : bool }
      (** The relay holds a lease for our alias. [alive] = last_seen + ttl
          has not elapsed; [reserved] = the alias is still reserved for us
          even though the lease is not alive (grace window). *)
  | Reg_query_failed of string
      (** A relay query was attempted but failed (network error or relay
          error response); the payload is the error detail. *)

(** Composite relay state. The five acceptance states of H5 plus
    [Configured_unverified], the honest "don't know" for the offline default
    where registration was never checked and no local evidence exists. *)
type state =
  | Unconfigured  (** No relay URL configured. *)
  | Configured_not_registered
      (** Relay configured, and we positively know this alias is not
          registered: the relay said so, or there is no local identity/alias
          to be registered under. *)
  | Configured_unverified
      (** Relay configured but registration is unknown: not checked (and no
          broker-owned connector evidence either way), or the check failed
          with no local evidence a registration ever existed. *)
  | Registered_live
      (** Registration is current AND the connector bridge is live — relay
          traffic can actually flow. *)
  | Registered_expired
      (** The relay holds a lease for us but it has expired (not alive). *)
  | Registered_unreachable
      (** Registration evidence exists but the relay/connector leg is down:
          the relay is unreachable, or the lease is alive while no
          broker-owned connector is live (peers can't actually reach us). *)

type classification = {
  state : state;
  reason : string;  (** Human-oriented one-line justification. *)
}

(** Pure classifier. Inputs:
    - [relay_configured]: a relay URL is configured (env/setup).
    - [has_identity]: a local Ed25519 identity loads (registration is
      impossible without one).
    - [has_alias]: a current session alias resolved.
    - [registration]: relay-side evidence, see {!registration_evidence}.
    - [connector_live]: broker-owned connector signal
      (Relay_doctor.connector_running) — fresh successful sync, NOT process
      presence (B181).
    - [local_reg_evidence]: a broker-owned connector-state file exists
      (proof some past sync/registration happened here). *)
val classify :
  relay_configured:bool ->
  has_identity:bool ->
  has_alias:bool ->
  registration:registration_evidence ->
  connector_live:bool ->
  local_reg_evidence:bool ->
  classification

(** Stable machine string for each state — the value rendered under
    ["registration"]["state"] in --json and embedded verbatim in the human
    "state:" line (guaranteeing human/JSON parity). *)
val state_to_string : state -> string

(** Which relay config file the [state:] line's context would read (#11).

    NOT a provenance claim about the URL: [relay_configured] is
    [resolve_relay_url None <> None] = [C2C_RELAY_URL] → the relay config
    file, so when [C2C_RELAY_URL] is exported the URL came from the
    environment and the named file contributed nothing (and may not exist).
    The rendered marker stays true regardless because it only names a real
    path and describes that path's reach; it is the file that applies
    otherwise, and the one [c2c relay setup] writes. Deliberately no fourth
    env-URL constructor: the payload is a file path, [C2C_RELAY_URL] is a URL,
    and that file still supplies the TOKEN when the URL is overridden.

    The file is resolved by [C2c_relay_cmd.relay_config_path]:
    [C2C_RELAY_CONFIG] → [<C2C_MCP_BROKER_ROOT>/relay.json] → else
    [$HOME/.config/c2c/relay.json]. Nothing in broker-root resolution sets
    [C2C_MCP_BROKER_ROOT], so the DEFAULT case (any plain shell) reads a
    machine-wide file — labelling the line "this repo's relay config" would be
    false exactly when no env var is set, and `c2c relay setup` would then
    write the machine-wide file the label denied. So the line names the file
    rather than guessing a scope; that is true in every branch and tells the
    operator where to look. The payload is the display path. *)
type relay_config_location =
  | Relay_config_machine of string  (** [$HOME/.config/c2c/relay.json]. *)
  | Relay_config_repo of string
      (** [<C2C_MCP_BROKER_ROOT>/relay.json]. Named by the env var, not
          claimed as "this repo's" root: [C2C_MCP_BROKER_ROOT] is a free-form
          override, and [C2c_repo_fp.resolve_broker_root] ignores values it
          rejects (e.g. legacy [.git/c2c/mcp] paths) while this classifier
          still honours them. *)
  | Relay_config_explicit of string
      (** [C2C_RELAY_CONFIG] points somewhere explicit; scope unknowable. *)

(** Stable --json scope tokens (#11). The [state:] line's token says which
    relay config file backs it; the [connector:] line's says the reading comes
    from the machine-wide connector service's last sync of this repo's broker
    root. They are different questions and were read as one contradictory
    answer ("erroring" beside "unconfigured"). *)
val scope_relay_config_machine : string

val scope_relay_config_repo : string
val scope_relay_config_explicit : string
val scope_connector_machine_service : string

(** The [scope] token for a location: one of [scope_relay_config_machine] /
    [scope_relay_config_repo] / [scope_relay_config_explicit]. *)
val relay_config_scope_token : relay_config_location -> string

(** The display path carried by a location. *)
val relay_config_path_of : relay_config_location -> string

(** [{"state": <state_to_string>, "reason": <reason>,
     "scope": <relay_config_scope_token config>,
     "config_path": <relay_config_path_of config>}]. [config] is required so
    no caller can silently drop the provenance the token asserts. *)
val classification_json :
  config:relay_config_location -> classification -> Yojson.Safe.t

(** ["<state_to_string> — <reason>"] — the human "state:" line body. *)
val classification_human : classification -> string

(** The full human "state:" line: [classification_human] plus a
    [\[relay config: <path> (<reach>)\]] marker naming the file behind it,
    matching [relay_config_scope_token config]. *)
val state_line : config:relay_config_location -> classification -> string

(** Parenthetical after the human [alias:] value in status/whoami (B234).

    Only [Configured_not_registered] appends "— not a relay registration"
    (positive absence: relay said no lease, or no identity/alias to
    register). States with registration evidence
    ([Registered_live]/[Registered_expired]/[Registered_unreachable])
    and honest-unknown ([Configured_unverified]/[Unconfigured]) use the
    neutral "local session alias" note so operators are not told they are
    unregistered when they are (or when we simply have not checked). *)
val alias_line_note : classification -> string

(** Map a relay /list lease object (Relay_registration_lease JSON shape:
    "alive" and "alias_reserved" booleans) to registration evidence. Missing
    or malformed fields read as [false]. *)
val registration_of_lease_json : Yojson.Safe.t -> registration_evidence

(* --- connector rendering ------------------------------------------------- *)

(** Bridge health class (B181). Distinct from process presence. *)
type connector_health =
  | Health_ok  (** Fresh last_ok — live bridge. *)
  | Health_stale  (** State file present, last_sync stale, no process. *)
  | Health_wedged  (** Process present but last_sync/last_ok stale. *)
  | Health_erroring  (** last_sync fresh but last_ok stale / failing. *)
  | Health_starting  (** Process present, no state file yet. *)
  | Health_absent  (** No process, no state file. *)

val health_to_string : connector_health -> string

type connector_info = {
  conn_live : bool;
      (** Relay_doctor.connector_running — fresh successful sync. *)
  conn_state_present : bool;  (** connector-state.json exists. *)
  conn_last_sync_age_s : float option;
      (** now - last_sync_ts when the state file exists. *)
  conn_last_ok_age_s : float option;
      (** now - last_ok_ts when the state file exists. *)
  conn_process_present : bool;
      (** Broker-attributed connector process observed (optional input). *)
  conn_health : connector_health;
  conn_remediation : string option;
      (** Copy-pasteable recovery command when not live. Always a runnable
          command; [Health_erroring] always also carries the commented
          what-to-check tail (#11 — it is a [#] shell comment, so it never
          breaks copy-paste, and the recorded error is reported alongside it
          rather than in place of it). The tail is unconditional because
          [Health_erroring] with [conn_last_error_detail = None] is REACHABLE
          and expected: [C2c_relay_connector.touch_connector_last_sync]
          refreshes last_sync at pass start while preserving last_ok and the
          last_error fields (B228), so a pass that hangs after a successful
          predecessor yields fresh last_sync + stale last_ok + no recorded
          error. A checklist conditioned on "an error is known" would give a
          hung connector no guidance at all. *)
  conn_last_error_op : string option;
      (** Failing op recorded by the connector's last sync of this root
          (#11), e.g. "poll"/"push". [None] on older state files. *)
  conn_last_error_detail : string option;
      (** Detail for that failure — reported to the operator instead of
          guessing at the cause. [None] when nothing was recorded. *)
  conn_inbound_rejected : int;
      (** #62: inbound rows the connector's LAST sync dropped (0 on older
          state files). Deliberately NOT an input to [conn_health]: a poll
          that rejects rows succeeded, and no local remediation clears it.
          But dropped rows are how mail silently goes missing on a connector
          reporting ok — relay polling is destructive, so a dropped row is
          already gone — so they are reported here, in [connector_json] and
          on the human line rather than only in connector-state.json, where
          nothing read them. Per-sync, not cumulative. *)
  conn_inbound_rejected_note : string option;
      (** Per-reason breakdown for [conn_inbound_rejected], labelled by class
          ("policy-rejected" = this host's own B196 filtering;
          "relay-contract-violating" = the relay served an undeliverable or
          misaddressed row). [None] when the last sync dropped nothing. *)
}

(** Derive connector info from the broker-owned connector-state file (already
    read by the caller) at time [now]. Uses
    [Relay_doctor.connector_running] — the state file's last_ok freshness is
    the authoritative bridge signal (no pgrep for liveness). Pass
    [~process_present:true] when a broker-scoped process was observed so
    health can distinguish wedged vs merely down. *)
val connector_info :
  ?process_present:bool ->
  state:C2c_relay_connector.connector_state option ->
  now:float ->
  unit ->
  connector_info

(** [{"live", "state_file", "last_sync_age_s", "last_ok_age_s",
     "process_present", "health", "remediation", "scope", "last_error_op",
     "last_error_detail"}]. [last_error_detail] carries the FULL detail — only
    the human line truncates it. *)
val connector_json : connector_info -> Yojson.Safe.t

(** Human connector line body. Leading word agrees with [conn_live] /
    [health]: live | down | wedged | erroring | starting | none. An erroring
    bridge also reports the recorded [last error] (#11), inside the
    parenthesised evidence group and truncated, so an unbounded error detail
    cannot displace the remediation command that follows it. *)
val connector_human : connector_info -> string

(** The full human "connector:" line: [connector_human] plus the scope marker
    matching [scope_connector_machine_service]. *)
val connector_line : connector_info -> string
