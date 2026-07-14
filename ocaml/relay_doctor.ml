(* relay_doctor.ml — scheme/attempt-aware relay capability logic plus
   broker-owned connector attribution, shared by `c2c doctor --relay`
   (c2c_doctor_relay.ml) and the `c2c relay subscribe` command guard
   (c2c_relay_cmd.ml).

   Everything here is pure and hermetically testable (no pgrep, no network,
   no clock unless [now] is passed in) so the doctor/capability truth can be
   asserted without a live relay. See test_c2c_doctor_capabilities.ml.

   B093 defects this closes (historical; B189 later enabled TLS subscribe):
   - capabilities used to claim `subscribe=yes` on TLS relays even though
     `c2c relay subscribe` rejected https/wss (exit 1). [subscribe_url_supported]
     is the single source of truth both surfaces consult, so the reported
     capability always matches what an actual attempt would do.
   - connector detection was machine-global `pgrep`; an unrelated connector on
     the same box falsely reported "connector running" for an isolated broker.
     [scope_connector_lines] scopes matches to this broker root and
     [connector_running] requires broker-owned *fresh successful sync*
     evidence (B181: process presence alone is never bridge health).
   - every emitted docs URL 404'd (`https://c2c.im/docs/relay`); [docs_url] now
     points at the published `/relay-quickstart/` permalink. *)

type status = Pass | Fail | Inconclusive

let status_str = function
  | Pass -> "PASS"
  | Fail -> "FAIL"
  | Inconclusive -> "INCONCLUSIVE"

type check_result = {
  check_id : string;
  status : status;
  message : string;
  detail : string option;
  fix_command : string option;
  docs_url : string option;
}

(* Canonical published relay docs permalink. The former
   `https://c2c.im/docs/relay` had no backing Jekyll page and returned 404;
   `/relay-quickstart/` is a real permalink (docs/relay-quickstart.md). *)
let docs_url = "https://c2c.im/relay-quickstart/"

(* ---------------------------------------------------------------------------
 * Capabilities (scheme/attempt-aware)
 * --------------------------------------------------------------------------- *)

(* subscribe = WebSocket push (`/ws/subscribe`). Plaintext (ws/http) and TLS
   (wss/https) client paths are both supported as of B189 via Relay_ws_client.
   Reject only obviously unusable schemes so the doctor matrix stays
   attempt-parity with `c2c relay subscribe`. *)
let subscribe_scheme_supported = function
  | Some ("http" | "https" | "ws" | "wss") | None -> true
  | Some _ -> false

let subscribe_url_supported url =
  subscribe_scheme_supported (Uri.scheme (Uri.of_string url))

let url_is_tls url =
  match Uri.scheme (Uri.of_string url) with
  | Some "https" | Some "wss" -> true
  | _ -> false

type capabilities = {
  send : bool;
  subscribe : bool;
  connect : bool;
  poll : bool;
  tls : bool;
}

let capabilities ~url ~reachable ~connector_running =
  {
    send = reachable;
    subscribe = reachable && subscribe_url_supported url;
    connect = connector_running;
    poll = reachable;
    tls = url_is_tls url;
  }

let yn b = if b then "yes" else "no"

let capabilities_message c =
  Printf.sprintf "send=%s subscribe=%s connect=%s poll=%s (%s)"
    (yn c.send) (yn c.subscribe) (yn c.connect) (yn c.poll)
    (if c.tls then "TLS" else "plaintext")

let capabilities_detail c =
  let row name ready desc =
    Printf.sprintf "  %-12s %-7s  %s" name (yn ready) desc
  in
  String.concat "\n"
    [ row "send" c.send "POST /send (DMs)"
    ; row "subscribe" c.subscribe
        "WebSocket push (/ws/subscribe; ws and wss/TLS)"
    ; row "connect" c.connect "live connector bridge"
    ; row "poll" c.poll "POST /poll_inbox (fallback fetch)"
    ]

