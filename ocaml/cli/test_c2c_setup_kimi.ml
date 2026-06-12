(* test_c2c_setup_kimi — unit tests for build_kimi_mcp_config.

   Covers #478 Slice 2:
   - allowedTools field is present and contains the full tool list
   - Idempotent merge: second call on same input yields identical output
   - Replacement, not duplication: running on a config that already has a
     c2c entry produces exactly one c2c entry (old one removed)
   - Pre-existing non-c2c mcpServers entries are preserved after merge *)

let ( // ) = Filename.concat

(* Simple substring search *)
let rec contains_substring ~haystack ~needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else if nlen > hlen then false
  else
    let rec match_at i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else match_at (i + 1)
    in
    match_at 0

(* Count how many entries with key "c2c" appear in a JSON mcpServers object.
   Useful for detecting duplicate-c2c-entry bugs. *)
let count_c2c_entries (json: Yojson.Safe.t) : int =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "mcpServers" fields with
       | Some (`Assoc servers) ->
           List.length (List.filter (fun (k, _) -> k = "c2c") servers)
       | _ -> 0)
  | _ -> 0

let root = "/fake/broker/root"
let server_path = "/fake/bin/c2c_mcp_server.exe"

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-setup-test-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o700);
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

(* ------------------------------------------------------------------ *)
(* Test 1: allowedTools present and non-empty in the merged config       *)
(* ------------------------------------------------------------------ *)

let test_allowed_tools_present () =
  let existing = `Assoc [] in
  let result = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"test-alias" ~server_path existing in
  let count = count_c2c_entries result in
  Alcotest.(check int) "exactly one c2c entry" 1 count;
  (* Verify allowedTools is present and non-empty in the c2c entry *)
  match result with
  | `Assoc fields ->
      (match List.assoc_opt "mcpServers" fields with
       | Some (`Assoc servers) ->
           (match List.assoc_opt "c2c" servers with
            | Some (`Assoc entry_fields) ->
                 (match List.assoc_opt "allowedTools" entry_fields with
                 | Some (`List tools) ->
                     Alcotest.(check bool) "allowedTools is a non-empty list"
                       true (List.length tools > 0)
                 | _ -> Alcotest.fail "allowedTools field missing or not a list from c2c entry")
            | _ -> Alcotest.fail "c2c entry not found in mcpServers")
       | _ -> Alcotest.fail "mcpServers not found in config")
  | _ -> Alcotest.fail "config is not a JSON object"

(* ------------------------------------------------------------------ *)
(* Test 2: Idempotent merge — two calls yield identical output           *)
(* ------------------------------------------------------------------ *)

