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

let replace_first ~needle ~replacement s =
  let sl = String.length s and nl = String.length needle in
  let rec find i =
    if i + nl > sl then None
    else if String.sub s i nl = needle then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> s
  | Some i ->
      String.sub s 0 i ^ replacement
      ^ String.sub s (i + nl) (sl - i - nl)

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

let codex_config_path home = home // ".codex" // "config.toml"
let codex_agents_path home = home // ".codex" // "AGENTS.md"

let fresh_codex_config ?(existing = "model = \"gpt-5.5\"\n") home =
  let config_path = codex_config_path home in
  existing ^ "\n"
  ^ C2c_codex_hooks.render_hooks_block ~config_path ~existing

let write_fresh_codex_install ?existing home =
  write_file (codex_config_path home) (fresh_codex_config ?existing home);
  write_file (codex_agents_path home)
    (C2c_codex_hooks.upsert_agents_md "# Operator notes\n")

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

let test_codex_managed_blocks_current () =
  with_tmp_dir (fun home ->
    write_fresh_codex_install home;
    let r = C2c_doctor_hooks.check_codex_managed_blocks ~home () in
    check bool "codex installed detected" true r.C2c_doctor_hooks.installed;
    check int "no codex block issues" 0 r.C2c_doctor_hooks.total_issues;
    check string "config current" "current"
      (C2c_doctor_hooks.status_label r.C2c_doctor_hooks.config.status);
    check string "agents current" "current"
      (C2c_doctor_hooks.status_label r.C2c_doctor_hooks.agents_md.status))

let test_codex_stale_config_reported () =
  with_tmp_dir (fun home ->
    let config =
      fresh_codex_config home
      |> replace_first ~needle:"statusMessage = \"c2c onboarding\""
           ~replacement:"statusMessage = \"old onboarding\""
    in
    write_file (codex_config_path home) config;
    write_file (codex_agents_path home) C2c_codex_hooks.agents_md_block;
    let r = C2c_doctor_hooks.check_codex_managed_blocks ~home () in
    check int "one stale config issue" 1 r.C2c_doctor_hooks.total_issues;
    check string "config stale" "stale"
      (C2c_doctor_hooks.status_label r.C2c_doctor_hooks.config.status);
    check (option string) "refresh command" (Some "c2c install codex")
      r.C2c_doctor_hooks.config.refresh_command;
    check bool "diff present" true
      (Option.is_some r.C2c_doctor_hooks.config.first_diff))

let test_codex_missing_agents_block_reported () =
  with_tmp_dir (fun home ->
    write_file (codex_config_path home) (fresh_codex_config home);
    let r = C2c_doctor_hooks.check_codex_managed_blocks ~home () in
    check int "one missing agents issue" 1 r.C2c_doctor_hooks.total_issues;
    check string "agents missing" "missing"
      (C2c_doctor_hooks.status_label r.C2c_doctor_hooks.agents_md.status);
    check (option string) "refresh command" (Some "c2c install codex")
      r.C2c_doctor_hooks.agents_md.refresh_command)

let test_codex_trust_index_drift_reported () =
  with_tmp_dir (fun home ->
    let user_hook =
      "[[hooks.PostToolUse]]\n\
       [[hooks.PostToolUse.hooks]]\n\
       type = \"command\"\n\
       command = \"/usr/bin/user-hook\"\n\n"
    in
    (* Simulate a user adding a hook group after install. The rendered c2c
       block still has post_tool_use index 0, but a fresh install would put
       c2c after the user hook and pre-trust index 1. *)
    write_file (codex_config_path home) (user_hook ^ fresh_codex_config home);
    write_file (codex_agents_path home) C2c_codex_hooks.agents_md_block;
    let r = C2c_doctor_hooks.check_codex_managed_blocks ~home () in
    check bool "trust index drift" true r.C2c_doctor_hooks.trust_index_drift;
    check string "config stale" "stale"
      (C2c_doctor_hooks.status_label r.C2c_doctor_hooks.config.status);
    check bool "reason mentions indices" true
      (C2c_doctor_hooks.contains r.C2c_doctor_hooks.config.reason "indices"))

(* --- Codex delivery-mode classification (T005) ---------------------------- *)

let classify = C2c_doctor_hooks.classify_codex_delivery
let label d = C2c_doctor_hooks.codex_delivery_mode_label d.C2c_doctor_hooks.cd_mode

let test_delivery_app_server_healthy () =
  let d =
    classify ~app_server_status:(Some "online-attached") ~hooks_installed:true
      ~wake_target:true
  in
  check string "mode" "app-server" (label d);
  check bool "healthy path has no remediation" true
    (d.C2c_doctor_hooks.cd_remediation = None);
  check bool "not input-injecting" false d.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary mentions draft-safety" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "draft-safe");
  check bool "summary states the gated-turn rule (idle + DND off)" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "idle and DND is off")

let test_delivery_app_server_starting_has_remediation () =
  let d =
    classify ~app_server_status:(Some "starting") ~hooks_installed:true
      ~wake_target:false
  in
  check string "mode" "app-server" (label d);
  check bool "starting carries an actionable next step" true
    (d.C2c_doctor_hooks.cd_remediation <> None)

let test_delivery_app_server_unavailable () =
  let d =
    classify ~app_server_status:(Some "failed-startup") ~hooks_installed:true
      ~wake_target:false
  in
  check string "mode" "app-server-unavailable" (label d);
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "app-server-unavailable must carry a remediation"
   | Some fix ->
       check bool "remediation says upgrade codex" true
         (C2c_doctor_hooks.contains fix "upgrade codex"));
  check bool "summary is truthful about the hook-boundary fallback" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "hook boundary");
  (* Same failure without hooks: no delivery path at all, still actionable. *)
  let d2 =
    classify ~app_server_status:(Some "failed-startup") ~hooks_installed:false
      ~wake_target:false
  in
  check string "mode (no hooks)" "app-server-unavailable" (label d2);
  check bool "no-hooks fallback is called out" true
    (C2c_doctor_hooks.contains d2.C2c_doctor_hooks.cd_summary "no delivery path")

