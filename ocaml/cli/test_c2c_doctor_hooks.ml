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
    classify ~degraded:false ~app_server_status:(Some "online-attached") ~hooks_installed:true
      ~wake_target:false
  in
  check string "mode" "app-server" (label d);
  check bool "summary mentions draft-safety" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "draft-safe");
  check bool "summary states the gated-turn rule (idle + DND off)" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "idle and DND is off");
  (* B131: the delivery loop is now DRIVEN under managed supervision, so the
     online-attached diagnostic reports LIVE arrival-time delivery — no
     "library-proven, hook fallback" caveat. *)
  check bool "summary says delivery is live/auto-injected" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "auto-injected");
  check bool "healthy app-server delivery carries no remediation" true
    (d.C2c_doctor_hooks.cd_remediation = None);
  check bool "app-server delivery is data-injection, not input-injection" false
    d.C2c_doctor_hooks.cd_input_injecting;
  (* Even with a wake target present, an online-attached session's live path is
     the draft-safe app-server data injection (B131) — it is NOT input-injecting;
     the wake pane-typing path is only the hook fallback used when app-server is
     unavailable. *)
  let dw =
    classify ~degraded:false ~app_server_status:(Some "online-attached") ~hooks_installed:true
      ~wake_target:true
  in
  check bool "online-attached app-server delivery is never input-injecting" false
    dw.C2c_doctor_hooks.cd_input_injecting

let test_delivery_app_server_degraded () =
  (* B138: online-attached BUT the deliver loop never loaded a thread → the
     transport is up but nothing actually delivers. Must NOT report the healthy
     app-server LIVE label; reports the distinct degraded classification with an
     actionable remediation. *)
  let d =
    classify ~degraded:true ~app_server_status:(Some "online-attached")
      ~hooks_installed:true ~wake_target:false
  in
  check string "degraded online-attached reports the distinct label"
    "app-server (degraded: no thread loaded)" (label d);
  check bool "summary says NOT being delivered / no thread loaded" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "no Codex thread"
     && C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "NOT");
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "degraded app-server must carry an actionable remediation"
   | Some fix ->
       check bool "remediation says open/focus a thread in the TUI" true
         (C2c_doctor_hooks.contains fix "thread"
          && C2c_doctor_hooks.contains fix "TUI"));
  check bool "degraded app-server delivery is data-path, not input-injecting"
    false d.C2c_doctor_hooks.cd_input_injecting;
  (* Healthy path is NOT weakened: a thread-loaded online-attached session still
     reports LIVE app-server. *)
  let healthy =
    classify ~degraded:false ~app_server_status:(Some "online-attached")
      ~hooks_installed:true ~wake_target:false
  in
  check string "thread-loaded online-attached still reports LIVE app-server"
    "app-server" (label healthy);
  check bool "healthy path carries no remediation" true
    (healthy.C2c_doctor_hooks.cd_remediation = None)

let test_delivery_app_server_starting_not_overclaimed () =
  (* A starting unit has no attached remote TUI yet — it must NOT get the
     healthy app-server label; the session's actual delivery is the hook
     fallback, annotated with the starting state + an actionable next step. *)
  let d =
    classify ~degraded:false ~app_server_status:(Some "starting") ~hooks_installed:true
      ~wake_target:false
  in
  check string "starting reports the live hook fallback, not app-server"
    "hooks" (label d);
  check bool "summary names the starting unit" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "starting");
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "starting must carry an actionable next step"
   | Some fix ->
       check bool "remediation points at dev diag" true
         (C2c_doctor_hooks.contains fix "c2c dev diag"));
  (* Without hooks, a starting unit means no live delivery path at all. *)
  let d2 =
    classify ~degraded:false ~app_server_status:(Some "starting") ~hooks_installed:false
      ~wake_target:false
  in
  check string "starting without hooks → unavailable" "unavailable" (label d2)

