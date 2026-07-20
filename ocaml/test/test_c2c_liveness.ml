(* Hermetic purpose-semantics for C2c_liveness (P3.M1.E2). *)

open Alcotest

let mk ~pid ~pid_start_time ~registered_by ~client_type ~last_activity_ts
    : C2c_mcp.registration =
  { session_id = "sid-liveness"
  ; alias = "peer-liveness"
  ; pid
  ; pid_start_time
  ; registered_at = Some 1.0
  ; canonical_alias = None
  ; dnd = false
  ; dnd_since = None
  ; dnd_until = None
  ; client_type
  ; plugin_version = None
  ; confirmed_at = None
  ; enc_pubkey = None
  ; ed25519_pubkey = None
  ; pubkey_signed_at = None
  ; pubkey_sig = None
  ; compacting = None
  ; last_activity_ts
  ; role = None
  ; compaction_count = 0
  ; automated_delivery = None
  ; tmux_location = None
  ; herdr_pane = None
  ; herdr_socket = None
  ; cwd = Some "/tmp"
  ; metadata_opt_out = false
  ; registered_by
  ; opaque_host_id = None
  }

let test_nudge_strict_unknown_pidless () =
  (* Pidless non-hook row stays Unknown → Nudge/Doctor false.
     (After #59 activity-backed hooks may read Alive when fresh.) *)
  let reg =
    mk ~pid:None ~pid_start_time:None ~registered_by:None
      ~client_type:(Some "pty") ~last_activity_ts:None
  in
  check bool "Nudge not alive for Unknown" false
    (C2c_liveness.is_alive_for C2c_liveness.Nudge reg);
  check bool "Doctor not alive for Unknown" false
    (C2c_liveness.is_alive_for C2c_liveness.Doctor reg)

let test_delivery_matches_broker_is_alive () =
  let reg =
    mk ~pid:None ~pid_start_time:None ~registered_by:None
      ~client_type:(Some "pty") ~last_activity_ts:None
  in
  let broker = C2c_mcp.Broker.registration_is_alive reg in
  let delivery = C2c_liveness.is_alive_for C2c_liveness.Delivery reg in
  let list_p = C2c_liveness.is_alive_for C2c_liveness.List reg in
  let sweep = C2c_liveness.is_alive_for C2c_liveness.Sweep reg in
  check bool "Delivery = broker" broker delivery;
  check bool "List = broker" broker list_p;
  check bool "Sweep = broker" broker sweep

let test_state_mirrors_broker () =
  let reg =
    mk ~pid:None ~pid_start_time:None ~registered_by:None
      ~client_type:(Some "pty") ~last_activity_ts:None
  in
  let b = C2c_mcp.Broker.registration_liveness_state reg in
  let s = C2c_liveness.state reg in
  let ok =
    match b, s with
    | C2c_mcp.Broker.Alive, C2c_liveness.Alive -> true
    | C2c_mcp.Broker.Dead, C2c_liveness.Dead -> true
    | C2c_mcp.Broker.Unknown, C2c_liveness.Unknown -> true
    | _ -> false
  in
  check bool "state mirrors broker tristate" true ok

let test_pid_alive_helper () =
  check bool "pid 1 usually exists" true (C2c_liveness.pid_alive 1);
  check bool "pid 0 false" false (C2c_liveness.pid_alive 0);
  check bool "huge pid false" false (C2c_liveness.pid_alive 2147483646)

let test_purpose_strings () =
  check string "nudge" "nudge"
    (C2c_liveness.purpose_to_string C2c_liveness.Nudge);
  check string "alive" "alive"
    (C2c_liveness.state_to_string C2c_liveness.Alive)

let () =
  run "c2c liveness (P3 C3)"
    [ ( "purpose"
      , [ test_case "Nudge/Doctor strict on Unknown" `Quick
            test_nudge_strict_unknown_pidless
        ; test_case "Delivery/List/Sweep match broker is_alive" `Quick
            test_delivery_matches_broker_is_alive
        ; test_case "state mirrors broker" `Quick test_state_mirrors_broker
        ; test_case "pid_alive helper" `Quick test_pid_alive_helper
        ; test_case "purpose strings" `Quick test_purpose_strings
        ] )
    ]
