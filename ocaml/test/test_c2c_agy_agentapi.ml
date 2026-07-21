(* Auto agy-env discovery — path + log parsers + ensure write (hermetic). *)

let ( // ) = Filename.concat

let with_tmp_instances (f : string -> unit) =
  let dir = Filename.temp_file "c2c_agy_inst" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let prev = Sys.getenv_opt "C2C_INSTANCES_DIR" in
  Unix.putenv "C2C_INSTANCES_DIR" dir;
  Fun.protect
    ~finally:(fun () ->
      (match prev with
       | Some v -> Unix.putenv "C2C_INSTANCES_DIR" v
       | None -> Unix.putenv "C2C_INSTANCES_DIR" "");
      let rec rm p =
        if Sys.file_exists p then
          if Sys.is_directory p then begin
            Array.iter (fun e -> rm (p // e)) (Sys.readdir p);
            Unix.rmdir p
          end
          else Sys.remove p
      in
      try rm dir with _ -> ())
    (fun () -> f dir)

(** One-shot HTTP/1.0 200 server on a free loopback port. Returns (port, pid).
    Child exits after one accept or ~3s. *)
let spawn_healthz_once () : int * int =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 1;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "expected inet"
  in
  let pid = Unix.fork () in
  if pid = 0 then begin
    (* child *)
    (try
       ignore (Unix.alarm 3);
       let client, _ = Unix.accept sock in
       let buf = Bytes.create 512 in
       ignore (Unix.read client buf 0 512);
       let resp =
         "HTTP/1.0 200 OK\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}"
       in
       ignore (Unix.write_substring client resp 0 (String.length resp));
       Unix.close client
     with _ -> ());
    (try Unix.close sock with _ -> ());
    Unix._exit 0
  end
  else begin
    Unix.close sock;
    (port, pid)
  end

let reap pid =
  try ignore (Unix.waitpid [] pid) with _ -> ()

let contains hay needle =
  let hl = String.length hay and nl = String.length needle in
  let rec loop i =
    if i + nl > hl then false
    else if String.sub hay i nl = needle then true
    else loop (i + 1)
  in
  loop 0

let mk_msg ~from_alias ~to_alias ~content : C2c_mcp.message =
  { C2c_mcp.from_alias; to_alias; content; deferrable = false;
    reply_via = None; enc_status = None; ts = 0.0; ephemeral = false;
    message_id = None; pow_difficulty = None }

let test_instance_dir_respects_c2c_instances_dir () =
  with_tmp_instances (fun dir ->
      let path = C2c_agy_agentapi.env_file_path "sess-a" in
      Alcotest.(check string) "env under C2C_INSTANCES_DIR" (dir // "sess-a" // "agy-env.json")
        path)

let test_write_read_roundtrip () =
  with_tmp_instances (fun _dir ->
      C2c_agy_agentapi.write_agy_env "e2e"
        ~ls_address:"127.0.0.1:35817"
        ~conversation_id:"5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a";
      match C2c_agy_agentapi.read_agy_env "e2e" with
      | None -> Alcotest.fail "expected env after write"
      | Some env ->
          Alcotest.(check string) "ls" "127.0.0.1:35817" env.ls_address;
          Alcotest.(check string) "conv" "5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a"
            env.conversation_id)

let test_parse_http_ls_from_log_line () =
  let line =
    "I0721 01:11:46.122163 3015913 server.go:546] Language server listening on \
     random port at 35817 for HTTP"
  in
  Alcotest.(check (option int)) "http port" (Some 35817)
    (C2c_agy_agentapi.parse_http_ls_port_from_line line);
  let https =
    "I0721 01:11:46.121762 3015913 server.go:538] Language server listening on \
     random port at 45369 for HTTPS (gRPC)"
  in
  Alcotest.(check (option int)) "ignore https" None
    (C2c_agy_agentapi.parse_http_ls_port_from_line https)

let test_parse_conversation_from_log_line () =
  let line =
    "I0721 01:16:29.173570 3015913 server.go:903] Created conversation \
     5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a"
  in
  Alcotest.(check (option string)) "conversation uuid"
    (Some "5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a")
    (C2c_agy_agentapi.parse_created_conversation_from_line line)

let test_scan_log_file () =
  let path = Filename.temp_file "agy-cli" ".log" in
  let oc = open_out path in
  output_string oc
    "noise\n\
     I0721 01:11:46.122163 3015913 server.go:546] Language server listening on \
     random port at 35817 for HTTP\n\
     I0721 01:11:46.121762 3015913 server.go:538] Language server listening on \
     random port at 45369 for HTTPS (gRPC)\n\
     I0721 01:16:29.173570 3015913 server.go:903] Created conversation \
     5dd0ca7f-dad7-4688-9616-aca5ed5e8f9a\n\
     I0721 01:51:00.000000 3015913 server.go:903] Created conversation \
     2862b925-6e8e-44c6-b083-bb040da3e28f\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match C2c_agy_agentapi.scan_cli_log path with
      | None -> Alcotest.fail "expected scan hit"
      | Some { ls_http_port; conversation_id } ->
          Alcotest.(check (option int)) "http port" (Some 35817) ls_http_port;
          Alcotest.(check (option string)) "last conversation"
            (Some "2862b925-6e8e-44c6-b083-bb040da3e28f") conversation_id)

let test_ensure_uses_existing_when_ls_alive () =
  let port, child = spawn_healthz_once () in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill child Sys.sigterm with _ -> ());
      reap child)
    (fun () ->
      with_tmp_instances (fun _ ->
          let ls = Printf.sprintf "127.0.0.1:%d" port in
          C2c_agy_agentapi.write_agy_env "keep" ~ls_address:ls
            ~conversation_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
          match
            C2c_agy_agentapi.ensure_agy_env ~session_id:"keep" ?agy_pid:None ()
          with
          | None -> Alcotest.fail "expected existing live env"
          | Some env ->
              Alcotest.(check string) "unchanged ls" ls env.ls_address))

let test_ensure_refreshes_dead_ls () =
  with_tmp_instances (fun _ ->
      C2c_agy_agentapi.write_agy_env "dead"
        ~ls_address:"127.0.0.1:1"
        ~conversation_id:"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
      let log_dir = Filename.temp_file "agy-logdir2" "" in
      Sys.remove log_dir;
      Unix.mkdir log_dir 0o755;
      let log = log_dir // "cli-20260721_999999.log" in
      let oc = open_out log in
      output_string oc "noise only\n";
      close_out oc;
      Fun.protect
        ~finally:(fun () ->
          (try Sys.remove log with _ -> ());
          (try Unix.rmdir log_dir with _ -> ()))
        (fun () ->
          match
            C2c_agy_agentapi.ensure_agy_env ~session_id:"dead"
              ~cli_log_dir:log_dir ?agy_pid:None ()
          with
          | Some env when env.ls_address = "127.0.0.1:1" ->
              Alcotest.fail "must not keep dead LS"
          | _ -> ()))

let test_ensure_writes_from_log_fixture () =
  let port, child = spawn_healthz_once () in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill child Sys.sigterm with _ -> ());
      reap child)
    (fun () ->
      with_tmp_instances (fun _ ->
          let log_dir = Filename.temp_file "agy-logdir" "" in
          Sys.remove log_dir;
          Unix.mkdir log_dir 0o755;
          let log = log_dir // "cli-20260721_011146.log" in
          let oc = open_out log in
          Printf.fprintf oc
            "I0721 01:11:46.122163 9 server.go:546] Language server listening on \
             random port at %d for HTTP\n\
             I0721 01:16:29.173570 9 server.go:903] Created conversation \
             11111111-2222-3333-4444-555555555555\n"
            port;
          close_out oc;
          Fun.protect
            ~finally:(fun () ->
              (try Sys.remove log with _ -> ());
              (try Unix.rmdir log_dir with _ -> ()))
            (fun () ->
              match
                C2c_agy_agentapi.ensure_agy_env ~session_id:"from-log"
                  ~cli_log_dir:log_dir ?agy_pid:None ()
              with
              | None -> Alcotest.fail "expected ensure from log"
              | Some env ->
                  let expected_ls = Printf.sprintf "127.0.0.1:%d" port in
                  Alcotest.(check string) "ls from log" expected_ls env.ls_address;
                  Alcotest.(check string) "conv from log"
                    "11111111-2222-3333-4444-555555555555" env.conversation_id;
                  Alcotest.(check bool) "persisted" true
                    (Sys.file_exists (C2c_agy_agentapi.env_file_path "from-log")))))

