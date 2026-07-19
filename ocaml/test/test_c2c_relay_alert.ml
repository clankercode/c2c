(** Pure-function tests for C2c_relay_alert (B010).

    Covers severity mapping, edge-triggered dedup (transition emits, plateau
    does not), and routing selection. No IO / no network — the whole point of
    the module being pure. *)

module A = C2c_relay_alert

let obs ?(difficulty = None) ?(rate_limited = false)
        ?(rate_limited_senders = [])
        ?(pow_retry_failed = false) ?(pow_retry_sender = None) ?(dlqs = [])
        ?(inbound_contract_aliases = []) () =
  { A.obs_difficulty = difficulty;
    obs_rate_limited = rate_limited;
    obs_rate_limited_senders = rate_limited_senders;
    obs_pow_retry_failed = pow_retry_failed;
    obs_pow_retry_sender = pow_retry_sender;
    obs_dlqs = dlqs;
    obs_inbound_contract_aliases = inbound_contract_aliases }

let kinds ems = List.map (fun e -> e.A.kind) ems
let sevs ems = List.map (fun e -> A.severity_to_string e.A.severity) ems
let targets ems = List.map (fun e -> A.target_to_string e.A.target) ems
let contract_aliases st = List.map fst st.A.inbound_contract_alerts

let contains ~needle s =
  let nl = String.length needle and sl = String.length s in
  let rec go i = i + nl <= sl && (String.sub s i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* --- difficulty edge --- *)

let test_difficulty_increase_emits_warn () =
  let ems, st = A.step A.initial_state (obs ~difficulty:(Some 4) ()) in
  Alcotest.(check (list string)) "one difficulty_increase" ["difficulty_increase"] (kinds ems);
  Alcotest.(check (list string)) "warn severity" ["WARN"] (sevs ems);
  Alcotest.(check (list string)) "connector log only" ["connector-log"] (targets ems);
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
  Alcotest.(check (list string)) "connector-wide limit is log-only"
    ["connector-log"] (targets ems1);
  Alcotest.(check bool) "state marks rate_limited" true st1.A.rate_limited;
  let ems2, st2 = A.step st1 (obs ~rate_limited:true ()) in
  Alcotest.(check (list string)) "sustained does not re-alert" [] (kinds ems2);
  Alcotest.(check bool) "still rate_limited" true st2.A.rate_limited;
  let ems3, st3 = A.step st2 (obs ~rate_limited:false ()) in
  Alcotest.(check (list string)) "recovery clears silently" [] (kinds ems3);
  Alcotest.(check bool) "rate_limited cleared" false st3.A.rate_limited

let test_rate_limit_from_outbox_dms_sender () =
  let ems, _ = A.step A.initial_state
    (obs ~rate_limited_senders:["alice"] ()) in
  Alcotest.(check (list string)) "DM only the responsible sender"
    ["dm:alice"] (targets ems)

let test_connector_rate_limit_does_not_suppress_sender () =
  let connector_ems, st =
    A.step A.initial_state (obs ~rate_limited:true ())
  in
  Alcotest.(check (list string)) "connector edge is logged"
    ["connector-log"] (targets connector_ems);
  let sender_ems, _ = A.step st (obs ~rate_limited_senders:["alice"] ()) in
  Alcotest.(check (list string)) "later sender gets independent edge"
    ["dm:alice"] (targets sender_ems)

let test_sender_plateaus_are_deduped_independently () =
  let _, st = A.step A.initial_state
    (obs ~rate_limited_senders:["alice"] ())
  in
  let ems, _ = A.step st
    (obs ~rate_limited_senders:["alice"; "bob"] ())
  in
  Alcotest.(check (list string)) "alice plateau suppressed; bob emitted"
    ["dm:bob"] (targets ems)

let test_multiple_senders_in_one_sync_are_preserved () =
  let ems, _ = A.step A.initial_state
    (obs ~rate_limited_senders:["alice"; "bob"; "ALICE"] ())
  in
  Alcotest.(check (list string)) "each distinct sender gets one emission"
    ["dm:alice"; "dm:bob"] (targets ems)

