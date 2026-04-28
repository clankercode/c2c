(* Tests for #386: c2c doctor opencode-plugin-drift debug-log double-boot scan.

   Mirrors test_c2c_opencode_install patterns from #340a (referenced in the
   slice spec). Exercises only the new debug-log scan; the existing
   symlink/drift logic is covered elsewhere. *)

open Alcotest

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

let () =
  run "c2c_opencode_plugin_drift"
    [ ( "debug_log_double_boot",
        [ test_case "no_log_returns_ok" `Quick test_double_boot_detection_no_log_returns_ok
        ; test_case "clean_log_returns_ok" `Quick test_double_boot_detection_clean_log_returns_ok
        ; test_case "dup_pid_returns_warning" `Quick test_double_boot_detection_dup_pid_returns_warning
        ] )
    ]
