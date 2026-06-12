(* Tests for #386: c2c doctor opencode-plugin-drift debug-log double-boot scan.

   Mirrors test_c2c_opencode_install patterns from #340a (referenced in the
   slice spec). Exercises only the new debug-log scan; the existing
   symlink/drift logic is covered elsewhere. *)

open Alcotest

let ( // ) = Filename.concat

let contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let with_tmp_dir f =
  let dir = Filename.temp_file "c2c-drift-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () ->
    let rec rm p =
      try
        let st = Unix.lstat p in
        match st.Unix.st_kind with
        | Unix.S_DIR ->
            Array.iter (fun e -> rm (Filename.concat p e)) (Sys.readdir p);
            Unix.rmdir p
        | _ -> Unix.unlink p
      with Unix.Unix_error _ -> ()
    in
    rm dir)
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let mkdir_p path =
  let rec loop dir =
    if dir <> "" && not (Sys.file_exists dir) then begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o700
    end
  in
  loop path

(* Build a boot-line in the exact format emitted by data/opencode-plugin/c2c.ts:217
   so a regression in the producer surfaces as a parse failure here. *)
let boot_line ~ts ~pid ~sha ~path =
  Printf.sprintf "[%s] pid=%d === c2c plugin boot sha=%s path=%s ===" ts pid sha path

let test_double_boot_detection_no_log_returns_ok () =
  with_tmp_dir (fun dir ->
    let log = Filename.concat dir "c2c-debug.log" in
    (* No file written. *)
    match C2c_opencode_plugin_drift.check_debug_log_double_boot ~log_path:log () with
    | Ok () -> ()
    | Error msg -> failf "expected Ok for missing log, got Error: %s" msg)

let test_double_boot_detection_clean_log_returns_ok () =
  with_tmp_dir (fun dir ->
    let log = Filename.concat dir "c2c-debug.log" in
    let lines =
      [ boot_line ~ts:"2026-04-28T00:00:00Z" ~pid:101 ~sha:"abc123" ~path:"/home/u/.opencode/plugins/c2c.ts"
      ; boot_line ~ts:"2026-04-28T00:01:00Z" ~pid:102 ~sha:"abc123" ~path:"/home/u/.opencode/plugins/c2c.ts"
      ; boot_line ~ts:"2026-04-28T00:02:00Z" ~pid:103 ~sha:"abc123" ~path:"/home/u/.opencode/plugins/c2c.ts"
      ]
    in
    write_file log (String.concat "\n" lines ^ "\n");
    match C2c_opencode_plugin_drift.check_debug_log_double_boot ~log_path:log () with
    | Ok () -> ()
    | Error msg -> failf "expected Ok for clean log, got Error: %s" msg)

let test_double_boot_detection_dup_pid_returns_warning () =
  with_tmp_dir (fun dir ->
    let log = Filename.concat dir "c2c-debug.log" in
    let lines =
      [ boot_line ~ts:"2026-04-28T00:00:00Z" ~pid:101
          ~sha:"abc123" ~path:"/home/u/.opencode/plugins/c2c.ts"
      ; boot_line ~ts:"2026-04-28T00:00:01Z" ~pid:101
          ~sha:"abc123" ~path:"/home/u/.bun/install/cache/foo/c2c.ts"
      ; boot_line ~ts:"2026-04-28T00:01:00Z" ~pid:202
          ~sha:"abc123" ~path:"/home/u/.opencode/plugins/c2c.ts"
      ]
    in
    write_file log (String.concat "\n" lines ^ "\n");
    match C2c_opencode_plugin_drift.check_debug_log_double_boot ~log_path:log () with
    | Ok () -> fail "expected Error for duplicate pid boot"
    | Error msg ->
        check bool "mentions DOUBLE-BOOT" true (contains msg "DOUBLE-BOOT");
        check bool "mentions pid 101" true (contains msg "101");
        check bool "lists first path" true
          (contains msg "/home/u/.opencode/plugins/c2c.ts");
        check bool "lists second path" true
          (contains msg "/home/u/.bun/install/cache/foo/c2c.ts");
        (* pid 202 had only one boot — should NOT be flagged. *)
        check bool "does not flag pid 202" false (contains msg "pid=202"))

let test_deployed_path_is_project_local_even_when_global_exists () =
  with_tmp_dir (fun dir ->
    let home = Filename.concat dir "home" in
    let project_plugin = dir // ".opencode" // "plugins" // "c2c.ts" in
    let global_plugin =
      home // ".config" // "opencode" // "plugins" // "c2c.ts"
    in
    mkdir_p (Filename.dirname project_plugin);
    mkdir_p (Filename.dirname global_plugin);
    write_file project_plugin "project";
    write_file global_plugin "global";
    check string "project-local plugin path wins"
      project_plugin
      (C2c_opencode_plugin_drift.deployed_path_for ~cwd:dir ()))

let test_missing_project_local_ignores_global_plugin () =
  with_tmp_dir (fun dir ->
    let home = Filename.concat dir "home" in
    let project_plugin = dir // ".opencode" // "plugins" // "c2c.ts" in
    let global_plugin =
      home // ".config" // "opencode" // "plugins" // "c2c.ts"
    in
    mkdir_p (Filename.dirname global_plugin);
    write_file global_plugin C2c_opencode_plugin_embedded.content;
    let code, msg = C2c_opencode_plugin_drift.check_plugin_drift ~cwd:dir () in
    check int "missing project-local plugin reports missing" 1 code;
    check bool "reports project-local path" true (contains msg project_plugin);
    check bool "does not report global path" false (contains msg global_plugin))

let test_embedded_regular_file_ok_without_canonical () =
  with_tmp_dir (fun dir ->
    let plugin = dir // ".opencode" // "plugins" // "c2c.ts" in
    mkdir_p (Filename.dirname plugin);
    write_file plugin C2c_opencode_plugin_embedded.content;
    let code, msg = C2c_opencode_plugin_drift.check_plugin_drift ~cwd:dir () in
    check int "embedded regular-file copy is OK without data/" 0 code;
    check bool "mentions embedded blob" true (contains msg "embedded blob"))

let () =
  run "c2c_opencode_plugin_drift"
    [ ( "debug_log_double_boot",
        [ test_case "no_log_returns_ok" `Quick test_double_boot_detection_no_log_returns_ok
        ; test_case "clean_log_returns_ok" `Quick test_double_boot_detection_clean_log_returns_ok
        ; test_case "dup_pid_returns_warning" `Quick test_double_boot_detection_dup_pid_returns_warning
        ] )
    ; ( "project_local_drift",
        [ test_case "deployed_path_is_project_local_even_when_global_exists" `Quick
            test_deployed_path_is_project_local_even_when_global_exists
        ; test_case "missing_project_local_ignores_global_plugin" `Quick
            test_missing_project_local_ignores_global_plugin
        ; test_case "embedded_regular_file_ok_without_canonical" `Quick
            test_embedded_regular_file_ok_without_canonical
        ] )
    ]