let test_delivery_hooks_wake_is_input_injecting () =
  let d = classify ~app_server_status:None ~hooks_installed:true ~wake_target:true in
  check string "mode" "hooks+wake" (label d);
  check bool "input-injecting flagged" true d.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary is truthful about typing into the pane" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "TYPES");
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "hooks+wake must carry a remediation"
   | Some fix ->
       check bool "remediation points at the app-server transport" true
         (C2c_doctor_hooks.contains fix "--app-server"))

let test_delivery_hooks_only () =
  let d = classify ~app_server_status:None ~hooks_installed:true ~wake_target:false in
  check string "mode" "hooks" (label d);
  check bool "not input-injecting" false d.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary says idle sessions wait for the next turn" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "idle session");
  check bool "remediation present" true (d.C2c_doctor_hooks.cd_remediation <> None)

let test_delivery_unavailable () =
  let d = classify ~app_server_status:None ~hooks_installed:false ~wake_target:false in
  check string "mode" "unavailable" (label d);
  check (option string) "remediation is the install command"
    (Some "run `c2c install codex`") d.C2c_doctor_hooks.cd_remediation

let test_delivery_offline_record_falls_back_to_hooks () =
  (* An ended app-server unit is not a live delivery path — classify by what
     actually delivers now. *)
  let d = classify ~app_server_status:(Some "offline") ~hooks_installed:true
      ~wake_target:false in
  check string "offline record → hooks" "hooks" (label d)

let test_delivery_never_claims_instant () =
  let all =
    [ classify ~app_server_status:(Some "online-attached") ~hooks_installed:true ~wake_target:false
    ; classify ~app_server_status:(Some "starting") ~hooks_installed:true ~wake_target:false
    ; classify ~app_server_status:(Some "failed-startup") ~hooks_installed:true ~wake_target:false
    ; classify ~app_server_status:None ~hooks_installed:true ~wake_target:true
    ; classify ~app_server_status:None ~hooks_installed:true ~wake_target:false
    ; classify ~app_server_status:None ~hooks_installed:false ~wake_target:false
    ]
  in
  List.iter
    (fun d ->
      check bool
        (Printf.sprintf "summary of %s never claims 'instant'" (label d))
        false
        (C2c_doctor_hooks.contains
           (String.lowercase_ascii d.C2c_doctor_hooks.cd_summary) "instant"))
    all

let test_delivery_report_structure () =
  let rep =
    C2c_doctor_hooks.codex_delivery_report ~hooks_installed:true
      ~instances:
        [ ("cx-live", Some "online-attached", false)
        ; ("cx-broken", Some "failed-startup", false)
        ; ("cx-tmux", None, true)
        ]
      ()
  in
  check string "default is hooks (no wake target for vanilla)" "hooks"
    (label rep.C2c_doctor_hooks.cdr_default);
  let modes =
    List.map
      (fun i -> (i.C2c_doctor_hooks.ci_name, label i.C2c_doctor_hooks.ci_delivery))
      rep.C2c_doctor_hooks.cdr_instances
  in
  check (list (pair string string)) "per-instance modes distinguished"
    [ ("cx-live", "app-server")
    ; ("cx-broken", "app-server-unavailable")
    ; ("cx-tmux", "hooks+wake")
    ]
    modes;
  (* JSON shape: mode/summary/remediation/input_injecting per row; no
     endpoints, tokens, or bodies anywhere in the machine output. *)
  let json =
    Yojson.Safe.to_string (C2c_doctor_hooks.codex_delivery_report_to_json rep)
  in
  List.iter
    (fun needle ->
      check bool (Printf.sprintf "json mentions %s" needle) true
        (C2c_doctor_hooks.contains json needle))
    [ "app-server-unavailable"; "hooks+wake"; "input_injecting";
      "app_server_status"; "remediation" ];
  List.iter
    (fun forbidden ->
      check bool (Printf.sprintf "json never contains %s" forbidden) false
        (C2c_doctor_hooks.contains json forbidden))
    [ "ws://"; "token"; "127.0.0.1" ]

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
    ; ( "codex-managed-blocks"
      , [ test_case "current blocks ok" `Quick test_codex_managed_blocks_current
        ; test_case "stale config reported" `Quick test_codex_stale_config_reported
        ; test_case "missing AGENTS.md reported" `Quick test_codex_missing_agents_block_reported
        ; test_case "trust index drift reported" `Quick test_codex_trust_index_drift_reported
        ] )
    ; ( "codex-delivery-mode"
      , [ test_case "app-server healthy" `Quick test_delivery_app_server_healthy
        ; test_case "app-server starting has next step" `Quick test_delivery_app_server_starting_has_remediation
        ; test_case "app-server unavailable + remediation" `Quick test_delivery_app_server_unavailable
        ; test_case "hooks+wake is input-injecting" `Quick test_delivery_hooks_wake_is_input_injecting
        ; test_case "hooks-only fallback" `Quick test_delivery_hooks_only
        ; test_case "unavailable → install codex" `Quick test_delivery_unavailable
        ; test_case "offline record falls back to hooks" `Quick test_delivery_offline_record_falls_back_to_hooks
        ; test_case "never claims instant delivery" `Quick test_delivery_never_claims_instant
        ; test_case "report structure + json hygiene" `Quick test_delivery_report_structure
        ] )
    ]
