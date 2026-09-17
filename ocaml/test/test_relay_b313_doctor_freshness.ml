(* B313: the doctor/state freshness window is a FIXED 120s
   ([Relay_doctor.connector_stale_threshold_s]) while the connector
   self-scales with observed pass work (B291/B307). On a many-root host a
   healthy root's last_ok ages about one full pass period (live measured:
   4-6 min walks), so doctor / Relay_state.derive_health classify a HEALTHY
   connector as stale and recommend starting another, and the B294 register
   guard's freshness arm misfires the same way (pid-alive usually saves it;
   roots with older state files lose that arm too).

   Fix under test, all hermetic (tmp dirs, fixture connector-state.json
   files, no network, no live relay):
   - the connector records PASS METADATA (pass_duration_s / pass_interval_s)
     in connector-state.json and doctor/Relay_state/connector_owns_alias
     scale the freshness window from it, floored at the 120s default and
     CAPPED so a wedged connector cannot read healthy for hours;
   - C2C_RELAY_DOCTOR_FRESHNESS_S overrides the window in SECONDS for
     operators and tests;
   - without metadata (older state files) and with a dead connector the
     behaviour is unchanged: past the window reads stale. *)

open Alcotest

module Conn = C2c_relay_connector

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

(* A pid that cannot be ours (same trick as the B294 suite): pid 1 is
   excluded by connector_pid_alive and a huge pid does not exist, so the
   pid arm never fires — the freshness arm is what is under test. *)
let dead_pid = 4_000_000

(* Fixture connector-state.json. [age]: how old last_ok_ts / last_sync_ts
   are. [pass_duration_s]/[pass_interval_s]: the B313 pass metadata keys
   (omitted from the file when None — the pre-B313 shape). *)
