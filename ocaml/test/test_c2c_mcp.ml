open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-mcp-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let test_register_and_list () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None;
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "one registration" 1 (List.length regs);
      let reg = List.hd regs in
      check string "alias" "storm-ember" reg.alias;
      check string "session" "session-a" reg.session_id)

let test_send_enqueues_message_for_target_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None;
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None;
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-ember" ~to_alias:"storm-storm" ~content:"hello";
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "one inbox message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "from alias" "storm-ember" msg.from_alias;
      check string "content" "hello" msg.content)

let test_drain_inbox_returns_and_clears_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None;
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None;
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-ember" ~to_alias:"storm-storm" ~content:"hello";
       let drained = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b" in
       check int "drained one message" 1 (List.length drained);
       check int "inbox now empty" 0 (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:"session-b")))

let test_blank_inbox_file_is_treated_as_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let path = Filename.concat dir "session-z.inbox.json" in
      let oc = open_out path in
      close_out oc;
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-z" in
      check int "blank inbox treated as empty" 0 (List.length inbox))

let test_channel_notification_matches_claude_channel_shape () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "debate me" }
  in
  let open Yojson.Safe.Util in
  check string "jsonrpc" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel" (json |> member "method" |> to_string);
  check string "content" "debate me" (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from_alias" |> to_string);
  check string "to alias meta" "storm-storm"
    (json |> member "params" |> member "meta" |> member "to_alias" |> to_string)

let test_initialize_returns_mcp_capabilities () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1)
          ; ("method", `String "initialize")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected initialize response"
       | Some json ->
           let open Yojson.Safe.Util in
            check string "protocol version" "2024-11-05"
              (json |> member "result" |> member "protocolVersion" |> to_string);
            check bool "instructions present"
              true
              (json |> member "result" |> member "instructions" <> `Null);
            ignore
              (json |> member "result" |> member "capabilities" |> member "experimental" |> member "claude/channel"))

let test_initialize_reports_supported_protocol_version () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 11)
          ; ("method", `String "initialize")
          ; ( "params",
              `Assoc
                [ ("protocolVersion", `String "2025-11-25")
                ; ("capabilities", `Assoc [])
                ; ( "clientInfo",
                    `Assoc [ ("name", `String "inspector"); ("version", `String "0.21.1") ] )
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          check string "protocol version supported" "2024-11-05"
            (json |> member "result" |> member "protocolVersion" |> to_string))

let test_tools_list_includes_register_list_send_and_whoami () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 2)
          ; ("method", `String "tools/list")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected tools/list response"
      | Some json ->
          let open Yojson.Safe.Util in
          let names =
            json |> member "result" |> member "tools" |> to_list
            |> List.map (fun item -> item |> member "name" |> to_string)
          in
          List.iter
            (fun expected -> check bool expected true (List.mem expected names))
            [ "register"; "list"; "send"; "whoami"; "poll_inbox" ])

let test_tools_list_marks_register_and_whoami_session_id_as_optional () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 21)
          ; ("method", `String "tools/list")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected tools/list response"
      | Some json ->
          let open Yojson.Safe.Util in
          let tools = json |> member "result" |> member "tools" |> to_list in
          let find_tool name =
            tools |> List.find (fun item -> item |> member "name" |> to_string = name)
          in
          let required_names item =
            item |> member "inputSchema" |> member "required" |> to_list
            |> List.map to_string
          in
          check (list string) "register required args" [ "alias" ]
            (required_names (find_tool "register"));
          check (list string) "whoami required args" []
            (required_names (find_tool "whoami")))

let test_tools_call_send_routes_message_through_broker () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None;
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None;
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 3)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "send")
                ; ( "arguments",
                    `Assoc
                      [ ("from_alias", `String "storm-ember")
                      ; ("to_alias", `String "storm-storm")
                      ; ("content", `String "hello from mcp")
                      ] )
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      (match response with None -> fail "expected tools/call response" | Some _ -> ());
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "one inbox message" 1 (List.length inbox);
       let msg = List.hd inbox in
       check string "mcp routed content" "hello from mcp" msg.content)

let test_tools_call_register_uses_current_session_id_when_omitted () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-live";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 4)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "storm-live") ])
                    ] )
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs = C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir) in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" "session-live" reg.session_id;
          check string "registered alias" "storm-live" reg.alias))

let test_tools_call_whoami_uses_current_session_id_when_omitted () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-live";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-live" ~alias:"storm-live" ~pid:None ~pid_start_time:None;
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 5)
              ; ("method", `String "tools/call")
              ; ("params", `Assoc [ ("name", `String "whoami"); ("arguments", `Assoc []) ])
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              check string "whoami alias" "storm-live"
                (json |> member "result" |> member "content" |> index 0 |> member "text" |> to_string)))

let test_tools_call_poll_inbox_drains_messages_as_tool_result () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-poll";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-from" ~alias:"storm-from" ~pid:None ~pid_start_time:None;
          C2c_mcp.Broker.register broker ~session_id:"session-poll" ~alias:"storm-poll" ~pid:None ~pid_start_time:None;
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-from" ~to_alias:"storm-poll" ~content:"hello-one";
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-from" ~to_alias:"storm-poll" ~content:"hello-two";
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 6)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "poll_inbox")
                    ; ("arguments", `Assoc [])
                    ] )
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              check bool "not an error" false
                (json |> member "result" |> member "isError" |> to_bool);
              let text =
                json |> member "result" |> member "content" |> index 0 |> member "text" |> to_string
              in
              let items = Yojson.Safe.from_string text |> to_list in
              check int "two messages returned" 2 (List.length items);
              let first = List.nth items 0 in
              check string "first from_alias" "storm-from" (first |> member "from_alias" |> to_string);
              check string "first to_alias" "storm-poll" (first |> member "to_alias" |> to_string);
              check string "first content" "hello-one" (first |> member "content" |> to_string);
              let second = List.nth items 1 in
              check string "second content" "hello-two" (second |> member "content" |> to_string);
              let remaining = C2c_mcp.Broker.read_inbox broker ~session_id:"session-poll" in
              check int "inbox drained to zero" 0 (List.length remaining)))