(* #78 cold-start: ensure_agy_env must NEVER accept a c2c-minted headless
   conversation as the wake target. When the CLI log has a live HTTP LS but no
   TUI-owned "Created conversation" line, ensure must return None and must not
   write agy-env.json — even if agentapi new-conversation would succeed
   (forced here via C2C_AGY_NEW_CONVERSATION_FIXTURE). send-message only wakes
   conversations the TUI itself owns. *)
let test_i78_ensure_does_not_mint_when_log_has_ls_only () =
  let fixture_conv = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" in
  let port, child = spawn_healthz_once () in
  let prev_fix = Sys.getenv_opt "C2C_AGY_NEW_CONVERSATION_FIXTURE" in
  Unix.putenv "C2C_AGY_NEW_CONVERSATION_FIXTURE" fixture_conv;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill child Sys.sigterm with _ -> ());
      reap child;
      match prev_fix with
      | Some v -> Unix.putenv "C2C_AGY_NEW_CONVERSATION_FIXTURE" v
      | None -> Unix.putenv "C2C_AGY_NEW_CONVERSATION_FIXTURE" "")
    (fun () ->
      with_tmp_instances (fun _ ->
          let log_dir = Filename.temp_file "agy-logdir-i78" "" in
          Sys.remove log_dir;
          Unix.mkdir log_dir 0o755;
          let log = log_dir // "cli-cold-start.log" in
          let oc = open_out log in
          (* Live LS only — no "Created conversation" (idle TUI, never turned). *)
          Printf.fprintf oc
            "I0721 01:11:46.122163 9 server.go:546] Language server listening on \
             random port at %d for HTTP\n"
            port;
          close_out oc;
          Fun.protect
            ~finally:(fun () ->
              (try Sys.remove log with _ -> ());
              (try Unix.rmdir log_dir with _ -> ()))
            (fun () ->
              let sid = "cold-start-i78" in
              let env_path = C2c_agy_agentapi.env_file_path sid in
              (match
                 C2c_agy_agentapi.ensure_agy_env ~session_id:sid
                   ~cli_log_dir:log_dir ?agy_pid:None ()
               with
               | Some env when env.conversation_id = fixture_conv ->
                   Alcotest.fail
                     "#78: ensure_agy_env must not mint a headless conversation \
                      (fixture id was accepted as wake target)"
               | Some env ->
                   Alcotest.failf
                     "#78: expected None while waiting for TUI conversation, \
                      got ls=%s conv=%s"
                     env.ls_address env.conversation_id
               | None -> ());
              Alcotest.(check bool)
                "#78: must not persist agy-env without TUI conversation" false
                (Sys.file_exists env_path))))

