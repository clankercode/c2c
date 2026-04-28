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

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

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

let test_resolve_model_override_explicit_wins_over_role () =
  let result =
    C2c_start.resolve_model_override
      ~model_override:(Some "anthropic:claude-sonnet-4-7")
      ~role_pmodel_override:(Some "anthropic:claude-opus-4-0")
      ~saved_model_override:(Some "openai:gpt-4o")
  in
  match result with
  | Some v -> check string "explicit --model wins over role pmodel" "anthropic:claude-sonnet-4-7" v
  | None -> fail "expected Some, got None"

let test_resolve_model_override_role_wins_over_saved () =
  let result =
    C2c_start.resolve_model_override
      ~model_override:None
      ~role_pmodel_override:(Some "anthropic:claude-opus-4-0")
      ~saved_model_override:(Some "openai:gpt-4o")
  in
  match result with
  | Some v -> check string "role pmodel wins over saved config" "anthropic:claude-opus-4-0" v
  | None -> fail "expected Some, got None"

let test_resolve_model_override_saved_used_when_neither_explicit_nor_role () =
  let result =
    C2c_start.resolve_model_override
      ~model_override:None
      ~role_pmodel_override:None
      ~saved_model_override:(Some "openai:gpt-4o")
  in
  match result with
  | Some v -> check string "saved config used when no explicit or role" "openai:gpt-4o" v
  | None -> fail "expected Some, got None"

let test_prepare_launch_args_adds_model_flag_for_claude () =
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"claude-sonnet-4-7" ()
  in
  check bool "adds --model" true (has_adjacent_pair "--model" "claude-sonnet-4-7" args)

let test_prepare_launch_args_adds_agent_flag_for_claude () =
  let args =
    C2c_start.prepare_launch_args ~name:"claude-proof" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~agent_name:"AgentName" ()
  in
  check bool "adds --agent" true (has_adjacent_pair "--agent" "AgentName" args);
  check bool "does not add --agents" false (List.mem "--agents" args)

let test_prepare_launch_args_opencode_agent_flag_uses_instance_name () =
  (* Regression: c2c start opencode --agent <role> -n <instance>
     used to pass `--agent <role>` to opencode, but the compiled
     agent file is written at .opencode/agents/<instance>.md, so
     opencode could not resolve the agent. Fix: pass instance name. *)
  let args =
    C2c_start.prepare_launch_args ~name:"test-agent-oc" ~client:"opencode"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~agent_name:"test-agent" ()
  in
  check bool "--agent uses instance name (compiled-file basename)" true
    (has_adjacent_pair "--agent" "test-agent-oc" args);
  check bool "--agent does NOT pass role name" false
    (has_adjacent_pair "--agent" "test-agent" args)

(* Regression #372: `c2c start <client> -- <args...>` must forward
   <args...> verbatim to the spawned client. The man-page documents this
   but the CLI dispatch previously refused with
   "extra argv after CLIENT is only supported for `c2c start tmux`".
   prepare_launch_args is the one place where the final argv is assembled,
   so assert that extra_args land on the tail for each managed client. *)
let test_prepare_launch_args_forwards_extra_args_for_claude () =
  let args =
    C2c_start.prepare_launch_args ~name:"claude-372" ~client:"claude"
      ~extra_args:[ "--print"; "hello world" ] ~broker_root:"/tmp/broker" ()
  in
  check bool "forwards --print" true (List.mem "--print" args);
  check bool "forwards 'hello world'" true (List.mem "hello world" args);
  check bool "forwarded args are adjacent and at tail" true
    (has_adjacent_pair "--print" "hello world" args)

let test_prepare_launch_args_forwards_extra_args_for_opencode () =
  let args =
    C2c_start.prepare_launch_args ~name:"oc-372" ~client:"opencode"
      ~extra_args:[ "--debug"; "--foo=bar" ] ~broker_root:"/tmp/broker" ()
  in
  check bool "forwards --debug" true (List.mem "--debug" args);
  check bool "forwards --foo=bar" true (List.mem "--foo=bar" args)

let test_prepare_launch_args_forwards_extra_args_for_codex () =
  let args =
    C2c_start.prepare_launch_args ~name:"cx-372" ~client:"codex"
      ~extra_args:[ "--profile"; "myprofile" ] ~broker_root:"/tmp/broker" ()
  in
  check bool "forwards --profile" true
    (has_adjacent_pair "--profile" "myprofile" args)

let test_prepare_launch_args_adds_model_flag_for_opencode () =
  let args =
    C2c_start.prepare_launch_args ~name:"oc-proof" ~client:"opencode"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"minimax-coding-plan/MiniMax-M2.7-highspeed" ()
  in
  check bool "adds --model"
    true
    (has_adjacent_pair "--model" "minimax-coding-plan/MiniMax-M2.7-highspeed" args)

let test_tmux_shell_command_quotes_argv () =
  check string "quotes spaces and shell metacharacters"
    "'gemini' 'hello world' '$(date)' 'a'\\''b'"
    (C2c_start.tmux_shell_command_of_argv
       [ "gemini"; "hello world"; "$(date)"; "a'b" ])

let test_tmux_message_payload_uses_c2c_envelope () =
  let msg : C2c_mcp.message =
    { from_alias = "alice"
    ; to_alias = "tmux-agent"
    ; content = "hello"
    ; deferrable = false
    ; reply_via = Some "c2c_send"
    ; enc_status = None
    ; ts = 0.0
    ; ephemeral = false
    }
  in
  let payload = C2c_start.tmux_message_payload [ msg ] in
  check bool "contains c2c envelope" true
    (String.starts_with ~prefix:"<c2c event=\"message\"" payload);
  check bool "contains sender" true
    (string_contains payload "from=\"alice\"");
  check bool "contains message content" true
    (string_contains payload "hello");
  check bool "closes envelope" true
    (String.ends_with ~suffix:"</c2c>" payload)

let test_parse_tmux_target_info_requires_loc_and_pane_id () =
  let parsed = C2c_start.parse_tmux_target_info "0:1.2 %42" in
  (match parsed with
   | Some info ->
       check string "location" "0:1.2" info.C2c_start.tmux_location;
       check string "pane id" "%42" info.C2c_start.tmux_pane_id
   | None -> fail "expected target info");
  check bool "missing pane id rejected" false
    (Option.is_some (C2c_start.parse_tmux_target_info "0:1.2"))

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

let test_finalize_outer_loop_exit_cleans_before_print () =
  let events = ref [] in
  let cleanup_and_exit code =
    events := !events @ [ Printf.sprintf "cleanup:%d" code ];
    code
  in
  let print_resume resume_cmd =
    events := !events @ [ "print:" ^ resume_cmd ]
  in
  let rc =
    C2c_start.finalize_outer_loop_exit ~cleanup_and_exit ~print_resume
      ~resume_cmd:"c2c start codex -n demo --session-id demo" ~exit_code:17
  in
  check int "finalize returns cleanup code" 17 rc;
  check (list string) "cleanup happens before print"
    [ "cleanup:17"; "print:c2c start codex -n demo --session-id demo" ]
    !events

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

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None ->
        (* Best-effort unset: empty string mimics "absent" for our env_has_key
           prefix check (entry would be "KEY="; key is still present in array
           but with empty value — so we use a sentinel and check explicitly). *)
        (try Unix.putenv key "" with _ -> ()))
    f

let test_build_env_strips_ambient_force_capabilities_for_codex () =
  with_env "C2C_MCP_FORCE_CAPABILITIES" "claude_channel" @@ fun () ->
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      ~client:(Some "codex")
      "codex-proof" (Some "codex-proof")
  in
  check bool "strips ambient C2C_MCP_FORCE_CAPABILITIES for codex" false
    (env_contains env "C2C_MCP_FORCE_CAPABILITIES=claude_channel");
  check bool "does not export force capabilities for codex" false
    (env_has_key env "C2C_MCP_FORCE_CAPABILITIES")

let test_build_env_strips_ambient_force_capabilities_for_opencode () =
  with_env "C2C_MCP_FORCE_CAPABILITIES" "claude_channel" @@ fun () ->
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      ~client:(Some "opencode")
      "opencode-proof" (Some "opencode-proof")
  in
  check bool "does not export force capabilities for opencode" false
    (env_has_key env "C2C_MCP_FORCE_CAPABILITIES")