let test_delivery_app_server_unavailable () =
  let d =
    classify ~degraded:false ~app_server_status:(Some "failed-startup") ~hooks_installed:true
      ~wake_target:false
  in
  check string "mode" "app-server-unavailable" (label d);
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "app-server-unavailable must carry a remediation"
   | Some fix ->
       check bool "remediation says upgrade codex" true
         (C2c_doctor_hooks.contains fix "upgrade codex"));
  check bool "summary is truthful about the hook-boundary fallback" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "hook-boundary");
  check bool "no wake target → not input-injecting" false
    d.C2c_doctor_hooks.cd_input_injecting;
  (* failed-startup with a surviving hooks+wake path must NOT hide that the
     live delivery types into the pane (review round 3, F4). *)
  let dw =
    classify ~degraded:false ~app_server_status:(Some "failed-startup") ~hooks_installed:true
      ~wake_target:true
  in
  check string "mode (wake fallback)" "app-server-unavailable" (label dw);
  check bool "surviving hooks+wake path flags input injection" true
    dw.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary is truthful about typing into the pane" true
    (C2c_doctor_hooks.contains dw.C2c_doctor_hooks.cd_summary "TYPES");
  (* Same failure without hooks: no delivery path at all, still actionable. *)
  let d2 =
    classify ~degraded:false ~app_server_status:(Some "failed-startup") ~hooks_installed:false
      ~wake_target:false
  in
  check string "mode (no hooks)" "app-server-unavailable" (label d2);
  check bool "no-hooks fallback is called out" true
    (C2c_doctor_hooks.contains d2.C2c_doctor_hooks.cd_summary
       "no codex delivery path")

let test_delivery_hooks_wake_is_input_injecting () =
  let d = classify ~degraded:false ~app_server_status:None ~hooks_installed:true ~wake_target:true in
  check string "mode" "hooks+wake" (label d);
  check bool "input-injecting flagged" true d.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary is truthful about typing into the pane" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "TYPES");
  (match d.C2c_doctor_hooks.cd_remediation with
   | None -> fail "hooks+wake must carry a remediation"
   | Some fix ->
       check bool "remediation points at the app-server transport" true
         (C2c_doctor_hooks.contains fix "app-server transport"))

let test_delivery_hooks_only () =
  let d = classify ~degraded:false ~app_server_status:None ~hooks_installed:true ~wake_target:false in
  check string "mode" "hooks" (label d);
  check bool "not input-injecting" false d.C2c_doctor_hooks.cd_input_injecting;
  check bool "summary says idle sessions wait for the next turn" true
    (C2c_doctor_hooks.contains d.C2c_doctor_hooks.cd_summary "idle session");
  check bool "remediation present" true (d.C2c_doctor_hooks.cd_remediation <> None)

let test_delivery_unavailable () =
  let d = classify ~degraded:false ~app_server_status:None ~hooks_installed:false ~wake_target:false in
  check string "mode" "unavailable" (label d);
  check (option string) "remediation is the install command"
    (Some "run `c2c install codex`") d.C2c_doctor_hooks.cd_remediation

let test_delivery_offline_record_falls_back_to_hooks () =
  (* An ended app-server unit is not a live delivery path — classify by what
     actually delivers now. *)
  let d = classify ~degraded:false ~app_server_status:(Some "offline") ~hooks_installed:true
      ~wake_target:false in
  check string "offline record → hooks" "hooks" (label d)

