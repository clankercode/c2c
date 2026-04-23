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
  check bool "passes local server through --channels" true
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
  check bool "passes local server through --channels" true
    (has_adjacent_pair "--channels" "server:c2c" args);
  check bool "does not add untagged channel name" false
    (has_adjacent_pair "--channels" "c2c" args)

let test_build_env_keeps_channel_delivery_without_force_flag () =
  let env =
    C2c_start.build_env ~broker_root_override:(Some "/tmp/c2c-test-broker")
      "claude-proof" (Some "claude-proof")
  in
  check bool "keeps managed channel delivery opt-in" true
    (env_contains env "C2C_MCP_CHANNEL_DELIVERY=1");
  check bool "does not export force channel delivery" false
    (env_has_key env "C2C_MCP_FORCE_CHANNEL_DELIVERY");
  ()

let test_probed_capabilities_for_claude_include_channel () =
  let caps =
    C2c_start.probed_capabilities ~client:"claude" ~binary_path:"/bin/true"
  in
  check (list string) "claude capability set"
    [ "claude_channel" ] caps

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

let () =
  Random.self_init ();
  Alcotest.run "c2c_start"
    [ ( "launch_args",
        [ ( "prepare_launch_args_claude_uses_development_channel_flag",
            `Quick, test_prepare_launch_args_claude_uses_development_channel_flag )
        ; ( "prepare_launch_args_claude_ignores_enable_channels_config",
            `Quick, test_prepare_launch_args_claude_ignores_enable_channels_config )
        ; ( "build_env_keeps_channel_delivery_without_force_flag",
            `Quick, test_build_env_keeps_channel_delivery_without_force_flag )
        ; ( "probed_capabilities_for_claude_include_channel",
            `Quick, test_probed_capabilities_for_claude_include_channel )
        ; ( "missing_role_capabilities_reports_missing_codex_xml_fd",
            `Quick, test_missing_role_capabilities_reports_missing_codex_xml_fd )
        ; ( "missing_role_capabilities_satisfied_for_claude_channel",
            `Quick, test_missing_role_capabilities_satisfied_for_claude_channel )
        ] )
    ; ( "pmodel",
        [ ("parse_pmodel_plain", `Quick, test_parse_pmodel_plain)
        ; ("parse_pmodel_prefix_colon", `Quick, test_parse_pmodel_prefix_colon)
        ; ("parse_pmodel_anthropic", `Quick, test_parse_pmodel_anthropic)
        ; ("parse_pmodel_errors", `Quick, test_parse_pmodel_errors)
        ; ("repo_config_pmodel_reads_table", `Quick,
           test_repo_config_pmodel_reads_table)
        ] )
    ]
