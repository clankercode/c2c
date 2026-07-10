open Alcotest

(* ------------------------------------------------------------------ *)
(* Path resolution                                                      *)
(* ------------------------------------------------------------------ *)

(* dune test may run the test with a relative `argv[0]`, so resolve
   to absolute via the current working directory before walking up. *)
let abs_path p =
  if Filename.is_relative p then Filename.concat (Unix.getcwd ()) p else p

(* `Sys.executable_name` for the test exe is something like
   `<worktree>/_build/default/ocaml/test/test_session_id_delivery.exe`
   (or relative under `dune test` — see abs_path above). The built
   binaries sit one level up under `cli/` and `tools/`.

   Hardcoding `_build/default/ocaml/{cli,tools}/...` works for `dune
   exec` (cwd == repo root) but fails under `dune test` (cwd == dune
   sandbox), so the previous literal-path approach surfaced 4 spurious
   "command not found" failures per test run. Same fix as
   test_inbox_hook_harness.ml: derive the absolute path from
   `Sys.executable_name`. *)
let find_built_bin subpath : string =
  let exe = abs_path Sys.executable_name in
  let exe_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname exe_dir in
  let bin = Filename.concat ocaml_dir subpath in
  if not (Sys.file_exists bin) then
    Alcotest.fail
      (Printf.sprintf "built binary not found at %s (test exe=%s)" bin exe);
  bin

let built_c2c = find_built_bin "cli/c2c.exe"
let built_inbox_hook = find_built_bin "tools/c2c_inbox_hook.exe"

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-session-id-test-%08x" (Random.bits ()))
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

let json_list_length path =
  match Yojson.Safe.from_string (read_file path) with
  | `List items -> List.length items
  | _ -> Alcotest.fail ("expected JSON list in " ^ path)

let first_json_object path =
  match Yojson.Safe.from_string (read_file path) with
  | `List (`Assoc fields :: _) -> fields
  | _ -> Alcotest.fail ("expected non-empty JSON object list in " ^ path)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let test_send_session_writes_global_inbox () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-send-p0" in
    let out = Filename.temp_file "c2c-send-session" ".out" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove out with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check int "send --session exits 0" 0 rc;
        let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
        check bool "session inbox exists" true (Sys.file_exists inbox_path);
        let inbox = read_file inbox_path in
        check bool "inbox contains message" true
          (string_contains inbox "hello world");
        let fields = first_json_object inbox_path in
        match List.assoc_opt "message_id" fields with
        | Some (`String s) ->
            check bool "session send stamps message_id" true (s <> "")
        | _ -> Alcotest.fail "message_id missing from session-send inbox"))

let test_send_session_rejects_invalid_session_id () =
  with_temp_dir (fun dir ->
    let escaped_name =
      Printf.sprintf "c2c-session-id-escape-%08x" (Random.bits ())
    in
    let escaped_path =
      Filename.concat (Filename.dirname dir) (escaped_name ^ ".inbox.json")
    in
    let out = Filename.temp_file "c2c-send-session-invalid" ".out" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove escaped_path with _ -> ()))
      (fun () ->
        let bad_sid = "../" ^ escaped_name in
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote bad_sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check bool "invalid session id exits nonzero" true (rc <> 0);
        check bool "invalid session id does not escape broker root" false
          (Sys.file_exists escaped_path)))

let test_send_session_rejects_reserved_sender () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-reserved-sender-p0" in
    let out = Filename.temp_file "c2c-send-session-reserved" ".out" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove out with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --from c2c --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check bool "reserved sender exits nonzero" true (rc <> 0);
        let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
        check bool "reserved sender does not write inbox" false
          (Sys.file_exists inbox_path)))

let test_send_session_rejects_reserved_sender_case_insensitive () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-reserved-case-p0" in
    let out = Filename.temp_file "c2c-send-session-reserved-case" ".out" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove out with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --from C2C --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check bool "case variant reserved sender exits nonzero" true (rc <> 0);
        let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
        check bool "case variant reserved sender does not write inbox" false
          (Sys.file_exists inbox_path)))