let test_delivery_never_claims_instant () =
  let all =
    [ classify ~degraded:false ~app_server_status:(Some "online-attached") ~hooks_installed:true ~wake_target:false
    ; classify ~degraded:false ~app_server_status:(Some "starting") ~hooks_installed:true ~wake_target:false
    ; classify ~degraded:false ~app_server_status:(Some "failed-startup") ~hooks_installed:true ~wake_target:false
    ; classify ~degraded:false ~app_server_status:None ~hooks_installed:true ~wake_target:true
    ; classify ~degraded:false ~app_server_status:None ~hooks_installed:true ~wake_target:false
    ; classify ~degraded:false ~app_server_status:None ~hooks_installed:false ~wake_target:false
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
        [ ("cx-live", Some "online-attached", false, false)
        ; ("cx-degraded", Some "online-attached", false, true)
        ; ("cx-broken", Some "failed-startup", false, false)
        ; ("cx-tmux", None, true, false)
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
    ; ("cx-degraded", "app-server (degraded: no thread loaded)")
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
      "app_server_status"; "remediation";
      "app-server (degraded: no thread loaded)" ];
  List.iter
    (fun forbidden ->
      check bool (Printf.sprintf "json never contains %s" forbidden) false
        (C2c_doctor_hooks.contains json forbidden))
    [ "ws://"; "token"; "127.0.0.1" ]

(* --- B238: Kimi deaf-session classifier ---------------------------------- *)

let test_kimi_classify_deaf_when_inbox_and_no_notifier () =
  match
    C2c_doctor_hooks.classify_kimi_session
      ~alias:"kimi-tulip"
      ~session_id:"session_abc"
      ~inbox_count:3
      ~notifier_running:false
      ~registered_by:(Some "kimi-hook")
  with
  | Some issue, true ->
      check string "alias" "kimi-tulip" issue.C2c_doctor_hooks.ksi_alias;
      check int "inbox" 3 issue.C2c_doctor_hooks.ksi_inbox_count;
      check bool "fix mentions start kimi" true
        (C2c_doctor_hooks.contains issue.C2c_doctor_hooks.ksi_fix_command
           "c2c start kimi")
  | _ -> fail "expected deaf issue"

let test_kimi_classify_no_issue_when_notifier_running () =
  match
    C2c_doctor_hooks.classify_kimi_session
      ~alias:"kimi-ok"
      ~session_id:"session_ok"
      ~inbox_count:5
      ~notifier_running:true
      ~registered_by:None
  with
  | None, false -> ()
  | _ -> fail "notifier running must not be flagged"

let test_kimi_classify_warn_only_empty_inbox () =
  match
    C2c_doctor_hooks.classify_kimi_session
      ~alias:"kimi-idle"
      ~session_id:"session_idle"
      ~inbox_count:0
      ~notifier_running:false
      ~registered_by:(Some "kimi-hook")
  with
  | Some _, false -> () (* issue for no-notifier list, not deaf *)
  | None, _ -> fail "empty inbox without notifier should still yield a soft issue"
  | Some _, true -> fail "empty inbox must not be classified as deaf"

let test_kimi_registration_detector () =
  let mk ~alias ~client_type ~registered_by : C2c_mcp.registration =
    { session_id = "sid"
    ; alias
    ; pid = None
    ; pid_start_time = None
    ; registered_at = None
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type
    ; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
    ; herdr_pane = None
    ; herdr_socket = None
    ; cwd = None
    ; metadata_opt_out = false
    ; registered_by
    ; opaque_host_id = None
    }
  in
  check bool "client_type=kimi" true
    (C2c_doctor_hooks.is_kimi_registration
       (mk ~alias:"x" ~client_type:(Some "kimi") ~registered_by:None));
  check bool "registered_by=kimi-hook" true
    (C2c_doctor_hooks.is_kimi_registration
       (mk ~alias:"x" ~client_type:None ~registered_by:(Some "kimi-hook")));
  check bool "alias prefix kimi-" true
    (C2c_doctor_hooks.is_kimi_registration
       (mk ~alias:"kimi-garnet" ~client_type:None ~registered_by:None));
  check bool "claude not kimi" false
    (C2c_doctor_hooks.is_kimi_registration
       (mk ~alias:"claude-x" ~client_type:(Some "claude") ~registered_by:None))

(* --- Grok identity-drift detector (#23a) ---------------------------------- *)

(* Seed a hermetic broker + statefile + fixture active_sessions.json. The
   active_sessions path is overridden via C2C_GROK_ACTIVE_SESSIONS so no real
   ~/.grok file is touched. *)
let with_grok_fixture f =
  with_tmp_dir (fun dir ->
    let broker_root = dir // "broker" in
    C2c_io.mkdir_p broker_root;
    let active_path = dir // "active_sessions.json" in
    let prev = Sys.getenv_opt "C2C_GROK_ACTIVE_SESSIONS" in
    Unix.putenv "C2C_GROK_ACTIVE_SESSIONS" active_path;
    Fun.protect
      ~finally:(fun () ->
        match prev with
        | Some v -> Unix.putenv "C2C_GROK_ACTIVE_SESSIONS" v
        | None -> Unix.putenv "C2C_GROK_ACTIVE_SESSIONS" "")
      (fun () -> f ~broker_root ~active_path))

let register_grok broker_root ~session_id ~alias =
  let broker = C2c_mcp.Broker.create ~root:broker_root in
  ignore
    (C2c_mcp.Broker.register broker ~session_id ~alias ~pid:None
       ~pid_start_time:None ~client_type:(Some "grok") ~from_auto_gen:true ())

(* Write the CLI statefile (default-session.json) that read_session_statefile
   consumes — inline so the test does not link the heavy c2c_cli_helpers. *)
let write_statefile broker_root ~session_id =
  write_file (broker_root // "default-session.json")
    (Yojson.Safe.to_string (`Assoc [ ("session_id", `String session_id) ]))

(* entries: (session_id, pid option) list — pid absent means no foreground pid. *)
let write_active_sessions active_path entries =
  let json =
    `List
      (List.map
         (fun (sid, pid) ->
           `Assoc
             (("session_id", `String sid)
              :: (match pid with Some p -> [ ("pid", `Int p) ] | None -> [])))
         entries)
  in
  write_file active_path (Yojson.Safe.to_string json)

