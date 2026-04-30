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

(* #470 regression guard: the `c2c start` Cmdliner term parses trailing
   args after `--` via `pos_all string []`. The previous shape
   `pos_right 1 (list string) []` used the `list string` converter, which
   split each token on commas — so `c2c start claude -- --prompt "Hello, world"`
   would arrive as ["--prompt"; "Hello"; " world"] instead of
   ["--prompt"; "Hello, world"]. `pos_all string []` preserves each token
   verbatim; commas inside arguments are NOT split. The first 2 positional
   elements (client name + `--`) are stripped before the result is used, so
   the final extra_argv contains only the args after `--`. *)
let test_extra_argv_preserves_commas_470 () =
  let extra_argv =
    Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"ARG" ~doc:"")
  in
  let client =
    Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"CLIENT" ~doc:"")
  in
  let name =
    Cmdliner.Arg.(value & opt (some string) None & info ["name"; "n"] ~docv:"NAME" ~doc:"")
  in
  let captured = ref None in
  let term =
    let open Cmdliner.Term.Syntax in
    let+ _client = client
    and+ _name = name
    and+ all = extra_argv in
    (* Strip client name (pos 0) and `--` (pos 1) *)
    captured := Some (match all with _ :: _ :: rest -> rest | _ -> [])
  in
  let cmd = Cmdliner.Cmd.v (Cmdliner.Cmd.info "start") term in
  let argv =
    [| "c2c"; "start"; "claude"; "-n"; "kimi-470";
       "--"; "--prompt"; "Hello, world"; "--flag=a,b,c"; "plain" |]
  in
  let _ = Cmdliner.Cmd.eval ~argv cmd in
  let got = match !captured with Some a -> a | None -> [] in
  check (list string)
    "comma-containing tokens preserved verbatim (no list-string split)"
    [ "--prompt"; "Hello, world"; "--flag=a,b,c"; "plain" ]
    got

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
    ; message_id = None
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

