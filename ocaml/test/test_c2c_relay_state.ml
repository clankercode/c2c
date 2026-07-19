(* test_c2c_relay_state — hermetic tests for Relay_state, the pure composite
   relay-state classifier behind `c2c status` / `c2c whoami` (H5).

   H5 separates the three facts those surfaces used to conflate under one
   "registered:" label (inventory A020/A027; B094 gap): the LOCAL broker
   alias, RELAY REGISTRATION (incl. expiry), and CONNECTOR liveness.

   Coverage (all pure — no live relay, no network):
   - the five acceptance states: Unconfigured, Configured_not_registered,
     Registered_live, Registered_expired, Registered_unreachable — plus the
     honest-unknown Configured_unverified;
   - registration_of_lease_json against the real RegistrationLease.to_json
     shape (alive + expired leases), and malformed-input totality;
   - connector_info single-sources Relay_doctor.connector_running (fresh /
     stale / absent state files) so status can never contradict the doctor;
   - human/JSON parity: the exact state string in classification_json is
     embedded verbatim in classification_human, connector_json.live agrees
     with connector_human's leading word;
   - end-to-end: `c2c whoami --json` vs human output in an isolated env
     (unconfigured relay) carry the same composite state;
   - B234: alias_line_note claims "not a relay registration" only for
     Configured_not_registered — never when lease/local evidence exists. *)

open Alcotest
open Relay_state

(* --- helpers --------------------------------------------------------------- *)

let state_testable =
  testable
    (fun fmt s -> Format.pp_print_string fmt (state_to_string s))
    ( = )

let check_state msg expected (c : classification) =
  check state_testable msg expected c.state

let string_contains ~needle haystack =
  Relay_doctor.string_contains ~needle haystack

(* Baseline inputs: relay configured, identity + alias present, no relay
   query performed, no connector, no local evidence. Each test overrides the
   axis it exercises. *)
let classify_with ?(relay_configured = true) ?(has_identity = true)
    ?(has_alias = true) ?(registration = Reg_not_checked)
    ?(connector_live = false) ?(local_reg_evidence = false) () =
  classify ~relay_configured ~has_identity ~has_alias ~registration
    ~connector_live ~local_reg_evidence

let conn_state ?(last_sync = 0.0) ?(last_ok = 0.0) ?last_error_op
    ?last_error_detail () : C2c_relay_connector.connector_state =
  {
    C2c_relay_connector.cs_last_sync_ts = last_sync;
    cs_last_ok_ts = last_ok;
    cs_last_error_op = last_error_op;
    cs_last_error_detail = last_error_detail;
    cs_last_error_ts = None;
    (* H3 added cs_node_id to connector_state; this H5 fixture predates it.
       None = no node-id recorded, the pre-H3 behaviour. *)
    cs_node_id = None;
    cs_sessions = [];
    cs_pid = None;
    cs_registered = [];
    cs_outbox_forwarded = 0;
    cs_outbox_failed = 0;
    cs_outbox_dlqed = 0;
    cs_inbound_delivered = 0;
    cs_inbound_rejected = 0;
  }

(* --- acceptance state: Unconfigured ---------------------------------------- *)

let test_unconfigured () =
  check_state "no relay URL -> unconfigured" Unconfigured
    (classify_with ~relay_configured:false ());
  (* Unconfigured dominates every other signal. *)
  check_state "unconfigured even with alive lease + connector" Unconfigured
    (classify_with ~relay_configured:false
       ~registration:(Reg_lease { alive = true; reserved = true })
       ~connector_live:true ~local_reg_evidence:true ())

(* --- acceptance state: Configured_not_registered ---------------------------- *)

let test_not_registered_relay_says_absent () =
  check_state "relay answered, alias absent -> configured_not_registered"
    Configured_not_registered
    (classify_with ~registration:Reg_absent ())

let test_not_registered_no_identity () =
  let c = classify_with ~has_identity:false () in
  check_state "no local identity -> configured_not_registered"
    Configured_not_registered c;
  check bool "reason points at c2c init" true
    (string_contains ~needle:"c2c init" c.reason)

let test_not_registered_no_alias () =
  check_state "no session alias -> configured_not_registered"
    Configured_not_registered
    (classify_with ~has_alias:false ())

(* --- acceptance state: Registered_live -------------------------------------- *)

let test_live_alive_lease_and_connector () =
  check_state "alive lease + live connector -> registered_live" Registered_live
    (classify_with ~registration:(Reg_lease { alive = true; reserved = true })
       ~connector_live:true ())

let test_live_from_broker_owned_connector_signal () =
  (* Offline default (no --relay query): a fresh broker-owned connector sync
     is itself live-registration evidence. *)
  check_state "not-checked + live connector -> registered_live" Registered_live
    (classify_with ~registration:Reg_not_checked ~connector_live:true
       ~local_reg_evidence:true ())

(* --- acceptance state: Registered_expired ----------------------------------- *)

