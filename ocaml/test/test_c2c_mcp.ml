open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-mcp-%06x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then true
    else if i + needle_len > haystack_len then false
    else if String.sub haystack i needle_len = needle then true
    else loop (i + 1)
  in
  loop 0

let is_json_object = function `Assoc _ -> true | _ -> false

let test_register_and_list () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "one registration" 1 (List.length regs);
      let reg = List.hd regs in
      check string "alias" "storm-ember" reg.alias;
      check string "session" "session-a" reg.session_id)

let test_send_enqueues_message_for_target_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-ember" ~to_alias:"storm-storm" ~content:"hello" ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "one inbox message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "from alias" "storm-ember" msg.from_alias;
      check string "content" "hello" msg.content)

let test_drain_inbox_returns_and_clears_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-ember" ~to_alias:"storm-storm" ~content:"hello" ();
       let drained = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b" in
       check int "drained one message" 1 (List.length drained);
       check int "inbox now empty" 0 (List.length (C2c_mcp.Broker.read_inbox broker ~session_id:"session-b")))

let test_drain_inbox_empty_does_not_touch_inbox_file () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let path = Filename.concat dir "session-empty.inbox.json" in
      (* Sanity: file does not exist yet. *)
      check bool "inbox file absent before drain" false (Sys.file_exists path);
      let drained =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-empty"
      in
      check int "empty drain returns no messages" 0 (List.length drained);
      (* Optimization: drain of an empty inbox must NOT create the
         file, because every such write fires a close_write inotify
         event and swamps agent-visibility monitors. *)
      check bool "inbox file still absent after empty drain" false
        (Sys.file_exists path))

let test_drain_inbox_empty_does_not_rewrite_existing_empty_file () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let path = Filename.concat dir "session-idle.inbox.json" in
      (* Enqueue then drain so the file exists and is already `[]`. *)
      C2c_mcp.Broker.register broker ~session_id:"session-sender"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-idle" ~alias:"idle"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
        ~to_alias:"idle" ~content:"one" ();
      let _ = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-idle" in
      check bool "inbox file exists after first drain" true
        (Sys.file_exists path);
      let before = (Unix.stat path).st_mtime in
      (* Force a second of wall time so mtime granularity captures any
         rewrite. 1s is coarse but the Linux ext4 default is 1s. *)
      Unix.sleep 1;
      let drained2 =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-idle"
      in
      check int "second drain returns 0" 0 (List.length drained2);
      let after = (Unix.stat path).st_mtime in
      check bool "mtime unchanged on no-op drain" true (before = after))

let test_blank_inbox_file_is_treated_as_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let path = Filename.concat dir "session-z.inbox.json" in
      let oc = open_out path in
      close_out oc;
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-z" in
      check int "blank inbox treated as empty" 0 (List.length inbox))

let test_read_inbox_is_non_destructive () =
  (* Regression test: gui --batch uses Broker.read_inbox (non-destructive)
     instead of Broker.drain_inbox. Verify read_inbox leaves messages intact. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-alice"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-bob"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"ping-one" ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"ping-two" ();
      (* First read — should return both messages *)
      let first = C2c_mcp.Broker.read_inbox broker ~session_id:"session-bob" in
      check int "first read returns 2 messages" 2 (List.length first);
      (* Second read immediately — messages must still be there (non-destructive) *)
      let second = C2c_mcp.Broker.read_inbox broker ~session_id:"session-bob" in
      check int "second read still returns 2 messages" 2 (List.length second);
      (* Verify content preserved *)
      check string "first message content" "ping-one"
        (List.hd first).content;
      check string "second message content" "ping-two"
        (List.nth first 1).content)

(* ---------- inbox archive (v0.6.2) ---------- *)

let test_drain_inbox_archives_messages_before_clearing () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-alice"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-bob"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"first ping" ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"second ping" ();
      let drained =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-bob"
      in
      check int "drained both" 2 (List.length drained);
      (* Archive file exists and is non-empty. *)
      let archive_file = C2c_mcp.Broker.archive_path broker ~session_id:"session-bob" in
      check bool "archive file exists after drain" true (Sys.file_exists archive_file);
      (* Read back: newest-first, both messages present, content matches. *)
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"session-bob" ~limit:100
      in
      check int "archive has both entries" 2 (List.length entries);
      (match entries with
       | [ newest; oldest ] ->
           check string "newest content" "second ping" newest.C2c_mcp.Broker.ae_content;
           check string "oldest content" "first ping" oldest.C2c_mcp.Broker.ae_content;
           check string "newest from_alias" "alice" newest.C2c_mcp.Broker.ae_from_alias;
           check string "newest to_alias" "bob" newest.C2c_mcp.Broker.ae_to_alias;
           check bool "drained_at is positive" true (newest.C2c_mcp.Broker.ae_drained_at > 0.0)
       | _ -> fail "expected exactly 2 archive entries"))

let test_drain_inbox_empty_does_not_create_archive () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _drained =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-silent"
      in
      let archive_file =
        C2c_mcp.Broker.archive_path broker ~session_id:"session-silent"
      in
      check bool "empty drain does not create archive file" false
        (Sys.file_exists archive_file))

let test_drain_inbox_push_suppresses_deferrable () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"receiver" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
        ~to_alias:"receiver" ~content:"urgent" ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
        ~to_alias:"receiver" ~content:"deferred" ~deferrable:true ();
      let pushed = C2c_mcp.Broker.drain_inbox_push broker ~session_id:"session-b" in
      check int "push returns only non-deferrable" 1 (List.length pushed);
      check string "pushed message is urgent" "urgent"
        (List.hd pushed).content;
      let remaining = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "deferrable remains in inbox" 1 (List.length remaining);
      check string "remaining is deferred" "deferred"
        (List.hd remaining).content;
      let all = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b" in
      check int "drain returns only deferred (urgent was pushed)" 1 (List.length all))

let test_read_archive_missing_session_returns_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"never-existed" ~limit:10
      in
      check int "no archive => empty list" 0 (List.length entries))

let test_read_archive_respects_limit () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-sender"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-recv"
        ~alias:"recv" ~pid:None ~pid_start_time:None ();
      for i = 1 to 5 do
        C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
          ~to_alias:"recv" ~content:(Printf.sprintf "msg-%d" i) ()
      done;
      let _ = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-recv" in
      (* Ask for the last 2 — should be msg-5 and msg-4 (newest first). *)
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"session-recv" ~limit:2
      in
      check int "limit=2 returns 2" 2 (List.length entries);
      (match entries with
       | [ newest; second ] ->
           check string "newest is msg-5" "msg-5" newest.C2c_mcp.Broker.ae_content;
           check string "second-newest is msg-4" "msg-4" second.C2c_mcp.Broker.ae_content
       | _ -> fail "expected exactly 2 entries"))

let test_tools_call_history_returns_archived_messages () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-histcaller";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-sender"
            ~alias:"sender" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-histcaller"
            ~alias:"histcaller" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"histcaller" ~content:"archived-one" ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"histcaller" ~content:"archived-two" ();
          let _ =
            C2c_mcp.Broker.drain_inbox broker ~session_id:"session-histcaller"
          in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 100)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "history")
                    ; ("arguments", `Assoc []) ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call history response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let arr = Yojson.Safe.from_string text |> to_list in
              check int "history returns 2 entries" 2 (List.length arr);
              let newest = List.nth arr 0 in
              check string "newest content via tool" "archived-two"
                (newest |> member "content" |> to_string)))

let test_tools_call_history_ignores_session_id_argument () =
  (* Subagent-style probe: caller tries to pass session_id="victim" to
     read another session's archive. The history tool must ignore the
     argument and only read the env session_id's archive. *)
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-attacker";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-sender"
            ~alias:"sender" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-victim"
            ~alias:"victim" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-attacker"
            ~alias:"attacker" ~pid:None ~pid_start_time:None ();
          (* Seed victim's archive. *)
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"victim" ~content:"secret-to-victim" ();
          let _ =
            C2c_mcp.Broker.drain_inbox broker ~session_id:"session-victim"
          in
          (* Attacker calls history with session_id="session-victim". *)
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 101)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "history")
                    ; ( "arguments",
                        `Assoc
                          [ ("session_id", `String "session-victim")
                          ] ) ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call history response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let arr = Yojson.Safe.from_string text |> to_list in
              (* Attacker's own archive is empty, so should return []. *)
              check int "attacker sees only their own archive (empty)"
                0 (List.length arr);
              check bool "tool is not an error" false
                (json |> member "result" |> member "isError" |> to_bool)))

let test_channel_notification_matches_claude_channel_shape () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "debate me"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  check string "jsonrpc" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel" (json |> member "method" |> to_string);
  check string "content" "debate me" (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from_alias" |> to_string);
  check string "to alias meta" "storm-storm"
    (json |> member "params" |> member "meta" |> member "to_alias" |> to_string)

let test_channel_notification_empty_content () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = ""; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  check string "jsonrpc" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel"
    (json |> member "method" |> to_string);
  check string "content is empty string" ""
    (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from_alias" |> to_string);
  check string "to alias meta" "storm-storm"
    (json |> member "params" |> member "meta" |> member "to_alias" |> to_string)

let test_channel_notification_special_chars () =
  let content = "line1\nline2\t\"quoted\" <angle> \xc3\xa9\xc3\xa0\xc3\xbc" in
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  (* Round-trip through Yojson serialization to verify escaping is valid *)
  let serialized = Yojson.Safe.to_string json in
  let reparsed = Yojson.Safe.from_string serialized in
  check string "content survives round-trip" content
    (reparsed |> member "params" |> member "content" |> to_string);
  check string "jsonrpc" "2.0" (reparsed |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel"
    (reparsed |> member "method" |> to_string)

let test_channel_notification_has_no_id_field () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "test"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  (* JSON-RPC 2.0 notifications MUST NOT include an "id" field *)
  check bool "no id field" true (member "id" json = `Null)

let test_initialize_with_channel_capable_client () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 50)
          ; ("method", `String "initialize")
          ; ( "params",
              `Assoc
                [ ( "capabilities",
                    `Assoc
                      [ ( "experimental",
                          `Assoc [ ("claude/channel", `Bool true) ] ) ] )
                ; ( "clientInfo",
                    `Assoc
                      [ ("name", `String "test-client")
                      ; ("version", `String "1.0.0")
                      ] )
                ] )
          ]
      in
      let response =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
      in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          check string "protocol version" "2024-11-05"
            (json |> member "result" |> member "protocolVersion" |> to_string);
          check bool "server declares claude/channel capability" true
            (json |> member "result" |> member "capabilities"
             |> member "experimental" |> member "claude/channel" |> is_json_object))

let test_initialize_without_channel_capability () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 51)
          ; ("method", `String "initialize")
          ; ( "params",
              `Assoc
                [ ( "clientInfo",
                    `Assoc
                      [ ("name", `String "basic-client")
                      ; ("version", `String "0.1.0")
                      ] )
                ] )
          ]
      in
      let response =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
      in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          check string "protocol version" "2024-11-05"
            (json |> member "result" |> member "protocolVersion" |> to_string);
          (* Server always declares its own channel capability regardless
             of whether the client advertised support *)
          check bool "server declares claude/channel capability" true
            (json |> member "result" |> member "capabilities"
             |> member "experimental" |> member "claude/channel" |> is_json_object))

let test_channel_notification_method_is_correct () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "check method"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  let method_str = json |> member "method" |> to_string in
  check string "exact method string" "notifications/claude/channel" method_str;
  (* Guard against common typos *)
  check bool "not singular notification" true (method_str <> "notification/claude/channel");
  check bool "not channel/ prefix" true
    (not (String.length method_str >= 8 && String.sub method_str 0 8 = "channel/"))

let test_channel_notification_with_role () =
  let json =
    C2c_mcp.channel_notification ~role:(Some "coordinator")
      { from_alias = "cairn-vigil"; to_alias = "stanza-coder"; content = "hi"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  let meta = json |> member "params" |> member "meta" in
  check string "role in meta" "coordinator" (meta |> member "role" |> to_string);
  check string "from_alias preserved" "cairn-vigil" (meta |> member "from_alias" |> to_string)

let test_channel_notification_without_role_omits () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "hi"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false }
  in
  let open Yojson.Safe.Util in
  let meta = json |> member "params" |> member "meta" in
  (* role attribute must be absent (not null, not empty string) when not set *)
  check bool "no role field when None" true (member "role" meta = `Null)

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
          (* Server declares experimental.claude/channel capability with an
             object value, matching MCP experimental capability schemas. *)
          check bool "server declares claude/channel capability"
            true
            (json |> member "result" |> member "capabilities"
             |> member "experimental" |> member "claude/channel" |> is_json_object))

let test_initialize_experimental_capability_values_are_objects () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 13)
          ; ("method", `String "initialize")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          let channel =
            json |> member "result" |> member "capabilities"
            |> member "experimental" |> member "claude/channel"
          in
          check bool "claude/channel capability is an object" true
            (is_json_object channel))

let test_initialize_reports_server_version_and_features () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 12)
          ; ("method", `String "initialize")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          let server_info = json |> member "result" |> member "serverInfo" in
          check string "server name" "c2c" (server_info |> member "name" |> to_string);
          let version = server_info |> member "version" |> to_string in
          check bool "version is not legacy 0.1.0" true (version <> "0.1.0");
          let features =
            server_info |> member "features" |> to_list |> List.map to_string
          in
          check bool "features is non-empty" true (features <> []);
          (* Includes the slice 1 load-bearing flags plus the slice 7
             behavioral contracts. A future refactor that drops any of
             these names from server_features must either keep the flag
             or update this list — silent removal is what we're
             guarding against, since clients probe these names. *)
          let required =
            [ "liveness"
            ; "sweep"
            ; "dead_letter"
            ; "dead_letter_redelivery"
            ; "poll_inbox"
            ; "send_all"
            ; "inbox_migration_on_register"
            ; "registry_locked_enqueue"
            ; "startup_auto_register"
            ; "send_room_alias_fallback"
            ; "join_leave_from_alias_fallback"
            ; "inbox_archive_on_drain"
            ; "history_tool"
            ; "join_room_history_backfill"
            ; "my_rooms_tool"
            ; "peek_inbox_tool"
            ; "rpc_audit_log"
            ; "tail_log_tool"
            ; "register_alias_hijack_guard"
            ; "missing_sender_alias_errors"
            ]
          in
          List.iter
            (fun f ->
              check bool (Printf.sprintf "features contains %s" f) true
                (List.mem f features))
            required)

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

let test_tools_list_includes_debug_when_build_flag_enabled () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 2002)
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
          check bool "debug tool matches build flag"
            Build_flags.mcp_debug_tool_enabled
            (List.mem "debug" names))

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
          let property_names item =
            item |> member "inputSchema" |> member "properties" |> to_assoc
            |> List.map fst
          in
          check (list string) "register required args" []
            (required_names (find_tool "register"));
          check (list string) "whoami required args" []
            (required_names (find_tool "whoami"));
          check bool "register advertises optional session_id" true
            (List.mem "session_id" (property_names (find_tool "register")));
          check bool "whoami advertises optional session_id" true
            (List.mem "session_id" (property_names (find_tool "whoami")));
          check bool "send advertises to_alias" true
            (List.mem "to_alias" (property_names (find_tool "send")));
          check bool "send advertises content" true
            (List.mem "content" (property_names (find_tool "send"))))

let test_tools_call_send_routes_message_through_broker () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
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

let test_tools_call_send_accepts_alias_as_to_alias_synonym () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b" ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 301)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "send")
                ; ( "arguments",
                    `Assoc
                      [ ("from_alias", `String "storm-ember")
                      ; ("alias", `String "storm-storm")
                      ; ("content", `String "via alias synonym")
                      ] )
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      (match response with None -> fail "expected tools/call response" | Some _ -> ());
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "one inbox message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "routed via alias synonym" "via alias synonym" msg.content)

let test_tools_call_send_missing_to_alias_returns_named_error () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a" ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 302)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "send")
                ; ( "arguments",
                    `Assoc
                      [ ("from_alias", `String "storm-ember")
                      ; ("content", `String "no recipient supplied")
                      ] )
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected tools/call response"
      | Some json ->
          let open Yojson.Safe.Util in
          let result = json |> member "result" in
          let is_error = try result |> member "isError" |> to_bool with _ -> false in
          check bool "send signals isError" true is_error;
          let text = result |> member "content" |> index 0 |> member "text" |> to_string in
          check bool "error names the missing field"
            true
            (let needle_a = "to_alias" in
             let needle_b = "alias" in
             let contains s sub =
               let n = String.length s and k = String.length sub in
               let rec loop i =
                 if i + k > n then false
                 else if String.sub s i k = sub then true
                 else loop (i + 1)
               in
               loop 0
             in
             contains text needle_a || contains text needle_b);
          check bool "error does not leak raw Yojson Type_error"
            false
            (let contains s sub =
               let n = String.length s and k = String.length sub in
               let rec loop i =
                 if i + k > n then false
                 else if String.sub s i k = sub then true
                 else loop (i + 1)
               in
               loop 0
             in
             contains text "Yojson__Safe.Util.Type_error"))

let test_tools_call_send_uses_current_registered_alias () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-a"
            ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-b"
            ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 31)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "codex")
                          ; ("to_alias", `String "storm-storm")
                          ; ("content", `String "identity should be bound")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let receipt = Yojson.Safe.from_string text in
               check string "receipt reports bound sender" "storm-ember"
                 (receipt |> member "from_alias" |> to_string));
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
          in
          check int "one inbox message" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "argument spoof ignored" "storm-ember" msg.from_alias;
          check string "content delivered" "identity should be bound"
            msg.content))

let test_tools_call_send_uses_current_alias_even_if_pid_stale () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-a"
            ~alias:"storm-ember" ~pid:(Some 999_999_999)
            ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-b"
            ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 32)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "codex")
                          ; ("to_alias", `String "storm-storm")
                          ; ("content", `String "stale pid should not unbind")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tools/call response"
           | Some _ -> ());
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
          in
          check int "one inbox message" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "stale self pid still binds by session_id"
            "storm-ember" msg.from_alias))

let test_tools_call_send_returns_receipt_json () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-x" ~alias:"sender-x" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-y" ~alias:"receiver-y" ~pid:None ~pid_start_time:None ();
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 99)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "send")
                ; ( "arguments",
                    `Assoc
                      [ ("from_alias", `String "sender-x")
                      ; ("to_alias", `String "receiver-y")
                      ; ("content", `String "receipt test payload")
                      ] )
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected send response"
      | Some json ->
          let open Yojson.Safe.Util in
          let text =
            json |> member "result" |> member "content" |> index 0
            |> member "text" |> to_string
          in
          let receipt = Yojson.Safe.from_string text in
          check bool "queued is true" true (receipt |> member "queued" |> to_bool);
          check string "to_alias in receipt" "receiver-y"
            (receipt |> member "to_alias" |> to_string);
          let ts = receipt |> member "ts" |> to_float in
          check bool "ts is positive" true (ts > 0.0))

let test_tools_call_debug_send_msg_to_self_enqueues_payload () =
  with_temp_dir (fun dir ->
      if not Build_flags.mcp_debug_tool_enabled then ()
      else
        let broker = C2c_mcp.Broker.create ~root:dir in
        C2c_mcp.Broker.register broker ~session_id:"session-debug"
          ~alias:"storm-debug" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-debug";
        Fun.protect
          ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
          (fun () ->
            let request =
              `Assoc
                [ ("jsonrpc", `String "2.0")
                ; ("id", `Int 3200)
                ; ("method", `String "tools/call")
                ; ( "params",
                    `Assoc
                      [ ("name", `String "debug")
                      ; ( "arguments",
                          `Assoc
                            [ ("action", `String "send_msg_to_self")
                            ; ("payload", `Assoc [ ("probe", `String "codex-delivery") ])
                            ] )
                      ] )
                ]
            in
            let response =
              Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
            in
            (match response with None -> fail "expected debug response" | Some _ -> ());
            let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-debug" in
            check int "one inbox message" 1 (List.length inbox);
            let msg = List.hd inbox in
            check string "from alias" "storm-debug" msg.from_alias;
            check string "to alias" "storm-debug" msg.to_alias;
            let payload =
              match Yojson.Safe.from_string msg.content with
              | `Assoc fields -> fields
              | _ -> fail "expected debug payload json"
            in
            let find_string key =
              match List.assoc_opt key payload with
              | Some (`String value) -> value
              | _ -> fail ("missing string field: " ^ key)
            in
            check string "kind" "c2c_debug" (find_string "kind");
            check string "action" "send_msg_to_self" (find_string "action");
            check string "alias" "storm-debug" (find_string "alias")))