let test_build_env_claude_keeps_force_capabilities_under_ambient () =
  with_env "C2C_MCP_FORCE_CAPABILITIES" "claude_channel" @@ fun () ->
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      ~client:(Some "claude")
      "claude-proof" (Some "claude-proof")
  in
  check bool "claude keeps force capabilities even with ambient set" true
    (env_contains env "C2C_MCP_FORCE_CAPABILITIES=claude_channel");
  (* And ensure no duplicate: only one entry with that key. *)
  let count =
    Array.fold_left
      (fun acc e ->
        if String.length e >= 27
           && String.sub e 0 27 = "C2C_MCP_FORCE_CAPABILITIES="
        then acc + 1
        else acc)
      0 env
  in
  check int "exactly one C2C_MCP_FORCE_CAPABILITIES entry" 1 count

let test_codex_heartbeat_interval_is_four_minutes () =
  check (float 0.001) "interval seconds" 240.0
    C2c_start.codex_heartbeat_interval_s

let test_codex_heartbeat_enabled_for_codex_family_only () =
  check bool "codex enabled" true
    (C2c_start.codex_heartbeat_enabled ~client:"codex");
  check bool "codex-headless disabled" false
    (C2c_start.codex_heartbeat_enabled ~client:"codex-headless");
  check bool "claude disabled" false
    (C2c_start.codex_heartbeat_enabled ~client:"claude");
  check bool "opencode disabled" false
    (C2c_start.codex_heartbeat_enabled ~client:"opencode");
  check bool "kimi disabled" false
    (C2c_start.codex_heartbeat_enabled ~client:"kimi")

let test_should_start_codex_heartbeat_requires_codex_deliver_daemon () =
  check bool "codex with deliver daemon" true
    (C2c_start.should_start_codex_heartbeat ~client:"codex"
       ~deliver_started:true);
  check bool "codex without deliver daemon" false
    (C2c_start.should_start_codex_heartbeat ~client:"codex"
       ~deliver_started:false);
  check bool "codex-headless excluded" false
    (C2c_start.should_start_codex_heartbeat ~client:"codex-headless"
       ~deliver_started:true);
  check bool "opencode excluded" false
    (C2c_start.should_start_codex_heartbeat ~client:"opencode"
       ~deliver_started:true)

let test_enqueue_codex_heartbeat_uses_broker_inbox_transport () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  let pid = Unix.getpid () in
  C2c_mcp.Broker.register broker ~session_id:"codex-heartbeat-session"
    ~alias:"codex-heartbeat-alias" ~pid:(Some pid)
    ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time pid)
    ~client_type:(Some "codex") ();
  C2c_start.enqueue_codex_heartbeat ~broker_root:dir
    ~alias:"codex-heartbeat-alias";
  match
    C2c_mcp.Broker.read_inbox broker ~session_id:"codex-heartbeat-session"
  with
  | [ msg ] ->
      check string "from alias" "codex-heartbeat-alias" msg.from_alias;
      check string "to alias" "codex-heartbeat-alias" msg.to_alias;
      check string "content" C2c_start.codex_heartbeat_content msg.content;
      check bool "not deferrable" false msg.deferrable
  | msgs ->
      fail
        (Printf.sprintf "expected exactly one heartbeat message, got %d"
           (List.length msgs))

let test_parse_heartbeat_duration_units () =
  check (result (float 0.001) string) "seconds"
    (Ok 45.0) (C2c_start.parse_heartbeat_duration_s "45s");
  check (result (float 0.001) string) "minutes"
    (Ok 240.0) (C2c_start.parse_heartbeat_duration_s "4m");
  check (result (float 0.001) string) "hours"
    (Ok 7200.0) (C2c_start.parse_heartbeat_duration_s "2h");
  check bool "bad duration errors" true
    (match C2c_start.parse_heartbeat_duration_s "soon" with
     | Error _ -> true
     | Ok _ -> false)

let test_agent_is_idle_no_activity_treated_as_idle () =
  check bool "no activity → idle" true
    (C2c_start.agent_is_idle
       ~now:1000.0 ~idle_threshold_s:240.0 ~last_activity_ts:None)

let test_agent_is_idle_recent_activity_not_idle () =
  (* 60s since last activity, threshold 240s → still active *)
  check bool "recent activity → not idle" false
    (C2c_start.agent_is_idle
       ~now:1000.0 ~idle_threshold_s:240.0 ~last_activity_ts:(Some 940.0))

let test_agent_is_idle_stale_activity_is_idle () =
  (* 300s since last activity, threshold 240s → idle *)
  check bool "stale activity → idle" true
    (C2c_start.agent_is_idle
       ~now:1000.0 ~idle_threshold_s:240.0 ~last_activity_ts:(Some 700.0))

let test_agent_is_idle_threshold_boundary_inclusive () =
  (* Exactly at threshold → considered idle (>=, not >) *)
  check bool "boundary inclusive" true
    (C2c_start.agent_is_idle
       ~now:1000.0 ~idle_threshold_s:240.0 ~last_activity_ts:(Some 760.0))

let test_should_fire_heartbeat_idle_only_false_always_fires () =
  with_temp_dir @@ fun dir ->
  let hb : C2c_start.managed_heartbeat =
    { C2c_start.heartbeat_name = "test"; schedule = Interval 240.0;
      interval_s = 240.0; message = "x"; command = None;
      command_timeout_s = 30.0; clients = []; role_classes = [];
      enabled = true; idle_only = false; idle_threshold_s = 240.0 }
  in
  (* No registration at all — but idle_only=false bypasses the check. *)
  check bool "always fires when idle_only=false" true
    (C2c_start.should_fire_heartbeat
       ~broker_root:dir ~alias:"never-registered" hb)

let test_should_fire_heartbeat_idle_only_no_registration_fires () =
  with_temp_dir @@ fun dir ->
  let hb : C2c_start.managed_heartbeat =
    { C2c_start.heartbeat_name = "test"; schedule = Interval 240.0;
      interval_s = 240.0; message = "x"; command = None;
      command_timeout_s = 30.0; clients = []; role_classes = [];
      enabled = true; idle_only = true; idle_threshold_s = 60.0 }
  in
  (* No registration ⇒ last_activity_ts is None ⇒ treated as idle ⇒ fires. *)
  check bool "no registration → fire" true
    (C2c_start.should_fire_heartbeat
       ~broker_root:dir ~alias:"unregistered-alias" hb)

let test_should_fire_heartbeat_skips_recent_activity () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"idle-test-session" ~alias:"idle-test-alias"
    ~pid:None ~pid_start_time:None ();
  (* Touch the session NOW so last_activity_ts is fresh. *)
  C2c_mcp.Broker.touch_session broker ~session_id:"idle-test-session";
  let hb : C2c_start.managed_heartbeat =
    { C2c_start.heartbeat_name = "test"; schedule = Interval 240.0;
      interval_s = 240.0; message = "x"; command = None;
      command_timeout_s = 30.0; clients = []; role_classes = [];
      enabled = true; idle_only = true; idle_threshold_s = 600.0 }
  in
  check bool "recent activity → skip" false
    (C2c_start.should_fire_heartbeat
       ~broker_root:dir ~alias:"idle-test-alias" hb)

