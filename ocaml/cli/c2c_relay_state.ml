(* c2c_relay_state - shared relay-state snapshot for `c2c status` and
   `c2c whoami` (B094).

   Both commands must work fully offline, so [snapshot] is pure-local: it
   reads the configured relay URL (reusing [C2c_relay_cmd.resolve_relay_url],
   which honors C2C_RELAY_URL / c2c relay setup), the local Ed25519 identity
   (fingerprint + b64url pubkey), the opaque host_id, and resolves the current
   session's alias. It never raises.

   The optional lease fetch ([fetch_alias_lease]) is a best-effort relay
   /list round-trip (signed, time-boxed). It is opt-in via the --relay flag on
   each command so the default path stays instant + offline. It never raises;
   on any failure it returns a structured [lease_result] the caller renders. *)

open C2c_cli_helpers

let b64url_nopad bytes =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet bytes

(* Case-insensitive equality (aliases are case-insensitive per
   C2c_mcp.Broker.alias_casefold). Used for both alias names and hex host ids. *)
let ci_equal a b =
  String.lowercase_ascii a = String.lowercase_ascii b

(** Local-only snapshot. [broker] is used only to resolve the current session
    alias; pass [None] to skip alias resolution. Never raises. *)
type snapshot = {
  relay_url : string option;
  identity_pk_b64 : string option;
  fingerprint : string option;
  host_id : string option;
  alias : string option;
}

let resolve_current_alias ?(broker : C2c_mcp.Broker.t option) () =
  match broker with
  | None -> env_auto_alias ()
  | Some b ->
      let regs = C2c_mcp.Broker.list_registrations b in
      let by_sid =
        match env_session_id () with
        | Some sid ->
            List.find_opt
              (fun (r : C2c_mcp.registration) -> r.session_id = sid)
              regs
        | None -> None
      in
      match by_sid with
      | Some r -> Some r.alias
      | None ->
          (* fall back to C2C_MCP_AUTO_REGISTER_ALIAS if the session isn't
             registered in this broker *)
          (match env_auto_alias () with
           | Some _ as v -> v
           | None ->
               (* last resort: a registration whose alias matches auto-alias *)
               None)

let snapshot ?(broker : C2c_mcp.Broker.t option) () : snapshot =
  let relay_url = C2c_relay_cmd.resolve_relay_url None in
  let identity_pk_b64, fingerprint =
    match Relay_identity.load () with
    | Ok id -> Some (b64url_nopad id.Relay_identity.public_key), Some id.Relay_identity.fingerprint
    | Error _ -> None, None
  in
  let host_id =
    try Some (Host_id.compute_host_hash_with_source ()).Host_id.host_id
    with _ -> None
  in
  let alias = resolve_current_alias ?broker () in
  { relay_url; identity_pk_b64; fingerprint; host_id; alias }

(** Best-effort lease lookup. Requires an alias, a relay URL, and a loadable
    identity. Honors a short timeout so the command never hangs. *)
type lease_result =
  | Lease of Yojson.Safe.t           (** the matching peer lease object *)
  | Relay_unreachable of string      (** network error or relay error response *)
  | Alias_not_found                  (** relay answered but our alias isn't listed *)
  | No_relay                         (** no relay URL configured *)
  | No_identity                      (** no local identity.json / bad perms *)
  | No_alias                         (** no current alias to look up *)

(* Find the lease for [alias] in the /list response, preferring one whose
   opaque_host_id matches [~our_host_id]. *)
let find_lease_for_alias ~alias ~our_host_id (resp : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let peers =
    match resp |> member "peers" with
    | `List l -> l
    | _ -> []
  in
  let matches =
    List.filter_map
      (fun p ->
         match p with
         | `Assoc _ ->
             (match p |> member "alias" |> to_string_option with
              | Some a when ci_equal a alias -> Some p
              | _ -> None)
         | _ -> None)
      peers
  in
  match matches with
  | [] -> None
  | [p] -> Some p
  | ps ->
      (* multiple aliases with the same name across hosts: prefer ours *)
      (match our_host_id with
       | None -> Some (List.hd ps)
       | Some hid ->
           (match
              List.find_opt
                (fun p ->
                   match p |> member "opaque_host_id" |> to_string_option with
                   | Some h -> ci_equal h hid
                   | None -> false)
                ps
            with
            | Some p -> Some p
            | None -> Some (List.hd ps)))

let fetch_alias_lease ?(timeout = 4.0) ~alias ~relay_url ~our_host_id ()
  : lease_result =
  match relay_url with
  | None -> No_relay
  | Some url ->
      (match alias with
       | None -> No_alias
       | Some a ->
           (match Relay_identity.load () with
            | Error _ -> No_identity
            | Ok id ->
                let client = Relay.Relay_client.make ~timeout url in
                let auth =
                  Relay_signed_ops.sign_request id
                    ~alias:a ~meth:"GET" ~path:"/list" ~body_str:"" ()
                in
                let resp =
                  Lwt_main.run
                    (Relay.Relay_client.list_peers_signed client
                       ~auth_header:auth ())
                in
                let open Yojson.Safe.Util in
                let ok =
                  match resp |> member "ok" with
                  | `Bool b -> b
                  | _ -> false
                in
                if not ok then begin
                  let detail =
                    match resp |> member "error" with
                    | `String s -> s
                    | _ -> Yojson.Safe.to_string resp
                  in
                  (* B184: surface actionable stderr hints for auth/verify
                     failures so whoami --relay is not opaque after
                     rename/register. *)
                  let alias_source = Relay_client_hints.Explicit a in
                  (match Relay_client_hints.hint_for_response ~alias_source resp with
                   | Some hint -> Printf.eprintf "%s%!" hint
                   | None -> ());
                  Relay_unreachable detail
                end
                else
                  match find_lease_for_alias ~alias:a ~our_host_id resp with
                  | Some lease -> Lease lease
                  | None -> Alias_not_found))

(* --- rendering helpers ----------------------------------------------------- *)

let relay_configured (s : snapshot) = s.relay_url <> None

(* --- composite state (H5) ---------------------------------------------------

   The pure classification lives in Relay_state (ocaml/relay_state.ml) so all
   five acceptance states are hermetically testable; this section only maps
   this module's I/O-shaped types ([snapshot], [lease_result]) onto the
   classifier's inputs and reads the broker-owned connector-state file (the
   same signal `c2c doctor --relay` consumes via Relay_doctor). *)