let test_tools_call_debug_send_raw_to_self_enqueues_verbatim () =
  with_temp_dir (fun dir ->
      if not Build_flags.mcp_debug_tool_enabled then ()
      else
        let broker = C2c_mcp.Broker.create ~root:dir in
        C2c_mcp.Broker.register broker ~session_id:"session-raw"
          ~alias:"storm-raw" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-raw";
        Fun.protect
          ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
          (fun () ->
            let raw_payload = "/compact" in
            let request =
              `Assoc
                [ ("jsonrpc", `String "2.0")
                ; ("id", `Int 3201)
                ; ("method", `String "tools/call")
                ; ( "params",
                    `Assoc
                      [ ("name", `String "debug")
                      ; ( "arguments",
                          `Assoc
                            [ ("action", `String "send_raw_to_self")
                            ; ("payload", `String raw_payload)
                            ] )
                      ] )
                ]
            in
            let response =
              Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
            in
            (match response with None -> fail "expected debug response" | Some _ -> ());
            let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-raw" in
            check int "one inbox message" 1 (List.length inbox);
            let msg = List.hd inbox in
            check string "from alias" "storm-raw" msg.from_alias;
            check string "to alias" "storm-raw" msg.to_alias;
            (* The body is the payload verbatim — NOT wrapped in a JSON
               c2c_debug envelope. This is the load-bearing assertion: the
               content arrives unmodified through the channel-notification
               path (which never adds the <c2c event="message"> envelope). *)
            check string "content is verbatim payload" raw_payload msg.content))

let test_tools_call_debug_send_raw_to_self_rejects_non_string_payload () =
  with_temp_dir (fun dir ->
      if not Build_flags.mcp_debug_tool_enabled then ()
      else
        let broker = C2c_mcp.Broker.create ~root:dir in
        C2c_mcp.Broker.register broker ~session_id:"session-raw-bad"
          ~alias:"storm-raw-bad" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-raw-bad";
        Fun.protect
          ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
          (fun () ->
            let request =
              `Assoc
                [ ("jsonrpc", `String "2.0")
                ; ("id", `Int 3202)
                ; ("method", `String "tools/call")
                ; ( "params",
                    `Assoc
                      [ ("name", `String "debug")
                      ; ( "arguments",
                          `Assoc
                            [ ("action", `String "send_raw_to_self")
                            (* object payload is invalid for raw — must be string *)
                            ; ("payload", `Assoc [ ("oops", `String "object") ])
                            ] )
                      ] )
                ]
            in
            let response =
              Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
            in
            (* Either the response carries an error envelope, or
               send_raw_to_self raised — both are acceptable; the load-bearing
               part is that the inbox stays empty. *)
            ignore response;
            let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-raw-bad" in
            check int "no inbox message on bad payload" 0 (List.length inbox)))

let test_tools_call_debug_get_env () =
  with_temp_dir (fun dir ->
      if not Build_flags.mcp_debug_tool_enabled then ()
      else
        let broker = C2c_mcp.Broker.create ~root:dir in
        C2c_mcp.Broker.register broker ~session_id:"session-env"
          ~alias:"env-test" ~pid:None ~pid_start_time:None ();
        Unix.putenv "C2C_MCP_SESSION_ID" "session-env";
        Unix.putenv "C2C_TEST_VAR_ONE" "value1";
        Unix.putenv "C2C_TEST_VAR_TWO" "value2";
        Unix.putenv "OTHER_VAR" "should_be_ignored";
        Fun.protect
          ~finally:(fun () ->
            Unix.putenv "C2C_MCP_SESSION_ID" "";
            Unix.putenv "C2C_TEST_VAR_ONE" "";
            Unix.putenv "C2C_TEST_VAR_TWO" "";
            Unix.putenv "OTHER_VAR" "")
          (fun () ->
            let request =
              `Assoc
                [ ("jsonrpc", `String "2.0")
                ; ("id", `Int 3201)
                ; ("method", `String "tools/call")
                ; ( "params",
                    `Assoc
                      [ ("name", `String "debug")
                      ; ( "arguments",
                          `Assoc [ ("action", `String "get_env") ] )
                      ] )
                ]
            in
            let response =
              Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
            in
            match response with
            | None -> fail "expected debug get_env response"
            | Some (`Assoc resp_fields) ->
                let result_fields =
                  match List.assoc_opt "result" resp_fields with
                  | Some (`Assoc f) -> f
                  | _ -> fail "expected result object in response"
                in
                let content_text =
                  match List.assoc_opt "content" result_fields with
                  | Some (`List [`Assoc cf]) ->
                      (match List.assoc_opt "text" cf with
                       | Some (`String t) -> t
                       | _ -> fail "expected text field in content object")
                  | _ -> fail "expected [content] structure in result"
                in
                let inner_json = Yojson.Safe.from_string content_text in
                let inner_fields = match inner_json with `Assoc fields -> fields | _ -> fail "expected object in text" in
                let find_string key =
                  match List.assoc_opt key inner_fields with
                  | Some (`String v) -> v
                  | _ -> fail ("missing string field: " ^ key)
                in
                let find_int key =
                  match List.assoc_opt key inner_fields with
                  | Some (`Int v) -> v
                  | _ -> fail ("missing int field: " ^ key)
                in
                check string "action" "get_env" (find_string "action");
                check string "prefix" "C2C_" (find_string "prefix");
                let count = find_int "count" in
                check bool "count >= 2" true (count >= 2);
                check string "C2C_TEST_VAR_ONE" "value1" (find_string "C2C_TEST_VAR_ONE");
                check string "C2C_TEST_VAR_TWO" "value2" (find_string "C2C_TEST_VAR_TWO")
            | Some _ -> fail "expected object response"))

(* MCP ping must return empty result, not -32601. Claude Code sends periodic
   pings; an error response triggers "server unhealthy" and a 3-5min disconnect
   cycle. Regression test for e107929. *)
let test_mcp_ping_returns_empty_result () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1)
          ; ("method", `String "ping")
          ; ("params", `Assoc [])
          ]
      in
      let response =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
      in
      match response with
      | None -> fail "expected response to ping"
      | Some json ->
          let open Yojson.Safe.Util in
          let result = json |> member "result" in
          check bool "ping result is object (not error)" true
            (result <> `Null);
          (* result must be empty {}, not an error *)
          check bool "no error field in ping response" true
            (json |> member "error" = `Null);
          check bool "ping result is empty object" true
            (result = `Assoc []))

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

let test_session_id_from_env_falls_back_to_codex_thread_id () =
  Unix.putenv "C2C_MCP_SESSION_ID" "";
  Unix.putenv "CODEX_THREAD_ID" "";
  Unix.putenv "CODEX_THREAD_ID" "codex-thread-123";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "")
    (fun () ->
      check (option string) "session id from env" (Some "codex-thread-123")
        (C2c_mcp.session_id_from_env ()))

let test_session_id_from_env_accepts_managed_codex_thread_id () =
  Unix.putenv "C2C_MCP_SESSION_ID" "";
  Unix.putenv "CODEX_THREAD_ID" "codex-managed-123";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "")
    (fun () ->
      check (option string) "session id from env" (Some "codex-managed-123")
        (C2c_mcp.session_id_from_env ()))

let test_session_id_from_env_uses_client_specific_claude_fallback () =
  Unix.putenv "C2C_MCP_SESSION_ID" "";
  Unix.putenv "CLAUDE_SESSION_ID" "claude-session-123";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CLAUDE_SESSION_ID" "")
    (fun () ->
      check (option string) "session id from env" (Some "claude-session-123")
        (C2c_mcp.session_id_from_env ~client_type:"claude" ()))

let test_session_id_from_env_uses_client_specific_opencode_fallback () =
  Unix.putenv "C2C_MCP_SESSION_ID" "";
  Unix.putenv "C2C_OPENCODE_SESSION_ID" "ses-opencode-123";
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "C2C_OPENCODE_SESSION_ID" "")
    (fun () ->
      check (option string) "session id from env" (Some "ses-opencode-123")
        (C2c_mcp.session_id_from_env ~client_type:"opencode" ()))

let test_tools_call_register_uses_codex_thread_id_when_c2c_session_id_missing ()
    =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
      Unix.putenv "CODEX_THREAD_ID" "codex-thread-123";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 42)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "storm-codex") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs =
            C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
          in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" "codex-thread-123" reg.session_id;
          check string "registered alias" "storm-codex" reg.alias))

let test_tools_call_register_uses_managed_codex_thread_id_when_c2c_session_id_missing ()
    =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
      Unix.putenv "CODEX_THREAD_ID" "codex-managed-123";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 43)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "storm-managed") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs =
            C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
          in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" "codex-managed-123" reg.session_id;
          check string "registered alias" "storm-managed" reg.alias))

let test_tools_call_whoami_uses_codex_turn_metadata_to_find_managed_session ()
    =
  with_temp_dir (fun dir ->
      let instances_dir = Filename.concat dir "instances" in
      let instance_dir = Filename.concat instances_dir "lyra-quill-x" in
      let config_path = Filename.concat instance_dir "config.json" in
      let codex_thread_id = "019dafa6-caef-7e50-bfad-323af643e3ce" in
      let broker = C2c_mcp.Broker.create ~root:dir in
      let managed_session_id = "Lyra-Quill-X" in
      let alias = "lyra-quill" in
      let config_json =
        `Assoc
          [ ("name", `String managed_session_id)
          ; ("client", `String "codex")
          ; ("session_id", `String managed_session_id)
          ; ("resume_session_id", `String codex_thread_id)
          ; ("codex_resume_target", `String codex_thread_id)
          ; ("alias", `String alias)
          ; ("extra_args", `List [])
          ; ("created_at", `Float 0.)
          ; ("broker_root", `String dir)
          ; ("auto_join_rooms", `String "swarm-lounge")
          ]
      in
      let mkdir path =
        try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      in
      mkdir instances_dir;
      mkdir instance_dir;
      let oc = open_out config_path in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () ->
          Yojson.Safe.pretty_to_channel oc config_json;
          output_char oc '\n');
      C2c_mcp.Broker.register broker ~session_id:managed_session_id
        ~alias ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
      Unix.putenv "C2C_INSTANCES_DIR" instances_dir;
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_INSTANCES_DIR" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 44)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "whoami")
                    ; ("arguments", `Assoc [])
                    ; ( "_meta",
                        `Assoc
                          [ ( "x-codex-turn-metadata",
                              `Assoc [ ("session_id", `String codex_thread_id) ] )
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let resolved_alias =
                match Yojson.Safe.from_string text with
                | `Assoc fields ->
                    (match List.assoc_opt "alias" fields with
                     | Some (`String value) -> value
                     | _ -> text)
                | _ -> text
              in
              check string "whoami alias" alias resolved_alias))

let test_tools_call_whoami_lazy_bootstraps_managed_codex_registration () =
  with_temp_dir (fun dir ->
      let instances_dir = Filename.concat dir "instances" in
      let instance_dir = Filename.concat instances_dir "lyra-quill-x" in
      let config_path = Filename.concat instance_dir "config.json" in
      let codex_thread_id = "019dafa6-caef-7e50-bfad-323af643e3ce" in
      let managed_session_id = "Lyra-Quill-X" in
      let alias = "lyra-quill" in
      let config_json =
        `Assoc
          [ ("name", `String managed_session_id)
          ; ("client", `String "codex")
          ; ("session_id", `String managed_session_id)
          ; ("resume_session_id", `String codex_thread_id)
          ; ("codex_resume_target", `String codex_thread_id)
          ; ("alias", `String alias)
          ; ("extra_args", `List [])
          ; ("created_at", `Float 0.)
          ; ("broker_root", `String dir)
          ; ("auto_join_rooms", `String "swarm-lounge")
          ]
      in
      let mkdir path =
        try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      in
      mkdir instances_dir;
      mkdir instance_dir;
      let oc = open_out config_path in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () ->
          Yojson.Safe.pretty_to_channel oc config_json;
          output_char oc '\n');
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" alias;
      Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "swarm-lounge";
      Unix.putenv "C2C_INSTANCES_DIR" instances_dir;
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "";
          Unix.putenv "C2C_INSTANCES_DIR" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 46)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "whoami")
                    ; ("arguments", `Assoc [])
                    ; ( "_meta",
                        `Assoc
                          [ ( "x-codex-turn-metadata",
                              `Assoc [ ("session_id", `String codex_thread_id) ] )
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let resolved_alias =
                match Yojson.Safe.from_string text with
                | `Assoc fields ->
                    (match List.assoc_opt "alias" fields with
                     | Some (`String value) -> value
                     | _ -> text)
                | _ -> text
              in
              check string "whoami alias" alias resolved_alias;
              let regs = C2c_mcp.Broker.list_registrations broker in
              check int "one registration" 1 (List.length regs);
              let reg = List.hd regs in
              check string "registered session" managed_session_id reg.session_id;
              check string "registered alias" alias reg.alias;
              let room_members =
                C2c_mcp.Broker.my_rooms broker ~session_id:managed_session_id
              in
              check int "auto joined one room" 1 (List.length room_members)))

