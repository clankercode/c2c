(** Pure-function tests for C2c_relay_alert (B010).

    Covers severity mapping, edge-triggered dedup (transition emits, plateau
    does not), and routing selection. No IO / no network — the whole point of
    the module being pure. *)

module A = C2c_relay_alert

let obs ?(difficulty = None) ?(rate_limited = false)
        ?(pow_retry_failed = false) ?(pow_retry_sender = None) ?(dlqs = []) () =
  { A.obs_difficulty = difficulty;
    obs_rate_limited = rate_limited;
    obs_pow_retry_failed = pow_retry_failed;
    obs_pow_retry_sender = pow_retry_sender;
    obs_dlqs = dlqs }

let kinds ems = List.map (fun e -> e.A.kind) ems
let sevs ems = List.map (fun e -> A.severity_to_string e.A.severity) ems
let targets ems = List.map (fun e -> A.target_to_string e.A.target) ems

let contains ~needle s =
  let nl = String.length needle and sl = String.length s in
  let rec go i = i + nl <= sl && (String.sub s i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* --- difficulty edge --- *)

let test_difficulty_increase_emits_warn () =
  let ems, st = A.step A.initial_state (obs ~difficulty:(Some 4) ()) in
  Alcotest.(check (list string)) "one difficulty_increase" ["difficulty_increase"] (kinds ems);
  Alcotest.(check (list string)) "warn severity" ["WARN"] (sevs ems);
  Alcotest.(check (list string)) "broadcast" ["broadcast"] (targets ems);
  Alcotest.(check int) "last_difficulty advanced" 4 st.A.last_difficulty;
  Alcotest.(check bool) "body mentions difficulty 4" true
    (contains ~needle:"to 4" (List.hd ems).A.body)

let test_difficulty_plateau_no_reemit () =
  let _, st = A.step A.initial_state (obs ~difficulty:(Some 4) ()) in
  let ems, st2 = A.step st (obs ~difficulty:(Some 4) ()) in
  Alcotest.(check (list string)) "plateau emits nothing" [] (kinds ems);
  Alcotest.(check int) "last_difficulty unchanged" 4 st2.A.last_difficulty

let test_difficulty_further_increase_emits () =
  let _, st = A.step A.initial_state (obs ~difficulty:(Some 4) ()) in
  let ems, st2 = A.step st (obs ~difficulty:(Some 8) ()) in
  Alcotest.(check (list string)) "re-emit on higher level" ["difficulty_increase"] (kinds ems);
  Alcotest.(check int) "last_difficulty advanced to 8" 8 st2.A.last_difficulty

let test_difficulty_decrease_emits_info () =
  let _, st = A.step A.initial_state (obs ~difficulty:(Some 8) ()) in
  let ems, st2 = A.step st (obs ~difficulty:(Some 2) ()) in
  Alcotest.(check (list string)) "decrease emits info edge" ["difficulty_decrease"] (kinds ems);
  Alcotest.(check (list string)) "info severity" ["INFO"] (sevs ems);
  Alcotest.(check int) "last_difficulty lowered to 2" 2 st2.A.last_difficulty

let test_difficulty_none_is_noop () =
  (* No observation must NOT be treated as a drop to 0. *)
  let _, st = A.step A.initial_state (obs ~difficulty:(Some 4) ()) in
  let ems, st2 = A.step st (obs ~difficulty:None ()) in
  Alcotest.(check (list string)) "None observation emits nothing" [] (kinds ems);
  Alcotest.(check int) "last_difficulty preserved" 4 st2.A.last_difficulty

(* --- rate-limit edge --- *)

let test_rate_limit_edge_then_plateau_then_recover () =
  let ems1, st1 = A.step A.initial_state (obs ~rate_limited:true ()) in
  Alcotest.(check (list string)) "first rejection warns" ["rate_limited"] (kinds ems1);
  Alcotest.(check (list string)) "broadcast" ["broadcast"] (targets ems1);
  Alcotest.(check bool) "state marks rate_limited" true st1.A.rate_limited;
  let ems2, st2 = A.step st1 (obs ~rate_limited:true ()) in
  Alcotest.(check (list string)) "sustained does not re-alert" [] (kinds ems2);
  Alcotest.(check bool) "still rate_limited" true st2.A.rate_limited;
  let ems3, st3 = A.step st2 (obs ~rate_limited:false ()) in
  Alcotest.(check (list string)) "recovery clears silently" [] (kinds ems3);
  Alcotest.(check bool) "rate_limited cleared" false st3.A.rate_limited

