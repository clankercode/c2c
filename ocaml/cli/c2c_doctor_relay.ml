(* c2c_doctor_relay — relay-side health checks for `c2c doctor --relay` (B093).

   `c2c doctor` historically checked nothing relay-side: a dead connector or
   a stuck remote-outbox was only findable by grepping broker files. This
   module runs a battery of structured checks (each with a stable check_id,
   a copy-pasteable fix_command, and a docs_url) and renders them in Human or
   JSON form. A non-zero exit is produced when any check FAILs.

   Reuses [C2c_relay_cmd.default_public_relay_url] / [resolve_relay_url] so the
   default relay URL is never hardcoded here, and [C2c_relay_connector] for
   outbox + connector-state inspection. *)

open Printf

(* ---------------------------------------------------------------------------
 * Check result types
 * --------------------------------------------------------------------------- *)

type check_status = Pass | Fail | Inconclusive

type check_result = {
  check_id : string;            (* stable identifier, never reordered/renamed *)
  status : check_status;
  message : string;             (* one-line human summary *)
  detail : string option;       (* optional multi-line extra context *)
  fix_command : string option;  (* copy-pasteable shell, no leading prompt *)
  docs_url : string option;
}

let status_str = function Pass -> "PASS" | Fail -> "FAIL" | Inconclusive -> "INCONCLUSIVE"

(* Canonical relay docs permalink lives in the shared core module so the
   subscribe guard, doctor, and tests never drift on the target URL. *)
let docs_relay = Relay_doctor.docs_url

(* Adapt a pure Relay_doctor.check_result (shared with the subscribe command)
   into the doctor-local check_result shape used by the renderers. *)
let status_of_rd = function
  | Relay_doctor.Pass -> Pass
  | Relay_doctor.Fail -> Fail
  | Relay_doctor.Inconclusive -> Inconclusive

let of_rd (r : Relay_doctor.check_result) =
  { check_id = r.Relay_doctor.check_id
  ; status = status_of_rd r.Relay_doctor.status
  ; message = r.Relay_doctor.message
  ; detail = r.Relay_doctor.detail
  ; fix_command = r.Relay_doctor.fix_command
  ; docs_url = r.Relay_doctor.docs_url }

(* ---------------------------------------------------------------------------
 * Helpers
 * --------------------------------------------------------------------------- *)

let resolve_broker_root () =
  try C2c_utils.resolve_broker_root () with _ -> "<unresolved>"

(* Resolve relay URL + report the source so the operator knows where it came
   from. Returns (url, source). *)
let resolve_url_with_source () =
  match Sys.getenv_opt "C2C_RELAY_URL" with
  | Some v when String.trim v <> "" -> (String.trim v, "env C2C_RELAY_URL")
  | _ ->
      (match C2c_relay_cmd.resolve_relay_url None with
       | Some v -> (v, "c2c relay setup config (relay.json)")
       | None -> (C2c_relay_cmd.default_public_relay_url, "default (public relay)"))

let age_str now ts =
  let delta = max 0.0 (now -. ts) in
  if delta < 60.0 then sprintf "%.0fs" delta
  else if delta < 3600.0 then sprintf "%.0fm" (delta /. 60.0)
  else if delta < 86400.0 then sprintf "%.0fh" (delta /. 3600.0)
  else sprintf "%.1fd" (delta /. 86400.0)

let rec take_first k xs = match xs, k with
  | _, 0 | [], _ -> []
  | x :: tl, _ -> x :: take_first (k - 1) tl

