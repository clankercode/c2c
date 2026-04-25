open Alcotest

let contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let test_stale_origin_warning_absent_when_not_ahead () =
  check (option string) "no warning"
    None
    (C2c_worktree.stale_origin_warning ~local_master_ahead:0)

let test_stale_origin_warning_mentions_risk_when_ahead () =
  match C2c_worktree.stale_origin_warning ~local_master_ahead:7 with
  | None -> fail "expected stale origin warning"
  | Some msg ->
      check bool "mentions origin/master" true (contains msg "origin/master");
      check bool "mentions commit count" true (contains msg "7 commit(s)");
      check bool "mentions branch behavior" true (contains msg "will still branch");
      check bool "mentions conflicts" true (contains msg "conflicts")

let () =
  run "c2c_worktree"
    [ ( "stale_origin_warning",
        [ test_case "absent when local master is not ahead" `Quick
            test_stale_origin_warning_absent_when_not_ahead
        ; test_case "mentions risk when local master is ahead" `Quick
            test_stale_origin_warning_mentions_risk_when_ahead
        ] )
    ]
