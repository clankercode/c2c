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
    | `Meta_dirty ->
        sh "git -C %s worktree add %s origin/master"
          (Filename.quote repo) (Filename.quote wt);
        sh "mkdir -p %s/.sitreps" (Filename.quote wt);
        sh "echo daily > %s/.sitreps/report.md" (Filename.quote wt)
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
    ?(active_window_hours = 0.0) ?(strict_dirt = false)
    ~main_path ~ignore_active wt =
  let prev = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> try Sys.chdir prev with _ -> ())
    (fun () ->
      Sys.chdir wt;
      C2c_worktree.classify_worktree
        ~main_path ~ignore_active ~active_window_hours ~strict_dirt
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
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf "clean+merged should be removable; got REFUSE: %s" reason))

let test_classify_dirty_is_refused () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Dirty in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
          check bool "refuse mentions dirty" true (contains reason "dirty")
      | _ -> fail "dirty should be refused")

let test_classify_meta_dirty_is_removable () =
  (* A worktree dirty only due to .sitreps/ files should be treated as
     clean (meta-ignored) and therefore REMOVABLE when strict_dirt=false. *)
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Meta_dirty in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true ~strict_dirt:false wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRemovable _ -> ()
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf "meta-only dirty should be removable; got: %s" reason))

let test_classify_meta_dirty_strict_is_refused () =
  (* Same situation but with strict_dirt=true → should be REFUSED. *)
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Meta_dirty in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true ~strict_dirt:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason; _ } ->
          check bool "refuse mentions dirty" true (contains reason "dirty")
      | C2c_worktree.GcPossiblyActive { reason } ->
          fail (Printf.sprintf "strict meta-dirty should be refused; got POSSIBLY_ACTIVE: %s" reason)
      | C2c_worktree.GcRemovable _ ->
          fail "strict meta-dirty should be refused, not removable")

let test_classify_ahead_is_refused () =
  with_tmp_dir (fun dir ->
      let (_repo, wt) = make_repo_with_worktree dir `Ahead in
      let c =
        classify_in_worktree ~main_path:None ~ignore_active:true wt
      in
      match c.C2c_worktree.gc_status with
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
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
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
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
      | C2c_worktree.GcRefused { reason; _ } | C2c_worktree.GcPossiblyActive { reason } ->
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
      | C2c_worktree.GcRefused { reason; _ } ->
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

(* ── is_meta_only_path ────────────────────────────────────────────────── *)

let test_is_meta_only_path_sitreps () =
  check bool "sitrep path is meta-only" true
    (C2c_worktree.is_meta_only_path ".sitreps/2026-05-05-sitrep.md")

let test_is_meta_only_path_collab_updates () =
  check bool "collab/updates path is meta-only" true
    (C2c_worktree.is_meta_only_path ".collab/updates/2026-04-28-foo.md")

let test_is_meta_only_path_collab_design () =
  check bool "collab/design path is meta-only" true
    (C2c_worktree.is_meta_only_path ".collab/design/2026-04-28-arch.md")

let test_is_meta_only_path_personal_logs () =
  check bool "personal-logs path is meta-only" true
    (C2c_worktree.is_meta_only_path ".c2c/personal-logs/birch-2026-05.log")

let test_is_meta_only_path_memory () =
  check bool "memory path is meta-only" true
    (C2c_worktree.is_meta_only_path ".c2c/memory/my-note.md")

let test_is_meta_only_path_dotgit () =
  check bool ".git/ prefix is meta-only" true
    (C2c_worktree.is_meta_only_path ".git/worktrees/foo")

let test_is_meta_only_path_real_code () =
  check bool "source file is NOT meta-only" false
    (C2c_worktree.is_meta_only_path "src/main.ml")

let test_is_meta_only_path_real_code_nested () =
  check bool "nested source file is NOT meta-only" false
    (C2c_worktree.is_meta_only_path "lib/c2c_worktree.ml")

let test_is_meta_only_path_dotgitignore () =
  (* .gitignore does NOT start with ".git/" so it is NOT meta-only.
     This is a regression test: the function previously checked ".git" (4
     chars) which incorrectly flagged .gitignore as meta-only. *)
  check bool ".gitignore is real code (not meta-only)" false
    (C2c_worktree.is_meta_only_path ".gitignore")

let test_is_meta_only_path_deep_sitreps () =
  check bool "deep sitrep path is meta-only" true
    (C2c_worktree.is_meta_only_path ".sitreps/subdir/2026-05-05.md")