let test_tools_call_debug_uses_codex_turn_metadata_to_find_managed_session () =
  with_temp_dir (fun dir ->
      if not Build_flags.mcp_debug_tool_enabled then ()
      else
        let instances_dir = Filename.concat dir "instances" in
        let instance_dir = Filename.concat instances_dir "lyra-quill-x" in
        let config_path = Filename.concat instance_dir "config.json" in
        let codex_thread_id = "019dafa6-caef-7e50-bfad-323af643e3ce" in
        let managed_session_id = "Lyra-Quill-X" in
        let alias = "lyra-quill" in
        let config_json =
          `Assoc
            [ ("name", `String managed_session_id)
            ; ("client", `String "codex")
            ; ("session_id", `String managed_session_id)
            ; ("resume_session_id", `String codex_thread_id)
            ; ("codex_resume_target", `String codex_thread_id)
            ; ("alias", `String alias)
            ; ("extra_args", `List [])
            ; ("created_at", `Float 0.)
            ; ("broker_root", `String dir)
            ; ("auto_join_rooms", `String "swarm-lounge")
            ]
        in
        let mkdir path =
          try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        in
        mkdir instances_dir;
        mkdir instance_dir;
        let oc = open_out config_path in
        Fun.protect
          ~finally:(fun () -> close_out oc)
          (fun () ->
            Yojson.Safe.pretty_to_channel oc config_json;
            output_char oc '\n');
        Unix.putenv "C2C_MCP_SESSION_ID" "";
        Unix.putenv "CODEX_THREAD_ID" "";
        Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" alias;
        Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "";
        Unix.putenv "C2C_INSTANCES_DIR" instances_dir;
        Fun.protect
          ~finally:(fun () ->
            Unix.putenv "C2C_MCP_SESSION_ID" "";
            Unix.putenv "CODEX_THREAD_ID" "";
            Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
            Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "";
            Unix.putenv "C2C_INSTANCES_DIR" "")
          (fun () ->
            let broker = C2c_mcp.Broker.create ~root:dir in
            let request =
              `Assoc
                [ ("jsonrpc", `String "2.0")
                ; ("id", `Int 47)
                ; ("method", `String "tools/call")
                ; ( "params",
                    `Assoc
                      [ ("name", `String "debug")
                      ; ( "arguments",
                          `Assoc
                            [ ("action", `String "send_msg_to_self")
                            ; ("payload", `Assoc [ ("probe", `String "codex-delivery") ])
                            ] )
                      ; ( "_meta",
                          `Assoc
                            [ ( "x-codex-turn-metadata",
                                `Assoc [ ("session_id", `String codex_thread_id) ] )
                            ] )
                      ] )
                ]
            in
            let response =
              Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
            in
            match response with
            | None -> fail "expected debug response"
            | Some json ->
                let open Yojson.Safe.Util in
                let result_text =
                  json |> member "result" |> member "content" |> index 0
                  |> member "text" |> to_string
                in
                let result_json = Yojson.Safe.from_string result_text in
                check bool "debug ok" true (result_json |> member "ok" |> to_bool);
                check string "resolved session"
                  managed_session_id
                  (result_json |> member "session_id" |> to_string);
                let regs = C2c_mcp.Broker.list_registrations broker in
                check int "one registration" 1 (List.length regs);
                let reg = List.hd regs in
                check string "registered session" managed_session_id reg.session_id;
                check string "registered alias" alias reg.alias;
                let inbox =
                  C2c_mcp.Broker.read_inbox broker ~session_id:managed_session_id
                in
                check int "one inbox message" 1 (List.length inbox)))

let test_tools_call_register_uses_codex_turn_metadata_when_env_missing () =
  with_temp_dir (fun dir ->
      let codex_thread_id = "codex-thread-meta-123" in
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 45)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "storm-meta") ])
                    ; ( "_meta",
                        `Assoc
                          [ ( "x-codex-turn-metadata",
                              `Assoc [ ("session_id", `String codex_thread_id) ] )
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs =
            C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
          in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" codex_thread_id reg.session_id;
          check string "registered alias" "storm-meta" reg.alias))

let test_tools_call_register_prefers_explicit_client_pid_env () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      Unix.putenv "C2C_MCP_SESSION_ID" "session-live";
      Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int live_pid);
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 41)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "storm-live") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs =
            C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
          in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check bool "registered pid uses explicit client pid" true (reg.pid = Some live_pid);
          check bool "explicit pid start_time present for live proc" true
            (reg.pid_start_time <> None)))

(* Calling register with no alias argument falls back to C2C_MCP_AUTO_REGISTER_ALIAS *)
let test_tools_call_register_no_alias_falls_back_to_env () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-noarg";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-xertrov-x";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 99)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [])
                    ] )
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          (match response with None -> fail "expected tools/call response" | Some _ -> ());
          let regs = C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir) in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "alias from env" "kimi-xertrov-x" reg.alias;
          check string "session from env" "session-noarg" reg.session_id))

(* register should reject an alias that is currently held by an alive
   registration under a different session_id. The error message should
   name the alias and the current holder so the caller knows how to
   proceed. The existing holder's registration must be untouched. *)
let test_tools_call_register_rejects_alias_hijack () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* session-owner registers "storm-beacon" with a live PID *)
      C2c_mcp.Broker.register broker ~session_id:"session-owner"
        ~alias:"storm-beacon" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* session-thief tries to claim the same alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-thief";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 77)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ( "arguments",
                        `Assoc [ ("alias", `String "storm-beacon") ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "register rejected with isError=true" true is_error;
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               check bool "error mentions contested alias" true
                 (string_contains text "storm-beacon");
               check bool "error mentions holder session" true
                 (string_contains text "session-owner");
               (* Structured response: JSON with suggested_alias and collision flag *)
               let parsed = Yojson.Safe.from_string text in
               let collision =
                 parsed |> member "collision" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "collision flag set" true collision;
               let suggested =
                 parsed |> member "suggested_alias" |> to_string_option
               in
               check bool "suggested_alias present" true (suggested <> None);
               check string "suggested_alias is prime-suffixed"
                 "storm-beacon-2" (Option.value suggested ~default:""));
          (* Original owner must still be registered *)
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          let owner =
            List.find_opt (fun r -> r.session_id = "session-owner") regs
          in
          check bool "owner registration preserved" true (owner <> None);
          check string "owner alias unchanged" "storm-beacon"
            (Option.get owner).alias;
          let thief =
            List.find_opt (fun r -> r.session_id = "session-thief") regs
          in
          check bool "thief not registered" true (thief = None)))

(* A pidless (legacy) stale entry with Unknown liveness must NOT block a new
   session from claiming the same alias.  registration_is_alive returns true
   for pid=None; the alias_hijack_conflict guard must use the tristate
   registration_liveness_state instead so Unknown entries are evicted, not
   treated as permanently Alive. *)
let test_tools_call_register_allows_takeover_of_pidless_stale_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register alias with pid=None — legacy pidless row, liveness=Unknown *)
      C2c_mcp.Broker.register broker ~session_id:"session-stale"
        ~alias:"drifting-elk" ~pid:None ~pid_start_time:None ();
      (* A new session tries to claim the same alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-new";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 180)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "drifting-elk") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "pidless stale alias should not block new session" false is_error);
          (* stale session evicted, new session holds alias *)
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          check bool "stale session evicted" true
            (List.for_all (fun r -> r.session_id <> "session-stale") regs);
          let new_reg =
            List.find_opt (fun r -> r.session_id = "session-new") regs
          in
          check bool "new session registered" true (new_reg <> None);
          check string "new session holds alias" "drifting-elk"
            (Option.get new_reg).alias))

(* When all prime-suffixed alias candidates are also alive, the broker returns
   collision_exhausted=true in the structured error rather than looping forever. *)
let test_tools_call_register_alias_collision_exhausted () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register the base alias + all 5 prime suffixes with live PIDs *)
      let primes = [ ""; "-2"; "-3"; "-5"; "-7"; "-11" ] in
      List.iteri (fun i sfx ->
        C2c_mcp.Broker.register broker
          ~session_id:(Printf.sprintf "session-owner-%d" i)
          ~alias:(Printf.sprintf "nova%s" sfx)
          ~pid:(Some live_pid) ~pid_start_time:None ()
      ) primes;
      (* session-exhausted tries to claim "nova" when all slots are taken *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-exhausted";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 88)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "nova") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "collision_exhausted rejected with isError=true" true is_error;
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              let exhausted =
                parsed |> member "collision_exhausted" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "collision_exhausted flag set" true exhausted;
              let collision =
                parsed |> member "collision" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "collision flag set on exhausted" true collision;
              (* suggested_alias should be absent when exhausted *)
              check bool "no suggested_alias when exhausted" true
                (parsed |> member "suggested_alias" |> to_string_option = None)))

(* register should allow re-registering the same alias under the same
   session_id (PID refresh after a restart). *)
let test_tools_call_register_allows_own_alias_refresh () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-self"
        ~alias:"my-alias" ~pid:(Some live_pid) ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-self";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 78)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "my-alias") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "own alias re-register not rejected" false is_error)))

let test_tools_call_register_alias_rename_notifies_rooms () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-renamed"
        ~alias:"old-alias" ~pid:None ~pid_start_time:None
        ~client_type:(Some "human") ();
      C2c_mcp.Broker.register broker ~session_id:"session-peer"
        ~alias:"peer-alias" ~pid:None ~pid_start_time:None
        ~client_type:(Some "human") ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"old-alias" ~session_id:"session-renamed");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"peer-alias" ~session_id:"session-peer");
      ignore
        (C2c_mcp.Broker.drain_inbox broker ~session_id:"session-renamed");
      ignore
        (C2c_mcp.Broker.drain_inbox broker ~session_id:"session-peer");
      Unix.putenv "C2C_MCP_SESSION_ID" "session-renamed";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 199)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments", `Assoc [ ("alias", `String "new-alias") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with None -> fail "expected register response" | Some _ -> ());
          let history =
            C2c_mcp.Broker.read_room_history broker ~room_id:"swarm-lounge"
              ~limit:10 ()
          in
          check int "two join events plus one rename history event" 3
            (List.length history);
          let event = List.hd (List.rev history) in
          check string "rename event sender" "c2c-system" event.rm_from_alias;
          (* Content is "old renamed to new {...json...}"; extract JSON suffix *)
          let json_start = String.index event.rm_content '{' in
          let json_str = String.sub event.rm_content json_start
            (String.length event.rm_content - json_start) in
          let parsed = Yojson.Safe.from_string json_str in
          let open Yojson.Safe.Util in
          check string "event type" "peer_renamed"
            (parsed |> member "type" |> to_string);
          check string "old alias" "old-alias"
            (parsed |> member "old_alias" |> to_string);
          check string "new alias" "new-alias"
            (parsed |> member "new_alias" |> to_string);
          let peer_inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-peer"
          in
          check int "peer received room fanout" 1 (List.length peer_inbox);
          let msg = List.hd peer_inbox in
          check string "fanout sender" "c2c-system" msg.from_alias;
          check string "fanout to tagged peer" "peer-alias#swarm-lounge"
            msg.to_alias;
          check string "fanout content matches history" event.rm_content
            msg.content))

let test_server_startup_auto_registers_alias_from_env () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-auto";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "opencode-local";
      Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int (Unix.getpid ()));
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let broker = C2c_mcp.Broker.create ~root:dir in
          let regs = C2c_mcp.Broker.list_registrations broker in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" "session-auto" reg.session_id;
          check string "registered alias" "opencode-local" reg.alias;
          check bool "registered pid" true (reg.pid = Some (Unix.getpid ()))))

let test_server_startup_auto_register_ignores_dead_client_pid_env () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-auto";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-nova";
      Unix.putenv "C2C_MCP_CLIENT_PID" "999999999";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let broker = C2c_mcp.Broker.create ~root:dir in
          let regs = C2c_mcp.Broker.list_registrations broker in
          check int "one registration" 1 (List.length regs);
          let reg = List.hd regs in
          check string "registered session" "session-auto" reg.session_id;
          check string "registered alias" "kimi-nova" reg.alias;
          check bool "dead env pid ignored" true (reg.pid = Some (Unix.getppid ()))))

let test_auto_register_startup_skips_when_alive_session_has_different_alias () =
  (* Regression: kimi -p inherits CLAUDE_SESSION_ID and should NOT evict the
     running Claude Code session's alias. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let me = Unix.getpid () in
      let my_start = C2c_mcp.Broker.read_pid_start_time me in
      (* Pre-register an alive session with alias "claude-code-session" *)
      C2c_mcp.Broker.register broker
        ~session_id:"shared-session" ~alias:"claude-code-session"
        ~pid:(Some me) ~pid_start_time:my_start ();
      (* Now simulate kimi starting with the same session_id but a different alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "shared-session";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-child-alias";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          (* Should still have only the original registration — kimi was blocked *)
          check int "one registration (hijack blocked)" 1 (List.length regs);
          let reg = List.hd regs in
          check string "alias preserved" "claude-code-session" reg.alias))

let test_auto_register_startup_skips_when_alive_session_owns_alias () =
  (* Regression: a one-shot probe with a different session_id but the same
     alias must NOT evict the live session that already owns the alias.
     Real scenario: opencode-c2c-msg accidentally gets alias=kimi-nova and
     evicts the live kimi session. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let me = Unix.getpid () in
      let my_start = C2c_mcp.Broker.read_pid_start_time me in
      (* Pre-register an alive kimi session owning alias "kimi-nova" *)
      C2c_mcp.Broker.register broker
        ~session_id:"kimi-real-session" ~alias:"kimi-nova"
        ~pid:(Some me) ~pid_start_time:my_start ();
      (* Simulate one-shot probe: different session_id, same alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "one-shot-probe-session";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-nova";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          (* Probe was blocked; original kimi registration preserved *)
          check int "one registration (alias hijack blocked)" 1 (List.length regs);
          let reg = List.hd regs in
          check string "session_id preserved" "kimi-real-session" reg.session_id;
          check string "alias preserved" "kimi-nova" reg.alias))

let test_auto_register_startup_skips_when_alive_same_session_different_pid () =
  (* Regression: child process launched from another agent inherits a wrong
     C2C_MCP_CLIENT_PID and must NOT overwrite the existing alive registration
     for the same session_id + alias. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let real_pid = Unix.getpid () in
      let real_start = C2c_mcp.Broker.read_pid_start_time real_pid in
      (* Pre-register an alive session with pid=real_pid *)
      C2c_mcp.Broker.register broker
        ~session_id:"kimi-nova" ~alias:"kimi-nova-2"
        ~pid:(Some real_pid) ~pid_start_time:real_start ();
      (* Simulate child process with inherited wrong C2C_MCP_CLIENT_PID *)
      let fake_pid = 111111 in
      Unix.putenv "C2C_MCP_SESSION_ID" "kimi-nova";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-nova-2";
      Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int fake_pid);
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          check int "one registration (same-session diff-pid blocked)" 1 (List.length regs);
          let reg = List.hd regs in
          check int "original pid preserved" real_pid (Option.get reg.pid)))

let test_auto_join_rooms_startup_joins_listed_rooms () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-social";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "social-agent";
      Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "swarm-lounge,design-review";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          C2c_mcp.auto_join_rooms_startup ~broker_root:dir;
          let broker = C2c_mcp.Broker.create ~root:dir in
          let rooms = C2c_mcp.Broker.list_rooms broker in
          let room_ids = List.map (fun r -> r.C2c_mcp.Broker.ri_room_id) rooms in
          check bool "joined swarm-lounge" true (List.mem "swarm-lounge" room_ids);
          check bool "joined design-review" true (List.mem "design-review" room_ids)))

let test_auto_join_rooms_startup_prefers_registered_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-social"
        ~alias:"new-alias" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-social";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "old-env-alias";
      Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "swarm-lounge";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "")
        (fun () ->
          C2c_mcp.auto_join_rooms_startup ~broker_root:dir;
          let members =
            C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
          in
          check (list string) "auto-join uses current registered alias"
            [ "new-alias" ]
            (List.map (fun m -> m.C2c_mcp.rm_alias) members)))

let test_auto_join_rooms_startup_skips_when_no_alias () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
      Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "swarm-lounge";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "")
        (fun () ->
          (* No alias configured: should be a no-op, not an error *)
          C2c_mcp.auto_join_rooms_startup ~broker_root:dir;
          let broker = C2c_mcp.Broker.create ~root:dir in
          let rooms = C2c_mcp.Broker.list_rooms broker in
          check int "no rooms created when alias absent" 0 (List.length rooms)))

let test_auto_join_rooms_startup_empty_env_is_noop () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-noop";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "noop-agent";
      Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_AUTO_JOIN_ROOMS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          C2c_mcp.auto_join_rooms_startup ~broker_root:dir;
          let broker = C2c_mcp.Broker.create ~root:dir in
          let rooms = C2c_mcp.Broker.list_rooms broker in
          check int "no rooms when env is empty" 0 (List.length rooms)))

let test_tools_call_whoami_uses_current_session_id_when_omitted () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-live";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-live" ~alias:"storm-live" ~pid:None ~pid_start_time:None ();
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
              let raw = json |> member "result" |> member "content" |> index 0 |> member "text" |> to_string in
              (* whoami now returns JSON when canonical_alias is present *)
              let alias_val =
                (try match Yojson.Safe.from_string raw with
                  | `Assoc fields ->
                      (match List.assoc_opt "alias" fields with
                       | Some (`String s) -> s
                       | _ -> raw)
                  | _ -> raw
                with _ -> raw)
              in
              check string "whoami alias" "storm-live" alias_val))

let test_tools_call_whoami_uses_codex_thread_id_when_c2c_session_id_missing ()
    =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "";
      Unix.putenv "CODEX_THREAD_ID" "codex-thread-123";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "";
          Unix.putenv "CODEX_THREAD_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"codex-thread-123"
            ~alias:"storm-codex" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 43)
              ; ("method", `String "tools/call")
              ; ("params", `Assoc [ ("name", `String "whoami"); ("arguments", `Assoc []) ])
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let raw =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let alias_val =
                (try
                   match Yojson.Safe.from_string raw with
                   | `Assoc fields ->
                       (match List.assoc_opt "alias" fields with
                        | Some (`String s) -> s
                        | _ -> raw)
                   | _ -> raw
                 with _ -> raw)
              in
              check string "whoami alias" "storm-codex" alias_val))

let test_tools_call_poll_inbox_drains_messages_as_tool_result () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-poll";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-from" ~alias:"storm-from" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-poll" ~alias:"storm-poll" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-from" ~to_alias:"storm-poll" ~content:"hello-one" ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"storm-from" ~to_alias:"storm-poll" ~content:"hello-two" ();
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
          C2c_mcp.Broker.register broker ~session_id:"session-empty" ~alias:"storm-empty" ~pid:None ~pid_start_time:None ();
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
      C2c_mcp.Broker.register broker ~session_id:"session-dead" ~alias:"storm-dead" ~pid:(Some dead) ~pid_start_time:None ();
      check_raises "dead recipient raises Invalid_argument"
        (Invalid_argument "recipient is not alive: storm-dead")
        (fun () ->
          C2c_mcp.Broker.enqueue_message broker
            ~from_alias:"storm-dead" ~to_alias:"storm-dead" ~content:"ping" ()))

let test_enqueue_picks_live_when_zombie_shares_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker ~session_id:"session-zombie" ~alias:"storm-twin" ~pid:(Some dead) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-live" ~alias:"storm-twin" ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"storm-twin" ~to_alias:"storm-twin" ~content:"alive!" ();
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
        ~from_alias:"storm-legacy" ~to_alias:"storm-legacy" ~content:"still works" ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"legacy-session" in
      check int "legacy enqueue delivered" 1 (List.length inbox))

let test_registration_persists_pid () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s" ~alias:"a" ~pid:(Some 42) ~pid_start_time:None ();
      let reg =
        C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
        |> List.hd
      in
      check bool "pid persisted" true (reg.pid = Some 42))

(* Slice 9: registry.json and *.inbox.json carry agent identity and
   message envelopes respectively, so they must not land at 0o644
   when the broker creates them from scratch. write_json_file uses
   explicit 0o600; the umask only ever removes bits, so a request for
   0o600 yields exactly 0o600. *)
let test_register_writes_registry_at_0o600 () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s" ~alias:"a" ~pid:None ~pid_start_time:None ();
      let st = Unix.stat (Filename.concat dir "registry.json") in
      let mode = st.Unix.st_perm land 0o777 in
      check int "registry.json mode is 0o600" 0o600 mode)

let test_enqueue_writes_inbox_at_0o600 () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"recv-sid" ~alias:"recv"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"sender" ~to_alias:"recv" ~content:"hello" ();
      let st = Unix.stat (Filename.concat dir "recv-sid.inbox.json") in
      let mode = st.Unix.st_perm land 0o777 in
      check int "inbox file mode is 0o600" 0o600 mode)

(* Slice 12: tools/call list reports per-peer alive as a tristate —
   true (verified live), false (verified dead pid or pid reuse),
   null (legacy pidless row, can't tell). Operators consuming the
   list response use this to identify zombie peers before
   broadcasting. The legacy registration_is_alive collapses Unknown
   into Alive for sweep/enqueue compat; this test pins down the
   tristate behavior on the list tool surface specifically. *)
let test_tools_call_list_reports_alive_tristate () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Live: real pid (this test process) with start_time captured *)
      let live_pid = Unix.getpid () in
      let live_start = C2c_mcp.Broker.read_pid_start_time live_pid in
      C2c_mcp.Broker.register broker
        ~session_id:"live-sid" ~alias:"live"
        ~pid:(Some live_pid) ~pid_start_time:live_start ();
      (* Dead: pid we know doesn't exist. Picking pid 1 with a
         deliberately wrong start_time forces the start_time mismatch
         path even on the off-chance pid 1 exists. *)
      C2c_mcp.Broker.register broker
        ~session_id:"dead-sid" ~alias:"dead"
        ~pid:(Some 999_999_999) ~pid_start_time:(Some 1) ();
      (* Pidless legacy row *)
      C2c_mcp.Broker.register broker
        ~session_id:"legacy-sid" ~alias:"legacy"
        ~pid:None ~pid_start_time:None ();
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 88)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "list"); ("arguments", `Assoc []) ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected list response"
      | Some json ->
          let open Yojson.Safe.Util in
          let content_text =
            json |> member "result" |> member "content" |> to_list |> List.hd
            |> member "text" |> to_string
          in
          let entries = Yojson.Safe.from_string content_text |> to_list in
          let lookup alias =
            List.find
              (fun e -> (e |> member "alias" |> to_string) = alias)
              entries
          in
          let live = lookup "live" in
          let dead = lookup "dead" in
          let legacy = lookup "legacy" in
          (* live row: alive Bool true *)
          (match live |> member "alive" with
           | `Bool true -> ()
           | other ->
               fail
                 (Printf.sprintf "live alive should be Bool true, got %s"
                    (Yojson.Safe.to_string other)));
          (* dead row: alive Bool false *)
          (match dead |> member "alive" with
           | `Bool false -> ()
           | other ->
               fail
                 (Printf.sprintf "dead alive should be Bool false, got %s"
                    (Yojson.Safe.to_string other)));
          (* legacy row: alive Null *)
          (match legacy |> member "alive" with
           | `Null -> ()
           | other ->
               fail
                 (Printf.sprintf "legacy alive should be Null, got %s"
                    (Yojson.Safe.to_string other)));
          check int "three entries returned" 3 (List.length entries))

let test_tools_call_list_includes_registered_at () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let before = Unix.gettimeofday () in
      C2c_mcp.Broker.register broker
        ~session_id:"ts-sid" ~alias:"ts-peer"
        ~pid:None ~pid_start_time:None ();
      let after = Unix.gettimeofday () in
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 99)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "list"); ("arguments", `Assoc []) ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected list response"
      | Some json ->
          let open Yojson.Safe.Util in
          let content_text =
            json |> member "result" |> member "content" |> to_list |> List.hd
            |> member "text" |> to_string
          in
          let entries = Yojson.Safe.from_string content_text |> to_list in
          let peer =
            List.find
              (fun e -> (e |> member "alias" |> to_string) = "ts-peer")
              entries
          in
          let ts =
            match peer |> member "registered_at" with
            | `Float f -> f
            | `Int n -> float_of_int n
            | other ->
                fail
                  (Printf.sprintf "registered_at should be float, got %s"
                     (Yojson.Safe.to_string other))
          in
          check bool "registered_at >= before" true (ts >= before);
          check bool "registered_at <= after" true (ts <= after))

(* Slice 11: write_json_file uses temp+rename atomicity. After any
   write completes the per-pid `.tmp.<pid>` sidecar must be gone.
   A leftover sidecar means either the rename failed silently or
   the cleanup path leaks state that would accumulate over time. *)
let test_write_json_file_leaves_no_tmp_sidecars () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"recv-sid" ~alias:"recv"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"send-sid" ~alias:"send"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"send" ~to_alias:"recv" ~content:"hello" ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"send" ~to_alias:"recv" ~content:"world" ();
      let entries = Sys.readdir dir |> Array.to_list in
      let tmp_sidecars =
        List.filter
          (fun name ->
            (* match `<anything>.tmp.<digits>` — the per-pid suffix *)
            try
              let i = String.rindex name '.' in
              let suffix_after = String.sub name (i + 1) (String.length name - i - 1) in
              let prefix = String.sub name 0 i in
              let is_digits = String.for_all (fun c -> c >= '0' && c <= '9') suffix_after in
              is_digits
              && suffix_after <> ""
              && (try String.length prefix >= 4
                      && String.sub prefix (String.length prefix - 4) 4 = ".tmp"
                  with _ -> false)
            with Not_found -> false)
          entries
      in
      check int "no tmp sidecars left in broker dir" 0
        (List.length tmp_sidecars))

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
        ~pid:(Some 42) ~pid_start_time:(Some 9999) ();
      let reg =
        C2c_mcp.Broker.list_registrations (C2c_mcp.Broker.create ~root:dir)
        |> List.hd
      in
      check bool "start_time persisted" true (reg.pid_start_time = Some 9999))

let test_start_time_mismatch_is_not_alive () =
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
    ; registered_at = None
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type = None; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
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
    ; registered_at = None
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type = None; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
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
    ; registered_at = None
    ; canonical_alias = None
    ; dnd = false
    ; dnd_since = None
    ; dnd_until = None
    ; client_type = None; plugin_version = None
    ; confirmed_at = None
    ; enc_pubkey = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
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
        ~session_id:"seed" ~alias:"seed-alias" ~pid:None ~pid_start_time:None ();
      let children =
        List.init n (fun i ->
            match Unix.fork () with
            | 0 ->
                let broker = C2c_mcp.Broker.create ~root:dir in
                C2c_mcp.Broker.register broker
                  ~session_id:(Printf.sprintf "s-%d" i)
                  ~alias:(Printf.sprintf "a-%d" i)
                  ~pid:None ~pid_start_time:None ();
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

let test_auto_register_startup_redelivers_dead_letter_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"managed-session" ~alias:"opencode-local"
        ~pid:(Some dead) ~pid_start_time:None ();
      write_file (Filename.concat dir "managed-session.inbox.json")
        {|[{"from_alias":"storm-ember","to_alias":"opencode-local","content":"queued while down"},{"from_alias":"storm-beacon","to_alias":"opencode-local","content":"second queued while down"}]|};
      let result = C2c_mcp.Broker.sweep broker in
      check int "dead session inbox swept" 1 (List.length result.deleted_inboxes);
      check int "two messages dead-lettered" 2 result.preserved_messages;
      check bool "swept inbox removed" false
        (Sys.file_exists (Filename.concat dir "managed-session.inbox.json"));
      Unix.putenv "C2C_MCP_SESSION_ID" "managed-session";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "opencode-local";
      Unix.putenv "C2C_MCP_CLIENT_PID" (string_of_int (Unix.getpid ()));
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"managed-session"
          in
          check int "dead-letter messages redelivered" 2 (List.length inbox);
          let contents = List.map (fun msg -> msg.C2c_mcp.content) inbox in
          check bool "first content restored" true
            (List.mem "queued while down" contents);
          check bool "second content restored" true
            (List.mem "second queued while down" contents);
          let dead_letter = C2c_mcp.Broker.dead_letter_path broker in
          let remaining =
            let ic = open_in dead_letter in
            Fun.protect
              ~finally:(fun () -> close_in ic)
              (fun () ->
                let lines = ref [] in
                (try
                   while true do
                     let line = input_line ic |> String.trim in
                     if line <> "" then lines := line :: !lines
                   done
                 with End_of_file -> ());
                !lines)
          in
          check int "redelivered records removed from dead-letter" 0
            (List.length remaining)))

let test_register_evicts_prior_reg_with_same_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* First register: legacy (pid=None). Simulates a pre-hardening
         session that left a ghost row behind. *)
      C2c_mcp.Broker.register broker
        ~session_id:"old-session" ~alias:"storm-recv"
        ~pid:None ~pid_start_time:None ();
      (* Second register: same alias, fresh session_id with pid. *)
      C2c_mcp.Broker.register broker
        ~session_id:"new-session" ~alias:"storm-recv"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "only one reg for the alias" 1
        (List.length
           (List.filter
              (fun r -> r.C2c_mcp.alias = "storm-recv")
              regs));
      check bool "new session survived"
        true
        (List.exists
           (fun r -> r.C2c_mcp.session_id = "new-session")
           regs);
      check bool "old session evicted"
        false
        (List.exists
           (fun r -> r.C2c_mcp.session_id = "old-session")
           regs);
      (* Enqueue must now reach the new session. *)
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"sender" ~to_alias:"storm-recv" ~content:"hello" ();
      let msgs =
        C2c_mcp.Broker.read_inbox broker ~session_id:"new-session"
      in
      check int "delivered to new session" 1 (List.length msgs);
      let old_inbox_path =
        Filename.concat dir "old-session.inbox.json"
      in
      check bool "old session inbox untouched"
        false
        (Sys.file_exists old_inbox_path))

let test_register_migrates_undrained_inbox_on_alias_re_register () =
  (* Bug: when a session re-registers under the same alias with a fresh
     session_id, any messages already queued on the old session's inbox file
     get stranded. Sweep eventually preserves them to dead-letter, but the
     re-launched session — the same logical agent — never sees them. The
     register call should migrate undrained messages to the new inbox. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"old-session" ~alias:"storm-recv"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"sender" ~to_alias:"storm-recv"
        ~content:"queued before re-register" ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"sender" ~to_alias:"storm-recv"
        ~content:"second queued message" ();
      (* Re-register same alias with a new session_id. *)
      C2c_mcp.Broker.register broker
        ~session_id:"new-session" ~alias:"storm-recv"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let drained =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"new-session"
      in
      check int "migrated message count" 2 (List.length drained);
      check string "first migrated content" "queued before re-register"
        (List.nth drained 0).C2c_mcp.content;
      check string "second migrated content" "second queued message"
        (List.nth drained 1).C2c_mcp.content;
      let old_inbox_path =
        Filename.concat dir "old-session.inbox.json"
      in
      check bool "old session inbox file removed" false
        (Sys.file_exists old_inbox_path))

let test_register_serializes_with_concurrent_enqueue () =
  (* Regression for the concurrent register-vs-send race. Without the
     registry lock around enqueue_message, a sender that resolved the
     alias to a session_id can race a re-register that just evicted that
     session, write to the about-to-be-deleted inbox file, and have its
     message stranded. With the lock, enqueue and register serialize on
     the registry mutex and every successfully-enqueued message lands on
     the currently-winning session's inbox. *)
  with_temp_dir (fun dir ->
      let _ = C2c_mcp.Broker.create ~root:dir in
      let parent_pid = Unix.getpid () in
      C2c_mcp.Broker.register (C2c_mcp.Broker.create ~root:dir)
        ~session_id:"target-s0" ~alias:"target"
        ~pid:(Some parent_pid) ~pid_start_time:None ();
      let n_msgs = 60 in
      let sender =
        match Unix.fork () with
        | 0 ->
            let broker = C2c_mcp.Broker.create ~root:dir in
            for i = 0 to n_msgs - 1 do
              (try
                 C2c_mcp.Broker.enqueue_message broker
                   ~from_alias:"sender" ~to_alias:"target"
                   ~content:(Printf.sprintf "msg-%d" i) ()
               with _ -> ())
            done;
            exit 0
        | child -> child
      in
      (* Parent: while the child is sending, churn through several
         re-registers so the race window is repeatedly opened. *)
      for k = 1 to 8 do
        C2c_mcp.Broker.register (C2c_mcp.Broker.create ~root:dir)
          ~session_id:(Printf.sprintf "target-s%d" k)
          ~alias:"target"
          ~pid:(Some parent_pid)
          ~pid_start_time:None ()
      done;
      let rec waitpid_eintr child =
        try ignore (Unix.waitpid [] child)
        with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr child
      in
      waitpid_eintr sender;
      (* Final winner is target-s8. All earlier session inbox files must
         have been migrated and removed. *)
      let final_drain =
        C2c_mcp.Broker.drain_inbox
          (C2c_mcp.Broker.create ~root:dir)
          ~session_id:"target-s8"
      in
      check int "all sender messages reached current owner" n_msgs
        (List.length final_drain);
      for k = 0 to 7 do
        let stale =
          Filename.concat dir
            (Printf.sprintf "target-s%d.inbox.json" k)
        in
        check bool
          (Printf.sprintf "stale inbox target-s%d.inbox.json removed" k)
          false (Sys.file_exists stale)
      done)

let test_concurrent_enqueue_does_not_lose_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"recipient" ~alias:"storm-recv"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let n = 12 in
      let per_child = 20 in
      let children =
        List.init n (fun i ->
            match Unix.fork () with
            | 0 ->
                let broker = C2c_mcp.Broker.create ~root:dir in
                for j = 0 to per_child - 1 do
                  C2c_mcp.Broker.enqueue_message broker
                    ~from_alias:(Printf.sprintf "sender-%d" i)
                    ~to_alias:"storm-recv"
                    ~content:(Printf.sprintf "msg-%d-%d" i j) ()
                done;
                exit 0
            | child -> child)
      in
      let rec waitpid_eintr child =
        try ignore (Unix.waitpid [] child)
        with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr child
      in
      List.iter waitpid_eintr children;
      let messages =
        C2c_mcp.Broker.read_inbox broker ~session_id:"recipient"
      in
      check int "all concurrent enqueues preserved" (n * per_child)
        (List.length messages);
      for i = 0 to n - 1 do
        let seen =
          List.filter
            (fun m ->
              m.C2c_mcp.from_alias = Printf.sprintf "sender-%d" i)
            messages
        in
        check int
          (Printf.sprintf "sender-%d delivered all %d messages" i per_child)
          per_child
          (List.length seen)
      done)

let test_sweep_drops_dead_reg_and_its_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"storm-dead" ~pid:(Some dead) ~pid_start_time:None ();
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
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
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
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"storm-live" ~to_alias:"storm-live" ~content:"keep me" ();
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

(* ---- Orphan inbox capture and replay (c2c restart Slice 3) ---- *)

let pending_replay_path dir session_id =
  Filename.concat dir ("pending-orphan-replay." ^ session_id ^ ".json")

let write_pending_replay_file path msgs =
  let json_list = `List (List.map (fun (from_alias, to_alias, content) ->
    `Assoc [
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
      ("deferrable", `Bool false);
      ("reply_via", `Null);
      ("enc_status", `Null);
    ]) msgs)
  in
  Yojson.Safe.to_file path json_list

let test_read_and_delete_orphan_inbox_captures_and_deletes () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* No registration — this is an orphan inbox *)
      write_file (Filename.concat dir "orphan-sid.inbox.json")
        {|[{"from_alias":"storm-ember","to_alias":"ghost-sid","content":"hello"},{"from_alias":"storm-beacon","to_alias":"ghost-sid","content":"world"}]|};
      let msgs = C2c_mcp.Broker.read_and_delete_orphan_inbox broker ~session_id:"orphan-sid" in
      check int "two messages captured" 2 (List.length msgs);
      List.iter (fun m ->
        check bool "from alias non-empty" true (m.C2c_mcp.from_alias <> "")) msgs;
      check bool "orphan file deleted" false
        (Sys.file_exists (Filename.concat dir "orphan-sid.inbox.json")))

let test_read_and_delete_orphan_inbox_missing_file_returns_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let msgs = C2c_mcp.Broker.read_and_delete_orphan_inbox broker ~session_id:"nonexistent" in
      check int "no messages" 0 (List.length msgs))

let test_replay_pending_orphan_inbox_appends_to_live_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register session so inbox is live *)
      C2c_mcp.Broker.register broker
        ~session_id:"live-sid" ~alias:"ghost-sid"
        ~pid:None ~pid_start_time:None ();
      (* Write pending replay file with 2 messages *)
      write_pending_replay_file (pending_replay_path dir "live-sid")
        [("storm-ember", "ghost-sid", "alpha"); ("storm-beacon", "ghost-sid", "beta")];
      let n = C2c_mcp.Broker.replay_pending_orphan_inbox broker ~session_id:"live-sid" in
      check int "replayed 2 messages" 2 n;
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"live-sid" in
      check int "live inbox has 2 messages" 2 (List.length inbox);
      List.iter (fun m ->
        check bool "from alias non-empty" true (m.C2c_mcp.from_alias <> "")) inbox;
      check bool "pending file deleted" false
        (Sys.file_exists (pending_replay_path dir "live-sid")))

let test_replay_pending_orphan_inbox_missing_pending_file_returns_zero () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"live-sid" ~alias:"ghost-sid"
        ~pid:None ~pid_start_time:None ();
      let n = C2c_mcp.Broker.replay_pending_orphan_inbox broker ~session_id:"live-sid" in
      check int "no pending file, returns 0" 0 n;
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"live-sid" in
      check int "inbox still empty" 0 (List.length inbox))

let test_replay_pending_orphan_inbox_empty_pending_file_returns_zero_and_deletes () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"live-sid" ~alias:"ghost-sid"
        ~pid:None ~pid_start_time:None ();
      write_pending_replay_file (pending_replay_path dir "live-sid") [];
      let n = C2c_mcp.Broker.replay_pending_orphan_inbox broker ~session_id:"live-sid" in
      check int "empty pending file, returns 0" 0 n;
      check bool "pending file deleted" false
        (Sys.file_exists (pending_replay_path dir "live-sid"));
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"live-sid" in
      check int "inbox still empty" 0 (List.length inbox))

(* ----------------------------------------------------------- *)

let test_sweep_preserves_nonempty_orphan_to_dead_letter () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* Orphan inbox with 2 messages. *)
      write_file (Filename.concat dir "ghost-sid.inbox.json")
        {|[{"from_alias":"storm-ember","to_alias":"storm-storm","content":"alpha"},{"from_alias":"storm-beacon","to_alias":"storm-storm","content":"beta"}]|};
      let result = C2c_mcp.Broker.sweep broker in
      check int "one orphan deleted" 1 (List.length result.deleted_inboxes);
      check int "two messages preserved" 2 result.preserved_messages;
      check bool "orphan file gone" false
        (Sys.file_exists (Filename.concat dir "ghost-sid.inbox.json"));
      let dead_letter = C2c_mcp.Broker.dead_letter_path broker in
      check bool "dead-letter file exists" true (Sys.file_exists dead_letter);
      let contents =
        let ic = open_in dead_letter in
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () ->
            let buf = Buffer.create 512 in
            try
              while true do
                Buffer.add_string buf (input_line ic);
                Buffer.add_char buf '\n'
              done;
              Buffer.contents buf
            with End_of_file -> Buffer.contents buf)
      in
      let lines =
        String.split_on_char '\n' contents
        |> List.filter (fun l -> l <> "")
      in
      check int "dead-letter records" 2 (List.length lines);
      let has_alpha =
        List.exists
          (fun line ->
            try
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              let msg = json |> member "message" in
              let content = msg |> member "content" |> to_string in
              let sid = json |> member "from_session_id" |> to_string in
              content = "alpha" && sid = "ghost-sid"
            with _ -> false)
          lines
      in
      check bool "alpha message with session id preserved" true has_alpha;
      (* Every dead-letter record must have a non-empty deleted_at
         timestamp and a well-formed message object with the three
         envelope fields. Operators use deleted_at to correlate sweeps
         with broker logs; silent loss of this field would make
         dead-letter.jsonl much less useful for triage. *)
      let records_are_well_formed =
        List.for_all
          (fun line ->
            try
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              let deleted_at = json |> member "deleted_at" |> to_number in
              let sid = json |> member "from_session_id" |> to_string in
              let msg = json |> member "message" in
              let from_alias = msg |> member "from_alias" |> to_string in
              let to_alias = msg |> member "to_alias" |> to_string in
              let content = msg |> member "content" |> to_string in
              deleted_at > 0.0
              && sid = "ghost-sid"
              && from_alias <> ""
              && to_alias <> ""
              && content <> ""
            with _ -> false)
          lines
      in
      check bool "every record well-formed with deleted_at + envelope"
        true records_are_well_formed;
      (* Dead-letter records carry the same envelope content as live
         inbox files, so the file must not be world-readable. The
         broker creates it with explicit 0o600; on any sane umask the
         resulting on-disk mode must mask to 0o600 (umask only ever
         removes bits, never adds them). *)
      let st = Unix.stat dead_letter in
      let mode = st.Unix.st_perm land 0o777 in
      check int "dead-letter file mode is 0o600" 0o600 mode)

let test_tools_call_send_all_routes_through_broker_and_returns_result () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-sender" ~alias:"storm-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-a" ~alias:"storm-a"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-b" ~alias:"storm-b"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-c" ~alias:"storm-c"
        ~pid:None ~pid_start_time:None ();
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 42)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "send_all")
                ; ( "arguments",
                    `Assoc
                      [ ("from_alias", `String "storm-sender")
                      ; ("content", `String "swarm broadcast")
                      ; ( "exclude_aliases",
                          `List [ `String "storm-b" ] )
                      ] )
                ] )
          ]
      in
      let response =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
      in
      let result_json =
        match response with
        | None -> fail "expected tools/call response"
        | Some resp ->
            let open Yojson.Safe.Util in
            let text =
              resp
              |> member "result"
              |> member "content"
              |> to_list
              |> List.hd
              |> member "text"
              |> to_string
            in
            Yojson.Safe.from_string text
      in
      let open Yojson.Safe.Util in
      let sent_to =
        result_json
        |> member "sent_to"
        |> to_list
        |> List.map to_string
      in
      let skipped =
        result_json
        |> member "skipped"
        |> to_list
      in
      check int "two aliases received (sender+exclude skipped)" 2
        (List.length sent_to);
      check bool "storm-a received" true (List.mem "storm-a" sent_to);
      check bool "storm-c received" true (List.mem "storm-c" sent_to);
      check bool "sender not in sent_to" false
        (List.mem "storm-sender" sent_to);
      check bool "excluded alias not in sent_to" false
        (List.mem "storm-b" sent_to);
      check int "nothing skipped (no dead peers)" 0 (List.length skipped);
      let inbox_a =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      check int "storm-a delivery landed" 1 (List.length inbox_a);
      check int "storm-b excluded, inbox untouched" 0 (List.length inbox_b);
      let msg = List.hd inbox_a in
      check string "content arrived" "swarm broadcast" msg.content;
      check string "from_alias stamped" "storm-sender" msg.from_alias;
      check string "to_alias is per-recipient" "storm-a" msg.to_alias)