let dead_pid = 2_147_483_646 (* astronomically unlikely to be a live pid *)

(* Statefile points at a grok session whose pid is dead/absent in
   active_sessions.json → drift is flagged with remediation. *)
let test_grok_flags_stale_statefile_identity () =
  with_grok_fixture (fun ~broker_root ~active_path ->
    let sid = "grok-sess-dead-0001" in
    register_grok broker_root ~session_id:sid ~alias:"grok-fixaa";
    write_statefile broker_root ~session_id:sid;
    (* active_sessions lists the sid but with a dead pid → not corroborated *)
    write_active_sessions active_path [ (sid, Some dead_pid) ];
    let g = C2c_doctor_hooks.check_grok_identity ~broker_root () in
    check int "one grok reg" 1 g.C2c_doctor_hooks.gid_grok_regs;
    check bool "flagged" true g.C2c_doctor_hooks.gid_flagged;
    check bool "no live grok sids" true (g.C2c_doctor_hooks.gid_live_grok_sids = []);
    check bool "remediation mentions C2C_MCP_SESSION_ID" true
      (List.exists
         (fun l -> C2c_doctor_hooks.contains l "C2C_MCP_SESSION_ID")
         g.C2c_doctor_hooks.gid_remediation);
    check bool "remediation lists a grok candidate" true
      (List.exists
         (fun l -> C2c_doctor_hooks.contains l "grok-fixaa")
         g.C2c_doctor_hooks.gid_remediation))

(* A single live grok session that matches the statefile → no drift. *)
let test_grok_quiet_when_corroborated () =
  with_grok_fixture (fun ~broker_root ~active_path ->
    let sid = "grok-sess-live-0002" in
    register_grok broker_root ~session_id:sid ~alias:"grok-fixbb";
    write_statefile broker_root ~session_id:sid;
    (* alive: our own pid definitely has a /proc entry *)
    write_active_sessions active_path [ (sid, Some (Unix.getpid ())) ];
    let g = C2c_doctor_hooks.check_grok_identity ~broker_root () in
    check int "one grok reg" 1 g.C2c_doctor_hooks.gid_grok_regs;
    check bool "not flagged" false g.C2c_doctor_hooks.gid_flagged;
    check bool "sole live grok sid corroborated" true
      (g.C2c_doctor_hooks.gid_live_grok_sids = [ sid ]);
    check bool "no remediation" true (g.C2c_doctor_hooks.gid_remediation = []))

