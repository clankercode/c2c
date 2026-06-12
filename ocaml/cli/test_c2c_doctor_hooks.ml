(* test_c2c_doctor_hooks.ml — unit tests for `c2c doctor hooks`.

   These tests never touch real HOME or real Claude config dirs. They:
   - set C2C_DOCTOR_CLAUDE_DIRS to point at temp dirs,
   - create synthetic settings.json / settings.local.json files,
   - exercise dangling detection, symlink resolution, malformed JSON skipping,
     non-c2c filtering, and multi-dir aggregation.

   Because the check is read-only and self-contained, no fixture env var is
   required to enable it; the temp-dir override is the guard. *)

open Alcotest

let ( // ) = Filename.concat

let with_tmp_dir f =
  let parent = Filename.get_temp_dir_name () // "c2c_doctor_hooks_test" in
  C2c_io.mkdir_p parent;
  let dir =
    Printf.sprintf "%s/dir-%d-%d-%d" parent (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1_000_000.)) (Random.int 1_000_000)
  in
  C2c_io.mkdir_p dir;
  Fun.protect ~finally:(fun () ->
    (* best-effort cleanup; leave artifacts behind only on failure *)
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let write_file path content =
  C2c_io.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)

let settings_json event command =
  Printf.sprintf {|{
  "hooks": {
    "%s": [
      {
        "matcher": "^(?!mcp__).*",
        "hooks": [
          { "type": "command", "command": "%s" }
        ]
      }
    ]
  }
}|} event command

let set_claude_dirs dirs =
  let value = String.concat ":" dirs in
  Unix.putenv "C2C_DOCTOR_CLAUDE_DIRS" value

let run_check dirs =
  set_claude_dirs dirs;
  C2c_doctor_hooks.check ~dirs ()

