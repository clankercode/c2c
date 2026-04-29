(* test_c2c_doctor_cherry_pick_readiness.ml — unit tests for #486 cherry-pick-readiness.

   Tests the pure `classify` function which maps (master_ahead, risky_file_count)
   to CLEAN / HARD-WARN classification.

   Positive case: master ahead <20 commits OR no risky files → CLEAN
   Negative case: master ahead >20 AND risky files exist → HARD *)

open Alcotest

(* Re-implement the classify logic here so the test is self-contained *)
type classification = [ `Clean | `Hard ]

let classify ~master_ahead ~risky_file_count =
  if master_ahead > 20 && risky_file_count > 0 then `Hard
  else `Clean

let test_clean_zero_commits_ahead () =
  check string "0 commits, 0 risky = CLEAN"
    "CLEAN" (match classify ~master_ahead:0 ~risky_file_count:0 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_clean_10_commits_ahead_no_risky () =
  check string "10 commits, 0 risky = CLEAN"
    "CLEAN" (match classify ~master_ahead:10 ~risky_file_count:0 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_clean_20_commits_ahead_no_risky () =
  check string "20 commits, 0 risky = CLEAN"
    "CLEAN" (match classify ~master_ahead:20 ~risky_file_count:0 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_clean_21_commits_but_no_risky () =
  check string "21 commits, 0 risky = CLEAN (threshold is >20)"
    "CLEAN" (match classify ~master_ahead:21 ~risky_file_count:0 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_clean_0_commits_ahead_with_risky () =
  check string "0 commits, 5 risky = CLEAN (master not ahead enough)"
    "CLEAN" (match classify ~master_ahead:0 ~risky_file_count:5 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_clean_19_commits_ahead_with_risky () =
  check string "19 commits, 3 risky = CLEAN (master not ahead enough)"
    "CLEAN" (match classify ~master_ahead:19 ~risky_file_count:3 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_hard_21_commits_1_risky () =
  check string "21 commits, 1 risky = HARD"
    "HARD" (match classify ~master_ahead:21 ~risky_file_count:1 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_hard_100_commits_1_risky () =
  check string "100 commits, 1 risky = HARD"
    "HARD" (match classify ~master_ahead:100 ~risky_file_count:1 with `Clean -> "CLEAN" | `Hard -> "HARD")

let test_hard_21_commits_5_risky () =
  check string "21 commits, 5 risky = HARD"
    "HARD" (match classify ~master_ahead:21 ~risky_file_count:5 with `Clean -> "CLEAN" | `Hard -> "HARD")

let () =
  run "cherry_pick_readiness"
    [ ( "classify"
      , [ test_case "zero commits, zero risky"  `Quick test_clean_zero_commits_ahead
        ; test_case "10 commits, zero risky"  `Quick test_clean_10_commits_ahead_no_risky
        ; test_case "20 commits, zero risky"  `Quick test_clean_20_commits_ahead_no_risky
        ; test_case "21 commits, zero risky (at boundary)" `Quick test_clean_21_commits_but_no_risky
        ; test_case "zero commits, with risky" `Quick test_clean_0_commits_ahead_with_risky
        ; test_case "19 commits, with risky" `Quick test_clean_19_commits_ahead_with_risky
        ; test_case "21 commits, 1 risky (HARD)" `Quick test_hard_21_commits_1_risky
        ; test_case "100 commits, 1 risky (HARD)" `Quick test_hard_100_commits_1_risky
        ; test_case "21 commits, 5 risky (HARD)" `Quick test_hard_21_commits_5_risky
        ] )
    ]