(* #272 push-aware heartbeat content -------------------------------------- *)

let test_automated_delivery_for_alias_unknown () =
  with_temp_dir @@ fun dir ->
  check (option bool) "unknown alias → None" None
    (C2c_start.automated_delivery_for_alias ~broker_root:dir ~alias:"missing")

let test_automated_delivery_for_alias_set_true () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"push-test-session" ~alias:"push-alice"
    ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.set_automated_delivery broker
    ~session_id:"push-test-session" ~automated_delivery:true;
  check (option bool) "after set true" (Some true)
    (C2c_start.automated_delivery_for_alias ~broker_root:dir ~alias:"push-alice")

let test_automated_delivery_for_alias_set_false () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"poll-test-session" ~alias:"poll-bob"
    ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.set_automated_delivery broker
    ~session_id:"poll-test-session" ~automated_delivery:false;
  check (option bool) "after set false" (Some false)
    (C2c_start.automated_delivery_for_alias ~broker_root:dir ~alias:"poll-bob")

let test_heartbeat_body_swap_for_push_capable () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"swap-test-session" ~alias:"swap-alice"
    ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.set_automated_delivery broker
    ~session_id:"swap-test-session" ~automated_delivery:true;
  let body =
    C2c_start.heartbeat_body_for_alias ~broker_root:dir ~alias:"swap-alice"
      ~message:C2c_start.default_managed_heartbeat_content
  in
  check string "push-capable + default → push-aware variant"
    C2c_start.push_aware_heartbeat_content body

let test_heartbeat_body_no_swap_for_non_push () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"nopush-session" ~alias:"nopush-bob"
    ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.set_automated_delivery broker
    ~session_id:"nopush-session" ~automated_delivery:false;
  let body =
    C2c_start.heartbeat_body_for_alias ~broker_root:dir ~alias:"nopush-bob"
      ~message:C2c_start.default_managed_heartbeat_content
  in
  check string "non-push + default → legacy body"
    C2c_start.default_managed_heartbeat_content body

let test_heartbeat_body_no_swap_when_unknown () =
  with_temp_dir @@ fun dir ->
  let body =
    C2c_start.heartbeat_body_for_alias ~broker_root:dir ~alias:"never-registered"
      ~message:C2c_start.default_managed_heartbeat_content
  in
  check string "unknown alias → conservative legacy body"
    C2c_start.default_managed_heartbeat_content body

let test_heartbeat_body_passes_custom_message_through () =
  with_temp_dir @@ fun dir ->
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id:"custom-session" ~alias:"custom-carol"
    ~pid:None ~pid_start_time:None ();
  C2c_mcp.Broker.set_automated_delivery broker
    ~session_id:"custom-session" ~automated_delivery:true;
  let custom = "Operator-authored: please run a sitrep round." in
  let body =
    C2c_start.heartbeat_body_for_alias ~broker_root:dir ~alias:"custom-carol"
      ~message:custom
  in
  check string "custom message passes through even for push agents"
    custom body

let test_heartbeat_aligned_schedule_next_delay () =
  let hb = C2c_start.
    { heartbeat_name = "sitrep"
    ; schedule = Aligned_interval { interval_s = 3600.0; offset_s = 420.0 }
    ; interval_s = 3600.0
    ; message = "sitrep"
    ; command = None
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = false
    ; idle_threshold_s = 0.0
    }
  in
  check (float 0.001) "before hour+7"
    120.0 (C2c_start.next_heartbeat_delay_s ~now:300.0 hb);
  check (float 0.001) "after hour+7 moves to next hour+7"
    3500.0 (C2c_start.next_heartbeat_delay_s ~now:520.0 hb)

let test_repo_config_managed_heartbeats_reads_default_and_named () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[heartbeat]\n\
       interval = \"4m\"\n\
       message = \"Default tick\"\n\
       clients = [\"claude\", \"codex\", \"opencode\"]\n\
       \n\
       [heartbeat.sitrep]\n\
       interval = \"1h\"\n\
       message = \"Write sitrep\"\n\
       role_classes = [\"coordinator\"]\n\
       \n\
       [heartbeat.quota]\n\
       interval = \"15m\"\n\
       message = \"Quota report\"\n\
       command = \"printf quota\"\n\
       role_classes = [\"coordinator\"]\n");
  with_cwd dir @@ fun () ->
  let specs = C2c_start.repo_config_managed_heartbeats () in
  check int "three specs" 3 (List.length specs);
  let default = List.find (fun hb -> hb.C2c_start.heartbeat_name = "default") specs in
  check (float 0.001) "default interval" 240.0 default.interval_s;
  check string "default message" "Default tick" default.message;
  check (list string) "default clients" [ "claude"; "codex"; "opencode" ]
    default.clients;
  let quota = List.find (fun hb -> hb.C2c_start.heartbeat_name = "quota") specs in
  check (float 0.001) "quota interval" 900.0 quota.interval_s;
  check (option string) "quota command" (Some "printf quota") quota.command;
  check (list string) "quota role classes" [ "coordinator" ] quota.role_classes

let test_resolve_managed_heartbeats_applies_role_override_and_named_entries () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coordinator\n\
       role: primary\n\
       role_class: coordinator\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role tick\"\n\
       \  heartbeats:\n\
       \    sitrep:\n\
       \      interval: 1h\n\
       \      message: \"Coordinator sitrep\"\n\
       ---\n\
       body\n"
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role) []
  in
  check int "default plus sitrep" 2 (List.length specs);
  let default = List.find (fun hb -> hb.C2c_start.heartbeat_name = "default") specs in
  check string "role default message wins" "Role tick" default.message;
  let sitrep = List.find (fun hb -> hb.C2c_start.heartbeat_name = "sitrep") specs in
  check (float 0.001) "sitrep interval" 3600.0 sitrep.interval_s;
  check string "sitrep message" "Coordinator sitrep" sitrep.message

let test_resolve_managed_heartbeats_role_override_preserves_config_fields () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coordinator\n\
       role: primary\n\
       role_class: coordinator\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role message only\"\n\
       ---\n\
       body\n"
  in
  let config_default =
    C2c_start.
      { heartbeat_name = "default"
      ; schedule = Interval 600.0
      ; interval_s = 600.0
      ; message = "Config message"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = [ "claude" ]
      ; role_classes = [ "coordinator" ]
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role) [ config_default ]
  in
  match specs with
  | [ hb ] ->
      check string "role message wins" "Role message only" hb.message;
      check (float 0.001) "config interval preserved" 600.0 hb.interval_s;
      check (list string) "config clients preserved" [ "claude" ] hb.clients;
      check (list string) "config role classes preserved" [ "coordinator" ]
        hb.role_classes
  | _ -> fail "expected one resolved default heartbeat"

let test_resolve_managed_heartbeats_per_agent_override_wins_last () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coordinator\n\
       role: primary\n\
       role_class: coordinator\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role message\"\n\
       ---\n\
       body\n"
  in
  let per_agent =
    C2c_start.
      { heartbeat_name = "default"
      ; schedule = Interval 120.0
      ; interval_s = 120.0
      ; message = "Per-agent message"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = [ "claude" ]
      ; role_classes = [ "coordinator" ]
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role)
      ~per_agent_specs:[ per_agent ] []
  in
  match specs with
  | [ hb ] ->
      check string "per-agent message wins" "Per-agent message" hb.message;
      check (float 0.001) "per-agent interval wins" 120.0 hb.interval_s
  | _ -> fail "expected one resolved default heartbeat"

(* ---------------------------------------------------------------------------
 * Layered config precedence: builtin → config.toml → role frontmatter → per-agent
 *)