let test_send_all_fans_out_and_skips_sender () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-sender" ~alias:"storm-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-a" ~alias:"storm-a"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-b" ~alias:"storm-b"
        ~pid:None ~pid_start_time:None ();
      let result =
        C2c_mcp.Broker.send_all broker
          ~from_alias:"storm-sender"
          ~content:"hello everyone"
          ~exclude_aliases:[]
      in
      check int "two recipients received" 2 (List.length result.sent_to);
      check bool "storm-a in sent_to" true
        (List.mem "storm-a" result.sent_to);
      check bool "storm-b in sent_to" true
        (List.mem "storm-b" result.sent_to);
      check bool "sender excluded from sent_to" false
        (List.mem "storm-sender" result.sent_to);
      check int "no one skipped" 0 (List.length result.skipped);
      let inbox_a =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      let inbox_sender =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-sender"
      in
      check int "storm-a inbox has one message" 1 (List.length inbox_a);
      check int "storm-b inbox has one message" 1 (List.length inbox_b);
      check int "sender inbox untouched" 0 (List.length inbox_sender);
      let msg = List.hd inbox_a in
      check string "content preserved" "hello everyone" msg.content;
      check string "from_alias stamped" "storm-sender" msg.from_alias;
      check string "to_alias per-recipient" "storm-a" msg.to_alias)

let test_send_all_honors_exclude_aliases () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-sender" ~alias:"storm-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-a" ~alias:"storm-a"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-b" ~alias:"storm-b"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-c" ~alias:"storm-c"
        ~pid:None ~pid_start_time:None ();
      let result =
        C2c_mcp.Broker.send_all broker
          ~from_alias:"storm-sender"
          ~content:"targeted broadcast"
          ~exclude_aliases:[ "storm-b" ]
      in
      check int "two recipients (b excluded)" 2 (List.length result.sent_to);
      check bool "storm-a delivered" true
        (List.mem "storm-a" result.sent_to);
      check bool "storm-c delivered" true
        (List.mem "storm-c" result.sent_to);
      check bool "storm-b skipped by exclude" false
        (List.mem "storm-b" result.sent_to);
      check int "excluded alias not in skipped list" 0
        (List.length result.skipped);
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      check int "storm-b inbox untouched" 0 (List.length inbox_b))

let test_send_all_skips_dead_recipients_with_reason () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-sender" ~alias:"storm-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"storm-dead"
        ~pid:(Some dead) ~pid_start_time:None ();
      let result =
        C2c_mcp.Broker.send_all broker
          ~from_alias:"storm-sender"
          ~content:"status ping"
          ~exclude_aliases:[]
      in
      check int "one live recipient" 1 (List.length result.sent_to);
      check string "live recipient is storm-live"
        "storm-live" (List.hd result.sent_to);
      check int "one skipped" 1 (List.length result.skipped);
      let alias, reason = List.hd result.skipped in
      check string "skipped alias is storm-dead" "storm-dead" alias;
      check string "skip reason is not_alive" "not_alive" reason;
      let inbox_dead =
        try C2c_mcp.Broker.read_inbox broker ~session_id:"session-dead"
        with _ -> []
      in
      check int "dead inbox untouched" 0 (List.length inbox_dead))

let test_send_all_sender_only_registry_returns_empty_result () =
  (* Edge case: the sender is the only registered peer. send_all
     should return sent_to=[], skipped=[] without error and without
     writing to any inbox file. Guards against a regression where the
     "skip sender" branch might instead fall through to the Unknown
     or Dead path. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-alone" ~alias:"solo"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let result =
        C2c_mcp.Broker.send_all broker
          ~from_alias:"solo"
          ~content:"hello to no one"
          ~exclude_aliases:[]
      in
      check int "no recipients" 0 (List.length result.sent_to);
      check int "no skipped" 0 (List.length result.skipped);
      let own_inbox =
        try C2c_mcp.Broker.read_inbox broker ~session_id:"session-alone"
        with _ -> []
      in
      check int "sender did not receive own broadcast" 0
        (List.length own_inbox))

let test_sweep_empty_orphan_writes_no_dead_letter () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      write_file (Filename.concat dir "empty-orphan.inbox.json") "[]";
      let result = C2c_mcp.Broker.sweep broker in
      check int "one orphan deleted" 1 (List.length result.deleted_inboxes);
      check int "no messages preserved" 0 result.preserved_messages;
      let dead_letter = C2c_mcp.Broker.dead_letter_path broker in
      check bool "no dead-letter noise for empty orphan" false
        (Sys.file_exists dead_letter))

(* Provisional sweep: a pid=None, confirmed_at=None reg with a recent registered_at
   is NOT swept until the timeout has elapsed. *)
let test_sweep_preserves_fresh_provisional_reg () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register with pid=None — no PID, no confirmed_at yet (provisional).
         registered_at defaults to now (fresh). Default timeout is 1800s.
         Sweep should NOT drop this — it hasn't timed out. *)
      C2c_mcp.Broker.register broker
        ~session_id:"prov-session" ~alias:"storm-prov"
        ~pid:None ~pid_start_time:None ();
      let result = C2c_mcp.Broker.sweep broker in
      check int "fresh provisional not dropped" 0 (List.length result.dropped_regs);
      check int "provisional still registered" 1
        (List.length (C2c_mcp.Broker.list_registrations broker)))

(* Provisional sweep: a pid=None, confirmed_at=None reg with a registered_at
   older than the timeout IS swept. *)
let test_sweep_drops_expired_provisional_reg () =
  with_temp_dir (fun dir ->
      (* Write a registry JSON with a registered_at 3601 seconds in the past.
         Default timeout is 1800s — this should be swept. *)
      let expired_ts = Unix.gettimeofday () -. 3601.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"prov-expired","alias":"storm-expired","registered_at":%f}]|}
          expired_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      Unix.putenv "C2C_PROVISIONAL_SWEEP_TIMEOUT" "1800";
      let result = C2c_mcp.Broker.sweep broker in
      Unix.putenv "C2C_PROVISIONAL_SWEEP_TIMEOUT" "1800";
      check int "expired provisional dropped" 1 (List.length result.dropped_regs);
      check int "no regs remain" 0
        (List.length (C2c_mcp.Broker.list_registrations broker)))

(* confirm_registration: first poll_inbox sets confirmed_at; subsequent calls are no-ops. *)
let test_confirm_registration_sets_confirmed_at () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"conf-session" ~alias:"storm-conf"
        ~pid:None ~pid_start_time:None ();
      let before = C2c_mcp.Broker.list_registrations broker in
      check bool "confirmed_at is None before poll"
        true ((List.hd before).confirmed_at = None);
      C2c_mcp.Broker.confirm_registration broker ~session_id:"conf-session";
      let after = C2c_mcp.Broker.list_registrations broker in
      check bool "confirmed_at is Some after confirm"
        true ((List.hd after).confirmed_at <> None);
      (* Idempotent: second call doesn't change the timestamp *)
      let ts1 = (List.hd after).confirmed_at in
      C2c_mcp.Broker.confirm_registration broker ~session_id:"conf-session";
      let after2 = C2c_mcp.Broker.list_registrations broker in
      check bool "confirmed_at unchanged on second confirm"
        true ((List.hd after2).confirmed_at = ts1))

(* confirm_registration: confirmed session is NOT swept even after timeout. *)
let test_confirmed_reg_not_swept_after_timeout () =
  with_temp_dir (fun dir ->
      (* Write a registry JSON: registered_at expired, but confirmed_at is set. *)
      let expired_ts = Unix.gettimeofday () -. 3601.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"conf-old","alias":"storm-confirmed-old","registered_at":%f,"confirmed_at":%f}]|}
          expired_ts expired_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      (* confirmed_at means it's no longer provisional — sweep should NOT drop it *)
      check int "confirmed (but old) reg not dropped" 0 (List.length result.dropped_regs))

(* client_type=human: exempted from provisional sweep even with expired registered_at. *)
let test_human_client_type_exempt_from_provisional_sweep () =
  with_temp_dir (fun dir ->
      let expired_ts = Unix.gettimeofday () -. 3601.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"human-session","alias":"storm-human","registered_at":%f,"client_type":"human"}]|}
          expired_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "human client_type not swept" 0 (List.length result.dropped_regs))

let test_sweep_evicts_dead_members_from_rooms () =
  (* When sweep drops a dead registration, evict_dead_from_rooms should
     also remove that session from any rooms it was in, so room member
     lists don't accumulate stale entries forever. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register two sessions: one live (current proc), one dead (bogus pid
         that certainly isn't alive — pid:None is treated as alive for
         backward-compat, so we use a large impossible pid instead). *)
      C2c_mcp.Broker.register broker
        ~session_id:"session-alive" ~alias:"storm-alive"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-ghost" ~alias:"storm-ghost"
        ~pid:(Some 999999999) ~pid_start_time:None ();
      (* Both join swarm-lounge *)
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"storm-alive" ~session_id:"session-alive");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"storm-ghost" ~session_id:"session-ghost");
      let members_before =
        C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
      in
      check int "two members before sweep" 2 (List.length members_before);
      (* Sweep: session-ghost has no pid → dead registration *)
      let { C2c_mcp.Broker.dropped_regs; _ } = C2c_mcp.Broker.sweep broker in
      check int "one dropped registration" 1 (List.length dropped_regs);
      let dead_sids = List.map (fun r -> r.C2c_mcp.session_id) dropped_regs in
      let dead_aliases = List.map (fun r -> r.C2c_mcp.alias) dropped_regs in
      (* Evict dead members from rooms *)
      let evicted =
        C2c_mcp.Broker.evict_dead_from_rooms broker ~dead_session_ids:dead_sids
          ~dead_aliases
      in
      check int "one member evicted" 1 (List.length evicted);
      let (evicted_room, evicted_alias) = List.hd evicted in
      check string "evicted from correct room" "swarm-lounge" evicted_room;
      check string "evicted the ghost alias" "storm-ghost" evicted_alias;
      (* Room now has only the live member *)
      let members_after =
        C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
      in
      check int "one member after eviction" 1 (List.length members_after);
      check string "remaining member is alive" "storm-alive"
        (List.hd members_after).C2c_mcp.rm_alias)

let test_prune_rooms_evicts_dead_members_without_touching_registrations () =
  (* prune_rooms should evict dead room members but NOT drop registrations or
     touch inboxes. Unlike sweep, safe to call while outer loops run. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s-alive" ~alias:"alive-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"s-dead" ~alias:"dead-peer"
        ~pid:(Some 999999999) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"alive-peer" ~session_id:"s-alive");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"dead-peer" ~session_id:"s-dead");
      let evicted = C2c_mcp.Broker.prune_rooms broker in
      check int "one member evicted" 1 (List.length evicted);
      let (evicted_room, evicted_alias) = List.hd evicted in
      check string "evicted from swarm-lounge" "swarm-lounge" evicted_room;
      check string "evicted dead-peer alias" "dead-peer" evicted_alias;
      (* Both registrations must still be present — prune_rooms must not drop them *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "both registrations still present" 2 (List.length regs);
      let members =
        C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
      in
      check int "one room member remaining" 1 (List.length members);
      check string "remaining is alive-peer" "alive-peer"
        (List.hd members).C2c_mcp.rm_alias)

let test_prune_rooms_noop_when_all_members_alive () =
  (* When all registered members are alive, prune_rooms returns an empty list. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s-alive" ~alias:"alive-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"alive-peer" ~session_id:"s-alive");
      let evicted = C2c_mcp.Broker.prune_rooms broker in
      check int "no members evicted when all alive" 0 (List.length evicted))