(* Two grok registrations, none alive in active_sessions → ambiguous drift. *)
let test_grok_flags_ambiguous_multi_registration () =
  with_grok_fixture (fun ~broker_root ~active_path ->
    register_grok broker_root ~session_id:"grok-a-0003" ~alias:"grok-fixcc";
    register_grok broker_root ~session_id:"grok-b-0004" ~alias:"grok-fixdd";
    (* both dead → no single corroborated live one *)
    write_active_sessions active_path
      [ ("grok-a-0003", Some dead_pid); ("grok-b-0004", Some dead_pid) ];
    let g = C2c_doctor_hooks.check_grok_identity ~broker_root () in
    check int "two grok regs" 2 g.C2c_doctor_hooks.gid_grok_regs;
    check bool "flagged ambiguous" true g.C2c_doctor_hooks.gid_flagged)

(* No grok registrations at all → detector is silent. *)
let test_grok_quiet_when_no_grok_regs () =
  with_grok_fixture (fun ~broker_root ~active_path ->
    write_active_sessions active_path [];
    let g = C2c_doctor_hooks.check_grok_identity ~broker_root () in
    check int "zero grok regs" 0 g.C2c_doctor_hooks.gid_grok_regs;
    check bool "not flagged" false g.C2c_doctor_hooks.gid_flagged)

let test_grok_registration_detector () =
  let mk ~alias ~client_type ~registered_by : C2c_mcp.registration =
    { session_id = "sid"; alias; pid = None; pid_start_time = None
    ; registered_at = None; canonical_alias = None; dnd = false
    ; dnd_since = None; dnd_until = None; client_type; plugin_version = None
    ; confirmed_at = None; enc_pubkey = None; ed25519_pubkey = None
    ; pubkey_signed_at = None; pubkey_sig = None; compacting = None
    ; last_activity_ts = None; role = None; compaction_count = 0
    ; automated_delivery = None; tmux_location = None; herdr_pane = None
    ; herdr_socket = None; cwd = None; metadata_opt_out = false
    ; registered_by; opaque_host_id = None }
  in
  check bool "client_type=grok" true
    (C2c_doctor_hooks.is_grok_registration
       (mk ~alias:"x" ~client_type:(Some "grok") ~registered_by:None));
  check bool "registered_by=grok-hook" true
    (C2c_doctor_hooks.is_grok_registration
       (mk ~alias:"x" ~client_type:None ~registered_by:(Some "grok-hook")));
  check bool "alias prefix grok-" true
    (C2c_doctor_hooks.is_grok_registration
       (mk ~alias:"grok-amber" ~client_type:None ~registered_by:None));
  check bool "claude not grok" false
    (C2c_doctor_hooks.is_grok_registration
       (mk ~alias:"claude-x" ~client_type:(Some "claude") ~registered_by:None))