let write_connector_state ?pass_duration_s ?pass_interval_s ?last_error_op
    ~dir ~managed ~age ~pid () =
  let now = Unix.gettimeofday () in
  let ts = now -. age in
  let sessions =
    if managed then `Assoc [ "b313-probe", `String "sess-b313" ]
    else `Assoc [ "somebody-else", `String "sess-other" ]
  in
  let registered =
    if managed then [ `String "b313-probe" ] else [ `String "somebody-else" ]
  in
  let optional key = function
    | Some v -> [ (key, `Float v) ]
    | None -> []
  in
  write_file
    (Filename.concat dir "connector-state.json")
    (Yojson.Safe.to_string
       (`Assoc
         ([ ("last_sync_ts", `Float ts)
          ; ("last_ok_ts", `Float ts)
          ; ("pid", match pid with Some p -> `Int p | None -> `Null)
          ; ("registered", `List registered)
          ; ("outbox_forwarded", `Int 0)
          ; ("outbox_failed", `Int 0)
          ; ("outbox_dlqed", `Int 0)
          ; ("inbound_delivered", `Int 0)
          ; ("inbound_rejected", `Int 0)
          ; ("inbound_rejected_note", `Null)
          ; ("last_error_op",
             match last_error_op with Some op -> `String op | None -> `Null)
          ; ("sessions", sessions) ]
         @ optional "pass_duration_s" pass_duration_s
         @ optional "pass_interval_s" pass_interval_s)))

(* Set/unset C2C_RELAY_DOCTOR_FRESHNESS_S around [f]. Empty string counts
   as unset (the override parser ignores non-positive / non-numeric). *)
let with_env var value f =
  let old = try Some (Sys.getenv var) with Not_found -> None in
  Unix.putenv var value;
  Fun.protect f ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv var v
      | None -> Unix.putenv var "")

(* --- red: a healthy many-root root past 120s must read healthy ---------- *)

(* last_ok 400s old with recorded pass work (350s walks, 30s poll) is the
   LIVE-MEASURED healthy xsm shape; the fixed 120s window calls it stale. *)
let test_metadata_scaled_window_keeps_healthy_root_ok () =
  with_temp_dir "c2c_b313_fresh" (fun dir ->
      write_connector_state ~pass_duration_s:350.0 ~pass_interval_s:30.0 ~dir ~managed:true ~age:400.0
        ~pid:(Some dead_pid) ();
      let now = Unix.gettimeofday () in
      let st = Conn.read_connector_state dir in
      check bool "fixture state file readable" true (st <> None);
      let info =
        Relay_state.connector_info ~state:st ~now ()
      in
      check bool "last_ok one pass period old + metadata -> live" true
        info.Relay_state.conn_live;
      check string "health class ok (not stale)" "ok"
        (Relay_state.health_to_string info.Relay_state.conn_health);
      check bool "no start-another-connector remediation" true
        (info.Relay_state.conn_remediation = None);
      let chk =
        Relay_doctor.connector_check ~relay_url:"https://relay.example"
          ~scoped_procs:[] ~state:st ~now
      in
      check bool "doctor connector check PASSes" true
        (chk.Relay_doctor.status = Relay_doctor.Pass))

(* The B294 register guard's freshness arm uses the same fixed 120s and
   misfires on the same shape: dead pid + last_ok one pass period old. *)
let test_owns_alias_freshness_arm_scales_with_metadata () =
  with_temp_dir "c2c_b313_own" (fun dir ->
      write_connector_state ~pass_duration_s:350.0 ~pass_interval_s:30.0 ~dir ~managed:true ~age:400.0
        ~pid:(Some dead_pid) ();
      let owned =
        Conn.connector_owns_alias ~broker_root:dir ~alias:"b313-probe"
          ~now:(Unix.gettimeofday ())
      in
      check bool "fresh arm survives one pass period with metadata" true
        (owned <> None))

(* --- C2C_RELAY_DOCTOR_FRESHNESS_S: operator/test override --------------- *)

let test_env_override_extends_window () =
  with_temp_dir "c2c_b313_env" (fun dir ->
      write_connector_state ~dir ~managed:true ~age:600.0
        ~pid:(Some dead_pid) ();
      with_env "C2C_RELAY_DOCTOR_FRESHNESS_S" "7200" (fun () ->
          let owned =
            Conn.connector_owns_alias ~broker_root:dir ~alias:"b313-probe"
              ~now:(Unix.gettimeofday ())
          in
          check bool "override makes a 600s-old root owned" true
            (owned <> None);
          let info =
            Relay_state.connector_info
              ~state:(Conn.read_connector_state dir)
              ~now:(Unix.gettimeofday ()) ()
          in
          check bool "override makes doctor read live" true
            info.Relay_state.conn_live))

(* Units: the override is SECONDS. 7200 means two hours, not 7.2s. *)
let test_env_override_is_in_seconds () =
  with_temp_dir "c2c_b313_units" (fun dir ->
      write_connector_state ~dir ~managed:true ~age:600.0
        ~pid:(Some dead_pid) ();
      with_env "C2C_RELAY_DOCTOR_FRESHNESS_S" "7200" (fun () ->
          let info =
            Relay_state.connector_info
              ~state:(Conn.read_connector_state dir)
              ~now:(Unix.gettimeofday ()) ()
          in
          check bool "600s old is inside a 7200s (not 7200ms) window" true
            info.Relay_state.conn_live);
      with_env "C2C_RELAY_DOCTOR_FRESHNESS_S" "10" (fun () ->
          let info =
            Relay_state.connector_info
              ~state:(Conn.read_connector_state dir)
              ~now:(Unix.gettimeofday ()) ()
          in
          check bool "600s old is outside a 10s window" false
            info.Relay_state.conn_live))

let test_env_override_garbage_ignored () =
  with_temp_dir "c2c_b313_envbad" (fun dir ->
      write_connector_state ~dir ~managed:true ~age:600.0
        ~pid:(Some dead_pid) ();
      List.iter
        (fun v ->
           with_env "C2C_RELAY_DOCTOR_FRESHNESS_S" v (fun () ->
               let owned =
                 Conn.connector_owns_alias ~broker_root:dir
                   ~alias:"b313-probe" ~now:(Unix.gettimeofday ())
               in
               check bool
                 (Printf.sprintf "override %S ignored" v) false
                 (owned <> None)))
        [ ""; "abc"; "0"; "-5" ])

(* --- guards: no metadata / dead connector / cap ------------------------- *)

let test_without_metadata_default_window_unchanged () =
  with_temp_dir "c2c_b313_nometa" (fun dir ->
      write_connector_state ~dir ~managed:true ~age:400.0
        ~pid:(Some dead_pid) ();
      let info =
        Relay_state.connector_info
          ~state:(Conn.read_connector_state dir)
          ~now:(Unix.gettimeofday ()) ()
      in
      check bool "pre-B313 state file: 400s old still stale" false
        info.Relay_state.conn_live;
      let owned =
        Conn.connector_owns_alias ~broker_root:dir ~alias:"b313-probe"
          ~now:(Unix.gettimeofday ())
      in
      check bool "pre-B313 state file: freshness arm still misfires (guard)"
        false (owned <> None))

let test_cap_bounds_scaled_window () =
  (* Metadata must not scale the window past the cap: a genuinely dead
     connector (2h-old last_ok, no live pid, no proc) still reads stale. *)
  with_temp_dir "c2c_b313_cap" (fun dir ->
      write_connector_state ~pass_duration_s:350.0 ~pass_interval_s:30.0 ~dir ~managed:true ~age:7200.0
        ~pid:(Some dead_pid) ();
      let info =
        Relay_state.connector_info
          ~state:(Conn.read_connector_state dir)
          ~now:(Unix.gettimeofday ()) ()
      in
      check bool "2h-old last_ok reads stale even with metadata" false
        info.Relay_state.conn_live;
      let chk =
        Relay_doctor.connector_check ~relay_url:"https://relay.example"
          ~scoped_procs:[] ~state:(Conn.read_connector_state dir)
          ~now:(Unix.gettimeofday ())
      in
      check bool "doctor still FAILs a dead connector" true
        (chk.Relay_doctor.status = Relay_doctor.Fail))

(* --- window formula + writer (pin the scaled-window arithmetic) --------- *)

(* Build a state VALUE directly (the reader path is exercised by the
   fixtures above). *)
let cs_with ?duration ?interval () =
  { Conn.cs_last_sync_ts = 0.0; cs_last_ok_ts = 0.0;
    cs_last_error_op = None; cs_last_error_detail = None;
    cs_last_error_ts = None;
    cs_registered = []; cs_node_id = None; cs_sessions = []; cs_pid = None;
    cs_outbox_forwarded = 0; cs_outbox_failed = 0; cs_outbox_dlqed = 0;
    cs_inbound_delivered = 0; cs_inbound_rejected = 0;
    cs_inbound_rejected_note = None;
    cs_wedged_since = None; cs_wedge_reason = None; cs_wedge_count = 0;
    cs_errors = []; cs_rate_limited = false; cs_retry_after_s = None;
    cs_pass_duration_s = duration; cs_pass_interval_s = interval }

let test_window_formula () =
  let f st = Conn.connector_freshness_window_s st in
  check (float 0.001) "30s interval + 350s walk -> 760s"
    760.0 (f (Some (cs_with ~duration:350.0 ~interval:30.0 ())));
  check (float 0.001) "fast host stays at the 120s floor" 120.0
    (f (Some (cs_with ~duration:10.0 ~interval:30.0 ())));
  check (float 0.001) "no metadata -> 120s default" 120.0
    (f (Some (cs_with ())));
  check (float 0.001) "half the metadata (duration only) -> 120s" 120.0
    (f (Some (cs_with ~duration:350.0 ())));
  check (float 0.001) "non-positive metadata ignored" 120.0
    (f (Some (cs_with ~duration:0.0 ~interval:30.0 ())));
  check (float 0.001) "no state at all -> 120s default" 120.0 (f None);
  check (float 0.001) "absurd metadata capped at 1h" 3600.0
    (f (Some (cs_with ~duration:100000.0 ~interval:30.0 ())))

let test_env_override_wins_over_metadata () =
  with_env "C2C_RELAY_DOCTOR_FRESHNESS_S" "5000" (fun () ->
      check (float 0.001) "override beats recorded metadata" 5000.0
        (Conn.connector_freshness_window_s
           (Some (cs_with ~duration:350.0 ~interval:30.0 ()))))

let test_writer_roundtrip_and_preservation () =
  with_temp_dir "c2c_b313_write" (fun dir ->
      Conn.write_connector_state ~pass_duration_s:350.0 ~pass_interval_s:30.0
        dir (Conn.no_work_sync_result ());
      (match Conn.read_connector_state dir with
       | Some st ->
           check (option (float 1e-6)) "duration written" (Some 350.0)
             st.Conn.cs_pass_duration_s;
           check (option (float 1e-6)) "interval written" (Some 30.0)
             st.Conn.cs_pass_interval_s
       | None -> fail "state file must be readable after write");
      (* A writer with no metadata argument preserves the previous cadence
         (B316 preserve-on-rebuild contract, extended to B313 fields). *)
      Conn.write_connector_state dir (Conn.no_work_sync_result ());
      (match Conn.read_connector_state dir with
       | Some st ->
           check (option (float 1e-6)) "duration preserved" (Some 350.0)
             st.Conn.cs_pass_duration_s;
           check (option (float 1e-6)) "interval preserved" (Some 30.0)
             st.Conn.cs_pass_interval_s
       | None -> fail "state file must be readable after second write");
      (* A non-positive observation is not an observation: preserve. *)
      Conn.write_connector_state ~pass_duration_s:0.0
        ~pass_interval_s:(-1.0) dir (Conn.no_work_sync_result ());
      (match Conn.read_connector_state dir with
       | Some st ->
           check (option (float 1e-6)) "non-positive duration not written" (Some 350.0)
             st.Conn.cs_pass_duration_s;
           check (option (float 1e-6)) "non-positive interval not written" (Some 30.0)
             st.Conn.cs_pass_interval_s
       | None -> fail "state file must be readable after third write"))

(* B313/B324 composition: the demotion (register arm failing, last_ok past
   the FIXED 120s floor) still fires, but the scaled freshness arm owns the
   alias while last_ok is inside the metadata-scaled window — one pass
   period of age is healthy cadence, not binding drift. Past the cap both
   arms fail and the documented register repair stays available. *)
let test_b324_demotion_uses_fixed_floor () =
  with_temp_dir "c2c_b313_b324" (fun dir ->
      let owns ~age =
        write_connector_state ~pass_duration_s:350.0 ~pass_interval_s:30.0
          ~last_error_op:"register" ~dir ~managed:true ~age
          ~pid:(Some (Unix.getpid ())) ();
        Conn.connector_owns_alias ~broker_root:dir ~alias:"b313-probe"
          ~now:(Unix.gettimeofday ())
      in
      check bool
        "register failing 400s + scaled window (760s) -> still owned" true
        (owns ~age:400.0 <> None);
      check bool
        "register failing past the cap -> repairable (B324 intact)" false
        (owns ~age:3600.0 <> None))

let () =
  run "relay-b313-doctor-freshness"
    [
      ( "scaled window",
        [
          Alcotest.test_case "metadata keeps a healthy many-root root ok"
            `Quick test_metadata_scaled_window_keeps_healthy_root_ok;
          Alcotest.test_case "owns_alias freshness arm scales" `Quick
            test_owns_alias_freshness_arm_scales_with_metadata;
        ] );
      ( "env override",
        [
          Alcotest.test_case "C2C_RELAY_DOCTOR_FRESHNESS_S extends" `Quick
            test_env_override_extends_window;
          Alcotest.test_case "override is in seconds" `Quick
            test_env_override_is_in_seconds;
          Alcotest.test_case "garbage override ignored" `Quick
            test_env_override_garbage_ignored;
        ] );
      ( "guards",
        [
          Alcotest.test_case "no metadata keeps the 120s default" `Quick
            test_without_metadata_default_window_unchanged;
          Alcotest.test_case "cap bounds the scaled window" `Quick
            test_cap_bounds_scaled_window;
        ] );
      ( "window formula",
        [
          Alcotest.test_case "interval + 2x duration + slop, floored, capped"
            `Quick test_window_formula;
          Alcotest.test_case "override wins over recorded metadata" `Quick
            test_env_override_wins_over_metadata;
        ] );
      ( "writer",
        [
          Alcotest.test_case "pass metadata round-trips and is preserved"
            `Quick test_writer_roundtrip_and_preservation;
        ] );
      ( "b324 composition",
        [
          Alcotest.test_case
            "register-arm demotion keeps the fixed 120s floor" `Quick
            test_b324_demotion_uses_fixed_floor;
        ] );
    ]