(* --- pow_retry_failed edge + routing --- *)

let test_pow_retry_failed_dm_sender () =
  let ems, st = A.step A.initial_state
    (obs ~pow_retry_failed:true ~pow_retry_sender:(Some "alice") ()) in
  Alcotest.(check (list string)) "one pow_retry_failed" ["pow_retry_failed"] (kinds ems);
  Alcotest.(check (list string)) "err severity" ["ERR"] (sevs ems);
  Alcotest.(check (list string)) "DM the sender" ["dm:alice"] (targets ems);
  Alcotest.(check bool) "state marks pow_failing" true st.A.pow_failing

let test_pow_retry_failed_no_sender_broadcasts () =
  let ems, _ = A.step A.initial_state (obs ~pow_retry_failed:true ()) in
  Alcotest.(check (list string)) "broadcast when sender unknown" ["broadcast"] (targets ems)

let test_pow_retry_failed_plateau_then_clear () =
  let _, st1 = A.step A.initial_state
    (obs ~pow_retry_failed:true ~pow_retry_sender:(Some "alice") ()) in
  let ems2, st2 = A.step st1
    (obs ~pow_retry_failed:true ~pow_retry_sender:(Some "alice") ()) in
  Alcotest.(check (list string)) "sustained pow failure does not re-alert" [] (kinds ems2);
  Alcotest.(check bool) "still pow_failing" true st2.A.pow_failing;
  let _, st3 = A.step st2 (obs ()) in
  Alcotest.(check bool) "cleared on success" false st3.A.pow_failing

(* --- DLQ discrete + routing --- *)

let test_dlq_dm_sender_per_entry () =
  let dlqs = [
    { A.dlq_sender = "alice"; dlq_to = "bob@host"; dlq_reason = "recipient_dead" };
    { A.dlq_sender = "carol"; dlq_to = "dave@host"; dlq_reason = "max_attempts" };
  ] in
  let ems, _ = A.step A.initial_state (obs ~dlqs ()) in
  Alcotest.(check (list string)) "two dlq emissions" ["dlq"; "dlq"] (kinds ems);
  Alcotest.(check (list string)) "both err" ["ERR"; "ERR"] (sevs ems);
  Alcotest.(check (list string)) "DM each originating sender"
    ["dm:alice"; "dm:carol"] (targets ems);
  Alcotest.(check bool) "body names recipient + reason" true
    (contains ~needle:"bob@host" (List.hd ems).A.body
     && contains ~needle:"recipient_dead" (List.hd ems).A.body)

(* --- combined: independent edges in one sync --- *)

let test_combined_emissions () =
  let dlqs = [ { A.dlq_sender = "alice"; dlq_to = "bob@host"; dlq_reason = "unknown_alias" } ] in
  let ems, _ = A.step A.initial_state
    (obs ~difficulty:(Some 4) ~rate_limited:true ~dlqs ()) in
  (* difficulty + rate-limit + dlq, in step order *)
  Alcotest.(check (list string)) "all three kinds"
    ["difficulty_increase"; "rate_limited"; "dlq"] (kinds ems)

let () =
  Alcotest.run "c2c_relay_alert" [
    "difficulty", [
      Alcotest.test_case "increase emits warn (broadcast)" `Quick test_difficulty_increase_emits_warn;
      Alcotest.test_case "plateau does not re-emit" `Quick test_difficulty_plateau_no_reemit;
      Alcotest.test_case "further increase re-emits" `Quick test_difficulty_further_increase_emits;
      Alcotest.test_case "decrease emits info" `Quick test_difficulty_decrease_emits_info;
      Alcotest.test_case "None observation is a no-op" `Quick test_difficulty_none_is_noop;
    ];
    "rate-limit", [
      Alcotest.test_case "edge → plateau → recover" `Quick test_rate_limit_edge_then_plateau_then_recover;
    ];
    "pow_retry_failed", [
      Alcotest.test_case "DM sender when known" `Quick test_pow_retry_failed_dm_sender;
      Alcotest.test_case "broadcast when sender unknown" `Quick test_pow_retry_failed_no_sender_broadcasts;
      Alcotest.test_case "plateau then clear" `Quick test_pow_retry_failed_plateau_then_clear;
    ];
    "dlq", [
      Alcotest.test_case "DM sender per entry" `Quick test_dlq_dm_sender_per_entry;
    ];
    "combined", [
      Alcotest.test_case "independent edges in one sync" `Quick test_combined_emissions;
    ];
  ]