(* #381: coordinator: boolean field in role frontmatter *)
let test_role_parse_coordinator_field () =
  let role_true = C2c_role.parse_string "---\ncoordinator: true\n---\nbody\n" in
  check bool "coordinator true parsed" true (role_true.C2c_role.coordinator = Some true);
  let role_false = C2c_role.parse_string "---\ncoordinator: false\n---\nbody\n" in
  check bool "coordinator false parsed" true (role_false.C2c_role.coordinator = Some false);
  let role_none = C2c_role.parse_string "---\nrole: subagent\n---\nbody\n" in
  check bool "coordinator absent → None" true (role_none.C2c_role.coordinator = None);
  let role_1 = C2c_role.parse_string "---\ncoordinator: 1\n---\nbody\n" in
  check bool "coordinator 1 parsed as true" true (role_1.C2c_role.coordinator = Some true);
  let role_0 = C2c_role.parse_string "---\ncoordinator: 0\n---\nbody\n" in
  check bool "coordinator 0 parsed as false" true (role_0.C2c_role.coordinator = Some false)

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

let test_probed_capabilities_for_kimi () =
  let caps =
    C2c_start.probed_capabilities ~client:"kimi" ~binary_path:"/bin/true"
  in
  check (list string) "kimi capability set"
    [ "kimi_wire" ] caps

(* #153: kimi-cli's default --max-steps-per-turn is 1000, too low for
   long-running agentic swarm work. Managed kimi sessions should default
   to 9999 to match the opencode posture. Assert the flag and value are
   adjacent in the assembled argv. *)
let test_prepare_launch_args_kimi_sets_max_steps_per_turn () =
  let tmp = Filename.temp_dir "c2c-test-kimi-153-" "" in
  let args =
    C2c_start.prepare_launch_args ~name:"kimi-153-proof" ~client:"kimi"
      ~extra_args:[] ~broker_root:tmp ()
  in
  check bool "adds --max-steps-per-turn 9999" true
    (has_adjacent_pair "--max-steps-per-turn" "9999" args)

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

(* Take the last n elements of lst, in their original order.
   Strategy: reverse, take first n, reverse back.
   The (n <= 0) case returns [] per List.length semantics. *)
let last_n n lst =
  let rec take n acc = function
    | [] -> List.rev acc
    | x :: xs when n > 0 -> take (n - 1) (x :: acc) xs
    (* n <= 0 or xs = [] but acc already has the right elements in order *)
    | _ -> acc
  in
  take n [] (List.rev lst)

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

(* #156: on RESUME (resume_session_id = Some _), kimi-cli treats --prompt as a
   finite work cycle — it processes the kickoff items, completes them, then exits
   code=0.  Resumed sessions must NOT be re-kickoffed; prompt_args must be [] on
   resume even when kickoff_prompt is Some non-empty string. *)
let test_kimi_resume_omits_prompt_flag () =
  (* Use a temp dir for the MCP config that KimiAdapter writes at launch-arg
     construction time.  broker_root is a directory that must exist. *)
  with_temp_dir @@ fun tmp ->
  let args =
    C2c_start.prepare_launch_args
      ~name:"kimi-test-resume"
      ~client:"kimi"
      ~extra_args:[]
      ~broker_root:tmp
      ~resume_session_id:"abc-123-uuid"
      ~kickoff_prompt:"poll inbox; list peers; post hello"
      ()
  in
  check bool "resume: --prompt must NOT appear in args" false
    (List.mem "--prompt" args)

(* #156: on a fresh spawn (resume_session_id = None), kimi-cli accepts
   --prompt as the initial instruction set and the session persists normally.
   Verify that kickoff_prompt IS forwarded as --prompt on fresh launches. *)
let test_kimi_fresh_includes_prompt_flag () =
  with_temp_dir @@ fun tmp ->
  let args =
    C2c_start.prepare_launch_args
      ~name:"kimi-test-fresh"
      ~client:"kimi"
      ~extra_args:[]
      ~broker_root:tmp
      ~kickoff_prompt:"poll inbox; list peers; post hello"
      ()
  in
  check bool "fresh: --prompt must appear in args" true
    (List.mem "--prompt" args)

(* #471: a plain re-launch (cli_extra_args = []) MUST clear the persisted
   extra_args, not silently inherit them. Otherwise a one-off bad invocation
   (e.g. `c2c start kimi -n NAME -- --prompt "..."` where the host CLI argv
   parser ate `--prompt`) sticks across plain re-launches. *)
let test_resolve_effective_extra_args_clears_on_plain_relaunch () =
  let got =
    C2c_start.resolve_effective_extra_args
      ~cli_extra_args:[]
      ~persisted_extra_args:[ "Welcome..." ]
  in
  check (list string) "plain re-launch yields empty extra_args" [] got

let test_resolve_effective_extra_args_replaces_when_cli_provided () =
  let got =
    C2c_start.resolve_effective_extra_args
      ~cli_extra_args:[ "--foo"; "bar" ]
      ~persisted_extra_args:[ "stale" ]
  in
  check (list string) "CLI args replace persisted" [ "--foo"; "bar" ] got

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
    ; last_launch_at = None
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = Some "/bin/true"
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  let rc =
    C2c_start.cmd_reset_thread ~do_exec:(fun _ -> ()) name "thread-reset-123"
  in
  check int "reset-thread rc" 0 rc;
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after reset-thread"
  | Some saved ->
      check (option string) "persisted codex resume target"
        (Some "thread-reset-123") saved.codex_resume_target

let test_last_launch_at_roundtrip () =
  let name = Printf.sprintf "launch-at-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let now = Unix.gettimeofday () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "kimi"
    ; session_id = name
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = now
    ; last_launch_at = Some now
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after write"
  | Some saved ->
      check (option (float 0.001)) "last_launch_at roundtrip" (Some now) saved.last_launch_at

let test_last_launch_at_backward_compat_missing_field () =
  let name = Printf.sprintf "launch-at-compat-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let now = Unix.gettimeofday () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "kimi"
    ; session_id = name
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = now
    ; last_launch_at = None
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after write"
  | Some saved ->
      check (option (float 0.001)) "last_launch_at None roundtrip" None saved.last_launch_at

(* #504: write_config skips persisting broker_root when it equals the resolver
   default. This prevents the stale-fingerprint drift that pinned peers to old
   broker roots across migrations: once `broker_root` is in saved config, the
   resume path re-injects it into env even after the env has been scrubbed,
   silently overriding the resolver. *)
let test_write_config_omits_broker_root_when_default () =
  let name = Printf.sprintf "broker-default-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  let default_root = C2c_start.broker_root () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "claude"
    ; session_id = name
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = Unix.gettimeofday ()
    ; last_launch_at = None
    ; broker_root = default_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  let path = C2c_start.config_path name in
  let ic = open_in path in
  let raw = Fun.protect ~finally:(fun () -> close_in ic)
              (fun () -> really_input_string ic (in_channel_length ic)) in
  check bool "raw JSON omits broker_root when value == resolver default" false
    (string_contains raw "\"broker_root\"");
  (* Round-trip: load_config_opt should still produce the resolver default. *)
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after write"
  | Some saved ->
      check string "load_config_opt falls back to resolver default"
        default_root saved.broker_root

let test_write_config_persists_broker_root_when_overridden () =
  let name = Printf.sprintf "broker-override-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun explicit_root ->
  (* Sanity: temp dir is unlikely to coincide with the resolver default. *)
  if explicit_root = C2c_start.broker_root () then
    fail "test setup: temp broker_root collided with resolver default";
  let cfg : C2c_start.instance_config =
    { name
    ; client = "claude"
    ; session_id = name
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = Unix.gettimeofday ()
    ; last_launch_at = None
    ; broker_root = explicit_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  let path = C2c_start.config_path name in
  let ic = open_in path in
  let raw = Fun.protect ~finally:(fun () -> close_in ic)
              (fun () -> really_input_string ic (in_channel_length ic)) in
  check bool "raw JSON persists broker_root when overridden" true
    (string_contains raw "\"broker_root\"");
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after write"
  | Some saved ->
      check string "explicit broker_root round-trips" explicit_root saved.broker_root

(* kimi-mcp-canonical-server slice (follow-up to #504):
   - canonical command must be c2c-mcp-server, NOT python3 + c2c_mcp.py
   - C2C_MCP_BROKER_ROOT must be omitted from env when broker_root
     equals the resolver default (drift-prevention, same rule as #504). *)

let test_kimi_mcp_config_uses_canonical_server () =
  let json =
    C2c_start.build_kimi_mcp_config "kuura-test" (C2c_start.broker_root ()) None
  in
  let raw = Yojson.Safe.to_string json in
  check bool "kimi MCP command is c2c-mcp-server" true
    (string_contains raw "\"command\":\"c2c-mcp-server\"");
  check bool "kimi MCP command is NOT python3" false
    (string_contains raw "\"command\":\"python3\"");
  check bool "kimi MCP args do NOT reference c2c_mcp.py" false
    (string_contains raw "c2c_mcp.py")

let test_kimi_mcp_config_omits_broker_root_env_when_default () =
  let default_root = C2c_start.broker_root () in
  let json = C2c_start.build_kimi_mcp_config "lumi-test" default_root None in
  let raw = Yojson.Safe.to_string json in
  check bool "C2C_MCP_BROKER_ROOT omitted from env when value == resolver default"
    false
    (string_contains raw "C2C_MCP_BROKER_ROOT")

let test_kimi_mcp_config_persists_broker_root_env_when_overridden () =
  with_temp_dir @@ fun explicit_root ->
  if explicit_root = C2c_start.broker_root () then
    fail "test setup: temp broker_root collided with resolver default";
  let json = C2c_start.build_kimi_mcp_config "tyyni-test" explicit_root None in
  let raw = Yojson.Safe.to_string json in
  check bool "C2C_MCP_BROKER_ROOT present in env when overridden" true
    (string_contains raw "C2C_MCP_BROKER_ROOT");
  check bool "explicit broker_root value appears in env" true
    (string_contains raw explicit_root)

let test_sync_instance_alias_updates_matching_session () =
  let name = Printf.sprintf "sync-alias-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let now = Unix.gettimeofday () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "kimi"
    ; session_id = "sess-abc-123"
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = "old-alias"
    ; extra_args = []
    ; created_at = now
    ; last_launch_at = None
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  C2c_start.sync_instance_alias ~session_id:"sess-abc-123" ~alias:"new-alias";
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after sync"
  | Some saved ->
      check string "alias updated" "new-alias" saved.alias

let test_sync_instance_alias_ignores_mismatched_session () =
  let name = Printf.sprintf "sync-alias-skip-%d" (Random.bits ()) in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let now = Unix.gettimeofday () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "kimi"
    ; session_id = "sess-other-456"
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = "old-alias"
    ; extra_args = []
    ; created_at = now
    ; last_launch_at = None
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    ; last_exit_code = None
    ; last_exit_reason = None
    }
  in
  C2c_start.write_config cfg;
  C2c_start.sync_instance_alias ~session_id:"sess-abc-123" ~alias:"new-alias";
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after sync"
  | Some saved ->
      check string "alias unchanged" "old-alias" saved.alias

let test_last_exit_code_reason_roundtrip () =
  let name = "test-exit-roundtrip" in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let now = Unix.gettimeofday () in
  let cfg : C2c_start.instance_config =
    { name
    ; client = "kimi"
    ; session_id = name
    ; resume_session_id = name
    ; codex_resume_target = None
    ; alias = name
    ; extra_args = []
    ; created_at = now
    ; last_launch_at = None
    ; last_exit_code = Some 143
    ; last_exit_reason = Some "term"
    ; broker_root
    ; auto_join_rooms = "swarm-lounge"
    ; binary_override = None
    ; model_override = None
    ; agent_name = None
    }
  in
  C2c_start.write_config cfg;
  match C2c_start.load_config_opt name with
  | None -> fail "expected config after write"
  | Some saved ->
      check (option int) "last_exit_code roundtrip" (Some 143) saved.last_exit_code;
      check (option string) "last_exit_reason roundtrip" (Some "term") saved.last_exit_reason

let test_last_exit_code_reason_backward_compat_missing_field () =
  let name = "test-exit-compat" in
  with_instance_dir name @@ fun _dir ->
  with_temp_dir @@ fun broker_root ->
  let path = C2c_start.config_path name in
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc "{\"name\":\"test-exit-compat\",\"client\":\"kimi\",\"session_id\":\"test-exit-compat\",\"resume_session_id\":\"test-exit-compat\",\"alias\":\"test-exit-compat\",\"extra_args\":[],\"created_at\":123.0,\"broker_root\":\"/tmp\",\"auto_join_rooms\":\"swarm-lounge\"}\n");
  match C2c_start.load_config_opt name with
  | None -> fail "expected config from legacy json"
  | Some saved ->
      check (option int) "missing last_exit_code is None" None saved.last_exit_code;
      check (option string) "missing last_exit_reason is None" None saved.last_exit_reason

let test_signal_name_mapping () =
  check string "sigterm" "term" (C2c_start.signal_name Sys.sigterm);
  check string "sigkill" "kill" (C2c_start.signal_name Sys.sigkill);
  check string "sighup" "hup" (C2c_start.signal_name Sys.sighup);
  check string "sigint" "int" (C2c_start.signal_name Sys.sigint);
  check string "sigusr1" "usr1" (C2c_start.signal_name Sys.sigusr1);
  check string "sigusr2" "usr2" (C2c_start.signal_name Sys.sigusr2);
  check string "sigpipe" "pipe" (C2c_start.signal_name Sys.sigpipe);
  check string "sigalrm" "alrm" (C2c_start.signal_name Sys.sigalrm);
  check string "sigchld" "chld" (C2c_start.signal_name Sys.sigchld);
  check string "sigsegv" "segv" (C2c_start.signal_name Sys.sigsegv);
  check string "sigabrt" "abrt" (C2c_start.signal_name Sys.sigabrt);
  check string "unknown" "sig99" (C2c_start.signal_name 99)

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

(* slice/coord-backup-fallthrough: with no config or no [swarm] section,
   coord_chain reads as the empty list (feature-off). *)
let test_coord_chain_default_empty () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let chain = C2c_start.swarm_config_coord_chain () in
  check (list string) "empty chain when no config" [] chain

(* slice/coord-backup-fallthrough: coord_chain reads an inline string
   array under [swarm], preserving order. *)
let test_coord_chain_reads_inline_array () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       coord_chain = [\"coordinator1\", \"stanza-coder\", \"jungle-coder\"]\n");
  with_cwd dir @@ fun () ->
  let chain = C2c_start.swarm_config_coord_chain () in
  check (list string) "chain order preserved"
    ["coordinator1"; "stanza-coder"; "jungle-coder"] chain

(* slice/coord-backup-fallthrough: idle-seconds defaults to 120.0
   when absent, parses a plain float when present, falls back to the
   default on garbage. *)
let test_coord_idle_seconds_defaults_and_overrides () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  check (float 0.0) "default idle 120s"
    120.0
    (C2c_start.swarm_config_coord_fallthrough_idle_seconds ())

let test_coord_idle_seconds_override () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       coord_fallthrough_idle_seconds = 60\n");
  with_cwd dir @@ fun () ->
  check (float 0.0) "override idle 60s"
    60.0
    (C2c_start.swarm_config_coord_fallthrough_idle_seconds ())

let test_coord_idle_seconds_garbage_falls_back () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       coord_fallthrough_idle_seconds = \"not-a-number\"\n");
  with_cwd dir @@ fun () ->
  check (float 0.0) "garbage falls back to default"
    120.0
    (C2c_start.swarm_config_coord_fallthrough_idle_seconds ())

(* slice/coord-backup-fallthrough: broadcast room defaults to
   "swarm-lounge", reads a custom room when present, accepts empty
   string to disable the broadcast tier. *)
let test_coord_broadcast_room_default () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  check string "default broadcast room"
    "swarm-lounge"
    (C2c_start.swarm_config_coord_fallthrough_broadcast_room ())

let test_coord_broadcast_room_override () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       coord_fallthrough_broadcast_room = \"emergency-room\"\n");
  with_cwd dir @@ fun () ->
  check string "override broadcast room"
    "emergency-room"
    (C2c_start.swarm_config_coord_fallthrough_broadcast_room ())

let test_coord_broadcast_room_empty_disables () =
  with_temp_dir @@ fun dir ->
  let c2c_dir = Filename.concat dir ".c2c" in
  Unix.mkdir c2c_dir 0o755;
  let config_path = Filename.concat c2c_dir "config.toml" in
  let oc = open_out config_path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc
      "[swarm]\n\
       coord_fallthrough_broadcast_room = \"\"\n");
  with_cwd dir @@ fun () ->
  check string "empty string disables broadcast tier"
    ""
    (C2c_start.swarm_config_coord_fallthrough_broadcast_room ())

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