(* PASS only when the relay is reachable AND a broker-owned connector bridge is
   live. A reachable-but-no-connector relay is Inconclusive (poll works, the
   live bridge doesn't), never a false PASS. *)
let capabilities_check ~url ~reachable ~connector_running =
  let c = capabilities ~url ~reachable ~connector_running in
  let status =
    if reachable && connector_running then Pass else Inconclusive
  in
  {
    check_id = "relay.capabilities";
    status;
    message = capabilities_message c;
    detail = Some (capabilities_detail c);
    fix_command =
      (if not connector_running then
         Some (Printf.sprintf "c2c relay connect --relay-url %s &" url)
       else None);
    docs_url = Some docs_url;
  }

(* ---------------------------------------------------------------------------
 * Connector attribution + staleness (broker-owned)
 * --------------------------------------------------------------------------- *)

(* stdlib-only substring test (avoids a Str dependency in the core lib). *)
let string_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else go (i + 1)
    in
    go 0

(* A machine-global `pgrep` line is attributable to THIS broker only when it
   references this broker root path — the unique per-broker discriminator. A
   bare `c2c relay connect` for another repo/broker (or an unrelated shell that
   merely mentions the string) is NOT this broker's connector. This is the fix
   for the B093 false positive where unrelated machine connectors promoted an
   isolated broker's capabilities to PASS. *)
let scope_connector_lines ~broker_root lines =
  if broker_root = "" || broker_root = "<unresolved>" then []
  else List.filter (fun l -> string_contains ~needle:broker_root l) lines

let connector_stale_threshold_s = 120.0

let connector_state_is_fresh ~now (st : C2c_relay_connector.connector_state) =
  now -. st.C2c_relay_connector.cs_last_sync_ts < connector_stale_threshold_s

let connector_state_ok_is_fresh ~now (st : C2c_relay_connector.connector_state) =
  now -. st.C2c_relay_connector.cs_last_ok_ts < connector_stale_threshold_s

(* Compact relative-age formatter for connector messages. *)
let age_str now ts =
  let delta = max 0.0 (now -. ts) in
  if delta < 60.0 then Printf.sprintf "%.0fs" delta
  else if delta < 3600.0 then Printf.sprintf "%.0fm" (delta /. 60.0)
  else if delta < 86400.0 then Printf.sprintf "%.0fh" (delta /. 3600.0)
  else Printf.sprintf "%.1fd" (delta /. 86400.0)

let recent_error_window_s = 300.0

let has_recent_error ~now (st : C2c_relay_connector.connector_state) =
  match st.C2c_relay_connector.cs_last_error_ts with
  | Some ts when now -. ts < recent_error_window_s -> true
  | _ -> false

(* Live bridge = a *successful* sync completed recently (last_ok fresh).
   last_sync alone is insufficient: a wedged process may never write state,
   and a looping-but-always-failing connector writes last_sync without
   delivering. Process presence is intentionally ignored here (B181): a
   multi-hour `c2c relay connect` PID with last_sync 1.4d is not a live
   bridge. [scoped_procs] is retained in the signature so call sites and
   diagnostics can still surface process evidence separately. *)
let connector_bridge_live ~state ~now =
  match state with
  | Some st ->
      connector_state_is_fresh ~now st && connector_state_ok_is_fresh ~now st
  | None -> false

let connector_running ~scoped_procs:_ ~state ~now =
  connector_bridge_live ~state ~now

let fix_restart_connect relay_url =
  Printf.sprintf
    "c2c restart relay-connect 2>/dev/null || \
     (pkill -f 'c2c relay connect' 2>/dev/null; \
      c2c relay connect --relay-url %s &)"
    relay_url

let fix_start_connect relay_url =
  Printf.sprintf
    "c2c start relay-connect --relay-url %s 2>/dev/null || \
     c2c relay connect --relay-url %s &"
    relay_url relay_url

(* Pure connector check. Every FAIL carries a copy-pasteable fix_command
   (B093 item 5). Bridge liveness is [connector_running] (fresh last_ok),
   which capabilities also consume — the two surfaces never disagree about
   whether the bridge is live. Process presence is a *separate* diagnostic:
   process alive + stale last_sync = wedged (FAIL, restart), not PASS. *)
let connector_check ~relay_url ~scoped_procs ~state ~now =
  let base id status message detail fix =
    {
      check_id = id;
      status;
      message;
      detail;
      fix_command = fix;
      docs_url = Some docs_url;
    }
  in
  let id = "relay.connector" in
  let n_procs = List.length scoped_procs in
  let live = connector_running ~scoped_procs ~state ~now in
  match live, state, n_procs with
  | false, None, 0 ->
      base id Fail
        "no relay connector attributable to this broker root and no prior sync state"
        (Some
           "Outbound remote-alias messages will queue in remote-outbox.jsonl \
            indefinitely. Process presence is not checked as bridge health — \
            start a connector for this broker.")
        (Some (fix_start_connect relay_url))
  | false, None, n when n > 0 ->
      (* Process attributed to this broker, no state file yet — first sync
         still in flight, OR a process that never successfully wrote state. *)
      base id Inconclusive
        (Printf.sprintf
           "connector process attributable to this broker (%d); no state file \
            yet (process≠bridge health)"
           n)
        (Some
           "First sync may still be in flight. If this persists beyond ~2m, \
            kill and restart the connector.")
        (Some (fix_restart_connect relay_url))
  | false, Some st, n ->
      let last_sync = st.C2c_relay_connector.cs_last_sync_ts in
      let last_ok = st.C2c_relay_connector.cs_last_ok_ts in
      let sync_age = age_str now last_sync in
      let ok_age = age_str now last_ok in
      if n > 0 then
        (* B181: process alive + stale bridge = wedged. Never PASS on PID alone. *)
        base id Fail
          (Printf.sprintf
             "connector process present but bridge stale (last sync %s ago, \
              last ok %s ago) — wedged; process≠bridge health"
             sync_age ok_age)
          (Some
             "A long-lived `c2c relay connect` PID is not proof of delivery. \
              Restart the connector so last_sync refreshes; check token/socket \
              if restart immediately re-stales.")
          (Some (fix_restart_connect relay_url))
      else if connector_state_is_fresh ~now st
              && not (connector_state_ok_is_fresh ~now st) then
        (* Cycling but not succeeding. *)
        let err =
          match st.C2c_relay_connector.cs_last_error_detail with
          | Some e -> Printf.sprintf " last error: %s" e
          | None -> ""
        in
        base id Fail
          (Printf.sprintf
             "connector syncing but not healthy (last sync %s ago, last ok %s \
              ago)%s"
             sync_age ok_age err)
          (Some
             "Bridge process may be alive (last_sync fresh) but successful \
              sync is stale — check token, identity, and relay reachability.")
          (Some (fix_restart_connect relay_url))
      else
        base id Fail
          (Printf.sprintf "connector not running (last sync %s ago)" sync_age)
          (Some
             "No broker-attributed process and last_sync is past the freshness \
              threshold. Outbox will not drain until a connector restarts.")
          (Some (fix_start_connect relay_url))
  | true, None, _ ->
      (* live requires a state file; unreachable in practice. *)
      base id Inconclusive
        "connector reported live without state file (internal inconsistency)"
        None None
  | true, Some st, n ->
      let evidence =
        if n > 0 then Printf.sprintf "%d proc + fresh last_ok" n
        else "fresh last_ok (state file)"
      in
      let last_err =
        match st.C2c_relay_connector.cs_last_error_detail with
        | Some e -> Printf.sprintf " last error: %s" e
        | None -> ""
      in
      let recent_err = has_recent_error ~now st in
      let status, detail, fix =
        if recent_err then
          let op =
            Option.value st.C2c_relay_connector.cs_last_error_op ~default:"?"
          in
          let ts =
            Option.value st.C2c_relay_connector.cs_last_error_ts ~default:0.0
          in
          ( Fail,
            Some
              (Printf.sprintf "recent error %s ago on %s%s" (age_str now ts) op
                 last_err),
            Some (fix_restart_connect relay_url) )
        else
          ( Pass,
            Some
              (Printf.sprintf
                 "last ok sync %s ago; fwd=%d failed=%d dlq=%d inbound=%d"
                 (age_str now st.C2c_relay_connector.cs_last_ok_ts)
                 st.C2c_relay_connector.cs_outbox_forwarded
                 st.C2c_relay_connector.cs_outbox_failed
                 st.C2c_relay_connector.cs_outbox_dlqed
                 st.C2c_relay_connector.cs_inbound_delivered),
            None )
      in
      base id status
        (Printf.sprintf "connector bridge live (%s); last sync %s ago%s" evidence
           (age_str now st.C2c_relay_connector.cs_last_sync_ts) last_err)
        detail fix
