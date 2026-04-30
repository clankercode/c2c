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

(* ------------------------------------------------------------------ *)
(* Test 1: allowedTools present and non-empty in the merged config       *)
(* ------------------------------------------------------------------ *)

let test_allowed_tools_present () =
  let existing = `Assoc [] in
  let result = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"test-alias" ~server_path existing in
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
  let result1 = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"test-alias" ~server_path existing in
  let result2 = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"test-alias" ~server_path existing in
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
  let result = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"new-alias" ~server_path existing in
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
  let result = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"upgraded-alias" ~server_path existing in
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
  let result = C2c_setup.build_kimi_mcp_config ~root ~alias_val:"alias" ~server_path existing in
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
                       true (List.mem_assoc "C2C_MCP_SESSION_ID" env_fields)
                 | _ -> Alcotest.fail "env missing from c2c entry")
            | _ -> Alcotest.fail "c2c entry missing")
       | _ -> Alcotest.fail "mcpServers missing")
  | _ -> Alcotest.fail "config is not a JSON object"

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
    ]