let registration_evidence (lease : lease_result option) :
    Relay_state.registration_evidence =
  match lease with
  | Some (Lease l) -> Relay_state.registration_of_lease_json l
  | Some Alias_not_found -> Relay_state.Reg_absent
  | Some (Relay_unreachable detail) -> Relay_state.Reg_query_failed detail
  (* No_relay / No_identity / No_alias carry no relay-side evidence; the
     classifier derives those cases from relay_configured/has_identity/
     has_alias directly. *)
  | Some No_relay | Some No_identity | Some No_alias | None ->
      Relay_state.Reg_not_checked

(* Best-effort connector process presence (B181). Prefer the broker-owned
   PID recorded in connector-state.json (works for the canonical
   `c2c relay connect` argv that carries no --broker-root). Fall back to
   broker-scoped pgrep for first-sync / pre-pid state files. Never raises. *)
let connector_process_present ~broker_root ~conn_state =
  let from_state =
    match conn_state with
    | Some st -> C2c_relay_connector.connector_pid_alive st
    | None -> false
  in
  if from_state then true
  else if broker_root = "" || broker_root = "<unresolved>" then false
  else
    try
      let patterns = [ "c2c relay connect"; "c2c_relay_connector" ] in
      let lines =
        List.concat_map
          (fun pat ->
             let cmd =
               Printf.sprintf "pgrep -af %s 2>/dev/null" (Filename.quote pat)
             in
             let ic = Unix.open_process_in cmd in
             Fun.protect
               ~finally:(fun () -> ignore (Unix.close_process_in ic))
               (fun () ->
                  let acc = ref [] in
                  (try
                     while true do
                       acc := input_line ic :: !acc
                     done
                   with End_of_file -> ());
                  List.rev !acc))
          patterns
      in
      Relay_doctor.scope_connector_lines ~broker_root lines <> []
    with _ -> false

(* Composite state + connector info for a snapshot. Reads the broker-owned
   connector-state file (never raises; missing file = no evidence). Also
   notes process presence for wedged vs down (B181). *)
let composite (s : snapshot) (lease : lease_result option) ~now :
    Relay_state.classification * Relay_state.connector_info =
  let broker_root =
    try resolve_broker_root () with _ -> "<unresolved>"
  in
  let conn_state =
    try C2c_relay_connector.read_connector_state broker_root with _ -> None
  in
  let process_present =
    connector_process_present ~broker_root ~conn_state
  in
  let conn =
    Relay_state.connector_info ~process_present ~state:conn_state ~now ()
  in
  let classification =
    Relay_state.classify
      ~relay_configured:(relay_configured s)
      ~has_identity:(s.identity_pk_b64 <> None)
      ~has_alias:(s.alias <> None)
      ~registration:(registration_evidence lease)
      ~connector_live:conn.Relay_state.conn_live
      ~local_reg_evidence:conn.Relay_state.conn_state_present
  in
  (classification, conn)