let test_tools_call_prune_rooms_via_mcp () =
  (* End-to-end: prune_rooms MCP tool evicts dead room members and returns them. *)
  with_temp_dir (fun dir ->
      let broker_root = dir in
      let broker = C2c_mcp.Broker.create ~root:broker_root in
      C2c_mcp.Broker.register broker
        ~session_id:"s-alive" ~alias:"alive-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"s-dead" ~alias:"dead-peer"
        ~pid:(Some 999999999) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"alive-peer" ~session_id:"s-alive");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"dead-peer" ~session_id:"s-dead");
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "prune_rooms")
                ; ("arguments", `Assoc [])
                ] )
          ]
      in
      let resp_opt =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root request)
      in
      (match resp_opt with
       | None -> check bool "expected a response" true false
       | Some resp ->
           let open Yojson.Safe.Util in
           let result_text =
             resp |> member "result" |> member "content"
             |> index 0 |> member "text" |> to_string
           in
           let result = Yojson.Safe.from_string result_text in
           let evicted =
             result |> member "evicted_room_members" |> to_list
           in
           check int "one eviction via MCP prune_rooms" 1 (List.length evicted)))

let test_prune_rooms_evicts_pidless_zombie_members () =
  (* prune_rooms must treat pid=None registrations (Unknown liveness) as
     evictable.  registration_is_alive returns true for pid=None for backward-
     compat, but these pidless rows cannot be verified alive and their inboxes
     accumulate dead fan-out messages — they should be removed from rooms. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Alive member: current pid, no pid_start_time *)
      C2c_mcp.Broker.register broker
        ~session_id:"s-alive" ~alias:"alive-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* Pidless zombie: no pid at all — legacy registration *)
      C2c_mcp.Broker.register broker
        ~session_id:"s-zombie" ~alias:"zombie-peer"
        ~pid:None ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"alive-peer" ~session_id:"s-alive");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"zombie-peer" ~session_id:"s-zombie");
      let evicted = C2c_mcp.Broker.prune_rooms broker in
      check int "pidless zombie evicted from room" 1 (List.length evicted);
      let (evicted_room, evicted_alias) = List.hd evicted in
      check string "evicted from swarm-lounge" "swarm-lounge" evicted_room;
      check string "evicted zombie-peer alias" "zombie-peer" evicted_alias;
      (* Both registrations still present — prune_rooms only touches room membership *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "both registrations still present" 2 (List.length regs);
      let members =
        C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
      in
      check int "one room member remaining" 1 (List.length members);
      check string "remaining member is alive-peer" "alive-peer"
        (List.hd members).C2c_mcp.rm_alias)

let test_liveness_unverified_pid_shows_unknown () =
  (* pid=Some live_pid, pid_start_time=None must show alive=null (Unknown),
     NOT alive=true. The ghost-alive bug: if the original process dies and the
     PID is reused, we can't tell — so we return Unknown rather than Alive.
     The list tool must expose this as null, not true. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let live_pid = Unix.getpid () in
      C2c_mcp.Broker.register broker
        ~session_id:"s-unverified" ~alias:"unverified-peer"
        ~pid:(Some live_pid) ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      let reg = List.find (fun r -> r.C2c_mcp.alias = "unverified-peer") regs in
      (match C2c_mcp.Broker.registration_liveness_state reg with
       | C2c_mcp.Broker.Unknown -> ()
       | C2c_mcp.Broker.Alive ->
           fail "pid+no_start_time must return Unknown, not Alive (ghost-alive bug)"
       | C2c_mcp.Broker.Dead ->
           fail "pid+no_start_time with live proc must not return Dead"))

let test_prune_rooms_keeps_unverified_pid_member () =
  (* prune_rooms must NOT evict a session with pid=Some live_pid, pid_start_time=None.
     Unknown-with-live-pid is conservative: process may be alive; don't evict.
     Only Unknown with pid=None (true pidless zombie) gets evicted. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s-unverified" ~alias:"unverified-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"unverified-peer" ~session_id:"s-unverified");
      let evicted = C2c_mcp.Broker.prune_rooms broker in
      check int "unverified-pid member must NOT be evicted" 0 (List.length evicted))

let test_prune_rooms_evicts_orphan_room_members () =
  (* prune_rooms should also evict room members whose registration row is
     already gone.  list_rooms reports these as dead, so prune_rooms must not
     depend only on the current registry's dead aliases/session IDs. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s-alive" ~alias:"alive-peer"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"alive-peer" ~session_id:"s-alive");
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"orphan-peer" ~session_id:"s-orphan");
      let evicted = C2c_mcp.Broker.prune_rooms broker in
      check int "orphan member evicted from room" 1 (List.length evicted);
      let (evicted_room, evicted_alias) = List.hd evicted in
      check string "evicted from swarm-lounge" "swarm-lounge" evicted_room;
      check string "evicted orphan-peer alias" "orphan-peer" evicted_alias;
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "live registration still present" 1 (List.length regs);
      let members =
        C2c_mcp.Broker.read_room_members broker ~room_id:"swarm-lounge"
      in
      check int "one room member remaining" 1 (List.length members);
      check string "remaining member is alive-peer" "alive-peer"
        (List.hd members).C2c_mcp.rm_alias)

let test_register_redelivers_dead_letter_on_same_session_id () =
  (* Scenario: a managed session (e.g. kimi-local) is swept while the outer
     loop is between iterations — PID dead, no live process. Messages queued to
     it go to dead-letter with from_session_id = the swept session_id.  When the
     outer loop restarts and calls register with the SAME session_id (stable
     alias-based ID via C2C_MCP_SESSION_ID=kimi-local), the broker should drain
     those dead-letter records and re-queue them into the inbox. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Write dead-letter records for kimi-local's session_id, simulating what
         sweep would produce after sweeping its inbox. *)
      let dead_letter = C2c_mcp.Broker.dead_letter_path broker in
      let dl_record content =
        Printf.sprintf
          {|{"from_session_id":"kimi-local","deleted_at":1712345678.0,"message":{"from_alias":"storm-beacon","to_alias":"kimi-local","content":"%s"}}|}
          content
      in
      write_file dead_letter
        (dl_record "msg-one" ^ "\n" ^ dl_record "msg-two" ^ "\n");
      (* Pre-create an empty inbox (sweep leaves behind an empty file) *)
      let inbox_path = Filename.concat dir "kimi-local.inbox.json" in
      write_file inbox_path "[]";
      (* Re-register with the same session_id — this is the managed restart *)
      Unix.putenv "C2C_MCP_SESSION_ID" "kimi-local";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 500)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments",
                       `Assoc [ ("alias", `String "kimi-local") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected register response"
           | Some _ -> ());
          (* Poll inbox — must contain the two recovered messages *)
          let broker2 = C2c_mcp.Broker.create ~root:dir in
          let drained =
            C2c_mcp.Broker.drain_inbox broker2 ~session_id:"kimi-local"
          in
          check int "two messages recovered from dead-letter" 2
            (List.length drained);
          let contents =
            List.map (fun m -> m.C2c_mcp.content) drained
          in
          check bool "msg-one recovered" true (List.mem "msg-one" contents);
          check bool "msg-two recovered" true (List.mem "msg-two" contents);
          (* Dead-letter file should be empty after redelivery *)
          let dead_letter_lines =
            try
              let ic = open_in dead_letter in
              Fun.protect
                ~finally:(fun () -> close_in ic)
                (fun () ->
                  let buf = ref [] in
                  (try
                     while true do
                       let l = String.trim (input_line ic) in
                       if l <> "" then buf := l :: !buf
                     done
                   with End_of_file -> ());
                  !buf)
            with _ -> []
          in
          check int "dead-letter cleared after redelivery" 0
            (List.length dead_letter_lines);
          ignore inbox_path))

let test_register_redelivers_dead_letter_by_alias_for_new_session_id () =
  (* Claude Code gets a fresh CLAUDE_SESSION_ID on every restart but keeps the
     same C2C_MCP_AUTO_REGISTER_ALIAS. Dead-letter records store the swept
     session's from_session_id (the OLD id), so a session_id match won't fire.
     The alias-based fallback (message.to_alias == alias) should recover those
     messages when the agent re-registers under the same alias. *)
  with_temp_dir (fun dir ->
      (* Write dead-letter records addressed to alias "storm-beacon" but from
         OLD session_id "old-claude-session-uuid". A new session
         "new-claude-session-uuid" registers as the same alias. *)
      let broker = C2c_mcp.Broker.create ~root:dir in
      let dead_letter = C2c_mcp.Broker.dead_letter_path broker in
      let dl_record content =
        (* from_session_id is the OLD session that was swept *)
        Printf.sprintf
          {|{"from_session_id":"old-claude-session-uuid","deleted_at":1712345678.0,"message":{"from_alias":"codex","to_alias":"storm-beacon","content":"%s"}}|}
          content
      in
      write_file dead_letter
        (dl_record "claude-msg-a" ^ "\n" ^ dl_record "claude-msg-b" ^ "\n");
      (* Register the NEW session under the same alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "new-claude-session-uuid";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 501)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ("arguments",
                       `Assoc [ ("alias", `String "storm-beacon") ])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected register response"
           | Some _ -> ());
          (* New session's inbox should contain the redelivered messages *)
          let broker2 = C2c_mcp.Broker.create ~root:dir in
          let drained =
            C2c_mcp.Broker.drain_inbox broker2
              ~session_id:"new-claude-session-uuid"
          in
          check int "two messages recovered via alias match" 2
            (List.length drained);
          let contents = List.map (fun m -> m.C2c_mcp.content) drained in
          check bool "claude-msg-a recovered" true
            (List.mem "claude-msg-a" contents);
          check bool "claude-msg-b recovered" true
            (List.mem "claude-msg-b" contents);
          (* Dead-letter should be cleared *)
          let dead_letter_lines =
            try
              let ic = open_in dead_letter in
              Fun.protect
                ~finally:(fun () -> close_in ic)
                (fun () ->
                  let buf = ref [] in
                  (try
                     while true do
                       let l = String.trim (input_line ic) in
                       if l <> "" then buf := l :: !buf
                     done
                   with End_of_file -> ());
                  !buf)
            with _ -> []
          in
          check int "dead-letter cleared after alias-based redelivery" 0
            (List.length dead_letter_lines)))

(* ---------- N:N rooms (phase 2) tests ---------- *)

let test_join_room_creates_room_and_adds_member () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      check int "one member after join" 1 (List.length members);
      let m = List.hd members in
      check string "member alias" "storm-ember" m.rm_alias;
      check string "member session_id" "session-a" m.rm_session_id;
      check bool "joined_at is positive" true (m.joined_at > 0.0);
      (* Verify the room dir and members.json were created on disk. *)
      let members_path =
        Filename.concat (Filename.concat (Filename.concat dir "rooms") "lobby") "members.json"
      in
      check bool "members.json exists" true (Sys.file_exists members_path))

let test_join_room_is_idempotent () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      check int "still one member after duplicate join" 1 (List.length members);
      check string "alias unchanged" "storm-ember" (List.hd members).rm_alias)

let test_join_room_broadcasts_system_message_to_all_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      (* Confirm both sessions so they are non-provisional and join broadcasts fire *)
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-a";
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-b";
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"alice" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"bob" ~session_id:"session-b"
      in
      let inbox_a =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      check int "existing member receives join broadcast" 1 (List.length inbox_a);
      check int "joining member receives join broadcast" 1 (List.length inbox_b);
      let msg_a = List.hd inbox_a in
      let msg_b = List.hd inbox_b in
      check string "system sender to existing member" "c2c-system"
        msg_a.from_alias;
      check string "system sender to joining member" "c2c-system"
        msg_b.from_alias;
      check string "existing member tagged to room" "alice#lobby"
        msg_a.to_alias;
      check string "joining member tagged to room" "bob#lobby"
        msg_b.to_alias;
      check string "join broadcast content" "bob joined room lobby"
        msg_a.content;
      check string "same join content to joining member" msg_a.content
        msg_b.content;
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"lobby" ~limit:10 ()
      in
      check int "two join events in history" 2 (List.length history);
      let last = List.hd (List.rev history) in
      check string "history system sender" "c2c-system" last.rm_from_alias;
      check string "history join content" "bob joined room lobby"
        last.rm_content)

let test_join_room_idempotent_does_not_rebroadcast () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-a";
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"alice" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"alice" ~session_id:"session-a"
      in
      let inbox =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      check int "duplicate join does not enqueue another system message" 0
        (List.length inbox);
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"lobby" ~limit:10 ()
      in
      check int "duplicate join does not append another history entry" 1
        (List.length history))

let test_join_room_idempotent_non_tail_member_does_not_rebroadcast () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-a";
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-b";
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"alice" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"bob" ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b"
      in
      let before =
        C2c_mcp.Broker.read_room_history broker ~room_id:"lobby" ~limit:10 ()
      in
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"alice" ~session_id:"session-a"
      in
      check int "same members after duplicate non-tail join" 2
        (List.length members);
      let inbox_a =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      check int "non-tail duplicate does not notify rejoining member" 0
        (List.length inbox_a);
      check int "non-tail duplicate does not notify other member" 0
        (List.length inbox_b);
      let after =
        C2c_mcp.Broker.read_room_history broker ~room_id:"lobby" ~limit:10 ()
      in
      check int "non-tail duplicate does not append history"
        (List.length before) (List.length after))

let test_leave_room_removes_member () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      let members =
        C2c_mcp.Broker.leave_room broker ~room_id:"lobby" ~alias:"storm-ember"
      in
      check int "empty after leave" 0 (List.length members))

let test_delete_room_succeeds_when_empty () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Join then leave to create an empty room *)
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"tmp-room"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"tmp-room" ~alias:"storm-ember"
      in
      (* delete_room should succeed on an empty room *)
      C2c_mcp.Broker.delete_room broker ~room_id:"tmp-room";
      (* Room should no longer appear in list *)
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check int "room deleted" 0 (List.length rooms))

let test_delete_room_fails_when_has_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"lobby"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      (* delete_room should raise Invalid_argument *)
      check_raises "cannot delete room with members"
        (Invalid_argument "cannot delete room with members: lobby")
        (fun () -> C2c_mcp.Broker.delete_room broker ~room_id:"lobby"))

let test_send_room_appends_history_and_fans_out () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register both aliases so they have live inboxes. *)
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-a";
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-b";
      (* Both join the room. *)
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"storm-storm" ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b"
      in
      (* storm-ember sends a message. *)
      let result =
        C2c_mcp.Broker.send_room broker ~from_alias:"storm-ember"
          ~room_id:"chat" ~content:"hello room"
      in
      check int "delivered to one peer" 1
        (List.length result.sr_delivered_to);
      check string "delivered to storm-storm" "storm-storm"
        (List.hd result.sr_delivered_to);
      check bool "ts is positive" true (result.sr_ts > 0.0);
      (* Verify history.jsonl *)
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"chat" ~limit:50 ()
      in
      check int "two join entries plus one room message" 3
        (List.length history);
      let h = List.hd (List.rev history) in
      check string "history from_alias" "storm-ember" h.rm_from_alias;
      check string "history content" "hello room" h.rm_content;
      (* Verify the fan-out inbox message *)
      let inbox_b =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-b"
      in
      check int "one inbox message for storm-storm" 1 (List.length inbox_b);
      let msg = List.hd inbox_b in
      check string "inbox from_alias" "storm-ember" msg.from_alias;
      check string "inbox to_alias tagged" "storm-storm#chat" msg.to_alias;
      check string "inbox content" "hello room" msg.content)

let test_send_room_skips_sender_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"storm-ember" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"storm-storm" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"storm-ember" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"storm-storm" ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.send_room broker ~from_alias:"storm-ember"
          ~room_id:"chat" ~content:"echo test"
      in
      let inbox_a =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-a"
      in
      check int "sender inbox is empty" 0 (List.length inbox_a))

let test_send_room_deduplicates_identical_content_within_window () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"receiver" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"sender" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"receiver" ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b"
      in
      (* Send the same content twice in quick succession *)
      let r1 =
        C2c_mcp.Broker.send_room broker ~from_alias:"sender"
          ~room_id:"chat" ~content:"online — inbox drained"
      in
      let r2 =
        C2c_mcp.Broker.send_room broker ~from_alias:"sender"
          ~room_id:"chat" ~content:"online — inbox drained"
      in
      (* First send should fan out; second should be suppressed *)
      check int "first send delivered to 1" 1 (List.length r1.sr_delivered_to);
      check int "second send suppressed (delivered_to empty)" 0 (List.length r2.sr_delivered_to);
      (* Receiver inbox has exactly one message, not two *)
      let inbox_b = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "receiver has 1 message (dedup)" 1 (List.length inbox_b);
      (* Room history also has exactly one entry *)
      let history = C2c_mcp.Broker.read_room_history broker ~room_id:"chat" ~limit:10 () in
      let sender_messages =
        List.filter
          (fun (m : C2c_mcp.room_message) -> m.rm_from_alias = "sender")
          history
      in
      check int "room history has 1 sender entry (dedup)" 1
        (List.length sender_messages))

let test_send_room_does_not_dedup_different_content () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"receiver" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"sender" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"receiver" ~session_id:"session-b"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.drain_inbox broker ~session_id:"session-b"
      in
      let r1 =
        C2c_mcp.Broker.send_room broker ~from_alias:"sender"
          ~room_id:"chat" ~content:"message one"
      in
      let r2 =
        C2c_mcp.Broker.send_room broker ~from_alias:"sender"
          ~room_id:"chat" ~content:"message two"
      in
      check int "first send delivered" 1 (List.length r1.sr_delivered_to);
      check int "second send (different content) delivered" 1 (List.length r2.sr_delivered_to);
      let history = C2c_mcp.Broker.read_room_history broker ~room_id:"chat" ~limit:10 () in
      let sender_messages =
        List.filter
          (fun (m : C2c_mcp.room_message) -> m.rm_from_alias = "sender")
          history
      in
      check int "room history has 2 sender entries" 2
        (List.length sender_messages))

let test_list_rooms_returns_room_with_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-alice" ~alias:"alice"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob" ~alias:"bob"
        ~pid:(Some 999999999) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-carol" ~alias:"carol"
        ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-alpha"
          ~alias:"alice" ~session_id:"s-alice"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-alpha"
          ~alias:"bob" ~session_id:"s-bob"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-beta"
          ~alias:"carol" ~session_id:"s-carol"
      in
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check int "two rooms" 2 (List.length rooms);
      let find_room rid =
        List.find (fun (r : C2c_mcp.Broker.room_info) -> r.ri_room_id = rid) rooms
      in
      let alpha = find_room "room-alpha" in
      let beta = find_room "room-beta" in
      check int "room-alpha has 2 members" 2 alpha.ri_member_count;
      check bool "room-alpha contains alice" true
        (List.mem "alice" alpha.ri_members);
      check bool "room-alpha contains bob" true
        (List.mem "bob" alpha.ri_members);
      check int "room-alpha has 1 alive member" 1 alpha.ri_alive_member_count;
      check int "room-alpha has 1 dead member" 1 alpha.ri_dead_member_count;
      check int "room-alpha has no unknown members" 0 alpha.ri_unknown_member_count;
      check int "room-beta has 1 member" 1 beta.ri_member_count;
      check int "room-beta has 1 unknown member" 1 beta.ri_unknown_member_count;
      check bool "room-beta contains carol" true
        (List.mem "carol" beta.ri_members))

let test_room_history_returns_last_n_lines () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* We need the room dir to exist for append_room_history. *)
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"chat"
          ~alias:"sender" ~session_id:"s"
      in
      for i = 1 to 10 do
        ignore
          (C2c_mcp.Broker.append_room_history broker ~room_id:"chat"
             ~from_alias:"sender"
             ~content:(Printf.sprintf "msg-%d" i))
      done;
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"chat" ~limit:3 ()
      in
      check int "limit 3 returns 3" 3 (List.length history);
      (* Should be the last 3: msg-8, msg-9, msg-10 *)
      check string "first of last 3" "msg-8"
        (List.nth history 0).rm_content;
      check string "second of last 3" "msg-9"
        (List.nth history 1).rm_content;
      check string "third of last 3" "msg-10"
        (List.nth history 2).rm_content)

let test_room_history_empty_room () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"empty-chat" ~limit:50 ()
      in
      check int "empty room has no history" 0 (List.length history))

let test_tools_call_join_room_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-mcp-room";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 100)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "join_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "mcp-lobby")
                          ; ("alias", `String "storm-mcp")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected join_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              check string "room_id in response" "mcp-lobby"
                (parsed |> member "room_id" |> to_string);
              let members = parsed |> member "members" |> to_list in
              check int "one member" 1 (List.length members);
              check string "member alias" "storm-mcp"
                (List.hd members |> member "alias" |> to_string);
              check string "member session_id" "session-mcp-room"
                (List.hd members |> member "session_id" |> to_string);
              let history = parsed |> member "history" |> to_list in
              check int "join response includes system join history" 1
                (List.length history);
              check string "join history sender" "c2c-system"
                (List.hd history |> member "from_alias" |> to_string);
              check string "join history content" "storm-mcp joined room mcp-lobby"
                (List.hd history |> member "content" |> to_string)))

let test_tools_call_join_room_backfills_recent_history () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-latecomer";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          (* First member joins and seeds three messages into history. *)
          C2c_mcp.Broker.register broker ~session_id:"session-firstmember"
            ~alias:"first-member" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.confirm_registration broker ~session_id:"session-firstmember";
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"backfill-room"
              ~alias:"first-member" ~session_id:"session-firstmember"
          in
          let _ =
            C2c_mcp.Broker.append_room_history broker
              ~room_id:"backfill-room" ~from_alias:"first-member"
              ~content:"msg one"
          in
          let _ =
            C2c_mcp.Broker.append_room_history broker
              ~room_id:"backfill-room" ~from_alias:"first-member"
              ~content:"msg two"
          in
          let _ =
            C2c_mcp.Broker.append_room_history broker
              ~room_id:"backfill-room" ~from_alias:"first-member"
              ~content:"msg three"
          in
          (* Latecomer joins via MCP tools/call. *)
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 211)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "join_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "backfill-room")
                          ; ("alias", `String "latecomer")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected join_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              let history = parsed |> member "history" |> to_list in
              check int "backfill returned prior history plus join notices" 5
                (List.length history);
              let contents =
                List.map (fun m -> m |> member "content" |> to_string) history
              in
              check bool "history contains msg one" true
                (List.mem "msg one" contents);
              check bool "history contains msg three" true
                (List.mem "msg three" contents);
              check string "first entry preserves order" "first-member joined room backfill-room"
                (List.hd history |> member "content" |> to_string);
              check string "last entry is latecomer join" "latecomer joined room backfill-room"
                (List.hd (List.rev history) |> member "content" |> to_string)))

let test_tools_call_peek_inbox_does_not_drain () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-peeker";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-peeker"
            ~alias:"peeker" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"peeker" ~content:"first" ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"peeker" ~content:"second" ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 400)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "peek_inbox")
                    ; ("arguments", `Assoc []) ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected peek_inbox response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let messages = parsed |> to_list in
               check int "peek returns both messages" 2
                 (List.length messages);
               check string "first content preserved" "first"
                 (List.hd messages |> member "content" |> to_string));
          (* After peek, a real poll_inbox still finds both messages. *)
          let still = C2c_mcp.Broker.read_inbox broker ~session_id:"session-peeker" in
          check int "inbox still has both messages after peek" 2
            (List.length still)))

let test_tools_call_peek_inbox_ignores_session_id_argument () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-self";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-self"
            ~alias:"self" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-victim"
            ~alias:"victim" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender"
            ~to_alias:"victim" ~content:"secret for victim only" ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 401)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "peek_inbox")
                    ; ( "arguments",
                        `Assoc
                          [ ("session_id", `String "session-victim") ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected peek_inbox response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              let messages = parsed |> to_list in
              check int "peek returns caller's empty inbox, not victim's" 0
                (List.length messages)))

let test_my_rooms_returns_only_sessions_memberships () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-me"
        ~alias:"me-alias" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-other"
        ~alias:"other-alias" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-one"
          ~alias:"me-alias" ~session_id:"session-me"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-two"
          ~alias:"me-alias" ~session_id:"session-me"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"room-three"
          ~alias:"other-alias" ~session_id:"session-other"
      in
      let mine = C2c_mcp.Broker.my_rooms broker ~session_id:"session-me" in
      let ids =
        List.map (fun (r : C2c_mcp.Broker.room_info) -> r.ri_room_id) mine
        |> List.sort compare
      in
      check (list string) "only my rooms returned"
        [ "room-one"; "room-two" ]
        ids;
      let theirs =
        C2c_mcp.Broker.my_rooms broker ~session_id:"session-other"
      in
      check int "other session has only their room" 1 (List.length theirs))

let test_tools_call_my_rooms_uses_env_session_id () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-env";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-env"
            ~alias:"env-me" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-victim"
            ~alias:"victim" ~pid:None ~pid_start_time:None ();
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"visible-to-env"
              ~alias:"env-me" ~session_id:"session-env"
          in
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"visible-to-victim"
              ~alias:"victim" ~session_id:"session-victim"
          in
          (* Call my_rooms with a bogus session_id argument — must be
             ignored; caller only sees rooms for session-env. *)
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 300)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "my_rooms")
                    ; ( "arguments",
                        `Assoc
                          [ ("session_id", `String "session-victim") ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected my_rooms response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              let rooms = parsed |> to_list in
              check int "my_rooms returns exactly one room for env session" 1
                (List.length rooms);
              check string "room_id is env's own room" "visible-to-env"
                (List.hd rooms |> member "room_id" |> to_string)))

let test_tools_call_join_room_respects_history_limit_zero () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-optout";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-seed"
            ~alias:"seed-member" ~pid:None ~pid_start_time:None ();
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"quiet-room"
              ~alias:"seed-member" ~session_id:"session-seed"
          in
          let _ =
            C2c_mcp.Broker.append_room_history broker
              ~room_id:"quiet-room" ~from_alias:"seed-member"
              ~content:"private chatter"
          in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 212)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "join_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "quiet-room")
                          ; ("alias", `String "optout")
                          ; ("history_limit", `Int 0)
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected join_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              let parsed = Yojson.Safe.from_string text in
              let history = parsed |> member "history" |> to_list in
              check int "history_limit=0 skips backfill entirely" 0
                (List.length history)))

let test_tools_call_send_room_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-sender-room";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          (* Register two aliases. *)
          C2c_mcp.Broker.register broker ~session_id:"session-sender-room"
            ~alias:"storm-sender" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-recv-room"
            ~alias:"storm-recv" ~pid:None ~pid_start_time:None ();
          (* Both join the room. *)
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"mcp-chat"
              ~alias:"storm-sender" ~session_id:"session-sender-room"
          in
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"mcp-chat"
              ~alias:"storm-recv" ~session_id:"session-recv-room"
          in
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-sender-room");
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-recv-room");
          (* Send via MCP tools/call. *)
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 101)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "storm-sender")
                          ; ("room_id", `String "mcp-chat")
                          ; ("content", `String "hello via mcp room")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected send_room response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let delivered =
                 parsed |> member "delivered_to" |> to_list |> List.map to_string
               in
               check int "one delivery" 1 (List.length delivered);
               check string "delivered to storm-recv" "storm-recv"
                 (List.hd delivered);
               check bool "ts is positive" true
                 (parsed |> member "ts" |> to_number > 0.0));
          (* Verify the recipient's inbox got the tagged message. *)
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-recv-room"
          in
          check int "recipient inbox has one message" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "from_alias" "storm-sender" msg.from_alias;
          check string "to_alias tagged" "storm-recv#mcp-chat" msg.to_alias;
          check string "content" "hello via mcp room" msg.content))

