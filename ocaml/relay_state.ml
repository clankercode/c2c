(* relay_state.ml — pure composite relay-state classifier (H5).

   See relay_state.mli for the full contract. Everything here is a pure
   function of its inputs (no I/O, no clock reads) so all five acceptance
   states — unconfigured / configured-not-registered / live / expired /
   unreachable — are hermetically testable (test_c2c_relay_state.ml).

   The connector signal is deliberately single-sourced from
   Relay_doctor.connector_running so `c2c status` / `c2c whoami` can never
   contradict `c2c doctor --relay` about whether a connector is live. *)

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
               relay traffic will not reach this broker" }
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
              "prior connector sync state exists but the connector is down" }
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

type connector_info = {
  conn_live : bool;
  conn_state_present : bool;
  conn_last_sync_age_s : float option;
}

let connector_info ~(state : C2c_relay_connector.connector_state option) ~now =
  {
    conn_live = Relay_doctor.connector_running ~scoped_procs:[] ~state ~now;
    conn_state_present = state <> None;
    conn_last_sync_age_s =
      (match state with
       | Some st -> Some (max 0.0 (now -. st.C2c_relay_connector.cs_last_sync_ts))
       | None -> None);
  }

let connector_json (c : connector_info) : Yojson.Safe.t =
  `Assoc
    [ ("live", `Bool c.conn_live)
    ; ("state_file", `Bool c.conn_state_present)
    ; ( "last_sync_age_s",
        match c.conn_last_sync_age_s with
        | Some a -> `Float a
        | None -> `Null )
    ]

let fmt_age_s a =
  if a < 60.0 then Printf.sprintf "%.0fs" a
  else if a < 3600.0 then Printf.sprintf "%.0fm" (a /. 60.0)
  else if a < 86400.0 then Printf.sprintf "%.0fh" (a /. 3600.0)
  else Printf.sprintf "%.1fd" (a /. 86400.0)

let connector_human (c : connector_info) =
  match c.conn_live, c.conn_last_sync_age_s with
  | true, Some a -> Printf.sprintf "live (last sync %s ago)" (fmt_age_s a)
  | true, None -> "live"
  | false, Some a -> Printf.sprintf "down (last sync %s ago)" (fmt_age_s a)
  | false, None ->
      "none (no connector sync state — start with 'c2c relay connect')"
