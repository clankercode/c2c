(* relay_state.ml — pure composite relay-state classifier (H5).

   See relay_state.mli for the full contract. Everything here is a pure
   function of its inputs (no I/O, no clock reads) so all five acceptance
   states — unconfigured / configured-not-registered / live / expired /
   unreachable — are hermetically testable (test_c2c_relay_state.ml).

   The connector signal is deliberately single-sourced from
   Relay_doctor.connector_running so `c2c status` / `c2c whoami` can never
   contradict `c2c doctor --relay` about whether a connector is live.

   B181: process presence is NOT bridge health. [connector_info] reports
   process evidence, health class, and remediation separately from [conn_live].

   #11: the `state:` and `connector:` lines answer different questions and
   printed unlabelled read as one contradiction. [state_line] names the relay
   config FILE it was derived from (machine-wide by default — see
   [relay_config_location]) and [connector_line] labels the connector's
   machine-service scope, so the pair stops reading as a contradiction. An
   erroring connector additionally reports the error it recorded, alongside
   (not instead of) the what-to-check checklist. *)

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

(* #11(2): the `state:` and `connector:` lines answer different questions, and
   an operator reading "erroring" beside "unconfigured — no relay URL
   configured" has no way to tell that. The connector line is the machine-wide
   connector service reporting its last sync of THIS repo's broker root
   (connector-state.json is per-root, so that failure is in scope here even
   for a repo that configured no relay of its own — the service syncs every
   discovered root with its shared url/token).

   The `state:` line, however, must NOT be labelled "this repo's relay
   config". [relay_configured] is `resolve_relay_url None <> None`, which is
   C2C_RELAY_URL → the relay config FILE, and
   [C2c_relay_cmd.relay_config_path] resolves that file as C2C_RELAY_CONFIG →
   <C2C_MCP_BROKER_ROOT>/relay.json → else
   $HOME/.config/c2c/relay.json. Nothing in broker-root resolution sets
   C2C_MCP_BROKER_ROOT (it is fingerprint-derived), so in the ordinary case —
   any plain shell — the predicate reads a MACHINE-WIDE file and a repo-scope
   claim is simply false; `c2c relay setup` then writes that same machine-wide
   file, contradicting the label. A claim whose truth value flips on an env
   var is not a contract.

   So name the file instead of guessing the scope. That is strictly true in
   every branch, and it is more actionable: it tells the operator exactly
   which file to look at (or which one `c2c relay setup` will write). *)
type relay_config_location =
  | Relay_config_machine of string
  | Relay_config_repo of string
  | Relay_config_explicit of string

let scope_relay_config_machine = "relay_config_machine"
let scope_relay_config_repo = "relay_config_repo"
let scope_relay_config_explicit = "relay_config_explicit"
let scope_connector_machine_service = "machine_connector_service"

let relay_config_scope_token = function
  | Relay_config_machine _ -> scope_relay_config_machine
  | Relay_config_repo _ -> scope_relay_config_repo
  | Relay_config_explicit _ -> scope_relay_config_explicit

let relay_config_path_of = function
  | Relay_config_machine p | Relay_config_repo p | Relay_config_explicit p -> p

(* The human tail for the `state:` line: the relay config FILE this context
   would read, and how far that file's reach goes.

   Deliberately NOT "where the URL this line reports on came from". [
   relay_configured] is `resolve_relay_url None <> None` = C2C_RELAY_URL →
   config file, so with C2C_RELAY_URL exported the URL came from the
   environment and this path contributed nothing (it need not even exist).
   The rendered string survives that case because it only ever names a real
   path and describes THAT path's reach — it never claims to be the
   provenance of the URL. Operators with C2C_RELAY_URL set should read this
   as "the file that would apply otherwise, and the one `c2c relay setup`
   writes"; the env var overrides it. We do not add a fourth env-URL
   constructor: the payload here is a file path, C2C_RELAY_URL is a URL, and
   the config file still supplies the TOKEN even when the URL is overridden,
   so suppressing the path would lose a still-load-bearing pointer. *)
let relay_config_note (loc : relay_config_location) =
  match loc with
  | Relay_config_machine p ->
      Printf.sprintf "[relay config: %s (machine-wide)]" p
  | Relay_config_repo p ->
      (* NOT "this repo's broker root": C2C_MCP_BROKER_ROOT is a free-form
         override and nothing binds it to this repo. Pointed at a legacy
         .git/c2c/mcp path it is ignored by
         [C2c_repo_fp.resolve_broker_root] (canonical fallback wins) while
         this classifier still honours it — so the named file can belong to a
         root the process is not using. Naming the env var is unconditionally
         true and just as actionable. *)
      Printf.sprintf "[relay config: %s (from C2C_MCP_BROKER_ROOT)]" p
  | Relay_config_explicit p ->
      Printf.sprintf "[relay config: %s (C2C_RELAY_CONFIG)]" p