(* Detect a running relay connector process (OCaml `c2c relay connect` or the
   Python c2c_relay_connector.py). Returns the raw `pgrep -af` "PID cmdline"
   lines — INCLUDING substring-only false positives (the sh -c wrapper this
   very function spawns, bug-report shells, grep, the doctor's own process).
   Classification into real connectors is the pure Relay_doctor classifier
   ([is_real_connector_line], consumed by scope_connector_lines /
   persistent_connector_pids); callers must NOT treat these raw lines as
   connectors directly (B218). *)
let detect_connector_processes () =
  let patterns =
    [ "c2c relay connect"
    ; "c2c_relay_connector"
    ]
  in
  List.concat_map
    (fun pat ->
       let cmd = sprintf "pgrep -af %s 2>/dev/null" (Filename.quote pat) in
       let ic = Unix.open_process_in cmd in
       let lines =
         Fun.protect ~finally:(fun () -> ignore (Unix.close_process_in ic))
           (fun () ->
              let acc = ref [] in
              (try while true do acc := input_line ic :: !acc done
               with End_of_file -> ());
              List.rev !acc)
       in
       (* B218: pgrep -af matches the FULL cmdline of ANY process containing
          the pattern as a SUBSTRING — not just real connector daemons. It
          excludes only pgrep's own pid, NOT the `sh -c` wrapper that
          open_process_in spawns to run this pipeline, nor unrelated shells
          whose argv quotes "c2c relay connect" (bug reports, the doctor's own
          remediation strings), grep/editors, or `c2c doctor --relay` itself.
          These raw lines are returned as-is; the pure Relay_doctor classifier
          (is_real_connector_line) filters them downstream. *)
       lines)
    patterns

let identity_opt () =
  (* Mirrors relay_connect_cmd's resolution: C2C_RELAY_IDENTITY_PATH env wins,
     else the default path if it exists. *)
  let path =
    match Sys.getenv_opt "C2C_RELAY_IDENTITY_PATH" with
    | Some p -> Some p
    | None ->
        let p = Relay_identity.default_path () in
        if Sys.file_exists p then Some p else None
  in
  match path with
  | Some p -> (match Relay_identity.load ~path:p () with Ok id -> Some id | Error _ -> None)
  | None -> None

(* ---------------------------------------------------------------------------
 * Probe (one Lwt pass: /health + /list)
 * --------------------------------------------------------------------------- *)

type probe = {
  url : string;
  url_source : string;
  health : Yojson.Safe.t option;     (* None if unreachable / errored *)
  health_error : string option;
  peers : Yojson.Safe.t list;        (* [] if /list failed or returned none *)
  list_error : string option;
  list_needs_auth : bool;            (* relay rejected unsigned /list *)
}

let extract_peers = function
  | `Assoc fs ->
      (match List.assoc_opt "peers" fs with
       | Some (`List xs) -> xs
       | _ -> [])
  | _ -> []

let needs_auth = function
  | `Assoc fs ->
      (match List.assoc_opt "error_code" fs with
       | Some (`String s) ->
           let lc = String.lowercase_ascii s in
           lc = "unauthorized" || lc = "needs_identity"
           || lc = "auth_required" || lc = "missing_identity"
       | _ -> false)
  | _ -> false

(* If /list returned ok=false for a non-auth reason (e.g. transient
   connection_error while /health still succeeded), surface the error string
   so the lease check can mark itself INCONCLUSIVE rather than falsely
   reporting every alias as missing. *)
let list_error_of = function
  | `Assoc fs when List.assoc_opt "ok" fs = Some (`Bool false) ->
      (match List.assoc_opt "error" fs with
       | Some (`String s) -> Some s
       | _ -> Some "unknown /list error")
  | _ -> None

let probe_relay ~url ~token ~identity ~signing_alias =
  let client = Relay.Relay_client.make ?token ~timeout:5.0 url in
  (* /health is unauthenticated. /list may need a signed request in prod mode;
     sign as the caller's real alias so a bound identity is accepted. *)
  let list_lwt =
    match identity, signing_alias with
    | Some id, Some alias ->
        (try
           let auth = Relay_signed_ops.sign_request id ~alias
             ~meth:"GET" ~path:"/list" ~body_str:"" () in
           Relay.Relay_client.list_peers_signed client ~auth_header:auth ()
         with e -> Lwt.return (`Assoc []))
    | _ -> Relay.Relay_client.list_peers client ()
  in
  let open Lwt.Infix in
  Lwt_main.run
    (Lwt.try_bind
       (fun () ->
          Relay.Relay_client.health client >>= fun health ->
          list_lwt >>= fun list_resp ->
          Lwt.return (health, list_resp))
       (fun (health, list_resp) ->
          let peers = extract_peers list_resp in
          let na = needs_auth list_resp in
          let list_error = if na then None else list_error_of list_resp in
          (* H7: Relay_client never raises — transport failures (connection
             refused, timeout, unparseable response) come back as a locally
             SYNTHESIZED ok:false JSON carrying transport:true. Fold those
             back into the unreachable branch (health = None + health_error)
             so relay.reachable / relay.lease / relay.capabilities judge a
             dead relay honestly instead of treating the client's own error
             object as proof the relay responded (C047 false PASS). *)
          let health, health_error =
            if Relay.Relay_client.is_transport_error health then
              let err =
                match health with
                | `Assoc fs ->
                    (match List.assoc_opt "error" fs with
                     | Some (`String s) -> s
                     | _ -> "connection_error")
                | _ -> "connection_error"
              in
              (None, Some err)
            else (Some health, None)
          in
          Lwt.return
            { url; url_source = ""; health; health_error;
              peers; list_error; list_needs_auth = na })
       (fun e ->
          (* Defensive only: with the H7 contract Relay_client no longer
             raises, so this branch should be dead — kept as a safety net. *)
          Lwt.return
            { url; url_source = ""; health = None;
              health_error = Some (Printexc.to_string e);
              peers = []; list_error = None; list_needs_auth = false }))

(* ---------------------------------------------------------------------------
 * Checks
 * --------------------------------------------------------------------------- *)

