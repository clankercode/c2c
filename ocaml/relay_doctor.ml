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

(* ---------------------------------------------------------------------------
 * Connector-line classification (B218)
 *
 * `pgrep -af <pat>` matches the FULL command line of ANY process whose argv
 * contains <pat> as a substring — NOT only real connector daemons. That
 * includes: the `sh -c "pgrep …"` wrapper that Unix.open_process_in spawns to
 * run the pipeline; unrelated shells whose argv quotes the string (e.g.
 * `bash -c bl bug --body "…c2c relay connect…"`); grep/editors; and c2c's own
 * `c2c doctor --relay` process. Counting those substring hits as connectors is
 * B218 (c2c doctor --relay reporting phantom "N relay connector processes
 * running" with ZERO real connectors). The canonical classifier below decides
 * connector-ness from the ACTUAL executable + leading subcommand, never
 * substring presence, and is the single source of truth consumed by both
 * [scope_connector_lines] and [persistent_connector_pids]. Pure. *)

(* basename of a path-ish token (handles absolute/relative exe paths). *)
let basename_of tok =
  match String.rindex_opt tok '/' with
  | Some i -> String.sub tok (i + 1) (String.length tok - i - 1)
  | None -> tok

(* Split a raw `pgrep -af` line ("<pid> <cmdline>") into (pid, argv). pgrep -af
   renders the process argv joined by spaces (NUL→space from /proc). We
   whitespace-split: the first token is the pid, the rest approximate argv.
   Args with embedded spaces are over-split, but classification only inspects
   argv[0] and the leading positional subcommand — neither contains spaces.
   Returns None when the leading token is not an integer pid. *)
let split_pgrep_line line =
  let toks =
    String.map (fun c -> if c = '\t' then ' ' else c) (String.trim line)
    |> String.split_on_char ' '
    |> List.filter (fun s -> s <> "")
  in
  match toks with
  | pid :: argv when int_of_string_opt pid <> None -> Some (pid, argv)
  | _ -> None

let is_shell_exe base =
  List.mem base
    [ "sh"; "bash"; "zsh"; "dash"; "fish"; "ksh"; "ash"; "csh"; "tcsh" ]

let is_search_exe base =
  List.mem base
    [ "pgrep"; "pkill"; "grep"; "egrep"; "fgrep"; "rg"; "ag"; "ack" ]

let is_python_exe base =
  String.length base >= 6 && String.sub base 0 6 = "python"

let is_connector_script base =
  base = "c2c_relay_connector" || base = "c2c_relay_connector.py"

(* True iff [line] denotes a genuine, persistent relay-connector process:
   - OCaml: argv[0] basename is the c2c binary (`c2c`, `/abs/…/c2c`, or
     `…/c2c.exe`) AND the leading positional subcommand is `relay connect` — the
     managed supervisor's child (`c2c relay connect --all-brokers`) or a manual
     `c2c relay connect [--relay-url …]`. `--once` transient syncs are excluded.
   - Python: the c2c_relay_connector script is exec'd — either argv[0] is the
     script (shebang) or a `python*` interpreter runs it as an argument.
     `--once` excluded.
   Shell wrappers (`sh -c …`), search tools (`pgrep`/`grep`), the doctor's own
   `c2c doctor` process (subcommand ≠ `relay connect`), and lines where the
   pattern appears only inside a quoted argument (argv[0] is not c2c/python, or
   the leading subcommand differs) are all rejected. Pure — feed it raw pgrep
   lines directly in tests, no process spawning. *)
let is_real_connector_line line =
  match split_pgrep_line line with
  | None | Some (_, []) -> false
  | Some (_pid, exe :: rest) ->
      let base = basename_of exe in
      let has_once = List.mem "--once" rest in
      if is_shell_exe base || is_search_exe base then false
      else if base = "c2c" || base = "c2c.exe" then
        (* leading positional (non-flag) tokens must be `relay connect`. *)
        let positionals =
          List.filter (fun t -> String.length t = 0 || t.[0] <> '-') rest
        in
        (match positionals with
         | "relay" :: "connect" :: _ -> not has_once
         | _ -> false)
      else if is_connector_script base then not has_once
      else if is_python_exe base then
        List.exists (fun t -> is_connector_script (basename_of t)) rest
        && not has_once
      else false

(* A machine-global `pgrep` line is attributable to THIS broker only when it is
   a REAL connector (B218 classifier) AND references this broker root path — the
   unique per-broker discriminator. A connector for another repo/broker (or an
   unrelated shell that merely mentions the string) is NOT this broker's
   connector. This is the fix for the B093 false positive where unrelated
   machine connectors promoted an isolated broker's capabilities to PASS. *)
let scope_connector_lines ~broker_root lines =
  if broker_root = "" || broker_root = "<unresolved>" then []
  else
    lines
    |> List.filter is_real_connector_line
    |> List.filter (fun l -> string_contains ~needle:broker_root l)

(* B210: machine-wide duplicate-connector detection. Persistent connectors
   (manual `c2c relay connect`, `--all-brokers`, or the managed supervisor's
   child) beyond the first indicate an uncoordinated multi-connect that storms
   the relay with 429s. [lines] are the raw machine-global pgrep `PID cmdline`
   lines (NOT scoped to a broker). B218: classify by actual executable +
   subcommand ([is_real_connector_line]) so shell wrappers, grep, bug-report
   shells, and the doctor's own process are never miscounted; `--once`
   transient syncs are excluded by the classifier. Returns the distinct
   persistent-connector pids. Pure. *)
let persistent_connector_pids lines =
  lines
  |> List.filter is_real_connector_line
  |> List.filter_map (fun l ->
       match split_pgrep_line l with
       | Some (pid, _) -> int_of_string_opt pid
       | None -> None)
  |> List.sort_uniq compare

(* A single [relay.connector_singleton] check surfaced only when >1 persistent
   connector is live on the host (B210 acceptance: duplicates prevented OR
   clearly surfaced). Returns None when 0 or 1 — the singleton invariant holds
   and there is nothing to warn about. *)
let duplicate_connector_check ~pids =
  match pids with
  | _ :: _ :: _ ->
      let n = List.length pids in
      Some {
        check_id = "relay.connector_singleton";
        status = Fail;
        message =
          Printf.sprintf
            "%d relay connector processes running on this host (expected 1) — \
             duplicates cause relay 429 storms (B210)"
            n;
        detail =
          Some
            (Printf.sprintf
               "pids: %s. A bare `c2c relay connect` or manual `--all-brokers` \
                started alongside the managed connector. Newer c2c refuses a \
                second persistent connector; stop the extras and keep exactly \
                one."
               (String.concat ", " (List.map string_of_int pids)));
        fix_command =
          Some
            "c2c stop relay-connect; pkill -f 'c2c relay connect'; \
             c2c start relay-connect";
        docs_url = Some docs_url;
      }
  | _ -> None

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


(* ---------------------------------------------------------------------------
 * B266 private-reachability diagnostics (pure; hermetically testable)
 * Shared by `c2c doctor --relay` via c2c_doctor_relay.ml.
 * --------------------------------------------------------------------------- *)

let auth_mode_of_health = function
  | None -> "unknown"
  | Some j ->
      Yojson.Safe.Util.(j |> member "auth_mode" |> to_string_option)
      |> Option.value ~default:"unknown"

let check_auth_mode ~health =
  match health with
  | None ->
      { check_id = "relay.auth_mode"
      ; status = Inconclusive
      ; message = "auth_mode check skipped (relay unreachable)"
      ; detail = None
      ; fix_command = None
      ; docs_url = Some docs_url }
  | Some j ->
      let mode = auth_mode_of_health (Some j) in
      if mode = "prod" then
        { check_id = "relay.auth_mode"
        ; status = Pass
        ; message = "auth_mode=prod (token-configured)"
        ; detail = None
        ; fix_command = None
        ; docs_url = Some docs_url }
      else if mode = "dev" then
        { check_id = "relay.auth_mode"
        ; status = Fail
        ; message =
            "auth_mode=dev (tokenless): private-reachability claims do not apply; contact delivery is refused"
        ; detail =
            Some "Configure C2C_RELAY_TOKEN / c2c relay serve --token for production"
        ; fix_command =
            Some "c2c relay serve --token <TOKEN>   # or set C2C_RELAY_TOKEN"
        ; docs_url = Some docs_url }
      else
        { check_id = "relay.auth_mode"
        ; status = Inconclusive
        ; message = Printf.sprintf "auth_mode=%s (unrecognised)" mode
        ; detail = None
        ; fix_command = None
        ; docs_url = Some docs_url }

let check_contact_protocol ~health =
  match health with
  | None ->
      { check_id = "relay.contact_protocol"
      ; status = Inconclusive
      ; message = "contact_protocol check skipped (relay unreachable)"
      ; detail = None
      ; fix_command = None
      ; docs_url = Some docs_url }
  | Some j ->
      (match Yojson.Safe.Util.member "contact_protocol" j with
       | `Int 1 ->
           { check_id = "relay.contact_protocol"
           ; status = Pass
           ; message = "contact_protocol=1 (c2c-contact/1)"
           ; detail = None
           ; fix_command = None
           ; docs_url = Some docs_url }
       | `Int n ->
           { check_id = "relay.contact_protocol"
           ; status = Fail
           ; message = Printf.sprintf "unsupported contact_protocol=%d" n
           ; detail = None
           ; fix_command = Some "git pull && just install-all"
           ; docs_url = Some docs_url }
       | _ ->
           { check_id = "relay.contact_protocol"
           ; status = Fail
           ; message =
               "contact_protocol not advertised (pre-B265 relay; mixed-version risk)"
           ; detail = Some "Upgrade relay to advertise contact_protocol:1"
           ; fix_command = Some "deploy/upgrade c2c relay binary"
           ; docs_url = Some docs_url })

let check_private_reachability ~health =
  match health with
  | None ->
      { check_id = "relay.private_reachability"
      ; status = Inconclusive
      ; message = "private_reachability check skipped (relay unreachable)"
      ; detail = None
      ; fix_command = None
      ; docs_url = Some docs_url }
  | Some j ->
      let mode = auth_mode_of_health (Some j) in
      (match Yojson.Safe.Util.member "private_reachability" j with
       | `String "consent_gated" when mode = "prod" ->
           { check_id = "relay.private_reachability"
           ; status = Pass
           ; message = "private_reachability=consent_gated (production)"
           ; detail = None
           ; fix_command = None
           ; docs_url = Some docs_url }
       | `String "consent_gated" ->
           { check_id = "relay.private_reachability"
           ; status = Inconclusive
           ; message =
               "private_reachability=consent_gated but auth_mode is not prod"
           ; detail =
               Some
                 "Tokenless/dev mode cannot substantiate private-reachability claims"
           ; fix_command = None
           ; docs_url = Some docs_url }
       | `String "process_local" when mode = "prod" ->
           { check_id = "relay.private_reachability"
           ; status = Fail
           ; message =
               "private_reachability=process_local (in-memory; not durable production)"
           ; detail =
               Some "Serve with --storage sqlite for durable consent-gated reachability"
           ; fix_command =
               Some "c2c relay serve --storage sqlite --token <TOKEN> ..."
           ; docs_url = Some docs_url }
       | `String "process_local" ->
           { check_id = "relay.private_reachability"
           ; status = Inconclusive
           ; message = "private_reachability=process_local (dev/in-memory)"
           ; detail = None
           ; fix_command = None
           ; docs_url = Some docs_url }
       | `String other ->
           { check_id = "relay.private_reachability"
           ; status = Fail
           ; message = Printf.sprintf "unexpected private_reachability=%s" other
           ; detail = None
           ; fix_command = Some "upgrade c2c relay binary"
           ; docs_url = Some docs_url }
       | _ ->
           { check_id = "relay.private_reachability"
           ; status = Fail
           ; message =
               "private_reachability not advertised (legacy/global-discovery relay)"
           ; detail = Some "Upgrade relay; do not claim consent-gated reachability"
           ; fix_command = Some "deploy/upgrade c2c relay binary"
           ; docs_url = Some docs_url })

let check_transport_security ~url ~health =
  let tls =
    match Uri.scheme (Uri.of_string url) with
    | Some ("https" | "wss") -> true
    | _ -> false
  in
  let mode = auth_mode_of_health health in
  if mode = "prod" && not tls then
    { check_id = "relay.transport_security"
    ; status = Fail
    ; message =
        "production relay URL is not TLS (grant secrets require confidential transport)"
    ; detail = Some url
    ; fix_command = Some "use https:// or wss:// relay URL behind TLS terminator"
    ; docs_url = Some docs_url }
  else if not tls then
    { check_id = "relay.transport_security"
    ; status = Inconclusive
    ; message = "plaintext relay URL (acceptable only for local/dev)"
    ; detail = Some url
    ; fix_command = None
    ; docs_url = Some docs_url }
  else
    { check_id = "relay.transport_security"
    ; status = Pass
    ; message = "TLS scheme on relay URL"
    ; detail = None
    ; fix_command = None
    ; docs_url = Some docs_url }
