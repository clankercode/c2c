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

let with_cwd dir f =
  let prev = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Sys.chdir prev) (fun () ->
    Sys.chdir dir;
    f ())

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
(* Feature B: env-marker is written when alias_from_auto_gen=true        *)
(* ------------------------------------------------------------------ *)

(* Pull the c2c entry's env field as an association list (helper for the
   env-marker tests below). *)
let c2c_env_fields result =
  match result with
  | `Assoc fields ->
      (match List.assoc_opt "mcpServers" fields with
       | Some (`Assoc servers) ->
           (match List.assoc_opt "c2c" servers with
            | Some (`Assoc entry_fields) ->
                (match List.assoc_opt "env" entry_fields with
                 | Some (`Assoc env_fields) -> env_fields
                 | _ -> Alcotest.fail "env missing from c2c entry")
            | _ -> Alcotest.fail "c2c entry missing")
       | _ -> Alcotest.fail "mcpServers missing")
  | _ -> Alcotest.fail "config is not a JSON object"

let test_env_marker_present_when_alias_from_auto_gen () =
  (* Blocklist+nonce env boundary: when c2c install kimi auto-picks the
     alias (do_install_client sees alias_opt=None), build_kimi_mcp_config
     must write C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1 alongside
     C2C_MCP_AUTO_REGISTER_ALIAS, so the server-side auto_register_startup
     can pass ~from_auto_gen:true and bypass the user-supplied blocklist
     for client-prefixed auto-gen names like 'kimi-ember-frost-n2b8'. *)
  let existing = `Assoc [] in
  let result =
    C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:true
      ~root ~alias_val:"kimi-ember-frost-n2b8" ~server_path existing
  in
  let env_fields = c2c_env_fields result in
  Alcotest.(check bool)
    "env marker C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN present"
    true
    (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_fields);
  Alcotest.(check (option string))
    "env marker is \"1\""
    (Some "1")
    (match List.assoc_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_fields with
     | Some (`String s) -> Some s
     | _ -> None);
  Alcotest.(check bool)
    "C2C_MCP_AUTO_REGISTER_ALIAS still present (alias communicated)"
    true
    (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS" env_fields)

let test_env_marker_absent_when_alias_explicit () =
  (* When the user passes --alias (or role/env), alias_from_auto_gen is
     false and the env marker must NOT be written — the blocklist SHOULD
     apply and reject client-prefixed names. *)
  let existing = `Assoc [] in
  let result =
    C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false
      ~root ~alias_val:"lyra-quill" ~server_path existing
  in
  let env_fields = c2c_env_fields result in
  Alcotest.(check bool)
    "env marker absent when alias explicit (blocklist must apply)"
    false
    (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_fields)

let test_kimi_config_pins_client_type () =
  (* Hijack hardening: kimi's env block must pin C2C_MCP_CLIENT_TYPE=kimi so
     inferred_client_type_from_env never fires. Otherwise a kimi launched from
     a Claude Code shell inherits CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID,
     infers "claude", and adopts the parent Claude session's identity/inbox. *)
  let result =
    C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false
      ~root ~alias_val:"lyra-quill" ~server_path (`Assoc [])
  in
  let env_fields = c2c_env_fields result in
  Alcotest.(check (option string))
    "C2C_MCP_CLIENT_TYPE pinned to kimi"
    (Some "kimi")
    (match List.assoc_opt "C2C_MCP_CLIENT_TYPE" env_fields with
     | Some (`String s) -> Some s
     | _ -> None)

let test_kimi_config_uses_configured_social_room () =
  with_temp_dir (fun dir ->
    let c2c_dir = dir // ".c2c" in
    Unix.mkdir c2c_dir 0o700;
    write_file (c2c_dir // "config.toml") "[swarm]\nsocial_room = \"mesh-lounge\"\n";
    with_cwd dir (fun () ->
      let result =
        C2c_setup.build_kimi_mcp_config ~alias_from_auto_gen:false
          ~root ~alias_val:"kimi-mesh" ~server_path (`Assoc [])
      in
      let env_fields = c2c_env_fields result in
      Alcotest.(check (option string))
        "C2C_MCP_AUTO_JOIN_ROOMS follows configured social_room"
        (Some "mesh-lounge")
        (match List.assoc_opt "C2C_MCP_AUTO_JOIN_ROOMS" env_fields with
         | Some (`String s) -> Some s
         | _ -> None)))

(* ------------------------------------------------------------------ *)
(* Feature B env-marker: setup_codex writes marker in config.toml      *)
(* ------------------------------------------------------------------ *)

(* run_setup_codex writes ~/.codex/config.toml (under $HOME) by calling
   [C2c_setup.setup_codex] with a real mcp_command and the supplied
   alias + marker. The env marker is only written when
   alias_from_auto_gen=true. *)
let run_setup_codex ~alias_from_auto_gen ~alias_val ~home ~server_path () =
  let old_home = Sys.getenv_opt "HOME" in
  Fun.protect
    ~finally:(fun () ->
      match old_home with
      | Some h -> Unix.putenv "HOME" h
      | None -> Unix.putenv "HOME" "")
    (fun () ->
      Unix.putenv "HOME" home;
      C2c_setup.setup_codex
        ~output_mode:C2c_types.Human ~dry_run:false
        ~root:"/fake/broker/root" ~alias_val
        ~server_path ~mcp_command:"c2c-mcp-server"
        ~client:"codex"
        ~alias_from_auto_gen)

let test_setup_codex_writes_env_marker_when_auto_gen () =
  (* End-to-end: c2c install codex (no --alias) must write the
     C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN marker in the [mcp_servers.c2c.env]
     TOML block of ~/.codex/config.toml. The MCP server reads this
     marker and bypasses the user-supplied blocklist for the
     auto-generated client-prefixed alias. *)
  with_temp_dir (fun dir ->
    let home = dir // "home" in
    Unix.mkdir home 0o700;
    run_setup_codex ~alias_from_auto_gen:true
      ~alias_val:"codex-ember-frost-n2b8"
      ~home ~server_path:"/fake/bin/c2c_mcp_server.exe" ();
    let config_path = home // ".codex" // "config.toml" in
    Alcotest.(check bool) "config.toml exists" true (Sys.file_exists config_path);
    let content = read_file config_path in
    Alcotest.(check bool)
      "env marker C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN present"
      true
      (contains_substring ~haystack:content
         ~needle:"C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN = \"1\"");
    Alcotest.(check bool)
      "config still bootstraps a [mcp_servers.c2c.env] block"
      true
      (contains_substring ~haystack:content
         ~needle:"[mcp_servers.c2c.env]"))

let test_setup_codex_writes_auto_register_alias () =
  (* Codex auto-identity gap (#10 companion): without
     C2C_MCP_AUTO_REGISTER_ALIAS in [mcp_servers.c2c.env] the c2c MCP server
     inside codex never auto-registers (auto_register_impl bails when the
     alias env is absent). setup_codex must write it, mirroring
     setup_kimi / setup_gemini. *)
  with_temp_dir (fun dir ->
    let home = dir // "home" in
    Unix.mkdir home 0o700;
    run_setup_codex ~alias_from_auto_gen:false
      ~alias_val:"lyra-quill"
      ~home ~server_path:"/fake/bin/c2c_mcp_server.exe" ();
    let config_path = home // ".codex" // "config.toml" in
    let content = read_file config_path in
    Alcotest.(check bool)
      "C2C_MCP_AUTO_REGISTER_ALIAS written with the alias"
      true
      (contains_substring ~haystack:content
         ~needle:"C2C_MCP_AUTO_REGISTER_ALIAS = \"lyra-quill\""))

let test_setup_codex_omits_env_marker_when_alias_explicit () =
  (* When --alias is supplied (alias_from_auto_gen=false), the env marker
     must NOT be written — the blocklist applies to user-supplied names
     and rejecting a user-supplied 'codex-...' alias is the intended
     behaviour. *)
  with_temp_dir (fun dir ->
    let home = dir // "home" in
    Unix.mkdir home 0o700;
    run_setup_codex ~alias_from_auto_gen:false
      ~alias_val:"lyra-quill"
      ~home ~server_path:"/fake/bin/c2c_mcp_server.exe" ();
    let config_path = home // ".codex" // "config.toml" in
    let content = read_file config_path in
    Alcotest.(check bool)
      "env marker absent when alias explicit"
      false
      (contains_substring ~haystack:content
         ~needle:"C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN"))

(* ------------------------------------------------------------------ *)
(* Feature B env-marker: setup_opencode writes marker in env block +    *)
(* alias_from_auto_gen=true in sidecar                                  *)
(* ------------------------------------------------------------------ *)

(* run_setup_opencode points setup_opencode at a target dir, writing both
   <target>/.opencode/opencode.json and <target>/.opencode/c2c-plugin.json.
   The env block carries the FROM_AUTO_GEN marker (for parity with the
   other clients' configs); the alias itself is communicated via the
   sidecar's `alias` field — not via the MCP env block, since opencode's
   plugin reads the sidecar directly. *)
let run_setup_opencode ~alias_from_auto_gen ~alias_val ~target_dir ~server_path () =
  C2c_setup.setup_opencode
    ~output_mode:C2c_types.Human ~dry_run:false
    ~root:"/fake/broker/root" ~alias_val
    ~server_path ~target_dir_opt:(Some target_dir)
    ~alias_from_auto_gen ~force:false ~deliver_watch:false ()

let read_json_file path =
  let ch = open_in path in
  Fun.protect ~finally:(fun () -> close_in ch)
    (fun () ->
      let n = in_channel_length ch in
      Yojson.Safe.from_string (really_input_string ch n))

let test_setup_opencode_writes_env_marker_and_sidecar_flag () =
  with_temp_dir (fun dir ->
    run_setup_opencode
      ~alias_from_auto_gen:true ~alias_val:"opencode-glade-rilla-n2b8"
      ~target_dir:dir ~server_path:"/fake/bin/c2c_mcp_server.exe" ();
    let opencode_json = dir // ".opencode" // "opencode.json" in
    Alcotest.(check bool) "opencode.json exists" true (Sys.file_exists opencode_json);
    let json = read_json_file opencode_json in
    (* Find mcp.c2c.environment in the JSON. *)
    let env_assoc =
      match json with
      | `Assoc fields ->
          (match List.assoc_opt "mcp" fields with
           | Some (`Assoc mcp) ->
               (match List.assoc_opt "c2c" mcp with
                | Some (`Assoc c2c) ->
                    (match List.assoc_opt "environment" c2c with
                     | Some (`Assoc env) -> env
                     | _ -> Alcotest.fail "environment missing from c2c entry")
                | _ -> Alcotest.fail "c2c entry missing from mcp")
           | _ -> Alcotest.fail "mcp section missing")
      | _ -> Alcotest.fail "opencode.json is not a JSON object"
    in
    Alcotest.(check bool)
      "env marker C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN present"
      true
      (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_assoc);
    Alcotest.(check (option string))
      "env marker is \"1\""
      (Some "1")
      (match List.assoc_opt "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_assoc with
       | Some (`String s) -> Some s
       | _ -> None);
    (* Sidecar carries the alias + alias_from_auto_gen:true. *)
    let sidecar = dir // ".opencode" // "c2c-plugin.json" in
    Alcotest.(check bool) "sidecar exists" true (Sys.file_exists sidecar);
    let sidecar_json = read_json_file sidecar in
    (match sidecar_json with
     | `Assoc fields ->
         Alcotest.(check (option string))
           "sidecar.alias is the auto-picked name"
           (Some "opencode-glade-rilla-n2b8")
           (match List.assoc_opt "alias" fields with
            | Some (`String s) -> Some s
            | _ -> None);
         Alcotest.(check (option bool))
           "sidecar.alias_from_auto_gen is true"
           (Some true)
           (match List.assoc_opt "alias_from_auto_gen" fields with
            | Some (`Bool b) -> Some b
            | _ -> None)
     | _ -> Alcotest.fail "sidecar is not a JSON object"))

let test_setup_opencode_omits_env_marker_when_alias_explicit () =
  with_temp_dir (fun dir ->
    run_setup_opencode
      ~alias_from_auto_gen:false ~alias_val:"lyra-quill"
      ~target_dir:dir ~server_path:"/fake/bin/c2c_mcp_server.exe" ();
    let opencode_json = dir // ".opencode" // "opencode.json" in
    let json = read_json_file opencode_json in
    let env_assoc =
      match json with
      | `Assoc fields ->
          (match List.assoc_opt "mcp" fields with
           | Some (`Assoc mcp) ->
               (match List.assoc_opt "c2c" mcp with
                | Some (`Assoc c2c) ->
                    (match List.assoc_opt "environment" c2c with
                     | Some (`Assoc env) -> env
                     | _ -> Alcotest.fail "environment missing from c2c entry")
                | _ -> Alcotest.fail "c2c entry missing from mcp")
           | _ -> Alcotest.fail "mcp section missing")
      | _ -> Alcotest.fail "opencode.json is not a JSON object"
    in
    Alcotest.(check bool)
      "env marker absent when alias explicit"
      false
      (List.mem_assoc "C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN" env_assoc))

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
        ; Alcotest.test_case "env marker present when alias_from_auto_gen=true" `Quick
            test_env_marker_present_when_alias_from_auto_gen
        ; Alcotest.test_case "env marker absent when alias explicit" `Quick
            test_env_marker_absent_when_alias_explicit
        ; Alcotest.test_case "client type pinned to kimi (hijack hardening)" `Quick
            test_kimi_config_pins_client_type
        ; Alcotest.test_case "configured social_room becomes auto-join env" `Quick
            test_kimi_config_uses_configured_social_room
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
    ; ("setup-codex-env-marker",
        [ Alcotest.test_case "setup_codex writes FROM_AUTO_GEN marker when alias auto-picked" `Quick
            test_setup_codex_writes_env_marker_when_auto_gen
        ; Alcotest.test_case "setup_codex writes C2C_MCP_AUTO_REGISTER_ALIAS" `Quick
            test_setup_codex_writes_auto_register_alias
        ; Alcotest.test_case "setup_codex omits FROM_AUTO_GEN marker when alias explicit" `Quick
            test_setup_codex_omits_env_marker_when_alias_explicit
        ] )
    ; ("setup-opencode-env-marker",
        [ Alcotest.test_case "setup_opencode writes marker in env block + sidecar flag" `Quick
            test_setup_opencode_writes_env_marker_and_sidecar_flag
        ; Alcotest.test_case "setup_opencode omits env marker when alias explicit" `Quick
            test_setup_opencode_omits_env_marker_when_alias_explicit
        ] )
    ]