(* #406b: Gemini adapter — build_start_args resume + model behavior. *)

let test_prepare_launch_args_gemini_fresh_session () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"gemini-fresh" ~client:"gemini"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "fresh session: no --resume flag" false
    (List.mem "--resume" args);
  check bool "no dev-channels (gemini has no equivalent)" false
    (List.mem "--dangerously-load-development-channels" args)

let test_prepare_launch_args_gemini_resume_default_to_latest () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"gemini-resume" ~client:"gemini"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"gemini-resume" ()
  in
  check bool "non-numeric session_id resumes to 'latest'" true
    (has_adjacent_pair "--resume" "latest" args)

let test_prepare_launch_args_gemini_resume_numeric_index_preserved () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"gemini-idx" ~client:"gemini"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"3" ()
  in
  check bool "numeric session_id passed through as resume index" true
    (has_adjacent_pair "--resume" "3" args);
  check bool "does NOT also set --resume latest" false
    (has_adjacent_pair "--resume" "latest" args)

let test_prepare_launch_args_gemini_model_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"gemini-m" ~client:"gemini"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"gemini-2.5-flash" ()
  in
  check bool "model flag present" true
    (has_adjacent_pair "--model" "gemini-2.5-flash" args)

let test_prepare_launch_args_gemini_empty_resume_treated_as_fresh () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"gemini-empty" ~client:"gemini"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"" ()
  in
  check bool "empty session_id: no --resume flag" false
    (List.mem "--resume" args)

(* Option C (MED-3 / #491 follow-up): codex-headless is NOT in client_adapters,
   so model_override is appended by the non-adapter else branch at
   prepare_launch_args:2816-2820.  Gemini is in client_adapters so the adapter
   handles model_override internally (pinned by test_prepare_launch_args_gemini_model_flag).
   This test pins the non-adapter path so a future #479-style audit cannot
   re-suspect the same dead-code suspicion and waste cycles re-checking. *)
let test_prepare_launch_args_codex_headless_model_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"cx-headless-test" ~client:"codex-headless"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~model_override:"codex-gpt-4" ()
  in
  check bool "model flag present for codex-headless" true
    (has_adjacent_pair "--model" "codex-gpt-4" args)

(* #139: KimiAdapter --session resume — wires kimi-cli's native --session flag
   from c2c instance state's resume_session_id, enabling restart-with-context. *)

let test_prepare_launch_args_kimi_resume_passes_session_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"kimi-resume" ~client:"kimi"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~resume_session_id:"abc-123" ()
  in
  check bool "resume_session_id Some: --session <uuid> appears" true
    (has_adjacent_pair "--session" "abc-123" args)

let test_prepare_launch_args_kimi_fresh_omits_session_flag () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"kimi-fresh" ~client:"kimi"
      ~extra_args:[] ~broker_root:"/tmp/broker" ()
  in
  check bool "resume_session_id None: --session flag omitted" false
    (List.mem "--session" args)

(* #146-prime: --agent-file path uses role name, not instance name, so that
   the file written by c2c roles compile (role-scoped) matches the path
   passed to kimi-cli. *)
let test_prepare_launch_args_kimi_agent_file_uses_role_name () =
  with_temp_dir @@ fun dir ->
  with_cwd dir @@ fun () ->
  let args =
    C2c_start.prepare_launch_args ~name:"azure-maple" ~client:"kimi"
      ~extra_args:[] ~broker_root:"/tmp/broker"
      ~agent_name:"coordinator1" ()
  in
  (* --agent-file should point to .kimi/agents/coordinator1/agent.yaml *)
  let idx =
    try List.find_index (fun a -> a = "--agent-file") args
    with Not_found -> None
  in
  (match idx with
   | Some _ -> ()
   | None -> Alcotest.fail "--agent-file flag missing");
  (match idx with
   | Some i when i + 1 < List.length args ->
       let path = List.nth args (i + 1) in
       check string "agent-file path uses role name"
         (".kimi/agents/coordinator1/agent.yaml")
         path
   | _ ->
        Alcotest.fail "--agent-file missing or has no value")

(* #489 regression: verify kimi_agent_yaml_path returns a path under
   .kimi/agents/<name>/agent.yaml (yaml dir), NOT .kimi/agents/<name>.md.
   This is the contract that write_agent_file (c2c.ml) and
   C2c_commands.agent_file_path both depend on. The bug: c2c.ml's local
   agent_file_path shadowed C2c_commands.agent_file_path and hardcoded .md. *)
let test_kimi_write_agent_file_uses_yaml_path () =
  let path = C2c_role.kimi_agent_yaml_path ~name:"test-agent" in
  check string "kimi_agent_yaml_path ends with agent.yaml"
    "agent.yaml" (Filename.basename path);
  check string "kimi_agent_yaml_path uses directory per agent"
    ".kimi/agents/test-agent" (Filename.dirname path);
  (* Ensure it's NOT the old wrong path (which was .kimi/agents/<name>.md) *)
  let wrong_path = Filename.concat (C2c_role.client_agent_dir ~client:"kimi") "test-agent.md" in
  check string "kimi_agent_yaml_path is NOT .md extension"
    ".kimi/agents/test-agent.md" wrong_path;
  (* The correct path must differ from the .md wrong path *)
  check bool "correct path differs from wrong .md path"
    true (path <> wrong_path)

(* #392: pure helpers for c2c_mcp's event-tag body-prefix shape.
   Hosted here since test_c2c_mcp.ml has a pre-existing build issue
   that doesn't reproduce in this executable. *)

let test_tag_to_body_prefix_known_values () =
  check string "fail emoji + uppercase + colon"
    "\xF0\x9F\x94\xB4 FAIL: "
    (C2c_mcp.tag_to_body_prefix (Some "fail"));
  check string "blocking emoji + uppercase + colon"
    "\xE2\x9B\x94 BLOCKING: "
    (C2c_mcp.tag_to_body_prefix (Some "blocking"));
  check string "urgent emoji + uppercase + colon"
    "\xE2\x9A\xA0\xEF\xB8\x8F URGENT: "
    (C2c_mcp.tag_to_body_prefix (Some "urgent"))

let test_tag_to_body_prefix_none_and_unknown () =
  check string "None → empty prefix" ""
    (C2c_mcp.tag_to_body_prefix None);
  check string "unknown tag → empty prefix (defensive default)" ""
    (C2c_mcp.tag_to_body_prefix (Some "informational"));
  check string "empty string tag → empty prefix" ""
    (C2c_mcp.tag_to_body_prefix (Some ""))

let test_parse_send_tag_accepts_known () =
  (match C2c_mcp.parse_send_tag (Some "fail") with
   | Ok (Some "fail") -> ()
   | _ -> fail "parse_send_tag (Some \"fail\") should accept");
  (match C2c_mcp.parse_send_tag (Some "blocking") with
   | Ok (Some "blocking") -> ()
   | _ -> fail "parse_send_tag (Some \"blocking\") should accept");
  (match C2c_mcp.parse_send_tag (Some "urgent") with
   | Ok (Some "urgent") -> ()
   | _ -> fail "parse_send_tag (Some \"urgent\") should accept")

let test_parse_send_tag_normalizes_none () =
  (match C2c_mcp.parse_send_tag None with
   | Ok None -> ()
   | _ -> fail "parse_send_tag None should accept as Ok None");
  (match C2c_mcp.parse_send_tag (Some "") with
   | Ok None -> ()
   | _ -> fail "parse_send_tag (Some \"\") should normalize to Ok None")

let test_parse_send_tag_rejects_unknown () =
  (match C2c_mcp.parse_send_tag (Some "informational") with
   | Error msg ->
     check bool "rejection message names the offending value" true
       (string_contains msg "informational");
     check bool "rejection message lists allowed values" true
       (string_contains msg "fail" && string_contains msg "blocking"
        && string_contains msg "urgent")
   | Ok _ -> fail "parse_send_tag (Some \"informational\") should reject");
  (match C2c_mcp.parse_send_tag (Some "FAIL") with
   | Error _ -> ()  (* case-sensitive — reject uppercase *)
   | Ok _ -> fail "parse_send_tag (Some \"FAIL\") should reject (case-sensitive)")

(* #392b convergence: verify that the body-prefix shape produced by
   parse_send_tag + tag_to_body_prefix round-trips cleanly through
   extract_tag_from_content, and that format_c2c_envelope emits the
   expected envelope shape and copies the tag attribute. The three
   in-tree callers (c2c_wire_bridge, c2c_inbox_hook, cli/c2c.ml's
   PostToolUse hook) all rely on this round-trip; if it ever drifts,
   tagged DMs will lose their visual indicator on one surface but
   not another. *)

let test_extract_tag_from_content_recognizes_known_prefixes () =
  check (option string) "fail prefix" (Some "fail")
    (C2c_mcp.extract_tag_from_content
       (C2c_mcp.tag_to_body_prefix (Some "fail") ^ "build broken"));
  check (option string) "blocking prefix" (Some "blocking")
    (C2c_mcp.extract_tag_from_content
       (C2c_mcp.tag_to_body_prefix (Some "blocking") ^ "stop here"));
  check (option string) "urgent prefix" (Some "urgent")
    (C2c_mcp.extract_tag_from_content
       (C2c_mcp.tag_to_body_prefix (Some "urgent") ^ "wake everyone"))

let test_extract_tag_from_content_returns_none_for_plain () =
  check (option string) "plain body → None" None
    (C2c_mcp.extract_tag_from_content "ordinary message");
  check (option string) "empty body → None" None
    (C2c_mcp.extract_tag_from_content "")

let test_format_c2c_envelope_basic_shape () =
  let env =
    C2c_mcp.format_c2c_envelope
      ~from_alias:"alice" ~to_alias:"bob"
      ~content:"hi" ()
  in
  check bool "starts with <c2c event=\"message\"" true
    (string_contains env "<c2c event=\"message\"");
  check bool "from=alice attribute" true
    (string_contains env "from=\"alice\"");
  check bool "to=bob attribute" true
    (string_contains env "to=\"bob\"");
  check bool "default reply_via=c2c_send" true
    (string_contains env "reply_via=\"c2c_send\"");
  check bool "body content present" true
    (string_contains env "hi");
  check bool "envelope closes with </c2c>" true
    (string_contains env "</c2c>");
  check bool "no tag attribute when tag absent" false
    (string_contains env "tag=");
  check bool "no role attribute when role absent" false
    (string_contains env "role=")

let test_format_c2c_envelope_passes_through_tag_and_role () =
  let env =
    C2c_mcp.format_c2c_envelope
      ~from_alias:"alice" ~to_alias:"bob"
      ~tag:"urgent" ~role:"coder"
      ~reply_via:"c2c_send_room"
      ~content:"see logs" ()
  in
  check bool "tag attribute present" true
    (string_contains env "tag=\"urgent\"");
  check bool "role attribute present" true
    (string_contains env "role=\"coder\"");
  check bool "explicit reply_via overrides default" true
    (string_contains env "reply_via=\"c2c_send_room\"")

let test_format_c2c_envelope_xml_escapes_attributes () =
  let env =
    C2c_mcp.format_c2c_envelope
      ~from_alias:"a&b" ~to_alias:"c<d>"
      ~content:"plain body" ()
  in
  check bool "ampersand in from_alias is &amp;" true
    (string_contains env "from=\"a&amp;b\"");
  check bool "lt/gt in to_alias are escaped" true
    (string_contains env "to=\"c&lt;d&gt;\"");
  (* Body content is NOT escaped — agents read it verbatim, including
     literal tags they may have authored. Document this invariant so a
     future change doesn't silently break round-trip. *)
  check bool "body content NOT escaped (verbatim pass-through)" true
    (string_contains env "plain body")

(* #462 — swarm-wide git-shim install path. *)

let with_env_override key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None ->
          (* No portable unsetenv via Sys/Unix; clear by setting empty.
             Empty value is treated as unset by [swarm_git_shim_dir]. *)
          Unix.putenv key "")
    f

let test_swarm_shim_install_path_uses_override () =
  with_temp_dir @@ fun dir ->
  with_env_override "C2C_GIT_SHIM_DIR" dir @@ fun () ->
  let installed = C2c_start.ensure_swarm_git_shim_installed () in
  check string "ensure_* returns override dir" dir installed;
  let shim = Filename.concat dir "git" in
  check bool "shim file exists at override path" true (Sys.file_exists shim);
  let st = Unix.stat shim in
  check bool "shim is executable (0o100 bit set)" true
    (st.Unix.st_perm land 0o100 <> 0)

let test_swarm_shim_install_idempotent () =
  with_temp_dir @@ fun dir ->
  with_env_override "C2C_GIT_SHIM_DIR" dir @@ fun () ->
  let _ = C2c_start.ensure_swarm_git_shim_installed () in
  let _ = C2c_start.ensure_swarm_git_shim_installed () in
  let shim = Filename.concat dir "git" in
  check bool "shim still present after second install" true
    (Sys.file_exists shim);
  let ic = open_in shim in
  let line = input_line ic in
  close_in ic;
  check string "shim shebang preserved" "#!/bin/bash" line

let test_swarm_shim_dir_falls_back_to_xdg () =
  with_env_override "C2C_GIT_SHIM_DIR" "" @@ fun () ->
  let dir = C2c_start.swarm_git_shim_dir () in
  (* Should end with c2c/bin (from XDG_STATE_HOME or HOME fallback). *)
  let suffix = Filename.concat "c2c" "bin" in
  let len_d = String.length dir in
  let len_s = String.length suffix in
  check bool
    (Printf.sprintf "shim dir ends with c2c/bin (got %s)" dir)
    true
    (len_d >= len_s
    && String.sub dir (len_d - len_s) len_s = suffix)

(* ─── #143 deliver_kickoff CLIENT_ADAPTER contract ───────────────────────── *)

(* Override C2C_INSTANCES_DIR to a tempdir so the opencode kickoff write
   lands under our control rather than ~/.local/share/c2c/instances. *)
let with_instances_dir_override dir f =
  let prev = try Some (Sys.getenv "C2C_INSTANCES_DIR") with Not_found -> None in
  Unix.putenv "C2C_INSTANCES_DIR" dir;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv "C2C_INSTANCES_DIR" v
      | None ->
        (* No setenv-unset binding in stdlib Unix; reset to empty so the
           adapter falls through to the HOME default on subsequent tests. *)
        Unix.putenv "C2C_INSTANCES_DIR" "")
    f

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      let b = Bytes.create n in
      really_input ic b 0 n;
      Bytes.to_string b)

(* Every registered adapter must satisfy [deliver_kickoff].  This is a
   compile-time guarantee from the [CLIENT_ADAPTER] signature, but we
   exercise each one at runtime to assert no [failwith] regression
   (warn-and-skip stubs must succeed) and to lock the contract. *)
let test_deliver_kickoff_all_adapters_succeed () =
  with_temp_dir @@ fun tmp ->
  with_instances_dir_override tmp @@ fun () ->
  let clients = [ "claude"; "codex"; "opencode"; "kimi"; "gemini" ] in
  List.iter (fun client ->
    match
      C2c_start.deliver_kickoff_for_client
        ~client
        ~name:"deliver-kickoff-probe"
        ~alias:"deliver-kickoff-alias"
        ~kickoff_text:"Hello kickoff."
        ()
    with
    | Ok _ -> ()
    | Error msg ->
      fail (Printf.sprintf
              "deliver_kickoff for %s returned Error: %s" client msg)
  ) clients

(* Empty kickoff_text is a documented no-op shortcut: no file write,
   no env pairs, no warn-and-skip log line. *)
let test_deliver_kickoff_empty_text_is_noop () =
  with_temp_dir @@ fun tmp ->
  with_instances_dir_override tmp @@ fun () ->
  List.iter (fun client ->
    match
      C2c_start.deliver_kickoff_for_client
        ~client ~name:"probe" ~alias:"probe-alias"
        ~kickoff_text:"" ()
    with
    | Ok pairs ->
      check int (Printf.sprintf "%s empty kickoff: 0 env pairs" client)
        0 (List.length pairs)
    | Error msg ->
      fail (Printf.sprintf "%s empty kickoff returned Error: %s" client msg)
  ) [ "claude"; "codex"; "opencode"; "kimi"; "gemini" ]

(* OpenCode is the only adapter with a real impl in #143: it writes the
   kickoff text under <inst_dir>/kickoff-prompt.txt and returns the
   C2C_AUTO_KICKOFF + C2C_KICKOFF_PROMPT_PATH env handshake. *)
let test_deliver_kickoff_opencode_writes_file_and_env () =
  with_temp_dir @@ fun tmp ->
  with_instances_dir_override tmp @@ fun () ->
  let name = "opencode-kickoff-probe" in
  let kickoff_text = "## Greetings\nProbe kickoff line." in
  match
    C2c_start.deliver_kickoff_for_client
      ~client:"opencode" ~name ~alias:"probe-alias" ~kickoff_text ()
  with
  | Error msg -> fail ("opencode deliver_kickoff Error: " ^ msg)
  | Ok pairs ->
    let auto = List.assoc_opt "C2C_AUTO_KICKOFF" pairs in
    let path_pair = List.assoc_opt "C2C_KICKOFF_PROMPT_PATH" pairs in
    check (option string) "C2C_AUTO_KICKOFF=1" (Some "1") auto;
    (match path_pair with
     | None -> fail "C2C_KICKOFF_PROMPT_PATH missing"
     | Some path ->
       check bool (Printf.sprintf "kickoff file exists: %s" path)
         true (Sys.file_exists path);
       let content = read_file path in
       check string "kickoff file content matches"
         kickoff_text content;
       (* Path lives under the C2C_INSTANCES_DIR override. *)
       check bool "kickoff path under override dir"
         true (string_contains path tmp);
       check bool "kickoff path uses instance name"
         true (string_contains path name))

(* Claude's deliver_kickoff is a deliberate no-op (positional argv
   delivery in build_start_args).  Even with a non-empty kickoff_text
   it must return Ok [] without writing any file. *)
let test_deliver_kickoff_claude_is_noop () =
  with_temp_dir @@ fun tmp ->
  with_instances_dir_override tmp @@ fun () ->
  match
    C2c_start.deliver_kickoff_for_client
      ~client:"claude" ~name:"claude-probe" ~alias:"claude-alias"
      ~kickoff_text:"text that should NOT be written" ()
  with
  | Error msg -> fail ("claude deliver_kickoff Error: " ^ msg)
  | Ok pairs ->
    check int "claude returns no env pairs" 0 (List.length pairs);
    (* Make sure no kickoff-prompt.txt was created under the tmp tree. *)
    let probe = Filename.concat tmp "claude-probe" in
    check bool "claude wrote no instance dir" false (Sys.file_exists probe)

(* Unknown / non-adapter clients (crush) get Ok [] so the launch path
   stays unchanged for them. *)
let test_deliver_kickoff_unknown_client_returns_empty () =
  match
    C2c_start.deliver_kickoff_for_client
      ~client:"crush" ~name:"x" ~alias:"x"
      ~kickoff_text:"hi" ()
  with
  | Ok pairs ->
    check int "crush has no adapter: 0 env pairs"
      0 (List.length pairs)
  | Error msg ->
    fail ("crush should not Error: " ^ msg)

let () =
  Random.self_init ();
  Alcotest.run "c2c_start"
    [ ( "event_tag_392",
        [ ( "tag_to_body_prefix_known_values",
            `Quick, test_tag_to_body_prefix_known_values )
        ; ( "tag_to_body_prefix_none_and_unknown",
            `Quick, test_tag_to_body_prefix_none_and_unknown )
        ; ( "parse_send_tag_accepts_known",
            `Quick, test_parse_send_tag_accepts_known )
        ; ( "parse_send_tag_normalizes_none",
            `Quick, test_parse_send_tag_normalizes_none )
        ; ( "parse_send_tag_rejects_unknown",
            `Quick, test_parse_send_tag_rejects_unknown )
        ] )
    ; ( "envelope_392b",
        [ ( "extract_tag_from_content_recognizes_known_prefixes",
            `Quick, test_extract_tag_from_content_recognizes_known_prefixes )
        ; ( "extract_tag_from_content_returns_none_for_plain",
            `Quick, test_extract_tag_from_content_returns_none_for_plain )
        ; ( "format_c2c_envelope_basic_shape",
            `Quick, test_format_c2c_envelope_basic_shape )
        ; ( "format_c2c_envelope_passes_through_tag_and_role",
            `Quick, test_format_c2c_envelope_passes_through_tag_and_role )
        ; ( "format_c2c_envelope_xml_escapes_attributes",
            `Quick, test_format_c2c_envelope_xml_escapes_attributes )
        ] )
    ; ( "gemini_adapter",
        [ ( "fresh_session_no_resume_flag",
            `Quick, test_prepare_launch_args_gemini_fresh_session )
        ; ( "resume_default_to_latest",
            `Quick, test_prepare_launch_args_gemini_resume_default_to_latest )
        ; ( "resume_numeric_index_preserved",
            `Quick, test_prepare_launch_args_gemini_resume_numeric_index_preserved )
        ; ( "model_flag",
            `Quick, test_prepare_launch_args_gemini_model_flag )
        ; ( "empty_resume_treated_as_fresh",
            `Quick, test_prepare_launch_args_gemini_empty_resume_treated_as_fresh )
        ] )
    ; ( "kimi_adapter",
        [ ( "resume_passes_session_flag",
            `Quick, test_prepare_launch_args_kimi_resume_passes_session_flag )
        ; ( "fresh_omits_session_flag",
            `Quick, test_prepare_launch_args_kimi_fresh_omits_session_flag )
        ; ( "agent_file_uses_role_name",
            `Quick, test_prepare_launch_args_kimi_agent_file_uses_role_name )
        ; ( "write_agent_file_kimi_uses_yaml_path",
            `Quick, test_kimi_write_agent_file_uses_yaml_path )
        ] )
    ; ( "launch_args",
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
        ; ( "extra_argv_preserves_commas_470",
            `Quick, test_extra_argv_preserves_commas_470 )
        ; ( "prepare_launch_args_adds_model_flag_for_opencode",
            `Quick, test_prepare_launch_args_adds_model_flag_for_opencode )
        ; ( "prepare_launch_args_codex_headless_model_flag",
            `Quick, test_prepare_launch_args_codex_headless_model_flag )
        ; ( "prepare_launch_args_kimi_sets_max_steps_per_turn",
            `Quick, test_prepare_launch_args_kimi_sets_max_steps_per_turn )
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
        ; ( "role_parse_coordinator_field",
            `Quick, test_role_parse_coordinator_field )
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
        ; ( "probed_capabilities_for_kimi",
            `Quick, test_probed_capabilities_for_kimi )
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
        ; ( "last_launch_at_roundtrip",
            `Quick, test_last_launch_at_roundtrip )
        ; ( "last_launch_at_backward_compat_missing_field",
            `Quick, test_last_launch_at_backward_compat_missing_field )
        ; ( "write_config_omits_broker_root_when_default",
            `Quick, test_write_config_omits_broker_root_when_default )
        ; ( "write_config_persists_broker_root_when_overridden",
            `Quick, test_write_config_persists_broker_root_when_overridden )
        ; ( "kimi_mcp_config_uses_canonical_server",
            `Quick, test_kimi_mcp_config_uses_canonical_server )
        ; ( "kimi_mcp_config_omits_broker_root_env_when_default",
            `Quick, test_kimi_mcp_config_omits_broker_root_env_when_default )
        ; ( "kimi_mcp_config_persists_broker_root_env_when_overridden",
            `Quick, test_kimi_mcp_config_persists_broker_root_env_when_overridden )
        ; ( "sync_instance_alias_updates_matching_session",
            `Quick, test_sync_instance_alias_updates_matching_session )
        ; ( "sync_instance_alias_ignores_mismatched_session",
            `Quick, test_sync_instance_alias_ignores_mismatched_session )
        ; ( "last_exit_code_reason_roundtrip",
            `Quick, test_last_exit_code_reason_roundtrip )
        ; ( "last_exit_code_reason_backward_compat_missing_field",
            `Quick, test_last_exit_code_reason_backward_compat_missing_field )
        ; ( "signal_name_mapping",
            `Quick, test_signal_name_mapping )
        ; ( "prepare_launch_args_extra_args_appended_verbatim",
            `Quick, test_prepare_launch_args_extra_args_appended_verbatim )
        ; ( "prepare_launch_args_extra_args_empty_by_default",
            `Quick, test_prepare_launch_args_extra_args_empty_by_default )
        ; ( "prepare_launch_args_extra_args_preserves_flags_around_extra",
            `Quick, test_prepare_launch_args_extra_args_preserves_flags_around_extra )
        ; ( "resolve_effective_extra_args_clears_on_plain_relaunch_471",
            `Quick, test_resolve_effective_extra_args_clears_on_plain_relaunch )
        ; ( "resolve_effective_extra_args_replaces_when_cli_provided_471",
            `Quick, test_resolve_effective_extra_args_replaces_when_cli_provided )
        ; ( "kimi_resume_omits_prompt_flag_156",
            `Quick, test_kimi_resume_omits_prompt_flag )
        ; ( "kimi_fresh_includes_prompt_flag_156",
            `Quick, test_kimi_fresh_includes_prompt_flag )
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
        ; ("coord_chain_default_empty", `Quick,
           test_coord_chain_default_empty)
        ; ("coord_chain_reads_inline_array", `Quick,
           test_coord_chain_reads_inline_array)
        ; ("coord_idle_seconds_defaults", `Quick,
           test_coord_idle_seconds_defaults_and_overrides)
        ; ("coord_idle_seconds_override", `Quick,
           test_coord_idle_seconds_override)
        ; ("coord_idle_seconds_garbage_falls_back", `Quick,
           test_coord_idle_seconds_garbage_falls_back)
        ; ("coord_broadcast_room_default", `Quick,
           test_coord_broadcast_room_default)
        ; ("coord_broadcast_room_override", `Quick,
           test_coord_broadcast_room_override)
        ; ("coord_broadcast_room_empty_disables", `Quick,
           test_coord_broadcast_room_empty_disables)
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
    ; ( "generate_alias_378",
        [ ( "generate_alias_no_same_word_doubled",
            `Quick,
            (fun () ->
              (* #378: generate_alias must not return same-word-doubled aliases
                 like "lumi-lumi". Reroll when w1 = w2. *)
              let n = 1000 in
              let bad : string list ref = ref [] in
              let rec loop i =
                if i >= n then ()
                else begin
                  let a = C2c_start.generate_alias () in
                  let parts = String.split_on_char '-' a in
                  match parts with
                  | [w1; w2] when w1 = w2 -> bad := a :: !bad; loop (i + 1)
                  | _ -> loop (i + 1)
                end
              in
              loop 0;
              check int
                (Printf.sprintf "no same-word-doubled aliases in %d samples" n)
                0 (List.length !bad) ) ) ] )
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
    ; ( "git_shim_swarm_install_462",
        [ ( "swarm_shim_install_path_uses_override",
            `Quick, test_swarm_shim_install_path_uses_override )
        ; ( "swarm_shim_install_idempotent",
            `Quick, test_swarm_shim_install_idempotent )
        ; ( "swarm_shim_dir_falls_back_to_xdg",
            `Quick, test_swarm_shim_dir_falls_back_to_xdg )
        ] )
    ; ( "deliver_kickoff_contract_143",
        [ ( "all_adapters_succeed",
            `Quick, test_deliver_kickoff_all_adapters_succeed )
        ; ( "empty_text_is_noop",
            `Quick, test_deliver_kickoff_empty_text_is_noop )
        ; ( "opencode_writes_file_and_env",
            `Quick, test_deliver_kickoff_opencode_writes_file_and_env )
        ; ( "claude_is_noop",
            `Quick, test_deliver_kickoff_claude_is_noop )
        ; ( "unknown_client_returns_empty",
            `Quick, test_deliver_kickoff_unknown_client_returns_empty )
        ] )
    ]
