open Alcotest
open C2c_relay_ownership

let lease alias host session = make_lease ~alias ~host_id:host ~session_id:session

let test_owner_key_and_route () =
  let l = lease "T3-abc" "host-1" "session-1" in
  check string "route" "T3-abc@host-1" (remote_address l);
  check string "casefold owner key" "t3-abc" (owner_key l);
  check bool "same owner ignores alias case" true
    (same_owner l (lease "t3-ABC" "host-1" "session-1"))

let test_registry_refuses_foreign_owner () =
  let r = create_registry () in
  let a = lease "t3-a" "host-1" "session-1" in
  let b = lease "t3-a" "host-2" "session-2" in
  (match claim r a with Ok () -> () | Error _ -> fail "first claim must win");
  (match claim r a with Ok () -> () | Error _ -> fail "idempotent claim must pass");
  (match claim r b with
   | Error (Foreign_owner owner) ->
       check string "foreign owner" "host-1" owner.host_id
   | Ok () -> fail "foreign owner claim must be refused");
  check bool "foreign release cannot remove owner" false (release r b);
  check bool "owner release succeeds" true (release r a);
  check (option string) "released" None
    (Option.map remote_address (owner r ~alias:"t3-a"))

let test_plan_waits_for_machine_connector () =
  let i = Some { lease = lease "t3-a" "host-1" "session-1"; eligible = true } in
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. i None in
  check (list string) "wait" ["wait-for-connector"]
    (List.map action_to_string p.actions)

let test_plan_publishes_owned_private_lease () =
  let l = lease "t3-a" "host-1" "session-1" in
  let i = Some { lease = l; eligible = true } in
  let o = Some { lease = l; expires_at = 200.; public = false } in
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. i o in
  check (list string) "publish" ["publish"]
    (List.map action_to_string p.actions)

let test_plan_renews_and_publishes_due_private_lease () =
  let l = lease "t3-a" "host-1" "session-1" in
  let i = Some { lease = l; eligible = true } in
  let o = Some { lease = l; expires_at = 120.; public = false } in
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. i o in
  check (list string) "renew then publish" ["renew"; "publish"]
    (List.map action_to_string p.actions)

let test_plan_refuses_foreign_and_retirement_keeps_it () =
  let own = lease "t3-a" "host-1" "session-1" in
  let foreign = lease "t3-a" "host-2" "session-2" in
  let eligible = Some { lease = own; eligible = true } in
  let retired = Some { lease = own; eligible = false } in
  let observed = Some { lease = foreign; expires_at = 200.; public = true } in
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. eligible observed in
  check (list string) "foreign eligible" ["refuse-foreign"]
    (List.map action_to_string p.actions);
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. retired observed in
  check (list string) "foreign retired" ["refuse-foreign"]
    (List.map action_to_string p.actions)

let test_plan_retirement_stops_renewal () =
  let l = lease "t3-a" "host-1" "session-1" in
  let i = Some { lease = l; eligible = false } in
  let o = Some { lease = l; expires_at = 200.; public = true } in
  let p = plan ~relay_enabled:true ~now:100. ~renew_before_s:30. i o in
  check (list string) "stop renewal" ["stop-renewal"]
    (List.map action_to_string p.actions)

let test_disabled_relay_preserves_local_delivery () =
  let l = lease "t3-a" "host-1" "session-1" in
  let i = Some { lease = l; eligible = true } in
  let o = Some { lease = l; expires_at = 1.; public = false } in
  let p = plan ~relay_enabled:false ~now:100. ~renew_before_s:30. i o in
  check (list string) "disabled" ["stop-renewal"]
    (List.map action_to_string p.actions)

let test_machine_connector_includes_shared_sessions_broker () =
  let previous = Sys.getenv_opt "C2C_SESSIONS_BROKER_ROOT" in
  let root = Filename.concat (Filename.get_temp_dir_name ()) "t006-sessions-broker" in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "C2C_SESSIONS_BROKER_ROOT" value
      | None -> Unix.putenv "C2C_SESSIONS_BROKER_ROOT" "")
    (fun () ->
      Unix.putenv "C2C_SESSIONS_BROKER_ROOT" root;
      let roots = C2c_relay_connector.discover_machine_broker_roots
        ~primary:"/tmp/t006-primary" in
      check bool "sessions broker discovered" true (List.mem root roots);
      check int "primary is present once" 1
        (List.length (List.filter ((=) "/tmp/t006-primary") roots)))

let test_retry_delay_is_bounded_and_deterministic () =
  check (float 0.001) "first" 2. (retry_delay_s ~base_s:2. ~max_s:10. ~attempt:0);
  check (float 0.001) "second" 4. (retry_delay_s ~base_s:2. ~max_s:10. ~attempt:1);
  check (float 0.001) "capped" 10. (retry_delay_s ~base_s:2. ~max_s:10. ~attempt:9);
  check (float 0.001) "invalid base" 1. (retry_delay_s ~base_s:0. ~max_s:0. ~attempt:0)

let () =
  run "c2c relay ownership"
    [ ("identity", [test_case "owner key and route" `Quick test_owner_key_and_route]);
      ("registry", [test_case "foreign owner" `Quick test_registry_refuses_foreign_owner]);
      ("planning",
       [ test_case "wait for connector" `Quick test_plan_waits_for_machine_connector;
         test_case "publish private lease" `Quick test_plan_publishes_owned_private_lease;
         test_case "renew and publish" `Quick test_plan_renews_and_publishes_due_private_lease;
         test_case "refuse foreign" `Quick test_plan_refuses_foreign_and_retirement_keeps_it;
         test_case "retire owned" `Quick test_plan_retirement_stops_renewal;
         test_case "relay disabled" `Quick test_disabled_relay_preserves_local_delivery ]);
      ("connector", [test_case "shared sessions broker" `Quick
         test_machine_connector_includes_shared_sessions_broker]);
      ("retry", [test_case "bounded backoff" `Quick test_retry_delay_is_bounded_and_deterministic]) ]