let test_is_meta_only_path_volumes_dir () =
  (* volumes/ is a Docker/compose directory, not user code *)
  check bool "volumes/ prefix is meta-only" true
    (C2c_worktree.is_meta_only_path "volumes/data/db.sqlite")

let test_is_meta_only_path_build_dir () =
  (* _build/ is Dune's output directory, not user code *)
  check bool "_build/ prefix is meta-only" true
    (C2c_worktree.is_meta_only_path "_build/default/ocaml/cli/c2c.exe")

let test_is_meta_only_path_log_suffix () =
  check bool ".log suffix is meta-only" true
    (C2c_worktree.is_meta_only_path "server.log")

let test_is_meta_only_path_lock_suffix () =
  check bool ".lock suffix is meta-only" true
    (C2c_worktree.is_meta_only_path "yarn.lock")

let test_is_meta_only_path_bak_suffix () =
  check bool ".bak suffix is meta-only" true
    (C2c_worktree.is_meta_only_path "backup.bak")

let test_is_meta_only_path_volumes_false () =
  (* "volumes" appears mid-path but is NOT the volumes/ prefix *)
  check bool "src/volumes_helper.ml is NOT meta-only" false
    (C2c_worktree.is_meta_only_path "src/volumes_helper.ml")

let test_is_meta_only_path_build_false () =
  (* "build/" is not "_build/" — must be exact prefix match *)
  check bool "build/output.js is NOT meta-only" false
    (C2c_worktree.is_meta_only_path "build/output.js")

(* ── is_meta_commit ───────────────────────────────────────────────────── *)

let test_is_meta_commit_sitrep () =
  check bool "sitrep subject is meta" true
    (C2c_worktree.is_meta_commit "sitrep: 14 UTC May 4 — quiet hour")

let test_is_meta_commit_sitrep_uppercase () =
  check bool "Sitrep (capital) is meta" true
    (C2c_worktree.is_meta_commit "Sitrep: morning check")

let test_is_meta_commit_docs () =
  check bool "docs subject is meta" true
    (C2c_worktree.is_meta_commit "docs: update runbook for GC")

let test_is_meta_commit_chore () =
  check bool "chore subject is meta" true
    (C2c_worktree.is_meta_commit "chore: bump version")

let test_is_meta_commit_findings () =
  check bool "findings subject is meta" true
    (C2c_worktree.is_meta_commit "findings: stale binary after install")

let test_is_meta_commit_wip_colon () =
  check bool "wip: subject is meta" true
    (C2c_worktree.is_meta_commit "wip: checkpoint before rebase")

let test_is_meta_commit_wip_paren () =
  check bool "wip(coord subject is meta" true
    (C2c_worktree.is_meta_commit "wip(coord): partial sitrep")

let test_is_meta_commit_add_collab () =
  check bool "add .collab/ is meta" true
    (C2c_worktree.is_meta_commit "add .collab/design/new-doc.md")

let test_is_meta_commit_update_docs () =
  check bool "update docs is meta" true
    (C2c_worktree.is_meta_commit "update docs/index.md with new section")

let test_is_meta_commit_design () =
  check bool "design subject is meta" true
    (C2c_worktree.is_meta_commit "design: worktree GC commit safety")

let test_is_meta_commit_feat_not_meta () =
  check bool "feat(...) is NOT meta" false
    (C2c_worktree.is_meta_commit "feat(gc): add --verbose flag")

let test_is_meta_commit_fix_not_meta () =
  check bool "fix(...) is NOT meta" false
    (C2c_worktree.is_meta_commit "fix(start): remove duplicate fd helpers")

let test_is_meta_commit_refactor_not_meta () =
  check bool "refactor is NOT meta" false
    (C2c_worktree.is_meta_commit "refactor(broker): simplify enqueue path")

let test_is_meta_commit_test_not_meta () =
  check bool "test(...) is NOT meta" false
    (C2c_worktree.is_meta_commit "test(#331): MCP memory integration test")

let test_is_meta_commit_empty () =
  check bool "empty string is NOT meta" false
    (C2c_worktree.is_meta_commit "")

(* ── strip_conventional_prefix ─────────────────────────────────────────── *)

let strip = C2c_worktree.strip_conventional_prefix

let test_strip_conv_prefix_scopeless () =
  check string "fix: message → message"
    "message" (strip "fix: message");
  check string "feat: message → message"
    "message" (strip "feat: message");
  check string "refactor: message → message"
    "message" (strip "refactor: message")

let test_strip_conv_prefix_scoped () =
  check string "fix(gc): message → message"
    "message" (strip "fix(gc): message");
  check string "feat(worktree): add heuristic → add heuristic"
    "add heuristic" (strip "feat(worktree): add heuristic");
  check string "chore(docs): update readme → update readme"
    "update readme" (strip "chore(docs): update readme")

let test_strip_conv_prefix_uppercase () =
  (* case-insensitive *)
  check string "FIX(scope): msg → msg"
    "msg" (strip "FIX(scope): msg");
  check string "Feat(gc): body → body"
    "body" (strip "Feat(gc): body")

let test_strip_conv_prefix_no_match () =
  check string "sitrep: 14 UTC May 5 → unchanged"
    "sitrep: 14 UTC May 5" (strip "sitrep: 14 UTC May 5");
  check string "wip: draft → unchanged"
    "wip: draft" (strip "wip: draft")

(* ── sha_count_map_of_refused ─────────────────────────────────────────── *)

let make_gc_candidate path branch size status =
  { C2c_worktree.gc_path = path
  ; C2c_worktree.gc_branch = branch
  ; C2c_worktree.gc_size = size
  ; C2c_worktree.gc_status = status }

(* 40-char SHA for use in unmerged_commits — deterministic, different per [n] *)
let sha40 n =
  let buf = Buffer.create 40 in
  for i = 0 to 39 do
    let nibble = (n lsr (i * 4)) land 15 in
    let c = match nibble with
      | 0 -> '0' | 1 -> '1' | 2 -> '2' | 3 -> '3'
      | 4 -> '4' | 5 -> '5' | 6 -> '6' | 7 -> '7'
      | 8 -> '8' | 9 -> '9' | 10 -> 'a' | 11 -> 'b'
      | 12 -> 'c' | 13 -> 'd' | 14 -> 'e' | 15 -> 'f'
    in
    Buffer.add_char buf c
  done;
  Buffer.contents buf

let test_sha_count_map_empty () =
  let map = C2c_worktree.sha_count_map_of_refused [] in
  check int "empty candidates → empty map" 0 (Hashtbl.length map)

let test_sha_count_map_single_commit () =
  let c = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let map = C2c_worktree.sha_count_map_of_refused [c] in
  check int "1 candidate, 1 commit → count=1" 1 (Hashtbl.find map (sha40 1))

let test_sha_count_map_same_sha_two_worktrees () =
  (* Same SHA appears in two worktrees → count=2 *)
  let c1 = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let c2 = make_gc_candidate "/path/wt2" "slice/bar" 2000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let map = C2c_worktree.sha_count_map_of_refused [c1; c2] in
  check int "same SHA in 2 worktrees → count=2" 2 (Hashtbl.find map (sha40 1))

let test_sha_count_map_different_shard () =
  let c1 = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let c2 = make_gc_candidate "/path/wt2" "slice/bar" 2000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 2, "fix: bar"] })
  in
  let map = C2c_worktree.sha_count_map_of_refused [c1; c2] in
  check int "2 different SHAs → map size=2" 2 (Hashtbl.length map);
  check int "sha1 → count=1" 1 (Hashtbl.find map (sha40 1));
  check int "sha2 → count=1" 1 (Hashtbl.find map (sha40 2))

