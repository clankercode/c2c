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
  (* Even with C2C_KIMI_DELIVER_FIXTURE_TOKEN set, the gate must be =1. *)
  with_tmpdir (fun tmp ->
      with_home tmp (fun () ->
          without_fixture (fun () ->
              Unix.putenv "C2C_KIMI_DELIVER_FIXTURE_TOKEN" "should-be-ignored";
              Alcotest.(check (option string)) "token override ignored without gate"
                None (C2c_kimi_deliver.read_server_token ()))))

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
      ]
    ; "submit_prompt",
      [ Alcotest.test_case "errors when no token available" `Quick
          test_submit_prompt_errors_without_token
      ]
    ; "deliver_message",
      [ Alcotest.test_case "message_envelope escapes hostile content" `Quick
          test_deliver_message_escapes_content
      ]
    ]
