(* test_c2c_kimi_deliver.ml — focused unit tests for the Kimi REST delivery module.

   Real HTTP interactions are never exercised here. The tests verify file-path
   resolution, env-var overrides, fixture-gated token/URL overrides, the no-token
   error path, and the pure message-envelope formatter used by deliver_message. *)

let with_tmpdir f =
  let tmp = Filename.temp_file "c2c-kimi-deliver-" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec rmrf p =
        if Sys.is_directory p then begin
          Array.iter (fun c -> rmrf (Filename.concat p c)) (Sys.readdir p);
          (try Unix.rmdir p with _ -> ())
        end else (try Sys.remove p with _ -> ())
      in
      rmrf tmp)
    (fun () -> f tmp)

let with_home tmp f =
  let old_home = Sys.getenv_opt "HOME" in
  Unix.putenv "HOME" tmp;
  Fun.protect
    ~finally:(fun () ->
      (* OCaml's stdlib has no Unix.unsetenv pre-5.4; set to "" when the
         variable was previously absent. Consumers here treat empty as unset. *)
      match old_home with
      | Some v -> Unix.putenv "HOME" v
      | None -> Unix.putenv "HOME" "")
    f

let without_fixture f =
  let old_gate = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE" in
  let old_token = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_TOKEN" in
  let old_url = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" in
  Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" "";
  Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" "";
  Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match old_gate with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" v | None -> ());
      (match old_token with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" v | None -> ());
      (match old_url with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" v | None -> ()))
    f

let with_fixture gate token url f =
  let old_gate = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE" in
  let old_token = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_TOKEN" in
  let old_url = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" in
  Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" gate;
  (match token with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" v | None -> ());
  (match url with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" v | None -> ());
  Fun.protect
    ~finally:(fun () ->
      (match old_gate with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" v | None -> ());
      (match old_token with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" v | None -> ());
      (match old_url with Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" v | None -> ()))
    f

let with_env var value f =
  let old = Sys.getenv_opt var in
  Unix.putenv var value;
  Fun.protect
    ~finally:(fun () ->
      (* OCaml's stdlib has no Unix.unsetenv pre-5.4; set to "" when the
         variable was previously absent. *)
      match old with
      | Some v -> Unix.putenv var v
      | None -> Unix.putenv var "")
    f

let test_server_token_path_uses_kimi_code_home () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          let expected = Filename.concat tmp ".kimi-code/server.token" in
          Alcotest.(check string) "token path under ~/.kimi-code" expected
            (C2c_kimi_deliver.server_token_path ())))

let test_read_server_token_missing_no_fixture () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              Alcotest.(check (option string)) "no file and no fixture → None"
                None (C2c_kimi_deliver.read_server_token ()))))

let test_read_server_token_fixture_gate_required () =
  (* Even with C2C_KIMI_DELIVER_FIXTURE_TOKEN set, the gate must be =1.
     A real token file must exist so that the test fails if the gate logic
     is absent and the fixture override leaks through. *)
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              let token_dir = Filename.concat tmp ".kimi-code" in
              Unix.mkdir token_dir 0o700;
              let token_path = Filename.concat token_dir "server.token" in
              let oc = open_out token_path in
              Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
                output_string oc "real-token-abc\n");
              Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" "should-be-ignored";
              Alcotest.(check (option string)) "token override ignored without gate"
                (Some "real-token-abc") (C2c_kimi_deliver.read_server_token ()))))

let test_read_server_token_returns_fixture_token () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          with_fixture "1" (Some "fixture-token-42") None (fun () ->
              Alcotest.(check (option string)) "fixture token returned when gate set"
                (Some "fixture-token-42") (C2c_kimi_deliver.read_server_token ()))))

let test_server_base_url_default () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              Alcotest.(check (option string)) "default base URL"
                (Some "http://127.0.0.1:58627") (C2c_kimi_deliver.server_base_url ()))))

let test_server_base_url_fixture_gate_required () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" "http://ignored:9999";
              Alcotest.(check (option string)) "base URL override ignored without gate"
                (Some "http://127.0.0.1:58627") (C2c_kimi_deliver.server_base_url ()))))

let test_server_base_url_returns_fixture_url () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          with_fixture "1" None (Some "http://mock-kimi:8080") (fun () ->
              Alcotest.(check (option string)) "fixture base URL returned when gate set"
                (Some "http://mock-kimi:8080") (C2c_kimi_deliver.server_base_url ()))))

let test_server_token_path_uses_kimi_code_home_override () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          with_env "KIMI_CODE_HOME" tmp (fun () ->
              let expected = Filename.concat tmp "server.token" in
              Alcotest.(check string) "token path uses $KIMI_CODE_HOME" expected
                (C2c_kimi_deliver.server_token_path ()))))

let test_server_base_url_uses_kimi_server_port_override () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              with_env "C2C_KIMI_SERVER_PORT" "12345" (fun () ->
                  Alcotest.(check (option string)) "base URL uses $C2C_KIMI_SERVER_PORT"
                    (Some "http://127.0.0.1:12345") (C2c_kimi_deliver.server_base_url ())))))