let test_sha_count_map_skips_non_refused () =
  (* GcRemovable and GcPossiblyActive entries are skipped *)
  let refused = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let removable = make_gc_candidate "/path/wt2" "slice/bar" 2000L
    (C2c_worktree.GcRemovable { reason = "clean" })
  in
  let possibly_active = make_gc_candidate "/path/wt3" "slice/baz" 3000L
    (C2c_worktree.GcPossiblyActive { reason = "fresh setup" })
  in
  let map = C2c_worktree.sha_count_map_of_refused [refused; removable; possibly_active] in
  check int "only GcRefused contributes entries" 1 (Hashtbl.length map);
  check int "sha1 count still 1" 1 (Hashtbl.find map (sha40 1))

(* ── deduplicate_shared_orphans ──────────────────────────────────────── *)

let test_dedup_threshold_zero_passes_through () =
  (* threshold=0 disables the feature — all candidates pass through unchanged *)
  let c1 = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:0 [c1] in
  match result with
  | [c] ->
      (match c.C2c_worktree.gc_status with
       | C2c_worktree.GcRefused _ -> ()
       | _ -> fail "threshold=0 should leave GcRefused unchanged")
  | _ -> fail "threshold=0 should return same count"

let test_dedup_threshold_negative_passes_through () =
  let c = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:(-1) [c] in
  match result with
  | [x] ->
      (match x.C2c_worktree.gc_status with
       | C2c_worktree.GcRefused _ -> ()
       | _ -> fail "negative threshold should leave GcRefused unchanged")
  | _ -> fail "negative threshold should return same count"

