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
     [connector_running] requires broker-owned evidence.
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

(* Broker-owned "connector running" signal used to gate the connect capability:
   a broker-attributed process OR a fresh broker-owned connector-state file.
   Machine-global pgrep alone is deliberately NOT enough. *)
let connector_running ~scoped_procs ~state ~now =
  scoped_procs <> []
  || (match state with Some st -> connector_state_is_fresh ~now st | None -> false)

(* Compact relative-age formatter for connector messages. *)
let age_str now ts =
  let delta = max 0.0 (now -. ts) in
  if delta < 60.0 then Printf.sprintf "%.0fs" delta
  else if delta < 3600.0 then Printf.sprintf "%.0fm" (delta /. 60.0)
  else if delta < 86400.0 then Printf.sprintf "%.0fh" (delta /. 3600.0)
  else Printf.sprintf "%.1fd" (delta /. 86400.0)

let recent_error_window_s = 300.0

(* Pure connector check. Every FAIL carries a copy-pasteable fix_command
   (B093 item 5 — some FAIL branches previously had fix_command=None).

   The "is the connector running?" determination is the SAME broker-owned
   signal the capabilities matrix consumes ([connector_running]): a scoped
   process OR a fresh broker-owned state file. This closes the peer-review B1
   false negative: the canonical launch `c2c relay connect --relay-url <url>`
   carries NO --broker-root on argv, so [scope_connector_lines] yields
   scoped_procs=[] for a genuinely-running healthy connector; the broker-owned
   state file (the authoritative signal, per the design note above) must then
   drive the running/PASS verdict on its own. Deriving both surfaces from
   [connector_running] guarantees they can never contradict — capabilities
   connect=yes ⇒ this check agrees the connector is running (PASS on the
   healthy path, never the "connector not running" falsehood). *)
let connector_check ~relay_url ~scoped_procs ~state ~now =
  let fix_connect =
    Printf.sprintf "c2c relay connect --relay-url %s &" relay_url
  in
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
  let running = connector_running ~scoped_procs ~state ~now in
  match running, state with
  | false, None ->
      base id Fail
        "no relay connector attributable to this broker root and no prior sync state"
        (Some
           "Outbound remote-alias messages will queue in remote-outbox.jsonl \
            indefinitely.")
        (Some fix_connect)
  | false, Some st ->
      (* Not running: scoped_procs=[] AND the state file is stale — the
         connector is genuinely down (its last sync aged past the freshness
         threshold). *)
      let last_sync = st.C2c_relay_connector.cs_last_sync_ts in
      base id Fail
        (Printf.sprintf "connector not running (last sync %s ago)"
           (age_str now last_sync))
        (Some "Outbox will not drain until a connector restarts.")
        (Some fix_connect)
  | true, None ->
      (* Running signal came from a scoped process while no state file exists
         yet — the first sync is still in flight (state=None can only pair with
         running=true via a scoped process). *)
      base id Inconclusive
        (Printf.sprintf
           "connector process attributable to this broker (%d); no state file \
            yet"
           (List.length scoped_procs))
        (Some "First sync may still be in flight.")
        None
  | true, Some st ->
      (* Running with a state file to read: evidence is a scoped process
         AND/OR a fresh broker-owned state file. A fresh healthy state file
         alone (scoped_procs=[]) is authoritative → PASS, matching what
         capabilities reports for the same inputs. *)
      let n = List.length scoped_procs in
      let evidence =
        if n > 0 then Printf.sprintf "%d proc" n else "state file"
      in
      let last_err =
        match st.C2c_relay_connector.cs_last_error_detail with
        | Some e -> Printf.sprintf " last error: %s" e
        | None -> ""
      in
      let recent_err =
        match st.C2c_relay_connector.cs_last_error_ts with
        | Some ts when now -. ts < recent_error_window_s -> true
        | _ -> false
      in
      let status, detail, fix =
        if recent_err then
          let op = Option.value st.C2c_relay_connector.cs_last_error_op ~default:"?" in
          let ts = Option.value st.C2c_relay_connector.cs_last_error_ts ~default:0.0 in
          ( Fail,
            Some
              (Printf.sprintf "recent error %s ago on %s%s" (age_str now ts) op
                 last_err),
            (* B093 item 5: a running-but-erroring connector must still offer a
               fix (previously fix_command=None here). *)
            Some fix_connect )
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
        (Printf.sprintf "connector running (%s); last sync %s ago%s" evidence
           (age_str now st.C2c_relay_connector.cs_last_sync_ts) last_err)
        detail fix
