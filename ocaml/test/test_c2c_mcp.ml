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

let test_channel_notification_matches_claude_channel_shape () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "debate me" }
  in
  let open Yojson.Safe.Util in
  check string "method" "notifications/claude/channel" (json |> member "method" |> to_string);
  check string "content" "debate me" (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from_alias" |> to_string)

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
          ignore
            (json |> member "result" |> member "capabilities" |> member "experimental" |> member "claude/channel"))

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

let () =
  run "c2c_mcp"
    [ ( "broker",
        [ test_case "register and list" `Quick test_register_and_list
        ; test_case "send enqueues target message" `Quick test_send_enqueues_message_for_target_alias
        ; test_case "drain inbox clears messages" `Quick test_drain_inbox_returns_and_clears_messages
        ; test_case "channel notification shape" `Quick test_channel_notification_matches_claude_channel_shape
        ; test_case "initialize returns capabilities" `Quick test_initialize_returns_mcp_capabilities
        ; test_case "tools/list exposes core tools" `Quick test_tools_list_includes_register_list_send_and_whoami
        ; test_case "tools/call send routes through broker" `Quick test_tools_call_send_routes_message_through_broker
        ] ) ]