let test_dedup_all_orphans_reclassified () =
  (* SHA appears in 3 worktrees, threshold=5 → all orphans (3 > 5 is FALSE)
     Actually: 3 > 5 is false, so NOT reclassified. Let me use threshold=2:
     3 > 2 is true → reclassified. *)
  let make_c path =
    make_gc_candidate path "slice/foo" 1000L
      (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "sitrep: update"] })
  in
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:2 [make_c "/w1"; make_c "/w2"; make_c "/w3"] in
  List.iter (fun c ->
    match c.C2c_worktree.gc_status with
    | C2c_worktree.GcRemovable { reason } ->
        check bool "reason mentions shared-orphan" true
          (contains reason "shared-orphan")
    | _ -> fail "all commits shared (>threshold) → should be GcRemovable"
  ) result

let test_dedup_some_not_all_orphans_kept_refused () =
  (* One worktree has a non-shared SHA → that worktree stays GcRefused *)
  let c1 = make_gc_candidate "/w1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  let c2 = make_gc_candidate "/w2" "slice/bar" 2000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 2, "fix: bar"] })
  in
  let c3 = make_gc_candidate "/w3" "slice/baz" 3000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [sha40 1, "fix: foo"] })
  in
  (* sha1 appears in 2 worktrees (w1,w3), threshold=2: 2>2 is FALSE
     → sha1 is NOT a shared orphan → w1 and w3 stay refused *)
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:2 [c1; c2; c3] in
  let refused_count = List.fold_left (fun n c ->
    match c.C2c_worktree.gc_status with
    | C2c_worktree.GcRefused _ -> n + 1
    | _ -> n) 0 result
  in
  (* All 3 stay refused: sha1 count=2, threshold=2, 2>2 is false → not shared.
     Layer 2 (meta-only) also fails because /w1 /w2 /w3 don't exist on disk
     so commit_touches_noncode_paths returns false. *)
  check int "all 3 stay refused (sha1 not orphan at threshold=2, Layer 2 fails on fake paths)" 3 refused_count

let test_dedup_empty_unmerged_commits_unchanged () =
  let c = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRefused { reason = "ahead"; unmerged_commits = [] })
  in
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:5 [c] in
  match result with
  | [x] ->
      (match x.C2c_worktree.gc_status with
       | C2c_worktree.GcRefused _ -> ()
       | _ -> fail "empty unmerged_commits should stay GcRefused")
  | _ -> fail "empty unmerged should return same count"