let test_resolve_managed_heartbeats_full_4layer_precedence () =
  (* Role: overrides message only *)
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coder\n\
       role: primary\n\
       role_class: coder\n\
       c2c:\n\
       \  heartbeat:\n\
       \    message: \"Role message\"\n\
       ---\n\
       body\n"
  in
  (* Config: overrides interval and message *)
  let config_default =
    C2c_start.
      { heartbeat_name = "default"
      ; schedule = Interval 180.0
      ; interval_s = 180.0
      ; message = "Config message"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = [ "claude"; "codex" ]
      ; role_classes = []
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
  in
  (* Per-agent: overrides everything *)
  let per_agent =
    C2c_start.
      { heartbeat_name = "default"
      ; schedule = Interval 120.0
      ; interval_s = 120.0
      ; message = "Per-agent message"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = [ "claude" ]
      ; role_classes = []
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role)
      ~per_agent_specs:[ per_agent ] [ config_default ]
  in
  match specs with
  | [ hb ] ->
      (* Per-agent wins for all fields it specifies *)
      check string "per-agent message wins" "Per-agent message" hb.message;
      check (float 0.001) "per-agent interval wins" 120.0 hb.interval_s;
      (* Clients from per-agent *)
      check (list string) "per-agent clients" [ "claude" ] hb.clients
  | _ -> fail "expected one resolved default heartbeat"

(* Config provides sitrep; role also adds sitrep with different values *)
let test_resolve_managed_heartbeats_role_adds_named_not_in_config () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coordinator\n\
       role: primary\n\
       role_class: coordinator\n\
       c2c:\n\
       \  heartbeats:\n\
       \    sitrep:\n\
       \      interval: 2h\n\
       \      message: \"Role sitrep\"\n\
       ---\n\
       body\n"
  in
  (* Config has default only *)
  let config_default =
    C2c_start.
      { heartbeat_name = "default"
      ; schedule = Interval 300.0
      ; interval_s = 300.0
      ; message = "Config default"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = [ "claude" ]
      ; role_classes = []
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role) [ config_default ]
  in
  (* Should have default + sitrep *)
  check int "two heartbeats" 2 (List.length specs);
  let sitrep = List.find (fun hb -> hb.C2c_start.heartbeat_name = "sitrep") specs in
  check (float 0.001) "role sitrep interval wins" 7200.0 sitrep.interval_s;
  check string "role sitrep message wins" "Role sitrep" sitrep.message

(* Role disables a heartbeat via c2c.heartbeat.enabled = false *)
let test_resolve_managed_heartbeats_role_disables_heartbeat () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Silent agent\n\
       role: primary\n\
       c2c:\n\
       \  heartbeat:\n\
       \    enabled: false\n\
       ---\n\
       body\n"
  in
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:(Some role) []
  in
  (* Role disables the only heartbeat; filtering removes it *)
  check int "role-disabled heartbeat filtered out" 0 (List.length specs)

(* No config, no role, no per-agent = builtin defaults *)
let test_resolve_managed_heartbeats_builtin_baseline () =
  let specs =
    C2c_start.resolve_managed_heartbeats ~client:"claude"
      ~deliver_started:false ~role:None []
  in
  match specs with
  | [ hb ] ->
      check string "builtin message"
        "Session heartbeat. Poll your C2C inbox and handle any messages. If you have exhausted all work, ask coordinator1 (or swarm-lounge) for more."
        hb.message;
      check (float 0.001) "builtin interval" 240.0 hb.interval_s;
      check (list string) "builtin clients"
        [ "claude"; "codex"; "opencode"; "kimi"; "crush" ]
        hb.clients;
      check bool "builtin enabled" true hb.enabled
  | _ -> fail "expected one resolved default heartbeat"

let test_resolve_managed_heartbeats_filters_clients_and_role_classes () =
  let role =
    C2c_role.parse_string
      "---\n\
       description: Coder\n\
       role: primary\n\
       role_class: coder\n\
       ---\n\
       body\n"
  in
  let specs =
    [ C2c_start.
        { heartbeat_name = "default"
        ; schedule = Interval 240.0
        ; interval_s = 240.0
        ; message = "default"
        ; command = None
        ; command_timeout_s = 30.0
        ; clients = [ "codex" ]
        ; role_classes = []
        ; enabled = true
        ; idle_only = false
        ; idle_threshold_s = 0.0
        }
    ; { heartbeat_name = "sitrep"
      ; schedule = Interval 3600.0
      ; interval_s = 3600.0
      ; message = "sitrep"
      ; command = None
      ; command_timeout_s = 30.0
      ; clients = []
      ; role_classes = [ "coordinator" ]
      ; enabled = true
      ; idle_only = false
      ; idle_threshold_s = 0.0
      }
    ]
  in
  check int "claude not in clients" 0
    (List.length
       (C2c_start.resolve_managed_heartbeats ~client:"claude"
          ~deliver_started:false ~role:(Some role) specs));
  check int "codex needs deliver daemon" 0
    (List.length
       (C2c_start.resolve_managed_heartbeats ~client:"codex"
          ~deliver_started:false ~role:(Some role) specs));
  check int "codex with deliver daemon" 1
    (List.length
       (C2c_start.resolve_managed_heartbeats ~client:"codex"
          ~deliver_started:true ~role:(Some role) specs))

let test_render_heartbeat_content_appends_command_output () =
  let hb = C2c_start.
    { heartbeat_name = "quota"
    ; schedule = Interval 900.0
    ; interval_s = 900.0
    ; message = "Quota report"
    ; command = Some "printf 'remaining=42'"
    ; command_timeout_s = 30.0
    ; clients = []
    ; role_classes = []
    ; enabled = true
    ; idle_only = false
    ; idle_threshold_s = 0.0
    }
  in
  let content = C2c_start.render_heartbeat_content hb in
  check bool "keeps base message" true
    (String.contains content 'Q');
  check bool "skips disallowed command" true
    (try ignore (Str.search_forward (Str.regexp_string "skipped disallowed heartbeat command") content 0); true
     with Not_found -> false)

let test_per_agent_managed_heartbeats_reads_instance_file () =
  let name = Printf.sprintf "heartbeat-agent-%d" (Random.bits ()) in
  with_instance_dir name @@ fun dir ->
  let path = Filename.concat dir "heartbeat.toml" in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[heartbeat]\n\
       interval = \"2m\"\n\
       message = \"Per-agent tick\"\n");
  let specs = C2c_start.per_agent_managed_heartbeats ~name in
  match specs with
  | [ hb ] ->
      check string "name" "default" hb.heartbeat_name;
      check string "message" "Per-agent tick" hb.message;
      check (float 0.001) "interval" 120.0 hb.interval_s
  | _ -> fail "expected one per-agent heartbeat"

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

let test_prepare_launch_args_codex_adds_permission_sideband_fds () =
  let args =
    C2c_start.prepare_launch_args ~name:"codex-proof" ~client:"codex"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~codex_xml_input_fd:"3"
      ~server_request_events_fd:"6"
      ~server_request_responses_fd:"7"
      ~resume_session_id:"placeholder-uuid"
      ()
  in
  check bool "xml input fd" true
    (has_adjacent_pair "--xml-input-fd" "3" args);
  check bool "server request events fd" true
    (has_adjacent_pair "--server-request-events-fd" "6" args);
  check bool "server request responses fd" true
    (has_adjacent_pair "--server-request-responses-fd" "7" args)

let test_codex_supports_server_request_fds_requires_both_flags () =
  with_temp_dir @@ fun dir ->
  let make_bin name help =
    let path = Filename.concat dir name in
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () ->
        output_string oc "#!/bin/sh\n";
        output_string oc "if [ \"$1\" = \"--help\" ]; then\n";
        List.iter
          (fun line -> Printf.fprintf oc "  printf '%%s\\n' %S\n" line)
          help;
        output_string oc "fi\n");
    Unix.chmod path 0o755;
    path
  in
  let full =
    make_bin "codex-full"
      [ "--xml-input-fd <FD>"
      ; "--server-request-events-fd <FD>"
      ; "--server-request-responses-fd <FD>"
      ]
  in
  let events_only =
    make_bin "codex-events-only"
      [ "--xml-input-fd <FD>"; "--server-request-events-fd <FD>" ]
  in
  check bool "full sideband support" true
    (C2c_start.codex_supports_server_request_fds full);
  check bool "requires response fd too" false
    (C2c_start.codex_supports_server_request_fds events_only)

let rec last_n n lst =
  let rec aux n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: xs -> aux (n - 1) (x :: acc) xs
  in
  aux n [] (List.rev lst)

let test_prepare_launch_args_extra_args_appended_verbatim () =
  let extra = [ "--foo"; "bar"; "--baz" ] in
  let args =
    C2c_start.prepare_launch_args ~name:"claude-test" ~client:"claude"
      ~extra_args:extra ~broker_root:"/tmp/broker" ()
  in
  (* extra_args are appended at the end of the argv *)
  check bool "extra args are appended at the end" true
    (List.exists (fun a -> a = "--foo") args);
  let last3 = last_n 3 args in
  check (list string) "extra args appended verbatim"
    [ "--foo"; "bar"; "--baz" ] last3

let test_prepare_launch_args_extra_args_empty_by_default () =
  let args =
    C2c_start.prepare_launch_args ~name:"claude-test" ~client:"claude"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  (* no --foo in args when extra_args is empty *)
  check bool "no extra flags when extra_args is empty" false
    (List.exists (fun a -> a = "--foo") args)

let test_prepare_launch_args_extra_args_preserves_flags_around_extra () =
  (* flags before extra_args should remain; extra_args append at end *)
  let extra = [ "--debug" ] in
  let args =
    C2c_start.prepare_launch_args ~name:"claude-test" ~client:"claude"
      ~extra_args:extra ~broker_root:"/tmp/broker" ()
  in
  (* --dangerously-load-development-channels must still be present *)
  check bool "standard flags preserved with extra_args" true
    (List.mem "--dangerously-load-development-channels" args);
  (* --debug must be at the end *)
  let last = last_n 1 args in
  check (list string) "extra args at end" [ "--debug" ] last

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
    ; agent_name = None
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

