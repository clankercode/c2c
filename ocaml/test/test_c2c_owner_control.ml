(* Hermetic tests for C2c_owner_control (P2.M2.E1.T003). *)

let tmp_dir () =
  let path = Filename.temp_file "c2c_owner_control" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let test_request_result_roundtrip () =
  let dir = tmp_dir () in
  let id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"inst-a"
      ~force:true ~expected_pid:4242 ~expected_start_time:99 ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "expected request"
  | Some req ->
      Alcotest.(check string) "id" id req.C2c_owner_control.id;
      Alcotest.(check bool) "force" true req.force;
      Alcotest.(check string) "name" "inst-a" req.instance_name;
      Alcotest.(check (option int)) "pid" (Some 4242) req.expected_pid;
      Alcotest.(check (option int)) "start" (Some 99) req.expected_start_time;
      (* consumed => gone *)
      Alcotest.(check bool) "consumed once" true
        (C2c_owner_control.consume_request ~instance_dir:dir = None);
      C2c_owner_control.write_result ~instance_dir:dir ~request_id:id
        ~result:C2c_owner_control.Restarting;
      (match
         C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
           ~timeout_s:0.5
       with
       | Some C2c_owner_control.Restarting -> ()
       | Some other ->
           Alcotest.failf "expected Restarting, got %s"
             (C2c_owner_control.result_kind_to_string other)
       | None -> Alcotest.fail "timeout waiting for result")

let test_toctou_pid_mismatch () =
  let dir = tmp_dir () in
  let id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"inst-a"
      ~force:false ~expected_pid:111 ~expected_start_time:5 ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "request"
  | Some req ->
      let owner =
        { C2c_owner_control.name = "inst-a"; pid = 222; start_time = Some 5 }
      in
      let plan =
        { C2c_owner_control.executable = "/bin/true"
        ; argv = [| "/bin/true" |]
        ; cwd = None
        ; env = [||]
        }
      in
      let exec_called = ref false in
      (match
         C2c_owner_control.commit_takeover ~instance_dir:dir ~request:req
           ~owner ~plan
           ~teardown:(fun () -> Ok ())
           ~do_exec:(fun _ -> exec_called := true)
           ()
       with
       | Error "pid-mismatch" -> ()
       | Error e -> Alcotest.failf "unexpected error %s" e
       | Ok () -> Alcotest.fail "should not commit");
      Alcotest.(check bool) "no exec" false !exec_called;
      (match
         C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
           ~timeout_s:0.2
       with
       | Some (C2c_owner_control.Declined "pid-mismatch") -> ()
       | Some other ->
           Alcotest.failf "expected declined pid-mismatch, got %s"
             (C2c_owner_control.result_kind_to_string other)
       | None -> Alcotest.fail "missing result")

let test_toctou_start_time_mismatch () =
  let dir = tmp_dir () in
  let id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"inst-a"
      ~force:true ~expected_pid:7 ~expected_start_time:100 ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "request"
  | Some req ->
      let owner =
        { C2c_owner_control.name = "inst-a"; pid = 7; start_time = Some 101 }
      in
      let plan =
        { C2c_owner_control.executable = "/bin/true"
        ; argv = [| "/bin/true" |]
        ; cwd = None
        ; env = [||]
        }
      in
      (match
         C2c_owner_control.commit_takeover ~instance_dir:dir ~request:req
           ~owner ~plan ~teardown:(fun () -> Ok ())
           ~do_exec:(fun _ -> ())
           ()
       with
       | Error "start-time-mismatch" -> ()
       | other ->
           Alcotest.failf "expected start-time-mismatch, got %s"
             (match other with Ok () -> "ok" | Error e -> e));
      (match
         C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
           ~timeout_s:0.2
       with
       | Some (C2c_owner_control.Declined "start-time-mismatch") -> ()
       | Some other ->
           Alcotest.failf "bad result %s"
             (C2c_owner_control.result_kind_to_string other)
       | None -> Alcotest.fail "missing result")

let test_name_mismatch () =
  let dir = tmp_dir () in
  let _id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"alpha"
      ~force:false ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "request"
  | Some req ->
      let owner =
        { C2c_owner_control.name = "beta"; pid = 1; start_time = None }
      in
      let plan =
        { C2c_owner_control.executable = "/bin/true"
        ; argv = [| "/bin/true" |]
        ; cwd = None
        ; env = [||]
        }
      in
      (match
         C2c_owner_control.commit_takeover ~instance_dir:dir ~request:req
           ~owner ~plan ~teardown:(fun () -> Ok ())
           ~do_exec:(fun _ -> ())
           ()
       with
       | Error "instance-name-mismatch" -> ()
       | other ->
           Alcotest.failf "expected name mismatch, got %s"
             (match other with Ok () -> "ok" | Error e -> e))

