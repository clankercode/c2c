(* Tests for C2c_schedule_fire — pure idle-predicate logic. *)

open Alcotest

let test_agent_is_idle_no_activity () =
  let result =
    C2c_schedule_fire.agent_is_idle ~now:100.0 ~idle_threshold_s:10.0
      ~last_activity_ts:None
  in
  check bool "no activity => idle" true result

let test_agent_is_idle_recent () =
  let result =
    C2c_schedule_fire.agent_is_idle ~now:100.0 ~idle_threshold_s:10.0
      ~last_activity_ts:(Some 95.0)
  in
  check bool "5s < 10s => not idle" false result

let test_agent_is_idle_stale () =
  let result =
    C2c_schedule_fire.agent_is_idle ~now:100.0 ~idle_threshold_s:10.0
      ~last_activity_ts:(Some 85.0)
  in
  check bool "15s > 10s => idle" true result

let test_agent_is_idle_exact_threshold () =
  let result =
    C2c_schedule_fire.agent_is_idle ~now:100.0 ~idle_threshold_s:10.0
      ~last_activity_ts:(Some 90.0)
  in
  check bool "10s >= 10s => idle" true result

let () =
  run "C2c_schedule_fire"
    [ ( "agent_is_idle"
      , [ test_case "no activity" `Quick test_agent_is_idle_no_activity
        ; test_case "recent activity" `Quick test_agent_is_idle_recent
        ; test_case "stale activity" `Quick test_agent_is_idle_stale
        ; test_case "exact threshold" `Quick test_agent_is_idle_exact_threshold
        ] )
    ]
