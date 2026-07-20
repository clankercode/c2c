(* test_c2c_list_scope — unit tests for the #74 repo-scope filter helpers.

   Covers the semantics decided for `c2c list`:
   (a) default HIDES a foreign-cwd row;
   (b) default SHOWS a same-repo / subdirectory-cwd row;
   (c) default SHOWS a no-cwd row (fail-open) — and an empty/blank cwd too;
   (d) --all is modelled by simply not calling the filter (all rows show);
   (e) partition_by_scope yields the correct hidden count for the footer.

   The helpers are pure/lexical, so these exercise the real logic directly
   without a broker, a git repo, or the binary. *)

open Alcotest

let scope = "/home/xertrov/src/c2c"

let in_scope ?(scope_dir = scope) row_cwd =
  C2c_list_scope.row_in_scope ~scope_dir ~row_cwd

(* (a) a foreign cwd — a sibling/unrelated directory — is out of scope. *)
let test_foreign_hidden () =
  check bool "unrelated dir out of scope" false
    (in_scope (Some "/home/xertrov/.llm-general/served-html"));
  check bool "sibling under /home/xertrov/src out of scope" false
    (in_scope (Some "/home/xertrov/src/other-repo"));
  (* prefix-but-not-subdir must NOT match: "/home/xertrov/src/c2c-extra". *)
  check bool "prefix sibling is not a subdir" false
    (in_scope (Some "/home/xertrov/src/c2c-extra"))

(* (b) the scope dir itself and any subdirectory are in scope. *)
let test_same_and_subdir_shown () =
  check bool "exact scope dir in scope" true (in_scope (Some scope));
  check bool "trailing slash normalized" true (in_scope (Some (scope ^ "/")));
  check bool "subdir in scope" true (in_scope (Some (scope ^ "/ocaml/cli")));
  check bool "worktree subdir in scope" true
    (in_scope (Some (scope ^ "/.worktrees/fix-74-list-scope")))

(* (c) fail-open: no cwd, empty cwd, and blank cwd are always shown. *)
let test_no_cwd_fail_open () =
  check bool "None cwd shown" true (in_scope None);
  check bool "empty cwd shown" true (in_scope (Some ""));
  check bool "blank cwd shown" true (in_scope (Some "   "));
  (* Fail-open also when the scope dir itself is unknown/empty. *)
  check bool "empty scope dir shows everything" true
    (in_scope ~scope_dir:"" (Some "/anywhere/at/all"))

(* (d) + (e): partition_by_scope splits rows and gives the hidden count that
   feeds the "N agents in other directories hidden" footer. Modelled as
   (name, cwd option) rows so no registration record is needed. *)
let rows =
  [ ("self", Some scope)
  ; ("subdir-peer", Some (scope ^ "/ocaml"))
  ; ("no-cwd-peer", None)
  ; ("blank-peer", Some "")
  ; ("foreign-a", Some "/home/xertrov/.llm-general")
  ; ("foreign-b", Some "/tmp/somewhere")
  ; ("foreign-c", Some "/home/xertrov/src/c2c-extra")
  ]

let test_partition_and_hidden_count () =
  let (shown, hidden) =
    C2c_list_scope.partition_by_scope ~scope_dir:scope ~cwd_of:snd rows
  in
  let names l = List.map fst l in
  check (list string) "shown rows"
    [ "self"; "subdir-peer"; "no-cwd-peer"; "blank-peer" ] (names shown);
  check (list string) "hidden rows"
    [ "foreign-a"; "foreign-b"; "foreign-c" ] (names hidden);
  (* (e) footer count. *)
  check int "hidden count" 3 (List.length hidden);
  (* (d) --all is "do not filter": every row is retained. *)
  check int "all rows without filter" 7 (List.length rows)

let test_normalize_dir () =
  check string "trailing slash stripped" "/a/b"
    (C2c_list_scope.normalize_dir "/a/b/");
  check string "multiple trailing slashes stripped" "/a/b"
    (C2c_list_scope.normalize_dir "/a/b///");
  check string "root preserved" "/" (C2c_list_scope.normalize_dir "/");
  check string "root preserved from multiple slashes" "/"
    (C2c_list_scope.normalize_dir "///");
  check string "whitespace trimmed" "/a/b"
    (C2c_list_scope.normalize_dir "  /a/b  ")

let () =
  run "c2c_list_scope"
    [ ( "row_in_scope",
        [ test_case "foreign hidden" `Quick test_foreign_hidden;
          test_case "same + subdir shown" `Quick test_same_and_subdir_shown;
          test_case "no-cwd fail-open" `Quick test_no_cwd_fail_open ] );
      ( "partition",
        [ test_case "partition + hidden count" `Quick
            test_partition_and_hidden_count ] );
      ( "normalize_dir",
        [ test_case "normalize" `Quick test_normalize_dir ] )
    ]