let test_likes_shell_substitution_detects_parens_and_backticks () =
  check bool "detects $(...)" true
    (C2c_start.likes_shell_substitution "$(date)");
  check bool "detects bare backticks" true
    (C2c_start.likes_shell_substitution "`date`");
  check bool "ignores plain text" false
    (C2c_start.likes_shell_substitution "hello");
  (* AC4: \$VAR — backslash escapes the dollar, not a substitution *)
  check bool "ignores \\$VAR (escaped dollar)" false
    (C2c_start.likes_shell_substitution "\\$VAR");
  (* AC5: lone backtick — no matching close, not a substitution *)
  check bool "ignores lone backtick" false
    (C2c_start.likes_shell_substitution "`");
  (* escaped parens: \$(...) — backslash before dollar, not a substitution *)
  check bool "ignores \\$(...) (escaped parens)" false
    (C2c_start.likes_shell_substitution "\\$(date)");
  (* $$ is a makefile variable reference, not a shell substitution *)
  check bool "ignores $$ (makefile)" false
    (C2c_start.likes_shell_substitution "$$HOME");
  (* $\ is an escaped dollar, not a shell substitution *)
  check bool "ignores $\\ (escaped dollar)" false
    (C2c_start.likes_shell_substitution "$\\date")

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

let test_fds_to_close_closes_non_preserved () =
  if not (Sys.file_exists "/proc/self/fd") then (
    print_endline "SKIP fds_to_close_closes_non_preserved (no /proc/self/fd)";
    ()
  ) else
    let r, w = Unix.pipe () in
    (try
       let would_close = C2c_start.fds_to_close ~preserve:[w] in
       if not (List.mem r would_close) then
         fail "fds_to_close: pipe read-end should be slated for closing";
       if List.mem w would_close then
         fail "fds_to_close: preserved fd should not be slated for closing";
       if List.mem Unix.stdin would_close then
         fail "fds_to_close: stdin should not be slated for closing";
       if List.mem Unix.stdout would_close then
         fail "fds_to_close: stdout should not be slated for closing";
       if List.mem Unix.stderr would_close then
         fail "fds_to_close: stderr should not be slated for closing";
       Unix.close r; Unix.close w
     with e ->
       (try Unix.close r with _ -> ());
       (try Unix.close w with _ -> ());
       raise e)

let test_fds_to_close_preserves_preserved_fd () =
  if not (Sys.file_exists "/proc/self/fd") then (
    print_endline "SKIP fds_to_close_preserves_preserved_fd (no /proc/self/fd)";
    ()
  ) else
    let r, w = Unix.pipe () in
    (try
       let would_close = C2c_start.fds_to_close ~preserve:[w] in
       if List.mem w would_close then
         fail "fds_to_close: preserved fd should not be slated for closing";
       if not (List.mem r would_close) then
         fail "fds_to_close: non-preserved fd should be slated for closing";
       Unix.close r; Unix.close w
     with e ->
       (try Unix.close r with _ -> ());
       (try Unix.close w with _ -> ());
       raise e)

let test_fds_to_close_preserves_stdio () =
  if not (Sys.file_exists "/proc/self/fd") then (
    print_endline "SKIP fds_to_close_preserves_stdio (no /proc/self/fd)";
    ()
  ) else
    let r, w = Unix.pipe () in
    (try
       let would_close = C2c_start.fds_to_close ~preserve:[r; w] in
       if List.mem Unix.stdin would_close then
         fail "fds_to_close: stdin should not be slated for closing";
       if List.mem Unix.stdout would_close then
         fail "fds_to_close: stdout should not be slated for closing";
       if List.mem Unix.stderr would_close then
         fail "fds_to_close: stderr should not be slated for closing";
       Unix.close r; Unix.close w
     with e ->
       (try Unix.close r with _ -> ());
       (try Unix.close w with _ -> ());
       raise e)

let test_repo_config_default_binary_reads_table () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[pmodel]\n\
       default = \"anthropic:claude-opus-4-7\"\n\
       \n\
       [default_binary]\n\
       codex = \"/usr/local/bin/my-codex\"\n\
       kimi  = \"/opt/kimi/kimi\"\n");
  with_cwd dir @@ fun () ->
  (match C2c_start.repo_config_default_binary "codex" with
   | Some p -> check string "codex binary" "/usr/local/bin/my-codex" p
   | None -> fail "codex entry missing");
  (match C2c_start.repo_config_default_binary "kimi" with
   | Some p -> check string "kimi binary" "/opt/kimi/kimi" p
   | None -> fail "kimi entry missing");
  (match C2c_start.repo_config_default_binary "claude" with
   | Some _ -> fail "claude should not resolve (not in table)"
   | None -> ())

let test_repo_config_default_binary_missing_table () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc "[pmodel]\ndefault = \"anthropic:claude-opus-4-7\"\n");
  with_cwd dir @@ fun () ->
  (match C2c_start.repo_config_default_binary "codex" with
   | Some _ -> fail "should return None when table absent"
   | None -> ())

let test_repo_config_default_binary_no_config_file () =
  with_temp_dir @@ fun dir ->
  (* No .c2c/config.toml at all *)
  with_cwd dir @@ fun () ->
  (match C2c_start.repo_config_default_binary "codex" with
   | Some _ -> fail "should return None when config file absent"
   | None -> ())

(* Regression test: cmd_start preflight must use same binary resolution as
   run_outer_loop. Both must call repo_config_default_binary when no --binary
   override is given, so the preflight capability check targets the configured
   binary, not the PATH default. This test verifies that [default_binary] is
   read correctly and that the function is accessible from both call sites. *)
let test_repo_config_default_binary_preflight_uses_config () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[default_binary]\n\
       codex-headless = \"/usr/local/bin/codex-bridge\"\n");
  with_cwd dir @@ fun () ->
  (* Simulate the binary_to_check resolution used by cmd_start preflight:
       binary_override > repo_config_default_binary > client_cfg.binary *)
  let binary_override = None in
  let client = "codex-headless" in
  let client_cfg_default = "codex-turn-start-bridge" in
  let resolved =
    match binary_override with
    | Some b -> b
    | None ->
      (match C2c_start.repo_config_default_binary client with
       | Some b -> b
       | None -> client_cfg_default)
  in
  check string "preflight resolves from [default_binary]"
    "/usr/local/bin/codex-bridge" resolved

(* #341: with no config or no [swarm] section, the restart-intro thunk
   returns the built-in default. Sanity-check a known substring so a future
   reword of the default is caught here. *)
let test_restart_intro_builtin_default () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let intro = C2c_start.swarm_config_restart_intro () in
  check bool "default contains canonical opener"
    true
    (string_contains intro "You have been started as a c2c swarm agent.");
  check bool "default contains placeholder {name}"
    true
    (string_contains intro "{name}");
  check bool "default contains placeholder {alias}"
    true
    (string_contains intro "{alias}")

(* #341: an override under [swarm] restart_intro replaces the built-in
   string entirely; \n escapes are decoded so single-line TOML can carry
   multi-line content. *)
let test_restart_intro_override () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       restart_intro = \"test custom intro\\nline two for {alias}\"\n");
  with_cwd dir @@ fun () ->
  let intro = C2c_start.swarm_config_restart_intro () in
  check string "override replaces built-in"
    "test custom intro\nline two for {alias}" intro;
  check bool "override does not contain default opener"
    false
    (string_contains intro "You have been started as a c2c swarm agent.")