(* Regression: OpenCode's backing model substitutes `alias` for
   `from_alias` when calling send_room (because join_room uses
   `alias`). The broker must accept either key so the three-way
   (Claude Code + Codex + OpenCode) chat actually works. *)
let test_tools_call_send_room_accepts_alias_as_from_alias_alias () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-sender-alias";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-sender-alias"
            ~alias:"storm-sender" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-recv-alias"
            ~alias:"storm-recv" ~pid:None ~pid_start_time:None ();
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"alias-chat"
              ~alias:"storm-sender" ~session_id:"session-sender-alias"
          in
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"alias-chat"
              ~alias:"storm-recv" ~session_id:"session-recv-alias"
          in
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-sender-alias");
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-recv-alias");
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 202)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_room")
                    ; ( "arguments",
                        `Assoc
                          [ (* Note: `alias` not `from_alias` —
                               this is the opencode substitution. *)
                            ("alias", `String "storm-sender")
                          ; ("room_id", `String "alias-chat")
                          ; ("content", `String "hello via alias fallback")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected send_room response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let delivered =
                 parsed |> member "delivered_to" |> to_list |> List.map to_string
               in
               check int "one delivery via alias fallback" 1
                 (List.length delivered);
               check string "delivered to storm-recv" "storm-recv"
                 (List.hd delivered));
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-recv-alias"
          in
          check int "recipient inbox has one message" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "from_alias resolved from alias fallback"
            "storm-sender" msg.from_alias;
          check string "content" "hello via alias fallback" msg.content))

let test_tools_call_send_room_uses_current_session_alias_when_omitted () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-sender-current";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-sender-current"
            ~alias:"storm-sender" ~pid:None ~pid_start_time:None ();
          C2c_mcp.Broker.register broker ~session_id:"session-recv-current"
            ~alias:"storm-recv" ~pid:None ~pid_start_time:None ();
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"current-chat"
              ~alias:"storm-sender" ~session_id:"session-sender-current"
          in
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"current-chat"
              ~alias:"storm-recv" ~session_id:"session-recv-current"
          in
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-sender-current");
          ignore
            (C2c_mcp.Broker.drain_inbox broker
               ~session_id:"session-recv-current");
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 204)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "current-chat")
                          ; ("content", `String "hello via current alias")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected send_room response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let delivered =
                 parsed |> member "delivered_to" |> to_list |> List.map to_string
               in
               check int "one delivery via current alias" 1
                 (List.length delivered);
               check string "delivered to storm-recv" "storm-recv"
                 (List.hd delivered));
          let inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-recv-current"
          in
          check int "recipient inbox has one message" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "from_alias resolved from current session"
            "storm-sender" msg.from_alias;
          check string "content" "hello via current alias" msg.content))

let test_tools_call_send_room_missing_sender_alias_is_actionable () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 205)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `Null)
                          ; ("room_id", `String "current-chat")
                          ; ("content", `String "hello")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected send_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "send_room rejected with isError=true" true is_error;
              check bool "error explains missing sender alias" true
                (string_contains text "missing sender alias");
              check bool "error is not raw Yojson internals" false
                (string_contains text "Yojson")))

(* Gap #8 / tail_log: after a tools/call, tail_log should return the
   log entry that was just appended. *)
let test_tools_call_tail_log_returns_audit_entries () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-tail-test";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          (* Call `list` to generate an audit entry. *)
          let _list_resp =
            Lwt_main.run
              (C2c_mcp.handle_request ~broker_root:dir
                 (`Assoc
                    [ ("jsonrpc", `String "2.0")
                    ; ("id", `Int 910)
                    ; ("method", `String "tools/call")
                    ; ("params",
                       `Assoc
                         [ ("name", `String "list")
                         ; ("arguments", `Assoc [])
                         ])
                    ]))
          in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 911)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "tail_log")
                    ; ("arguments", `Assoc [])
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected tail_log response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let entries = Yojson.Safe.from_string text |> to_list in
               (* `tail_log` reads the log before its own entry is appended,
                  so we see exactly the `list` entry from the prior call. *)
               check int "exactly one entry (list call)" 1 (List.length entries);
               let first = List.hd entries in
               check string "first tool is list" "list"
                 (first |> member "tool" |> to_string);
               check bool "first ok=true" true
                 (first |> member "ok" |> to_bool);
               check bool "ts is positive" true
                 (first |> member "ts" |> to_number > 0.0))))

(* Gap #8: every tools/call should append one line to broker.log. *)
let test_tools_call_appends_to_broker_log () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-log-test";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let log_path = Filename.concat dir "broker.log" in
          check bool "no log yet" false (Sys.file_exists log_path);
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 900)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "list")
                    ; ("arguments", `Assoc [])
                    ] )
              ]
          in
          let _response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          check bool "log created" true (Sys.file_exists log_path);
          let line = String.trim (In_channel.input_all (open_in log_path)) in
          let parsed = Yojson.Safe.from_string line in
          let open Yojson.Safe.Util in
          check string "tool field" "list" (parsed |> member "tool" |> to_string);
          check bool "ok field true" true (parsed |> member "ok" |> to_bool);
          check bool "ts is positive" true
            (parsed |> member "ts" |> to_number > 0.0)))

(* Regression for gap #2: join_room should accept `from_alias` as a
   synonym for `alias`, mirroring the send-side fallback. Models that
   already standardized on `from_alias` for send/send_room shouldn't
   re-learn a different key when they also want to join. *)
let test_tools_call_join_room_accepts_from_alias_as_alias () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-join-from_alias";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-join-from_alias"
            ~alias:"storm-joiner" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 301)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "join_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "from-alias-chat")
                          ; (* Note: `from_alias` not `alias`. *)
                            ("from_alias", `String "storm-joiner")
                          ; ("history_limit", `Int 0)
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected join_room response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let members =
                 parsed |> member "members" |> to_list
               in
               check int "one member" 1 (List.length members);
               let first = List.hd members in
               check string "alias resolved from from_alias fallback"
                 "storm-joiner" (first |> member "alias" |> to_string))))

(* Quality: room_history limit > total messages should return all messages,
   not truncate or error. *)
let test_room_history_limit_larger_than_total_returns_all () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      for i = 1 to 5 do
        ignore
          (C2c_mcp.Broker.append_room_history broker ~room_id:"overflow"
             ~from_alias:"sender-a"
             ~content:(Printf.sprintf "msg-%d" i))
      done;
      (* Request 100 but only 5 exist: should return all 5, not fail. *)
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"overflow" ~limit:100 ()
      in
      check int "returns all 5 when limit > count" 5 (List.length history);
      check string "first message" "msg-1"
        (List.nth history 0).rm_content;
      check string "last message" "msg-5"
        (List.nth history 4).rm_content)

(* Quality: history must preserve from_alias for each sender so the
   reading agent can attribute messages correctly. *)
let test_room_history_preserves_multiple_senders () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      ignore
        (C2c_mcp.Broker.append_room_history broker ~room_id:"multi-sender"
           ~from_alias:"alice" ~content:"hi from alice");
      ignore
        (C2c_mcp.Broker.append_room_history broker ~room_id:"multi-sender"
           ~from_alias:"bob" ~content:"hi from bob");
      ignore
        (C2c_mcp.Broker.append_room_history broker ~room_id:"multi-sender"
           ~from_alias:"alice" ~content:"alice again");
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"multi-sender" ~limit:10 ()
      in
      check int "3 messages" 3 (List.length history);
      check string "first sender" "alice" (List.nth history 0).rm_from_alias;
      check string "first content" "hi from alice" (List.nth history 0).rm_content;
      check string "second sender" "bob" (List.nth history 1).rm_from_alias;
      check string "third sender" "alice" (List.nth history 2).rm_from_alias;
      check string "third content" "alice again" (List.nth history 2).rm_content)

(* Quality: a large inbox (50 messages) must drain completely in one poll.
   Guards against any off-by-one or truncation in the inbox read/drain path. *)
let test_large_inbox_drains_all_messages () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-src" ~alias:"src" ~pid:None
        ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-dst" ~alias:"dst" ~pid:None
        ~pid_start_time:None ();
      for i = 1 to 50 do
        C2c_mcp.Broker.enqueue_message broker ~from_alias:"src" ~to_alias:"dst"
          ~content:(Printf.sprintf "bulk-%d" i) ()
      done;
      (* drain_inbox removes and returns all messages *)
      let inbox = C2c_mcp.Broker.drain_inbox broker ~session_id:"s-dst" in
      check int "50 messages drained" 50 (List.length inbox);
      (* Verify order: first enqueued first *)
      check string "first content" "bulk-1" (List.nth inbox 0).content;
      check string "last content" "bulk-50" (List.nth inbox 49).content;
      (* After draining, inbox is empty — read_inbox peeks without draining *)
      let after = C2c_mcp.Broker.read_inbox broker ~session_id:"s-dst" in
      check int "inbox empty after drain" 0 (List.length after))

(* Remote alias: to_alias containing '@' is appended to remote-outbox.jsonl
   for async relay forwarding, not written to a local inbox. *)
let test_send_remote_alias_appends_to_outbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Remote alias with '@' should go to outbox, not local inbox. *)
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"jungle-coder"
        ~to_alias:"lyra@relay"
        ~content:"hello across machines"
        ();
      let outbox_path = Filename.concat dir "remote-outbox.jsonl" in
      check bool "outbox file created" true (Sys.file_exists outbox_path);
      (* Read and verify the JSON line. *)
      let json_str = Stdlib.input_line (open_in outbox_path) in
      let json = Yojson.Safe.from_string json_str in
      let open Yojson.Safe.Util in
      check string "from_alias" "jungle-coder"
        (match json |> member "from_alias" with `String s -> s | _ -> "");
      check string "to_alias" "lyra@relay"
        (match json |> member "to_alias" with `String s -> s | _ -> "");
      check string "content" "hello across machines"
        (match json |> member "content" with `String s -> s | _ -> ""))

(* Quality: limit=1 returns only the most recent message, not the oldest. *)
let test_room_history_limit_one_returns_last () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"limit-one"
          ~alias:"sender" ~session_id:"s"
      in
      List.iter
        (fun msg ->
          ignore
            (C2c_mcp.Broker.append_room_history broker ~room_id:"limit-one"
               ~from_alias:"sender" ~content:msg))
        [ "first"; "second"; "third"; "fourth"; "fifth" ];
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"limit-one" ~limit:1 ()
      in
      check int "exactly one message" 1 (List.length history);
      check string "most recent only" "fifth" (List.hd history).rm_content)

(* Regression for gap #2: leave_room should accept `from_alias` too.
   Join + leave must use the same schema. *)
let test_tools_call_leave_room_accepts_from_alias_as_alias () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-leave-from_alias";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-leave-from_alias"
            ~alias:"storm-leaver" ~pid:None ~pid_start_time:None ();
          let _ =
            C2c_mcp.Broker.join_room broker ~room_id:"from-alias-leave"
              ~alias:"storm-leaver"
              ~session_id:"session-leave-from_alias"
          in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 302)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "leave_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("room_id", `String "from-alias-leave")
                          ; (* Note: `from_alias` not `alias`. *)
                            ("from_alias", `String "storm-leaver")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          (match response with
           | None -> fail "expected leave_room response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string text in
               let members =
                 parsed |> member "members" |> to_list
               in
               check int "zero members after leave" 0
                 (List.length members))))

(* Regression: join_room without any alias source returns actionable isError. *)
let test_tools_call_join_room_missing_alias_is_actionable () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 310)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "join_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("alias", `Null)
                          ; ("room_id", `String "test-missing-alias")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected join_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "join_room rejected with isError=true" true is_error;
              check bool "error explains missing member alias" true
                (string_contains text "missing member alias");
              check bool "error is not raw Yojson internals" false
                (string_contains text "Yojson")))

(* Regression: leave_room without any alias source returns actionable isError. *)
let test_tools_call_leave_room_missing_alias_is_actionable () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 311)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "leave_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("alias", `Null)
                          ; ("room_id", `String "test-missing-alias")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected leave_room response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "leave_room rejected with isError=true" true is_error;
              check bool "error explains missing member alias" true
                (string_contains text "missing member alias");
              check bool "error is not raw Yojson internals" false
                (string_contains text "Yojson")))

let test_register_rename_fans_out_peer_renamed_notification () =
  (* When a session re-registers with a different alias while it's a room
     member, the broker should append a peer_renamed notification to the
     room history of every room the session was in. *)
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-rename";
      Unix.putenv "C2C_MCP_CLIENT_PID" "";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_CLIENT_PID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          ignore broker;
          let make_request id name args =
            Lwt_main.run
              (C2c_mcp.handle_request ~broker_root:dir
                 (`Assoc
                   [ ("jsonrpc", `String "2.0")
                   ; ("id", `Int id)
                   ; ("method", `String "tools/call")
                   ; ("params",
                      `Assoc [ ("name", `String name); ("arguments", `Assoc args) ])
                   ]))
          in
          (* Register original alias. *)
          ignore (make_request 1 "register" [ ("alias", `String "old-alias") ]);
          (* Join a room as old-alias. *)
          ignore
            (make_request 2 "join_room"
               [ ("from_alias", `String "old-alias")
               ; ("room_id", `String "rename-test-room")
               ]);
          (* Re-register with a new alias — should append peer_renamed to room. *)
          ignore (make_request 3 "register" [ ("alias", `String "new-alias") ]);
          (* Verify peer_renamed appears in room history. *)
          let history =
            C2c_mcp.Broker.read_room_history
              (C2c_mcp.Broker.create ~root:dir)
              ~room_id:"rename-test-room" ~limit:20 ()
          in
          let found =
            List.exists
              (fun m ->
                let open Yojson.Safe in
                try
                  (* Content is "old renamed to new {...json...}"; extract JSON suffix *)
                  let s = m.C2c_mcp.rm_content in
                  let idx = String.index s '{' in
                  let j = from_string (String.sub s idx (String.length s - idx)) in
                  Util.(member "type" j |> to_string) = "peer_renamed"
                  && Util.(member "old_alias" j |> to_string) = "old-alias"
                  && Util.(member "new_alias" j |> to_string) = "new-alias"
                with _ -> false)
              history
          in
          check bool "peer_renamed in room history" true found;
          let members =
            C2c_mcp.Broker.read_room_members
              (C2c_mcp.Broker.create ~root:dir)
              ~room_id:"rename-test-room"
          in
          check (list string) "room member alias updated after rename"
            [ "new-alias" ]
            (List.map (fun m -> m.C2c_mcp.rm_alias) members)))

let test_register_new_peer_broadcasts_peer_register_to_swarm_lounge () =
  (* Provisional sessions defer peer_register until first poll_inbox confirms them.
     A brand-new session registers (provisional, no pid) → no broadcast yet.
     On first poll_inbox, confirm_registration fires the deferred broadcast. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Existing peer: confirm so join_room broadcasts, then drain setup messages *)
      C2c_mcp.Broker.register broker ~session_id:"session-existing"
        ~alias:"existing-peer" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-existing";
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"existing-peer" ~session_id:"session-existing");
      ignore (C2c_mcp.Broker.drain_inbox broker ~session_id:"session-existing");
      Unix.putenv "C2C_MCP_SESSION_ID" "session-new-peer";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "new-peer";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          let register_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 1)
              ; ("method", `String "tools/call")
              ; ("params",
                 `Assoc
                   [ ("name", `String "register")
                   ; ("arguments", `Assoc [ ("alias", `String "new-peer") ])
                   ])
              ]
          in
          ignore (Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir register_req));
          (* After register only: provisional session → broadcast NOT yet emitted *)
          let history_after_register =
            C2c_mcp.Broker.read_room_history broker ~room_id:"swarm-lounge" ~limit:20 ()
          in
          let found_before_confirm =
            List.exists
              (fun m ->
                try
                  let s = m.C2c_mcp.rm_content in
                  let idx = String.index s '{' in
                  let j = Yojson.Safe.from_string (String.sub s idx (String.length s - idx)) in
                  Yojson.Safe.Util.(member "type" j |> to_string) = "peer_register"
                  && Yojson.Safe.Util.(member "alias" j |> to_string) = "new-peer"
                with _ -> false)
              history_after_register
          in
          check bool "peer_register NOT in swarm-lounge before poll_inbox" false found_before_confirm;
          (* poll_inbox triggers confirm_registration → deferred broadcast fires *)
          let poll_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 2)
              ; ("method", `String "tools/call")
              ; ("params",
                 `Assoc
                   [ ("name", `String "poll_inbox")
                   ; ("arguments", `Assoc [])
                   ])
              ]
          in
          ignore (Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir poll_req));
          let lounge_history =
            C2c_mcp.Broker.read_room_history broker ~room_id:"swarm-lounge" ~limit:20 ()
          in
          let found_register =
            List.exists
              (fun m ->
                try
                  let s = m.C2c_mcp.rm_content in
                  let idx = String.index s '{' in
                  let j = Yojson.Safe.from_string (String.sub s idx (String.length s - idx)) in
                  Yojson.Safe.Util.(member "type" j |> to_string) = "peer_register"
                  && Yojson.Safe.Util.(member "alias" j |> to_string) = "new-peer"
                with _ -> false)
              lounge_history
          in
          check bool "peer_register in swarm-lounge history after poll_inbox" true found_register;
          let existing_inbox =
            C2c_mcp.Broker.read_inbox broker ~session_id:"session-existing"
          in
          check (list string) "existing peer notified via inbox fanout after poll_inbox"
            [ "new-peer registered {\"type\":\"peer_register\",\"alias\":\"new-peer\"}" ]
            (List.map (fun m -> m.C2c_mcp.content) existing_inbox)))

let test_join_room_updates_session_id_on_alias_rejoin () =
  (* When the same alias joins a room twice with different session_ids
     (e.g. kimi restarts with a new session_id), only one member entry
     should exist and the session_id should reflect the latest join.
     This prevents duplicate room fanout messages. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _m1 =
        C2c_mcp.Broker.join_room broker ~room_id:"test-room"
          ~alias:"kimi-nova" ~session_id:"kimi-xertrov-x-game"
      in
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"test-room"
          ~alias:"kimi-nova" ~session_id:"kimi-nova"
      in
      check int "only one member after alias rejoin" 1 (List.length members);
      let m = List.hd members in
      check string "alias preserved" "kimi-nova" m.C2c_mcp.rm_alias;
      check string "session_id updated to latest" "kimi-nova" m.C2c_mcp.rm_session_id)

let test_join_room_updates_alias_on_session_rejoin () =
  (* When the same session joins a room under a new alias, it is a rename,
     not a second membership. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _m1 =
        C2c_mcp.Broker.join_room broker ~room_id:"test-room"
          ~alias:"old-alias" ~session_id:"stable-session"
      in
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"test-room"
          ~alias:"new-alias" ~session_id:"stable-session"
      in
      check int "only one member after session alias rejoin" 1 (List.length members);
      let m = List.hd members in
      check string "alias updated to latest" "new-alias" m.C2c_mcp.rm_alias;
      check string "session_id preserved" "stable-session" m.C2c_mcp.rm_session_id)

(* send should reject if from_alias is held by an alive different session. *)
let test_tools_call_send_rejects_impersonation () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* "real-owner" holds "storm-beacon" with a live pid *)
      C2c_mcp.Broker.register broker ~session_id:"real-owner"
        ~alias:"storm-beacon" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* "storm-beacon" also registers a target to send to *)
      C2c_mcp.Broker.register broker ~session_id:"target-session"
        ~alias:"tide-runner" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* An unrelated session tries to send as "storm-beacon" *)
      Unix.putenv "C2C_MCP_SESSION_ID" "impostor-session";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 201)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "storm-beacon")
                          ; ("to_alias", `String "tide-runner")
                          ; ("content", `String "impersonation attempt")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "send rejected with isError=true" true is_error;
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "error mentions stolen alias" true
                (string_contains text "storm-beacon")))

(* send_all should reject if from_alias is held by an alive different session. *)
let test_tools_call_send_all_rejects_impersonation () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"real-owner"
        ~alias:"storm-beacon" ~pid:(Some live_pid) ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "impostor-session";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 202)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_all")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "storm-beacon")
                          ; ("content", `String "broadcast impersonation")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "send_all rejected with isError=true" true is_error))

(* send_room should reject if from_alias is held by an alive different session. *)
let test_tools_call_send_room_rejects_impersonation () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"real-owner"
        ~alias:"storm-beacon" ~pid:(Some live_pid) ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.join_room broker ~room_id:"swarm-lounge"
           ~alias:"storm-beacon" ~session_id:"real-owner");
      Unix.putenv "C2C_MCP_SESSION_ID" "impostor-session";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 203)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "send_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("from_alias", `String "storm-beacon")
                          ; ("room_id", `String "swarm-lounge")
                          ; ("content", `String "room impersonation")
                          ] )
                    ] )
              ]
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          match response with
          | None -> fail "expected tools/call response"
          | Some json ->
              let open Yojson.Safe.Util in
              let is_error =
                json |> member "result" |> member "isError" |> to_bool_option
                |> Option.value ~default:false
              in
              check bool "send_room rejected with isError=true" true is_error))

let test_send_room_invite_adds_to_invite_list () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.send_room_invite broker ~room_id:"secret-club"
        ~from_alias:"alice" ~invitee_alias:"bob";
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"secret-club" in
      check string "visibility" "public"
        (match meta.visibility with Public -> "public" | Invite_only -> "invite_only");
      check (list string) "invited_members" ["bob"] meta.invited_members)

let test_send_room_invite_only_member_can_invite () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      check_raises "non-member cannot invite"
        (Invalid_argument "send_room_invite rejected: only room members can invite")
        (fun () ->
           C2c_mcp.Broker.send_room_invite broker ~room_id:"secret-club"
             ~from_alias:"bob" ~invitee_alias:"carol"))

let test_join_room_invite_only_rejects_uninvited () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret-club"
        ~from_alias:"alice" ~visibility:C2c_mcp.Invite_only;
      check_raises "uninvited rejected"
        (Invalid_argument "join_room rejected: room 'secret-club' is invite-only and 'bob' is not on the invite list")
        (fun () ->
           ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
             ~alias:"bob" ~session_id:"session-b")))

let test_join_room_invite_only_accepts_invited () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret-club"
        ~from_alias:"alice" ~visibility:C2c_mcp.Invite_only;
      C2c_mcp.Broker.send_room_invite broker ~room_id:"secret-club"
        ~from_alias:"alice" ~invitee_alias:"bob";
      let members =
        C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
          ~alias:"bob" ~session_id:"session-b"
      in
      check int "bob can join after invite" 2 (List.length members))

let test_set_room_visibility_changes_mode () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret-club"
        ~from_alias:"alice" ~visibility:C2c_mcp.Invite_only;
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"secret-club" in
      check bool "visibility is invite_only" true
        (match meta.visibility with Invite_only -> true | Public -> false))