(* --fix (#19): restore a dangling c2c-owned hook script from the canonical
   embedded content, without touching settings.json. *)
let test_fix_restores_dangling_c2c_hook () =
  with_tmp_dir (fun dir ->
    let missing = dir // "c2c-inbox-check.sh" in
    write_file (dir // "settings.json") (settings_json "PostToolUse" missing);
    let r = run_check [ dir ] in
    check int "dangling before fix" 1 r.C2c_doctor_hooks.total_dangling;
    let restored, unknown, failed = C2c_doctor_hooks.fix_dangling r in
    check int "restored one" 1 (List.length restored);
    check int "none unknown" 0 (List.length unknown);
    check int "none failed" 0 (List.length failed);
    check bool "script exists after fix" true (Sys.file_exists missing);
    let ic = open_in missing in
    let content =
      Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        really_input_string ic (in_channel_length ic))
    in
    check bool "content is the canonical inbox-check script" true
      (content = C2c_claude_hook_scripts.claude_hook_script);
    let st = Unix.stat missing in
    check int "mode is 0755" 0o755 (st.Unix.st_perm land 0o777);
    let r2 = run_check [ dir ] in
    check int "dangling after fix" 0 r2.C2c_doctor_hooks.total_dangling)

(* --fix only restores KNOWN c2c-owned scripts; an unknown dangling script
   (even one containing 'c2c') is reported, never fabricated. *)
let test_fix_ignores_non_c2c_owned_dangling () =
  with_tmp_dir (fun dir ->
    let missing = dir // "my-c2c-custom.sh" in
    write_file (dir // "settings.json") (settings_json "PostToolUse" missing);
    let r = run_check [ dir ] in
    check int "dangling before" 1 r.C2c_doctor_hooks.total_dangling;
    let restored, unknown, failed = C2c_doctor_hooks.fix_dangling r in
    check int "nothing restored" 0 (List.length restored);
    check int "one unknown" 1 (List.length unknown);
    check int "none failed" 0 (List.length failed);
    check bool "custom script still absent" false (Sys.file_exists missing))

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
        ; test_case "--fix restores dangling c2c hook" `Quick test_fix_restores_dangling_c2c_hook
        ; test_case "--fix ignores non-c2c-owned dangling" `Quick test_fix_ignores_non_c2c_owned_dangling
        ] )
    ; ( "codex-managed-blocks"
      , [ test_case "current blocks ok" `Quick test_codex_managed_blocks_current
        ; test_case "stale config reported" `Quick test_codex_stale_config_reported
        ; test_case "missing AGENTS.md reported" `Quick test_codex_missing_agents_block_reported
        ; test_case "trust index drift reported" `Quick test_codex_trust_index_drift_reported
        ] )
    ; ( "codex-delivery-mode"
      , [ test_case "app-server healthy" `Quick test_delivery_app_server_healthy
        ; test_case "app-server degraded (no thread loaded)" `Quick test_delivery_app_server_degraded
        ; test_case "starting is not overclaimed as app-server" `Quick test_delivery_app_server_starting_not_overclaimed
        ; test_case "app-server unavailable + remediation" `Quick test_delivery_app_server_unavailable
        ; test_case "hooks+wake is input-injecting" `Quick test_delivery_hooks_wake_is_input_injecting
        ; test_case "hooks-only fallback" `Quick test_delivery_hooks_only
        ; test_case "unavailable → install codex" `Quick test_delivery_unavailable
        ; test_case "offline record falls back to hooks" `Quick test_delivery_offline_record_falls_back_to_hooks
        ; test_case "never claims instant delivery" `Quick test_delivery_never_claims_instant
        ; test_case "report structure + json hygiene" `Quick test_delivery_report_structure
        ] )
    ; ( "kimi-delivery-b238"
      , [ test_case "deaf when inbox + no notifier" `Quick test_kimi_classify_deaf_when_inbox_and_no_notifier
        ; test_case "no issue when notifier running" `Quick test_kimi_classify_no_issue_when_notifier_running
        ; test_case "empty inbox soft-warn only" `Quick test_kimi_classify_warn_only_empty_inbox
        ; test_case "registration detector" `Quick test_kimi_registration_detector
        ] )
    ; ( "grok-identity-23a"
      , [ test_case "flags stale statefile identity" `Quick test_grok_flags_stale_statefile_identity
        ; test_case "quiet when corroborated live" `Quick test_grok_quiet_when_corroborated
        ; test_case "flags ambiguous multi-registration" `Quick test_grok_flags_ambiguous_multi_registration
        ; test_case "quiet when no grok regs" `Quick test_grok_quiet_when_no_grok_regs
        ; test_case "registration detector" `Quick test_grok_registration_detector
        ] )
    ]