let test_expired_lease () =
  let reserved =
    classify_with ~registration:(Reg_lease { alive = false; reserved = true })
      ~connector_live:true ()
  in
  check_state "expired lease (reserved) -> registered_expired"
    Registered_expired reserved;
  check bool "reserved reason mentions re-register" true
    (string_contains ~needle:"re-register" reserved.reason);
  let released =
    classify_with ~registration:(Reg_lease { alive = false; reserved = false }) ()
  in
  check_state "expired lease (released) -> registered_expired"
    Registered_expired released;
  check bool "released reason mentions released" true
    (string_contains ~needle:"released" released.reason)

(* --- acceptance state: Registered_unreachable ------------------------------- *)

let test_unreachable_alive_lease_connector_down () =
  let c =
    classify_with ~registration:(Reg_lease { alive = true; reserved = true })
      ~connector_live:false ()
  in
  check_state "alive lease + connector down -> registered_unreachable"
    Registered_unreachable c;
  check bool "reason names the connector" true
    (string_contains ~needle:"connector" c.reason)

let test_unreachable_relay_query_failed_with_local_evidence () =
  let c =
    classify_with ~registration:(Reg_query_failed "connection refused")
      ~local_reg_evidence:true ()
  in
  check_state "query failed + local evidence -> registered_unreachable"
    Registered_unreachable c;
  check bool "reason carries the failure detail" true
    (string_contains ~needle:"connection refused" c.reason)

let test_unreachable_stale_local_evidence () =
  check_state
    "not-checked + stale connector state -> registered_unreachable"
    Registered_unreachable
    (classify_with ~registration:Reg_not_checked ~connector_live:false
       ~local_reg_evidence:true ())

(* --- honest-unknown: Configured_unverified ----------------------------------- *)

let test_unverified_not_checked_no_evidence () =
  let c = classify_with () in
  check_state "not-checked, no evidence -> configured_unverified"
    Configured_unverified c;
  check bool "reason suggests --relay" true
    (string_contains ~needle:"--relay" c.reason)

let test_unverified_query_failed_no_evidence () =
  check_state "query failed, no evidence -> configured_unverified"
    Configured_unverified
    (classify_with ~registration:(Reg_query_failed "timeout") ())

(* --- registration_of_lease_json against the real relay lease shape ---------- *)

let test_lease_json_alive_roundtrip () =
  let lease =
    Relay_registration_lease.RegistrationLease.make ~node_id:"n1"
      ~session_id:"s1" ~alias:"qqzzy-vexil" ()
  in
  let j = Relay_registration_lease.RegistrationLease.to_json lease in
  match registration_of_lease_json j with
  | Reg_lease { alive; _ } ->
      check bool "fresh RegistrationLease.to_json reads alive" true alive
  | _ -> fail "expected Reg_lease from lease JSON"

let test_lease_json_expired_roundtrip () =
  (* last_seen far in the past: lease dead AND alias released. *)
  let lease =
    Relay_registration_lease.RegistrationLease.make ~node_id:"n1"
      ~session_id:"s1" ~alias:"qqzzy-vexil"
      ~last_seen:(Unix.gettimeofday () -. (400.0 *. 86400.0))
      ()
  in
  let j = Relay_registration_lease.RegistrationLease.to_json lease in
  (match registration_of_lease_json j with
   | Reg_lease { alive; reserved } ->
       check bool "ancient lease reads not alive" false alive;
       check bool "ancient lease reads released" false reserved
   | _ -> fail "expected Reg_lease from lease JSON");
  check_state "ancient lease classifies registered_expired" Registered_expired
    (classify_with ~registration:(registration_of_lease_json j) ())