let check_configured ~probe =
  { check_id = "relay.configured"
  ; status = Pass
  ; message = sprintf "relay URL: %s (from %s)" probe.url probe.url_source
  ; detail = None
  ; fix_command =
      Some (sprintf "c2c relay setup --url %s" C2c_relay_cmd.default_public_relay_url)
  ; docs_url = Some docs_relay }

let check_reachable ~probe =
  match probe.health, probe.health_error with
  | None, Some err ->
      { check_id = "relay.reachable"
      ; status = Fail
      ; message = sprintf "relay unreachable: %s" probe.url
      ; detail = Some (sprintf "error: %s" err)
      ; fix_command =
          Some (sprintf
            "c2c relay status --relay-url %s   # confirm; if down, check the \
             relay host or run a local relay with: c2c relay serve"
            probe.url)
      ; docs_url = Some docs_relay }
  | None, None ->
      { check_id = "relay.reachable"
      ; status = Inconclusive
      ; message = "relay reachable: no response and no error captured"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j, _ ->
      let open Yojson.Safe.Util in
      let ok = j |> member "ok" = `Bool true in
      let version = j |> member "version" |> to_string_option |> Option.value ~default:"?" in
      let git_hash = j |> member "git_hash" |> to_string_option |> Option.value ~default:"?" in
      let auth_mode = j |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown" in
      (* B121: protocol-skew health is rewritten to ok:false/incompatible_client
         by Relay_client.health — still proves the host is up; the dedicated
         relay.protocol check carries the FAIL + upgrade guidance. *)
      if ok || Relay.Relay_client.is_protocol_incompatible j then
        let version =
          if version = "?" then
            j |> member "server_version" |> to_string_option
            |> Option.value ~default:"?"
          else version
        in
        { check_id = "relay.reachable"
        ; status = Pass
        ; message = sprintf "relay reachable — %s @ %s (auth: %s)"
            version git_hash auth_mode
        ; detail = Some (sprintf "GET %s/health → responded" probe.url)
        ; fix_command = None
        ; docs_url = Some docs_relay }
      else
        (* The relay returned a well-formed JSON response — even ok=false
           (e.g. "unknown endpoint /health" on an older relay version).
           Receiving a coherent HTTP/JSON reply PROVES reachability; ok=false
           here is an endpoint/detail nuance, NOT an unreachability condition.
           Client-synthesized transport errors never reach this branch:
           probe_relay folds them (via Relay_client.is_transport_error) into
           health = None, which lands in the FAIL branch above (H7). *)
        { check_id = "relay.reachable"
        ; status = Pass
        ; message =
            sprintf "relay reachable (responded; ok=false from %s/health)"
              probe.url
        ; detail = Some (Yojson.Safe.pretty_to_string j)
        ; fix_command = None
        ; docs_url = Some docs_relay }

(* B121: wire protocol compatibility. Distinct from reachability — the relay
   can be up while this client is too old (or too new) for its wire version. *)
(* B266: production private-reachability diagnostics. *)
let check_auth_mode ~probe =
  match probe.health with
  | None ->
      { check_id = "relay.auth_mode"
      ; status = Inconclusive
      ; message = "auth_mode check skipped (relay unreachable)"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j ->
      let open Yojson.Safe.Util in
      let mode =
        j |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown"
      in
      if mode = "prod" then
        { check_id = "relay.auth_mode"
        ; status = Pass
        ; message = "auth_mode=prod (token-configured)"
        ; detail = None; fix_command = None; docs_url = Some docs_relay }
      else if mode = "dev" then
        { check_id = "relay.auth_mode"
        ; status = Fail
        ; message =
            "auth_mode=dev (tokenless): private-reachability claims do not apply; contact delivery is refused"
        ; detail = Some "Configure C2C_RELAY_TOKEN / c2c relay serve --token for production"
        ; fix_command = Some "c2c relay serve --token <TOKEN>   # or set C2C_RELAY_TOKEN"
        ; docs_url = Some docs_relay }
      else
        { check_id = "relay.auth_mode"
        ; status = Inconclusive
        ; message = sprintf "auth_mode=%s (unrecognised)" mode
        ; detail = None; fix_command = None; docs_url = Some docs_relay }

let check_contact_protocol ~probe =
  match probe.health with
  | None ->
      { check_id = "relay.contact_protocol"
      ; status = Inconclusive
      ; message = "contact_protocol check skipped (relay unreachable)"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j ->
      let open Yojson.Safe.Util in
      (match j |> member "contact_protocol" with
       | `Int 1 ->
           { check_id = "relay.contact_protocol"
           ; status = Pass
           ; message = "contact_protocol=1 (c2c-contact/1)"
           ; detail = None; fix_command = None; docs_url = Some docs_relay }
       | `Int n ->
           { check_id = "relay.contact_protocol"
           ; status = Fail
           ; message = sprintf "unsupported contact_protocol=%d" n
           ; detail = None
           ; fix_command = Some "git pull && just install-all"
           ; docs_url = Some docs_relay }
       | _ ->
           { check_id = "relay.contact_protocol"
           ; status = Fail
           ; message =
               "contact_protocol not advertised (pre-B265 relay; mixed-version risk)"
           ; detail = Some "Upgrade relay to advertise contact_protocol:1"
           ; fix_command = Some "deploy/upgrade c2c relay binary"
           ; docs_url = Some docs_relay })

(* B266: health must advertise private_reachability=consent_gated for production
   claims. Missing or unexpected values fail closed for doctor. *)
let check_private_reachability ~probe =
  match probe.health with
  | None ->
      { check_id = "relay.private_reachability"
      ; status = Inconclusive
      ; message = "private_reachability check skipped (relay unreachable)"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j ->
      let open Yojson.Safe.Util in
      let mode =
        j |> member "auth_mode" |> to_string_option |> Option.value ~default:"unknown"
      in
      (match j |> member "private_reachability" with
       | `String "consent_gated" when mode = "prod" ->
           { check_id = "relay.private_reachability"
           ; status = Pass
           ; message = "private_reachability=consent_gated (production)"
           ; detail = None; fix_command = None; docs_url = Some docs_relay }
       | `String "consent_gated" ->
           { check_id = "relay.private_reachability"
           ; status = Inconclusive
           ; message =
               "private_reachability=consent_gated but auth_mode is not prod"
           ; detail = Some "Tokenless/dev mode cannot substantiate private-reachability claims"
           ; fix_command = None; docs_url = Some docs_relay }
       | `String other ->
           { check_id = "relay.private_reachability"
           ; status = Fail
           ; message = sprintf "unexpected private_reachability=%s" other
           ; detail = None
           ; fix_command = Some "upgrade c2c relay binary"
           ; docs_url = Some docs_relay }
       | _ ->
           { check_id = "relay.private_reachability"
           ; status = Fail
           ; message =
               "private_reachability not advertised (legacy/global-discovery relay)"
           ; detail = Some "Upgrade relay; do not claim consent-gated reachability"
           ; fix_command = Some "deploy/upgrade c2c relay binary"
           ; docs_url = Some docs_relay })

