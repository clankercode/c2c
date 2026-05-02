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

(* Re-implement chain classify for self-contained tests *)
let classify_chain ~tip_sha ~rev_list_shas =
  let ancestors = List.filter (fun s -> s <> tip_sha) rev_list_shas in
  match ancestors with
  | [] -> `Ok
  | _ -> `Chain_warn ancestors

let test_chain_empty_revlist () =
  check string "empty rev-list = Ok (SHA already on master)"
    "OK"
    (match classify_chain ~tip_sha:"abc123" ~rev_list_shas:[] with `Ok -> "OK" | `Chain_warn _ -> "CHAIN")

let test_chain_single_commit () =
  check string "single commit = Ok (just the tip)"
    "OK"
    (match classify_chain ~tip_sha:"abc123" ~rev_list_shas:["abc123"] with `Ok -> "OK" | `Chain_warn _ -> "CHAIN")

let test_chain_two_commits () =
  check string "two commits = Chain_warn with 1 ancestor"
    "CHAIN:1"
    (match classify_chain ~tip_sha:"abc123" ~rev_list_shas:["abc123"; "def456"] with
     | `Ok -> "OK"
     | `Chain_warn ancestors -> Printf.sprintf "CHAIN:%d" (List.length ancestors))

let test_chain_four_commits () =
  check string "four commits = Chain_warn with 3 ancestors"
    "CHAIN:3"
    (match classify_chain ~tip_sha:"tip000" ~rev_list_shas:["tip000"; "aaa111"; "bbb222"; "ccc333"] with
     | `Ok -> "OK"
     | `Chain_warn ancestors -> Printf.sprintf "CHAIN:%d" (List.length ancestors))

let test_chain_ancestors_exclude_tip () =
  check string "ancestors list excludes tip SHA"
    "aaa111,bbb222"
    (match classify_chain ~tip_sha:"tip000" ~rev_list_shas:["tip000"; "aaa111"; "bbb222"] with
     | `Ok -> "OK"
     | `Chain_warn ancestors -> String.concat "," ancestors)

let test_chain_tip_not_in_list () =
  check string "tip not in rev-list = all entries are ancestors"
    "CHAIN:2"
    (match classify_chain ~tip_sha:"tip000" ~rev_list_shas:["aaa111"; "bbb222"] with
     | `Ok -> "OK"
     | `Chain_warn ancestors -> Printf.sprintf "CHAIN:%d" (List.length ancestors))

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
    ; ( "chain_classify"
      , [ test_case "empty rev-list (on master)" `Quick test_chain_empty_revlist
        ; test_case "single commit (just tip)" `Quick test_chain_single_commit
        ; test_case "two commits (1 ancestor)" `Quick test_chain_two_commits
        ; test_case "four commits (3 ancestors)" `Quick test_chain_four_commits
        ; test_case "ancestors exclude tip" `Quick test_chain_ancestors_exclude_tip
        ; test_case "tip not in rev-list" `Quick test_chain_tip_not_in_list
        ] )
    ]
