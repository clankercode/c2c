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
     (unconfigured relay) carry the same composite state. *)

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

let conn_state ?(last_sync = 0.0) ?(last_ok = 0.0) () :
    C2c_relay_connector.connector_state =
  {
    C2c_relay_connector.cs_last_sync_ts = last_sync;
    cs_last_ok_ts = last_ok;
    cs_last_error_op = None;
    cs_last_error_detail = None;
    cs_last_error_ts = None;
    (* H3 added cs_node_id to connector_state; this H5 fixture predates it.
       None = no node-id recorded, the pre-H3 behaviour. *)
    cs_node_id = None;
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
  let info = connector_info ~state:(Some st) ~now in
  check bool "fresh state -> live" true info.conn_live;
  check bool "state file present" true info.conn_state_present;
  (match info.conn_last_sync_age_s with
   | Some a -> check (float 0.001) "age = now - last_sync" 30.0 a
   | None -> fail "expected last-sync age");
  (* Same verdict as the doctor's broker-owned signal. *)
  check bool "agrees with Relay_doctor.connector_running"
    (Relay_doctor.connector_running ~scoped_procs:[] ~state:(Some st) ~now)
    info.conn_live

let test_connector_stale_state_is_down () =
  let st = conn_state ~last_sync:(now -. 3600.0) ~last_ok:(now -. 3600.0) () in
  let info = connector_info ~state:(Some st) ~now in
  check bool "stale state -> down" false info.conn_live;
  check bool "state file still present" true info.conn_state_present;
  check bool "agrees with Relay_doctor.connector_running"
    (Relay_doctor.connector_running ~scoped_procs:[] ~state:(Some st) ~now)
    info.conn_live

let test_connector_absent_state () =
  let info = connector_info ~state:None ~now in
  check bool "no state file -> down" false info.conn_live;
  check bool "no state file recorded" false info.conn_state_present;
  check bool "no age" true (info.conn_last_sync_age_s = None)

(* --- human/JSON parity ------------------------------------------------------- *)

let all_states =
  [ Unconfigured; Configured_not_registered; Configured_unverified;
    Registered_live; Registered_expired; Registered_unreachable ]

let json_string j key =
  match j with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> failwith (Printf.sprintf "missing string key %S" key))
  | _ -> failwith "expected Assoc"

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
  List.iter
    (fun state ->
       let c = { state; reason = "some reason" } in
       let json_state = json_string (classification_json c) "state" in
       let human = classification_human c in
       check bool
         (Printf.sprintf "human line embeds JSON state %S" json_state)
         true
         (string_contains ~needle:json_state human);
       check string "JSON reason matches record"
         c.reason (json_string (classification_json c) "reason");
       check bool "human line embeds reason" true
         (string_contains ~needle:c.reason human))
    all_states

let test_connector_human_json_parity () =
  let cases =
    [ connector_info ~state:(Some (conn_state ~last_sync:(now -. 5.0) ())) ~now;
      connector_info ~state:(Some (conn_state ~last_sync:(now -. 9999.0) ())) ~now;
      connector_info ~state:None ~now ]
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
       let human = connector_human info in
       check bool "json live flag matches record" info.conn_live live_json;
       let human_says_live = string_contains ~needle:"live" human
                             && not (string_contains ~needle:"down" human)
                             && not (string_contains ~needle:"none" human) in
       check bool "human leading word agrees with json live" live_json
         human_says_live)
    cases

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
  let tmp = mkdtemp () in
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
  (* No session alias resolves in this isolated env; the relay section's
     alias line must say so — and the old conflated "  registered:" label
     (A020/A027: local alias presented as relay registration) must be gone. *)
  check bool "human output has the alias: line" true
    (string_contains ~needle:"alias:      (no current session alias)" out_h);
  check bool "old conflated 'registered:' label is gone" false
    (string_contains ~needle:"  registered:" out_h)

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
          test_case "absent state" `Quick test_connector_absent_state ] );
      ( "human/JSON parity",
        [ test_case "state strings distinct + pinned" `Quick
            test_state_strings_distinct_and_stable;
          test_case "classification parity" `Quick
            test_classification_human_json_parity;
          test_case "connector parity" `Quick test_connector_human_json_parity ] );
      ( "whoami end-to-end",
        [ test_case "json/human parity (unconfigured)" `Quick
            test_whoami_json_human_parity_unconfigured ] );
    ]