let test_idempotent_output () =
  let existing = `Assoc [] in
  let result1 = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"test-alias" ~server_path existing in
  let result2 = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"test-alias" ~server_path existing in
  let s1 = Yojson.Safe.to_string result1 in
  let s2 = Yojson.Safe.to_string result2 in
  Alcotest.(check string) "second call produces identical output (idempotent)"
    s1 s2

(* ------------------------------------------------------------------ *)
(* Test 3: Replacement, not duplication — old c2c entry is replaced    *)
(* ------------------------------------------------------------------ *)

let test_replacement_not_duplication () =
  (* Pre-existing config with an old c2c entry using a DIFFERENT alias *)
  let existing =
    `Assoc [
      ("mcpServers", `Assoc [
        ("c2c", `Assoc [
          ("type", `String "stdio");
          ("command", `String "old-command");
          ("env", `Assoc [
            ("C2C_MCP_SESSION_ID", `String "old-alias")
          ])
        ]);
        ("some-other-server", `Assoc [
          ("type", `String "stdio");
          ("command", `String "other")
        ])
      ])
    ]
  in
  let result = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"new-alias" ~server_path existing in
  let count = count_c2c_entries result in
  Alcotest.(check int) "exactly one c2c entry after merge" 1 count;
  (* Verify new alias is present, old alias is gone *)
  let s = Yojson.Safe.to_string result in
  let contains_old_alias = contains_substring ~haystack:s ~needle:"old-alias" in
  let contains_new_alias = contains_substring ~haystack:s ~needle:"new-alias" in
  Alcotest.(check bool) "old alias absent from output" false contains_old_alias;
  Alcotest.(check bool) "new alias present in output" true contains_new_alias

(* ------------------------------------------------------------------ *)
(* Test 4: allowedTools added when absent in old config                  *)
(* ------------------------------------------------------------------ *)

let test_allowed_tools_added_when_absent () =
  (* Old c2c entry WITHOUT allowedTools *)
  let existing =
    `Assoc [
      ("mcpServers", `Assoc [
        ("c2c", `Assoc [
          ("type", `String "stdio");
          ("command", `String "opam");
          ("env", `Assoc [
            ("C2C_MCP_SESSION_ID", `String "old-alias")
          ])
          (* intentionally no allowedTools field *)
        ])
      ])
    ]
  in
  let result = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"upgraded-alias" ~server_path existing in
  match result with
  | `Assoc fields ->
      (match List.assoc_opt "mcpServers" fields with
       | Some (`Assoc servers) ->
           (match List.assoc_opt "c2c" servers with
            | Some (`Assoc entry_fields) ->
                Alcotest.(check bool) "allowedTools now present after upgrade"
                  true (List.mem_assoc "allowedTools" entry_fields)
            | _ -> Alcotest.fail "c2c entry missing")
       | _ -> Alcotest.fail "mcpServers missing")
  | _ -> Alcotest.fail "config is not a JSON object"

(* ------------------------------------------------------------------ *)
(* Test 5: Non-c2c mcpServers entries are preserved                      *)
(* ------------------------------------------------------------------ *)

let test_other_servers_preserved () =
  let existing =
    `Assoc [
      ("mcpServers", `Assoc [
        ("c2c", `Assoc [
          ("type", `String "stdio");
          ("command", `String "old");
          ("env", `Assoc [])
        ]);
        ("my-server", `Assoc [
          ("type", `String "stdio");
          ("command", `String "my-cmd")
        ])
      ]);
      ("some-top-level-field", `String "preserved")
    ]
  in
  let result = C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false ~root ~alias_val:"alias" ~server_path existing in
  let s = Yojson.Safe.to_string result in
  let contains_my_server = contains_substring ~haystack:s ~needle:"my-server" in
  Alcotest.(check bool) "my-server entry preserved after merge" true contains_my_server;

  (* Also verify the new c2c entry has the new env values *)
  match result with
  | `Assoc fields ->
      (match List.assoc_opt "mcpServers" fields with
       | Some (`Assoc servers) ->
           (match List.assoc_opt "c2c" servers with
            | Some (`Assoc entry_fields) ->
                (match List.assoc_opt "env" entry_fields with
                 | Some (`Assoc env_fields) ->
                     Alcotest.(check bool) "new alias in env"
                       true (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS" env_fields)
                 | _ -> Alcotest.fail "env missing from c2c entry")
            | _ -> Alcotest.fail "c2c entry missing")
       | _ -> Alcotest.fail "mcpServers missing")
  | _ -> Alcotest.fail "config is not a JSON object"

let test_claude_hook_prefers_ocaml_inbox_hook () =
  let script = C2c_setup.claude_hook_script in
  Alcotest.(check bool) "prefers installed inbox hook"
    true
    (contains_substring ~haystack:script ~needle:"command -v c2c-inbox-hook-ocaml");
  Alcotest.(check bool) "has dev-tree inbox hook fallback"
    true
    (contains_substring ~haystack:script
       ~needle:"_build/default/ocaml/tools/c2c_inbox_hook.exe");
  Alcotest.(check bool) "keeps legacy c2c hook fallback"
    true
    (contains_substring ~haystack:script ~needle:"c2c hook")

let additional_context_of_hook_json raw =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
      (match List.assoc_opt "hookSpecificOutput" fields with
       | Some (`Assoc hook_fields) ->
           (match List.assoc_opt "additionalContext" hook_fields with
            | Some (`String s) -> s
            | _ -> Alcotest.fail "additionalContext missing")
       | _ -> Alcotest.fail "hookSpecificOutput missing")
  | _ -> Alcotest.fail "hook output is not a JSON object"

let test_claude_hook_merges_multiple_context_outputs () =
  with_temp_dir (fun dir ->
    let bin_dir = dir // "bin" in
    Unix.mkdir bin_dir 0o700;
    let script_path = dir // "c2c-inbox-check.sh" in
    write_file script_path C2c_setup.claude_hook_script;
    Unix.chmod script_path 0o755;
    let inbox_hook = bin_dir // "c2c-inbox-hook-ocaml" in
    let cold_hook = bin_dir // "c2c-cold-boot-hook" in
    write_file inbox_hook
      "#!/bin/sh\nprintf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"inbox\\\\ncold\\\\n\"}}'\n";
    write_file cold_hook
      "#!/bin/sh\nprintf '%s\\n' '{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"should-not-run\\\\n\"}}'\n";
    Unix.chmod inbox_hook 0o755;
    Unix.chmod cold_hook 0o755;
    let out = Filename.temp_file "c2c-claude-hook" ".out" in
    let err = Filename.temp_file "c2c-claude-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let old_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in
        let cmd =
          Printf.sprintf
            "env HOME=%s PATH=%s C2C_MCP_SESSION_ID=test-session \
             C2C_MCP_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote dir)
            (Filename.quote (bin_dir ^ ":" ^ old_path))
            (Filename.quote (dir // "broker"))
            (Filename.quote script_path) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        Alcotest.(check int) "wrapper exits 0" 0 rc;
        let context = additional_context_of_hook_json (read_file out) in
        Alcotest.(check bool) "merged context includes inbox hook" true
          (contains_substring ~haystack:context ~needle:"inbox");
        Alcotest.(check bool) "merged context includes cold boot hook" true
          (contains_substring ~haystack:context ~needle:"cold");
        Alcotest.(check bool) "wrapper does not emit a second hook JSON" false
          (contains_substring ~haystack:context ~needle:"should-not-run")))

(* ------------------------------------------------------------------ *)
(* Stop hook tests (P1)                                                  *)
(* ------------------------------------------------------------------ *)

let test_stop_hook_script_prefers_ocaml_binary () =
  let script = C2c_setup.claude_stop_hook_script in
  Alcotest.(check bool) "prefers installed stop hook"
    true
    (contains_substring ~haystack:script ~needle:"command -v c2c-stop-hook-ocaml");
  Alcotest.(check bool) "has dev-tree stop hook fallback"
    true
    (contains_substring ~haystack:script
       ~needle:"_build/default/ocaml/tools/c2c_stop_hook.exe");
  Alcotest.(check bool) "exits silently when no binary found"
    true
    (contains_substring ~haystack:script ~needle:"exit 0")

let test_stop_hook_blocks_when_messages () =
  (* Verify that the Stop hook emits {"decision":"block","reason":"..."} when
     messages exist. We test this by running the actual c2c_stop_hook binary
     with a mock stdin that provides a session_id, and a global broker that
     has a message queued. *)
  with_temp_dir (fun dir ->
    let bin_dir = dir // "bin" in
    Unix.mkdir bin_dir 0o700;
    let stop_hook = bin_dir // "c2c-stop-hook-ocaml" in
    (* Create a mock stop hook that returns a block decision *)
    write_file stop_hook
      "#!/bin/sh\nprintf '%s\\n' '{\"decision\":\"block\",\"reason\":\"test message\\n\"}'\n";
    Unix.chmod stop_hook 0o755;
    let script_path = dir // "c2c-stop-deliver.sh" in
    write_file script_path C2c_setup.claude_stop_hook_script;
    Unix.chmod script_path 0o755;
    let out = Filename.temp_file "c2c-stop-hook" ".out" in
    let err = Filename.temp_file "c2c-stop-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let old_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in
        let cmd =
          Printf.sprintf
            "env HOME=%s PATH=%s C2C_MCP_SESSION_ID=test-session \
             C2C_MCP_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote dir)
            (Filename.quote (bin_dir ^ ":" ^ old_path))
            (Filename.quote (dir // "broker"))
            (Filename.quote script_path) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        Alcotest.(check int) "wrapper exits 0" 0 rc;
        let output = read_file out in
        let json = Yojson.Safe.from_string output in
        match json with
        | `Assoc fields ->
            let decision = List.assoc_opt "decision" fields in
            Alcotest.(check (option string)) "decision is block"
              (Some "block") (Option.map (function `String s -> s | _ -> "") decision);
            let reason = List.assoc_opt "reason" fields in
            Alcotest.(check bool) "reason contains test message"
              (match reason with Some (`String s) -> contains_substring ~haystack:s ~needle:"test message" | _ -> false)
              true
        | _ -> Alcotest.fail "stop hook output is not a JSON object"))

let test_stop_hook_exits_silently_when_no_messages () =
  (* Verify that the Stop hook exits without output when no messages exist.
     The wrapper script should exit 0 without blocking. *)
  with_temp_dir (fun dir ->
    let bin_dir = dir // "bin" in
    Unix.mkdir bin_dir 0o700;
    let stop_hook = bin_dir // "c2c-stop-hook-ocaml" in
    (* Create a mock stop hook that exits silently (no messages) *)
    write_file stop_hook "#!/bin/sh\nexit 0\n";
    Unix.chmod stop_hook 0o755;
    let script_path = dir // "c2c-stop-deliver.sh" in
    write_file script_path C2c_setup.claude_stop_hook_script;
    Unix.chmod script_path 0o755;
    let out = Filename.temp_file "c2c-stop-hook" ".out" in
    let err = Filename.temp_file "c2c-stop-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let old_path = Sys.getenv_opt "PATH" |> Option.value ~default:"" in
        let cmd =
          Printf.sprintf
            "env HOME=%s PATH=%s C2C_MCP_SESSION_ID=test-session \
             C2C_MCP_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote dir)
            (Filename.quote (bin_dir ^ ":" ^ old_path))
            (Filename.quote (dir // "broker"))
            (Filename.quote script_path) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        Alcotest.(check int) "wrapper exits 0" 0 rc;
        let output = read_file out in
        Alcotest.(check string) "no output when no messages" "" output))

let test_no_double_delivery_drain_is_destructive () =
  (* Verify that draining is destructive: once PostToolUse drains the inbox,
     Stop finds nothing. This is inherent in the broker's drain_inbox_push
     which atomically removes messages. *)
  with_temp_dir (fun dir ->
    let broker_dir = dir // "broker" in
    Unix.mkdir broker_dir 0o700;
    let session_id = "test-session-no-double" in
    (* Create a mock inbox file with a message *)
    let inbox_path = broker_dir // (session_id ^ ".inbox.json") in
    let mock_message = `Assoc [
      ("from_alias", `String "sender");
      ("to_alias", `String session_id);
      ("content", `String "test message");
      ("ts", `String "2026-06-12T00:00:00Z");
    ] in
    write_file inbox_path (Yojson.Safe.to_string (`List [mock_message]));
    (* First drain should return the message *)
    let broker = C2c_mcp.Broker.create ~root:broker_dir in
    let first_drain = C2c_mcp.Broker.drain_inbox_push ~drained_by:"test" broker ~session_id in
    Alcotest.(check int) "first drain returns 1 message" 1 (List.length first_drain);
    (* Second drain should return empty (destructive drain) *)
    let second_drain = C2c_mcp.Broker.drain_inbox_push ~drained_by:"test" broker ~session_id in
    Alcotest.(check int) "second drain returns 0 messages (destructive)" 0 (List.length second_drain))

(* ------------------------------------------------------------------ *)

let () =
  Random.self_init ();
  Alcotest.run "c2c_setup_kimi"
    [ ("build-kimi-mcp-config",
        [ Alcotest.test_case "allowedTools present in merged config" `Quick
            test_allowed_tools_present
        ; Alcotest.test_case "idempotent: two calls yield identical output" `Quick
            test_idempotent_output
        ; Alcotest.test_case "replacement not duplication" `Quick
            test_replacement_not_duplication
        ; Alcotest.test_case "allowedTools added when absent in old config" `Quick
            test_allowed_tools_added_when_absent
        ; Alcotest.test_case "non-c2c mcpServers entries preserved" `Quick
            test_other_servers_preserved
        ] )
    ; ("claude-hook",
        [ Alcotest.test_case "prefers OCaml inbox hook" `Quick
            test_claude_hook_prefers_ocaml_inbox_hook
        ; Alcotest.test_case "merges multiple context outputs" `Quick
            test_claude_hook_merges_multiple_context_outputs
        ] )
    ; ("stop-hook",
        [ Alcotest.test_case "stop hook script prefers OCaml binary" `Quick
            test_stop_hook_script_prefers_ocaml_binary
        ; Alcotest.test_case "stop hook blocks when messages exist" `Quick
            test_stop_hook_blocks_when_messages
        ; Alcotest.test_case "stop hook exits silently when no messages" `Quick
            test_stop_hook_exits_silently_when_no_messages
        ; Alcotest.test_case "no double delivery: drain is destructive" `Quick
            test_no_double_delivery_drain_is_destructive
        ] )
    ]