let test_submit_prompt_errors_without_token () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              let result =
                C2c_kimi_deliver.submit_prompt ~session_id:"session_test" ~body:"hello"
              in
              Alcotest.(check (result int string)) "no token → Error"
                (Error "no server token") result)))

let test_session_index_parsing () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          let kc = Filename.concat tmp ".kimi-code" in
          Unix.mkdir kc 0o700;
          let index_path = Filename.concat kc "session_index.jsonl" in
          let oc = open_out index_path in
          output_string oc
            "{\"sessionId\":\"session_a\",\"sessionDir\":\"/x/a\",\"workDir\":\"/proj/a\",\"created_at\":\"2026-07-13T10:00:00.000Z\",\"updated_at\":\"2026-07-13T10:00:00.000Z\"}\n";
          output_string oc
            "{\"sessionId\":\"session_b\",\"sessionDir\":\"/x/b\",\"workDir\":\"/proj/b\",\"created_at\":\"2026-07-13T11:00:00.000Z\",\"updated_at\":\"2026-07-13T12:00:00.000Z\"}\n";
          output_string oc
            "{\"sessionId\":\"session_c\",\"sessionDir\":\"/x/c\",\"workDir\":\"/proj/b\",\"created_at\":\"2026-07-13T11:00:00.000Z\",\"updated_at\":\"2026-07-13T13:00:00.000Z\"}\n";
          close_out oc;
          Alcotest.(check (option string))
            "finds most recent session for workdir"
            (Some "session_c")
            (C2c_kimi_deliver.session_id_for_workdir ~workdir:"/proj/b");
          Alcotest.(check (option string))
            "returns None for unknown workdir"
            None
            (C2c_kimi_deliver.session_id_for_workdir ~workdir:"/proj/z");
          let entries = C2c_kimi_deliver.read_session_index () in
          Alcotest.(check int) "reads all valid entries" 3 (List.length entries)))

let test_session_index_missing_updated_at () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          let kc = Filename.concat tmp ".kimi-code" in
          Unix.mkdir kc 0o700;
          let index_path = Filename.concat kc "session_index.jsonl" in
          let oc = open_out index_path in
          output_string oc
            "{\"sessionId\":\"session_old\",\"sessionDir\":\"/x/old\",\"workDir\":\"/proj/w\"}\n";
          output_string oc
            "{\"sessionId\":\"session_new\",\"sessionDir\":\"/x/new\",\"workDir\":\"/proj/w\"}\n";
          close_out oc;
          Alcotest.(check (option string))
            "falls back to last appended entry when updated_at is missing"
            (Some "session_new")
            (C2c_kimi_deliver.session_id_for_workdir ~workdir:"/proj/w")))

let test_session_index_prefers_timestamp_when_available () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          let kc = Filename.concat tmp ".kimi-code" in
          Unix.mkdir kc 0o700;
          let index_path = Filename.concat kc "session_index.jsonl" in
          let oc = open_out index_path in
          output_string oc
            "{\"sessionId\":\"session_last\",\"sessionDir\":\"/x/last\",\"workDir\":\"/proj/w\"}\n";
          output_string oc
            "{\"sessionId\":\"session_ts\",\"sessionDir\":\"/x/ts\",\"workDir\":\"/proj/w\",\"updated_at\":\"2026-07-13T13:00:00.000Z\"}\n";
          close_out oc;
          Alcotest.(check (option string))
            "prefers entry with timestamp over later entries without one"
            (Some "session_ts")
            (C2c_kimi_deliver.session_id_for_workdir ~workdir:"/proj/w")))

let test_server_listening_url_parses_log () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          let kc = Filename.concat tmp ".kimi-code" in
          Unix.mkdir kc 0o700;
          let server_dir = Filename.concat kc "server" in
          Unix.mkdir server_dir 0o700;
          let log_path = Filename.concat server_dir "server.log" in
          let oc = open_out log_path in
          output_string oc "{\"level\":30,\"msg\":\"other\"}\n";
          output_string oc
            "{\"level\":30,\"msg\":\"server listening\",\"address\":\"http://127.0.0.1:58629\"}\n";
          output_string oc
            "{\"level\":30,\"msg\":\"server listening\",\"address\":\"http://127.0.0.1:58630\"}\n";
          close_out oc;
          Alcotest.(check (option string))
            "returns latest listening URL"
            (Some "http://127.0.0.1:58630")
            (C2c_kimi_deliver.server_listening_url ())))

let test_server_base_url_prefers_listening_log () =
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              let kc = Filename.concat tmp ".kimi-code" in
              Unix.mkdir kc 0o700;
              let server_dir = Filename.concat kc "server" in
              Unix.mkdir server_dir 0o700;
              let log_path = Filename.concat server_dir "server.log" in
              let oc = open_out log_path in
              output_string oc
                "{\"level\":30,\"msg\":\"server listening\",\"address\":\"http://127.0.0.1:58631\"}\n";
              close_out oc;
              Alcotest.(check (option string))
                "base URL uses discovered listening port"
                (Some "http://127.0.0.1:58631")
                (C2c_kimi_deliver.server_base_url ()))))