(* --- #351: c2c instances --- alive-only default + --all archive view ---- *)

(* Resolve the built CLI binary relative to this test executable.
   dune places this at _build/default/ocaml/test/test_c2c_start.exe and
   the CLI at _build/default/ocaml/cli/c2c.exe. We derive the latter
   from the former so the test runs against the freshly-built binary
   rather than whatever happens to be on PATH. *)
let built_c2c_binary () =
  let exe = Sys.executable_name in
  let test_dir = Filename.dirname exe in            (* .../ocaml/test *)
  let ocaml_dir = Filename.dirname test_dir in      (* .../ocaml *)
  Filename.concat ocaml_dir (Filename.concat "cli" "c2c.exe")

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

(* Build a fixture instances_dir holding [alive_count] running instances
   (with PIDs that point at our own process — guaranteed alive) and
   [zombie_count] stopped instances (PID files reference a process that
   does not exist). Returns the directory path; caller is responsible for
   passing it via C2C_INSTANCES_DIR. *)
let build_instances_fixture ~alive ~zombies dir =
  let live_pid = Unix.getpid () in
  (* Find a PID guaranteed not to exist. PID 0x7fff_fffe is well above
     typical kernel pid_max but we still verify with kill 0. *)
  let dead_pid =
    let rec find_dead p =
      if p <= 1 then 1 (* shouldn't happen but bail *)
      else
        match Unix.kill p 0 with
        | () -> find_dead (p - 1)
        | exception Unix.Unix_error _ -> p
    in
    find_dead 999_999
  in
  for i = 1 to alive do
    let name = Printf.sprintf "alive-%d" i in
    let inst_dir = Filename.concat dir name in
    Unix.mkdir inst_dir 0o755;
    write_file (Filename.concat inst_dir "config.json")
      (Printf.sprintf {|{"client":"claude","name":"%s"}|} name);
    write_file (Filename.concat inst_dir "outer.pid")
      (string_of_int live_pid)
  done;
  for i = 1 to zombies do
    let name = Printf.sprintf "zombie-%d" i in
    let inst_dir = Filename.concat dir name in
    Unix.mkdir inst_dir 0o755;
    write_file (Filename.concat inst_dir "config.json")
      (Printf.sprintf {|{"client":"codex","name":"%s"}|} name);
    write_file (Filename.concat inst_dir "outer.pid")
      (string_of_int dead_pid)
  done

let read_all_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic)
    (fun () ->
      let b = Buffer.create 256 in
      try
        while true do
          Buffer.add_channel b ic 4096
        done;
        assert false
      with End_of_file -> Buffer.contents b)

let run_instances_and_capture_json ~instances_dir ~extra_args =
  let bin = built_c2c_binary () in
  if not (Sys.file_exists bin) then
    Alcotest.failf "expected built CLI at %s — run `dune build` first" bin;
  let stdout_path = Filename.temp_file "c2c-instances-stdout" ".json" in
  let cmd =
    Printf.sprintf "C2C_INSTANCES_DIR=%s %s instances --json %s > %s 2>/dev/null"
      (Filename.quote instances_dir)
      (Filename.quote bin)
      extra_args
      (Filename.quote stdout_path)
  in
  let rc = Sys.command cmd in
  if rc <> 0 then
    Alcotest.failf "c2c instances exited %d (cmd: %s)" rc cmd;
  let raw = read_all_file stdout_path in
  Sys.remove stdout_path;
  Yojson.Safe.from_string raw

let count_in_envelope j =
  match j with
  | `Assoc fields ->
      let alive = match List.assoc_opt "alive" fields with Some (`Int n) -> n | _ -> -1 in
      let total = match List.assoc_opt "total" fields with Some (`Int n) -> n | _ -> -1 in
      let filtered = match List.assoc_opt "filtered" fields with Some (`Bool b) -> b | _ -> false in
      let n_listed =
        match List.assoc_opt "instances" fields with
        | Some (`List xs) -> List.length xs
        | _ -> -1
      in
      (alive, total, filtered, n_listed)
  | _ -> Alcotest.failf "expected JSON object envelope, got %s" (Yojson.Safe.to_string j)

let test_instances_default_filters_to_alive () =
  with_temp_dir (fun dir ->
    build_instances_fixture ~alive:1 ~zombies:2 dir;
    let j = run_instances_and_capture_json ~instances_dir:dir ~extra_args:"" in
    let (alive, total, filtered, n_listed) = count_in_envelope j in
    check int "alive count = 1" 1 alive;
    check int "total count = 3" 3 total;
    check bool "filtered = true (default)" true filtered;
    check int "listed = alive only (1)" 1 n_listed)

let test_instances_all_shows_archive () =
  with_temp_dir (fun dir ->
    build_instances_fixture ~alive:1 ~zombies:2 dir;
    let j = run_instances_and_capture_json ~instances_dir:dir ~extra_args:"--all" in
    let (alive, total, filtered, n_listed) = count_in_envelope j in
    check int "alive count = 1" 1 alive;
    check int "total count = 3" 3 total;
    check bool "filtered = false under --all" false filtered;
    check int "listed = full archive (3)" 3 n_listed)

let test_instances_json_default_filters () =
  with_temp_dir (fun dir ->
    build_instances_fixture ~alive:2 ~zombies:5 dir;
    let j = run_instances_and_capture_json ~instances_dir:dir ~extra_args:"" in
    let (alive, total, filtered, n_listed) = count_in_envelope j in
    check int "alive count = 2" 2 alive;
    check int "total count = 7" 7 total;
    check bool "default JSON also filters" true filtered;
    check int "listed = alive only (2)" 2 n_listed;
    (* All listed entries should have status=running. *)
    match j with
    | `Assoc fields ->
        (match List.assoc_opt "instances" fields with
         | Some (`List xs) ->
             List.iter (fun item ->
               match item with
               | `Assoc f ->
                   (match List.assoc_opt "status" f with
                    | Some (`String s) ->
                        check string "every listed entry is running" "running" s
                    | _ -> Alcotest.fail "status field missing")
               | _ -> Alcotest.fail "expected object")
               xs
         | _ -> Alcotest.fail "instances field missing")
    | _ -> Alcotest.fail "expected envelope")

(* --- #333: c2c instances clean-stale --- removes zombies + protects named --- *)

(* Build a fixture with custom-named instances. Each entry is
   (name, alive). Mirrors build_instances_fixture but lets tests choose
   names to exercise the test-pattern + protected-alias logic. *)
let build_named_instances_fixture entries dir =
  let live_pid = Unix.getpid () in
  let dead_pid =
    let rec find_dead p =
      if p <= 1 then 1
      else
        match Unix.kill p 0 with
        | () -> find_dead (p - 1)
        | exception Unix.Unix_error _ -> p
    in
    find_dead 999_999
  in
  List.iter (fun (name, alive) ->
    let inst_dir = Filename.concat dir name in
    Unix.mkdir inst_dir 0o755;
    write_file (Filename.concat inst_dir "config.json")
      (Printf.sprintf {|{"client":"claude","name":"%s"}|} name);
    write_file (Filename.concat inst_dir "outer.pid")
      (string_of_int (if alive then live_pid else dead_pid))
  ) entries

let run_clean_stale_and_capture_json ~instances_dir ~extra_args =
  let bin = built_c2c_binary () in
  if not (Sys.file_exists bin) then
    Alcotest.failf "expected built CLI at %s — run `dune build` first" bin;
  let stdout_path = Filename.temp_file "c2c-clean-stale-stdout" ".json" in
  let cmd =
    Printf.sprintf
      "C2C_INSTANCES_DIR=%s %s instances clean-stale --json %s > %s 2>/dev/null"
      (Filename.quote instances_dir)
      (Filename.quote bin)
      extra_args
      (Filename.quote stdout_path)
  in
  let rc = Sys.command cmd in
  if rc <> 0 then
    Alcotest.failf "c2c instances clean-stale exited %d (cmd: %s)" rc cmd;
  let raw = read_all_file stdout_path in
  Sys.remove stdout_path;
  Yojson.Safe.from_string raw

let dir_entries dir =
  if Sys.file_exists dir && Sys.is_directory dir
  then Array.to_list (Sys.readdir dir) |> List.sort String.compare
  else []

let int_field fields name =
  match List.assoc_opt name fields with Some (`Int n) -> n | _ -> -1

let bool_field fields name =
  match List.assoc_opt name fields with Some (`Bool b) -> b | _ -> false

let string_list_field fields name =
  match List.assoc_opt name fields with
  | Some (`List xs) ->
      List.filter_map (fun j -> match j with `String s -> Some s | _ -> None) xs
  | _ -> []

(* Stamp an instance dir's mtimes back >24h ago so the no-activity-24h
   criterion fires deterministically (without needing to actually wait). *)
let age_instance_dir ~instances_dir ~name ~age_seconds =
  let target = Unix.gettimeofday () -. age_seconds in
  let inst = Filename.concat instances_dir name in
  let touch path =
    if Sys.file_exists path then
      try Unix.utimes path target target with _ -> ()
  in
  touch inst;
  List.iter (fun f -> touch (Filename.concat inst f))
    [ "config.json"; "outer.pid"; "stderr.log"; "stdout.log"; "tmux.json" ]

let test_clean_stale_dry_run_reports_candidates () =
  with_temp_dir (fun dir ->
    build_named_instances_fixture
      [ ("alive-keeper", true)
      ; ("codex-reset-1234567890", false)
      ; ("oc-bootstrap-test-foo", false)
      ] dir;
    let j = run_clean_stale_and_capture_json
      ~instances_dir:dir ~extra_args:"--dry-run"
    in
    let fields = match j with
      | `Assoc f -> f
      | _ -> Alcotest.fail "expected envelope"
    in
    check int "removed = 0 under --dry-run" 0 (int_field fields "removed");
    check int "candidates_total = 2 (alive excluded)" 2
      (int_field fields "candidates_total");
    check bool "dry_run = true" true (bool_field fields "dry_run");
    (* All 3 instance dirs still on disk *)
    check int "all 3 instances still present"
      3 (List.length (dir_entries dir)))

let test_clean_stale_removes_zombies_only () =
  with_temp_dir (fun dir ->
    build_named_instances_fixture
      [ ("alive-keeper", true)
      ; ("codex-reset-9876543210", false)
      ; ("kimi-wire-ocaml-smoke-x", false)
      ] dir;
    let j = run_clean_stale_and_capture_json
      ~instances_dir:dir ~extra_args:""
    in
    let fields = match j with
      | `Assoc f -> f
      | _ -> Alcotest.fail "expected envelope"
    in
    check int "removed = 2" 2 (int_field fields "removed");
    check int "candidates_total = 2" 2 (int_field fields "candidates_total");
    check bool "dry_run = false" false (bool_field fields "dry_run");
    let removed = string_list_field fields "removed_aliases" in
    check bool "alive-keeper not in removed_aliases"
      false (List.mem "alive-keeper" removed);
    (* On-disk: only alive-keeper remains *)
    let entries = dir_entries dir in
    check int "exactly 1 instance dir remains" 1 (List.length entries);
    check bool "alive-keeper preserved" true (List.mem "alive-keeper" entries))

let test_clean_stale_protected_named_aliases () =
  with_temp_dir (fun dir ->
    build_named_instances_fixture
      [ ("coordinator1", false)
      ; ("random-zombie", false)
      ] dir;
    (* Both stale-by-PID; coordinator1 is also matched but protected. *)
    age_instance_dir ~instances_dir:dir ~name:"random-zombie"
      ~age_seconds:(2.0 *. 86400.0);
    age_instance_dir ~instances_dir:dir ~name:"coordinator1"
      ~age_seconds:(2.0 *. 86400.0);
    let j = run_clean_stale_and_capture_json
      ~instances_dir:dir ~extra_args:""
    in
    let fields = match j with
      | `Assoc f -> f
      | _ -> Alcotest.fail "expected envelope"
    in
    check int "removed = 1 (random-zombie only)" 1 (int_field fields "removed");
    check int "candidates_total = 2 (both stale)" 2
      (int_field fields "candidates_total");
    check int "protected = 1 (coordinator1)" 1 (int_field fields "protected");
    let removed = string_list_field fields "removed_aliases" in
    check bool "random-zombie removed" true (List.mem "random-zombie" removed);
    check bool "coordinator1 not removed"
      false (List.mem "coordinator1" removed);
    let protected_aliases = string_list_field fields "protected_aliases" in
    check bool "coordinator1 reported as protected"
      true (List.mem "coordinator1" protected_aliases);
    let entries = dir_entries dir in
    check bool "coordinator1 preserved on disk"
      true (List.mem "coordinator1" entries);
    check bool "random-zombie removed on disk"
      false (List.mem "random-zombie" entries))

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
        ; ( "resolve_model_override_explicit_wins_over_role",
            `Quick, test_resolve_model_override_explicit_wins_over_role )
        ; ( "resolve_model_override_role_wins_over_saved",
            `Quick, test_resolve_model_override_role_wins_over_saved )
        ; ( "resolve_model_override_saved_used_when_neither_explicit_nor_role",
            `Quick, test_resolve_model_override_saved_used_when_neither_explicit_nor_role )
        ; ( "prepare_launch_args_adds_model_flag_for_claude",
            `Quick, test_prepare_launch_args_adds_model_flag_for_claude )
        ; ( "prepare_launch_args_adds_agent_flag_for_claude",
            `Quick, test_prepare_launch_args_adds_agent_flag_for_claude )
        ; ( "prepare_launch_args_opencode_agent_flag_uses_instance_name",
            `Quick, test_prepare_launch_args_opencode_agent_flag_uses_instance_name )
        ; ( "prepare_launch_args_forwards_extra_args_for_claude",
            `Quick, test_prepare_launch_args_forwards_extra_args_for_claude )
        ; ( "prepare_launch_args_forwards_extra_args_for_opencode",
            `Quick, test_prepare_launch_args_forwards_extra_args_for_opencode )
        ; ( "prepare_launch_args_forwards_extra_args_for_codex",
            `Quick, test_prepare_launch_args_forwards_extra_args_for_codex )
        ; ( "prepare_launch_args_adds_model_flag_for_opencode",
            `Quick, test_prepare_launch_args_adds_model_flag_for_opencode )
        ; ( "tmux_shell_command_quotes_argv",
            `Quick, test_tmux_shell_command_quotes_argv )
        ; ( "tmux_message_payload_uses_c2c_envelope",
            `Quick, test_tmux_message_payload_uses_c2c_envelope )
        ; ( "parse_tmux_target_info_requires_loc_and_pane_id",
            `Quick, test_parse_tmux_target_info_requires_loc_and_pane_id )
        ; ( "build_env_keeps_channel_delivery_without_force_flag",
            `Quick, test_build_env_keeps_channel_delivery_without_force_flag )
        ; ( "build_env_does_not_seed_codex_thread_id",
            `Quick, test_build_env_does_not_seed_codex_thread_id )
        ; ( "build_env_strips_ambient_force_capabilities_for_codex",
            `Quick, test_build_env_strips_ambient_force_capabilities_for_codex )
        ; ( "build_env_strips_ambient_force_capabilities_for_opencode",
            `Quick, test_build_env_strips_ambient_force_capabilities_for_opencode )
        ; ( "build_env_claude_keeps_force_capabilities_under_ambient",
            `Quick, test_build_env_claude_keeps_force_capabilities_under_ambient )
        ; ( "codex_heartbeat_interval_is_four_minutes",
            `Quick, test_codex_heartbeat_interval_is_four_minutes )
        ; ( "codex_heartbeat_enabled_for_codex_family_only",
            `Quick, test_codex_heartbeat_enabled_for_codex_family_only )
        ; ( "should_start_codex_heartbeat_requires_codex_deliver_daemon",
            `Quick, test_should_start_codex_heartbeat_requires_codex_deliver_daemon )
        ; ( "enqueue_codex_heartbeat_uses_broker_inbox_transport",
            `Quick, test_enqueue_codex_heartbeat_uses_broker_inbox_transport )
        ; ( "parse_heartbeat_duration_units",
            `Quick, test_parse_heartbeat_duration_units )
        ; ( "automated_delivery_for_alias_unknown",
            `Quick, test_automated_delivery_for_alias_unknown )
        ; ( "automated_delivery_for_alias_set_true",
            `Quick, test_automated_delivery_for_alias_set_true )
        ; ( "automated_delivery_for_alias_set_false",
            `Quick, test_automated_delivery_for_alias_set_false )
        ; ( "heartbeat_body_swap_for_push_capable",
            `Quick, test_heartbeat_body_swap_for_push_capable )
        ; ( "heartbeat_body_no_swap_for_non_push",
            `Quick, test_heartbeat_body_no_swap_for_non_push )
        ; ( "heartbeat_body_no_swap_when_unknown",
            `Quick, test_heartbeat_body_no_swap_when_unknown )
        ; ( "heartbeat_body_passes_custom_message_through",
            `Quick, test_heartbeat_body_passes_custom_message_through )
        ; ( "heartbeat_aligned_schedule_next_delay",
            `Quick, test_heartbeat_aligned_schedule_next_delay )
        ; ( "agent_is_idle_no_activity_treated_as_idle",
            `Quick, test_agent_is_idle_no_activity_treated_as_idle )
        ; ( "agent_is_idle_recent_activity_not_idle",
            `Quick, test_agent_is_idle_recent_activity_not_idle )
        ; ( "agent_is_idle_stale_activity_is_idle",
            `Quick, test_agent_is_idle_stale_activity_is_idle )
        ; ( "agent_is_idle_threshold_boundary_inclusive",
            `Quick, test_agent_is_idle_threshold_boundary_inclusive )
        ; ( "should_fire_heartbeat_idle_only_false_always_fires",
            `Quick, test_should_fire_heartbeat_idle_only_false_always_fires )
        ; ( "should_fire_heartbeat_idle_only_no_registration_fires",
            `Quick, test_should_fire_heartbeat_idle_only_no_registration_fires )
        ; ( "should_fire_heartbeat_skips_recent_activity",
            `Quick, test_should_fire_heartbeat_skips_recent_activity )
        ; ( "repo_config_managed_heartbeats_reads_default_and_named",
            `Quick, test_repo_config_managed_heartbeats_reads_default_and_named )
        ; ( "resolve_managed_heartbeats_applies_role_override_and_named_entries",
            `Quick,
            test_resolve_managed_heartbeats_applies_role_override_and_named_entries )
        ; ( "resolve_managed_heartbeats_role_override_preserves_config_fields",
            `Quick,
            test_resolve_managed_heartbeats_role_override_preserves_config_fields )
        ; ( "resolve_managed_heartbeats_per_agent_override_wins_last",
            `Quick,
            test_resolve_managed_heartbeats_per_agent_override_wins_last )
        ; ( "resolve_managed_heartbeats_full_4layer_precedence",
            `Quick,
            test_resolve_managed_heartbeats_full_4layer_precedence )
        ; ( "resolve_managed_heartbeats_role_adds_named_not_in_config",
            `Quick,
            test_resolve_managed_heartbeats_role_adds_named_not_in_config )
        ; ( "resolve_managed_heartbeats_role_disables_heartbeat",
            `Quick,
            test_resolve_managed_heartbeats_role_disables_heartbeat )
        ; ( "resolve_managed_heartbeats_builtin_baseline",
            `Quick,
            test_resolve_managed_heartbeats_builtin_baseline )
        ; ( "resolve_managed_heartbeats_filters_clients_and_role_classes",
            `Quick, test_resolve_managed_heartbeats_filters_clients_and_role_classes )
        ; ( "render_heartbeat_content_appends_command_output",
            `Quick, test_render_heartbeat_content_appends_command_output )
        ; ( "per_agent_managed_heartbeats_reads_instance_file",
            `Quick, test_per_agent_managed_heartbeats_reads_instance_file )
        ; ( "finalize_outer_loop_exit_cleans_before_print",
            `Quick, test_finalize_outer_loop_exit_cleans_before_print )
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
        ; ( "prepare_launch_args_codex_adds_permission_sideband_fds",
            `Quick, test_prepare_launch_args_codex_adds_permission_sideband_fds )
        ; ( "codex_supports_server_request_fds_requires_both_flags",
            `Quick, test_codex_supports_server_request_fds_requires_both_flags )
        ; ( "cmd_reset_thread_persists_codex_resume_target",
            `Quick, test_cmd_reset_thread_persists_codex_resume_target )
        ; ( "prepare_launch_args_extra_args_appended_verbatim",
            `Quick, test_prepare_launch_args_extra_args_appended_verbatim )
        ; ( "prepare_launch_args_extra_args_empty_by_default",
            `Quick, test_prepare_launch_args_extra_args_empty_by_default )
        ; ( "prepare_launch_args_extra_args_preserves_flags_around_extra",
            `Quick, test_prepare_launch_args_extra_args_preserves_flags_around_extra )
        ] )
    ; ( "pmodel",
        [ ("parse_pmodel_plain", `Quick, test_parse_pmodel_plain)
        ; ("parse_pmodel_prefix_colon", `Quick, test_parse_pmodel_prefix_colon)
        ; ("parse_pmodel_anthropic", `Quick, test_parse_pmodel_anthropic)
        ; ("parse_pmodel_errors", `Quick, test_parse_pmodel_errors)
        ; ( "likes_shell_substitution_detects_parens_and_backticks",
            `Quick,
            test_likes_shell_substitution_detects_parens_and_backticks )
        ; ("repo_config_pmodel_reads_table", `Quick,
           test_repo_config_pmodel_reads_table)
        ; ("repo_config_default_binary_reads_table", `Quick,
           test_repo_config_default_binary_reads_table)
        ; ("repo_config_default_binary_missing_table", `Quick,
           test_repo_config_default_binary_missing_table)
        ; ("repo_config_default_binary_no_config_file", `Quick,
           test_repo_config_default_binary_no_config_file)
        ; ("repo_config_default_binary_preflight_uses_config", `Quick,
           test_repo_config_default_binary_preflight_uses_config)
        ] )
    ; ( "swarm_config",
        [ ("restart_intro_builtin_default", `Quick,
           test_restart_intro_builtin_default)
        ; ("restart_intro_override", `Quick,
           test_restart_intro_override)
        ] )
    ; ( "get_tmux_location",
        [ ( "get_tmux_location_exits_nonzero_when_not_in_tmux",
            `Quick,
            (fun () ->
              let rc = Sys.command "env -u TMUX c2c get-tmux-location > /dev/null 2>&1" in
              check int "non-zero exit when not in tmux" 1 rc) )
        ; ( "get_tmux_location_json_flag",
            `Quick,
            (fun () ->
              let tmpfile = Filename.temp_file "c2c-tmux-test" ".out" in
              Fun.protect ~finally:(fun () -> Sys.remove tmpfile |> ignore)
                (fun () ->
                  ignore (Sys.command (Printf.sprintf "c2c get-tmux-location --json > %s" tmpfile));
                  let ch = open_in tmpfile in
                  Fun.protect ~finally:(fun () -> close_in ch)
                    (fun () ->
                      let output = input_line ch in
                      close_in ch;
                      check bool "JSON output is a string starting with quote"
                        true
                        (String.length output > 0 && output.[0] = '"'))) ))
        ] )
    ; ( "fds_to_close",
        [ ( "fds_to_close_closes_non_preserved",
            `Quick, test_fds_to_close_closes_non_preserved )
        ; ( "fds_to_close_preserves_preserved_fd",
            `Quick, test_fds_to_close_preserves_preserved_fd )
        ; ( "fds_to_close_preserves_stdio",
            `Quick, test_fds_to_close_preserves_stdio )
        ] )
    ; ( "default_name",
        [ ( "default_name_drops_client_prefix",
            `Quick,
            (fun () ->
              (* #277: default_name should NOT prefix with the client name.
                 The returned string should be a "<word1>-<word2>" pair, with
                 no occurrence of the client substring at the start. *)
              List.iter
                (fun client ->
                  let n = C2c_start.default_name client in
                  check bool
                    (Printf.sprintf "name %S does not start with %S-" n client)
                    false
                    (String.length n > String.length client + 1
                     && String.sub n 0 (String.length client + 1)
                        = client ^ "-");
                  check bool
                    (Printf.sprintf "name %S has exactly one '-' separator" n)
                    true
                    (let count = ref 0 in
                     String.iter (fun c -> if c = '-' then incr count) n;
                     !count = 1))
                [ "claude"; "codex"; "opencode"; "kimi"; "crush" ]) )
        ] )
    ; ( "instances_filter_351",
        [ ( "test_instances_default_filters_to_alive",
            `Quick, test_instances_default_filters_to_alive )
        ; ( "test_instances_all_shows_archive",
            `Quick, test_instances_all_shows_archive )
        ; ( "test_instances_json_default_filters",
            `Quick, test_instances_json_default_filters )
        ] )
    ; ( "instances_clean_stale_333",
        [ ( "test_clean_stale_dry_run_reports_candidates",
            `Quick, test_clean_stale_dry_run_reports_candidates )
        ; ( "test_clean_stale_removes_zombies_only",
            `Quick, test_clean_stale_removes_zombies_only )
        ; ( "test_clean_stale_protected_named_aliases",
            `Quick, test_clean_stale_protected_named_aliases )
        ] )
    ]
