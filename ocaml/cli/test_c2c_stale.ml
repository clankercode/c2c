(* Unit tests for C2c_stale — the version-aware staleness primitive (I010). *)

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)

let tmp_file ~suffix contents =
  let path = Filename.temp_file "c2c_stale_test" suffix in
  write_file path contents;
  path

let verdict_testable =
  Alcotest.testable
    (fun ppf v -> Format.pp_print_string ppf (C2c_stale.verdict_label v))
    (fun a b ->
      match (a, b) with
      | C2c_stale.Current, C2c_stale.Current
      | C2c_stale.Stale, C2c_stale.Stale ->
          true
      | C2c_stale.Unknown _, C2c_stale.Unknown _ -> true
      | _ -> false)

let test_same_path_is_current () =
  (* A path compared against itself: same inode -> Current, no hashing. *)
  let f = tmp_file ~suffix:".bin" "identical-image-bytes" in
  Alcotest.check verdict_testable "same inode is current" C2c_stale.Current
    (C2c_stale.compare_images ~target:f ~installed:f)

let test_identical_content_diff_inode_is_current () =
  (* install-all rm+cp mints a new inode even when the code is unchanged; the
     content hash must recognise that as Current, not a needless restart. *)
  let a = tmp_file ~suffix:".bin" "same-bytes-two-files" in
  let b = tmp_file ~suffix:".bin" "same-bytes-two-files" in
  Alcotest.check verdict_testable "identical content across inodes is current"
    C2c_stale.Current
    (C2c_stale.compare_images ~target:a ~installed:b)

let test_different_content_same_size_is_stale () =
  (* Same length, different bytes -> size fast path can't decide, hash does. *)
  let a = tmp_file ~suffix:".bin" "AAAAAAAA" in
  let b = tmp_file ~suffix:".bin" "BBBBBBBB" in
  Alcotest.check verdict_testable "different content is stale" C2c_stale.Stale
    (C2c_stale.compare_images ~target:a ~installed:b)

let test_different_size_is_stale () =
  let a = tmp_file ~suffix:".bin" "short" in
  let b = tmp_file ~suffix:".bin" "a much longer image than the other one" in
  Alcotest.check verdict_testable "different size is stale" C2c_stale.Stale
    (C2c_stale.compare_images ~target:a ~installed:b)

let test_missing_target_is_unknown () =
  let installed = tmp_file ~suffix:".bin" "present" in
  Alcotest.check verdict_testable "missing target is unknown"
    (C2c_stale.Unknown "")
    (C2c_stale.compare_images ~target:"/nonexistent/c2c-stale-target"
       ~installed)

let test_missing_installed_is_unknown () =
  let target = tmp_file ~suffix:".bin" "present" in
  Alcotest.check verdict_testable "missing installed is unknown"
    (C2c_stale.Unknown "")
    (C2c_stale.compare_images ~target
       ~installed:"/nonexistent/c2c-stale-installed")

let test_classify_self_is_current () =
  (* The running process compared against its own /proc/self/exe: same inode. *)
  Alcotest.check verdict_testable "self is current" C2c_stale.Current
    (C2c_stale.classify ~installed_exe:"/proc/self/exe" (Unix.getpid ()))

let test_classify_dead_pid_is_unknown () =
  (* Fork a child that exits immediately, reap it, then classify its pid: its
     /proc/<pid>/exe is gone -> Unknown (skipped safely). *)
  let pid = Unix.fork () in
  if pid = 0 then Unix._exit 0
  else begin
    ignore (Unix.waitpid [] pid);
    (* Give the kernel a moment to tear down /proc/<pid>. *)
    Unix.sleepf 0.05;
    Alcotest.check verdict_testable "dead pid is unknown"
      (C2c_stale.Unknown "")
      (C2c_stale.classify ~installed_exe:"/proc/self/exe" pid)
  end

let () =
  Alcotest.run "c2c_stale"
    [ ( "compare_images",
        [ Alcotest.test_case "same path is current" `Quick
            test_same_path_is_current;
          Alcotest.test_case "identical content, different inode is current"
            `Quick test_identical_content_diff_inode_is_current;
          Alcotest.test_case "different content is stale" `Quick
            test_different_content_same_size_is_stale;
          Alcotest.test_case "different size is stale" `Quick
            test_different_size_is_stale;
          Alcotest.test_case "missing target is unknown" `Quick
            test_missing_target_is_unknown;
          Alcotest.test_case "missing installed is unknown" `Quick
            test_missing_installed_is_unknown ] );
      ( "classify",
        [ Alcotest.test_case "self is current" `Quick
            test_classify_self_is_current;
          Alcotest.test_case "dead pid is unknown" `Quick
            test_classify_dead_pid_is_unknown ] )
    ]