(* ---- The wake method: `agy agentapi send-message` ---------------------- *)

(* The load-bearing assertion for agy's automated wake: the deliver path invokes
   exactly `agy agentapi send-message --title=c2c inbound <conversation_id>
   <content>`. Asserting the pure argv keeps this hermetic (no `agy` spawn) while
   pinning the command the live e2e proved wakes the TUI (WOKE-AW7Q2). *)
let test_send_argv_shape () =
  Alcotest.(check (array string)) "send-message argv"
    [| "agy"; "agentapi"; "send-message"; "--title=c2c inbound"; "conv-123"
     ; "hello world" |]
    (C2c_agy_agentapi.agentapi_send_argv ~conversation_id:"conv-123"
       ~content:"hello world")

let test_new_conversation_argv_shape () =
  Alcotest.(check (array string)) "new-conversation argv"
    [| "agy"; "agentapi"; "new-conversation"; "--model=flash_lite"
     ; "--title=c2c-wake"; "hi" |]
    (C2c_agy_agentapi.agentapi_new_conversation_argv ~model:"flash_lite"
       ~title:"c2c-wake" ~prompt:"hi")

(* The wake is routed to the right language server by ANTIGRAVITY_LS_ADDRESS;
   a stale LS/project from the inherited env must be replaced, not duplicated. *)