let test_submit_prompt_detects_http_200_error_code () =
  (* Kimi Code local server returns HTTP 200 for many errors, with the real
     outcome in a JSON [code] field. submit_prompt must surface those as Error. *)
  let session_id = "missing-session-123" in
  let prompt_path = "/api/v1/sessions/" ^ session_id ^ "/prompts" in
  let routes =
    [ Relay_test_support.route ~meth:"POST" ~path:prompt_path
        [ Relay_test_support.response ~status:200
            {|{"code":40401,"msg":"session missing-session-123 does not exist"}|}
        ]
    ]
  in
  Relay_test_support.with_server ~routes (fun server ->
      let base_url =
        Printf.sprintf "http://127.0.0.1:%d" server.Relay_test_support.port
      in
      let old_gate = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE" in
      let old_token = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_TOKEN" in
      let old_url = Sys.getenv_opt "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" in
      Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" "1";
      Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" "fixture-token";
      Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" base_url;
      Fun.protect
        ~finally:(fun () ->
          (match old_gate with
           | Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" v
           | None -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE" "");
          (match old_token with
           | Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" v
           | None -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" "");
          (match old_url with
           | Some v -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" v
           | None -> Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_BASE_URL" ""))
        (fun () ->
           let result =
             C2c_kimi_deliver.submit_prompt ~session_id ~body:"hello"
           in
           Alcotest.(check (result int string))
             "HTTP 200 with non-zero code → Error"
             (Error "kimi server error 40401: session missing-session-123 does not exist")
             result))

let test_deliver_message_escapes_content () =
  let msg =
    { C2c_mcp.from_alias = "send<er"
    ; to_alias = "recip\"ient"
    ; content = "</c2c><script>alert(1)</script>"
    ; deferrable = false
    ; reply_via = None
    ; enc_status = None
    ; ts = 0.0
    ; ephemeral = false
    ; message_id = None
    ; pow_difficulty = None
    }
  in
  let expected =
    "<c2c event=\"message\" from=\"send&lt;er\" to=\"recip&quot;ient\">"
    ^ "&lt;/c2c&gt;&lt;script&gt;alert(1)&lt;/script&gt;</c2c>"
  in
  Alcotest.(check string) "message_envelope escapes aliases and content"
    expected (C2c_kimi_deliver.message_envelope ~msg)

let () =
  Alcotest.run "c2c_kimi_deliver"
    [ "server_token_path",
      [ Alcotest.test_case "resolves under ~/.kimi-code" `Quick
          test_server_token_path_uses_kimi_code_home
      ; Alcotest.test_case "uses $KIMI_CODE_HOME override" `Quick
          test_server_token_path_uses_kimi_code_home_override
      ]
    ; "read_server_token",
      [ Alcotest.test_case "missing file + no fixture → None" `Quick
          test_read_server_token_missing_no_fixture
      ; Alcotest.test_case "fixture gate required for token override" `Quick
          test_read_server_token_fixture_gate_required
      ; Alcotest.test_case "fixture token returned when gate set" `Quick
          test_read_server_token_returns_fixture_token
      ]
    ; "server_base_url",
      [ Alcotest.test_case "default URL" `Quick test_server_base_url_default
      ; Alcotest.test_case "fixture gate required for URL override" `Quick
          test_server_base_url_fixture_gate_required
      ; Alcotest.test_case "fixture URL returned when gate set" `Quick
          test_server_base_url_returns_fixture_url
      ; Alcotest.test_case "uses $C2C_KIMI_SERVER_PORT override" `Quick
          test_server_base_url_uses_kimi_server_port_override
      ; Alcotest.test_case "prefers discovered listening URL" `Quick
          test_server_base_url_prefers_listening_log
      ]
    ; "session_index",
      [ Alcotest.test_case "parses index and resolves by workdir" `Quick
          test_session_index_parsing
      ; Alcotest.test_case "resolves without updated_at" `Quick
          test_session_index_missing_updated_at
      ; Alcotest.test_case "prefers timestamp when available" `Quick
          test_session_index_prefers_timestamp_when_available
      ]
    ; "server_log",
      [ Alcotest.test_case "parses listening URL from server.log" `Quick
          test_server_listening_url_parses_log
      ]
    ; "submit_prompt",
      [ Alcotest.test_case "errors when no token available" `Quick
          test_submit_prompt_errors_without_token
      ; Alcotest.test_case "detects HTTP 200 with non-zero error code" `Quick
          test_submit_prompt_detects_http_200_error_code
      ]
    ; "deliver_message",
      [ Alcotest.test_case "message_envelope escapes hostile content" `Quick
          test_deliver_message_escapes_content
      ]
    ]