let test_hook_reads_stdin_session_and_drains_global_inbox () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-hook-p0" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      {|[{"from_alias":"sender-a","to_alias":"test-sid-hook-p0","content":"hello world","ts":1.0}]|};
    let out = Filename.temp_file "c2c-inbox-hook" ".out" in
    let err = Filename.temp_file "c2c-inbox-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let stdin_payload =
          Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|}
            sid
        in
        (* Hermetic: C2C_STATE_HOME + HOME point at the empty temp dir so the
           new repo-fingerprint fallback (C2C_MCP_BROKER_ROOT unset) resolves
           to a path with no registry.json and never touches the real
           ~/.c2c broker. *)
        let cmd =
          Printf.sprintf
            "printf %%s %s | env -u C2C_MCP_SESSION_ID -u \
             C2C_MCP_BROKER_ROOT C2C_STATE_HOME=%s HOME=%s \
             C2C_POST_TOOL_FULL_INJECT=1 \
             C2C_SESSIONS_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote stdin_payload) (Filename.quote dir)
            (Filename.quote dir) (Filename.quote dir)
            (Filename.quote built_inbox_hook) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check int "inbox hook exits 0" 0 rc;
        let stdout = read_file out in
        let json = Yojson.Safe.from_string stdout in
        let open Yojson.Safe.Util in
        let context =
          json |> member "hookSpecificOutput" |> member "additionalContext"
          |> to_string
        in
        check bool "additionalContext has c2c envelope" true
          (string_contains context "<c2c ");
        check bool "additionalContext has message content" true
          (string_contains context "hello world");
        check bool "additionalContext closes c2c envelope" true
          (string_contains context "</c2c>");
        check bool "additionalContext appends system-reminder" true
          (string_contains context "<system-reminder>");
        check int "global session inbox drained" 0
          (json_list_length inbox_path)))

let test_cli_hook_reads_stdin_session_and_drains_global_inbox () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-cli-hook-p0" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      {|[{"from_alias":"sender-a","to_alias":"test-sid-cli-hook-p0","content":"hello from cli hook","ts":1.0}]|};
    let out = Filename.temp_file "c2c-cli-hook" ".out" in
    let err = Filename.temp_file "c2c-cli-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let cmd =
          Printf.sprintf
            "env C2C_MCP_SESSION_ID=%s C2C_MCP_BROKER_ROOT=%s \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s hook < /dev/null > %s 2> %s"
            (Filename.quote sid) (Filename.quote dir) (Filename.quote dir)
            (Filename.quote built_c2c) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check int "cli hook exits 0" 0 rc;
        let stdout = read_file out in
        let json = Yojson.Safe.from_string stdout in
        let open Yojson.Safe.Util in
        let context =
          json |> member "hookSpecificOutput" |> member "additionalContext"
          |> to_string
        in
        check bool "cli hook emits c2c envelope" true
          (string_contains context "<c2c ");
        check bool "cli hook emits system-reminder" true
          (string_contains context "<system-reminder>");
        check bool "cli hook preserves content" true
          (string_contains context "hello from cli hook");
        check int "cli hook drains inbox" 0
          (json_list_length inbox_path)))

(* claude-full-delivery: the CLI fallback (`c2c hook post-tool`, also the
   bare `c2c hook` default) shares C2c_hook_lib.run_post_tool with the
   standalone binary, so its mid-turn drain must be push-only — a
   deferrable message stays queued for the next turn boundary. *)
