(* relay_state.ml — pure composite relay-state classifier (H5).

   See relay_state.mli for the full contract. Everything here is a pure
   function of its inputs (no I/O, no clock reads) so all five acceptance
   states — unconfigured / configured-not-registered / live / expired /
   unreachable — are hermetically testable (test_c2c_relay_state.ml).

   The connector signal is deliberately single-sourced from
   Relay_doctor.connector_running so `c2c status` / `c2c whoami` can never
   contradict `c2c doctor --relay` about whether a connector is live.

   B181: process presence is NOT bridge health. [connector_info] reports
   process evidence, health class, and remediation separately from [conn_live]. *)

type registration_evidence =
  | Reg_not_checked
  | Reg_absent
  | Reg_lease of { alive : bool; reserved : bool }
  | Reg_query_failed of string

type state =
  | Unconfigured
  | Configured_not_registered
  | Configured_unverified
  | Registered_live
  | Registered_expired
  | Registered_unreachable

type classification = { state : state; reason : string }

let state_to_string = function
  | Unconfigured -> "unconfigured"
  | Configured_not_registered -> "configured_not_registered"
  | Configured_unverified -> "configured_unverified"
  | Registered_live -> "registered_live"
  | Registered_expired -> "registered_expired"
  | Registered_unreachable -> "registered_unreachable"

