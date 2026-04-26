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

(* --- #313 worktree-gc tests --- *)

let sh fmt =
  Printf.ksprintf (fun cmd ->
      let code = Sys.command (cmd ^ " >/dev/null 2>&1") in
      if code <> 0 then
        failwith (Printf.sprintf "shell command failed (%d): %s" code cmd))
    fmt

(* Build a minimal git repo with refs/remotes/origin/master pointing at
   HEAD (faked via update-ref so we don't need an actual remote), plus
   a worktree branched off origin/master in [wt_state]. *)
let make_repo_with_worktree dir wt_state =
  let repo = Filename.concat dir "repo" in
  let wt = Filename.concat dir "wt" in
  sh "git init -q -b master %s" (Filename.quote repo);
  sh "git -C %s config user.email t@t" (Filename.quote repo);
  sh "git -C %s config user.name t" (Filename.quote repo);
  sh "echo a > %s/f" (Filename.quote repo);
  sh "git -C %s add f" (Filename.quote repo);
  sh "git -C %s commit -q -m a" (Filename.quote repo);
  (* Synthesize origin/master without needing a real remote. *)
  sh "git -C %s update-ref refs/remotes/origin/master HEAD" (Filename.quote repo);
  (match wt_state with
   | `Clean ->
       sh "git -C %s worktree add %s origin/master"
         (Filename.quote repo) (Filename.quote wt)
   | `Dirty ->
       sh "git -C %s worktree add %s origin/master"
         (Filename.quote repo) (Filename.quote wt);
       sh "echo modified > %s/dirty.txt" (Filename.quote wt)
   | `Ahead ->
       sh "git -C %s worktree add -b ahead %s origin/master"
         (Filename.quote repo) (Filename.quote wt);
       sh "echo b > %s/g" (Filename.quote wt);
       sh "git -C %s add g" (Filename.quote wt);
       sh "git -C %s commit -q -m b" (Filename.quote wt)
   | `Detached_at_origin_master ->
       sh "git -C %s worktree add --detach %s origin/master"
         (Filename.quote repo) (Filename.quote wt));
  (repo, wt)

(* classify_worktree shells out to git inside the candidate path; chdir
   to it so cwd-resolution works, restore cwd on exit. [active_window_hours]
   defaults to 0.0 which disables the #314 freshness heuristic — the
   #313-era tests don't depend on it; #314 tests pass an explicit value. *)
let classify_in_worktree
    ?(active_window_hours = 0.0) ~main_path ~ignore_active wt =
  let prev = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> try Sys.chdir prev with _ -> ())
    (fun () ->
      Sys.chdir wt;
      C2c_worktree.classify_worktree
        ~main_path ~ignore_active ~active_window_hours
        (Filename.basename wt, wt, ""))

let with_tmp_dir f =
  let tmp = Filename.temp_file "c2c-wt-test-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () -> f tmp)

let test_classify_clean_merged_is_removable () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Clean in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRemovable _ -> ()
      | C2c_worktree.GcRefused { reason } | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf "clean+merged should be removable; got REFUSE: %s" reason))

let test_classify_dirty_is_refused () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Dirty in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason } | C2c_worktree.GcPossiblyActive { reason } ->
          check bool "refuse mentions dirty" true (contains reason "dirty")
      | _ -> fail "dirty should be refused")

let test_classify_ahead_is_refused () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Ahead in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason } | C2c_worktree.GcPossiblyActive { reason } ->
          check bool "refuse mentions ancestor" true
            (contains reason "ancestor of origin/master")
      | _ -> fail "branch-ahead should be refused")

let test_classify_detached_at_origin_master_is_removable () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Detached_at_origin_master in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRemovable _ -> ()
      | C2c_worktree.GcRefused { reason } | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf "detached-at-origin/master should be removable; got REFUSE: %s" reason))

