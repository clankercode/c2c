(* test_git_helpers — unit tests for Git_helpers.
   Focus: is_c2c_shim content-check + find_real_git skip logic. *)

let tmpdir () =
  let base = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_git_helpers_%d" (Unix.getpid ()))
  in
  Unix.mkdir base 0o755;
  base

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Unix.chmod path 0o755

let rmrf dir =
  (* Simple recursive remove for test tmpdir.  Not production-grade;
     good enough for flat test dirs. *)
  let entries = Sys.readdir dir in
  Array.iter (fun name ->
    let p = Filename.concat dir name in
    if Sys.is_directory p then begin
      let sub = Sys.readdir p in
      Array.iter (fun s -> Sys.remove (Filename.concat p s)) sub;
      Unix.rmdir p
    end else Sys.remove p
  ) entries;
  Unix.rmdir dir

(* ── is_c2c_shim ─────────────────────────────────────────── *)

let test_is_shim_positive () =
  let dir = tmpdir () in
  let path = Filename.concat dir "git" in
  write_file path
    ("#!/bin/bash\n" ^
     "# Delegation shim: git attribution for managed sessions.\n" ^
     "exec /usr/bin/git \"$@\"\n");
  Alcotest.(check bool) "shim detected" true
    (Git_helpers.is_c2c_shim path);
  rmrf dir

let test_is_shim_negative () =
  let dir = tmpdir () in
  let path = Filename.concat dir "git" in
  write_file path "#!/bin/bash\nexec /usr/bin/git \"$@\"\n";
  Alcotest.(check bool) "real git not flagged" false
    (Git_helpers.is_c2c_shim path);
  rmrf dir

let test_is_shim_nonexistent () =
  Alcotest.(check bool) "missing file returns false" false
    (Git_helpers.is_c2c_shim "/nonexistent/git")

let test_is_shim_binary_file () =
  let dir = tmpdir () in
  let path = Filename.concat dir "git" in
  (* Write 256 bytes of binary data — no marker present. *)
  let buf = Bytes.create 256 in
  for i = 0 to 255 do Bytes.set buf i (Char.chr (i land 0xFF)) done;
  let oc = open_out_bin path in
  output_bytes oc buf;
  close_out oc;
  Unix.chmod path 0o755;
  Alcotest.(check bool) "binary file not flagged" false
    (Git_helpers.is_c2c_shim path);
  rmrf dir

let test_is_shim_empty_file () =
  let dir = tmpdir () in
  let path = Filename.concat dir "git" in
  write_file path "";
  Alcotest.(check bool) "empty file not flagged" false
    (Git_helpers.is_c2c_shim path);
  rmrf dir

(* ── find_real_git with synthetic PATH ────────────────────── *)

let test_find_real_git_skips_shim () =
  let dir = tmpdir () in
  (* Create two subdirs: one with a shim, one with "real" git. *)
  let shim_dir = Filename.concat dir "shim" in
  let real_dir = Filename.concat dir "real" in
  Unix.mkdir shim_dir 0o755;
  Unix.mkdir real_dir 0o755;
  let shim_git = Filename.concat shim_dir "git" in
  let real_git = Filename.concat real_dir "git" in
  write_file shim_git
    ("#!/bin/bash\n" ^
     "# Delegation shim: git attribution for managed sessions.\n" ^
     "exec '" ^ shim_git ^ "' \"$@\"\n");
  write_file real_git "#!/bin/bash\nexec /usr/bin/git \"$@\"\n";
  (* Set PATH so shim comes first, real comes second.  Unset
     C2C_GIT_SHIM_DIR to exercise the content-check path. *)
  let old_path = Sys.getenv_opt "PATH" in
  let old_shim_dir = Sys.getenv_opt "C2C_GIT_SHIM_DIR" in
  Unix.putenv "PATH" (shim_dir ^ ":" ^ real_dir ^ ":/usr/bin");
  (try Unix.putenv "C2C_GIT_SHIM_DIR" "" with _ -> ());
  let result = Git_helpers.find_real_git () in
  (* Restore. *)
  (match old_path with
   | Some p -> Unix.putenv "PATH" p
   | None -> ());
  (match old_shim_dir with
   | Some d -> Unix.putenv "C2C_GIT_SHIM_DIR" d
   | None -> ());
  Alcotest.(check string) "skipped shim, found real" real_git result;
  rmrf dir

let test_find_real_git_fallback () =
  let dir = tmpdir () in
  (* Only shim on PATH — should fall through to /usr/bin/git. *)
  let shim_dir = Filename.concat dir "shim" in
  Unix.mkdir shim_dir 0o755;
  write_file (Filename.concat shim_dir "git")
    ("#!/bin/bash\n" ^
     "# Delegation shim: git attribution for managed sessions.\n" ^
     "exec /usr/bin/git \"$@\"\n");
  let old_path = Sys.getenv_opt "PATH" in
  let old_shim_dir = Sys.getenv_opt "C2C_GIT_SHIM_DIR" in
  Unix.putenv "PATH" shim_dir;
  (try Unix.putenv "C2C_GIT_SHIM_DIR" "" with _ -> ());
  let result = Git_helpers.find_real_git () in
  (match old_path with
   | Some p -> Unix.putenv "PATH" p
   | None -> ());
  (match old_shim_dir with
   | Some d -> Unix.putenv "C2C_GIT_SHIM_DIR" d
   | None -> ());
  Alcotest.(check string) "fell back to /usr/bin/git" "/usr/bin/git" result;
  rmrf dir

(* ── marker string consistency ────────────────────────────── *)

let test_shim_marker_value () =
  (* Ensure the marker constant matches what c2c_start writes.
     If someone changes the shim template without updating
     Git_helpers.shim_marker, this test catches the drift. *)
  Alcotest.(check bool) "marker contains 'Delegation shim'" true
    (let m = Git_helpers.shim_marker in
     String.length m > 0 &&
     String.sub m 0 (min (String.length m) 18) = "# Delegation shim:")

let () =
  Alcotest.run "git_helpers" [
    "is_c2c_shim", [
      Alcotest.test_case "positive — shim with marker" `Quick
        test_is_shim_positive;
      Alcotest.test_case "negative — plain script" `Quick
        test_is_shim_negative;
      Alcotest.test_case "nonexistent file" `Quick
        test_is_shim_nonexistent;
      Alcotest.test_case "binary file" `Quick
        test_is_shim_binary_file;
      Alcotest.test_case "empty file" `Quick
        test_is_shim_empty_file;
    ];
    "find_real_git", [
      Alcotest.test_case "skips shim on PATH (content-check)" `Quick
        test_find_real_git_skips_shim;
      Alcotest.test_case "falls back to /usr/bin/git" `Quick
        test_find_real_git_fallback;
    ];
    "marker", [
      Alcotest.test_case "marker value" `Quick
        test_shim_marker_value;
    ];
  ]
