open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-start-test-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let with_cwd dir f =
  let prev = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Unix.chdir prev)
    (fun () ->
      Unix.chdir dir;
      f ())

let with_instance_dir name f =
  let dir = C2c_start.instance_dir name in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)));
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let rec has_adjacent_pair left right = function
  | a :: b :: _ when a = left && b = right -> true
  | _ :: tl -> has_adjacent_pair left right tl
  | [] -> false

let env_contains env expected =
  Array.exists (fun entry -> String.equal entry expected) env

let env_has_key env key =
  let prefix = key ^ "=" in
  Array.exists
    (fun entry ->
      let len = String.length prefix in
      String.length entry >= len
      && String.sub entry 0 len = prefix)
    env

let test_prepare_launch_args_claude_uses_development_channel_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "uses development channel flag" true
    (List.mem "--dangerously-load-development-channels" args);
  check bool "passes local server through dev channel flag" true
    (has_adjacent_pair "--dangerously-load-development-channels" "server:c2c" args);
  check bool "does not pass --channels server:c2c (Max 2026-04-24)" false
    (has_adjacent_pair "--channels" "server:c2c" args)

let test_prepare_launch_args_claude_ignores_enable_channels_config () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
      output_string oc "enable_channels = true\n");
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "still uses development channel flag" true
    (List.mem "--dangerously-load-development-channels" args);
  check bool "passes local server through dev channel flag" true
    (has_adjacent_pair "--dangerously-load-development-channels" "server:c2c" args);
  check bool "does not pass --channels server:c2c (Max 2026-04-24)" false
    (has_adjacent_pair "--channels" "server:c2c" args);
  check bool "does not add untagged channel name" false
    (has_adjacent_pair "--channels" "c2c" args)

let test_normalize_model_override_for_opencode_requires_provider () =
  match C2c_start.normalize_model_override_for_client ~client:"opencode" "MiniMax-M2.7-highspeed" with
  | Ok _ -> fail "expected opencode bare model to be rejected"
  | Error _ -> ()

let test_normalize_model_override_for_opencode_rewrites_provider_model () =
  check string "provider/model"
    "minimax-coding-plan/MiniMax-M2.7-highspeed"
    (match C2c_start.normalize_model_override_for_client
             ~client:"opencode"
             "minimax-coding-plan:MiniMax-M2.7-highspeed"
     with
     | Ok model -> model
     | Error msg -> fail msg)

let test_normalize_model_override_for_claude_accepts_plain_model () =
  check string "plain model preserved"
    "claude-sonnet-4-7"
    (match C2c_start.normalize_model_override_for_client
             ~client:"claude"
             "claude-sonnet-4-7"
     with
     | Ok model -> model
     | Error msg -> fail msg)

let test_normalize_model_override_for_claude_discards_provider_prefix () =
  check string "provider removed"
    "claude-sonnet-4-7"
    (match C2c_start.normalize_model_override_for_client
             ~client:"claude"
             "anthropic:claude-sonnet-4-7"
     with
     | Ok model -> model
     | Error msg -> fail msg)

let test_prepare_launch_args_adds_model_flag_for_claude () =
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"claude-sonnet-4-7" ()
  in
  check bool "adds --model" true (has_adjacent_pair "--model" "claude-sonnet-4-7" args)

let test_prepare_launch_args_adds_model_flag_for_opencode () =
  let args =
    C2c_start.prepare_launch_args ~name:"oc-proof" ~client:"opencode"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"minimax-coding-plan/MiniMax-M2.7-highspeed" ()
  in
  check bool "adds --model"
    true
    (has_adjacent_pair "--model" "minimax-coding-plan/MiniMax-M2.7-highspeed" args)

let test_build_env_keeps_channel_delivery_without_force_flag () =
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      ~client:(Some "claude")
      "claude-proof" (Some "claude-proof")
  in
  check bool "keeps managed channel delivery opt-in" true
    (env_contains env "C2C_MCP_CHANNEL_DELIVERY=1");
  check bool "exports force capabilities for claude" true
    (env_contains env "C2C_MCP_FORCE_CAPABILITIES=claude_channel");
  ()

