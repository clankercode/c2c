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
   about whether a connector is live. *)

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
      (Relay_doctor.connector_running).
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

(** [{"state": <state_to_string>, "reason": <reason>}] *)
val classification_json : classification -> Yojson.Safe.t

(** ["<state_to_string> — <reason>"] — the human "state:" line body. *)
val classification_human : classification -> string

(** Map a relay /list lease object (Relay_registration_lease JSON shape:
    "alive" and "alias_reserved" booleans) to registration evidence. Missing
    or malformed fields read as [false]. *)
val registration_of_lease_json : Yojson.Safe.t -> registration_evidence

(* --- connector rendering ------------------------------------------------- *)

type connector_info = {
  conn_live : bool;  (** Relay_doctor.connector_running verdict. *)
  conn_state_present : bool;  (** connector-state.json exists. *)
  conn_last_sync_age_s : float option;
      (** now - last_sync_ts when the state file exists. *)
}

(** Derive connector info from the broker-owned connector-state file (already
    read by the caller) at time [now]. Uses
    [Relay_doctor.connector_running ~scoped_procs:[]] — the state file is the
    authoritative broker-owned signal for status surfaces (no pgrep). *)
val connector_info :
  state:C2c_relay_connector.connector_state option -> now:float -> connector_info

(** [{"live": bool, "state_file": bool, "last_sync_age_s": float|null}] *)
val connector_json : connector_info -> Yojson.Safe.t

(** e.g. ["live (last sync 12s ago)"], ["down (last sync 6m ago)"],
    ["none (no connector sync state — start with 'c2c relay connect')"]. The
    leading word agrees with [connector_json]'s ["live"] field. *)
val connector_human : connector_info -> string