let test_tools_call_poll_inbox_empty_inbox_returns_empty_json_array () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-empty";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-empty" ~alias:"storm-empty" ~pid:None ~pid_start_time:None;
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 7)
              ; ("method", `String "tools/call")
              ; ("params", `Assoc [ ("name", `String "poll_inbox"); ("arguments", `Assoc []) ])
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0 |> member "text" |> to_string
              in
              check string "empty array text" "[]" text))

let dead_pid () =
  match Unix.fork () with
  | 0 -> exit 0
  | child ->
      let _ = Unix.waitpid [] child in
      let rec wait n =
        if n <= 0 then child
        else if not (Sys.file_exists ("/proc/" ^ string_of_int child)) then child
        else (
          ignore (Unix.select [] [] [] 0.005);
          wait (n - 1))
      in
      wait 20

let test_enqueue_to_dead_peer_raises () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker ~session_id:"session-dead" ~alias:"storm-dead" ~pid:(Some dead) ~pid_start_time:None;
      check_raises "dead recipient raises Invalid_argument"
        (Invalid_argument "recipient is not alive: storm-dead")
        (fun () ->
          C2c_mcp.Broker.enqueue_message broker
            ~from_alias:"storm-dead" ~to_alias:"storm-dead" ~content:"ping"))

let test_enqueue_picks_live_when_zombie_shares_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker ~session_id:"session-zombie" ~alias:"storm-twin" ~pid:(Some dead) ~pid_start_time:None;
      C2c_mcp.Broker.register broker ~session_id:"session-live" ~alias:"storm-twin" ~pid:(Some (Unix.getpid ())) ~pid_start_time:None;
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"storm-twin" ~to_alias:"storm-twin" ~content:"alive!";
      let zombie_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-zombie" in
      let live_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-live" in
      check int "zombie inbox untouched" 0 (List.length zombie_inbox);
      check int "live inbox got message" 1 (List.length live_inbox))

let test_registration_without_pid_loads_as_alive () =
  with_temp_dir (fun dir ->
      let registry_path = Filename.concat dir "registry.json" in
      let oc = open_out registry_path in
      output_string oc
        {|[{"session_id":"legacy-session","alias":"storm-legacy"}]|};
      close_out oc;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "one legacy registration" 1 (List.length regs);
      let reg = List.hd regs in
      check bool "pid field absent" true (reg.pid = None);
      check bool "legacy entry treated as alive" true
        (C2c_mcp.Broker.registration_is_alive reg);
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"storm-legacy" ~to_alias:"storm-legacy" ~content:"still works";
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"legacy-session" in
      check int "legacy enqueue delivered" 1 (List.length inbox))

let test_registration_persists_pid () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s" ~alias:"a" ~pid:(Some 42) ~pid_start_time:None;
      let reg =
        C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
        |> List.hd
      in
      check bool "pid persisted" true (reg.pid = Some 42))

let test_read_pid_start_time_for_self_is_some () =
  (* /proc/self/stat field 22 should be readable for the current process. *)
  let me = Unix.getpid () in
  check bool "start_time for self is Some" true
    (C2c_mcp.Broker.read_pid_start_time me <> None)