let test_ack_only_after_teardown_commit () =
  let dir = tmp_dir () in
  let id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"inst-a"
      ~force:true ~expected_pid:9 ~expected_start_time:3 ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "request"
  | Some req ->
      let owner =
        { C2c_owner_control.name = "inst-a"; pid = 9; start_time = Some 3 }
      in
      let plan =
        { C2c_owner_control.executable = "/bin/true"
        ; argv = [| "/bin/true" |]
        ; cwd = None
        ; env = [||]
        }
      in
      let order = ref [] in
      let teardown () =
        order := "teardown" :: !order;
        (* No result file yet — ack must not precede commit. *)
        Alcotest.(check bool) "no early result" true
          (C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
             ~timeout_s:0.0
           = None);
        Ok ()
      in
      let do_exec _ =
        order := "exec" :: !order;
        match
          C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
            ~timeout_s:0.2
        with
        | Some C2c_owner_control.Restarting -> ()
        | _ -> Alcotest.fail "restarting ack must be visible at exec"
      in
      (match
         C2c_owner_control.commit_takeover ~instance_dir:dir ~request:req
           ~owner ~plan ~teardown ~do_exec ()
       with
       | Ok () -> ()
       | Error e -> Alcotest.failf "commit failed: %s" e);
      Alcotest.(check (list string)) "order"
        [ "exec"; "teardown" ] !order

let test_teardown_failure_does_not_exec () =
  let dir = tmp_dir () in
  let id =
    C2c_owner_control.request_restart ~instance_dir:dir ~instance_name:"inst-a"
      ~force:false ~expected_pid:1 ()
  in
  match C2c_owner_control.consume_request ~instance_dir:dir with
  | None -> Alcotest.fail "request"
  | Some req ->
      let owner =
        { C2c_owner_control.name = "inst-a"; pid = 1; start_time = None }
      in
      let plan =
        { C2c_owner_control.executable = "/bin/true"
        ; argv = [| "/bin/true" |]
        ; cwd = None
        ; env = [||]
        }
      in
      let exec_called = ref false in
      (match
         C2c_owner_control.commit_takeover ~instance_dir:dir ~request:req
           ~owner ~plan
           ~teardown:(fun () -> Error "reap-failed")
           ~do_exec:(fun _ -> exec_called := true)
           ()
       with
       | Error "reap-failed" -> ()
       | other ->
           Alcotest.failf "expected reap-failed, got %s"
             (match other with Ok () -> "ok" | Error e -> e));
      Alcotest.(check bool) "no exec" false !exec_called;
      (match
         C2c_owner_control.await_result ~instance_dir:dir ~request_id:id
           ~timeout_s:0.2
       with
       | Some (C2c_owner_control.Failed "reap-failed") -> ()
       | Some other ->
           Alcotest.failf "expected failed reap, got %s"
             (C2c_owner_control.result_kind_to_string other)
       | None -> Alcotest.fail "missing result")

let test_timeout_await () =
  let dir = tmp_dir () in
  match
    C2c_owner_control.await_result ~instance_dir:dir ~request_id:"nope"
      ~timeout_s:0.05
  with
  | None -> ()
  | Some _ -> Alcotest.fail "should time out"

let test_filter_env_strips_ambient_and_instance () =
  let source =
    [| "HOME=/home/x"
     ; "PATH=/usr/bin"
     ; "C2C_INSTANCE_NAME=should-go"
     ; "C2C_MCP_BROKER_ROOT=/tmp/broker"
     ; "SECRET_TOKEN=nope"
     ; "AWS_SECRET_ACCESS_KEY=nope"
     ; "TERM=xterm"
    |]
  in
  let env = C2c_owner_control.filter_env ~source () in
  let keys =
    Array.to_list env
    |> List.map (fun e ->
           try String.sub e 0 (String.index e '=') with Not_found -> e)
  in
  Alcotest.(check bool) "keeps HOME" true (List.mem "HOME" keys);
  Alcotest.(check bool) "keeps PATH" true (List.mem "PATH" keys);
  Alcotest.(check bool) "keeps broker" true
    (List.mem "C2C_MCP_BROKER_ROOT" keys);
  Alcotest.(check bool) "keeps TERM" true (List.mem "TERM" keys);
  Alcotest.(check bool) "strips instance" false
    (List.mem "C2C_INSTANCE_NAME" keys);
  Alcotest.(check bool) "strips SECRET" false (List.mem "SECRET_TOKEN" keys);
  Alcotest.(check bool) "strips AWS" false
    (List.mem "AWS_SECRET_ACCESS_KEY" keys)

let () =
  Alcotest.run "c2c_owner_control"
    [ ( "owner-control",
        [ Alcotest.test_case "request/result roundtrip" `Quick
            test_request_result_roundtrip
        ; Alcotest.test_case "TOCTOU pid mismatch" `Quick test_toctou_pid_mismatch
        ; Alcotest.test_case "TOCTOU start-time mismatch" `Quick
            test_toctou_start_time_mismatch
        ; Alcotest.test_case "instance name mismatch" `Quick test_name_mismatch
        ; Alcotest.test_case "ack only after teardown commit" `Quick
            test_ack_only_after_teardown_commit
        ; Alcotest.test_case "teardown failure no exec" `Quick
            test_teardown_failure_does_not_exec
        ; Alcotest.test_case "await timeout" `Quick test_timeout_await
        ; Alcotest.test_case "controlled env filter" `Quick
            test_filter_env_strips_ambient_and_instance
        ] )
    ]