let test_missing_c2c_hook_reported () =
  with_tmp_dir (fun dir ->
    let missing = dir // "c2c-inbox-check.sh" in
    write_file (dir // "settings.json") (settings_json "PostToolUse" missing);
    let r = run_check [ dir ] in
    check int "referenced count" 1 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 1 r.C2c_doctor_hooks.total_dangling;
    match r.C2c_doctor_hooks.dirs with
    | [ d ] ->
        check int "dir dangling list length" 1 (List.length d.C2c_doctor_hooks.dangling);
        let x = List.hd d.C2c_doctor_hooks.dangling in
        check string "config file" (dir // "settings.json") x.C2c_doctor_hooks.config_file;
        check string "event" "PostToolUse" x.C2c_doctor_hooks.event;
        check string "command path" missing x.C2c_doctor_hooks.command_path
    | _ -> fail "expected exactly one dir result")

let test_present_c2c_hook_ok () =
  with_tmp_dir (fun dir ->
    let present = dir // "c2c-inbox-check.sh" in
    write_file present "#!/bin/bash\nexit 0\n";
    write_file (dir // "settings.json") (settings_json "PostToolUse" present);
    let r = run_check [ dir ] in
    check int "referenced count" 1 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 0 r.C2c_doctor_hooks.total_dangling)

let test_symlinked_hooks_dir_resolves () =
  with_tmp_dir (fun dir ->
    let shared = dir // "shared-hooks" in
    C2c_io.mkdir_p shared;
    let script = shared // "c2c-inbox-check.sh" in
    write_file script "#!/bin/bash\nexit 0\n";
    let config_dir = dir // "claude" in
    C2c_io.mkdir_p config_dir;
    Unix.symlink shared (config_dir // "hooks");
    let referenced_path = config_dir // "hooks" // "c2c-inbox-check.sh" in
    write_file (config_dir // "settings.json") (settings_json "PostToolUse" referenced_path);
    let r = run_check [ config_dir ] in
    check int "referenced count" 1 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 0 r.C2c_doctor_hooks.total_dangling)

let test_settings_local_json_dangling_reported () =
  with_tmp_dir (fun dir ->
    let missing = dir // "c2c-stop-deliver.sh" in
    write_file (dir // "settings.local.json") (settings_json "Stop" missing);
    let r = run_check [ dir ] in
    check int "referenced count" 1 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 1 r.C2c_doctor_hooks.total_dangling;
    match r.C2c_doctor_hooks.dirs with
    | [ d ] ->
        check int "dir dangling list length" 1 (List.length d.C2c_doctor_hooks.dangling);
        let x = List.hd d.C2c_doctor_hooks.dangling in
        check string "config file" (dir // "settings.local.json") x.C2c_doctor_hooks.config_file;
        check string "event" "Stop" x.C2c_doctor_hooks.event;
        check string "command path" missing x.C2c_doctor_hooks.command_path
    | _ -> fail "expected exactly one dir result")

let test_leading_whitespace_absolute_path_reported () =
  with_tmp_dir (fun dir ->
    let missing = dir // "c2c-inbox-check.sh" in
    write_file (dir // "settings.json")
      (settings_json "PostToolUse" ("\t  " ^ missing ^ " --from-hook"));
    let r = run_check [ dir ] in
    check int "referenced count" 1 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 1 r.C2c_doctor_hooks.total_dangling;
    match r.C2c_doctor_hooks.dirs with
    | [ d ] ->
        let x = List.hd d.C2c_doctor_hooks.dangling in
        check string "command path trims leading whitespace" missing x.C2c_doctor_hooks.command_path
    | _ -> fail "expected exactly one dir result")

let test_malformed_settings_skipped () =
  with_tmp_dir (fun dir ->
    write_file (dir // "settings.json") "{ this is not valid json";
    let r = run_check [ dir ] in
    check int "dangling count" 0 r.C2c_doctor_hooks.total_dangling;
    (* settings.json is unparseable and settings.local.json is missing *)
    check int "skipped count" 2 r.C2c_doctor_hooks.total_skipped)

let test_non_c2c_hook_not_flagged () =
  with_tmp_dir (fun dir ->
    let missing = "/usr/bin/nonexistent-mytool-doctor-hooks-test" in
    write_file (dir // "settings.json") (settings_json "PostToolUse" missing);
    let r = run_check [ dir ] in
    check int "referenced count" 0 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 0 r.C2c_doctor_hooks.total_dangling)

let test_relative_and_path_c2c_commands_ignored () =
  with_tmp_dir (fun dir ->
    let payload = {|{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "c2c-inbox-hook-ocaml --from-path" },
          { "type": "command", "command": "./c2c-inbox-check.sh" }
        ]
      }
    ]
  }
}|} in
    write_file (dir // "settings.json") payload;
    let r = run_check [ dir ] in
    check int "referenced count" 0 r.C2c_doctor_hooks.total_referenced;
    check int "dangling count" 0 r.C2c_doctor_hooks.total_dangling)

let test_multiple_dirs_aggregate () =
  with_tmp_dir (fun dir1 ->
    with_tmp_dir (fun dir2 ->
      let missing = dir1 // "c2c-inbox-check.sh" in
      write_file (dir1 // "settings.json") (settings_json "PostToolUse" missing);
      let present = dir2 // "c2c-stop-deliver.sh" in
      write_file present "#!/bin/bash\nexit 0\n";
      write_file (dir2 // "settings.json") (settings_json "Stop" present);
      let r = run_check [ dir1; dir2 ] in
      check int "referenced count" 2 r.C2c_doctor_hooks.total_referenced;
      check int "dangling count" 1 r.C2c_doctor_hooks.total_dangling;
      check int "dir result count" 2 (List.length r.C2c_doctor_hooks.dirs)))

let () =
  run "c2c_doctor_hooks"
    [ ( "dangling_detection"
      , [ test_case "missing c2c hook is reported"     `Quick test_missing_c2c_hook_reported
        ; test_case "present c2c hook is ok"          `Quick test_present_c2c_hook_ok
        ; test_case "symlinked hooks dir resolves"    `Quick test_symlinked_hooks_dir_resolves
        ; test_case "settings.local dangling reported" `Quick test_settings_local_json_dangling_reported
        ; test_case "leading whitespace path reported" `Quick test_leading_whitespace_absolute_path_reported
        ; test_case "malformed settings is skipped"   `Quick test_malformed_settings_skipped
        ; test_case "non-c2c missing hook ignored"    `Quick test_non_c2c_hook_not_flagged
        ; test_case "relative and PATH c2c ignored"   `Quick test_relative_and_path_c2c_commands_ignored
        ; test_case "multiple dirs aggregate"         `Quick test_multiple_dirs_aggregate
        ] )
    ]