(* Classification precedence:
   1. no relay URL → Unconfigured (nothing else matters);
   2. an actual relay answer (lease / absent) beats local inference;
   3. with no relay answer, the broker-owned connector signal stands in:
      a fresh connector sync is live registration evidence, a stale
      connector-state file is past-registration evidence with the bridge
      down (unreachable), and neither means we simply don't know. *)
let classify ~relay_configured ~has_identity ~has_alias ~registration
    ~connector_live ~local_reg_evidence =
  if not relay_configured then
    { state = Unconfigured; reason = "no relay URL configured" }
  else
    match registration with
    | Reg_lease { alive = true; _ } ->
        if connector_live then
          { state = Registered_live;
            reason = "relay lease alive; connector bridge live" }
        else
          { state = Registered_unreachable;
            reason =
              "relay lease alive but no live connector bridge — inbound \
               relay traffic will not reach this broker (process presence \
               alone is not bridge health; restart connect if last_sync is \
               stale)" }
    | Reg_lease { alive = false; reserved } ->
        { state = Registered_expired;
          reason =
            (if reserved then
               "relay lease expired (alias still reserved — re-register to \
                revive it)"
             else "relay lease expired and alias released") }
    | Reg_absent ->
        { state = Configured_not_registered;
          reason = "relay reachable; this alias holds no lease there" }
    | Reg_query_failed detail ->
        if connector_live || local_reg_evidence then
          { state = Registered_unreachable;
            reason = "relay query failed: " ^ detail }
        else
          { state = Configured_unverified;
            reason =
              "relay query failed (" ^ detail
              ^ ") and no local registration evidence" }
    | Reg_not_checked ->
        if not has_identity then
          { state = Configured_not_registered;
            reason = "no local identity — run 'c2c init'" }
        else if not has_alias then
          { state = Configured_not_registered;
            reason = "no current session alias to register" }
        else if connector_live then
          { state = Registered_live;
            reason = "connector bridge live (fresh broker-owned sync state)" }
        else if local_reg_evidence then
          { state = Registered_unreachable;
            reason =
              "prior connector sync state exists but the connector is down \
               (stale last_sync — restart connect; do not assume a live PID \
               is a live bridge)" }
        else
          { state = Configured_unverified;
            reason = "registration not checked — pass --relay to query" }

let classification_json (c : classification) : Yojson.Safe.t =
  `Assoc
    [ ("state", `String (state_to_string c.state))
    ; ("reason", `String c.reason)
    ]

let classification_human (c : classification) =
  Printf.sprintf "%s — %s" (state_to_string c.state) c.reason

let registration_of_lease_json (lease : Yojson.Safe.t) : registration_evidence =
  let bool_member k =
    match lease with
    | `Assoc fields ->
        (match List.assoc_opt k fields with Some (`Bool b) -> b | _ -> false)
    | _ -> false
  in
  Reg_lease { alive = bool_member "alive"; reserved = bool_member "alias_reserved" }

(* --- connector rendering --------------------------------------------------- *)

type connector_health =
  | Health_ok
  | Health_stale
  | Health_wedged
  | Health_erroring
  | Health_starting
  | Health_absent

let health_to_string = function
  | Health_ok -> "ok"
  | Health_stale -> "stale"
  | Health_wedged -> "wedged"
  | Health_erroring -> "erroring"
  | Health_starting -> "starting"
  | Health_absent -> "absent"

type connector_info = {
  conn_live : bool;
  conn_state_present : bool;
  conn_last_sync_age_s : float option;
  conn_last_ok_age_s : float option;
  conn_process_present : bool;
  conn_health : connector_health;
  conn_remediation : string option;
}

let default_remediation_start =
  "c2c start relay-connect 2>/dev/null || c2c relay connect &"

let default_remediation_restart =
  "c2c restart relay-connect 2>/dev/null || \
   (pkill -f 'c2c relay connect' 2>/dev/null; c2c relay connect &)"

let derive_health ~live ~process_present ~state ~now : connector_health =
  match state with
  | None ->
      if process_present then Health_starting else Health_absent
  | Some st ->
      if live then Health_ok
      else if Relay_doctor.connector_state_is_fresh ~now st
              && not (Relay_doctor.connector_state_ok_is_fresh ~now st) then
        Health_erroring
      else if process_present then Health_wedged
      else Health_stale

let remediation_for = function
  | Health_ok -> None
  | Health_absent -> Some default_remediation_start
  | Health_starting -> Some default_remediation_restart
  | Health_stale -> Some default_remediation_start
  | Health_wedged -> Some default_remediation_restart
  | Health_erroring ->
      Some
        (default_remediation_restart
         ^ "  # also: check token (c2c relay setup), identity (c2c init), \
            relay reachability")

let connector_info ?(process_present = false)
    ~(state : C2c_relay_connector.connector_state option) ~now () =
  let live =
    Relay_doctor.connector_running ~scoped_procs:[] ~state ~now
  in
  let health = derive_health ~live ~process_present ~state ~now in
  {
    conn_live = live;
    conn_state_present = state <> None;
    conn_last_sync_age_s =
      (match state with
       | Some st ->
           Some (max 0.0 (now -. st.C2c_relay_connector.cs_last_sync_ts))
       | None -> None);
    conn_last_ok_age_s =
      (match state with
       | Some st ->
           Some (max 0.0 (now -. st.C2c_relay_connector.cs_last_ok_ts))
       | None -> None);
    conn_process_present = process_present;
    conn_health = health;
    conn_remediation = remediation_for health;
  }

let connector_json (c : connector_info) : Yojson.Safe.t =
  `Assoc
    [ ("live", `Bool c.conn_live)
    ; ("state_file", `Bool c.conn_state_present)
    ; ( "last_sync_age_s",
        match c.conn_last_sync_age_s with
        | Some a -> `Float a
        | None -> `Null )
    ; ( "last_ok_age_s",
        match c.conn_last_ok_age_s with
        | Some a -> `Float a
        | None -> `Null )
    ; ("process_present", `Bool c.conn_process_present)
    ; ("health", `String (health_to_string c.conn_health))
    ; ( "remediation",
        match c.conn_remediation with
        | Some s -> `String s
        | None -> `Null )
    ]

let fmt_age_s a =
  if a < 60.0 then Printf.sprintf "%.0fs" a
  else if a < 3600.0 then Printf.sprintf "%.0fm" (a /. 60.0)
  else if a < 86400.0 then Printf.sprintf "%.0fh" (a /. 3600.0)
  else Printf.sprintf "%.1fd" (a /. 86400.0)

let connector_human (c : connector_info) =
  let age_bit =
    match c.conn_last_sync_age_s with
    | Some a -> Printf.sprintf "last sync %s ago" (fmt_age_s a)
    | None -> "no last_sync"
  in
  let ok_bit =
    match c.conn_last_ok_age_s with
    | Some a when c.conn_state_present ->
        Printf.sprintf ", last ok %s ago" (fmt_age_s a)
    | _ -> ""
  in
  let proc_bit =
    if c.conn_process_present then "; process present" else ""
  in
  let rem_bit =
    match c.conn_remediation with
    | Some r -> Printf.sprintf " — %s" r
    | None -> ""
  in
  match c.conn_health with
  | Health_ok ->
      Printf.sprintf "live (%s%s%s)" age_bit ok_bit
        (if c.conn_process_present then "; process present" else "")
  | Health_absent ->
      Printf.sprintf
        "none (no connector sync state — start with 'c2c relay connect')%s"
        rem_bit
  | Health_starting ->
      Printf.sprintf
        "starting (process present, no state file yet; process≠bridge health)%s"
        rem_bit
  | Health_wedged ->
      Printf.sprintf
        "wedged (%s%s; process present but bridge not live — process≠bridge \
         health)%s"
        age_bit ok_bit rem_bit
  | Health_stale ->
      Printf.sprintf "down (%s%s; no attributable process)%s" age_bit ok_bit
        rem_bit
  | Health_erroring ->
      Printf.sprintf "erroring (%s%s%s)%s" age_bit ok_bit proc_bit rem_bit