let test_set_room_visibility_only_member_can_change () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      check_raises "non-member cannot change visibility"
        (Invalid_argument "set_room_visibility rejected: only room members can change visibility")
        (fun () ->
           C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret-club"
             ~from_alias:"bob" ~visibility:C2c_mcp.Invite_only))

let test_list_rooms_includes_visibility_and_invited_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.send_room_invite broker ~room_id:"secret-club"
        ~from_alias:"alice" ~invitee_alias:"bob";
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check int "one room" 1 (List.length rooms);
      let room = List.hd rooms in
      check string "visibility public" "public"
        (match room.ri_visibility with Public -> "public" | Invite_only -> "invite_only");
      check (list string) "invited_members" ["bob"] room.ri_invited_members)

let test_tools_call_send_room_invite_via_mcp () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 301)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "send_room_invite")
                     ; ( "arguments",
                         `Assoc
                           [ ("room_id", `String "secret-club")
                           ; ("invitee_alias", `String "bob")
                           ] )
                     ] )
               ]
           in
           let response =
             Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
           in
           match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "send_room_invite success" false is_error;
               let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"secret-club" in
               check (list string) "invited via MCP" ["bob"] meta.invited_members))

let test_tools_call_set_room_visibility_via_mcp () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 302)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "set_room_visibility")
                     ; ( "arguments",
                         `Assoc
                           [ ("room_id", `String "secret-club")
                           ; ("visibility", `String "invite_only")
                           ] )
                     ] )
               ]
           in
           let response =
             Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
           in
           match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "set_room_visibility success" false is_error;
               let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"secret-club" in
                check bool "visibility is invite_only" true
                  (match meta.visibility with Invite_only -> true | Public -> false)))

(* --- prompts/list and prompts/get tests (run via subprocess to isolate Sys.chdir) --- *)

let run_prompts_test_skeleton ~dir ~skill_name ~test_code =
  let skills_dir = Filename.concat dir (Filename.concat ".opencode" "skills") in
  let skill_dir = Filename.concat skills_dir skill_name in
  Unix.mkdir (Filename.concat dir ".opencode") 0o755;
  Unix.mkdir skills_dir 0o755;
  Unix.mkdir skill_dir 0o755;
  let skill_file = Filename.concat skill_dir "SKILL.md" in
  let oc = open_out skill_file in
  output_string oc "name: test-skill\ndescription: A test skill for prompts\n---\nTest skill body content.\n";
  close_out oc;
  let code = Printf.sprintf "begin %s; exit 0 end" test_code in
  let full_code = Printf.sprintf "Sys.chdir %S; %s" dir code in
  let result = Sys.command ("ocaml -stdio <<'EOF'\n" ^ full_code ^ "\nEOF\n 2>&1") in
  if result <> 0 then Printf.eprintf "subprocess failed with code %d\n%!" result;
  result

let test_prompts_list_via_subprocess () =
  with_temp_dir (fun dir ->
      let test_code =
        "let prompts = C2c_mcp.list_skills_as_prompts () in \
         let n = List.length prompts in \
         if n = 0 then failwith \"expected at least one prompt\"; \
         let p = List.hd prompts in \
         match p with \
         | `Assoc fields -> \
           (match List.assoc_opt \"name\" fields with \
            Some (`String \"test-skill\") -> () \
            | _ -> failwith \"expected name field\") \
         | _ -> failwith \"expected prompt to be object\""
      in
      let result = run_prompts_test_skeleton ~dir ~skill_name:"test-skill" ~test_code in
      check int "prompts/list subprocess" 0 result)

let test_prompts_get_via_subprocess () =
  with_temp_dir (fun dir ->
      let test_code =
        "match C2c_mcp.get_skill \"test-skill\" with \
         | Some (desc, content) -> \
           if desc <> \"A test skill for prompts\" then failwith \"wrong description\"; \
           if not (String.length content > 0) then failwith \"expected content\" \
         | None -> failwith \"expected Some\""
      in
      let result = run_prompts_test_skeleton ~dir ~skill_name:"test-skill" ~test_code in
      check int "prompts/get subprocess" 0 result)

let test_prompts_get_unknown_via_subprocess () =
  with_temp_dir (fun dir ->
      let test_code =
        "match C2c_mcp.get_skill \"nonexistent\" with \
         | None -> () \
         | Some _ -> failwith \"expected None for unknown skill\""
      in
      let result = run_prompts_test_skeleton ~dir ~skill_name:"test-skill" ~test_code in
      check int "prompts/get unknown subprocess" 0 result)

let test_join_room_invite_only_rejects_uninvited_via_mcp () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret-club"
        ~from_alias:"alice" ~visibility:C2c_mcp.Invite_only;
      Unix.putenv "C2C_MCP_SESSION_ID" "session-b";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 303)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "join_room")
                     ; ( "arguments",
                         `Assoc
                           [ ("room_id", `String "secret-club")
                           ; ("alias", `String "bob")
                           ] )
                     ] )
               ]
           in
           let response =
             Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
           in
           match response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
                in
                check bool "join_room rejected with isError=true" true is_error))

(* === M2/M4: pending permission tracking === *)

let test_open_pending_reply_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester"
            ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 901)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:abc:123")
                          ; ("kind", `String "permission")
                          ; ( "supervisors",
                              `List [ `String "coordinator1"; `String "ceo" ] )
                          ] )
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
              let content =
                json |> member "result" |> member "content"
                |> Yojson.Safe.Util.index 0 |> member "text" |> Yojson.Safe.Util.to_string
                |> Yojson.Safe.from_string
              in
              check bool "ok is true" true (content |> member "ok" |> to_bool);
              check string "perm_id matches" "perm:abc:123" (content |> member "perm_id" |> to_string);
              check string "kind is permission" "permission" (content |> member "kind" |> to_string)))

let test_check_pending_reply_valid_supervisor_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester"
            ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
          let open_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 901)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:xyz:789")
                          ; ("kind", `String "permission")
                          ; ( "supervisors",
                              `List [ `String "coordinator1"; `String "ceo" ] )
                          ] )
                    ] )
              ]
          in
          let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir open_req) in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 902)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:xyz:789")
                          ; ("reply_from_alias", `String "coordinator1")
                          ] )
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
              let content =
                json |> member "result" |> member "content"
                |> Yojson.Safe.Util.index 0 |> member "text" |> Yojson.Safe.Util.to_string
                |> Yojson.Safe.from_string
              in
              check bool "valid is true" true (content |> member "valid" |> to_bool);
              check string "requester_session_id matches" "session-requester"
                (content |> member "requester_session_id" |> to_string)))

let test_check_pending_reply_unknown_perm_id_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester"
            ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 903)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:unknown:999")
                          ; ("reply_from_alias", `String "coordinator1")
                          ] )
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
              let content =
                json |> member "result" |> member "content"
                |> Yojson.Safe.Util.index 0 |> member "text" |> Yojson.Safe.Util.to_string
                |> Yojson.Safe.from_string
              in
              check bool "valid is false" false (content |> member "valid" |> to_bool);
              check string "error is 'unknown permission ID'" "unknown permission ID"
                (content |> member "error" |> to_string)))

let test_check_pending_reply_non_supervisor_via_mcp () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester"
            ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
          let open_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 903)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:def:456")
                          ; ("kind", `String "question")
                          ; ( "supervisors",
                              `List [ `String "coordinator1" ] )
                          ] )
                    ] )
              ]
          in
          let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir open_req) in
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 904)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:def:456")
                          ; ("reply_from_alias", `String "attacker")
                          ] )
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
              let content =
                json |> member "result" |> member "content"
                |> Yojson.Safe.Util.index 0 |> member "text" |> Yojson.Safe.Util.to_string
                |> Yojson.Safe.from_string
              in
              check bool "valid is false" false (content |> member "valid" |> to_bool);
              let error_str = content |> member "error" |> to_string in
              check bool "error mentions non-supervisor" true
                (string_contains error_str "reply from non-supervisor")))

(* M4: alias-reuse guard — registration is blocked when the alias has an
   active pending permission from a prior owner, even if that owner is dead.
   The prior owner may be alive or dead; the pending state is the blocker. *)
let test_register_rejects_alias_with_pending_permission_from_alive_owner () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* session-owner registers "test-alias" without a PID (simulates dead owner) *)
      C2c_mcp.Broker.register broker ~session_id:"session-owner"
        ~alias:"test-alias" ~pid:None ~pid_start_time:None ();
      (* Open a pending permission for "test-alias" from session-owner *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-owner";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let open_perm_request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 55)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-test-123")
                          ; ("kind", `String "permission")
                          ; ("supervisors", `List [`String "coordinator1"])
                          ] )
                    ] )
              ]
          in
          let open_response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir open_perm_request)
          in
          check bool "open_pending_reply succeeded" true
            (match open_response with
             | Some json ->
                 let open Yojson.Safe.Util in
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
                 |> not
             | None -> false);
          (* session-thief tries to claim the same alias — must be rejected *)
          Unix.putenv "C2C_MCP_SESSION_ID" "session-thief";
          let reg_request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 77)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ( "arguments",
                        `Assoc [ ("alias", `String "test-alias") ] )
                    ] )
              ]
          in
          let reg_response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir reg_request)
          in
          (match reg_response with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "register rejected with isError=true" true is_error;
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               check bool "error mentions pending permission" true
                 (string_contains text "pending permission");
               check bool "error mentions the alias" true
                 (string_contains text "test-alias");
               (* session-owner still registered *)
                let regs = C2c_mcp.Broker.list_registrations broker in
                let open C2c_mcp in
                let owner =
                  List.find_opt (fun r -> r.session_id = "session-owner") regs
               in
               check bool "owner registration preserved" true (owner <> None);
               let thief =
                 List.find_opt (fun r -> r.session_id = "session-thief") regs
               in
               check bool "thief not registered" true (thief = None))))

(* --- liveness self-heal: respawn-under-new-pid (slice/liveness-respawn-pid) --- *)