let classification_json ~(config : relay_config_location)
    (c : classification) : Yojson.Safe.t =
  `Assoc
    [ ("state", `String (state_to_string c.state))
    ; ("reason", `String c.reason)
    ; ("scope", `String (relay_config_scope_token config))
    ; ("config_path", `String (relay_config_path_of config))
    ]

let classification_human (c : classification) =
  Printf.sprintf "%s — %s" (state_to_string c.state) c.reason

(* The rendered `state:` line: classification plus the relay config file this
   context would read (see [relay_config_note] — C2C_RELAY_URL, when set,
   overrides that file for the URL). *)
let state_line ~(config : relay_config_location) (c : classification) =
  Printf.sprintf "%s  %s" (classification_human c) (relay_config_note config)

(* B234: parenthetical after the human alias value. Must not claim the
   alias is "not a relay registration" when composite state indicates
   registration evidence exists (lease live/expired, or unreachable with
   prior/local evidence). Only Configured_not_registered is a positive
   absence signal; unverified/unconfigured stay neutral so operators are
   not misled into re-registering. *)
let alias_line_note (c : classification) : string =
  match c.state with
  | Configured_not_registered ->
      "  (local session alias — not a relay registration)"
  | Registered_live | Registered_expired | Registered_unreachable
  | Configured_unverified | Unconfigured ->
      "  (local session alias)"

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
  (* #11(2): the failing op and its detail as recorded by the connector's
     last sync of this broker root. Reported instead of guessing at the
     cause; None on older state files and on paths that record no detail. *)
  conn_last_error_op : string option;
  conn_last_error_detail : string option;
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

(* #11(2): Health_erroring means the connector synced THIS broker root inside
   the freshness window and that sync failed — a live, in-scope failure whose
   cause is already in the state file. [connector_human] reports that cause
   instead of leaving the operator to guess.

   The what-to-check checklist stays UNCONDITIONAL rather than being traded
   for the recorded error, because Health_erroring does NOT imply a recorded
   error. [C2c_relay_connector.touch_connector_last_sync] (called at the top
   of every [run_sync_once]) refreshes last_sync_ts while PRESERVING last_ok_ts
   and the last_error_* fields — that is its B228 purpose, so a hung HTTP path
   shows as erroring rather than as a frozen state file. So: pass N succeeds
   (last_error := Null, last_ok := T), pass N+1 touches last_sync and then
   hangs; once T ages past the 120s [Relay_doctor] window we have a fresh
   last_sync, a stale last_ok, and last_error = None — Health_erroring with
   NOTHING recorded. The sync watchdog only fires at [sync_watchdog_s] =
   max 90.0 (interval *. 4.0) after pass start, so that window is tens of
   seconds to minutes wide on a routine production hang, not a legacy file.

   That makes the unconditional checklist MORE necessary, not less: a hung
   sync is exactly the case with no error text to show, so a checklist
   conditioned on "an error is known" would leave the operator with no
   guidance at all in the one state that most needs it.
   [test_connector_erroring_without_detail_keeps_guidance] pins this reachable
   None case. The recorded errors are also weak substitutes when they do
   exist — `("sync", Printexc.to_string exn)` is opaque, and
   `("poll_inbox", "dropped N policy-rejected inbound row(s)…")` is inbound
   accounting rather than a connectivity fault yet still drives `erroring`.
   The checklist is a `#` shell comment on a runnable command: it costs
   nothing and never breaks copy-paste, so render it alongside the error.

   Health_wedged is deliberately untouched: it is a property of the connector
   *process*, independent of any repo's relay config, and "restart" is right
   for it whatever the last error said. *)
let remediation_for health =
  match health with
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
  let last_error_op =
    match state with
    | Some st -> st.C2c_relay_connector.cs_last_error_op
    | None -> None
  in
  let last_error =
    match state with
    | Some st -> st.C2c_relay_connector.cs_last_error_detail
    | None -> None
  in
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
    conn_last_error_op = last_error_op;
    conn_last_error_detail = last_error;
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
    ; ("scope", `String scope_connector_machine_service)
    ; ( "last_error_op",
        match c.conn_last_error_op with Some s -> `String s | None -> `Null )
    ; ( "last_error_detail",
        match c.conn_last_error_detail with
        | Some s -> `String s
        | None -> `Null )
    ]

(* Ceiling on the recorded error detail in the HUMAN line only (#11). The
   connector's own renderers clip this field at 80; a slightly higher bound
   keeps more of a useful message while still capping the line. *)
let err_detail_max_chars = 120

(* [String.sub s 0 n] is a BYTE slice, and err_detail sources include
   [Yojson.Safe.to_string] of relay response bodies and [Printexc.to_string],
   either of which can carry non-ASCII UTF-8. Cutting mid-sequence emits a
   lone continuation byte and renders as mojibake, so back the cut off to the
   last index that is not a continuation byte (0b10xxxxxx). Pure and
   total: for ASCII it is the identity, and it can only shorten. *)
let utf8_safe_cut s n =
  let n = min n (String.length s) in
  let rec back i =
    if i <= 0 then 0
    else if Char.code s.[i] land 0xC0 <> 0x80 then i
    else back (i - 1)
  in
  if n >= String.length s then String.length s else back n

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
  (* #11(2): report the failure the connector actually recorded. Same idiom as
     Relay_doctor's connector check; the op prefix says which leg failed.

     Bounded, and rendered INSIDE the parenthesised evidence group (with the
     "; " separator the other bits use) so it cannot displace the
     copy-pasteable remediation command that follows. err_detail sources
     include Yojson.Safe.to_string of a whole relay response, i.e. unbounded
     in principle; the connector's own log renderers truncate this same field,
     so truncate here too. --json keeps the full detail. *)
  let err_bit =
    let clip s =
      if String.length s > err_detail_max_chars then
        String.sub s 0 (utf8_safe_cut s err_detail_max_chars) ^ "..."
      else s
    in
    match (c.conn_last_error_op, c.conn_last_error_detail) with
    | _, None -> ""
    | None, Some detail -> Printf.sprintf "; last error: %s" (clip detail)
    | Some op, Some detail ->
        Printf.sprintf "; last error: %s: %s" op (clip detail)
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
      Printf.sprintf "erroring (%s%s%s%s)%s" age_bit ok_bit proc_bit err_bit
        rem_bit

(* The rendered `connector:` line: health plus its scope marker. *)
let connector_line (c : connector_info) =
  Printf.sprintf "%s  [scope: machine connector service, this repo's broker \
                  root]"
    (connector_human c)