let test_dedup_non_refused_unchanged () =
  let c = make_gc_candidate "/path/wt1" "slice/foo" 1000L
    (C2c_worktree.GcRemovable { reason = "clean" })
  in
  let result = C2c_worktree.deduplicate_shared_orphans ~threshold:5 [c] in
  match result with
  | [x] ->
      (match x.C2c_worktree.gc_status with
       | C2c_worktree.GcRemovable _ -> ()
       | _ -> fail "GcRemovable should stay GcRemovable")
  | _ -> fail "non-refused should return same count"

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
        ; test_case "meta-only dirty → REMOVABLE (strict_dirt=false)" `Quick
            test_classify_meta_dirty_is_removable
        ; test_case "meta-only dirty → REFUSE (strict_dirt=true)" `Quick
            test_classify_meta_dirty_strict_is_refused
        ] )
    ; ( "gc_json",
        [ test_case "json_of_int64 small → `Int" `Quick
            test_json_of_int64_small_is_int
        ; test_case "json_of_int64 large → numeric (not `String)" `Quick
            test_json_of_int64_large_is_numeric
        ] )
    ; ( "is_meta_only_path",
        [ test_case ".sitreps/ path → true" `Quick
            test_is_meta_only_path_sitreps
        ; test_case ".collab/updates/ path → true" `Quick
            test_is_meta_only_path_collab_updates
        ; test_case ".collab/design/ path → true" `Quick
            test_is_meta_only_path_collab_design
        ; test_case ".c2c/personal-logs/ path → true" `Quick
            test_is_meta_only_path_personal_logs
        ; test_case ".c2c/memory/ path → true" `Quick
            test_is_meta_only_path_memory
        ; test_case ".git prefix → true" `Quick
            test_is_meta_only_path_dotgit
        ; test_case "src/ file → false" `Quick
            test_is_meta_only_path_real_code
        ; test_case "lib/ nested file → false" `Quick
            test_is_meta_only_path_real_code_nested
        ; test_case ".gitignore → false (not .git/)" `Quick
            test_is_meta_only_path_dotgitignore
        ; test_case "deep .sitreps/ path → true" `Quick
            test_is_meta_only_path_deep_sitreps
        ; test_case "volumes/ prefix → true" `Quick
            test_is_meta_only_path_volumes_dir
        ; test_case "_build/ prefix → true" `Quick
            test_is_meta_only_path_build_dir
        ; test_case ".log suffix → true" `Quick
            test_is_meta_only_path_log_suffix
        ; test_case ".lock suffix → true" `Quick
            test_is_meta_only_path_lock_suffix
        ; test_case ".bak suffix → true" `Quick
            test_is_meta_only_path_bak_suffix
        ; test_case "src/volumes_helper.ml → false (not prefix)" `Quick
            test_is_meta_only_path_volumes_false
        ; test_case "build/output.js → false (not _build/)" `Quick
            test_is_meta_only_path_build_false
        ] )
    ; ( "is_meta_commit",
        [ test_case "sitrep subject" `Quick
            test_is_meta_commit_sitrep
        ; test_case "Sitrep uppercase" `Quick
            test_is_meta_commit_sitrep_uppercase
        ; test_case "docs subject" `Quick
            test_is_meta_commit_docs
        ; test_case "chore subject" `Quick
            test_is_meta_commit_chore
        ; test_case "findings subject" `Quick
            test_is_meta_commit_findings
        ; test_case "wip: subject" `Quick
            test_is_meta_commit_wip_colon
        ; test_case "wip(coord subject" `Quick
            test_is_meta_commit_wip_paren
        ; test_case "add .collab/" `Quick
            test_is_meta_commit_add_collab
        ; test_case "update docs" `Quick
            test_is_meta_commit_update_docs
        ; test_case "design subject" `Quick
            test_is_meta_commit_design
        ; test_case "feat NOT meta" `Quick
            test_is_meta_commit_feat_not_meta
        ; test_case "fix NOT meta" `Quick
            test_is_meta_commit_fix_not_meta
        ; test_case "refactor NOT meta" `Quick
            test_is_meta_commit_refactor_not_meta
        ; test_case "test NOT meta" `Quick
            test_is_meta_commit_test_not_meta
        ; test_case "empty string NOT meta" `Quick
            test_is_meta_commit_empty
        ] )
    ; ( "sha_count_map_of_refused",
        [ test_case "empty candidates → empty map" `Quick
            test_sha_count_map_empty
        ; test_case "single commit → count=1" `Quick
            test_sha_count_map_single_commit
        ; test_case "same SHA in 2 worktrees → count=2" `Quick
            test_sha_count_map_same_sha_two_worktrees
        ; test_case "different SHAs → map size = n" `Quick
            test_sha_count_map_different_shard
        ; test_case "GcRemovable/GcPossiblyActive skipped" `Quick
            test_sha_count_map_skips_non_refused
        ] )
    ; ( "deduplicate_shared_orphans",
        [ test_case "threshold=0 → pass-through unchanged" `Quick
            test_dedup_threshold_zero_passes_through
        ; test_case "negative threshold → pass-through unchanged" `Quick
            test_dedup_threshold_negative_passes_through
        ; test_case "all commits shared (>threshold) → reclassified GcRemovable" `Quick
            test_dedup_all_orphans_reclassified
        ; test_case "some commits NOT shared → stays GcRefused" `Quick
            test_dedup_some_not_all_orphans_kept_refused
        ; test_case "empty unmerged_commits → unchanged" `Quick
            test_dedup_empty_unmerged_commits_unchanged
        ; test_case "non-GcRefused → unchanged" `Quick
            test_dedup_non_refused_unchanged
        ] )
    ; ( "strip_conventional_prefix",
        [ test_case "fix: message → message" `Quick
            test_strip_conv_prefix_scopeless
        ; test_case "fix(gc): message → message" `Quick
            test_strip_conv_prefix_scoped
        ; test_case "FIX(scope): msg → msg (case-insensitive)" `Quick
            test_strip_conv_prefix_uppercase
        ; test_case "sitrep: 14 UTC May 5 → unchanged (no match)" `Quick
            test_strip_conv_prefix_no_match
        ] )
    ]