let check_transport_security ~probe =
  let url = probe.url in
  let tls =
    match Uri.scheme (Uri.of_string url) with
    | Some ("https" | "wss") -> true
    | _ -> false
  in
  let mode =
    match probe.health with
    | Some j ->
        Yojson.Safe.Util.(j |> member "auth_mode" |> to_string_option)
        |> Option.value ~default:"unknown"
    | None -> "unknown"
  in
  if mode = "prod" && not tls then
    { check_id = "relay.transport_security"
    ; status = Fail
    ; message =
        "production relay URL is not TLS (grant secrets require confidential transport)"
    ; detail = Some url
    ; fix_command = Some "use https:// or wss:// relay URL behind TLS terminator"
    ; docs_url = Some docs_relay }
  else if not tls then
    { check_id = "relay.transport_security"
    ; status = Inconclusive
    ; message = "plaintext relay URL (acceptable only for local/dev)"
    ; detail = Some url; fix_command = None; docs_url = Some docs_relay }
  else
    { check_id = "relay.transport_security"
    ; status = Pass
    ; message = "TLS scheme on relay URL"
    ; detail = None; fix_command = None; docs_url = Some docs_relay }

let check_protocol ~probe =
  match probe.health with
  | None ->
      { check_id = "relay.protocol"
      ; status = Inconclusive
      ; message = "protocol check skipped (relay unreachable)"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j when Relay.Relay_client.is_protocol_incompatible j ->
      let open Yojson.Safe.Util in
      let msg =
        j |> member "error" |> to_string_option
        |> Option.value
             ~default:(sprintf
               "relay %s speaks an incompatible protocol; upgrade c2c \
                (git pull && just install-all)"
               probe.url)
      in
      (* Prefer the structured too-new/too-old signal when present so the
         fix_command matches the error direction (upgrade client vs wait
         for relay deploy). Fall back to upgrade-client for rewritten
         health bodies that only carry the error string. *)
      let client_pv =
        match j |> member "client_protocol_version" with
        | `Int i -> i
        | _ -> Version.relay_protocol_version
      in
      let server_pv =
        match j |> member "server_protocol_version" with
        | `Int i -> Some i
        | _ -> None
      in
      let fix_command =
        match server_pv with
        | Some sp when client_pv > sp ->
            Some (sprintf
              "wait for relay deploy, or: c2c relay setup --url <matching-relay>   \
               # client v%d is newer than relay protocol v%d"
              client_pv sp)
        | _ ->
            Some "git pull && just install-all   # then retry c2c relay status"
      in
      { check_id = "relay.protocol"
      ; status = Fail
      ; message = msg
      ; detail = Some (Yojson.Safe.pretty_to_string j)
      ; fix_command
      ; docs_url = Some docs_relay }
  | Some j ->
      (match Relay.Relay_client.protocol_compat_of_health j with
       | Relay.Relay_client.Compatible ->
           let open Yojson.Safe.Util in
           let pv =
             match j |> member "protocol_version" with
             | `Int i -> string_of_int i
             | _ -> string_of_int Version.relay_protocol_version
           in
           { check_id = "relay.protocol"
           ; status = Pass
           ; message = sprintf "protocol compatible (v%s)" pv
           ; detail = None; fix_command = None; docs_url = Some docs_relay }
       | Relay.Relay_client.Unknown ->
           { check_id = "relay.protocol"
           ; status = Pass
           ; message =
               "protocol version not advertised (pre-B121 relay; assuming compatible)"
           ; detail = None; fix_command = None; docs_url = Some docs_relay }
       | Relay.Relay_client.Client_too_old _ as compat ->
           let msg =
             match Relay.Relay_client.upgrade_message ~url:probe.url compat with
             | Some m -> m
             | None -> "incompatible relay protocol"
           in
           { check_id = "relay.protocol"
           ; status = Fail
           ; message = msg
           ; detail = Some (Yojson.Safe.pretty_to_string j)
           ; fix_command =
               Some "git pull && just install-all   # then retry c2c relay status"
           ; docs_url = Some docs_relay }
       | Relay.Relay_client.Client_too_new {
           server_protocol; client_protocol; _
         } as compat ->
           let msg =
             match Relay.Relay_client.upgrade_message ~url:probe.url compat with
             | Some m -> m
             | None -> "incompatible relay protocol"
           in
           { check_id = "relay.protocol"
           ; status = Fail
           ; message = msg
           ; detail = Some (Yojson.Safe.pretty_to_string j)
           ; fix_command =
               Some (sprintf
                 "wait for relay deploy, or: c2c relay setup --url <matching-relay>   \
                  # client v%d is newer than relay protocol v%d"
                 client_protocol server_protocol)
           ; docs_url = Some docs_relay })

let check_lease ~probe ~local_aliases ~local_total =
  if probe.health = None then
    { check_id = "relay.lease"
    ; status = Inconclusive
    ; message = "lease check skipped (relay unreachable)"
    ; detail = None; fix_command = None; docs_url = Some docs_relay }
  else if local_aliases = [] then
    { check_id = "relay.lease"
    ; status = Inconclusive
    ; message =
        sprintf "no alive local aliases to lease-check (%d total, 0 alive)"
          local_total
    ; detail = None
    ; fix_command = Some "c2c init   # or restart a managed client (c2c start <client>)"
    ; docs_url = Some docs_relay }
  else if probe.list_needs_auth then
    { check_id = "relay.lease"
    ; status = Inconclusive
    ; message = "relay requires signed /list; no usable local identity"
    ; detail = Some "Run `c2c relay list` to inspect leases manually."
    ; fix_command = Some "c2c relay identity init && c2c relay register --alias <alias>"
    ; docs_url = Some docs_relay }
  else if probe.list_error <> None then
    { check_id = "relay.lease"
    ; status = Inconclusive
    ; message = sprintf "/list failed: %s"
        (Option.value probe.list_error ~default:"(unknown)")
    ; detail = Some "Relay reachable but /list errored; cannot assess leases."
    ; fix_command = Some (sprintf "c2c relay list --relay-url %s" probe.url)
    ; docs_url = Some docs_relay }
  else
    let open Yojson.Safe.Util in
    (* Store (alive, remaining_lease_seconds) per peer alias so the TTL/expiry
       is surfaced, not just the alive boolean (B093 asks for TTL/expiry). *)
    let now = Unix.gettimeofday () in
    let peer_info = Hashtbl.create 16 in
    List.iter
      (fun p ->
         let alias = match p |> member "alias" with `String s -> s | _ -> "" in
         let alive = match p |> member "alive" with `Bool b -> b | _ -> false in
         let last_seen = match p |> member "last_seen" with
           | `Float f -> f | `Int i -> float_of_int i | _ -> now in
         let ttl = match p |> member "ttl" with
           | `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
         let remaining = (last_seen +. ttl) -. now in
         if alias <> "" then Hashtbl.replace peer_info alias (alive, remaining))
      probe.peers;
    let truly_missing =
      List.filter (fun a -> not (Hashtbl.mem peer_info a)) local_aliases
    in
    let truly_dead =
      List.filter
        (fun a ->
           match Hashtbl.find_opt peer_info a with
           | Some (alive, _) -> not alive
           | None -> false)
        local_aliases
    in
    if truly_missing = [] && truly_dead = [] then begin
      (* Report the shortest remaining lease so the operator knows when the
         next heartbeat is due. *)
      let min_remaining =
        List.filter_map
          (fun a -> match Hashtbl.find_opt peer_info a with
           | Some (_, r) -> Some r | None -> None)
          local_aliases
        |> List.fold_left min infinity
      in
      let detail =
        if min_remaining = infinity then None
        else Some (sprintf "shortest remaining lease: %s" (age_str now (now -. min_remaining)))
      in
      { check_id = "relay.lease"
      ; status = Pass
      ; message = sprintf "all %d alive local alias(es) have live leases"
          (List.length local_aliases)
      ; detail; fix_command = None; docs_url = Some docs_relay }
    end
    else
      (* Cap the named lists so the output isn't drowned by a huge roster. *)
      let cap ~label xs =
        let n = List.length xs in
        let shown =
          xs |> (fun l -> if List.length l > 10 then take_first 10 l else l)
          |> String.concat ", "
        in
        sprintf "%s: %s%s" label shown
          (if n > 10 then sprintf " (+%d more)" (n - 10) else "")
      in
      let bits = [] in
      let bits =
        if truly_missing <> [] then cap ~label:"not registered" truly_missing :: bits
        else bits
      in
      let bits =
        if truly_dead <> [] then cap ~label:"lease expired" truly_dead :: bits
        else bits
      in
      { check_id = "relay.lease"
      ; status = Fail
      ; message = sprintf "%d/%d alive alias(es) missing or expired"
          (List.length truly_missing + List.length truly_dead)
          (List.length local_aliases)
      ; detail = Some (String.concat "\n" bits)
      ; fix_command =
          Some (sprintf "c2c relay connect --relay-url %s   # re-registers + heartbeats"
                  probe.url)
      ; docs_url = Some docs_relay }

(* Broker-owned connector check: machine-global pgrep matches are scoped to
   this broker root (Relay_doctor.scope_connector_lines) so an unrelated
   connector on the same box can't falsely report "running" here (B093). All
   the branch/staleness/fix logic is the pure Relay_doctor.connector_check. *)
let check_connector ~relay_url ~scoped_procs ~state ~now =
  of_rd (Relay_doctor.connector_check ~relay_url ~scoped_procs ~state ~now)

let check_outbox ~broker_root =
  let entries = C2c_relay_connector.read_outbox broker_root in
  let depth = List.length entries in
  let now = Unix.gettimeofday () in
  if depth = 0 then
    { check_id = "relay.outbox"
    ; status = Pass
    ; message = "remote-outbox empty (0 pending)"
    ; detail = None; fix_command = None; docs_url = Some docs_relay }
  else
    let oldest =
      List.fold_left
        (fun acc e ->
           if e.C2c_relay_connector.ob_enqueued_at < acc
           then e.C2c_relay_connector.ob_enqueued_at else acc)
        now entries
    in
    let age = now -. oldest in
    let stuck = age > C2c_relay_connector.max_age_seconds in
    let deep = depth > 25 in
    let status = if stuck || deep then Fail else Pass in
    let fix_command =
      let (url, _) = resolve_url_with_source () in
      if stuck then
        Some (sprintf
                "c2c relay connect --relay-url %s --once   # drain now; check relay reachability\n\
                 # inspect stuck entries: head $(c2c root)/remote-outbox.jsonl"
                url)
      else if deep then
        Some "c2c relay connect --once   # drain the backlog"
      else None
    in
    let per_recip =
      let tbl = Hashtbl.create 8 in
      List.iter (fun e ->
          let n = try Hashtbl.find tbl e.C2c_relay_connector.ob_to with Not_found -> 0 in
          Hashtbl.replace tbl e.C2c_relay_connector.ob_to (n + 1)) entries;
      Hashtbl.fold (fun k v acc -> sprintf "  %s: %d" k v :: acc) tbl []
      |> List.rev |> String.concat "\n"
    in
    { check_id = "relay.outbox"
    ; status
    ; message = sprintf "remote-outbox depth=%d oldest=%s%s"
        depth (age_str now oldest)
        (if stuck then " (STUCK > 1h)" else if deep then " (deep)" else "")
    ; detail = Some (sprintf "oldest pending: %s ago\nby recipient:\n%s"
                       (age_str now oldest) per_recip)
    ; fix_command
    ; docs_url = Some docs_relay }

(* Scheme/attempt-aware capabilities matrix (Relay_doctor.capabilities_check):
   subscribe reflects the actual `c2c relay subscribe` outcome for the
   configured scheme (no over TLS), and connect reflects the broker-owned
   connector signal — never a machine-global false positive. *)
let check_capabilities ~probe ~connector_running =
  of_rd
    (Relay_doctor.capabilities_check ~url:probe.url
       ~reachable:(probe.health <> None) ~connector_running)

(* B268: client binary vs changelog cache — informational (PASS even when
   behind; never fails doctor --relay). Offline/empty cache → PASS silent. *)
let check_client_update ~broker_root =
  match
    (try C2c_changelog.latest_known_newer ~broker_root () with _ -> None)
  with
  | None ->
      { check_id = "client.update"
      ; status = Pass
      ; message = sprintf "client version %s (no newer release in local changelog cache)"
          Version.version
      ; detail = None; fix_command = None; docs_url = None }
  | Some latest ->
      { check_id = "client.update"
      ; status = Pass
      ; message = sprintf "newer release %s available (you're on %s)"
          latest Version.version
      ; detail = Some "Surfaced from the local changelog cache (no network probe)."
      ; fix_command = Some "c2c self-update"
      ; docs_url = None }

(* B268: relay /health version vs latest known in changelog cache.
   Informational only — a client cannot upgrade a remote relay. Fail closed
   (PASS + skip) when relay unreachable or version missing. *)
let check_relay_version ~probe ~broker_root =
  match probe.health with
  | None ->
      { check_id = "relay.version"
      ; status = Inconclusive
      ; message = "relay version check skipped (relay unreachable)"
      ; detail = None; fix_command = None; docs_url = Some docs_relay }
  | Some j ->
      let open Yojson.Safe.Util in
      let reported =
        match j |> member "version" |> to_string_option with
        | Some v when String.trim v <> "" && v <> "?" -> Some v
        | _ ->
            (match j |> member "server_version" |> to_string_option with
             | Some v when String.trim v <> "" && v <> "?" -> Some v
             | _ -> None)
      in
      (match
         try
           C2c_changelog.component_behind_latest ~reported ~broker_root ()
         with _ -> None
       with
       | None ->
           let ver = Option.value reported ~default:"?" in
           { check_id = "relay.version"
           ; status = Pass
           ; message = sprintf "relay version %s (not behind latest known release)" ver
           ; detail = None; fix_command = None; docs_url = Some docs_relay }
       | Some (ver, latest) ->
           { check_id = "relay.version"
           ; status = Pass
           ; message = sprintf
               "relay version %s is behind latest known %s (informational)"
               ver latest
           ; detail = Some
               "Client cannot upgrade a remote relay — flag for deploy/ops."
           ; fix_command = None
           ; docs_url = Some docs_relay })

(* ---------------------------------------------------------------------------
 * Run all checks
 * --------------------------------------------------------------------------- *)

let run_checks () =
  let broker_root = resolve_broker_root () in
  let (url, url_source) = resolve_url_with_source () in
  let token = C2c_relay_cmd.resolve_relay_token None in
  let identity = identity_opt () in
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  (* Only lease-check ALIVE local registrations: dead locals are obviously
     not relay-leased and would drown the signal in noise. *)
  let alive_regs =
    List.filter
      (fun (r : C2c_mcp.registration) ->
         C2c_mcp.Broker.registration_liveness_state r = C2c_mcp.Broker.Alive)
      (C2c_mcp.Broker.list_registrations broker)
  in
  let local_aliases = List.map (fun (r : C2c_mcp.registration) -> r.alias) alive_regs in
  let local_total = List.length (C2c_mcp.Broker.list_registrations broker) in
  (* Signing alias: env wins, else the first alive local registration. Only
     used when an identity is loaded; falls back to unsigned /list otherwise. *)
  let signing_alias =
    match C2c_cli_helpers.env_auto_alias () with
    | Some a -> Some a
    | None -> (match local_aliases with a :: _ -> Some a | [] -> None)
  in
  let probe =
    try probe_relay ~url ~token ~identity ~signing_alias
    with e ->
      { url; url_source
      ; health = None
      ; health_error = Some (Printexc.to_string e)
      ; peers = []; list_error = None; list_needs_auth = false }
  in
  let probe = { probe with url_source } in
  (* Scope machine-global pgrep matches to THIS broker root for diagnostics
     (wedged vs absent). Bridge liveness is fresh last_ok only (B181) — process
     presence alone never marks the connector live. Both the connector check
     and the capabilities matrix consume connector_running. *)
  let now = Unix.gettimeofday () in
  let all_connector_procs = detect_connector_processes () in
  (* B210: machine-wide duplicate-connector surfacing (not broker-scoped). *)
  let duplicate_check =
    Relay_doctor.duplicate_connector_check
      ~pids:(Relay_doctor.persistent_connector_pids all_connector_procs)
  in
  let scoped_procs =
    Relay_doctor.scope_connector_lines ~broker_root all_connector_procs
  in
  let state = C2c_relay_connector.read_connector_state broker_root in
  (* B181: treat a live PID recorded in connector-state as process evidence
     even when argv lacks --broker-root (canonical production launch). *)
  let scoped_procs =
    match state with
    | Some st when C2c_relay_connector.connector_pid_alive st ->
        let tag =
          match st.C2c_relay_connector.cs_pid with
          | Some p -> Printf.sprintf "%d connector-state.pid" p
          | None -> "connector-state.pid"
        in
        if List.exists (fun l -> l = tag) scoped_procs then scoped_procs
        else tag :: scoped_procs
    | _ -> scoped_procs
  in
  let connector_running =
    Relay_doctor.connector_running ~scoped_procs ~state ~now
  in
  let checks =
    [ check_configured ~probe
    ; check_reachable ~probe
    ; check_protocol ~probe
    ; check_auth_mode ~probe
    ; check_contact_protocol ~probe
    ; check_private_reachability ~probe
    ; check_transport_security ~probe
    ; check_lease ~probe ~local_aliases ~local_total
    ; check_connector ~relay_url:probe.url ~scoped_procs ~state ~now
    ; check_outbox ~broker_root
    ; check_capabilities ~probe ~connector_running
    ; check_client_update ~broker_root
    ; check_relay_version ~probe ~broker_root
    ]
    @ (match duplicate_check with Some c -> [ of_rd c ] | None -> [])
  in
  (broker_root, probe, checks)

(* ---------------------------------------------------------------------------
 * Rendering
 * --------------------------------------------------------------------------- *)

let any_fail checks = List.exists (fun c -> c.status = Fail) checks

let icon = function Pass -> "✓" | Fail -> "✗" | Inconclusive -> "?"

let iso_now () =
  let now = Unix.gettimeofday () in
  let t = Unix.gmtime now in
  sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec

let render_human ~broker_root ~probe checks =
  let line = String.make 64 '-' in
  printf "c2c doctor --relay   (B093)\n";
  printf "%s\n" line;
  printf "broker root:  %s\n" broker_root;
  printf "relay url:    %s  (%s)\n" probe.url probe.url_source;
  printf "checked at:   %s\n" (iso_now ());
  printf "%s\n\n" line;
  List.iter
    (fun c ->
       printf "%s [%-7s] %s\n" (icon c.status) (status_str c.status) c.message;
       printf "    check_id:    %s\n" c.check_id;
       (match c.detail with
        | Some d ->
            List.iter (fun l -> printf "    %s\n" l) (String.split_on_char '\n' d)
        | None -> ());
       (match c.fix_command with
        | Some cmd ->
            let ls = String.split_on_char '\n' cmd in
            List.iteri (fun i l ->
                if i = 0 then printf "    fix:         %s\n" l
                else printf "                 %s\n" l) ls
        | None -> ());
       (match c.docs_url with
        | Some u -> printf "    docs:        %s\n" u
        | None -> ());
       printf "\n")
    checks;
  let n_fail = List.length (List.filter (fun c -> c.status = Fail) checks) in
  let n_inc = List.length (List.filter (fun c -> c.status = Inconclusive) checks) in
  let n_pass = List.length (List.filter (fun c -> c.status = Pass) checks) in
  printf "%s\n" line;
  printf "summary: %d PASS, %d FAIL, %d INCONCLUSIVE\n" n_pass n_fail n_inc;
  if n_fail > 0 then
    printf "→ %d check(s) FAILING. Run the listed fix: commands above.\n" n_fail

let status_json = function
  | Pass -> `String "PASS" | Fail -> `String "FAIL" | Inconclusive -> `String "INCONCLUSIVE"

let render_json ~broker_root ~probe checks =
  let checks_json =
    `List
      (List.map
         (fun c ->
            `Assoc
              [ ("check_id", `String c.check_id)
              ; ("status", status_json c.status)
              ; ("message", `String c.message)
              ; ("detail", match c.detail with Some d -> `String d | None -> `Null)
              ; ("fix_command", match c.fix_command with Some s -> `String s | None -> `Null)
              ; ("docs_url", match c.docs_url with Some s -> `String s | None -> `Null)
              ])
         checks)
  in
  let n_fail = List.length (List.filter (fun c -> c.status = Fail) checks) in
  let n_inc = List.length (List.filter (fun c -> c.status = Inconclusive) checks) in
  let summary =
    `Assoc
      [ ("total", `Int (List.length checks))
      ; ("pass", `Int (List.length (List.filter (fun c -> c.status = Pass) checks)))
      ; ("fail", `Int n_fail)
      ; ("inconclusive", `Int n_inc)
      ; ("any_fail", `Bool (n_fail > 0))
      ]
  in
  let obj =
    `Assoc
      [ ("broker_root", `String broker_root)
      ; ("relay_url", `String probe.url)
      ; ("relay_url_source", `String probe.url_source)
      ; ("checked_at", `String (iso_now ()))
      ; ("checks", checks_json)
      ; ("summary", summary)
      ]
  in
  print_endline (Yojson.Safe.pretty_to_string obj)

(* Entry point used by c2c_doctor_cmd. Prints output and returns an exit code
   (0 unless any check FAILs). *)
let run ~json =
  let (broker_root, probe, checks) = run_checks () in
  if json then
    render_json ~broker_root ~probe checks
  else
    render_human ~broker_root ~probe checks;
  if any_fail checks then 1 else 0
