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
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember";
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "one registration" 1 (List.length regs);
      let reg = List.hd regs in
      check string "alias" "storm-ember" reg.alias;
      check string "session" "session-a" reg.session_id)

let test_send_enqueues_message_for_target_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember";
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm";
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-ember" ~to_alias:"storm-storm" ~content:"hello";
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "one inbox message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "from alias" "storm-ember" msg.from_alias;
      check string "content" "hello" msg.content)

let test_drain_inbox_returns_and_clears_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember";
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm";
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
            [ "register"; "list"; "send"; "whoami" ])

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
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember";
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm";
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
          C2c_mcp.Broker.register broker ~session_id:"session-live" ~alias:"storm-live";
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

let () =
  run "c2c_mcp"
    [ ( "broker",
        [ test_case "register and list" `Quick test_register_and_list
        ; test_case "send enqueues target message" `Quick test_send_enqueues_message_for_target_alias
        ; test_case "drain inbox clears messages" `Quick test_drain_inbox_returns_and_clears_messages
        ; test_case "blank inbox file treated as empty" `Quick test_blank_inbox_file_is_treated_as_empty
        ; test_case "channel notification shape" `Quick test_channel_notification_matches_claude_channel_shape
        ; test_case "initialize returns capabilities" `Quick test_initialize_returns_mcp_capabilities
         ; test_case "initialize echoes requested protocol version" `Quick
             test_initialize_echoes_requested_protocol_version
         ; test_case "tools/list exposes core tools" `Quick test_tools_list_includes_register_list_send_and_whoami
         ; test_case "tools/list makes current-session args optional" `Quick
             test_tools_list_marks_register_and_whoami_session_id_as_optional
         ; test_case "tools/call send routes through broker" `Quick test_tools_call_send_routes_message_through_broker
         ; test_case "tools/call register uses current session id when omitted" `Quick
             test_tools_call_register_uses_current_session_id_when_omitted
         ; test_case "tools/call whoami uses current session id when omitted" `Quick
             test_tools_call_whoami_uses_current_session_id_when_omitted
         ] ) ]