let test_classify_main_worktree_is_refused_even_if_offered () =
  with_tmp_dir (fun dir ->
      let (repo, _wt) = make_repo_with_worktree dir `Clean in
      (* Pretend the candidate IS the main worktree (defense-in-depth
         check inside classify_worktree). *)
      let c =
        classify_in_worktree ~main_path:(Some repo) ~ignore_active:true repo
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason } | C2c_worktree.GcPossiblyActive { reason } ->
          check bool "refuse mentions main worktree" true
            (contains reason "main worktree")
      | _ -> fail "main worktree should never be removable")

(* #314: POSSIBLY_ACTIVE freshness heuristic. *)

let test_possibly_active_when_head_eq_origin_and_within_window () =
  with_tmp_dir (fun dir ->
      (* `Detached_at_origin_master gives HEAD == origin/master HEAD
         exactly. The worktree was just created so admin-dir mtime is
         within any reasonable window. With active_window_hours=2.0 it
         should classify as POSSIBLY_ACTIVE. *)
      let (_repo, wt) = make_repo_with_worktree dir `Detached_at_origin_master in
      let c =
        classify_in_worktree
          ~active_window_hours:2.0 ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcPossiblyActive { reason } ->
          check bool "reason mentions HEAD==origin/master" true
            (contains reason "HEAD==origin/master")
      | _ ->
          fail "fresh detached-at-origin should be POSSIBLY_ACTIVE \
                with active_window_hours=2.0")

(* Regression for lyra's #314 FAIL repro: classify_worktree must
   snapshot admin-dir mtime BEFORE running git commands. is_dirty,
   head_ancestor, and rev-parse all bump admin mtime to "now"; if
   the freshness check stats fresh, an actually-old worktree at
   HEAD==origin/master gets soft-refused as POSSIBLY_ACTIVE. *)
let test_old_worktree_at_origin_classifies_removable_not_possibly_active () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Detached_at_origin_master in
      (* Force the admin-dir mtime older than any reasonable active
         window. The admin dir is at <wt>/.git → "gitdir: <path>". *)
      let admin =
        let dotgit = Filename.concat wt ".git" in
        let ic = open_in dotgit in
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () ->
            let line = input_line ic in
            let prefix = "gitdir: " in
            String.trim
              (String.sub line (String.length prefix)
                 (String.length line - String.length prefix)))
      in
      sh "touch -d '5 hours ago' %s" (Filename.quote admin);
      let c =
        classify_in_worktree
          ~active_window_hours:2.0 ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRemovable _ -> ()
      | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf
                  "5-hours-old admin dir + window=2.0 must be REMOVABLE; \
                   got POSSIBLY_ACTIVE: %s" reason)
      | C2c_worktree.GcRefused { reason } ->
          fail (Printf.sprintf "expected REMOVABLE; got REFUSE: %s" reason))

let test_possibly_active_disabled_when_window_zero () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Detached_at_origin_master in
      (* active_window_hours=0.0 disables the heuristic — should fall
         through to REMOVABLE. *)
      let c =
        classify_in_worktree
          ~active_window_hours:0.0 ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRemovable _ -> ()
      | _ ->
          fail "active_window_hours=0.0 should disable the heuristic — \
                expected REMOVABLE")

let test_json_of_int64_small_is_int () =
  match C2c_worktree.json_of_int64 1234L with
  | `Int 1234 -> ()
  | other ->
      fail (Printf.sprintf "expected `Int 1234, got %s"
              (Yojson.Safe.to_string other))

let test_json_of_int64_large_is_numeric () =
  (* On 63-bit int OCaml, this fits in `Int; on 31-bit it'd be `Intlit.
     Either way, it must NOT be `String. *)
  match C2c_worktree.json_of_int64 100000000000L with
  | `Int _ | `Intlit _ -> ()
  | `String _ -> fail "json_of_int64 must not emit `String"
  | other ->
      fail (Printf.sprintf "unexpected JSON kind: %s"
              (Yojson.Safe.to_string other))

let () =
  run "c2c_worktree"
    [ ( "stale_origin_warning",
        [ test_case "absent when local master is not ahead" `Quick
            test_stale_origin_warning_absent_when_not_ahead
        ; test_case "mentions risk when local master is ahead" `Quick
            test_stale_origin_warning_mentions_risk_when_ahead
        ] )
    ; ( "gc_classify",
        [ test_case "clean + merged → REMOVABLE" `Quick
            test_classify_clean_merged_is_removable
        ; test_case "dirty → REFUSE" `Quick
            test_classify_dirty_is_refused
        ; test_case "branch ahead → REFUSE" `Quick
            test_classify_ahead_is_refused
        ; test_case "detached at origin/master → REMOVABLE" `Quick
            test_classify_detached_at_origin_master_is_removable
        ; test_case "main worktree REFUSE even if offered" `Quick
            test_classify_main_worktree_is_refused_even_if_offered
        ; test_case "fresh HEAD==origin within window → POSSIBLY_ACTIVE (#314)" `Quick
            test_possibly_active_when_head_eq_origin_and_within_window
        ; test_case "active_window_hours=0 disables heuristic (#314)" `Quick
            test_possibly_active_disabled_when_window_zero
        ; test_case "old admin mtime + HEAD==origin → REMOVABLE (#314 lyra regress)" `Quick
            test_old_worktree_at_origin_classifies_removable_not_possibly_active
        ] )
    ; ( "gc_json",
        [ test_case "json_of_int64 small → `Int" `Quick
            test_json_of_int64_small_is_int
        ; test_case "json_of_int64 large → numeric (not `String)" `Quick
            test_json_of_int64_large_is_numeric
        ] )
    ]
