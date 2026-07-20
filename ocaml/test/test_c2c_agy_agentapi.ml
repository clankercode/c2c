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
       Unix.alarm 3;
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
            test_ensure_writes_from_log_fixture ] )
    ]