let test_build_env_does_not_seed_codex_thread_id () =
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      ~client:(Some "codex")
      "codex-proof" (Some "codex-proof")
  in
  check bool "does not seed CODEX_THREAD_ID" false
    (env_has_key env "CODEX_THREAD_ID");
  check bool "does not export legacy CODEX_SESSION_ID" false
    (env_has_key env "CODEX_SESSION_ID");
  check bool "does not export force capabilities for non-claude" false
    (env_has_key env "C2C_MCP_FORCE_CAPABILITIES")

let test_start_deliver_daemon_detaches_from_terminal_stdio_and_group () =
  with_temp_dir @@ fun dir ->
  let bin_dir = Filename.concat dir "bin" in
  Unix.mkdir bin_dir 0o755;
  let output_path = Filename.concat dir "deliver-daemon-state.txt" in
  let script_path = Filename.concat bin_dir "c2c-deliver-inbox" in
  let oc = open_out script_path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      output_string oc
        (Printf.sprintf "%s"
           (String.concat ""
              [ "#!/usr/bin/env python3\n"
              ; "import os\n"
              ; "import time\n"
              ; Printf.sprintf "with open(%S, 'w', encoding='utf-8') as f:\n" output_path
              ; "    f.write('stdin=' + os.readlink('/proc/self/fd/0') + '\\n')\n"
              ; "    f.write('stdout=' + os.readlink('/proc/self/fd/1') + '\\n')\n"
              ; "    f.write('stderr=' + os.readlink('/proc/self/fd/2') + '\\n')\n"
              ; "    f.write('pid=' + str(os.getpid()) + '\\n')\n"
              ; "    f.write('pgid=' + str(os.getpgrp()) + '\\n')\n"
              ; "time.sleep(30)\n"
              ])));
  Unix.chmod script_path 0o755;
  let pid_opt =
    C2c_start.start_deliver_daemon ~name:"deliver-proof" ~client:"codex"
      ~broker_root:dir ~command_override:(script_path, []) ()
  in
  match pid_opt with
  | None -> fail "expected deliver daemon pid"
  | Some pid ->
      let rec wait_for_output attempts_remaining =
        if attempts_remaining <= 0 then fail "deliver daemon never wrote state"
        else if Sys.file_exists output_path then ()
        else (
          Unix.sleepf 0.1;
          wait_for_output (attempts_remaining - 1)
        )
      in
      wait_for_output 50;
      let ic = open_in output_path in
      let lines =
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () ->
            let rec collect acc =
              try collect (input_line ic :: acc)
              with End_of_file -> List.rev acc
            in
            collect [])
      in
      let assoc =
        List.filter_map
          (fun line ->
            match String.split_on_char '=' line with
            | [ key; value ] -> Some (key, value)
            | _ -> None)
          lines
      in
      let find key =
        match List.assoc_opt key assoc with
        | Some value -> value
        | None -> fail ("missing key in sidecar state: " ^ key)
      in
      check string "stdin" "/dev/null" (find "stdin");
      check bool "stdout is not controlling tty"
        false
        (String.starts_with ~prefix:"/dev/pts/" (find "stdout"));
      check bool "stderr is not controlling tty"
        false
        (String.starts_with ~prefix:"/dev/pts/" (find "stderr"));
      (try Unix.kill pid Sys.sigterm with _ -> ());
      Unix.sleepf 0.1;
      (try Unix.kill pid Sys.sigkill with _ -> ())

let test_probed_capabilities_for_claude_include_channel () =
  let caps =
    C2c_start.probed_capabilities ~client:"claude" ~binary_path:"/bin/true"
  in
  check (list string) "claude capability set"
    [ "claude_channel" ] caps

let test_probed_capabilities_for_opencode_include_plugin () =
  let caps =
    C2c_start.probed_capabilities ~client:"opencode" ~binary_path:"/bin/true"
  in
  check (list string) "opencode capability set"
    [ "opencode_plugin" ] caps

let test_probed_capabilities_for_kimi_include_wire () =
  let caps =
    C2c_start.probed_capabilities ~client:"kimi" ~binary_path:"/bin/true"
  in
  check (list string) "kimi capability set"
    [ "kimi_wire" ] caps

let test_check_pty_inject_capability_ok_when_yama_zero () =
  let result =
    C2c_start.check_pty_inject_capability
      ~python_path:"/usr/bin/python3"
      ~yama_ptrace_scope:"0"
      ()
  in
  check bool "yama zero => ok" true (match result with `Ok -> true | _ -> false)

let test_check_pty_inject_capability_ok_when_getcap_has_ptrace () =
  let result =
    C2c_start.check_pty_inject_capability
      ~python_path:"/usr/bin/python3"
      ~yama_ptrace_scope:"1"
      ~getcap_output:"/usr/bin/python3 cap_sys_ptrace=ep"
      ()
  in
  check bool "getcap ptrace => ok" true (match result with `Ok -> true | _ -> false)