let test_lease_json_malformed_total () =
  (match registration_of_lease_json `Null with
   | Reg_lease { alive = false; reserved = false } -> ()
   | _ -> fail "malformed lease JSON must read as dead lease");
  match registration_of_lease_json (`Assoc [ ("alive", `String "yes") ]) with
  | Reg_lease { alive = false; _ } -> ()
  | _ -> fail "non-bool alive must read as false"

(* --- connector_info: single-sourced from Relay_doctor ----------------------- *)

let now = 1_000_000.0

let test_connector_fresh_state_is_live () =
  let st = conn_state ~last_sync:(now -. 30.0) ~last_ok:(now -. 30.0) () in
  let info = connector_info ~state:(Some st) ~now () in
  check bool "fresh state -> live" true info.conn_live;
  check bool "state file present" true info.conn_state_present;
  check string "health ok" "ok" (health_to_string info.conn_health);
  check bool "no remediation when live" true (info.conn_remediation = None);
  (match info.conn_last_sync_age_s with
   | Some a -> check (float 0.001) "age = now - last_sync" 30.0 a
   | None -> fail "expected last-sync age");
  (match info.conn_last_ok_age_s with
   | Some a -> check (float 0.001) "ok age = now - last_ok" 30.0 a
   | None -> fail "expected last-ok age");
  (* Same verdict as the doctor's broker-owned signal. *)
  check bool "agrees with Relay_doctor.connector_running"
    (Relay_doctor.connector_running ~scoped_procs:[] ~state:(Some st) ~now)
    info.conn_live

let test_connector_stale_state_is_down () =
  let st = conn_state ~last_sync:(now -. 3600.0) ~last_ok:(now -. 3600.0) () in
  let info = connector_info ~state:(Some st) ~now () in
  check bool "stale state -> down" false info.conn_live;
  check bool "state file still present" true info.conn_state_present;
  check string "health stale" "stale" (health_to_string info.conn_health);
  check bool "remediation present" true (info.conn_remediation <> None);
  check bool "agrees with Relay_doctor.connector_running"
    (Relay_doctor.connector_running ~scoped_procs:[] ~state:(Some st) ~now)
    info.conn_live

let test_connector_wedged_process_present () =
  (* B181: process alive + stale last_sync = wedged, not live. *)
  let st = conn_state ~last_sync:(now -. 3600.0) ~last_ok:(now -. 3600.0) () in
  let info = connector_info ~process_present:true ~state:(Some st) ~now () in
  check bool "wedged is not live" false info.conn_live;
  check string "health wedged" "wedged" (health_to_string info.conn_health);
  check bool "process_present recorded" true info.conn_process_present;
  check bool "remediation mentions restart or connect" true
    (match info.conn_remediation with
     | Some r ->
         string_contains ~needle:"restart" r
         || string_contains ~needle:"relay connect" r
     | None -> false);
  let human = connector_human info in
  check bool "human says wedged" true (string_contains ~needle:"wedged" human);
  check bool "human notes process≠bridge" true
    (string_contains ~needle:"process≠bridge" human
    || string_contains ~needle:"process" human)

let test_connector_pid_alive_helper () =
  (* Self PID must look alive; impossible PID must not. *)
  let base = conn_state ~last_sync:now ~last_ok:now () in
  let self =
    { base with C2c_relay_connector.cs_pid = Some (Unix.getpid ()) }
  in
  let gone = { base with C2c_relay_connector.cs_pid = Some 999_999_999 } in
  let none = { base with C2c_relay_connector.cs_pid = None } in
  check bool "self pid alive" true (C2c_relay_connector.connector_pid_alive self);
  check bool "bogus pid not alive" false
    (C2c_relay_connector.connector_pid_alive gone);
  check bool "missing pid not alive" false
    (C2c_relay_connector.connector_pid_alive none)

let test_connector_absent_state () =
  let info = connector_info ~state:None ~now () in
  check bool "no state file -> down" false info.conn_live;
  check bool "no state file recorded" false info.conn_state_present;
  check bool "no age" true (info.conn_last_sync_age_s = None);
  check string "health absent" "absent" (health_to_string info.conn_health)

let json_string j key =
  match j with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> failwith (Printf.sprintf "missing string key %S" key))
  | _ -> failwith "expected Assoc"

(* --- #11(2): erroring must report the real error, not a guess -------------- *)

(* An erroring connector means the machine-wide connector service synced THIS
   repo's broker root within the freshness window and that sync failed —
   connector-state.json is per-root, so the failure is in scope here. The
   state file already carries the failing op and its detail; the old
   remediation ignored both and appended a guessed checklist ("check token
   …, identity …, relay reachability") instead. Surface the fact we have. *)

let erroring_info ?last_error_op ?last_error_detail () =
  connector_info ~process_present:true
    ~state:
      (Some
         (conn_state ~last_sync:(now -. 10.0) ~last_ok:(now -. 9999.0)
            ?last_error_op ?last_error_detail ()))
    ~now ()

let test_connector_erroring_surfaces_real_error () =
  let info =
    erroring_info ~last_error_op:"poll"
      ~last_error_detail:"relay 401 unauthorized: signer not accepted" ()
  in
  check string "health erroring" "erroring" (health_to_string info.conn_health);
  let human = connector_line info in
  (* The operator must see the actual failure, not a checklist. *)
  check bool "human surfaces the real error detail" true
    (string_contains ~needle:"relay 401 unauthorized: signer not accepted"
       human);
  check bool "human names the failing op" true
    (string_contains ~needle:"poll" human);
  (* The what-to-check tail is kept ALONGSIDE the real error, not traded for
     it. write_connector_state sets ok = (last_error = None) and only advances
     last_ok_ts when ok, so Health_erroring implies last_error was Some —
     dropping the checklist "only when an error is known" would delete it in
     every production case while looking like it was preserved. It is a `#`
     shell comment on a runnable command, so it costs nothing. *)
  check bool "what-to-check tail is retained alongside the real error" true
    (string_contains ~needle:"check token" human);
  (* …and the copy-pasteable recovery command survives (docs/commands.md
     contract: remediation is a runnable command when not live). *)
  check bool "remediation still a runnable restart command" true
    (match info.conn_remediation with
     | Some r -> string_contains ~needle:"c2c restart relay-connect" r
     | None -> false);
  check bool "human still carries the restart command" true
    (string_contains ~needle:"c2c restart relay-connect" human);
  (* JSON parity: the same fact, machine-readable. *)
  let j = connector_json info in
  check string "json last_error_detail" "relay 401 unauthorized: signer not accepted"
    (json_string j "last_error_detail");
  check string "json last_error_op" "poll" (json_string j "last_error_op")

let test_connector_erroring_without_detail_keeps_guidance () =
  (* Legacy / hand-written state files can record no detail. The checklist is
     unconditional, so this path is guidance-identical to the one above; pin
     it so the two cannot silently diverge again. *)
  let info = erroring_info () in
  check string "health erroring" "erroring" (health_to_string info.conn_health);
  check bool "falls back to the checklist when no error is recorded" true
    (match info.conn_remediation with
     | Some r ->
         string_contains ~needle:"c2c restart relay-connect" r
         && string_contains ~needle:"check token" r
     | None -> false);
  let j = connector_json info in
  check bool "json last_error_detail is null" true
    (match j with
     | `Assoc fields -> List.assoc_opt "last_error_detail" fields = Some `Null
     | _ -> false)

let test_connector_wedged_remediation_untouched () =
  (* Wedged is a property of the connector PROCESS — machine-wide and
     independent of any repo's relay config — and is the one class where
     "restart the connector" is unambiguously right. Pin it: no error tail,
     no checklist, just the restart command. *)
  let info =
    connector_info ~process_present:true
      ~state:
        (Some
           (conn_state ~last_sync:(now -. 3600.0) ~last_ok:(now -. 3600.0)
              ~last_error_op:"push"
              ~last_error_detail:"connection refused" ()))
      ~now ()
  in
  check string "health wedged" "wedged" (health_to_string info.conn_health);
  check (option string) "wedged remediation is the bare restart command"
    (Some
       "c2c restart relay-connect 2>/dev/null || (pkill -f 'c2c relay \
        connect' 2>/dev/null; c2c relay connect &)")
    info.conn_remediation

(* --- #11(2): the two lines must not read as one contradiction ------------- *)

let test_relay_lines_scopes_disambiguated () =
  (* The reported symptom: "connector: erroring" printed beside
     "state: unconfigured — no relay URL configured" reads as
     self-contradictory. Both are true; they answer different questions.
     The rendered lines must say which is which. *)
  let cls = { state = Unconfigured; reason = "no relay URL configured" } in
  (* The DEFAULT host: no env var set, so the relay config is machine-wide. *)
  let sline =
    state_line ~config:(Relay_config_machine "/home/u/.config/c2c/relay.json")
      cls
  in
  let cinfo =
    erroring_info ~last_error_op:"push" ~last_error_detail:"relay unreachable" ()
  in
  let cline = connector_line cinfo in
  (* Each line keeps everything it said before… *)
  check bool "state line keeps the classification body" true
    (string_contains ~needle:(classification_human cls) sline);
  check bool "connector line keeps the health body" true
    (string_contains ~needle:(connector_human cinfo) cline);
  (* …and gains a marker that distinguishes it from the other. The state line
     names its config FILE (which on this default host is machine-wide); the
     connector line names the machine service acting on this repo's root. *)
  check bool "state line names the relay config file it read" true
    (string_contains ~needle:"relay config: /home/u/.config/c2c/relay.json"
       sline);
  check bool "connector line is scoped to the machine service" true
    (string_contains ~needle:"machine connector service" cline);
  check bool "the two markers are not the same claim" false
    (string_contains ~needle:"machine connector service" sline);
  (* The withdrawn premise must stay absent: neither line claims the other's
     subject, and the state line makes no repo-scope claim it cannot back. *)
  check bool "state line makes no repo-scope claim on a default host" false
    (string_contains ~needle:"this repo" sline);
  check bool "connector line does not claim to describe the relay config" false
    (string_contains ~needle:"relay config:" cline)

(* --- #11(2): the recorded error must not crowd out the recovery command --- *)

let test_connector_error_detail_bounded () =
  (* err_detail sources include Yojson.Safe.to_string of a whole relay
     response — unbounded in principle. The connector's own log renderers clip
     this field; the human line must too, or a large detail pushes the
     copy-pasteable command far down a wrapped line. *)
  let detail = String.make 900 'x' in
  let info =
    erroring_info ~last_error_op:"poll" ~last_error_detail:detail ()
  in
  let human = connector_line info in
  check bool "human line does not carry the full 900-char detail" false
    (string_contains ~needle:detail human);
  check bool "detail is elided" true (string_contains ~needle:"xxx..." human);
  check bool "human line stays bounded" true (String.length human < 500);
  (* The command must survive AND come last, so a long detail cannot displace
     it: the error sits inside the parenthesised evidence group. *)
  check bool "recovery command still present" true
    (string_contains ~needle:"c2c restart relay-connect" human);
  let idx needle =
    let n = String.length needle and h = String.length human in
    let rec go i = if i + n > h then -1
      else if String.sub human i n = needle then i else go (i + 1) in
    go 0
  in
  check bool "the recovery command follows the error, not the reverse" true
    (idx "last error:" >= 0 && idx "c2c restart relay-connect" > idx "last error:");
  (* A separator, so the previous bit and the error do not run together. *)
  check bool "error bit is separated" true
    (string_contains ~needle:"; last error:" human);
  (* --json keeps the whole thing: truncation is a rendering concern only. *)
  check string "json keeps the full detail" detail
    (json_string (connector_json info) "last_error_detail")

(* --- #11(2): scope/provenance labels ------------------------------------- *)

let test_state_line_names_the_relay_config_file () =
  (* The blocking defect this replaces: the line asserted "[scope: this repo's
     relay config]" while relay_configured, in the DEFAULT case (neither
     C2C_RELAY_CONFIG nor C2C_MCP_BROKER_ROOT set — every plain shell, since
     broker-root resolution is fingerprint-derived), reads the machine-wide
     $HOME/.config/c2c/relay.json. `c2c relay setup` then writes that same
     machine-wide file, contradicting the label. Naming the file is true in
     every branch. *)
  let cls = { state = Unconfigured; reason = "no relay URL configured" } in
  let machine =
    state_line ~config:(Relay_config_machine "/home/u/.config/c2c/relay.json") cls
  in
  check bool "machine-wide default is not claimed as repo scope" false
    (string_contains ~needle:"this repo" machine);
  check bool "machine-wide default says machine-wide" true
    (string_contains ~needle:"machine-wide" machine);
  check bool "the file is named" true
    (string_contains ~needle:"/home/u/.config/c2c/relay.json" machine);
  let repo =
    state_line ~config:(Relay_config_repo "/b/root/relay.json") cls
  in
  check bool "broker-root config IS this repo's" true
    (string_contains ~needle:"this repo's broker root" repo);
  check bool "repo case names its file" true
    (string_contains ~needle:"/b/root/relay.json" repo);
  let explicit =
    state_line ~config:(Relay_config_explicit "/etc/c2c.json") cls
  in
  check bool "explicit override names the env var, claims no scope" true
    (string_contains ~needle:"C2C_RELAY_CONFIG" explicit);
  check bool "explicit override makes no repo claim" false
    (string_contains ~needle:"this repo" explicit);
  (* Every variant still carries the classification verbatim. *)
  List.iter
    (fun l ->
       check bool "state line keeps the classification body" true
         (string_contains ~needle:(classification_human cls) l))
    [ machine; repo; explicit ]

let test_scope_tokens_pinned () =
  (* These are sold as stable --json tokens; pin the literal values and the
     mapping from location to token, in both the accessor and the rendered
     JSON. *)
  check (list string) "relay-config scope token contract"
    [ "relay_config_machine"; "relay_config_repo"; "relay_config_explicit" ]
    [ scope_relay_config_machine; scope_relay_config_repo;
      scope_relay_config_explicit ];
  check string "connector scope token contract" "machine_connector_service"
    scope_connector_machine_service;
  let cls = { state = Unconfigured; reason = "no relay URL configured" } in
  List.iter
    (fun (loc, tok, path) ->
       check string "accessor token" tok (relay_config_scope_token loc);
       check string "accessor path" path (relay_config_path_of loc);
       let j = classification_json ~config:loc cls in
       check string "registration.scope" tok (json_string j "scope");
       check string "registration.config_path" path (json_string j "config_path"))
    [ (Relay_config_machine "/home/u/.config/c2c/relay.json",
       "relay_config_machine", "/home/u/.config/c2c/relay.json");
      (Relay_config_repo "/b/root/relay.json", "relay_config_repo",
       "/b/root/relay.json");
      (Relay_config_explicit "/etc/c2c.json", "relay_config_explicit",
       "/etc/c2c.json") ];
  (* The connector line's token is unchanged and is asserted here for the
     first time — it was the other untested half of the contract. *)
  check string "connector.scope"  "machine_connector_service"
    (json_string
       (connector_json (erroring_info ~last_error_op:"push"
                          ~last_error_detail:"boom" ()))
       "scope")

(* --- human/JSON parity ------------------------------------------------------- *)

let all_states =
  [ Unconfigured; Configured_not_registered; Configured_unverified;
    Registered_live; Registered_expired; Registered_unreachable ]

let test_state_strings_distinct_and_stable () =
  let strings = List.map state_to_string all_states in
  check int "six distinct state strings" 6
    (List.length (List.sort_uniq compare strings));
  (* Pin the exact machine strings — these are the --json contract. *)
  check (list string) "state string contract"
    [ "unconfigured"; "configured_not_registered"; "configured_unverified";
      "registered_live"; "registered_expired"; "registered_unreachable" ]
    strings

let test_classification_human_json_parity () =
  let config = Relay_config_machine "/home/u/.config/c2c/relay.json" in
  List.iter
    (fun state ->
       let c = { state; reason = "some reason" } in
       let json_state = json_string (classification_json ~config c) "state" in
       let human = classification_human c in
       check bool
         (Printf.sprintf "human line embeds JSON state %S" json_state)
         true
         (string_contains ~needle:json_state human);
       check string "JSON reason matches record"
         c.reason (json_string (classification_json ~config c) "reason");
       check bool "human line embeds reason" true
         (string_contains ~needle:c.reason human);
       (* The rendered line and the JSON must agree on the config file too. *)
       check bool "state line embeds the JSON config_path" true
         (string_contains
            ~needle:(json_string (classification_json ~config c) "config_path")
            (state_line ~config c)))
    all_states

let test_connector_human_json_parity () =
  let cases =
    [ connector_info
        ~state:(Some (conn_state ~last_sync:(now -. 5.0) ~last_ok:(now -. 5.0) ()))
        ~now ();
      connector_info
        ~state:
          (Some (conn_state ~last_sync:(now -. 9999.0) ~last_ok:(now -. 9999.0) ()))
        ~now ();
      connector_info
        ~process_present:true
        ~state:
          (Some (conn_state ~last_sync:(now -. 9999.0) ~last_ok:(now -. 9999.0) ()))
        ~now ();
      connector_info ~state:None ~now ();
      (* #11: erroring, with and without a recorded error. *)
      erroring_info ~last_error_op:"poll" ~last_error_detail:"boom" ();
      erroring_info () ]
  in
  List.iter
    (fun info ->
       let j = connector_json info in
       let live_json =
         match j with
         | `Assoc fields ->
             (match List.assoc_opt "live" fields with
              | Some (`Bool b) -> b
              | _ -> failwith "connector_json missing live")
         | _ -> failwith "expected Assoc"
       in
       let health_json =
         match j with
         | `Assoc fields ->
             (match List.assoc_opt "health" fields with
              | Some (`String s) -> s
              | _ -> failwith "connector_json missing health")
         | _ -> failwith "expected Assoc"
       in
       let human = connector_human info in
       check bool "json live flag matches record" info.conn_live live_json;
       check string "json health matches record"
         (health_to_string info.conn_health) health_json;
       (* Live bridge: human leads with "live (". Other classes must not. *)
       let human_says_live =
         String.length human >= 4 && String.sub human 0 4 = "live"
       in
       check bool "human leading word agrees with json live" live_json
         human_says_live;
       check bool "json has process_present" true
         (match j with
          | `Assoc fields -> List.mem_assoc "process_present" fields
          | _ -> false);
       check bool "json has remediation key" true
         (match j with
          | `Assoc fields -> List.mem_assoc "remediation" fields
          | _ -> false);
       (* #11: remediation and the recorded error must not diverge between
          the two surfaces. Whatever the human line offers as a command, the
          JSON must offer verbatim; whatever error the human reports, the
          JSON must carry. *)
       (match info.conn_remediation with
        | Some r ->
            check string "json remediation matches record" r
              (json_string j "remediation");
            check bool "human line carries the remediation" true
              (string_contains ~needle:r human)
        | None ->
            check bool "json remediation null when none" true
              (match j with
               | `Assoc fields -> List.assoc_opt "remediation" fields = Some `Null
               | _ -> false));
       (match info.conn_last_error_detail with
        | Some d ->
            check string "json last_error_detail matches record" d
              (json_string j "last_error_detail");
            check bool "human line reports the recorded error" true
              (string_contains ~needle:d human)
        | None ->
            check bool "json last_error_detail null when none" true
              (match j with
               | `Assoc fields ->
                   List.assoc_opt "last_error_detail" fields = Some `Null
               | _ -> false)))
    cases

(* --- B234: alias line parenthetical must match composite registration ------ *)

let test_alias_line_note_accurate () =
  let note_of ?registration ?connector_live ?local_reg_evidence
      ?(relay_configured = true) ?(has_identity = true) ?(has_alias = true) () =
    let c =
      classify_with ~relay_configured ~has_identity ~has_alias
        ?registration ?connector_live ?local_reg_evidence ()
    in
    alias_line_note c
  in
  let claims_unregistered note =
    string_contains ~needle:"not a relay registration" note
  in
  (* Positive registration evidence: never claim unregistered (the dogfood
     footgun — whoami --relay showed "not a relay registration" while lease
     was alive on the relay). *)
  check bool "registered_live: no unregistered claim" false
    (claims_unregistered
       (note_of
          ~registration:(Reg_lease { alive = true; reserved = true })
          ~connector_live:true ()));
  check bool "registered_live note is neutral local-session" true
    (string_contains ~needle:"local session alias"
       (note_of
          ~registration:(Reg_lease { alive = true; reserved = true })
          ~connector_live:true ()));
  check bool "registered_expired: no unregistered claim" false
    (claims_unregistered
       (note_of
          ~registration:(Reg_lease { alive = false; reserved = true }) ()));
  check bool "registered_unreachable (lease alive, bridge down): no claim"
    false
    (claims_unregistered
       (note_of
          ~registration:(Reg_lease { alive = true; reserved = true })
          ~connector_live:false ()));
  check bool "registered_unreachable (stale local evidence): no claim" false
    (claims_unregistered
       (note_of ~local_reg_evidence:true ()));
  (* Honest unknown / unconfigured: also neutral — absence not proven. *)
  check bool "configured_unverified: no unregistered claim" false
    (claims_unregistered (note_of ()));
  check bool "unconfigured: no unregistered claim" false
    (claims_unregistered (note_of ~relay_configured:false ()));
  (* Positive absence only. *)
  check bool "relay said absent: claims not a relay registration" true
    (claims_unregistered (note_of ~registration:Reg_absent ()));
  check bool "no identity: claims not a relay registration" true
    (claims_unregistered (note_of ~has_identity:false ()));
  check bool "no alias: claims not a relay registration" true
    (claims_unregistered (note_of ~has_alias:false ()))

(* --- end-to-end: c2c whoami human/JSON parity (isolated env) ---------------- *)

let c2c_bin =
  let dir = Filename.dirname Sys.executable_name in
  let candidate =
    Filename.concat (Filename.concat (Filename.dirname dir) "cli") "c2c.exe"
  in
  if Sys.file_exists candidate then candidate else "c2c"

let mkdtemp () =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-relay-state-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir base 0o700;
  base

(* Run [c2c_bin args] with a minimal curated env (no C2C_RELAY_URL, isolated
   HOME + broker root) and return (exit_code, stdout). *)
let run_c2c ~tmp args =
  let out_path = Filename.concat tmp (Printf.sprintf "out-%d" (Random.int 1_000_000)) in
  let env =
    [| "PATH=" ^ (try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin");
       "HOME=" ^ tmp;
       "XDG_CONFIG_HOME=" ^ Filename.concat tmp ".config";
       "C2C_MCP_SESSION_ID=relay-state-h5-test";
       "C2C_MCP_BROKER_ROOT=" ^ Filename.concat tmp "broker";
    |]
  in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600 in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0o600 in
  let pid =
    Unix.create_process_env c2c_bin
      (Array.of_list (c2c_bin :: args))
      env Unix.stdin out_fd dev_null
  in
  Unix.close out_fd;
  Unix.close dev_null;
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  let ic = open_in_bin out_path in
  let out = really_input_string ic (in_channel_length ic) in
  close_in ic;
  (code, out)

let test_whoami_json_human_parity_unconfigured () =
  (* B226/B187: whoami exits non-zero for unregistered sessions. Seed a local
     registration (still no relay URL / identity) so the test exercises the
     unconfigured *relay* classifier without ambient host state. *)
  let tmp = mkdtemp () in
  (* B187/B226: whoami refuses unregistered session_ids. Seed a local broker
     registration so identity resolves; leave relay unconfigured. Hermetic
     HOME/broker isolation so CI has no ambient session. *)
  let broker_root = Filename.concat tmp "broker" in
  Unix.mkdir broker_root 0o700;
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  let sid = "relay-state-h5-test" in
  let alias = "zzh5-relay-state-self" in
  C2c_mcp.Broker.register broker ~session_id:sid ~alias
    ~pid:(Some (Unix.getpid ())) ~pid_start_time:None
    ~client_type:(Some "test") ();
  let code_j, out_j = run_c2c ~tmp [ "whoami"; "--json" ] in
  check int "whoami --json exit 0" 0 code_j;
  let j = Yojson.Safe.from_string out_j in
  let relay = Yojson.Safe.Util.member "relay" j in
  let registration = Yojson.Safe.Util.member "registration" relay in
  let json_state = json_string registration "state" in
  check string "isolated env classifies unconfigured" "unconfigured" json_state;
  (match Yojson.Safe.Util.member "connector" relay with
   | `Assoc fields ->
       (match List.assoc_opt "live" fields with
        | Some (`Bool b) -> check bool "connector not live in isolated env" false b
        | _ -> fail "relay.connector.live missing")
   | _ -> fail "relay.connector missing");
  (* #11(2): this harness sets C2C_MCP_BROKER_ROOT, so the relay config file
     really is repo-local here and the tokens must say so — end-to-end, not
     just in the pure renderer. On a plain shell (no env var) the same code
     path reports relay_config_machine instead; that is the case the old
     "this repo's relay config" label got wrong. *)
  check string "registration.scope reflects the broker-root config file"
    "relay_config_repo" (json_string registration "scope");
  check string "registration.config_path names that file"
    (Filename.concat (Filename.concat tmp "broker") "relay.json")
    (json_string registration "config_path");
  (match Yojson.Safe.Util.member "connector" relay with
   | `Assoc fields ->
       check bool "connector.scope token present" true
         (List.assoc_opt "scope" fields
          = Some (`String "machine_connector_service"))
   | _ -> fail "relay.connector missing");
  check bool "relay.alias key still present (additive JSON)" true
    (match relay with
     | `Assoc fields -> List.mem_assoc "alias" fields
     | _ -> false);
  let code_h, out_h = run_c2c ~tmp [ "whoami" ] in
  check int "whoami (human) exit 0" 0 code_h;
  check bool "human output renders the same composite state string" true
    (string_contains ~needle:json_state out_h);
  check bool "human output has a state: line" true
    (string_contains ~needle:"state:" out_h);
  check bool "human output has a connector: line" true
    (string_contains ~needle:"connector:" out_h);
  check bool "human state line names the same relay config file" true
    (string_contains
       ~needle:
         ("relay config: "
          ^ Filename.concat (Filename.concat tmp "broker") "relay.json")
       out_h);
  (* Local broker alias is present; the old conflated "  registered:" label
     (A020/A027) must stay gone. B234: unconfigured is not positive absence —
     do not require "not a relay registration" on the alias line. *)
  check bool "human relay section shows the local alias" true
    (string_contains ~needle:("alias:      " ^ alias) out_h);
  check bool "human output has a state: line for relay" true
    (string_contains ~needle:"state:" out_h);
  check bool "old conflated 'registered:' label is gone" false
    (string_contains ~needle:"  registered:" out_h);
  (* B234: unconfigured is not positive absence — do not claim
     "not a relay registration" (that note is only for
     configured_not_registered). Neutral local-session note is fine. *)
  check bool "unconfigured whoami does not claim 'not a relay registration'"
    false
    (string_contains ~needle:"not a relay registration" out_h);
  check bool "unconfigured whoami keeps neutral local-session note" true
    (string_contains ~needle:"local session alias" out_h)

(* --- runner ------------------------------------------------------------------ *)

let () =
  Random.self_init ();
  run "c2c_relay_state"
    [
      ( "classify: unconfigured",
        [ test_case "no relay URL dominates" `Quick test_unconfigured ] );
      ( "classify: configured_not_registered",
        [ test_case "relay says absent" `Quick test_not_registered_relay_says_absent;
          test_case "no identity" `Quick test_not_registered_no_identity;
          test_case "no alias" `Quick test_not_registered_no_alias ] );
      ( "classify: registered_live",
        [ test_case "alive lease + connector" `Quick test_live_alive_lease_and_connector;
          test_case "broker-owned connector signal" `Quick
            test_live_from_broker_owned_connector_signal ] );
      ( "classify: registered_expired",
        [ test_case "expired lease (reserved/released)" `Quick test_expired_lease ] );
      ( "classify: registered_unreachable",
        [ test_case "alive lease, connector down" `Quick
            test_unreachable_alive_lease_connector_down;
          test_case "relay query failed, local evidence" `Quick
            test_unreachable_relay_query_failed_with_local_evidence;
          test_case "stale local evidence" `Quick test_unreachable_stale_local_evidence ] );
      ( "classify: configured_unverified",
        [ test_case "not checked, no evidence" `Quick
            test_unverified_not_checked_no_evidence;
          test_case "query failed, no evidence" `Quick
            test_unverified_query_failed_no_evidence ] );
      ( "lease JSON",
        [ test_case "alive RegistrationLease round-trip" `Quick
            test_lease_json_alive_roundtrip;
          test_case "expired RegistrationLease round-trip" `Quick
            test_lease_json_expired_roundtrip;
          test_case "malformed input total" `Quick test_lease_json_malformed_total ] );
      ( "connector signal",
        [ test_case "fresh state live" `Quick test_connector_fresh_state_is_live;
          test_case "stale state down" `Quick test_connector_stale_state_is_down;
          test_case "wedged process present (B181)" `Quick
            test_connector_wedged_process_present;
          test_case "connector_pid_alive helper" `Quick
            test_connector_pid_alive_helper;
          test_case "absent state" `Quick test_connector_absent_state ] );
      ( "connector presentation (#11)",
        [ test_case "erroring surfaces the real error" `Quick
            test_connector_erroring_surfaces_real_error;
          test_case "erroring without detail keeps guidance" `Quick
            test_connector_erroring_without_detail_keeps_guidance;
          test_case "wedged remediation untouched" `Quick
            test_connector_wedged_remediation_untouched;
          test_case "error detail bounded, command last" `Quick
            test_connector_error_detail_bounded;
          test_case "state/connector line scopes disambiguated" `Quick
            test_relay_lines_scopes_disambiguated;
          test_case "state line names the relay config file" `Quick
            test_state_line_names_the_relay_config_file;
          test_case "scope tokens pinned" `Quick test_scope_tokens_pinned ] );
      ( "human/JSON parity",
        [ test_case "state strings distinct + pinned" `Quick
            test_state_strings_distinct_and_stable;
          test_case "classification parity" `Quick
            test_classification_human_json_parity;
          test_case "connector parity" `Quick test_connector_human_json_parity ] );
      ( "alias line note (B234)",
        [ test_case "note only when positively not registered" `Quick
            test_alias_line_note_accurate ] );
      ( "whoami end-to-end",
        [ test_case "json/human parity (unconfigured)" `Quick
            test_whoami_json_human_parity_unconfigured ] );
    ]