let test_cli_hook_holds_deferrable_mid_turn () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-cli-defer-p0" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      (Printf.sprintf
         {|[{"from_alias":"sender-a","to_alias":%S,"content":"push body cli","ts":1.0},{"from_alias":"sender-b","to_alias":%S,"content":"deferrable body cli","ts":2.0,"deferrable":true}]|}
         sid sid);
    let out = Filename.temp_file "c2c-cli-hook-defer" ".out" in
    let err = Filename.temp_file "c2c-cli-hook-defer" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let cmd =
          Printf.sprintf
            "env C2C_MCP_SESSION_ID=%s C2C_MCP_BROKER_ROOT=%s \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s hook < /dev/null > %s 2> %s"
            (Filename.quote sid) (Filename.quote dir) (Filename.quote dir)
            (Filename.quote built_c2c) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check int "cli hook exits 0" 0 rc;
        let stdout = read_file out in
        check bool "cli hook delivers push message" true
          (string_contains stdout "push body cli");
        check bool "cli hook holds deferrable message" false
          (string_contains stdout "deferrable body cli");
        check int "deferrable stays queued" 1 (json_list_length inbox_path);
        check bool "queued message is the deferrable one" true
          (string_contains (read_file inbox_path) "deferrable body cli")))

let test_hook_extracts_session_from_truncated_large_payload () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-hook-large-p0" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      {|[{"from_alias":"sender-a","to_alias":"test-sid-hook-large-p0","content":"large payload delivery","ts":1.0}]|};
    let out = Filename.temp_file "c2c-inbox-hook-large" ".out" in
    let err = Filename.temp_file "c2c-inbox-hook-large" ".err" in
    let input = Filename.temp_file "c2c-inbox-hook-large" ".json" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ());
        (try Sys.remove input with _ -> ()))
      (fun () ->
        let stdin_payload =
          Printf.sprintf {|{"session_id":%S,"tool_response":%S|}
            sid (String.make (128 * 1024) 'x')
        in
        let truncated =
          String.sub stdin_payload 0 (String.length stdin_payload - 8)
        in
        write_file input truncated;
        (* Hermetic: C2C_STATE_HOME + HOME redirect the repo-fingerprint
           fallback into the empty temp dir (see the sibling hook test). *)
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_STATE_HOME=%s HOME=%s C2C_POST_TOOL_FULL_INJECT=1 \
             C2C_SESSIONS_BROKER_ROOT=%s %s < %s > %s 2> %s"
            (Filename.quote dir) (Filename.quote dir)
            (Filename.quote dir) (Filename.quote built_inbox_hook)
            (Filename.quote input) (Filename.quote out) (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check int "inbox hook exits 0" 0 rc;
        let stdout = read_file out in
        let json = Yojson.Safe.from_string stdout in
        let open Yojson.Safe.Util in
        let context =
          json |> member "hookSpecificOutput" |> member "additionalContext"
          |> to_string
        in
        check bool "additionalContext has message content" true
          (string_contains context "large payload delivery");
        check int "global session inbox drained" 0
          (json_list_length inbox_path)))

let test_hook_merges_message_and_cold_boot_context () =
  with_temp_dir (fun global_dir ->
    with_temp_dir (fun repo_dir ->
      let sid = "test-sid-hook-cold-p0" in
      let alias = "test-agent-p0" in
      let broker = C2c_mcp.Broker.create ~root:repo_dir in
      C2c_mcp.Broker.register broker ~session_id:sid ~alias ~pid:None
        ~pid_start_time:None ();
      let inbox_path = Filename.concat global_dir (sid ^ ".inbox.json") in
      write_file inbox_path
        {|[{"from_alias":"sender-a","to_alias":"test-sid-hook-cold-p0","content":"hello with cold boot","ts":1.0}]|};
      let out = Filename.temp_file "c2c-inbox-hook-cold" ".out" in
      let err = Filename.temp_file "c2c-inbox-hook-cold" ".err" in
      Fun.protect
        ~finally:(fun () ->
          (try Sys.remove out with _ -> ());
          (try Sys.remove err with _ -> ()))
        (fun () ->
          let stdin_payload =
            Printf.sprintf
              {|{"session_id":%S,"hook_event_name":"PostToolUse"}|}
              sid
          in
          let cmd =
            Printf.sprintf
              "printf %%s %s | env C2C_MCP_SESSION_ID=%s \
               C2C_MCP_BROKER_ROOT=%s C2C_SESSIONS_BROKER_ROOT=%s \
               C2C_POST_TOOL_FULL_INJECT=1 %s > %s 2> %s"
              (Filename.quote stdin_payload) (Filename.quote sid)
              (Filename.quote repo_dir) (Filename.quote global_dir)
              (Filename.quote built_inbox_hook) (Filename.quote out)
              (Filename.quote err)
          in
          let rc = Sys.command cmd in
          check int "inbox hook exits 0" 0 rc;
          let stdout = read_file out in
          let json = Yojson.Safe.from_string stdout in
          let open Yojson.Safe.Util in
          let context =
            json |> member "hookSpecificOutput" |> member "additionalContext"
            |> to_string
          in
          check bool "additionalContext has c2c envelope" true
            (string_contains context "hello with cold boot");
          check bool "additionalContext has cold boot context" true
            (string_contains context "kind=\"cold-boot\"");
          check int "global session inbox drained" 0
            (json_list_length inbox_path))))

let test_hook_rejects_invalid_stdin_session_id () =
  with_temp_dir (fun dir ->
    let escaped_name =
      Printf.sprintf "c2c-session-id-hook-escape-%08x" (Random.bits ())
    in
    let escaped_path =
      Filename.concat (Filename.dirname dir) (escaped_name ^ ".inbox.json")
    in
    write_file escaped_path
      (Printf.sprintf
         {|[{"from_alias":"sender-a","to_alias":"../%s","content":"secret outside root","ts":1.0}]|}
         escaped_name);
    let out = Filename.temp_file "c2c-inbox-hook-invalid" ".out" in
    let err = Filename.temp_file "c2c-inbox-hook-invalid" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove escaped_path with _ -> ());
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let stdin_payload =
          Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|}
            ("../" ^ escaped_name)
        in
        (* Hermetic: C2C_STATE_HOME + HOME redirect the repo-fingerprint
           fallback into the empty temp dir (invalid session_id exits before
           the drain, but keep the sandbox uniform + defensive). *)
        let cmd =
          Printf.sprintf
            "printf %%s %s | env -u C2C_MCP_SESSION_ID -u \
             C2C_MCP_BROKER_ROOT C2C_STATE_HOME=%s HOME=%s \
             C2C_SESSIONS_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote stdin_payload) (Filename.quote dir)
            (Filename.quote dir) (Filename.quote dir)
            (Filename.quote built_inbox_hook) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check bool "invalid hook session exits nonzero" true (rc <> 0);
        let stdout = read_file out in
        check bool "invalid hook session does not drain escaped inbox" false
          (string_contains stdout "secret outside root");
        check int "escaped inbox remains untouched" 1
          (json_list_length escaped_path)))