(* JSON for the lease_result (the "lease" sub-object of the relay block). *)
let lease_result_json = function
  | Lease l -> l
  | Relay_unreachable detail ->
      `Assoc [ ("state", `String "unreachable"); ("detail", `String detail) ]
  | Alias_not_found ->
      `Assoc [ ("state", `String "not_found") ]
  | No_relay -> `Assoc [ ("state", `String "no_relay") ]
  | No_identity -> `Assoc [ ("state", `String "no_identity") ]
  | No_alias -> `Assoc [ ("state", `String "no_alias") ]

(* JSON "relay" object combining snapshot + optional lease_result.

   H5 + B181 additions (additive): "registration" ({state, reason}) and
   "connector" ({live, state_file, last_sync_age_s, last_ok_age_s,
   process_present, health, remediation}). Same facts as the human
   "state:" / "connector:" lines in [print_relay_section]. *)
let relay_json ?now (s : snapshot) (lease : lease_result option) : Yojson.Safe.t =
  let now = match now with Some n -> n | None -> Unix.gettimeofday () in
  let classification, conn = composite s lease ~now in
  let opt_str = function None -> `Null | Some v -> `String v in
  let lease_j =
    match lease with
    | None -> `Null
    | Some r -> lease_result_json r
  in
  `Assoc
    [ ("url", opt_str s.relay_url)
    ; ("configured", `Bool (relay_configured s))
    ; ("alias", opt_str s.alias)
    ; ("host_id", opt_str s.host_id)
    ; ("identity_pk", opt_str s.identity_pk_b64)
    ; ("fingerprint", opt_str s.fingerprint)
    ; ("lease", lease_j)
    ; ("registration", Relay_state.classification_json classification)
    ; ("connector", Relay_state.connector_json conn)
    ]

(* Human-readable one-line lease summary for the [Lease _] case, given the
   current time [now] (Unix epoch). Returns the summary text. *)
let lease_summary ~now (lease : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let alive = match lease |> member "alive" with `Bool b -> b | _ -> false in
  let reserved =
    match lease |> member "alias_reserved" with `Bool b -> b | _ -> false
  in
  let ttl = match lease |> member "ttl" with `Float f -> f | `Int i -> float_of_int i | _ -> 0.0 in
  let release_at =
    match lease |> member "alias_release_at" with
    | `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None
  in
  let state_str =
    if alive then "alive" else if reserved then "reserved (offline)" else "expired"
  in
  let ttl_str = Printf.sprintf "ttl=%.0fs" ttl in
  let expiry_str =
    match release_at with
    | None -> ""
    | Some t ->
        let delta = t -. now in
        if delta <= 0.0 then ", released"
        else if delta < 3600.0 then Printf.sprintf ", releases in %.0fm" (delta /. 60.0)
        else if delta < 86400.0 then Printf.sprintf ", releases in %.0fh" (delta /. 3600.0)
        else Printf.sprintf ", releases in %.0fd" (delta /. 86400.0)
  in
  Printf.sprintf "%s, %s%s" state_str ttl_str expiry_str

(* Human-readable "Relay:" section for status/whoami. Prints the relay URL
   (or a not-configured note), current alias, host_id, fingerprint, the lease
   line (when [lease] is Some), and a one-line @hostid addressing hint.
   Never errors. *)
let print_relay_section (s : snapshot) (lease : lease_result option) ~now () =
  let classification, conn = composite s lease ~now in
  Printf.printf "Relay:\n";
  (match s.relay_url with
   | Some url -> Printf.printf "  url:        %s  (configured)\n" url
   | None ->
       Printf.printf "  url:        (not configured — run 'c2c relay setup --url <URL>')\n");
  (* H5: the local broker alias is session identity, NOT relay registration —
     the old label here was "registered:", which conflated the two (A020/A027).
     Registration and connector state get their own lines below. *)
  (match s.alias with
   | Some a -> Printf.printf "  alias:      %s  (local session alias — not a relay registration)\n" a
   | None -> Printf.printf "  alias:      (no current session alias)\n");
  Printf.printf "  state:      %s\n"
    (Relay_state.classification_human classification);
  Printf.printf "  connector:  %s\n" (Relay_state.connector_human conn);
  (match s.host_id with
   | Some h -> Printf.printf "  host_id:    %s  (opaque; address peers as <alias>@<host_id>)\n" h
   | None -> ());
  (match s.fingerprint with
   | Some f -> Printf.printf "  identity:   %s  (Ed25519 fingerprint)\n" f
   | None -> Printf.printf "  identity:   (no local identity — run 'c2c init')\n");
  (match lease with
   | None ->
       Printf.printf "  lease:      (not checked — pass --relay to query live TTL/expiry)\n"
   | Some r ->
       (match r with
        | Lease l ->
            Printf.printf "  lease:      %s\n" (lease_summary ~now l)
        | Relay_unreachable detail ->
            Printf.printf "  lease:      (relay unreachable: %s)\n" detail
        | Alias_not_found ->
            Printf.printf "  lease:      (not registered on the relay as this alias — run 'c2c relay register --alias <ALIAS>')\n"
        | No_relay ->
            Printf.printf "  lease:      (no relay configured)\n"
        | No_identity ->
            Printf.printf "  lease:      (no local identity — run 'c2c init')\n"
        | No_alias ->
            Printf.printf "  lease:      (no current alias to look up)\n"));
  Printf.printf "  Addressing: bare <alias> = local (same machine); \
<alias>@<host_id> = cross-host via relay.\n";
  Printf.printf "              Use 'c2c relay list' for peer host_ids; \
'c2c host-id' prints your own.\n"