(* Pick a pid value that's almost certainly not in the process table.
   /proc/<this>/* will not exist, so registration_is_alive returns false. *)
let dead_pid = 0x7f00_0000  (* 2130706432, far above typical pid_max *)

let test_discover_live_pid_finds_matching_session () =
  let scan_pids () = [ 1234; 5678 ] in
  let read_environ pid =
    if pid = 1234 then Some [ ("PATH", "/usr/bin"); ("C2C_MCP_SESSION_ID", "session-x") ]
    else if pid = 5678 then Some [ ("C2C_MCP_SESSION_ID", "session-y") ]
    else None
  in
  let got =
    C2c_mcp.Broker.discover_live_pid_for_session_with
      ~scan_pids ~read_environ ~session_id:"session-y"
  in
  check (option int) "discovers session-y at pid 5678" (Some 5678) got

let test_discover_live_pid_returns_none_when_no_match () =
  let scan_pids () = [ 1234; 5678 ] in
  let read_environ pid =
    if pid = 1234 then Some [ ("C2C_MCP_SESSION_ID", "other-session") ]
    else None
  in
  let got =
    C2c_mcp.Broker.discover_live_pid_for_session_with
      ~scan_pids ~read_environ ~session_id:"session-not-found"
  in
  check (option int) "no match" None got

let test_discover_live_pid_skips_unreadable_environ () =
  let scan_pids () = [ 100; 200; 300 ] in
  let read_environ pid =
    if pid = 100 then None  (* permission denied / process gone *)
    else if pid = 200 then Some []  (* empty env *)
    else if pid = 300 then Some [ ("C2C_MCP_SESSION_ID", "target") ]
    else None
  in
  let got =
    C2c_mcp.Broker.discover_live_pid_for_session_with
      ~scan_pids ~read_environ ~session_id:"target"
  in
  check (option int) "tolerates unreadable / empty environs" (Some 300) got

let test_refresh_pid_if_dead_noops_when_pidless () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-pidless" ~alias:"alpha-test"
        ~pid:None ~pid_start_time:None ();
      let scan_pids () = [ 1234 ] in
      let read_environ _ = Some [ ("C2C_MCP_SESSION_ID", "s-pidless") ] in
      let refreshed =
        C2c_mcp.Broker.refresh_pid_if_dead_with
          ~scan_pids ~read_environ broker ~session_id:"s-pidless"
      in
      check bool "no-op for pidless reg" false refreshed)

let test_refresh_pid_if_dead_noops_when_alive () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let live_pid = Unix.getpid () in
      let live_start = C2c_mcp.Broker.read_pid_start_time live_pid in
      C2c_mcp.Broker.register broker ~session_id:"s-alive" ~alias:"alpha-alive"
        ~pid:(Some live_pid) ~pid_start_time:live_start ();
      let scan_pids () = [ 999_999 ] in
      let read_environ _ = Some [ ("C2C_MCP_SESSION_ID", "s-alive") ] in
      let refreshed =
        C2c_mcp.Broker.refresh_pid_if_dead_with
          ~scan_pids ~read_environ broker ~session_id:"s-alive"
      in
      check bool "no-op for alive reg" false refreshed)

let test_refresh_pid_if_dead_updates_when_dead_and_live_discovered () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-respawn" ~alias:"alpha-respawn"
        ~pid:(Some dead_pid) ~pid_start_time:(Some 12345) ();
      let live_pid = Unix.getpid () in
      let scan_pids () = [ live_pid ] in
      let read_environ pid =
        if pid = live_pid then Some [ ("C2C_MCP_SESSION_ID", "s-respawn") ]
        else None
      in
      let refreshed =
        C2c_mcp.Broker.refresh_pid_if_dead_with
          ~scan_pids ~read_environ broker ~session_id:"s-respawn"
      in
      check bool "refresh happened" true refreshed;
      let regs = C2c_mcp.Broker.list_registrations broker in
      let reg = List.find (fun (r : C2c_mcp.registration) -> r.session_id = "s-respawn") regs in
      check (option int) "pid updated to live process" (Some live_pid) reg.pid;
      check bool "registration is now alive"
        true (C2c_mcp.Broker.registration_is_alive reg))

let test_refresh_pid_if_dead_noops_when_no_replacement_discovered () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-stale" ~alias:"alpha-stale"
        ~pid:(Some dead_pid) ~pid_start_time:None ();
      let scan_pids () = [] in
      let read_environ _ = None in
      let refreshed =
        C2c_mcp.Broker.refresh_pid_if_dead_with
          ~scan_pids ~read_environ broker ~session_id:"s-stale"
      in
      check bool "no-op when discovery finds nothing" false refreshed;
      let regs = C2c_mcp.Broker.list_registrations broker in
      let reg = List.find (fun (r : C2c_mcp.registration) -> r.session_id = "s-stale") regs in
      check (option int) "pid unchanged" (Some dead_pid) reg.pid)

(* Regression for the gap lyra-quill caught on 3f3a08ad: target-side
   self-heal during alias resolution. A sender hitting send / send_all /
   send_room must recover when the target peer is alive under a fresh
   pid but hasn't touched the broker since respawn. Without the resolver
   self-heal, enqueue_message returned "recipient is not alive" for
   exactly this case during the 2026-04-26 outage. *)
let test_resolve_alias_self_heals_dead_target_via_inject () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Target was registered with a now-dead pid. Target has not
         touched the broker since respawn. Sender doesn't know that yet. *)
      C2c_mcp.Broker.register broker ~session_id:"s-target" ~alias:"galaxy-test"
        ~pid:(Some dead_pid) ~pid_start_time:(Some 99) ();
      (* Pre-flight check: registration_is_alive is false, so the legacy
         resolver path returns All_recipients_dead. *)
      (let regs = C2c_mcp.Broker.list_registrations broker in
       let reg = List.find (fun (r : C2c_mcp.registration) -> r.session_id = "s-target") regs in
       check bool "pre-heal: target reg is dead" false (C2c_mcp.Broker.registration_is_alive reg));
      (* Now patch in a discovery scanner that finds the test process as
         the live owner of "s-target". Drive the heal via a direct call —
         we can't bypass resolve's hardcoded discoverers without an
         injection seam, but we CAN swap the registry's pid via
         refresh_pid_if_dead_with so the in-place test setup mirrors
         what the resolver would do internally on the live binary. *)
      let live_pid = Unix.getpid () in
      let scan_pids () = [ live_pid ] in
      let read_environ pid =
        if pid = live_pid then Some [ ("C2C_MCP_SESSION_ID", "s-target") ]
        else None
      in
      let healed =
        C2c_mcp.Broker.refresh_pid_if_dead_with
          ~scan_pids ~read_environ broker ~session_id:"s-target"
      in
      check bool "heal happened" true healed;
      (* Now the sender's path resolves cleanly: enqueue_message finds an
         Alive registration via registration_is_alive, no
         All_recipients_dead error. *)
      C2c_mcp.Broker.register broker ~session_id:"s-sender" ~alias:"sender-test"
        ~pid:(Some live_pid) ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time live_pid) ();
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"sender-test" ~to_alias:"galaxy-test"
        ~content:"after-respawn delivery" ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"s-target" in
      check int "delivery succeeded post-heal" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "content delivered" "after-respawn delivery" msg.content)

(* True end-to-end regression for the resolver self-heal: addresses
   lyra's follow-up ask after 3b8c1cea. Drives `enqueue_message` → which
   internally calls `resolve_live_session_id_by_alias` → which on the
   All_dead branch calls `refresh_pid_if_dead` → which now reads the
   `set_proc_hooks_for_test` overrides. The test never touches real
   /proc and exercises the full delivery path including the heal. *)
let test_enqueue_self_heals_dead_target_via_resolver_hooks () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-target-eh" ~alias:"galaxy-eh"
        ~pid:(Some dead_pid) ~pid_start_time:(Some 99) ();
      let live_pid = Unix.getpid () in
      let scan_pids () = [ live_pid ] in
      let read_environ pid =
        if pid = live_pid then Some [ ("C2C_MCP_SESSION_ID", "s-target-eh") ]
        else None
      in
      Fun.protect
        ~finally:C2c_mcp.Broker.clear_proc_hooks_for_test
        (fun () ->
          C2c_mcp.Broker.set_proc_hooks_for_test ~scan_pids ~read_environ ();
          (* Pre-flight: resolver still sees target as dead until heal. *)
          (let regs = C2c_mcp.Broker.list_registrations broker in
           let reg = List.find (fun (r : C2c_mcp.registration) -> r.session_id = "s-target-eh") regs in
           check bool "pre-heal: registration_is_alive=false" false (C2c_mcp.Broker.registration_is_alive reg));
          (* Sender enqueues — resolver should heal target during dispatch. *)
          C2c_mcp.Broker.register broker ~session_id:"s-sender-eh" ~alias:"sender-eh"
            ~pid:(Some live_pid)
            ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time live_pid) ();
          C2c_mcp.Broker.enqueue_message broker
            ~from_alias:"sender-eh" ~to_alias:"galaxy-eh"
            ~content:"resolver-heal e2e" ();
          (* Post: target's pid was healed, message delivered. *)
          let regs = C2c_mcp.Broker.list_registrations broker in
          let reg =
            List.find (fun (r : C2c_mcp.registration) -> r.session_id = "s-target-eh") regs
          in
          check (option int) "target pid healed by resolver" (Some live_pid) reg.pid;
          let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"s-target-eh" in
          check int "message delivered after resolver heal" 1 (List.length inbox);
          let msg = List.hd inbox in
          check string "delivered content" "resolver-heal e2e" msg.content))

let test_proc_hooks_clear_restores_real_proc () =
  (* Sanity: after clear_proc_hooks_for_test, the broker no longer uses
     the test scanners. We assert this by setting hooks that would heal,
     clearing them, and verifying refresh_pid_if_dead returns false
     (real /proc has no process claiming our synthetic session_id). *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let synth_sid = Printf.sprintf "synth-%d" (Random.bits ()) in
      C2c_mcp.Broker.register broker ~session_id:synth_sid ~alias:"alpha-clear"
        ~pid:(Some dead_pid) ~pid_start_time:(Some 1) ();
      C2c_mcp.Broker.set_proc_hooks_for_test
        ~scan_pids:(fun () -> [ Unix.getpid () ])
        ~read_environ:(fun _ -> Some [ ("C2C_MCP_SESSION_ID", synth_sid) ])
        ();
      C2c_mcp.Broker.clear_proc_hooks_for_test ();
      let healed = C2c_mcp.Broker.refresh_pid_if_dead broker ~session_id:synth_sid in
      check bool "refresh did NOT happen post-clear (real /proc has no match)" false healed)

(* Note: an end-to-end test using the real /proc scan is impractical here.
   /proc/<pid>/environ is a kernel snapshot taken at exec time; calling
   Unix.putenv inside the test process does NOT update it, so the test
   process can't make itself a "discoverable live target" via the default
   scanner. Coverage of the touch_session→refresh path is via the
   refresh_pid_if_dead_with unit tests above (mock scanners) plus the
   live-binary dogfood after install-all. *)

(* --- #286: send-memory handoff --- *)

let test_notify_shared_with_dms_listed_recipients () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author" ~alias:"alice-h"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob" ~alias:"bob-h"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-carol" ~alias:"carol-h"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-h" ~name:"handoff-note"
          ~description:"shared with friends"
          ~shared:false ~shared_with:["bob-h"; "carol-h"] ()
      in
      check int "two recipients notified" 2 (List.length notified);
      let bob_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"s-bob" in
      check int "bob received DM" 1 (List.length bob_inbox);
      let msg = List.hd bob_inbox in
      check string "from is the author" "alice-h" msg.from_alias;
      check bool "DM is deferrable" true msg.deferrable;
      check bool "msg references the path" true
        (let needle = ".c2c/memory/alice-h/handoff-note.md" in
         let h = msg.content in
         let nl = String.length needle in
         let hl = String.length h in
         let rec scan i = i + nl <= hl && (String.sub h i nl = needle || scan (i+1)) in
         scan 0))

let test_notify_skips_self_in_recipients () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author2" ~alias:"alice-skip"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob2" ~alias:"bob-skip"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-skip" ~name:"self-note"
          ~shared:false ~shared_with:["alice-skip"; "bob-skip"] ()
      in
      check int "self skipped, only one recipient" 1 (List.length notified);
      check string "the one recipient is bob, not alice" "bob-skip"
        (List.hd notified))

let test_notify_skipped_when_globally_shared () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author3" ~alias:"alice-global"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob3" ~alias:"bob-global"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-global" ~name:"global-note"
          ~shared:true ~shared_with:["bob-global"] ()
      in
      check int "no targeted handoff for globally-shared entry" 0
        (List.length notified);
      let bob_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"s-bob3" in
      check int "bob received nothing" 0 (List.length bob_inbox))

let test_notify_silently_skips_unknown_alias () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author4" ~alias:"alice-unknown"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob4" ~alias:"bob-unknown"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-unknown" ~name:"mixed-note"
          ~shared:false
          ~shared_with:["bob-unknown"; "ghost-not-registered"] ()
      in
      check int "only the registered recipient notified" 1
        (List.length notified);
      check string "registered recipient is bob" "bob-unknown"
        (List.hd notified))

let test_notify_empty_shared_with_is_noop () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author5" ~alias:"alice-empty"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-empty" ~name:"private-note"
          ~shared:false ~shared_with:[] ()
      in
      check int "no notifications for empty shared_with" 0
        (List.length notified))

let () =
  run "c2c_mcp"
    [ ( "broker",
        [ test_case "register and list" `Quick test_register_and_list
        ; test_case "send enqueues target message" `Quick test_send_enqueues_message_for_target_alias
        ; test_case "drain inbox clears messages" `Quick test_drain_inbox_returns_and_clears_messages
        ; test_case "empty drain does not create inbox file" `Quick
            test_drain_inbox_empty_does_not_touch_inbox_file
        ; test_case "empty drain does not rewrite existing empty inbox file" `Quick
            test_drain_inbox_empty_does_not_rewrite_existing_empty_file
        ; test_case "blank inbox file treated as empty" `Quick test_blank_inbox_file_is_treated_as_empty
        ; test_case "read_inbox is non-destructive (gui --batch regression)" `Quick
            test_read_inbox_is_non_destructive
         ; test_case "drain archives messages before clearing" `Quick
            test_drain_inbox_archives_messages_before_clearing
        ; test_case "empty drain does not create archive" `Quick
            test_drain_inbox_empty_does_not_create_archive
        ; test_case "drain_inbox_push suppresses deferrable" `Quick
            test_drain_inbox_push_suppresses_deferrable
        ; test_case "read_archive missing session returns empty" `Quick
            test_read_archive_missing_session_returns_empty
        ; test_case "read_archive respects limit" `Quick
            test_read_archive_respects_limit
        ; test_case "tools/call history returns archived messages" `Quick
            test_tools_call_history_returns_archived_messages
        ; test_case "tools/call history ignores session_id arg (subagent probe)" `Quick
            test_tools_call_history_ignores_session_id_argument
        ; test_case "channel notification shape" `Quick test_channel_notification_matches_claude_channel_shape
        ; test_case "channel notification empty content" `Quick
            test_channel_notification_empty_content
        ; test_case "channel notification special chars" `Quick
            test_channel_notification_special_chars
        ; test_case "channel notification has no id field" `Quick
            test_channel_notification_has_no_id_field
        ; test_case "initialize with channel capable client" `Quick
            test_initialize_with_channel_capable_client
        ; test_case "initialize without channel capability" `Quick
            test_initialize_without_channel_capability
        ; test_case "channel notification method is correct" `Quick
            test_channel_notification_method_is_correct
        ; test_case "channel notification with role" `Quick
            test_channel_notification_with_role
        ; test_case "channel notification without role omits" `Quick
            test_channel_notification_without_role_omits
        ; test_case "initialize returns capabilities" `Quick test_initialize_returns_mcp_capabilities
        ; test_case "initialize experimental capability values are objects" `Quick
            test_initialize_experimental_capability_values_are_objects
         ; test_case "initialize reports server version and features" `Quick
             test_initialize_reports_server_version_and_features
         ; test_case "initialize reports supported protocol version" `Quick
             test_initialize_reports_supported_protocol_version
         ; test_case "tools/list exposes core tools" `Quick test_tools_list_includes_register_list_send_and_whoami
         ; test_case "tools/list includes debug when build flag enabled" `Quick
             test_tools_list_includes_debug_when_build_flag_enabled
         ; test_case "tools/list makes current-session args optional" `Quick
             test_tools_list_marks_register_and_whoami_session_id_as_optional
         ; test_case "tools/call send routes through broker" `Quick test_tools_call_send_routes_message_through_broker
         ; test_case "tools/call send accepts `alias` as to_alias synonym" `Quick
             test_tools_call_send_accepts_alias_as_to_alias_synonym
         ; test_case "tools/call send missing to_alias returns named error" `Quick
             test_tools_call_send_missing_to_alias_returns_named_error
         ; test_case "tools/call send binds sender to current registration" `Quick
             test_tools_call_send_uses_current_registered_alias
         ; test_case "tools/call send binds sender even if own pid is stale" `Quick
             test_tools_call_send_uses_current_alias_even_if_pid_stale
         ; test_case "tools/call send returns receipt JSON" `Quick test_tools_call_send_returns_receipt_json
          ; test_case "tools/call debug send_msg_to_self enqueues payload" `Quick
              test_tools_call_debug_send_msg_to_self_enqueues_payload
          ; test_case "tools/call debug send_raw_to_self enqueues verbatim" `Quick
              test_tools_call_debug_send_raw_to_self_enqueues_verbatim
          ; test_case "tools/call debug send_raw_to_self rejects non-string payload" `Quick
              test_tools_call_debug_send_raw_to_self_rejects_non_string_payload
          ; test_case "tools/call debug get_env returns C2C_ vars" `Quick
              test_tools_call_debug_get_env
          ; test_case "MCP ping returns empty result not -32601 (e107929)" `Quick
             test_mcp_ping_returns_empty_result
         ; test_case "tools/call register uses current session id when omitted" `Quick
              test_tools_call_register_uses_current_session_id_when_omitted
         ; test_case "session_id_from_env falls back to CODEX_THREAD_ID" `Quick
             test_session_id_from_env_falls_back_to_codex_thread_id
         ; test_case "session_id_from_env accepts managed CODEX_THREAD_ID" `Quick
             test_session_id_from_env_accepts_managed_codex_thread_id
         ; test_case "session_id_from_env uses client-specific CLAUDE_SESSION_ID fallback" `Quick
             test_session_id_from_env_uses_client_specific_claude_fallback
         ; test_case "session_id_from_env uses client-specific opencode fallback" `Quick
             test_session_id_from_env_uses_client_specific_opencode_fallback
         ; test_case "tools/call register uses CODEX_THREAD_ID when C2C session id missing" `Quick
             test_tools_call_register_uses_codex_thread_id_when_c2c_session_id_missing
         ; test_case "tools/call register uses managed CODEX_THREAD_ID when C2C session id missing" `Quick
             test_tools_call_register_uses_managed_codex_thread_id_when_c2c_session_id_missing
         ; test_case "tools/call register uses Codex turn metadata when env missing" `Quick
             test_tools_call_register_uses_codex_turn_metadata_when_env_missing
         ; test_case "tools/call register prefers explicit client pid env" `Quick
             test_tools_call_register_prefers_explicit_client_pid_env
         ; test_case "tools/call register no alias falls back to env" `Quick
             test_tools_call_register_no_alias_falls_back_to_env
          ; test_case "tools/call register rejects alias hijack from alive session" `Quick
              test_tools_call_register_rejects_alias_hijack
          ; test_case "M4: register rejects alias with pending permission from prior owner" `Quick
              test_register_rejects_alias_with_pending_permission_from_alive_owner
          ; test_case "tools/call register allows takeover of pidless stale alias (Bug #7)" `Quick
              test_tools_call_register_allows_takeover_of_pidless_stale_alias
         ; test_case "tools/call register returns collision_exhausted when all primes taken" `Quick
             test_tools_call_register_alias_collision_exhausted
         ; test_case "tools/call register allows own alias refresh" `Quick
             test_tools_call_register_allows_own_alias_refresh
         ; test_case "tools/call register alias rename notifies rooms" `Quick
             test_tools_call_register_alias_rename_notifies_rooms
         ; test_case "server startup auto-registers alias from env" `Quick
             test_server_startup_auto_registers_alias_from_env
         ; test_case "server startup ignores dead client pid env" `Quick
             test_server_startup_auto_register_ignores_dead_client_pid_env
         ; test_case "server startup auto-register redelivers dead-letter messages" `Quick
             test_auto_register_startup_redelivers_dead_letter_messages
         ; test_case "auto_register_startup skips when alive session has different alias" `Quick
             test_auto_register_startup_skips_when_alive_session_has_different_alias
         ; test_case "auto_register_startup skips when alive session already owns alias" `Quick
             test_auto_register_startup_skips_when_alive_session_owns_alias
         ; test_case "auto_register_startup skips when alive same session has different pid" `Quick
             test_auto_register_startup_skips_when_alive_same_session_different_pid
         ; test_case "auto_join_rooms_startup joins listed rooms" `Quick
             test_auto_join_rooms_startup_joins_listed_rooms
         ; test_case "auto_join_rooms_startup prefers current registered alias" `Quick
             test_auto_join_rooms_startup_prefers_registered_alias
         ; test_case "auto_join_rooms_startup skips when no alias" `Quick
             test_auto_join_rooms_startup_skips_when_no_alias
         ; test_case "auto_join_rooms_startup empty env is noop" `Quick
             test_auto_join_rooms_startup_empty_env_is_noop
         ; test_case "tools/call whoami uses current session id when omitted" `Quick
              test_tools_call_whoami_uses_current_session_id_when_omitted
         ; test_case "tools/call whoami uses CODEX_THREAD_ID when C2C session id missing" `Quick
             test_tools_call_whoami_uses_codex_thread_id_when_c2c_session_id_missing
         ; test_case "tools/call whoami uses Codex turn metadata to find managed session" `Quick
             test_tools_call_whoami_uses_codex_turn_metadata_to_find_managed_session
         ; test_case "tools/call whoami lazily bootstraps managed Codex registration" `Quick
             test_tools_call_whoami_lazy_bootstraps_managed_codex_registration
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
         ; test_case "register writes registry.json at mode 0o600" `Quick
             test_register_writes_registry_at_0o600
         ; test_case "enqueue writes inbox file at mode 0o600" `Quick
             test_enqueue_writes_inbox_at_0o600
         ; test_case "write_json_file leaves no tmp sidecars" `Quick
             test_write_json_file_leaves_no_tmp_sidecars
         ; test_case "tools/call list includes registered_at timestamp" `Quick
             test_tools_call_list_includes_registered_at
         ; test_case "tools/call list reports alive tristate per peer" `Quick
             test_tools_call_list_reports_alive_tristate
         ; test_case "concurrent register does not lose entries" `Quick
             test_concurrent_register_does_not_lose_entries
         ; test_case "register evicts prior reg with same alias" `Quick
             test_register_evicts_prior_reg_with_same_alias
         ; test_case "register migrates undrained inbox on alias re-register"
             `Quick test_register_migrates_undrained_inbox_on_alias_re_register
         ; test_case "register serializes with concurrent enqueue" `Quick
             test_register_serializes_with_concurrent_enqueue
         ; test_case "concurrent enqueue does not lose messages" `Quick
             test_concurrent_enqueue_does_not_lose_messages
         ; test_case "sweep drops dead reg and its inbox" `Quick
             test_sweep_drops_dead_reg_and_its_inbox
         ; test_case "sweep deletes orphan inbox file" `Quick
             test_sweep_deletes_orphan_inbox_file
         ; test_case "sweep preserves live reg and its inbox" `Quick
             test_sweep_preserves_live_reg_and_its_inbox
         ; test_case "sweep preserves legacy pidless reg" `Quick
             test_sweep_preserves_legacy_pidless_reg
         ; test_case "sweep preserves non-empty orphan to dead-letter" `Quick
             test_sweep_preserves_nonempty_orphan_to_dead_letter
         ; test_case "sweep empty orphan writes no dead-letter" `Quick
             test_sweep_empty_orphan_writes_no_dead_letter
         ; test_case "sweep preserves fresh provisional reg" `Quick
             test_sweep_preserves_fresh_provisional_reg
         ; test_case "sweep drops expired provisional reg" `Quick
             test_sweep_drops_expired_provisional_reg
         ; test_case "confirm_registration sets confirmed_at" `Quick
             test_confirm_registration_sets_confirmed_at
         ; test_case "confirmed reg not swept after timeout" `Quick
             test_confirmed_reg_not_swept_after_timeout
         ; test_case "human client_type exempt from provisional sweep" `Quick
             test_human_client_type_exempt_from_provisional_sweep
         ; test_case "sweep evicts dead members from rooms" `Quick
             test_sweep_evicts_dead_members_from_rooms
         ; test_case "prune_rooms evicts dead members without touching registrations" `Quick
             test_prune_rooms_evicts_dead_members_without_touching_registrations
         ; test_case "prune_rooms noop when all members alive" `Quick
             test_prune_rooms_noop_when_all_members_alive
         ; test_case "tools/call prune_rooms evicts dead members via MCP" `Quick
             test_tools_call_prune_rooms_via_mcp
         ; test_case "prune_rooms evicts pidless zombie members (Unknown liveness)" `Quick
             test_prune_rooms_evicts_pidless_zombie_members
         ; test_case "liveness: pid+no_start_time shows Unknown not Alive (ghost-alive fix)" `Quick
             test_liveness_unverified_pid_shows_unknown
         ; test_case "prune_rooms keeps unverified-pid member (conservative)" `Quick
             test_prune_rooms_keeps_unverified_pid_member
         ; test_case "prune_rooms evicts orphan room members" `Quick
             test_prune_rooms_evicts_orphan_room_members
         ; test_case "register redelivers dead-letter on same session_id" `Quick
             test_register_redelivers_dead_letter_on_same_session_id
         ; test_case "register redelivers dead-letter by alias (new session_id)" `Quick
             test_register_redelivers_dead_letter_by_alias_for_new_session_id
         ; test_case "send_all fans out and skips sender" `Quick
             test_send_all_fans_out_and_skips_sender
         ; test_case "send_all honors exclude_aliases" `Quick
             test_send_all_honors_exclude_aliases
         ; test_case "send_all skips dead recipients with reason" `Quick
             test_send_all_skips_dead_recipients_with_reason
         ; test_case "send_all sender-only registry returns empty result"
             `Quick test_send_all_sender_only_registry_returns_empty_result
         ; test_case "tools/call send_all routes through broker and returns result" `Quick
             test_tools_call_send_all_routes_through_broker_and_returns_result
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
         ; test_case "join_room creates room and adds member" `Quick
             test_join_room_creates_room_and_adds_member
         ; test_case "join_room is idempotent" `Quick
             test_join_room_is_idempotent
         ; test_case "join_room broadcasts system message to all members" `Quick
             test_join_room_broadcasts_system_message_to_all_members
         ; test_case "join_room idempotent does not rebroadcast" `Quick
             test_join_room_idempotent_does_not_rebroadcast
         ; test_case "join_room idempotent non-tail member does not rebroadcast" `Quick
             test_join_room_idempotent_non_tail_member_does_not_rebroadcast
         ; test_case "leave_room removes member" `Quick
             test_leave_room_removes_member
         ; test_case "delete_room succeeds when empty" `Quick
             test_delete_room_succeeds_when_empty
         ; test_case "delete_room fails when has members" `Quick
             test_delete_room_fails_when_has_members
         ; test_case "send_room appends history and fans out" `Quick
             test_send_room_appends_history_and_fans_out
         ; test_case "send_room skips sender inbox" `Quick
             test_send_room_skips_sender_inbox
         ; test_case "send_room deduplicates identical content within window" `Quick
             test_send_room_deduplicates_identical_content_within_window
         ; test_case "send_room does not dedup different content" `Quick
             test_send_room_does_not_dedup_different_content
         ; test_case "list_rooms returns rooms with members" `Quick
             test_list_rooms_returns_room_with_members
         ; test_case "room_history returns last N lines" `Quick
             test_room_history_returns_last_n_lines
         ; test_case "room_history empty room returns empty" `Quick
             test_room_history_empty_room
         ; test_case "tools/call join_room via MCP" `Quick
             test_tools_call_join_room_via_mcp
         ; test_case "tools/call join_room backfills recent history" `Quick
             test_tools_call_join_room_backfills_recent_history
         ; test_case "tools/call join_room history_limit=0 opts out" `Quick
             test_tools_call_join_room_respects_history_limit_zero
         ; test_case "tools/call peek_inbox does not drain" `Quick
             test_tools_call_peek_inbox_does_not_drain
         ; test_case "tools/call peek_inbox ignores session_id arg" `Quick
             test_tools_call_peek_inbox_ignores_session_id_argument
         ; test_case "my_rooms returns only caller's memberships" `Quick
             test_my_rooms_returns_only_sessions_memberships
         ; test_case "tools/call my_rooms uses env session_id, ignores args" `Quick
             test_tools_call_my_rooms_uses_env_session_id
         ; test_case "tools/call tail_log returns audit entries" `Quick
             test_tools_call_tail_log_returns_audit_entries
         ; test_case "tools/call appends to broker.log" `Quick
             test_tools_call_appends_to_broker_log
         ; test_case "tools/call send_room via MCP" `Quick
             test_tools_call_send_room_via_mcp
         ; test_case "tools/call send_room accepts `alias` as from_alias fallback" `Quick
             test_tools_call_send_room_accepts_alias_as_from_alias_alias
         ; test_case "tools/call send_room uses current session alias when omitted" `Quick
             test_tools_call_send_room_uses_current_session_alias_when_omitted
         ; test_case "tools/call send_room missing sender alias is actionable" `Quick
             test_tools_call_send_room_missing_sender_alias_is_actionable
         ; test_case "tools/call join_room accepts `from_alias` as alias fallback" `Quick
             test_tools_call_join_room_accepts_from_alias_as_alias
         ; test_case "tools/call leave_room accepts `from_alias` as alias fallback" `Quick
             test_tools_call_leave_room_accepts_from_alias_as_alias
         ; test_case "tools/call join_room missing alias is actionable" `Quick
             test_tools_call_join_room_missing_alias_is_actionable
         ; test_case "tools/call leave_room missing alias is actionable" `Quick
             test_tools_call_leave_room_missing_alias_is_actionable
         ; test_case "room_history limit larger than total returns all" `Quick
             test_room_history_limit_larger_than_total_returns_all
         ; test_case "room_history preserves sender identity across multiple senders" `Quick
             test_room_history_preserves_multiple_senders
          ; test_case "large inbox drains all messages correctly" `Quick
              test_large_inbox_drains_all_messages
          ; test_case "send remote alias appends to outbox" `Quick
              test_send_remote_alias_appends_to_outbox
          ; test_case "room_history limit=1 returns only last message" `Quick
              test_room_history_limit_one_returns_last
         ; test_case "register rename fans out peer_renamed notification" `Quick
             test_register_rename_fans_out_peer_renamed_notification
         ; test_case "new peer registration broadcasts peer_register to swarm-lounge" `Quick
             test_register_new_peer_broadcasts_peer_register_to_swarm_lounge
         ; test_case "join_room updates session_id when alias rejoins with new session" `Quick
             test_join_room_updates_session_id_on_alias_rejoin
         ; test_case "join_room updates alias when session rejoins with new alias" `Quick
             test_join_room_updates_alias_on_session_rejoin
         ; test_case "tools/call send rejects impersonation of alive alias" `Quick
             test_tools_call_send_rejects_impersonation
         ; test_case "tools/call send_all rejects impersonation of alive alias" `Quick
             test_tools_call_send_all_rejects_impersonation
         ; test_case "tools/call send_room rejects impersonation of alive alias" `Quick
             test_tools_call_send_room_rejects_impersonation
         ; test_case "send_room_invite adds to invite list" `Quick
             test_send_room_invite_adds_to_invite_list
         ; test_case "send_room_invite only member can invite" `Quick
             test_send_room_invite_only_member_can_invite
         ; test_case "join_room invite_only rejects uninvited" `Quick
             test_join_room_invite_only_rejects_uninvited
         ; test_case "join_room invite_only accepts invited" `Quick
             test_join_room_invite_only_accepts_invited
         ; test_case "set_room_visibility changes mode" `Quick
             test_set_room_visibility_changes_mode
         ; test_case "set_room_visibility only member can change" `Quick
             test_set_room_visibility_only_member_can_change
         ; test_case "list_rooms includes visibility and invited_members" `Quick
             test_list_rooms_includes_visibility_and_invited_members
         ; test_case "tools/call send_room_invite via MCP" `Quick
             test_tools_call_send_room_invite_via_mcp
         ; test_case "tools/call set_room_visibility via MCP" `Quick
             test_tools_call_set_room_visibility_via_mcp
          ; test_case "join_room invite_only rejects uninvited via MCP" `Quick
              test_join_room_invite_only_rejects_uninvited_via_mcp
          ; test_case "open_pending_reply via MCP" `Quick
              test_open_pending_reply_via_mcp
          ; test_case "check_pending_reply valid supervisor via MCP" `Quick
              test_check_pending_reply_valid_supervisor_via_mcp
          ; test_case "check_pending_reply unknown perm_id via MCP" `Quick
              test_check_pending_reply_unknown_perm_id_via_mcp
           ; test_case "check_pending_reply non-supervisor via MCP" `Quick
               test_check_pending_reply_non_supervisor_via_mcp
           ; test_case "prompts/list returns skills as prompts" `Quick
               test_prompts_list_via_subprocess
           ; test_case "prompts/get returns skill content" `Quick
               test_prompts_get_via_subprocess
           ; test_case "prompts/get unknown skill returns error" `Quick
               test_prompts_get_unknown_via_subprocess
           ; test_case "read_and_delete_orphan_inbox captures and deletes" `Quick
               test_read_and_delete_orphan_inbox_captures_and_deletes
           ; test_case "read_and_delete_orphan_inbox missing file returns empty" `Quick
               test_read_and_delete_orphan_inbox_missing_file_returns_empty
           ; test_case "replay_pending_orphan_inbox appends to live inbox" `Quick
               test_replay_pending_orphan_inbox_appends_to_live_inbox
           ; test_case "replay_pending_orphan_inbox missing pending file returns zero" `Quick
               test_replay_pending_orphan_inbox_missing_pending_file_returns_zero
           ; test_case "replay_pending_orphan_inbox empty pending file returns zero and deletes" `Quick
               test_replay_pending_orphan_inbox_empty_pending_file_returns_zero_and_deletes
           ; test_case "discover_live_pid finds matching session" `Quick
               test_discover_live_pid_finds_matching_session
           ; test_case "discover_live_pid returns None when no match" `Quick
               test_discover_live_pid_returns_none_when_no_match
           ; test_case "discover_live_pid skips unreadable environ" `Quick
               test_discover_live_pid_skips_unreadable_environ
           ; test_case "refresh_pid_if_dead noops when pidless" `Quick
               test_refresh_pid_if_dead_noops_when_pidless
           ; test_case "refresh_pid_if_dead noops when alive" `Quick
               test_refresh_pid_if_dead_noops_when_alive
           ; test_case "refresh_pid_if_dead updates when dead and live discovered" `Quick
               test_refresh_pid_if_dead_updates_when_dead_and_live_discovered
           ; test_case "refresh_pid_if_dead noops when no replacement discovered" `Quick
               test_refresh_pid_if_dead_noops_when_no_replacement_discovered
           ; test_case "resolve alias self-heals dead target via inject" `Quick
               test_resolve_alias_self_heals_dead_target_via_inject
           ; test_case "enqueue self-heals dead target via resolver hooks (end-to-end)" `Quick
               test_enqueue_self_heals_dead_target_via_resolver_hooks
           ; test_case "proc hooks clear restores real /proc" `Quick
               test_proc_hooks_clear_restores_real_proc
           ; test_case "notify_shared_with DMs listed recipients" `Quick
               test_notify_shared_with_dms_listed_recipients
           ; test_case "notify_shared_with skips self in recipients" `Quick
               test_notify_skips_self_in_recipients
           ; test_case "notify_shared_with skipped when globally shared" `Quick
               test_notify_skipped_when_globally_shared
           ; test_case "notify_shared_with silently skips unknown alias" `Quick
               test_notify_silently_skips_unknown_alias
           ; test_case "notify_shared_with empty shared_with is noop" `Quick
               test_notify_empty_shared_with_is_noop
           ] ) ]