let test_registration_persists_pid_start_time () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s" ~alias:"a"
        ~pid:(Some 42) ~pid_start_time:(Some 9999);
      let reg =
        C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
        |> List.hd
      in
      check bool "start_time persisted" true (reg.pid_start_time = Some 9999))

let test_start_time_mismatch_is_not_alive () =
  (* Simulate pid reuse: use the current process's pid (definitely live) with
     a stored start_time that can't match the current one. *)
  let me = Unix.getpid () in
  let bogus_start_time =
    match C2c_mcp.Broker.read_pid_start_time me with
    | Some n -> n + 1
    | None -> 1
  in
  let reg =
    { C2c_mcp.session_id = "s"
    ; alias = "a"
    ; pid = Some me
    ; pid_start_time = Some bogus_start_time
    }
  in
  check bool "mismatched start_time → not alive" false
    (C2c_mcp.Broker.registration_is_alive reg)

let test_start_time_match_is_alive () =
  let me = Unix.getpid () in
  let start = C2c_mcp.Broker.read_pid_start_time me in
  let reg =
    { C2c_mcp.session_id = "s"
    ; alias = "a"
    ; pid = Some me
    ; pid_start_time = start
    }
  in
  check bool "matching start_time → alive" true
    (C2c_mcp.Broker.registration_is_alive reg)

let test_start_time_none_falls_back_to_proc_exists () =
  (* Legacy / no-start-time case still uses old /proc-exists-only semantics. *)
  let me = Unix.getpid () in
  let reg =
    { C2c_mcp.session_id = "s"
    ; alias = "a"
    ; pid = Some me
    ; pid_start_time = None
    }
  in
  check bool "pid exists + no stored start_time → alive" true
    (C2c_mcp.Broker.registration_is_alive reg)

let test_concurrent_register_does_not_lose_entries () =
  with_temp_dir (fun dir ->
      let n = 12 in
      (* Pre-touch the broker root so every child racer starts with the root
         created and doesn't trip over ensure_root races of its own. *)
      let _ = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register (C2c_mcp.Broker.create ~root:dir)
        ~session_id:"seed" ~alias:"seed-alias" ~pid:None ~pid_start_time:None;
      let children =
        List.init n (fun i ->
            match Unix.fork () with
            | 0 ->
                let broker = C2c_mcp.Broker.create ~root:dir in
                C2c_mcp.Broker.register broker
                  ~session_id:(Printf.sprintf "s-%d" i)
                  ~alias:(Printf.sprintf "a-%d" i)
                  ~pid:None ~pid_start_time:None;
                exit 0
            | child -> child)
      in
      let rec waitpid_eintr child =
        try ignore (Unix.waitpid [] child)
        with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr child
      in
      List.iter waitpid_eintr children;
      let regs =
        C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
      in
      (* seed + n children all survived the race. *)
      check int "all concurrent registrations survived" (n + 1) (List.length regs);
      for i = 0 to n - 1 do
        let alias = Printf.sprintf "a-%d" i in
        check bool ("alias " ^ alias ^ " present") true
          (List.exists (fun reg -> reg.C2c_mcp.alias = alias) regs)
      done)

let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let test_sweep_drops_dead_reg_and_its_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"storm-dead" ~pid:(Some dead) ~pid_start_time:None;
      (* Seed a fake inbox file for the dead reg. *)
      write_file (Filename.concat dir "session-dead.inbox.json") "[]";
      let result = C2c_mcp.Broker.sweep broker in
      check int "one dropped reg" 1 (List.length result.dropped_regs);
      check string "dropped alias" "storm-dead"
        (List.hd result.dropped_regs).alias;
      check int "one deleted inbox" 1 (List.length result.deleted_inboxes);
      check string "deleted inbox sid" "session-dead"
        (List.hd result.deleted_inboxes);
      check int "registry empty after sweep" 0
        (List.length (C2c_mcp.Broker.list_registrations broker));
      check bool "inbox file gone" false
        (Sys.file_exists (Filename.concat dir "session-dead.inbox.json")))

let test_sweep_deletes_orphan_inbox_file () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None;
      (* Orphan: no matching registration. *)
      write_file (Filename.concat dir "orphan-sid.inbox.json")
        {|[{"from_alias":"x","to_alias":"y","content":"hi"}]|};
      let result = C2c_mcp.Broker.sweep broker in
      check int "no dropped regs" 0 (List.length result.dropped_regs);
      check int "one orphan deleted" 1 (List.length result.deleted_inboxes);
      check string "orphan sid" "orphan-sid"
        (List.hd result.deleted_inboxes);
      check bool "orphan file gone" false
        (Sys.file_exists (Filename.concat dir "orphan-sid.inbox.json")))