let () =
  Alcotest.run "session_id_delivery"
    [ ( "send-session",
        [ ( "writes global sessions inbox", `Quick,
            test_send_session_writes_global_inbox )
        ; ( "rejects invalid session id", `Quick,
            test_send_session_rejects_invalid_session_id )
        ; ( "rejects reserved sender", `Quick,
            test_send_session_rejects_reserved_sender )
        ; ( "rejects reserved sender case-insensitively", `Quick,
            test_send_session_rejects_reserved_sender_case_insensitive )
        ] )
    ; ( "hook",
        [ ( "reads stdin session_id and drains global inbox", `Quick,
            test_hook_reads_stdin_session_and_drains_global_inbox )
        ; ( "legacy cli hook reads stdin session_id and drains global inbox", `Quick,
            test_cli_hook_reads_stdin_session_and_drains_global_inbox )
        ; ( "cli hook holds deferrable mid-turn (push-only drain)", `Quick,
            test_cli_hook_holds_deferrable_mid_turn )
        ; ( "extracts session_id from truncated large payload", `Quick,
            test_hook_extracts_session_from_truncated_large_payload )
        ; ( "merges message and cold boot context", `Quick,
            test_hook_merges_message_and_cold_boot_context )
        ; ( "rejects invalid stdin session_id", `Quick,
            test_hook_rejects_invalid_stdin_session_id )
        ] )
    ]