let test_sender_rate_limit_recovery_resets_edge () =
  let _, st1 = A.step A.initial_state
    (obs ~rate_limited_senders:["alice"] ())
  in
  let recovery_ems, st2 = A.step st1 (obs ()) in
  Alcotest.(check (list string)) "recovery is silent" [] (kinds recovery_ems);
  let ems, _ = A.step st2 (obs ~rate_limited_senders:["alice"] ()) in
  Alcotest.(check (list string)) "sender re-alerts after recovery"
    ["dm:alice"] (targets ems)

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

(* --- #62: relay-served undeliverable inbound rows --- *)

(* This is the ONLY agent-visible signal for the class. The connector
   deliberately keeps these drops out of [last_error]/health (a restart cannot
   fix a relay serving malformed rows), and polling the relay is destructive,
   so the mail is already gone by the time we notice. If these emissions stop
   firing, a relay can drain and destroy 100% of a host's inbound mail while
   `c2c whoami` reports the connector healthy. *)

let test_inbound_contract_dms_affected_alias () =
  let ems, st =
    A.step A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "one inbound_contract" [ "inbound_contract" ]
    (kinds ems);
  Alcotest.(check (list string)) "err severity" [ "ERR" ] (sevs ems);
  Alcotest.(check (list string)) "DM the recipient whose mail was destroyed"
    [ "dm:alpha" ] (targets ems);
  Alcotest.(check bool) "body says the rows were dropped and not retried" true
    (contains ~needle:"DROPPED" (List.hd ems).A.body
     && contains ~needle:"NOT be retried" (List.hd ems).A.body);
  Alcotest.(check bool) "body names the alias" true
    (contains ~needle:"alpha" (List.hd ems).A.body);
  Alcotest.(check (list string)) "alert record kept for alpha" [ "alpha" ]
    (contract_aliases st)

let test_inbound_contract_plateau_does_not_spam () =
  (* A relay serving garbage on every 30s sync must alert once, not 120
     times an hour into the agent's inbox. *)
  let ems1, st1 =
    A.step ~now:0. A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "first sync alerts" [ "inbound_contract" ]
    (kinds ems1);
  let ems2, st2 =
    A.step ~now:30. st1 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "sustained failure does not re-alert" []
    (kinds ems2);
  let ems3, _ =
    A.step ~now:60. st2 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "still quiet on the third sync" []
    (kinds ems3)

(* #72 (the headline defect): intermittent drops with CLEAN polls between must
   NOT re-alert on every occurrence. Under #62 an idle sync cleared the plateau
   list, so the next drop re-fired — 50 misrouted rows across 50 syncs = 50 DMs.
   Within the re-alert floor the recurrence is now muted and merely counted. *)
let test_inbound_contract_intermittent_within_floor_is_muted () =
  let ems1, st1 =
    A.step ~now:0. A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "first drop alerts" [ "inbound_contract" ]
    (kinds ems1);
  (* a clean sync in between must NOT re-arm the alert *)
  let ems2, st2 = A.step ~now:100. st1 (obs ()) in
  Alcotest.(check (list string)) "clean sync is silent" [] (kinds ems2);
  Alcotest.(check (list string)) "record retained inside the floor" [ "alpha" ]
    (contract_aliases st2);
  (* a fresh drop, still inside the floor, is muted (previously re-alerted) *)
  let ems3, _ =
    A.step ~now:200. st2 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "recurrence within the floor is muted" []
    (kinds ems3)

(* #72: after the floor elapses a recurrence re-alerts, and the DM carries the
   count of occurrences muted meanwhile so nothing is silently lost. *)
let test_inbound_contract_realerts_after_floor_with_count () =
  let floor = A.inbound_contract_realert_floor_s in
  let ems1, st1 =
    A.step ~now:0. A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "first drop alerts" [ "inbound_contract" ]
    (kinds ems1);
  (* two muted recurrences inside the floor *)
  let _, st2 =
    A.step ~now:60. st1 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  let _, st3 =
    A.step ~now:120. st2 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  (* one more, now past the floor: re-alerts and reports the 2 muted syncs *)
  let ems4, _ =
    A.step ~now:(floor +. 1.) st3 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "re-alerts after the floor"
    [ "inbound_contract" ] (kinds ems4);
  Alcotest.(check bool) "DM reports the 2 muted occurrences" true
    (contains ~needle:"2 further" (List.hd ems4).A.body)

(* #72: once the floor elapses with no fresh drop the record is retired, so a
   genuinely new episode later alerts immediately with no muted-count clause. *)
let test_inbound_contract_record_retired_after_floor () =
  let floor = A.inbound_contract_realert_floor_s in
  let _, st1 =
    A.step ~now:0. A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  let ems2, st2 = A.step ~now:(floor +. 1.) st1 (obs ()) in
  Alcotest.(check (list string)) "clean sync after floor is silent" []
    (kinds ems2);
  Alcotest.(check (list string)) "record retired" [] (contract_aliases st2);
  let ems3, _ =
    A.step ~now:(floor +. 2.) st2 (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  Alcotest.(check (list string)) "fresh episode re-alerts" [ "inbound_contract" ]
    (kinds ems3);
  Alcotest.(check bool) "no muted-count clause on a fresh alert" false
    (contains ~needle:"further sync" (List.hd ems3).A.body)

let test_inbound_contract_aliases_dedupe_independently () =
  let _, st1 =
    A.step A.initial_state (obs ~inbound_contract_aliases:[ "alpha" ] ())
  in
  let ems, _ =
    A.step st1 (obs ~inbound_contract_aliases:[ "alpha"; "beta"; "beta" ] ())
  in
  Alcotest.(check (list string)) "only the new alias alerts, once"
    [ "dm:beta" ] (targets ems)

let test_no_inbound_contract_drops_is_silent () =
  let ems, st = A.step A.initial_state (obs ()) in
  Alcotest.(check (list string)) "nothing emitted" [] (kinds ems);
  Alcotest.(check (list string)) "no record" [] (contract_aliases st)

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
      Alcotest.test_case "increase emits warn (connector log)" `Quick test_difficulty_increase_emits_warn;
      Alcotest.test_case "plateau does not re-emit" `Quick test_difficulty_plateau_no_reemit;
      Alcotest.test_case "further increase re-emits" `Quick test_difficulty_further_increase_emits;
      Alcotest.test_case "decrease emits info" `Quick test_difficulty_decrease_emits_info;
      Alcotest.test_case "None observation is a no-op" `Quick test_difficulty_none_is_noop;
    ];
    "rate-limit", [
      Alcotest.test_case "edge → plateau → recover" `Quick test_rate_limit_edge_then_plateau_then_recover;
      Alcotest.test_case "outbox rejection DMs sender" `Quick test_rate_limit_from_outbox_dms_sender;
      Alcotest.test_case "connector then sender emit independently" `Quick
        test_connector_rate_limit_does_not_suppress_sender;
      Alcotest.test_case "Alice plateau does not suppress Bob" `Quick
        test_sender_plateaus_are_deduped_independently;
      Alcotest.test_case "multiple senders in one sync" `Quick
        test_multiple_senders_in_one_sync_are_preserved;
      Alcotest.test_case "sender recovery resets edge" `Quick
        test_sender_rate_limit_recovery_resets_edge;
    ];
    "pow_retry_failed", [
      Alcotest.test_case "DM sender when known" `Quick test_pow_retry_failed_dm_sender;
      Alcotest.test_case "broadcast when sender unknown" `Quick test_pow_retry_failed_no_sender_broadcasts;
      Alcotest.test_case "plateau then clear" `Quick test_pow_retry_failed_plateau_then_clear;
    ];
    "dlq", [
      Alcotest.test_case "DM sender per entry" `Quick test_dlq_dm_sender_per_entry;
    ];
    "inbound_contract", [
      Alcotest.test_case "DMs the alias whose mail was destroyed" `Quick
        test_inbound_contract_dms_affected_alias;
      Alcotest.test_case "continuous drops alert once" `Quick
        test_inbound_contract_plateau_does_not_spam;
      Alcotest.test_case "#72 intermittent drops within floor are muted" `Quick
        test_inbound_contract_intermittent_within_floor_is_muted;
      Alcotest.test_case "#72 re-alerts after floor carrying muted count" `Quick
        test_inbound_contract_realerts_after_floor_with_count;
      Alcotest.test_case "#72 record retired after floor re-alerts fresh" `Quick
        test_inbound_contract_record_retired_after_floor;
      Alcotest.test_case "aliases dedupe independently" `Quick
        test_inbound_contract_aliases_dedupe_independently;
      Alcotest.test_case "no drops is silent" `Quick
        test_no_inbound_contract_drops_is_silent;
    ];
    "combined", [
      Alcotest.test_case "independent edges in one sync" `Quick test_combined_emissions;
    ];
  ]