let test_sweep_preserves_live_reg_and_its_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None;
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"storm-live" ~to_alias:"storm-live" ~content:"keep me";
      let result = C2c_mcp.Broker.sweep broker in
      check int "no drops" 0 (List.length result.dropped_regs);
      check int "no deletions" 0 (List.length result.deleted_inboxes);
      check int "live inbox intact" 1
        (List.length
           (C2c_mcp.Broker.read_inbox broker ~session_id:"session-live")))

let test_sweep_preserves_legacy_pidless_reg () =
  with_temp_dir (fun dir ->
      write_file (Filename.concat dir "registry.json")
        {|[{"session_id":"legacy-session","alias":"storm-legacy"}]|};
      write_file (Filename.concat dir "legacy-session.inbox.json") "[]";
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "legacy reg not dropped" 0 (List.length result.dropped_regs);
      check int "legacy inbox not deleted" 0
        (List.length result.deleted_inboxes);
      check int "legacy reg still present" 1
        (List.length (C2c_mcp.Broker.list_registrations broker));
      check bool "legacy inbox file still present" true
        (Sys.file_exists (Filename.concat dir "legacy-session.inbox.json")))

let () =
  run "c2c_mcp"
    [ ( "broker",
        [ test_case "register and list" `Quick test_register_and_list
        ; test_case "send enqueues target message" `Quick test_send_enqueues_message_for_target_alias
        ; test_case "drain inbox clears messages" `Quick test_drain_inbox_returns_and_clears_messages
        ; test_case "blank inbox file treated as empty" `Quick test_blank_inbox_file_is_treated_as_empty
        ; test_case "channel notification shape" `Quick test_channel_notification_matches_claude_channel_shape
        ; test_case "initialize returns capabilities" `Quick test_initialize_returns_mcp_capabilities
         ; test_case "initialize reports supported protocol version" `Quick
             test_initialize_reports_supported_protocol_version
         ; test_case "tools/list exposes core tools" `Quick test_tools_list_includes_register_list_send_and_whoami
         ; test_case "tools/list makes current-session args optional" `Quick
             test_tools_list_marks_register_and_whoami_session_id_as_optional
         ; test_case "tools/call send routes through broker" `Quick test_tools_call_send_routes_message_through_broker
         ; test_case "tools/call register uses current session id when omitted" `Quick
             test_tools_call_register_uses_current_session_id_when_omitted
         ; test_case "tools/call whoami uses current session id when omitted" `Quick
             test_tools_call_whoami_uses_current_session_id_when_omitted
         ; test_case "tools/call poll_inbox drains messages as tool result" `Quick
             test_tools_call_poll_inbox_drains_messages_as_tool_result
         ; test_case "tools/call poll_inbox empty inbox returns empty json array" `Quick
             test_tools_call_poll_inbox_empty_inbox_returns_empty_json_array
         ; test_case "enqueue to dead peer raises" `Quick test_enqueue_to_dead_peer_raises
         ; test_case "enqueue picks live when zombie shares alias" `Quick
             test_enqueue_picks_live_when_zombie_shares_alias
         ; test_case "registration without pid field is treated as alive" `Quick
             test_registration_without_pid_loads_as_alive
         ; test_case "registration persists pid" `Quick test_registration_persists_pid
         ; test_case "concurrent register does not lose entries" `Quick
             test_concurrent_register_does_not_lose_entries
         ; test_case "sweep drops dead reg and its inbox" `Quick
             test_sweep_drops_dead_reg_and_its_inbox
         ; test_case "sweep deletes orphan inbox file" `Quick
             test_sweep_deletes_orphan_inbox_file
         ; test_case "sweep preserves live reg and its inbox" `Quick
             test_sweep_preserves_live_reg_and_its_inbox
         ; test_case "sweep preserves legacy pidless reg" `Quick
             test_sweep_preserves_legacy_pidless_reg
         ; test_case "read_pid_start_time self is Some" `Quick
             test_read_pid_start_time_for_self_is_some
         ; test_case "registration persists pid_start_time" `Quick
             test_registration_persists_pid_start_time
         ; test_case "start_time mismatch is not alive" `Quick
             test_start_time_mismatch_is_not_alive
         ; test_case "start_time match is alive" `Quick
             test_start_time_match_is_alive
         ; test_case "start_time none falls back to /proc exists" `Quick
             test_start_time_none_falls_back_to_proc_exists
         ] ) ]