let test_with_ls_env_sets_and_strips () =
  let base =
    [| "PATH=/bin"; "ANTIGRAVITY_LS_ADDRESS=stale:1"
     ; "ANTIGRAVITY_PROJECT_ID=old"; "HOME=/x" |]
  in
  let out = C2c_agy_agentapi.with_ls_env ~ls_address:"127.0.0.1:35817" base in
  let has p = Array.exists (fun s -> s = p) out in
  let count_prefix pfx =
    Array.fold_left
      (fun acc s ->
        if String.length s >= String.length pfx
           && String.sub s 0 (String.length pfx) = pfx
        then acc + 1 else acc)
      0 out
  in
  Alcotest.(check bool) "new LS set" true
    (has "ANTIGRAVITY_LS_ADDRESS=127.0.0.1:35817");
  Alcotest.(check bool) "project id set" true
    (has "ANTIGRAVITY_PROJECT_ID=default-cli-project");
  Alcotest.(check int) "exactly one LS entry" 1
    (count_prefix "ANTIGRAVITY_LS_ADDRESS=");
  Alcotest.(check int) "exactly one project-id entry" 1
    (count_prefix "ANTIGRAVITY_PROJECT_ID=");
  Alcotest.(check bool) "unrelated env preserved" true
    (has "PATH=/bin" && has "HOME=/x")

(* B098: the content pushed into the TUI is framed as DATA, never as an
   instruction or an approval — the envelope plus an explicit "treat as data"
   hint. *)
let test_format_inbound_payload_data_framed () =
  let payload =
    C2c_agy_agentapi.format_inbound_payload
      [ mk_msg ~from_alias:"peer-x" ~to_alias:"agy-y"
          ~content:"ping WOKE-TEST" ]
  in
  Alcotest.(check bool) "c2c envelope present" true (contains payload "<c2c");
  Alcotest.(check bool) "sender attributed" true (contains payload "peer-x");
  Alcotest.(check bool) "body carried" true (contains payload "WOKE-TEST");
  Alcotest.(check bool) "DATA framing (treat as data)" true
    (contains payload "treat as data")

(* Empty inbox short-circuits to Ok without touching agentapi / auto-discovery
   (keeps this hermetic — no dependence on a real ~/.gemini CLI log). *)
let test_deliver_messages_empty_is_ok () =
  match C2c_agy_agentapi.deliver_messages ~session_id:"none" [] with
  | Ok () -> ()
  | Error e -> Alcotest.failf "empty deliver should be Ok, got Error %s" e

let () =
  Alcotest.run "c2c_agy_agentapi"
    [ ( "paths",
        [ Alcotest.test_case "C2C_INSTANCES_DIR" `Quick
            test_instance_dir_respects_c2c_instances_dir
        ; Alcotest.test_case "write/read" `Quick test_write_read_roundtrip ] )
    ; ( "log_parse",
        [ Alcotest.test_case "http ls port" `Quick
            test_parse_http_ls_from_log_line
        ; Alcotest.test_case "created conversation" `Quick
            test_parse_conversation_from_log_line
        ; Alcotest.test_case "scan file last-wins conv" `Quick test_scan_log_file
        ] )
    ; ( "ensure",
        [ Alcotest.test_case "keeps existing when LS alive" `Quick
            test_ensure_uses_existing_when_ls_alive
        ; Alcotest.test_case "refreshes dead LS" `Quick
            test_ensure_refreshes_dead_ls
        ; Alcotest.test_case "writes from log fixture" `Quick
            test_ensure_writes_from_log_fixture
        ; Alcotest.test_case
            "#78 cold-start: no headless mint when log has LS only" `Quick
            test_i78_ensure_does_not_mint_when_log_has_ls_only ] )
    ; ( "send",
        [ Alcotest.test_case "send-message argv" `Quick test_send_argv_shape
        ; Alcotest.test_case "new-conversation argv" `Quick
            test_new_conversation_argv_shape
        ; Alcotest.test_case "with_ls_env sets and strips" `Quick
            test_with_ls_env_sets_and_strips ] )
    ; ( "payload",
        [ Alcotest.test_case "inbound payload is DATA-framed (B098)" `Quick
            test_format_inbound_payload_data_framed
        ; Alcotest.test_case "empty deliver is Ok" `Quick
            test_deliver_messages_empty_is_ok ] )
    ]