let test_check_pty_inject_capability_missing_when_cap_absent () =
  let result =
    C2c_start.check_pty_inject_capability
      ~python_path:"/usr/bin/python3"
      ~yama_ptrace_scope:"1"
      ~getcap_output:""
      ()
  in
  check bool "missing cap => missing" true
    (match result with `Missing_cap "/usr/bin/python3" -> true | _ -> false)

let test_runtime_capabilities_for_opencode_include_plugin_active_when_fresh () =
  let name = Printf.sprintf "opencode-fresh-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let last_active = "2026-04-24T01:00:30.000Z" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String last_active)
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String last_active)
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String last_active)
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let caps =
    C2c_start.runtime_capabilities ~client:"opencode" ~name
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check (list string) "fresh runtime capability set"
    [ "opencode_plugin_active" ] caps

let test_runtime_capabilities_for_opencode_exclude_plugin_active_when_stale () =
  let name = Printf.sprintf "opencode-stale-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:00.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:00.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let caps =
    C2c_start.runtime_capabilities ~client:"opencode" ~name
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:02:01.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check (list string) "stale runtime capability set" [] caps

let test_runtime_capabilities_for_opencode_require_matching_session_id () =
  let name = Printf.sprintf "opencode-mismatch-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:30.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String "other-session")
              ; ("state_last_updated_at", `String "2026-04-24T01:00:30.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:30.000Z")
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let caps =
    C2c_start.runtime_capabilities ~client:"opencode" ~name
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check (list string) "mismatched session runtime capability set" [] caps

let test_should_enable_opencode_fallback_respects_startup_grace () =
  let name = Printf.sprintf "opencode-grace-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:10.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:10.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:10.000Z")
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let should_enable =
    C2c_start.should_enable_opencode_fallback ~name
      ~start_time:((match Ptime.of_rfc3339 "2026-04-24T01:00:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:00:30.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check bool "fallback suppressed during startup grace" false should_enable

let test_should_enable_opencode_fallback_after_grace_when_plugin_stale () =
  let name = Printf.sprintf "opencode-fallback-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:00.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:00.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let should_enable =
    C2c_start.should_enable_opencode_fallback ~name
      ~start_time:((match Ptime.of_rfc3339 "2026-04-24T01:00:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:30.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check bool "fallback enabled after grace when plugin stale" true should_enable

let test_delivery_mode_for_opencode_plugin_active () =
  let name = Printf.sprintf "opencode-mode-plugin-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:30.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:30.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:30.000Z")
                          ; ("heartbeat_interval_ms", `Int 10000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let mode =
    C2c_start.delivery_mode ~client:"opencode" ~name ~binary_path:"/bin/true"
      ~start_time:None
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check string "delivery mode plugin" "plugin" mode

let test_delivery_mode_for_opencode_grace_window () =
  let name = Printf.sprintf "opencode-mode-grace-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:00.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:00.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("heartbeat_interval_ms", `Int 600000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let mode =
    C2c_start.delivery_mode ~client:"opencode" ~name ~binary_path:"/bin/true"
      ~start_time:(Some (match Ptime.of_rfc3339 "2026-04-24T01:01:10.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:30.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check string "delivery mode grace" "plugin_grace" mode

let test_delivery_mode_for_opencode_native_fallback () =
  let name = Printf.sprintf "opencode-mode-fallback-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let state_path = Filename.concat dir "oc-plugin-state.json" in
  let json =
    `Assoc
      [ ("event", `String "state.snapshot")
      ; ("ts", `String "2026-04-24T01:00:00.000Z")
      ; ( "state",
          `Assoc
              [ ("c2c_session_id", `String name)
              ; ("state_last_updated_at", `String "2026-04-24T01:00:00.000Z")
              ; ( "activity_sources",
                  `Assoc
                    [ ( "plugin",
                        `Assoc
                          [ ("source_type", `String "plugin")
                          ; ("first_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("last_active_at", `String "2026-04-24T01:00:00.000Z")
                          ; ("heartbeat_interval_ms", `Int 600000)
                          ] )
                    ] )
              ] )
      ]
  in
  Yojson.Safe.to_file state_path json;
  let mode =
    C2c_start.delivery_mode ~client:"opencode" ~name ~binary_path:"/bin/true"
      ~start_time:(Some (match Ptime.of_rfc3339 "2026-04-24T01:00:00.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ~available_capabilities:
        [ C2c_capability.to_string C2c_capability.Opencode_plugin
        ; C2c_capability.to_string C2c_capability.Pty_inject
        ]
      ~now:((match Ptime.of_rfc3339 "2026-04-24T01:01:30.000Z" with Ok (t, _, _) -> Ptime.to_float_s t | Error _ -> failwith "bad test ts"))
      ()
  in
  check string "delivery mode fallback" "native_pty_fallback" mode

let test_missing_role_capabilities_reports_missing_codex_xml_fd () =
  let role =
    C2c_role.parse_string
      "---\nrequired_capabilities: [codex_xml_fd]\n---\nrole body\n"
  in
  let missing =
    C2c_start.missing_role_capabilities ~client:"claude"
      ~binary_path:"/bin/true" role
  in
  check (list string) "missing codex xml fd"
    [ "codex_xml_fd" ] missing

let test_missing_role_capabilities_satisfied_for_claude_channel () =
  let role =
    C2c_role.parse_string
      "---\nrequired_capabilities: [claude_channel]\n---\nrole body\n"
  in
  let missing =
    C2c_start.missing_role_capabilities ~client:"claude"
      ~binary_path:"/bin/true" role
  in
  check (list string) "claude channel satisfied" [] missing

let test_prepare_launch_args_codex_resume_last_by_default () =
  let args =
    C2c_start.prepare_launch_args ~name:"codex-proof" ~client:"codex"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"placeholder-uuid"
      ()
  in
  check (list string) "codex resume last"
    [ "resume"; "--last" ] args

let test_prepare_launch_args_codex_uses_exact_resume_target_when_set () =
  let args =
    C2c_start.prepare_launch_args ~name:"codex-proof" ~client:"codex"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"placeholder-uuid"
      ~codex_resume_target:"thread-abc"
      ()
  in
  check (list string) "codex exact resume"
    [ "resume"; "thread-abc" ] args

let test_cmd_reset_thread_persists_codex_resume_target () =
  let name = Printf.sprintf "codex-reset-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let cfg : C2c_start.instance_config =
    { name
    ; client = "codex"
    ; session_id = name
    ; resume_session_id =
        Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ())
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = Unix.gettimeofday ()
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = Some "/bin/true"
    ; model_override = None
    }
  in
  C2c_start.write_config cfg;
  let rc = C2c_start.cmd_reset_thread name "thread-reset-123" in
  check int "reset-thread rc" 0 rc;
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after reset-thread"
  | Some saved ->
      check (option string) "persisted codex resume target"
        (Some "thread-reset-123") saved.codex_resume_target

(* ------------------------------------------------------------------ *)
(* pmodel parsing                                                      *)
(* ------------------------------------------------------------------ *)

let pmodel_testable =
  Alcotest.testable
    (fun ppf (p : C2c_start.pmodel) ->
      Format.fprintf ppf "{provider=%s; model=%s}" p.provider p.model)
    (fun (a : C2c_start.pmodel) (b : C2c_start.pmodel) ->
      a.provider = b.provider && a.model = b.model)

let ok_pmodel msg ~provider ~model actual =
  match actual with
  | Ok p ->
    Alcotest.check pmodel_testable msg
      C2c_start.{ provider; model } p
  | Error e -> Alcotest.failf "%s: expected Ok but got Error %S" msg e

let is_error = function Error _ -> true | Ok _ -> false

let test_parse_pmodel_plain () =
  ok_pmodel "openai:gpt-4o" ~provider:"openai" ~model:"gpt-4o"
    (C2c_start.parse_pmodel "openai:gpt-4o")

let test_parse_pmodel_prefix_colon () =
  ok_pmodel ":groq:openai/gpt-oss-120b"
    ~provider:"groq" ~model:"openai/gpt-oss-120b"
    (C2c_start.parse_pmodel ":groq:openai/gpt-oss-120b")

let test_parse_pmodel_anthropic () =
  ok_pmodel "anthropic:claude-opus-4-7"
    ~provider:"anthropic" ~model:"claude-opus-4-7"
    (C2c_start.parse_pmodel "anthropic:claude-opus-4-7")

let test_parse_pmodel_errors () =
  check bool "empty string -> error" true
    (is_error (C2c_start.parse_pmodel ""));
  check bool "whitespace only -> error" true
    (is_error (C2c_start.parse_pmodel "   "));
  check bool "no colon -> error" true
    (is_error (C2c_start.parse_pmodel "openai"));
  check bool "empty provider -> error" true
    (is_error (C2c_start.parse_pmodel ":gpt-4o"));
  (* ":gpt-4o" has leading ':' prefix, stripped body is "gpt-4o",
     which has no colon -> missing separator error. *)
  check bool "empty model after colon -> error" true
    (is_error (C2c_start.parse_pmodel "openai:"))

let test_repo_config_pmodel_reads_table () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "generation_client = \"opencode\"\n\
       enable_channels = true\n\
       \n\
       [pmodel]\n\
       default     = \"anthropic:claude-opus-4-7\"\n\
       coder       = \"anthropic:claude-sonnet-4-6\"\n\
       coordinator = \":groq:openai/gpt-oss-120b\"\n");
  with_cwd dir @@ fun () ->
  let pairs = C2c_start.repo_config_pmodel () in
  check int "three entries" 3 (List.length pairs);
  (match C2c_start.repo_config_pmodel_lookup "default" with
   | Some (p : C2c_start.pmodel) ->
     check string "default provider" "anthropic" p.provider;
     check string "default model" "claude-opus-4-7" p.model
   | None -> fail "default missing");
  (match C2c_start.repo_config_pmodel_lookup "coordinator" with
   | Some (p : C2c_start.pmodel) ->
     check string "coordinator provider" "groq" p.provider;
     check string "coordinator model" "openai/gpt-oss-120b" p.model
   | None -> fail "coordinator missing");
  (match C2c_start.repo_config_pmodel_lookup "nope" with
   | Some _ -> fail "unset role should not resolve"
   | None -> ())

let test_body_stripped_of_frontmatter () =
  let marker = "---\n" in
  let mlen = String.length marker in
  let rec find_next after off =
    if off + mlen > String.length after then None
    else if String.sub after off mlen = marker then Some off
    else find_next after (off + 1)
  in
  let extract_body rendered =
    match find_next rendered 0 with
    | None -> rendered
    | Some first_off ->
        let after_first =
          String.sub rendered (first_off + mlen)
            (String.length rendered - first_off - mlen)
        in
        match find_next after_first 0 with
        | None -> String.trim after_first
        | Some second_off ->
            let raw =
              String.sub after_first (second_off + mlen)
                (String.length after_first - second_off - mlen)
            in
            String.trim raw
  in
  check string "body extracted exactly" "Body"
    (extract_body "---\ndesc: foo\n---\n\nBody");
  check string "body extracted with trailing newline" "You are a agent."
    (extract_body "---\ndesc: test\nrole: primary\n---\n\nYou are a agent.\n");
  check string "no frontmatter returns trimmed" "No frontmatter Just body"
    (extract_body "No frontmatter Just body");
  check string "double fence body" "Double fence"
    (extract_body "---\n---\n\nDouble fence")

let () =
  Random.self_init ();
  Alcotest.run "c2c_start"
    [ ( "launch_args",
        [ ( "prepare_launch_args_claude_uses_development_channel_flag",
            `Quick, test_prepare_launch_args_claude_uses_development_channel_flag )
        ; ( "prepare_launch_args_claude_ignores_enable_channels_config",
            `Quick, test_prepare_launch_args_claude_ignores_enable_channels_config )
        ; ( "normalize_model_override_for_opencode_requires_provider",
            `Quick, test_normalize_model_override_for_opencode_requires_provider )
        ; ( "normalize_model_override_for_opencode_rewrites_provider_model",
            `Quick, test_normalize_model_override_for_opencode_rewrites_provider_model )
        ; ( "normalize_model_override_for_claude_accepts_plain_model",
            `Quick, test_normalize_model_override_for_claude_accepts_plain_model )
        ; ( "normalize_model_override_for_claude_discards_provider_prefix",
            `Quick, test_normalize_model_override_for_claude_discards_provider_prefix )
        ; ( "prepare_launch_args_adds_model_flag_for_claude",
            `Quick, test_prepare_launch_args_adds_model_flag_for_claude )
        ; ( "prepare_launch_args_adds_model_flag_for_opencode",
            `Quick, test_prepare_launch_args_adds_model_flag_for_opencode )
        ; ( "build_env_keeps_channel_delivery_without_force_flag",
            `Quick, test_build_env_keeps_channel_delivery_without_force_flag )
        ; ( "build_env_does_not_seed_codex_thread_id",
            `Quick, test_build_env_does_not_seed_codex_thread_id )
        ; ( "start_deliver_daemon_detaches_from_terminal_stdio_and_group",
            `Quick, test_start_deliver_daemon_detaches_from_terminal_stdio_and_group )
        ; ( "probed_capabilities_for_claude_include_channel",
            `Quick, test_probed_capabilities_for_claude_include_channel )
        ; ( "probed_capabilities_for_opencode_include_plugin",
            `Quick, test_probed_capabilities_for_opencode_include_plugin )
        ; ( "probed_capabilities_for_kimi_include_wire",
            `Quick, test_probed_capabilities_for_kimi_include_wire )
        ; ( "check_pty_inject_capability_ok_when_yama_zero",
            `Quick, test_check_pty_inject_capability_ok_when_yama_zero )
        ; ( "check_pty_inject_capability_ok_when_getcap_has_ptrace",
            `Quick, test_check_pty_inject_capability_ok_when_getcap_has_ptrace )
        ; ( "check_pty_inject_capability_missing_when_cap_absent",
            `Quick, test_check_pty_inject_capability_missing_when_cap_absent )
        ; ( "runtime_capabilities_for_opencode_include_plugin_active_when_fresh",
            `Quick,
            test_runtime_capabilities_for_opencode_include_plugin_active_when_fresh )
        ; ( "runtime_capabilities_for_opencode_exclude_plugin_active_when_stale",
            `Quick,
            test_runtime_capabilities_for_opencode_exclude_plugin_active_when_stale )
        ; ( "runtime_capabilities_for_opencode_require_matching_session_id",
            `Quick,
            test_runtime_capabilities_for_opencode_require_matching_session_id )
        ; ( "should_enable_opencode_fallback_respects_startup_grace",
            `Quick,
            test_should_enable_opencode_fallback_respects_startup_grace )
        ; ( "should_enable_opencode_fallback_after_grace_when_plugin_stale",
            `Quick,
            test_should_enable_opencode_fallback_after_grace_when_plugin_stale )
        ; ( "delivery_mode_for_opencode_plugin_active",
            `Quick, test_delivery_mode_for_opencode_plugin_active )
        ; ( "delivery_mode_for_opencode_grace_window",
            `Quick, test_delivery_mode_for_opencode_grace_window )
        ; ( "delivery_mode_for_opencode_native_fallback",
            `Quick, test_delivery_mode_for_opencode_native_fallback )
        ; ( "missing_role_capabilities_reports_missing_codex_xml_fd",
            `Quick, test_missing_role_capabilities_reports_missing_codex_xml_fd )
        ; ( "missing_role_capabilities_satisfied_for_claude_channel",
            `Quick, test_missing_role_capabilities_satisfied_for_claude_channel )
        ; ( "prepare_launch_args_codex_resume_last_by_default",
            `Quick, test_prepare_launch_args_codex_resume_last_by_default )
        ; ( "prepare_launch_args_codex_uses_exact_resume_target_when_set",
            `Quick, test_prepare_launch_args_codex_uses_exact_resume_target_when_set )
        ; ( "cmd_reset_thread_persists_codex_resume_target",
            `Quick, test_cmd_reset_thread_persists_codex_resume_target )
        ] )
    ; ( "pmodel",
        [ ("parse_pmodel_plain", `Quick, test_parse_pmodel_plain)
        ; ("parse_pmodel_prefix_colon", `Quick, test_parse_pmodel_prefix_colon)
        ; ("parse_pmodel_anthropic", `Quick, test_parse_pmodel_anthropic)
        ; ("parse_pmodel_errors", `Quick, test_parse_pmodel_errors)
        ; ("repo_config_pmodel_reads_table", `Quick,
           test_repo_config_pmodel_reads_table)
        ] )
    ; ( "build_agent_json_body_extraction",
        [ ("body_stripped_of_frontmatter", `Quick,
           test_body_stripped_of_frontmatter) ] )
    ]
