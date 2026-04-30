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

let is_hex_sha256 s =
  String.length s = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       s

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

(* #307a: delivery_mode_histogram counts by deferrable flag and groups
   by sender alias. The archive carries the deferrable field at write
   time (see append_archive); v1 of this slice exposes it through
   archive_entry.ae_deferrable so the histogram can count without new
   broker instrumentation. *)
let test_delivery_mode_histogram_counts_and_by_sender () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-coord"
        ~alias:"coord" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-relay"
        ~alias:"relay" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-recv307"
        ~alias:"recv307" ~pid:None ~pid_start_time:None ();
      (* coord: 4 push (deferrable=false), 0 poll. *)
      for i = 1 to 4 do
        C2c_mcp.Broker.enqueue_message broker ~from_alias:"coord"
          ~to_alias:"recv307" ~content:(Printf.sprintf "c%d" i) ()
      done;
      (* relay: 1 push, 2 poll (deferrable=true). *)
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"relay"
        ~to_alias:"recv307" ~content:"r-push" ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"relay"
        ~to_alias:"recv307" ~content:"r-def-1" ~deferrable:true ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"relay"
        ~to_alias:"recv307" ~content:"r-def-2" ~deferrable:true ();
      (* drain to archive. *)
      let _ = C2c_mcp.Broker.drain_inbox broker ~session_id:"s-recv307" in
      let result =
        C2c_mcp.Broker.delivery_mode_histogram broker
          ~session_id:"s-recv307" ()
      in
      check int "total = 7" 7 result.C2c_mcp.Broker.dmh_total;
      check int "push intent = 5" 5 result.dmh_push;
      check int "poll-only = 2" 2 result.dmh_poll;
      check int "two senders" 2 (List.length result.dmh_by_sender);
      (* coord first (sorted by total desc). *)
      let coord = List.hd result.dmh_by_sender in
      check string "first sender by total = coord" "coord" coord.dms_alias;
      check int "coord total = 4" 4 coord.dms_total;
      check int "coord push = 4" 4 coord.dms_push;
      check int "coord poll = 0" 0 coord.dms_poll;
      let relay = List.nth result.dmh_by_sender 1 in
      check string "second sender = relay" "relay" relay.dms_alias;
      check int "relay total = 3" 3 relay.dms_total;
      check int "relay push = 1" 1 relay.dms_push;
      check int "relay poll = 2" 2 relay.dms_poll)

let test_delivery_mode_histogram_last_n_filter () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-snd-ln"
        ~alias:"snd-ln" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-rcv-ln"
        ~alias:"rcv-ln" ~pid:None ~pid_start_time:None ();
      for i = 1 to 6 do
        let deferrable = i mod 2 = 0 in
        C2c_mcp.Broker.enqueue_message broker ~from_alias:"snd-ln"
          ~to_alias:"rcv-ln" ~content:(Printf.sprintf "m%d" i)
          ~deferrable ()
      done;
      let _ = C2c_mcp.Broker.drain_inbox broker ~session_id:"s-rcv-ln" in
      (* last 3 should be m4 (def), m5 (push), m6 (def) → 1 push, 2 poll. *)
      let result =
        C2c_mcp.Broker.delivery_mode_histogram broker
          ~session_id:"s-rcv-ln" ~last_n:3 ()
      in
      check int "last_n=3 total" 3 result.C2c_mcp.Broker.dmh_total;
      check int "last_n=3 push = 1" 1 result.dmh_push;
      check int "last_n=3 poll = 2" 2 result.dmh_poll)

let test_delivery_mode_histogram_empty_archive_is_zero () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result =
        C2c_mcp.Broker.delivery_mode_histogram broker
          ~session_id:"never-archived" ()
      in
      check int "empty archive => total 0" 0 result.C2c_mcp.Broker.dmh_total;
      check int "empty archive => push 0" 0 result.dmh_push;
      check int "empty archive => poll 0" 0 result.dmh_poll;
      check int "no senders" 0 (List.length result.dmh_by_sender))

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
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "debate me"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
  in
  let open Yojson.Safe.Util in
  check string "jsonrpc" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel" (json |> member "method" |> to_string);
  check string "content" "debate me" (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from" |> to_string);
  check string "to alias meta" "storm-storm"
    (json |> member "params" |> member "meta" |> member "to" |> to_string)

let test_channel_notification_empty_content () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = ""; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
  in
  let open Yojson.Safe.Util in
  check string "jsonrpc" "2.0" (json |> member "jsonrpc" |> to_string);
  check string "method" "notifications/claude/channel"
    (json |> member "method" |> to_string);
  check string "content is empty string" ""
    (json |> member "params" |> member "content" |> to_string);
  check string "from alias meta" "storm-ember"
    (json |> member "params" |> member "meta" |> member "from" |> to_string);
  check string "to alias meta" "storm-storm"
    (json |> member "params" |> member "meta" |> member "to" |> to_string)

let test_channel_notification_special_chars () =
  let content = "line1\nline2\t\"quoted\" <angle> \xc3\xa9\xc3\xa0\xc3\xbc" in
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
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
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "test"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
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
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "check method"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
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
      { from_alias = "cairn-vigil"; to_alias = "stanza-coder"; content = "hi"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
  in
  let open Yojson.Safe.Util in
  let meta = json |> member "params" |> member "meta" in
  check string "role in meta" "coordinator" (meta |> member "role" |> to_string);
  check string "from preserved" "cairn-vigil" (meta |> member "from" |> to_string)

let test_channel_notification_without_role_omits () =
  let json =
    C2c_mcp.channel_notification
      { from_alias = "storm-ember"; to_alias = "storm-storm"; content = "hi"; deferrable = false; reply_via = None; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }
  in
  let open Yojson.Safe.Util in
  let meta = json |> member "params" |> member "meta" in
  (* role attribute must be absent (not null, not empty string) when not set *)
  check bool "no role field when None" true (member "role" meta = `Null)

(* #157 — channel_notification meta ts field *)
let test_channel_notification_ts_utc_hhmm () =
  (* 1746009600.0 = 2025-04-30 10:40:00 UTC — a known timestamp whose
     HH:MM string is "10:40".  We verify:
       (a) ts key is present in meta
       (b) value is exactly "10:40" (5-char, double-digit fields, colon separator)
       (c) format matches \d\d:\d\d (no leading junk, no seconds)
     Mirror of format_c2c_envelope: Printf.sprintf "%02d:%02d" tm.tm_hour tm.tm_min. *)
  let json =
    C2c_mcp.channel_notification
      { from_alias = "jungle-coder"; to_alias = "stanza-coder"; content = "ping"; deferrable = false; reply_via = None; enc_status = None; ts = 1746009600.0; ephemeral = false; message_id = None }
  in
  let open Yojson.Safe.Util in
  let meta = json |> member "params" |> member "meta" in
  let ts_val = meta |> member "ts" |> to_string in
  check string "ts is 10:40" "10:40" ts_val;
  check int "ts length is 5" 5 (String.length ts_val);
  (* Structural format check: DD:DD *)
  let is_digit c = c >= '0' && c <= '9' in
  check bool "ts format is DD:DD" true
    (is_digit ts_val.[0] && is_digit ts_val.[1]
     && ts_val.[2] = ':' && is_digit ts_val.[3] && is_digit ts_val.[4])

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

let assert_server_runtime_identity server_info =
  let open Yojson.Safe.Util in
  check int "runtime identity schema" 1
    (server_info |> member "runtime_identity" |> member "schema" |> to_int);
  check bool "runtime pid is positive" true
    (server_info |> member "runtime_identity" |> member "pid" |> to_int > 0);
  check bool "runtime started_at is positive" true
    (server_info |> member "runtime_identity" |> member "started_at" |> to_float > 0.);
  check bool "runtime executable path is present" true
    (server_info |> member "runtime_identity" |> member "executable" |> to_string <> "");
  check bool "runtime executable mtime is positive" true
    (server_info |> member "runtime_identity" |> member "executable_mtime" |> to_float
    > 0.);
  check bool "runtime executable sha256 is hex" true
    (server_info |> member "runtime_identity" |> member "executable_sha256" |> to_string
    |> is_hex_sha256)

let test_initialize_reports_server_runtime_identity () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1201)
          ; ("method", `String "initialize")
          ; ("params", `Assoc [])
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected initialize response"
      | Some json ->
          let open Yojson.Safe.Util in
          assert_server_runtime_identity
            (json |> member "result" |> member "serverInfo"))

let test_tools_call_server_info_reports_runtime_identity () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1202)
          ; ("method", `String "tools/call")
          ; ( "params",
              `Assoc
                [ ("name", `String "server_info")
                ; ("arguments", `Assoc [])
                ] )
          ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
      match response with
      | None -> fail "expected tools/call response"
      | Some json ->
          let open Yojson.Safe.Util in
          let content =
            json |> member "result" |> member "content" |> to_list |> List.hd
            |> member "text" |> to_string |> Yojson.Safe.from_string
          in
          assert_server_runtime_identity content)

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

let test_send_and_set_dnd_schema_types_are_correct () =
  with_temp_dir (fun dir ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 999)
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
          let send_tool = find_tool "send" in
          let set_dnd_tool = find_tool "set_dnd" in
          let send_props = send_tool |> member "inputSchema" |> member "properties" in
          let set_dnd_props = set_dnd_tool |> member "inputSchema" |> member "properties" in
          let prop_type_string tool_props prop_name =
            tool_props |> member prop_name |> member "type" |> to_string
          in
          (* Regression test: send.deferrable and send.ephemeral must be boolean *)
          check string "send.deferrable is boolean" "boolean"
            (prop_type_string send_props "deferrable");
          check string "send.ephemeral is boolean" "boolean"
            (prop_type_string send_props "ephemeral");
          (* Regression test: set_dnd.on must be boolean, until_epoch must be number *)
          check string "set_dnd.on is boolean" "boolean"
            (prop_type_string set_dnd_props "on");
          check string "set_dnd.until_epoch is number" "number"
            (prop_type_string set_dnd_props "until_epoch"))

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

(* #432 follow-up (slate-coder 2026-04-29): the MCP register tool's
   alias_hijack_conflict guard must compare aliases case-insensitively.
   Pre-fix, an attacker could register "foo-bar" against a victim
   holding "Foo-Bar" — the hijack guard's raw `=` would miss the
   collision, but the eviction predicate at L1898 is case-fold and
   would still evict the victim, hijacking inbox + identity.
   See
   .collab/findings/2026-04-29T14-25-00Z-slate-coder-alias-casefold-guard-asymmetry-takeover.md. *)
let test_tools_call_register_rejects_alias_hijack_casefold_asymmetry () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Victim registers original-case alias with a live PID *)
      C2c_mcp.Broker.register broker ~session_id:"session-victim"
        ~alias:"Foo-Bar" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* Queue a message on the victim's inbox so we can detect any
         migration that would happen if the guard was bypassed and
         eviction (which IS case-fold) ran against the victim row. *)
      C2c_mcp.Broker.enqueue_message broker
        ~from_alias:"third-party" ~to_alias:"Foo-Bar"
        ~content:"victim-only message" ();
      let victim_inbox_path =
        Filename.concat dir "session-victim.inbox.json"
      in
      let victim_inbox_before =
        if Sys.file_exists victim_inbox_path then
          Some (let ic = open_in victim_inbox_path in
                let len = in_channel_length ic in
                let s = really_input_string ic len in
                close_in ic; s)
        else None
      in
      check bool "victim inbox file exists pre-attack" true
        (victim_inbox_before <> None);
      (* Attacker uses a different session_id and the lower-case form. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-attacker";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 4329)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "register")
                    ; ( "arguments",
                        `Assoc [ ("alias", `String "foo-bar") ] )
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
                 json |> member "result" |> member "isError"
                 |> to_bool_option |> Option.value ~default:false
               in
               check bool "casefold-asymmetry hijack rejected (isError=true)"
                 true is_error;
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               check bool "error mentions contested alias" true
                 (string_contains text "foo-bar");
               check bool "error mentions victim's holder session" true
                 (string_contains text "session-victim");
               let parsed = Yojson.Safe.from_string text in
               let collision =
                 parsed |> member "collision" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "collision flag set" true collision);
          (* Victim row in the registry is UNCHANGED — same session_id,
             original-case alias preserved. *)
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          let victim =
            List.find_opt (fun r -> r.session_id = "session-victim") regs
          in
          check bool "victim registration preserved" true (victim <> None);
          check string "victim alias unchanged (original case)" "Foo-Bar"
            (Option.get victim).alias;
          let attacker =
            List.find_opt (fun r -> r.session_id = "session-attacker") regs
          in
          check bool "attacker did NOT register" true (attacker = None);
          (* Victim's inbox file is byte-for-byte unchanged — no
             migration to attacker's session occurred. *)
          let victim_inbox_after =
            if Sys.file_exists victim_inbox_path then
              Some (let ic = open_in victim_inbox_path in
                    let len = in_channel_length ic in
                    let s = really_input_string ic len in
                    close_in ic; s)
            else None
          in
          check bool "victim inbox file still exists post-attack" true
            (victim_inbox_after <> None);
          check bool "victim inbox unchanged (no migration to attacker)" true
            (victim_inbox_before = victim_inbox_after);
          (* Attacker's inbox file does NOT exist — nothing was migrated. *)
          let attacker_inbox_path =
            Filename.concat dir "session-attacker.inbox.json"
          in
          check bool "no inbox file created for attacker session" false
            (Sys.file_exists attacker_inbox_path)))

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

let test_guard1_pidless_zombie_does_not_fire_hijack () =
  (* #345: a pidless zombie row (e.g. left by post-OOM cleanup) sharing the
     same session_id but a different alias must NOT block a legitimate
     resume that re-registers under a new alias. Guard 1 must skip
     pid=None rows. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Pre-register a pidless zombie row with alias "old-zombie-alias" *)
      C2c_mcp.Broker.register broker
        ~session_id:"shared-session" ~alias:"old-zombie-alias"
        ~pid:None ~pid_start_time:None ();
      (* Legitimate resume: same session_id, different alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "shared-session";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "fresh-alias";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          check bool "fresh-alias registered (zombie did not block hijack guard)"
            true (List.exists (fun r -> r.alias = "fresh-alias") regs)))

let test_guard2_pidless_zombie_does_not_block_post_oom_resume () =
  (* #345 (highest-impact site): post-OOM swarm-dance — the prior session
     left a pidless zombie row owning alias "kimi-nova". The legitimate
     fresh session has the same env-configured alias but a new session_id
     + pid. Guard 2 must skip pid=None rows so the resume registers. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Pre-register a pidless zombie owning alias "kimi-nova" under a stale session_id *)
      C2c_mcp.Broker.register broker
        ~session_id:"crashed-session" ~alias:"kimi-nova"
        ~pid:None ~pid_start_time:None ();
      (* Legitimate fresh-session resume with same alias *)
      Unix.putenv "C2C_MCP_SESSION_ID" "fresh-session-after-oom";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "kimi-nova";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          (* The fresh session must be registered (zombie did not block) *)
          let fresh =
            List.find_opt
              (fun r ->
                 r.session_id = "fresh-session-after-oom"
                 && r.alias = "kimi-nova")
              regs
          in
          check bool "fresh post-OOM registration succeeded"
            true (Option.is_some fresh)))

let test_guard4_pidless_zombie_does_not_trigger_same_pid_alive () =
  (* #345 defense-in-depth: a pidless zombie row with a different
     session_id and different alias must NOT match Guard 4's same-pid
     predicate, even if `pid` were ever to fall back to None in the
     future. Today this is structurally enforced by the `pid` fallback
     to Unix.getppid (), but the explicit `Option.is_some reg.pid`
     filter pins the predicate semantics. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Pre-register a pidless zombie with a different session_id + alias *)
      C2c_mcp.Broker.register broker
        ~session_id:"old-session" ~alias:"old-alias"
        ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "new-session";
      Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "new-alias";
      Fun.protect
        ~finally:(fun () ->
          Unix.putenv "C2C_MCP_SESSION_ID" "";
          Unix.putenv "C2C_MCP_AUTO_REGISTER_ALIAS" "")
        (fun () ->
          C2c_mcp.auto_register_startup ~broker_root:dir;
          let regs = C2c_mcp.Broker.list_registrations broker in
          let open C2c_mcp in
          let new_reg =
            List.find_opt
              (fun r ->
                 r.session_id = "new-session"
                 && r.alias = "new-alias")
              regs
          in
          check bool "new registration succeeded (Guard 4 did not fire on pidless)"
            true (Option.is_some new_reg)))

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
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
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
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
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
    ; ed25519_pubkey = None
    ; pubkey_signed_at = None
    ; pubkey_sig = None
    ; compacting = None
    ; last_activity_ts = None
    ; role = None
    ; compaction_count = 0
    ; automated_delivery = None
    ; tmux_location = None
    }
  in
  check bool "pid exists + no stored start_time → alive" true
    (C2c_mcp.Broker.registration_is_alive reg)

(* E2E S2: lazy-create Ed25519 key on first register via handle_tool_call.
   Verifies: (i) key file created at <broker_root>/keys/<alias>.ed25519 mode 0600,
   (ii) ed25519_pubkey + pubkey_signed_at + pubkey_sig all populated. *)
let test_ed25519_lazy_create_on_first_register () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let keys_dir = Filename.concat dir "keys" in
      let args = `Assoc [ ("alias", `String "lazy-test");
                           ("enc_pubkey", `String "x25519_dummy_pk_for_lazy_test_b64") ]
      in
      let _response = Lwt_main.run (C2c_mcp.handle_tool_call
        ~broker ~session_id_override:(Some "lazy-sid")
        ~tool_name:"register" ~arguments:args)
      in
      (* (i): key file must exist with mode 0600. *)
      let key_path = Filename.concat keys_dir "lazy-test.ed25519" in
      Alcotest.(check bool) "key file created" true (Sys.file_exists key_path);
      let stat = Unix.stat key_path in
      let mode = stat.Unix.st_perm in
      Alcotest.(check bool) "key file mode 0600" true ((mode land 0o777) = 0o600);
      (* (ii): ed25519_pubkey + pubkey_signed_at + pubkey_sig must be populated. *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      match List.find_opt (fun r -> r.C2c_mcp.alias = "lazy-test") regs with
      | None -> Alcotest.fail "registration not found"
      | Some r ->
          (match r.C2c_mcp.ed25519_pubkey with
           | None -> Alcotest.fail "ed25519_pubkey should be populated (lazy-create fired)"
           | Some _ -> ());
          (match r.C2c_mcp.pubkey_signed_at with
           | None -> Alcotest.fail "pubkey_signed_at should be populated"
           | Some _ -> ());
          (match r.C2c_mcp.pubkey_sig with
           | None -> Alcotest.fail "pubkey_sig should be populated"
           | Some _ -> ()))

(* CRIT-2 register-path: read whole broker.log file as a single string
   (mirrors test_slice_b_followup_pin_mismatch_audit_log shape). *)
let read_broker_log_full dir =
  let path = Filename.concat dir "broker.log" in
  let ic = open_in path in
  let buf = Buffer.create 1024 in
  (try
     while true do Buffer.add_channel buf ic 1024 done
   with End_of_file -> ());
  close_in ic;
  Buffer.contents buf

let log_contains_substr log_content sub =
  try ignore (Str.search_forward (Str.regexp_string sub) log_content 0); true
  with Not_found -> false

(* E2E S2: when ed25519 pubkey mismatches the TOFU pin, handle_tool_call
   returns an error without creating a registration.
   Verifies: (i) error response, (ii) no registration created,
   (iii) relay_pins.json still holds the original pin,
   (iv) [CRIT-2] broker.log gets a relay_e2e_register_pin_mismatch
   audit line carrying alias + key_class + pinned_b64. *)
let test_register_rejects_ed25519_mismatch () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Pre-pin an ed25519 pubkey for alias "mismatch-ed". *)
      ignore (C2c_mcp.Broker.pin_ed25519_sync ~alias:"mismatch-ed" ~pk:"pk-old-b64");
      (* Drive register through the handler layer so pin-checking fires.
         Pass enc_pubkey so handler attempts lazy ed25519 creation — the new key
         will differ from the pre-pinned pk, triggering mismatch. *)
      let args = `Assoc [ ("alias", `String "mismatch-ed");
                           ("enc_pubkey", `String "x25519_dummy_pk_b64") ]
      in
      let response = Lwt_main.run (C2c_mcp.handle_tool_call
        ~broker ~session_id_override:(Some "mismatch-ed-sid")
        ~tool_name:"register" ~arguments:args)
      in
      let open Yojson.Safe.Util in
      let is_error = match response |> member "isError" with `Bool b -> b | _ -> false in
      Alcotest.(check bool) "response is error" true is_error;
      (* (ii): no registration for "mismatch-ed". *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      Alcotest.(check bool) "no registration for mismatched alias" true
        (List.for_all (fun r -> r.C2c_mcp.alias <> "mismatch-ed") regs);
      (* (iii): relay_pins.json still pins pk-old under "ed25519" key. *)
      let pins_path = Filename.concat dir "relay_pins.json" in
      Alcotest.(check bool) "relay_pins.json exists" true (Sys.file_exists pins_path);
      let pins_json = Yojson.Safe.from_file pins_path in
      let ed_pins = match pins_json |> Yojson.Safe.Util.member "ed25519" with
        | `Assoc l ->
            (match List.assoc_opt "mismatch-ed" l with
             | Some (`String s) -> Some s | _ -> None)
        | _ -> None
      in
      Alcotest.(check (option string)) "ed25519 pin still pk-old"
        (Some "pk-old-b64") ed_pins;
      (* (iv) CRIT-2: audit-log line emitted on broker.log. *)
      let log_path = Filename.concat dir "broker.log" in
      Alcotest.(check bool) "broker.log written" true (Sys.file_exists log_path);
      let log_content = read_broker_log_full dir in
      Alcotest.(check bool) "audit-log has relay_e2e_register_pin_mismatch event" true
        (log_contains_substr log_content "\"event\":\"relay_e2e_register_pin_mismatch\"");
      Alcotest.(check bool) "audit-log carries alias" true
        (log_contains_substr log_content "\"alias\":\"mismatch-ed\"");
      Alcotest.(check bool) "audit-log key_class is ed25519" true
        (log_contains_substr log_content "\"key_class\":\"ed25519\"");
      Alcotest.(check bool) "audit-log carries pinned_b64=pk-old-b64" true
        (log_contains_substr log_content "\"pinned_b64\":\"pk-old-b64\""))

(* E2E S2: when x25519 pubkey mismatches the TOFU pin, handle_tool_call
   returns an error without creating a registration.
   Verifies: (i) error response, (ii) no registration created,
   (iii) relay_pins.json still holds the original x25519 pin,
   (iv) [CRIT-2] broker.log gets a relay_e2e_register_pin_mismatch
   audit line for the x25519 class with claimed_b64 + pinned_b64,
   (v) [CRIT-2 invariant] when Ed25519 is pre-pinned to a key K AND
   that exact key is the one the handler sees on disk (Already_pinned
   path), an x25519-only mismatch reject MUST leave the Ed25519 pin
   completely untouched (still K). This is the load-bearing CRIT-2
   invariant: a single-class register failure cannot collateral-damage
   a sibling pin. *)
let test_register_rejects_x25519_mismatch () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let alias = "mismatch-x25519" in
      (* CRIT-2 invariant setup: pre-create an Ed25519 keypair on disk
         at the broker's per-alias key path so the handler's lazy-load
         branch (Sys.file_exists priv_path = true) returns the same
         key, then pre-pin the matching pubkey. This means Ed25519 will
         take the [Already_pinned] path during register and *only* the
         X25519 mismatch fires. *)
      let keys_dir = Filename.concat dir "keys" in
      (try Unix.mkdir keys_dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let priv_path = Filename.concat keys_dir (alias ^ ".ed25519") in
      let ed_id = Relay_identity.load_or_create_at ~path:priv_path ~alias_hint:alias in
      let ed_pinned_b64 = Relay_identity.b64url_encode ed_id.Relay_identity.public_key in
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias ~pk:ed_pinned_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial Ed25519 pre-pin");
      (* Pre-pin an x25519 pubkey for the alias. *)
      ignore (C2c_mcp.Broker.pin_x25519_sync ~alias ~pk:"x25519-old-b64");
      (* Pre-generate the X25519 key the handler will load, by pointing
         C2C_KEY_DIR at our temp dir and calling [Relay_enc.load_or_generate]
         ourselves first. The handler ignores any [enc_pubkey] arg and
         always uses [Relay_enc.load_or_generate] for the broker-side
         X25519, so this gives us the exact [claimed_b64] value the
         audit-log line will carry. *)
      let x25519_key_dir = Filename.concat dir "x25519-keys" in
      (try Unix.mkdir x25519_key_dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      Unix.putenv "C2C_KEY_DIR" x25519_key_dir;
      let claimed_x25519_b64 =
        match Relay_enc.load_or_generate ~alias () with
        | Ok enc -> Relay_enc.public_key_b64 enc
        | Error e -> Alcotest.failf "Relay_enc.load_or_generate setup failed: %s" e
      in
      (* Drive register through the handler. Handler will [load_or_generate]
         the same X25519 key (cached in our temp dir), produce the same
         pubkey, hit the pre-pinned mismatch ("x25519-old-b64"), and reject.
         Ed25519 should NOT mismatch because the on-disk key matches the pin. *)
      let args = `Assoc [ ("alias", `String alias) ] in
      let response = Lwt_main.run (C2c_mcp.handle_tool_call
        ~broker ~session_id_override:(Some "mismatch-x-sid")
        ~tool_name:"register" ~arguments:args)
      in
      let open Yojson.Safe.Util in
      let is_error = match response |> member "isError" with `Bool b -> b | _ -> false in
      Alcotest.(check bool) "response is error" true is_error;
      (* (ii): no registration for "mismatch-x25519". *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      Alcotest.(check bool) "no registration for mismatched alias" true
        (List.for_all (fun r -> r.C2c_mcp.alias <> alias) regs);
      (* (iii): relay_pins.json still pins x25519-old under "x25519" key. *)
      let pins_path = Filename.concat dir "relay_pins.json" in
      Alcotest.(check bool) "relay_pins.json exists" true (Sys.file_exists pins_path);
      let pins_json = Yojson.Safe.from_file pins_path in
      let x_pins = match pins_json |> Yojson.Safe.Util.member "x25519" with
        | `Assoc l ->
            (match List.assoc_opt alias l with
             | Some (`String s) -> Some s | _ -> None)
        | _ -> None
      in
      Alcotest.(check (option string)) "x25519 pin still x25519-old-b64"
        (Some "x25519-old-b64") x_pins;
      (* (iv) CRIT-2: audit-log line emitted on broker.log for x25519 class. *)
      let log_path = Filename.concat dir "broker.log" in
      Alcotest.(check bool) "broker.log written" true (Sys.file_exists log_path);
      let log_content = read_broker_log_full dir in
      Alcotest.(check bool) "audit-log has relay_e2e_register_pin_mismatch event" true
        (log_contains_substr log_content "\"event\":\"relay_e2e_register_pin_mismatch\"");
      Alcotest.(check bool) "audit-log carries alias" true
        (log_contains_substr log_content (Printf.sprintf "\"alias\":\"%s\"" alias));
      Alcotest.(check bool) "audit-log key_class is x25519" true
        (log_contains_substr log_content "\"key_class\":\"x25519\"");
      Alcotest.(check bool) "audit-log carries pinned_b64=x25519-old-b64" true
        (log_contains_substr log_content "\"pinned_b64\":\"x25519-old-b64\"");
      Alcotest.(check bool) "audit-log carries claimed_b64=<handler-computed X25519 pubkey>" true
        (log_contains_substr log_content
           (Printf.sprintf "\"claimed_b64\":\"%s\"" claimed_x25519_b64));
      (* (v) CRIT-2 INVARIANT: Ed25519 pin is UNCHANGED post-reject.
         Single-class (x25519) mismatch must not collateral-touch the
         Ed25519 pin — it's still the pre-pinned ed_pinned_b64. *)
      let ed_pin_post = match pins_json |> Yojson.Safe.Util.member "ed25519" with
        | `Assoc l ->
            (match List.assoc_opt alias l with
             | Some (`String s) -> Some s | _ -> None)
        | _ -> None
      in
      Alcotest.(check (option string)) "Ed25519 pin UNCHANGED post-x25519-reject"
        (Some ed_pinned_b64) ed_pin_post;
      (* Belt-and-braces: NO ed25519-class audit line on this test —
         only x25519 mismatched, so we should not see key_class=ed25519
         in the log. *)
      Alcotest.(check bool) "audit-log has NO key_class=ed25519 line" false
        (log_contains_substr log_content "\"key_class\":\"ed25519\""))

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

let test_register_case_insensitive_collision_evicts_lower () =
  (* #378: "Lyra-Quill" and "lyra-quill" are the same identity for collision
     purposes. Registering the upper-case form evicts the lower-case holder. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"lower-session" ~alias:"lyra-quill"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"upper-session" ~alias:"Lyra-Quill"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "only one reg after case-insensitive collision" 1 (List.length regs);
      check bool "upper-session survived"
        true
        (List.exists (fun r -> r.C2c_mcp.session_id = "upper-session") regs);
      check bool "lower-session was evicted"
        false
        (List.exists (fun r -> r.C2c_mcp.session_id = "lower-session") regs))

let test_register_stores_original_case () =
  (* #378: collision is case-insensitive, but the stored alias preserves its original case. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"mixed-session" ~alias:"Lyra-Quill"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      check int "one registration" 1 (List.length regs);
      check bool "stored alias preserves original case"
        true
        (List.exists (fun r -> r.C2c_mcp.alias = "Lyra-Quill") regs))

let test_suggest_alias_prime_case_insensitive_with_suffix () =
  (* #378: suggest_alias_prime returns lowercased base with prime suffix when
     colliding with a case-variant. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"lower-session" ~alias:"lyra-quill"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let suggestion = C2c_mcp.Broker.suggest_alias_for_alias broker ~alias:"Lyra-Quill" in
      check bool "suggestion returned" true (match suggestion with Some _ -> true | None -> false);
      let suggestion = Option.get suggestion in
      check bool "suggestion has prime suffix" true
        (match suggestion with "lyra-quill" -> false | _ -> true))

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

let test_register_logs_event_when_session_id_differs_from_alias () =
  (* #529: when a fresh registration has session_id != alias, the broker logs
     a session_id_differs_from_alias event so operators can see this config.
     The session_id itself is NOT canonicalized — the sender resolves alias→session_id
     via the registry, so both enqueue and drain already use the same session_id-based
     path correctly. This log provides visibility into mismatched configurations. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let log_path = Filename.concat dir "broker.log" in
      (* Fresh registration: session_id differs from alias.
         Broker should log session_id_differs_from_alias event. *)
      C2c_mcp.Broker.register broker
        ~session_id:"mismatched-session-id" ~alias:"fresh-agent"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* Verify session_id in registry is NOT canonicalized — stays as original. *)
      let regs = C2c_mcp.Broker.list_registrations broker in
      match List.find_opt (fun r -> r.C2c_mcp.alias = "fresh-agent") regs with
      | None -> Alcotest.fail "fresh-agent not found in registry"
      | Some reg ->
          check string "session_id preserved as original" "mismatched-session-id" reg.C2c_mcp.session_id;
          (* Verify log event was written. *)
          let json =
            try Yojson.Safe.from_file log_path
            with _ -> `Null
          in
          let open Yojson.Safe.Util in
          let events = match json with
            | `List items -> items
            | `Assoc _ -> [json]
            | _ -> []
          in
          let has_diff_event =
            List.exists (fun item ->
              match item |> member "event" |> to_string_option with
              | Some "session_id_differs_from_alias" -> true
              | _ -> false)
              events
          in
          check bool "session_id_differs_from_alias event logged" true has_diff_event)

let test_register_no_log_when_session_id_matches_alias () =
  (* #529 variant: when session_id == alias on fresh reg, no log event needed —
     the configuration is as expected. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let log_path = Filename.concat dir "broker.log" in
      C2c_mcp.Broker.register broker
        ~session_id:"matching-agent" ~alias:"matching-agent"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let regs = C2c_mcp.Broker.list_registrations broker in
      match List.find_opt (fun r -> r.C2c_mcp.alias = "matching-agent") regs with
      | None -> Alcotest.fail "matching-agent not found in registry"
      | Some reg ->
          check string "session_id preserved" "matching-agent" reg.C2c_mcp.session_id;
          (* Log should NOT have session_id_differs_from_alias since they match. *)
          if Sys.file_exists log_path then
            let json =
              try Yojson.Safe.from_file log_path
              with _ -> `Null
            in
            let open Yojson.Safe.Util in
            let events = match json with
              | `List items -> items
              | `Assoc _ -> [json]
              | _ -> []
            in
            let has_diff_event =
              List.exists (fun item ->
                match item |> member "event" |> to_string_option with
                | Some "session_id_differs_from_alias" -> true
                | _ -> false)
                events
            in
            check bool "no session_id_differs_from_alias event when they match" false has_diff_event)

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

(* #344: legacy pidless rows (no registered_at anchor) used to be preserved
   forever by sweep — the canonical pidless-zombie un-reapability bug. The
   new sweep predicate ([is_sweep_keepable]) drops them. *)
let test_sweep_drops_pidless_legacy_row () =
  with_temp_dir (fun dir ->
      write_file (Filename.concat dir "registry.json")
        {|[{"session_id":"legacy-session","alias":"storm-legacy"}]|};
      write_file (Filename.concat dir "legacy-session.inbox.json") "[]";
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "legacy reg dropped" 1 (List.length result.dropped_regs);
      check int "legacy inbox deleted" 1
        (List.length result.deleted_inboxes);
      check int "registry empty after sweep" 0
        (List.length (C2c_mcp.Broker.list_registrations broker));
      check bool "legacy inbox file gone" false
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

(* #433: every dead-letter write must emit a `dead_letter_write` line in
   broker.log so `c2c tail-log` surfaces the silent-failure trail. The
   audit "broker-log-coverage-audit-cairn 2026-04-29" caught this HIGH
   gap — sweep was preserving messages to dead-letter.jsonl but tail-log
   showed nothing, contradicting the dogfooding rule that silent failures
   must be observable. *)
let test_sweep_dead_letter_write_emits_broker_log_event () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      write_file (Filename.concat dir "ghost-sid.inbox.json")
        {|[{"from_alias":"storm-ember","to_alias":"storm-storm","content":"alpha"},{"from_alias":"storm-beacon","to_alias":"storm-storm","content":"beta"}]|};
      let result = C2c_mcp.Broker.sweep broker in
      check int "two messages preserved" 2 result.preserved_messages;
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log written" true (Sys.file_exists log_path);
      let lines =
        let ic = open_in log_path in
        Fun.protect
          ~finally:(fun () -> close_in ic)
          (fun () ->
            let acc = ref [] in
            (try
               while true do
                 let line = input_line ic |> String.trim in
                 if line <> "" then acc := line :: !acc
               done
             with End_of_file -> ());
            List.rev !acc)
      in
      let dl_events =
        List.filter
          (fun line ->
            try
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              json |> member "event" |> to_string = "dead_letter_write"
            with _ -> false)
          lines
      in
      check int "two dead_letter_write events" 2 (List.length dl_events);
      let has_alpha_event =
        List.exists
          (fun line ->
            try
              let json = Yojson.Safe.from_string line in
              let open Yojson.Safe.Util in
              json |> member "event" |> to_string = "dead_letter_write"
              && json |> member "reason" |> to_string = "inbox_sweep"
              && json |> member "from_alias" |> to_string = "storm-ember"
              && json |> member "to_alias" |> to_string = "storm-storm"
              && json |> member "from_session_id" |> to_string = "ghost-sid"
            with _ -> false)
          dl_events
      in
      check bool "alpha event has reason+aliases+sid" true has_alpha_event)

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

(* #383: peer_offline broadcast tests *)

(* Sweep emits peer_offline for every confirmed dead registration. *)
let test_sweep_emits_peer_offline_for_confirmed_dead_reg () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* alice: alive, will receive the notification *)
      C2c_mcp.Broker.register broker
        ~session_id:"session-alice" ~alias:"storm-alice"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* bob: confirmed (poll_inbox called), then PID dies *)
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-bob" ~alias:"storm-bob"
        ~pid:(Some dead) ~pid_start_time:None ();
      (* Promote bob to confirmed *)
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-bob";
      let result = C2c_mcp.Broker.sweep broker in
      check int "bob dropped" 1 (List.length result.dropped_regs);
      check string "dropped alias" "storm-bob"
        (List.hd result.dropped_regs).alias;
      (* alice's inbox should have the peer_offline message *)
      let alice_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-alice" in
      check int "alice got exactly one notification" 1 (List.length alice_inbox);
      let msg = List.hd alice_inbox in
      check string "from is broker" "broker" msg.from_alias;
      check string "to is alice" "storm-alice" msg.to_alias;
      (* Verify peer_offline envelope format *)
      check bool "content has peer_offline event" true
        (string_contains msg.content "<c2c event=\"peer_offline\"");
      check bool "content has storm-bob alias" true
        (string_contains msg.content "alias=\"storm-bob\"");
      check bool "content has reason=killed" true
        (string_contains msg.content "reason=\"killed\"");
      check bool "content has detected_at" true
        (string_contains msg.content "detected_at=");
      check bool "content has last_seen=" true
        (string_contains msg.content "last_seen="))

(* Sweep does NOT emit peer_offline for an expired provisional reg
   (confirmed_at=None), even though it IS dropped by sweep. *)
let test_sweep_does_not_emit_peer_offline_for_provisional_expired_reg () =
  with_temp_dir (fun dir ->
      (* Write a registry with an expired provisional reg (no confirmed_at). *)
      let expired_ts = Unix.gettimeofday () -. 3601.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"prov-dead","alias":"storm-prov","registered_at":%f}]|}
          expired_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Also register a live peer so sweep would have somewhere to broadcast to. *)
      C2c_mcp.Broker.register broker
        ~session_id:"session-live" ~alias:"storm-live"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      Unix.putenv "C2C_PROVISIONAL_SWEEP_TIMEOUT" "1800";
      let result = C2c_mcp.Broker.sweep broker in
      Unix.putenv "C2C_PROVISIONAL_SWEEP_TIMEOUT" "1800";
      check int "provisional dropped" 1 (List.length result.dropped_regs);
      check string "dropped alias" "storm-prov"
        (List.hd result.dropped_regs).alias;
      (* Live peer's inbox must NOT contain any peer_offline message *)
      let live_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-live" in
      let peer_offline_count =
        List.fold_left
          (fun n (msg : C2c_mcp.message) -> if string_contains msg.content "<c2c event=\"peer_offline\"" then n + 1 else n)
          0 live_inbox
      in
      check int "no peer_offline emitted for provisional" 0 peer_offline_count)

(* peer_offline message has correct XML envelope format. *)
let test_sweep_peer_offline_message_format () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"session-witness" ~alias:"storm-witness"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"storm-dead"
        ~pid:(Some dead) ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-dead";
      let (_ : C2c_mcp.Broker.sweep_result) = C2c_mcp.Broker.sweep broker in
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-witness" in
      match inbox with
      | [] -> fail "expected peer_offline in witness inbox"
      | msg :: _ ->
          let c = msg.content in
          (* All 5 attributes must be present *)
          check bool "event attr" true
            (string_contains c "<c2c event=\"peer_offline\"");
          check bool "alias attr" true
            (string_contains c "alias=\"storm-dead\"");
          check bool "detected_at attr" true
            (string_contains c "detected_at=\"");
          check bool "reason attr" true
            (string_contains c "reason=\"killed\"");
          check bool "last_seen attr" true
            (string_contains c "last_seen=\"");
          (* Must be self-closing *)
          check bool "self-closing tag" true
            (string_contains c "/>"))

(* The dead alias does NOT receive its own peer_offline notification. *)
let test_sweep_dead_alias_excluded_from_peer_offline_receipt () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register only the dead peer (no other alive peers). *)
      let dead = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-dead" ~alias:"storm-dead"
        ~pid:(Some dead) ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-dead";
      let (_ : C2c_mcp.Broker.sweep_result) = C2c_mcp.Broker.sweep broker in
      (* storm-dead's inbox may have been deleted by sweep, but no NEW
         peer_offline should have been delivered there. *)
      let inbox_exists = Sys.file_exists (Filename.concat dir "session-dead.inbox.json") in
      if inbox_exists then
        let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-dead" in
        let peer_offline_count =
          List.fold_left
            (fun n (msg : C2c_mcp.message) -> if string_contains msg.content "<c2c event=\"peer_offline\"" then n + 1 else n)
            0 inbox
        in
        check int "dead alias got no self-notification" 0 peer_offline_count
      else
        (* Inbox was deleted by sweep — also fine, means nothing was delivered. *)
        check bool "inbox deleted (no self-delivery)" true true)

(* Multiple confirmed dead registrations each emit their own peer_offline. *)
let test_sweep_multiple_confirmed_dead_regs_each_emit_peer_offline () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* alice: alive witness *)
      C2c_mcp.Broker.register broker
        ~session_id:"session-alice" ~alias:"storm-alice"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      (* bob and carol: both confirmed dead *)
      let dead1 = dead_pid () in
      let dead2 = dead_pid () in
      C2c_mcp.Broker.register broker
        ~session_id:"session-bob" ~alias:"storm-bob"
        ~pid:(Some dead1) ~pid_start_time:None ();
      C2c_mcp.Broker.register broker
        ~session_id:"session-carol" ~alias:"storm-carol"
        ~pid:(Some dead2) ~pid_start_time:None ();
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-bob";
      C2c_mcp.Broker.confirm_registration broker ~session_id:"session-carol";
      let result = C2c_mcp.Broker.sweep broker in
      check int "two dead regs" 2 (List.length result.dropped_regs);
      (* alice should have TWO peer_offline messages — one per dead peer *)
      let alice_inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-alice" in
      let peer_offline_messages =
        List.filter
          (fun (msg : C2c_mcp.message) -> string_contains msg.content "<c2c event=\"peer_offline\"")
          alice_inbox
      in
      check int "alice got two peer_offline messages" 2 (List.length peer_offline_messages);
      let aliases =
        List.map
          (fun (msg : C2c_mcp.message) ->
             let start_idx = try String.index msg.content 'a' + String.length "alias=\"" with Not_found -> -1 in
             if start_idx < 0 then "" else
               let rest = String.sub msg.content start_idx (String.length msg.content - start_idx) in
               try String.sub rest 0 (String.index_from rest 0 '"')
               with _ -> "")
          peer_offline_messages
      in
      let has_bob = List.exists (fun a -> string_contains a "storm-bob") aliases in
      let has_carol = List.exists (fun a -> string_contains a "storm-carol") aliases in
      check bool "has bob's peer_offline" true has_bob;
      check bool "has carol's peer_offline" true has_carol)

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

(* #344: a confirmed-but-pidless row that registered more than the
   pidless-keep window ago (default 1h) IS now swept. Pre-#344, sweep
   preserved any confirmed reg forever once confirmed_at was set, which
   left zombies (e.g. respawned daemons whose old row never had its PID
   updated) un-reapable. PID-tracked confirmed rows are unaffected by
   this change — only the pidless arm is tightened. *)
let test_confirmed_pidless_old_reg_swept () =
  with_temp_dir (fun dir ->
      (* Write a registry JSON: registered_at and confirmed_at both > 1h
         ago, no pid. *)
      let expired_ts = Unix.gettimeofday () -. 7200.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"conf-old","alias":"storm-confirmed-old","registered_at":%f,"confirmed_at":%f}]|}
          expired_ts expired_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "confirmed pidless old reg dropped" 1 (List.length result.dropped_regs))

(* #344: pidless row whose registered_at is older than the pidless-keep
   window (default 1h) is dropped, even if confirmed_at is set. Mirrors
   the audit's Finding 1 — a daemon that respawned under a new PID
   leaves the old row to age into a zombie. *)
let test_sweep_drops_pidless_old_row () =
  with_temp_dir (fun dir ->
      let old_ts = Unix.gettimeofday () -. 7200.0 in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"old-pidless","alias":"storm-old-pidless","registered_at":%f,"confirmed_at":%f}]|}
          old_ts old_ts
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "old pidless reg dropped" 1 (List.length result.dropped_regs);
      check int "registry empty" 0
        (List.length (C2c_mcp.Broker.list_registrations broker)))

(* #344: a freshly-registered pidless row that has drained at least once
   (confirmed_at = Some _) is preserved — this is the brief plugin-handoff
   window where a real session momentarily has no pid. *)
let test_sweep_keeps_pidless_recent_drained_row () =
  with_temp_dir (fun dir ->
      let now = Unix.gettimeofday () in
      let reg_json =
        Printf.sprintf
          {|[{"session_id":"recent-pidless","alias":"storm-recent","registered_at":%f,"confirmed_at":%f}]|}
          now now
      in
      write_file (Filename.concat dir "registry.json") reg_json;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let result = C2c_mcp.Broker.sweep broker in
      check int "recent pidless drained reg kept" 0 (List.length result.dropped_regs);
      check int "registry still has reg" 1
        (List.length (C2c_mcp.Broker.list_registrations broker)))

(* #344 regression: a row tracked by the current process pid is unaffected
   by the new pidless-zombie predicate. *)
let test_sweep_keeps_alive_pid_row () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"live-pid" ~alias:"storm-live-pid"
        ~pid:(Some (Unix.getpid ())) ~pid_start_time:None ();
      let result = C2c_mcp.Broker.sweep broker in
      check int "live-pid reg not dropped" 0 (List.length result.dropped_regs);
      check int "registry still has reg" 1
        (List.length (C2c_mcp.Broker.list_registrations broker)))

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
      (* delete_room should succeed on an empty room when called by creator *)
      C2c_mcp.Broker.delete_room broker ~room_id:"tmp-room"
        ~caller_alias:"storm-ember" ();
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
        (fun () ->
          C2c_mcp.Broker.delete_room broker ~room_id:"lobby"
            ~caller_alias:"storm-ember" ()))

(* #alias-casefold: creator stored canonical-lowercase via casefold-on-write
   at join time; delete must succeed when caller's [caller_alias] differs in
   case from the stored [created_by]. *)
let test_delete_room_creator_check_case_insensitive () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Joiner stamps created_by; casefold-on-write forces lowercase. *)
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"tmp-room"
          ~alias:"Storm-Ember" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"tmp-room" ~alias:"Storm-Ember"
      in
      (* Caller resolves with a different casing — must still be allowed. *)
      C2c_mcp.Broker.delete_room broker ~room_id:"tmp-room"
        ~caller_alias:"STORM-ember" ();
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check int "room deleted via case-insensitive creator match"
        0 (List.length rooms))

(* #alias-casefold: legacy room with mixed-case [created_by] (written before
   casefold-on-write) still permits delete when caller resolves to a
   different casing — read-side casefold compatibility. *)
let test_delete_room_legacy_mixed_case_creator () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"legacy-room"
          ~alias:"alice" ~session_id:"session-a"
      in
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"legacy-room" ~alias:"alice"
      in
      (* Manually overwrite room meta to simulate legacy mixed-case storage. *)
      let meta_path =
        Filename.concat dir
          (Filename.concat "rooms" (Filename.concat "legacy-room" "meta.json"))
      in
      let oc = open_out meta_path in
      output_string oc
        "{\"visibility\":\"public\",\"invited_members\":[],\"created_by\":\"Alice\"}";
      close_out oc;
      (* Caller "alice" must still be able to delete the legacy room. *)
      C2c_mcp.Broker.delete_room broker ~room_id:"legacy-room"
        ~caller_alias:"alice" ();
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check int "legacy mixed-case room deleted"
        0 (List.length rooms))

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

(* #392 S1: tag-bucketing — history stores bare content, fan-out delivers prefixed.
   Key invariants:
   - History never contains a tag prefix (tag is presentation-only, per-recipient)
   - Fan-out delivers prefixed content to each recipient's inbox
   - Same bare content with different tags → different prefix in each inbox
     (dedup-on-bare-content, tested in S2) *)
let test_send_room_tag_stores_bare_content_fans_out_prefixed () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-alice"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"room1"
        ~alias:"alice" ~session_id:"s-alice");
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"room1"
        ~alias:"bob" ~session_id:"s-bob");
      ignore (C2c_mcp.Broker.drain_inbox broker ~session_id:"s-alice");
      ignore (C2c_mcp.Broker.drain_inbox broker ~session_id:"s-bob");
      (* Send with a "fail" tag *)
      let result =
        C2c_mcp.Broker.send_room ~tag:"fail" broker
          ~from_alias:"alice" ~room_id:"room1" ~content:"build broken"
      in
      check int "delivered to bob" 1 (List.length result.sr_delivered_to);
      (* S1a: history stores BARE content (no prefix) *)
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"room1" ~limit:10 ()
      in
      let h = List.hd (List.rev history) in
      check string "history content is bare" "build broken" h.rm_content;
      check bool "history content has no tag prefix" false
        (String.sub h.rm_content 0 (min 4 (String.length h.rm_content)) = "🔴");
      (* S1b: bob's inbox gets PREFIXED content *)
      let inbox_bob = C2c_mcp.Broker.read_inbox broker ~session_id:"s-bob" in
      check int "bob has 1 message" 1 (List.length inbox_bob);
      let msg = List.hd inbox_bob in
      let fail_prefix = C2c_mcp.tag_to_body_prefix (Some "fail") in
      check bool "inbox content starts with fail prefix" true
        (String.length msg.content >= String.length fail_prefix
         && String.sub msg.content 0 (String.length fail_prefix) = fail_prefix);
      check bool "inbox content ends with bare body" true
        (msg.content = fail_prefix ^ "build broken"))

(* #392 S2: dedup-on-bare-content — same bare body, different tag = duplicate.
   The dedup key is the bare content, not the prefixed content. Re-tagging an
   already-sent message (e.g. upgrading no-tag → "fail" or "fail" → "urgent")
   should still be suppressed as a dup, so agents can't DOS a room by re-tagging. *)
let test_send_room_dedup_on_bare_content_ignores_tag () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-sender"
        ~alias:"sender" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-recv"
        ~alias:"receiver" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"room1"
        ~alias:"sender" ~session_id:"s-sender");
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"room1"
        ~alias:"receiver" ~session_id:"s-recv");
      ignore (C2c_mcp.Broker.drain_inbox broker ~session_id:"s-sender");
      ignore (C2c_mcp.Broker.drain_inbox broker ~session_id:"s-recv");
      (* Send without a tag *)
      let r1 =
        C2c_mcp.Broker.send_room broker
          ~from_alias:"sender" ~room_id:"room1" ~content:"urgent fix"
      in
      check int "first send delivered" 1 (List.length r1.sr_delivered_to);
      (* Re-send the SAME bare content but with a "fail" tag → dup *)
      let r2 =
        C2c_mcp.Broker.send_room ~tag:"fail" broker
          ~from_alias:"sender" ~room_id:"room1" ~content:"urgent fix"
      in
      check int "second send (same bare body, different tag) suppressed" 0
        (List.length r2.sr_delivered_to);
      (* Re-send again with "urgent" tag → still dup *)
      let r3 =
        C2c_mcp.Broker.send_room ~tag:"urgent" broker
          ~from_alias:"sender" ~room_id:"room1" ~content:"urgent fix"
      in
      check int "third send (urgent tag on same bare body) suppressed" 0
        (List.length r3.sr_delivered_to);
      (* Receiver has exactly 1 message (from first send only) *)
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"s-recv" in
      check int "receiver has exactly 1 message" 1 (List.length inbox);
      (* History has exactly 1 entry *)
      let history =
        C2c_mcp.Broker.read_room_history broker ~room_id:"room1" ~limit:10 ()
      in
      let sender_msgs =
        List.filter (fun (m : C2c_mcp.room_message) -> m.rm_from_alias = "sender") history
      in
      check int "history has exactly 1 sender entry" 1 (List.length sender_msgs))

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

(* #392b: tag round-trips through room history storage.
   Content with body-prefix → append_room_history → read_room_history →
   extract_tag_from_content still detects the tag. Validates relay propagation AC:
   "tag survives alias@host round trip". *)
let test_room_history_tag_roundtrip () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ = C2c_mcp.Broker.join_room broker ~room_id:"tag-test" ~alias:"sender" ~session_id:"s1" in
      (* Tagged content as stored after body-prefix is applied at send time.
         Prefix is from C2c_mcp.tag_to_body_prefix (Some "fail"). *)
      let tagged_content = "🔴 FAIL: " ^ "build broken on sha abc123" in
      ignore (C2c_mcp.Broker.append_room_history broker
        ~room_id:"tag-test" ~from_alias:"sender" ~content:tagged_content);
      (* Read back and verify the tag is still detectable from stored content *)
      let history = C2c_mcp.Broker.read_room_history broker ~room_id:"tag-test" ~limit:1 () in
      match history with
      | [msg] ->
          let tag = C2c_mcp.extract_tag_from_content msg.rm_content in
          Alcotest.(check (option string)) "tag detected after round-trip"
            (Some "fail") tag
      | _ -> Alcotest.fail "expected exactly 1 history entry after append"
    )

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

(* #432: delete_room must reject if caller_alias is held by an alive
   different session — symmetry with send_room/send_room_invite/
   set_room_visibility. The threat path is an unregistered caller
   passing `alias: <peer-name>`; `alias_for_current_session_or_argument`
   only falls back to the arg when the calling session is unregistered. *)
let test_delete_room_impersonation_rejected () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Only agent-b is registered (with a live pid). *)
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"agent-b" ~pid:(Some live_pid) ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"room-x"
                ~alias:"agent-b" ~session_id:"session-b");
      (* Unregistered session-a calls delete_room with alias=agent-b. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 432001)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "delete_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("alias", `String "agent-b")
                          ; ("room_id", `String "room-x")
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
              check bool "delete_room rejected with isError=true" true is_error;
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "error mentions stolen alias" true
                (string_contains text "agent-b")))

(* #432: leave_room must reject if alias is held by an alive different
   session — symmetry with sibling room handlers. The threat path is an
   unregistered caller passing `alias: <peer-name>` to evict that peer. *)
let test_leave_room_impersonation_rejected () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Only agent-b is registered (with a live pid). *)
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"agent-b" ~pid:(Some live_pid) ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"shared-room"
                ~alias:"agent-b" ~session_id:"session-b");
      (* Unregistered session-a tries to evict agent-b. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 432002)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "leave_room")
                    ; ( "arguments",
                        `Assoc
                          [ ("alias", `String "agent-b")
                          ; ("room_id", `String "shared-room")
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
              check bool "leave_room rejected with isError=true" true is_error;
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "error mentions stolen alias" true
                (string_contains text "agent-b")))

(* #432: stop_self must reject when the resolved alias targets a peer
   instance (alias registered to a different alive session). The original
   handler would SIGTERM that peer's outer.pid file — a DoS vector against
   any peer whose alias you can list. The threat path is an unregistered
   caller passing `alias: <peer-name>` (because
   `alias_for_current_session_or_argument` falls back to the `alias` /
   `from_alias` arg when the calling session has no registration). *)
let test_stop_self_cannot_kill_other () =
  with_temp_dir (fun dir ->
      let live_pid = Unix.getpid () in
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Only session-b is registered, holding alias "alias-b". *)
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"alias-b" ~pid:(Some live_pid) ~pid_start_time:None ();
      (* session-a is unregistered, calls stop_self with alias=alias-b. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-a";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 432003)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "stop_self")
                    ; ( "arguments",
                        `Assoc
                          [ ("alias", `String "alias-b")
                          ; ("reason", `String "DoS attempt")
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
              check bool "stop_self rejected with isError=true" true is_error;
              let text =
                json |> member "result" |> member "content" |> index 0
                |> member "text" |> to_string
              in
              check bool "error mentions targeted alias" true
                (string_contains text "alias-b")))

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

(* #433: send_room_invite must auto-DM the invitee with a
   <c2c event="room-invite" ...> envelope. Prior behaviour was
   ACL-append-only, so the invitee never learned about the invite. *)
let test_send_room_invite_auto_dms_invitee () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.join_room broker ~room_id:"secret-club"
                ~alias:"alice" ~session_id:"session-a");
      C2c_mcp.Broker.send_room_invite broker ~room_id:"secret-club"
        ~from_alias:"alice" ~invitee_alias:"bob";
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-b" in
      check int "bob has 1 inbox message" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "from_alias is alice" "alice" msg.from_alias;
      let contains haystack needle =
        let h = haystack in
        let n = needle in
        let lh = String.length h and ln = String.length n in
        let rec aux i =
          if i + ln > lh then false
          else if String.sub h i ln = n then true
          else aux (i + 1)
        in
        aux 0
      in
      check bool "envelope has event=room-invite" true
        (contains msg.content "event=\"room-invite\"");
      check bool "envelope mentions room" true
        (contains msg.content "secret-club"))

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

(* #394: c2c rooms create — explicit room creation. *)
let test_create_public_room_with_auto_join () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let r =
        C2c_mcp.Broker.create_room broker ~room_id:"design-syndicate"
          ~caller_alias:"stanza-coder" ~caller_session_id:"session-stanza"
          ~visibility:C2c_mcp.Public ~invited_members:[] ~auto_join:true
      in
      check string "room_id" "design-syndicate" r.cr_room_id;
      check string "created_by" "stanza-coder" r.cr_created_by;
      check bool "auto_joined" true r.cr_auto_joined;
      check (list string) "members has creator" ["stanza-coder"] r.cr_members;
      check bool "visibility public" true
        (match r.cr_visibility with Public -> true | Invite_only -> false);
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"design-syndicate" in
      check string "meta created_by persisted" "stanza-coder" meta.created_by;
      let members = C2c_mcp.Broker.read_room_members broker ~room_id:"design-syndicate" in
      check int "one member persisted" 1 (List.length members))

let test_create_invite_only_with_invited_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let r =
        C2c_mcp.Broker.create_room broker ~room_id:"design-syndicate"
          ~caller_alias:"stanza-coder" ~caller_session_id:"session-stanza"
          ~visibility:C2c_mcp.Invite_only
          ~invited_members:["galaxy-coder"; "lyra-quill"; "galaxy-coder"]
          ~auto_join:true
      in
      check bool "visibility invite_only" true
        (match r.cr_visibility with Invite_only -> true | Public -> false);
      check (list string) "invited dedup" ["galaxy-coder"; "lyra-quill"] r.cr_invited_members;
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"design-syndicate" in
      check (list string) "invited_members persisted" ["galaxy-coder"; "lyra-quill"]
        meta.invited_members)

let test_create_no_join () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let r =
        C2c_mcp.Broker.create_room broker ~room_id:"design-syndicate"
          ~caller_alias:"stanza-coder" ~caller_session_id:"session-stanza"
          ~visibility:C2c_mcp.Public ~invited_members:[] ~auto_join:false
      in
      check bool "not auto_joined" false r.cr_auto_joined;
      check (list string) "members empty" [] r.cr_members;
      let members = C2c_mcp.Broker.read_room_members broker ~room_id:"design-syndicate" in
      check int "no members persisted" 0 (List.length members);
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"design-syndicate" in
      check string "created_by still recorded" "stanza-coder" meta.created_by)

let test_create_existing_room_errors () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      ignore (C2c_mcp.Broker.create_room broker ~room_id:"design-syndicate"
                ~caller_alias:"stanza-coder" ~caller_session_id:"session-stanza"
                ~visibility:C2c_mcp.Public ~invited_members:[] ~auto_join:true);
      check_raises "second create errors"
        (Invalid_argument "room already exists: design-syndicate")
        (fun () ->
           ignore (C2c_mcp.Broker.create_room broker ~room_id:"design-syndicate"
                     ~caller_alias:"galaxy-coder" ~caller_session_id:"session-galaxy"
                     ~visibility:C2c_mcp.Public ~invited_members:[] ~auto_join:true)))

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

(* --- set_dnd string/bool parsing tests --- *)

let test_tools_call_set_dnd_on_string_true_enables_dnd () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-dnd"
        ~alias:"dnd-test" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-dnd";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 9501)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "set_dnd")
                     ; ( "arguments",
                         `Assoc [ ("on", `String "true") ] )
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
               let result = Yojson.Safe.from_string text in
               let ok = result |> member "ok" |> to_bool in
               let dnd_val = result |> member "dnd" |> to_bool in
               check bool "set_dnd on:\"true\" ok" true ok;
               check bool "set_dnd on:\"true\" enables dnd" true dnd_val))

let test_tools_call_set_dnd_on_string_false_disables_dnd () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-dnd2"
        ~alias:"dnd-test2" ~pid:None ~pid_start_time:None ();
      (* Enable DND first via bool to test disable *)
      ignore (C2c_mcp.Broker.set_dnd broker ~session_id:"session-dnd2" ~dnd:true ());
      Unix.putenv "C2C_MCP_SESSION_ID" "session-dnd2";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 9502)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "set_dnd")
                     ; ( "arguments",
                         `Assoc [ ("on", `String "false") ] )
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
               let result = Yojson.Safe.from_string text in
               let ok = result |> member "ok" |> to_bool in
               let dnd_val = result |> member "dnd" |> to_bool in
               check bool "set_dnd on:\"false\" ok" true ok;
               check bool "set_dnd on:\"false\" disables dnd" false dnd_val))

let run_set_dnd_with_on_arg ~session_id ~req_id ~on_arg =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id
        ~alias:("dnd-test-" ^ session_id) ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" session_id;
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int req_id)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "set_dnd")
                     ; ("arguments", `Assoc [ ("on", on_arg) ])
                     ] )
               ]
           in
           let response =
             Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
           in
           match response with
           | None -> failwith "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               Yojson.Safe.from_string text))

let test_tools_call_set_dnd_on_int_one_enables_dnd () =
  let result =
    run_set_dnd_with_on_arg ~session_id:"session-dnd-int1" ~req_id:9503
      ~on_arg:(`Int 1)
  in
  let open Yojson.Safe.Util in
  let ok = result |> member "ok" |> to_bool in
  let dnd_val = result |> member "dnd" |> to_bool in
  check bool "set_dnd on:1 ok" true ok;
  check bool "set_dnd on:1 enables dnd" true dnd_val

let test_tools_call_set_dnd_on_int_zero_disables_dnd () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-dnd-int0"
        ~alias:"dnd-test-int0" ~pid:None ~pid_start_time:None ();
      ignore (C2c_mcp.Broker.set_dnd broker ~session_id:"session-dnd-int0" ~dnd:true ());
      Unix.putenv "C2C_MCP_SESSION_ID" "session-dnd-int0";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
           let request =
             `Assoc
               [ ("jsonrpc", `String "2.0")
               ; ("id", `Int 9504)
               ; ("method", `String "tools/call")
               ; ( "params",
                   `Assoc
                     [ ("name", `String "set_dnd")
                     ; ("arguments", `Assoc [ ("on", `Int 0) ])
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
               let result = Yojson.Safe.from_string text in
               let ok = result |> member "ok" |> to_bool in
               let dnd_val = result |> member "dnd" |> to_bool in
               check bool "set_dnd on:0 ok" true ok;
               check bool "set_dnd on:0 disables dnd" false dnd_val))

(* Regression: ambiguous bool inputs default to [false] (do-not-enable-DND).
   The handler does not raise — silent-fail-closed is the documented behavior
   for set_dnd. The point of the test is to lock in that "yes"/floats do not
   accidentally COERCE to true. *)
let test_tools_call_set_dnd_on_invalid_input_defaults_false () =
  let result_yes =
    run_set_dnd_with_on_arg ~session_id:"session-dnd-yes" ~req_id:9505
      ~on_arg:(`String "yes")
  in
  let result_float =
    run_set_dnd_with_on_arg ~session_id:"session-dnd-float" ~req_id:9506
      ~on_arg:(`Float 1.0)
  in
  let open Yojson.Safe.Util in
  check bool "set_dnd on:\"yes\" does not enable" false
    (result_yes |> member "dnd" |> to_bool);
  check bool "set_dnd on:1.0 does not enable" false
    (result_float |> member "dnd" |> to_bool)

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
  (* [#432 Slice B] Updated for the auth-fix: reply_from_alias is now
     derived from the calling session, not the request argument. The
     test now registers BOTH the requester and the supervisor with
     distinct sessions, opens the pending entry as the requester, then
     calls check_pending_reply from the SUPERVISOR's session. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-requester"
        ~alias:"agent-a" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-supervisor"
        ~alias:"coordinator1" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
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
          (* Switch to the supervisor session — they are the one calling
             check_pending_reply post-fix. The reply_from_alias arg is
             still passed (legacy compat) but is silently ignored. *)
          Unix.putenv "C2C_MCP_SESSION_ID" "session-supervisor";
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

(* [#432 Slice D] Decision audit log — broker.log gains a
   "pending_open" JSONL line per successful open_pending_reply RPC.
   perm_id and requester_session_id are hashed (16 hex chars);
   aliases + supervisors stay plaintext. *)
let read_broker_log_lines dir =
  let path = Filename.concat dir "broker.log" in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec loop acc =
      try loop (input_line ic :: acc)
      with End_of_file -> close_in_noerr ic; List.rev acc
    in
    loop []

let parse_broker_log_lines_with_event dir event =
  read_broker_log_lines dir
  |> List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        let open Yojson.Safe.Util in
        match json |> member "event" with
        | `String e when e = event -> Some json
        | _ -> None
      with _ -> None)

let is_hex16 s =
  String.length s = 16
  && String.for_all
       (function '0'..'9' | 'a'..'f' -> true | _ -> false) s

let test_pending_open_audit_log_written () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester-d1";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester-d1"
            ~alias:"stanza-coder" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 9001)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:audit:slice-d-1")
                          ; ("kind", `String "permission")
                          ; ( "supervisors",
                              `List [ `String "coordinator1"; `String "lyra-quill" ] )
                          ] )
                    ] )
              ]
          in
          let response = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          (match response with
           | None -> fail "expected tools/call response"
           | Some _ -> ());
          let lines = parse_broker_log_lines_with_event dir "pending_open" in
          check int "exactly one pending_open line" 1 (List.length lines);
          let json = List.hd lines in
          let open Yojson.Safe.Util in
          let perm_id_hash = json |> member "perm_id_hash" |> to_string in
          check bool "perm_id_hash is 16 hex" true (is_hex16 perm_id_hash);
          let session_hash = json |> member "requester_session_hash" |> to_string in
          check bool "requester_session_hash is 16 hex" true (is_hex16 session_hash);
          check string "kind plaintext" "permission"
            (json |> member "kind" |> to_string);
          check string "requester_alias plaintext" "stanza-coder"
            (json |> member "requester_alias" |> to_string);
          let sups =
            json |> member "supervisors" |> to_list |> List.map to_string
          in
          check (list string) "supervisors plaintext"
            [ "coordinator1"; "lyra-quill" ] sups;
          (* Privacy: raw perm_id and raw session_id MUST NOT appear in the line. *)
          let raw_line =
            List.hd (read_broker_log_lines dir
                     |> List.filter (fun l -> string_contains l "pending_open"))
          in
          check bool "raw perm_id absent" false
            (string_contains raw_line "perm:audit:slice-d-1");
          check bool "raw session_id absent" false
            (string_contains raw_line "session-requester-d1")))

(* slice/coord-backup-fallthrough: log_coord_fallthrough_fired writes
   a [event=coord_fallthrough_fired] line with the expected schema —
   perm_id_hash is hashed (16 hex), aliases plaintext, tier as int.
   This exercises the audit-log helper directly; the broker scheduler
   that calls it lands in the follow-up slice (per the design doc's
   §11 split). *)
let test_coord_fallthrough_audit_line_written () =
  with_temp_dir (fun dir ->
      let perm_id = "perm:fallthrough:slice-skel-1" in
      C2c_mcp.log_coord_fallthrough_fired
        ~broker_root:dir
        ~perm_id
        ~tier:1
        ~primary_alias:"coordinator1"
        ~backup_alias:"stanza-coder"
        ~requester_alias:"galaxy-coder"
        ~elapsed_s:120.5
        ~ts:1714389600.0;
      let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
      check int "exactly one coord_fallthrough_fired line" 1 (List.length lines);
      let json = List.hd lines in
      let open Yojson.Safe.Util in
      let perm_id_hash = json |> member "perm_id_hash" |> to_string in
      check bool "perm_id_hash is 16 hex" true (is_hex16 perm_id_hash);
      check int "tier is 1" 1 (json |> member "tier" |> to_int);
      check string "primary_alias plaintext" "coordinator1"
        (json |> member "primary_alias" |> to_string);
      check string "backup_alias plaintext" "stanza-coder"
        (json |> member "backup_alias" |> to_string);
      check string "requester_alias plaintext" "galaxy-coder"
        (json |> member "requester_alias" |> to_string);
      check (float 0.0) "elapsed_s preserved"
        120.5 (json |> member "elapsed_s" |> to_number);
      (* Privacy: raw perm_id MUST NOT appear plaintext in the audit line. *)
      let raw_line =
        List.hd
          (read_broker_log_lines dir
           |> List.filter (fun l -> string_contains l "coord_fallthrough_fired"))
      in
      check bool "raw perm_id absent" false
        (string_contains raw_line perm_id))

(* slice/coord-backup-fallthrough: a broadcast-tier fire records
   backup_alias="<broadcast>" and a tier index past the chain length.
   Same shape as a per-backup tier; the consumer (audit reader) keys
   off the literal "<broadcast>" backup_alias to distinguish. *)
let test_coord_fallthrough_audit_broadcast_tier () =
  with_temp_dir (fun dir ->
      C2c_mcp.log_coord_fallthrough_fired
        ~broker_root:dir
        ~perm_id:"perm:fallthrough:slice-skel-2"
        ~tier:3
        ~primary_alias:"coordinator1"
        ~backup_alias:"<broadcast>"
        ~requester_alias:"galaxy-coder"
        ~elapsed_s:360.0
        ~ts:1714389960.0;
      let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
      check int "one broadcast-tier line" 1 (List.length lines);
      let json = List.hd lines in
      let open Yojson.Safe.Util in
      check string "backup_alias is <broadcast>" "<broadcast>"
        (json |> member "backup_alias" |> to_string);
      check int "tier 3" 3 (json |> member "tier" |> to_int))

(* slice/coord-backup-scheduler-impl: helper — open a pending entry
   with caller-controlled created_at so we can simulate "elapsed past
   the idle threshold" without sleeping. *)
let make_pending
    ?(perm_id = "perm:scheduler-test")
    ?(requester_alias = "galaxy-coder")
    ?(supervisors = [ "coordinator1" ])
    ?(elapsed_s = 0.0)
    ?(resolved_at = None)
    ?(fallthrough_fired_at = [])
    ()
  : C2c_mcp.pending_permission =
  let now = Unix.gettimeofday () in
  { perm_id
  ; kind = C2c_mcp.Permission
  ; requester_session_id = "session-galaxy"
  ; requester_alias
  ; supervisors
  ; created_at = now -. elapsed_s
  ; expires_at = now +. 600.0
  ; fallthrough_fired_at
  ; resolved_at
  }

(* slice/coord-backup-scheduler-impl T1: at idle threshold the
   scheduler fires the first backup tier — DM enqueued AND
   fallthrough_fired_at[0] is set. *)
let test_coord_fallthrough_fires_at_idle_threshold () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register the backup so it counts as Alive. registration_is_alive
         on a pidless row returns true (Alive collapse), see broker
         predicate. The backup needs an inbox to receive the DM. *)
      C2c_mcp.Broker.register broker ~session_id:"session-backup-1"
        ~alias:"stanza-coder" ~pid:None ~pid_start_time:None ();
      (* Pre-load a pending entry past the idle threshold. *)
      let p = make_pending ~elapsed_s:125.0 () in
      C2c_mcp.Broker.open_pending_permission broker p;
      Coord_fallthrough.tick
        ~broker
        ~broker_root:dir
        ~chain:[ "stanza-coder" ]
        ~idle_seconds:120.0
        ~broadcast_room:"swarm-lounge"
        ();
      (* Backup got the DM. *)
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-backup-1" in
      check int "backup inbox has one DM" 1 (List.length inbox);
      let m = List.hd inbox in
      check bool "DM body mentions perm_id" true
        (string_contains m.C2c_mcp.content p.perm_id);
      check string "DM from coord-fallthrough sender"
        Coord_fallthrough.broadcast_sender_alias m.C2c_mcp.from_alias;
      (* Audit line written. *)
      let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
      check int "one fallthrough audit line" 1 (List.length lines);
      let json = List.hd lines in
      let open Yojson.Safe.Util in
      check int "tier 1" 1 (json |> member "tier" |> to_int);
      check string "backup_alias=stanza-coder" "stanza-coder"
        (json |> member "backup_alias" |> to_string);
      (* fallthrough_fired_at[0] is set. *)
      let stored = C2c_mcp.Broker.find_pending_permission broker p.perm_id in
      (match stored with
       | None -> fail "pending entry vanished"
       | Some s ->
           (match List.nth_opt s.fallthrough_fired_at 0 with
            | Some (Some _) -> ()
            | _ -> fail "fallthrough_fired_at[0] not stamped")))

(* slice/coord-backup-scheduler-impl T2: an entry with resolved_at set
   does not trigger any fallthrough fire, regardless of elapsed time. *)
let test_coord_fallthrough_resolved_skips () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-backup-1"
        ~alias:"stanza-coder" ~pid:None ~pid_start_time:None ();
      let now = Unix.gettimeofday () in
      let p = make_pending ~elapsed_s:300.0
                ~resolved_at:(Some (now -. 100.0)) () in
      C2c_mcp.Broker.open_pending_permission broker p;
      Coord_fallthrough.tick
        ~broker
        ~broker_root:dir
        ~chain:[ "stanza-coder" ]
        ~idle_seconds:120.0
        ~broadcast_room:"swarm-lounge"
        ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-backup-1" in
      check int "no DM enqueued for resolved entry" 0 (List.length inbox);
      let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
      check int "no audit line for resolved entry" 0 (List.length lines))

(* slice/coord-backup-scheduler-impl T3 / Cairn answer 2:
   skip-and-advance — when chain[0] has no live registration, advance
   to chain[1] in the SAME tick (don't wait next 60s). *)
let test_coord_fallthrough_skip_and_advance () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Only the second backup has a live registration. *)
      C2c_mcp.Broker.register broker ~session_id:"session-live-coord"
        ~alias:"live-coord" ~pid:None ~pid_start_time:None ();
      let p = make_pending ~elapsed_s:125.0 () in
      C2c_mcp.Broker.open_pending_permission broker p;
      Coord_fallthrough.tick
        ~broker
        ~broker_root:dir
        ~chain:[ "offline-coord"; "live-coord" ]
        ~idle_seconds:120.0
        ~broadcast_room:"swarm-lounge"
        ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-live-coord" in
      check int "live-coord got DM same tick" 1 (List.length inbox);
      (* Offline-coord row was skipped (stamped) but no enqueue
         happened to it. *)
      let stored = C2c_mcp.Broker.find_pending_permission broker p.perm_id in
      (match stored with
       | None -> fail "pending entry vanished"
       | Some s ->
           check int "fired_at has 2 stamps (skip + fire)" 2
             (List.length s.fallthrough_fired_at);
           (match s.fallthrough_fired_at with
            | [ Some _; Some _ ] -> ()
            | _ -> fail "expected both tier slots stamped"));
      (* Audit log: only the live-coord fire emits audit. The skipped
         offline tier does not — silent skip. *)
      let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
      check int "one audit line (live-coord only)" 1 (List.length lines);
      let json = List.hd lines in
      let open Yojson.Safe.Util in
      check string "backup_alias=live-coord" "live-coord"
        (json |> member "backup_alias" |> to_string))

(* slice/coord-backup-scheduler-impl T4 / Cairn answer 3: once the
   entire chain is fired-or-skipped, broadcast to broadcast_room.
   Audit line has tier=N+1 and backup_alias="<broadcast>". *)
let test_coord_fallthrough_chain_exhausted_broadcasts () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Set up two live backups + create the broadcast room with the
         requester as a member so fan_out_room_message has somewhere
         to land messages we can verify. *)
      C2c_mcp.Broker.register broker ~session_id:"session-a"
        ~alias:"a" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-b"
        ~alias:"b" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-watcher"
        ~alias:"watcher" ~pid:None ~pid_start_time:None ();
      let _ : C2c_mcp.room_member list =
        C2c_mcp.Broker.join_room broker
          ~room_id:"swarm-lounge" ~alias:"watcher"
          ~session_id:"session-watcher"
      in
      (* Past 3*idle (a, b, broadcast) — ensures all three tiers fire
         in one drain pass. *)
      let p = make_pending ~elapsed_s:400.0 () in
      C2c_mcp.Broker.open_pending_permission broker p;
      Coord_fallthrough.tick
        ~broker
        ~broker_root:dir
        ~chain:[ "a"; "b" ]
        ~idle_seconds:120.0
        ~broadcast_room:"swarm-lounge"
        ();
      (* Watcher in swarm-lounge got the broadcast. *)
      let inbox =
        C2c_mcp.Broker.read_inbox broker ~session_id:"session-watcher"
      in
      check bool "watcher got broadcast" true
        (List.exists
           (fun (m : C2c_mcp.message) ->
             string_contains m.C2c_mcp.content "@coordinator-backup")
           inbox);
      (* Audit log: 3 lines — tier 1 (a), tier 2 (b), tier 3
         (broadcast). *)
      let lines =
        parse_broker_log_lines_with_event dir "coord_fallthrough_fired"
      in
      check int "three fallthrough audit lines" 3 (List.length lines);
      let broadcast_line =
        List.find
          (fun json ->
            let open Yojson.Safe.Util in
            json |> member "backup_alias" |> to_string = "<broadcast>")
          lines
      in
      let open Yojson.Safe.Util in
      check int "broadcast tier = chain_len+1" 3
        (broadcast_line |> member "tier" |> to_int))

(* slice/coord-backup-scheduler-impl T5: check_pending_reply with a
   valid supervisor reply stamps resolved_at on the entry. *)
let test_check_pending_reply_writes_resolved_at () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-coord";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-coord"
            ~alias:"coordinator1" ~pid:None ~pid_start_time:None ();
          let p = make_pending
                    ~perm_id:"perm:resolved-at-test"
                    ~supervisors:[ "coordinator1" ] () in
          C2c_mcp.Broker.open_pending_permission broker p;
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 9100)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String p.perm_id) ] )
                    ] )
              ]
          in
          let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          let stored = C2c_mcp.Broker.find_pending_permission broker p.perm_id in
          (match stored with
           | None -> fail "pending entry vanished"
           | Some s ->
               check bool "resolved_at <> None after valid check" true
                 (s.resolved_at <> None))))

(* slice/coord-backup-scheduler-impl T6: idempotency — running the
   scheduler twice past the same threshold fires the backup tier
   exactly ONCE. The second tick observes fallthrough_fired_at[0]
   already stamped and skips. *)
let test_coord_fallthrough_no_double_fire () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-backup"
        ~alias:"stanza-coder" ~pid:None ~pid_start_time:None ();
      let p = make_pending ~elapsed_s:125.0 () in
      C2c_mcp.Broker.open_pending_permission broker p;
      let do_tick () =
        Coord_fallthrough.tick
          ~broker
          ~broker_root:dir
          ~chain:[ "stanza-coder" ]
          ~idle_seconds:120.0
          ~broadcast_room:"swarm-lounge"
          ()
      in
      do_tick ();
      do_tick ();
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"session-backup" in
      check int "exactly one DM after double-tick" 1 (List.length inbox);
       let lines = parse_broker_log_lines_with_event dir "coord_fallthrough_fired" in
       check int "exactly one audit line after double-tick" 1 (List.length lines))

(* slice/coord-backup-fallthrough T9: primary (or any supervisor) replies
   BEFORE idle threshold → backup never DM'd. resolved_at blocks fire. *)
let test_coord_fallthrough_resolved_blocks_fire () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      (* Register the primary/supervisor alias so check_pending_reply succeeds. *)
      C2c_mcp.Broker.register broker ~session_id:"session-coord"
        ~alias:"coordinator1" ~pid:None ~pid_start_time:None ();
      (* Create a pending entry at "now" (elapsed_s=0). *)
      let p = make_pending ~elapsed_s:0.0 () in
      C2c_mcp.Broker.open_pending_permission broker p;
      (* Simulate primary/supervisor reply — stamp resolved_at via
         check_pending_reply. Do this BEFORE advancing past idle threshold. *)
      Unix.putenv "C2C_MCP_SESSION_ID" "session-coord";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "") (fun () ->
        let request =
          `Assoc
            [ ("jsonrpc", `String "2.0")
            ; ("id", `Int 9109)
            ; ("method", `String "tools/call")
            ; ( "params",
                `Assoc
                  [ ("name", `String "check_pending_reply")
                  ; ( "arguments",
                      `Assoc [ ("perm_id", `String p.perm_id) ] )
                  ] )
            ]
        in
        let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
        (* Now advance time past the idle threshold (125s > 120s idle). *)
        let now = Unix.gettimeofday () in
        let late_now = now +. 125.0 in
        Coord_fallthrough.tick
          ~now:late_now
          ~broker
          ~broker_root:dir
          ~chain:[ "stanza-coder" ]
          ~idle_seconds:120.0
          ~broadcast_room:"swarm-lounge"
          ();
        (* No DM should be enqueued — entry is resolved. *)
        let inbox =
          C2c_mcp.Broker.read_inbox broker ~session_id:"session-backup"
        in
        check int "no DM after resolved_at stamp" 0 (List.length inbox);
        let lines =
          parse_broker_log_lines_with_event dir "coord_fallthrough_fired"
        in
        check int "no audit line for resolved entry" 0 (List.length lines)))

(* [#432 Slice D] check_pending_reply for an unknown perm_id emits a
   "pending_check" line with outcome="unknown_perm". *)
let test_pending_check_audit_log_outcome () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester-d2";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let broker = C2c_mcp.Broker.create ~root:dir in
          C2c_mcp.Broker.register broker ~session_id:"session-requester-d2"
            ~alias:"stanza-coder" ~pid:None ~pid_start_time:None ();
          let request =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 9002)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm:audit:slice-d-unknown")
                          ; ("reply_from_alias", `String "coordinator1")
                          ] )
                    ] )
              ]
          in
          let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request) in
          let lines = parse_broker_log_lines_with_event dir "pending_check" in
          check int "exactly one pending_check line" 1 (List.length lines);
          let json = List.hd lines in
          let open Yojson.Safe.Util in
          check string "outcome unknown_perm" "unknown_perm"
            (json |> member "outcome" |> to_string);
          (* Post-#432 Slice B: reply_from_alias is derived from the
             calling session's registration, not from request args.
             session-requester-d2 was registered as "stanza-coder", so
             that's what the audit line records — confirming the
             alias-binding fix is reflected in audit data. *)
          check string "reply_from_alias plaintext (session-derived)"
            "stanza-coder"
            (json |> member "reply_from_alias" |> to_string);
          let perm_id_hash = json |> member "perm_id_hash" |> to_string in
          check bool "perm_id_hash is 16 hex" true (is_hex16 perm_id_hash);
          (* Raw perm_id MUST NOT appear in the line. *)
          let raw_line =
            List.hd (read_broker_log_lines dir
                     |> List.filter (fun l -> string_contains l "pending_check"))
          in
          check bool "raw perm_id absent" false
            (string_contains raw_line "perm:audit:slice-d-unknown")))

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

(* [#432] Concurrent open_pending_permission across N forked children must
   not lose entries. Without with_pending_lock, two interleaved
   load→cons→save sequences would silently drop one of the entries (the
   classic POSIX-file-locking lost-update scenario). With the per-file
   advisory lock, all N entries persist. *)
let test_concurrent_open_pending_permission () =
  with_temp_dir (fun dir ->
      let n_children = 8 in
      let now = Unix.gettimeofday () in
      let children =
        List.init n_children (fun i ->
            match Unix.fork () with
            | 0 ->
                (* Child: each instantiates its OWN broker handle so the
                   lockf state is per-process (not shared via a parent fd).
                   Open a unique pending entry, then exit cleanly. *)
                let child_broker = C2c_mcp.Broker.create ~root:dir in
                let entry : C2c_mcp.pending_permission =
                  { perm_id = Printf.sprintf "perm-concurrent-%d" i
                  ; kind = C2c_mcp.Permission
                  ; requester_session_id = Printf.sprintf "session-%d" i
                  ; requester_alias = Printf.sprintf "alias-%d" i
                  ; supervisors = [ "coordinator1" ]
                  ; created_at = now
                  ; expires_at = now +. 600.0
                  ; fallthrough_fired_at = []
                  ; resolved_at = None
                  }
                in
                C2c_mcp.Broker.open_pending_permission child_broker entry;
                exit 0
            | pid -> pid)
      in
      (* [#432 EINTR fix] Wrap waitpid in an EINTR-retry loop. Slate
         observed a flake where a SIGALRM (heartbeat-armed test
         harness) landed during the parent's blocking waitpid, surfacing
         as Unix_error(EINTR, ...). Retry on EINTR — this is the
         standard pattern for blocking syscalls in OCaml. *)
      let rec waitpid_eintr pid =
        try Unix.waitpid [] pid
        with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr pid
      in
      List.iter
        (fun pid ->
          let _, status = waitpid_eintr pid in
          (match status with
           | Unix.WEXITED 0 -> ()
           | Unix.WEXITED rc ->
               Alcotest.fail (Printf.sprintf "child pid=%d exited rc=%d" pid rc)
           | Unix.WSIGNALED s ->
               Alcotest.fail (Printf.sprintf "child pid=%d signaled %d" pid s)
           | Unix.WSTOPPED s ->
               Alcotest.fail (Printf.sprintf "child pid=%d stopped %d" pid s)))
        children;
      (* Parent: probe each expected entry via the public API. With the
         lock in place, every child's open_pending_permission must have
         been serialized — all N perm_ids resolvable. Without the lock,
         interleaved load/save would drop some. *)
      let parent_broker = C2c_mcp.Broker.create ~root:dir in
      List.iter
        (fun i ->
          let expected = Printf.sprintf "perm-concurrent-%d" i in
          let found =
            C2c_mcp.Broker.find_pending_permission parent_broker expected
          in
          check bool
            (Printf.sprintf "entry for child %d preserved (no lost-update)" i)
            true (found <> None))
        (List.init n_children (fun i -> i)))
(* [#432 Slice B / Finding 4-B1] open_pending_reply must reject callers
   whose session is not registered. Pre-fix: the handler stored
   requester_alias="" and wrote the entry anyway — meaningless audit
   data + a small attack surface where unregistered callers prime the
   pending-permissions namespace. Post-fix: isError=true, no entry
   written. *)
let test_open_pending_reply_rejects_unregistered_caller () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-not-registered";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 91)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-unreg-1")
                          ; ("kind", `String "permission")
                          ; ("supervisors", `List [`String "coordinator1"])
                          ] )
                    ] )
              ]
          in
          let resp = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir req) in
          (match resp with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "isError=true on unregistered caller" true is_error;
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               check bool "error mentions registration requirement" true
                 (string_contains text "registered"));
          let broker = C2c_mcp.Broker.create ~root:dir in
          let entry =
            C2c_mcp.Broker.find_pending_permission broker "perm-unreg-1"
          in
          check bool "no pending entry written for unregistered caller"
            true (entry = None)))

(* [#432 Slice B / Finding 4-B2] check_pending_reply must derive
   reply_from_alias from the calling session's registration, NOT from
   request arguments. Pre-fix: any agent who knew a perm_id (visible in
   broker.log) could call with any supervisor's alias and get back the
   requester's session_id (info disclosure). Post-fix: alias derived
   from the calling session; legacy reply_from_alias arg is silently
   ignored. *)
let test_check_pending_reply_derives_from_session_not_arg () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-supervisor"
        ~alias:"coord-x" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-requester"
        ~alias:"reqr-x" ~pid:None ~pid_start_time:None ();
      Unix.putenv "C2C_MCP_SESSION_ID" "session-requester";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let open_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 92)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-derive-1")
                          ; ("kind", `String "permission")
                          ; ("supervisors", `List [`String "coord-x"])
                          ] )
                    ] )
              ]
          in
          let _ = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir open_req) in
          (* The supervisor calls check_pending_reply. The arg
             reply_from_alias is set to a NON-supervisor alias to
             simulate a legacy/malicious caller — the broker must
             ignore the arg and use the session-derived "coord-x". *)
          Unix.putenv "C2C_MCP_SESSION_ID" "session-supervisor";
          let check_req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 93)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-derive-1")
                          ; ("reply_from_alias", `String "fake-non-supervisor")
                          ] )
                    ] )
              ]
          in
          let resp =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir check_req)
          in
          (match resp with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let content_text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               let parsed = Yojson.Safe.from_string content_text in
               let valid =
                 parsed |> member "valid" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "valid=true (alias derived from session, not arg)"
                 true valid;
               let req_sid =
                 parsed |> member "requester_session_id" |> to_string_option
                 |> Option.value ~default:""
               in
               check string "requester_session_id returned correctly"
                 "session-requester" req_sid)))

(* [#432 Slice B / Finding 4-B2 companion] check_pending_reply rejects
   callers whose session is not registered. *)
let test_check_pending_reply_rejects_unregistered_caller () =
  with_temp_dir (fun dir ->
      Unix.putenv "C2C_MCP_SESSION_ID" "session-not-registered-2";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 94)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "check_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-anything")
                          ; ("reply_from_alias", `String "coordinator1")
                          ] )
                    ] )
              ]
          in
          let resp = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir req) in
          (match resp with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "isError=true on unregistered caller" true is_error)))

(* [#432 Slice C] per-alias capacity cap. After [pending_per_alias_cap]
   pending entries are open for a single alias, the next open must be
   rejected with [Pending_capacity_exceeded (`Per_alias _)]. Bounds a
   single bad/compromised caller's footprint and the M4 register-guard
   scan length. *)
let test_open_pending_permission_per_alias_cap () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let now = Unix.gettimeofday () in
      let make_entry i =
        ({ perm_id = Printf.sprintf "perm-cap-%d" i
         ; kind = C2c_mcp.Permission
         ; requester_session_id = "session-flooder"
         ; requester_alias = "flooder"
         ; supervisors = [ "coord" ]
         ; created_at = now
         ; expires_at = now +. 600.0
         ; fallthrough_fired_at = []
         ; resolved_at = None
         } : C2c_mcp.pending_permission)
      in
      (* Open exactly cap entries — must all succeed. *)
      for i = 0 to C2c_mcp.Broker.pending_per_alias_cap - 1 do
        C2c_mcp.Broker.open_pending_permission broker (make_entry i)
      done;
      (* The (cap+1)-th open must raise. *)
      let raised =
        try
          C2c_mcp.Broker.open_pending_permission broker
            (make_entry C2c_mcp.Broker.pending_per_alias_cap);
          None
        with C2c_mcp.Broker.Pending_capacity_exceeded which -> Some which
      in
      check bool "per-alias cap raises Pending_capacity_exceeded" true
        (raised <> None);
      (match raised with
       | Some (`Per_alias a) ->
           check string "raised with the offending alias" "flooder" a
       | Some `Global -> fail "expected Per_alias, got Global"
       | None -> fail "expected exception"))

(* [#432 follow-up by stanza-coder] [pending_permission_exists_for_alias]
   compares case-insensitively. Closes the symmetry sweep across all
   alias-eviction surfaces (Broker.register eviction at L1898;
   alias_hijack_conflict at L5074; alias_occupied_guard at L4704; this
   pending-perm guard at L848). Without case-fold here, an attacker
   could open a pending permission under "Foo-Bar" and the M4 alias-
   reuse guard at register time would miss case-variant lookups
   ("foo-bar" / "FOO-BAR"), leaving the pending-perm-takeover path
   composable with case-variance. *)
let test_pending_permission_exists_for_alias_is_case_insensitive () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let now = Unix.gettimeofday () in
      let entry =
        ({ perm_id = "perm-casefold-1"
         ; kind = C2c_mcp.Permission
         ; requester_session_id = "session-victim"
         ; requester_alias = "Foo-Bar"
         ; supervisors = [ "coord" ]
         ; created_at = now
         ; expires_at = now +. 600.0
         ; fallthrough_fired_at = []
         ; resolved_at = None
         } : C2c_mcp.pending_permission)
      in
      C2c_mcp.Broker.open_pending_permission broker entry;
      check bool "exact match (Foo-Bar) finds pending perm" true
        (C2c_mcp.Broker.pending_permission_exists_for_alias broker "Foo-Bar");
      check bool "lowercase variant (foo-bar) finds pending perm" true
        (C2c_mcp.Broker.pending_permission_exists_for_alias broker "foo-bar");
      check bool "uppercase variant (FOO-BAR) finds pending perm" true
        (C2c_mcp.Broker.pending_permission_exists_for_alias broker "FOO-BAR");
      check bool "mixed-case variant (FoO-BaR) finds pending perm" true
        (C2c_mcp.Broker.pending_permission_exists_for_alias broker "FoO-BaR");
      check bool "unrelated alias does NOT find pending perm" false
        (C2c_mcp.Broker.pending_permission_exists_for_alias broker "other-alias"))

(* [#432 Slice C] expired entries do not count toward the cap. After
   N expired entries + (cap-1) live entries, the next open must
   succeed because the lazy-eviction filter sees only the live ones. *)
let test_open_pending_permission_expired_dont_count () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let now = Unix.gettimeofday () in
      (* Pre-load 5 expired entries by writing the JSON file directly.
         Using literal JSON rather than C2c_mcp.pending_permission_to_json
         which is not exposed in the .mli. *)
      let expired_json =
        `List
          (List.init 5 (fun i ->
               `Assoc
                 [ ("perm_id", `String (Printf.sprintf "perm-expired-%d" i))
                 ; ("kind", `String "permission")
                 ; ("requester_session_id", `String "session-old")
                 ; ("requester_alias", `String "flooder")
                 ; ("supervisors", `List [`String "coord"])
                 ; ("created_at", `Float (now -. 1200.0))
                 ; ("expires_at", `Float (now -. 600.0)) ]))
      in
      let path = Filename.concat dir "pending_permissions.json" in
      let oc = open_out path in
      output_string oc (Yojson.Safe.to_string expired_json);
      close_out oc;
      (* Now open exactly cap fresh entries — all must succeed because
         the expired ones don't count. *)
      let make_fresh i =
        ({ perm_id = Printf.sprintf "perm-fresh-%d" i
         ; kind = C2c_mcp.Permission
         ; requester_session_id = "session-flooder"
         ; requester_alias = "flooder"
         ; supervisors = [ "coord" ]
         ; created_at = now
         ; expires_at = now +. 600.0
         ; fallthrough_fired_at = []
         ; resolved_at = None
         } : C2c_mcp.pending_permission)
      in
      for i = 0 to C2c_mcp.Broker.pending_per_alias_cap - 1 do
        C2c_mcp.Broker.open_pending_permission broker (make_fresh i)
      done;
      (* Verify all cap fresh entries are present (and no expired). *)
      List.iter
        (fun i ->
          let pid = Printf.sprintf "perm-fresh-%d" i in
          check bool
            (Printf.sprintf "fresh entry %d present after expired pre-load" i)
            true
            (C2c_mcp.Broker.find_pending_permission broker pid <> None))
        (List.init C2c_mcp.Broker.pending_per_alias_cap (fun i -> i)))

(* [#432 Slice C] MCP handler returns isError=true with explanatory text
   when per-alias cap is exceeded. *)
let test_open_pending_reply_handler_returns_error_at_cap () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-flooder"
        ~alias:"flooder" ~pid:None ~pid_start_time:None ();
      let now = Unix.gettimeofday () in
      (* Pre-fill to cap directly via the broker API. *)
      for i = 0 to C2c_mcp.Broker.pending_per_alias_cap - 1 do
        C2c_mcp.Broker.open_pending_permission broker
          { perm_id = Printf.sprintf "perm-prefill-%d" i
          ; kind = C2c_mcp.Permission
          ; requester_session_id = "session-flooder"
          ; requester_alias = "flooder"
          ; supervisors = [ "coord" ]
          ; created_at = now
          ; expires_at = now +. 600.0
          ; fallthrough_fired_at = []
          ; resolved_at = None }
      done;
      Unix.putenv "C2C_MCP_SESSION_ID" "session-flooder";
      Fun.protect ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
        (fun () ->
          let req =
            `Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 432)
              ; ("method", `String "tools/call")
              ; ( "params",
                  `Assoc
                    [ ("name", `String "open_pending_reply")
                    ; ( "arguments",
                        `Assoc
                          [ ("perm_id", `String "perm-overflow")
                          ; ("kind", `String "permission")
                          ; ("supervisors", `List [`String "coord"])
                          ] )
                    ] )
              ]
          in
          let resp = Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir req) in
          (match resp with
           | None -> fail "expected tools/call response"
           | Some json ->
               let open Yojson.Safe.Util in
               let is_error =
                 json |> member "result" |> member "isError" |> to_bool_option
                 |> Option.value ~default:false
               in
               check bool "isError=true at cap" true is_error;
               let text =
                 json |> member "result" |> member "content" |> index 0
                 |> member "text" |> to_string
               in
               check bool "error mentions cap reached" true
                 (string_contains text "cap reached"))))

(* [#432 Slice E] Relay-e2e TOFU pins were process-local Hashtbls; every
   broker restart silently reset first-seen-wins for messaging-layer
   x25519/ed25519 identity. The fix persists both Hashtbls to
   <broker_root>/relay_pins.json under flock + tmp+rename. The two
   "persists across recreate" tests below assert the simple round-trip;
   the concurrent-fork test mirrors Slice A's lost-update guard. *)
let test_relay_pin_x25519_persists_across_broker_recreate () =
  with_temp_dir (fun dir ->
      let broker1 = C2c_mcp.Broker.create ~root:dir in
      let pk = "x25519-test-pubkey-base64-aaaa" in
      let r = C2c_mcp.Broker.pin_x25519_sync ~alias:"foo" ~pk in
      check bool "first pin returns New_pin" true (r = `New_pin);
      let _ = broker1 in
      (* Recreate broker handle from same root — simulates restart. The
         in-memory Hashtbl gets re-loaded from relay_pins.json. *)
      let _broker2 = C2c_mcp.Broker.create ~root:dir in
      (match C2c_mcp.Broker.get_pinned_x25519 "foo" with
       | Some pk' ->
         check string "x25519 pin survives broker recreate" pk pk'
       | None ->
         Alcotest.fail "x25519 pin not persisted across broker recreate"))

let test_relay_pin_ed25519_persists_across_broker_recreate () =
  with_temp_dir (fun dir ->
      let broker1 = C2c_mcp.Broker.create ~root:dir in
      let pk = "ed25519-test-pubkey-base64-bbbb" in
      let r = C2c_mcp.Broker.pin_ed25519_sync ~alias:"bar" ~pk in
      check bool "first pin returns New_pin" true (r = `New_pin);
      let _ = broker1 in
      let _broker2 = C2c_mcp.Broker.create ~root:dir in
      (match C2c_mcp.Broker.get_pinned_ed25519 "bar" with
       | Some pk' ->
         check string "ed25519 pin survives broker recreate" pk pk'
       | None ->
         Alcotest.fail "ed25519 pin not persisted across broker recreate"))

(* [#432 TOFU 5 observability] Operator-clear path: deleting
   <broker_root>/relay_pins.json wipes in-memory pins on the next
   load_relay_pins_from_disk call. Pre-fix, [load_section] only
   cleared the Hashtbl when the on-disk JSON contained
   `Some (`Assoc entries)` for the section, so an externally-
   deleted file would leave stale pins in process memory. The fix
   makes in-memory a true write-through cache of disk: file
   missing → both Hashtbls clear. *)
let test_relay_pin_external_delete_clears_in_memory () =
  with_temp_dir (fun dir ->
      let broker1 = C2c_mcp.Broker.create ~root:dir in
      let _ = C2c_mcp.Broker.pin_x25519_sync ~alias:"alpha" ~pk:"pk-x" in
      let _ = C2c_mcp.Broker.pin_ed25519_sync ~alias:"alpha" ~pk:"pk-ed" in
      check bool "x25519 pinned before delete" true
        (C2c_mcp.Broker.get_pinned_x25519 "alpha" <> None);
      check bool "ed25519 pinned before delete" true
        (C2c_mcp.Broker.get_pinned_ed25519 "alpha" <> None);
      let _ = broker1 in
      (* Operator deletes the on-disk pin store. *)
      let pin_path = Filename.concat dir "relay_pins.json" in
      Sys.remove pin_path;
      (* Broker.create re-runs load_relay_pins_from_disk which now
         clears both Hashtbls when the file is missing. *)
      let _broker2 = C2c_mcp.Broker.create ~root:dir in
      check bool "x25519 cleared after external delete" true
        (C2c_mcp.Broker.get_pinned_x25519 "alpha" = None);
      check bool "ed25519 cleared after external delete" true
        (C2c_mcp.Broker.get_pinned_ed25519 "alpha" = None))

(* [#432 TOFU 5 observability] Companion: malformed JSON is also
   treated as "operator wiped store" — both Hashtbls clear rather
   than retaining stale state. Catches the case where a corrupted
   write or external editing produces non-JSON content. *)
let test_relay_pin_malformed_json_clears_in_memory () =
  with_temp_dir (fun dir ->
      let broker1 = C2c_mcp.Broker.create ~root:dir in
      let _ = C2c_mcp.Broker.pin_x25519_sync ~alias:"beta" ~pk:"pk-x" in
      check bool "x25519 pinned before corrupt" true
        (C2c_mcp.Broker.get_pinned_x25519 "beta" <> None);
      let _ = broker1 in
      (* Operator (or filesystem corruption) leaves non-JSON garbage. *)
      let pin_path = Filename.concat dir "relay_pins.json" in
      let oc = open_out pin_path in
      output_string oc "this-is-not-json";
      close_out oc;
      let _broker2 = C2c_mcp.Broker.create ~root:dir in
      check bool "x25519 cleared after malformed JSON" true
        (C2c_mcp.Broker.get_pinned_x25519 "beta" = None))

(* [#432 Slice E] Mirrors Slice A's [test_concurrent_open_pending_permission]:
   N forked children each pin a distinct alias from a fresh broker
   handle (independent flock state). After all children exit, the
   parent recreates the broker and confirms every alias is visible. A
   missing flock would cause read-modify-write interleaving to drop
   pins; with the lock all N persist. *)
let test_relay_pin_concurrent_save_no_lost_update () =
  with_temp_dir (fun dir ->
      let n_children = 4 in
      let children =
        List.init n_children (fun i ->
            match Unix.fork () with
            | 0 ->
                let _child_broker = C2c_mcp.Broker.create ~root:dir in
                let alias = Printf.sprintf "alias-pin-%d" i in
                let pk = Printf.sprintf "pk-x25519-child-%d-aaaa" i in
                let _ = C2c_mcp.Broker.pin_x25519_sync ~alias ~pk in
                exit 0
            | pid -> pid)
      in
      (* [#432 EINTR fix, mirrors Slice A] Retry waitpid on EINTR; a
         SIGALRM from a heartbeat-armed test harness landing during a
         blocking waitpid surfaces as Unix_error(EINTR, ...). *)
      let rec waitpid_eintr pid =
        try Unix.waitpid [] pid
        with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_eintr pid
      in
      List.iter
        (fun pid ->
          let _, status = waitpid_eintr pid in
          (match status with
           | Unix.WEXITED 0 -> ()
           | Unix.WEXITED rc ->
               Alcotest.fail (Printf.sprintf "child pid=%d exited rc=%d" pid rc)
           | Unix.WSIGNALED s ->
               Alcotest.fail (Printf.sprintf "child pid=%d signaled %d" pid s)
           | Unix.WSTOPPED s ->
               Alcotest.fail (Printf.sprintf "child pid=%d stopped %d" pid s)))
        children;
      let _parent_broker = C2c_mcp.Broker.create ~root:dir in
      List.iter
        (fun i ->
          let alias = Printf.sprintf "alias-pin-%d" i in
          let expected_pk = Printf.sprintf "pk-x25519-child-%d-aaaa" i in
          match C2c_mcp.Broker.get_pinned_x25519 alias with
          | Some pk ->
            check string
              (Printf.sprintf "pin for child %d preserved (no lost-update)" i)
              expected_pk pk
          | None ->
            Alcotest.fail
              (Printf.sprintf "pin for child %d dropped (lost-update)" i))
        (List.init n_children (fun i -> i)))

(* CRIT-1 Slice B — TOFU integration tests for from_ed25519 receive path.
   Plan: .collab/design/2026-04-29-relay-crypto-crit-fix-plan-cairn.md.
   Production code: C2c_mcp.decrypt_envelope (~lines 4296-4410) handles
   Slice B claimed-Ed25519 semantics: prefer claimed for verify, reject
   pinned/claimed mismatch BEFORE sig verify, pin claimed on first-contact
   success, leave pin untouched on legacy v1 (no claim).

   Real box-x25519-v1 encryption is required (the plain-envelope and
   Not_for_me branches both bypass the TOFU code path). Receiver-side
   X25519 + Ed25519 identities are constructed in-memory via
   [Relay_enc.generate] / [Relay_identity.generate] so the tests touch
   no env vars or on-disk identity files — earlier drafts that
   overrode HOME/C2C_KEY_DIR and restored via [Unix.putenv ""] left
   [Sys.getenv_opt] returning [Some ""], which downstream code treats
   as a valid empty keys_dir and writes stray .x25519 files into CWD.
   [decrypt_envelope] takes our keys as explicit args, so no env
   override is needed for the test surface. *)

(* Generate Ed25519 keypair (sender's signing identity). Mirrors
   gen_ed25519 in test_relay_e2e.ml. *)
let slice_b_gen_ed25519 () =
  Mirage_crypto_rng_unix.use_default ();
  let priv, pub = Mirage_crypto_ec.Ed25519.generate () in
  let seed = Mirage_crypto_ec.Ed25519.priv_to_octets priv in
  let pk_raw = Mirage_crypto_ec.Ed25519.pub_to_octets pub in
  seed, pk_raw

(* Build a signed v2 envelope with from_ed25519 = sender_ed_b64.
   Encrypts plaintext to recipient's X25519 pubkey. Returns the wire
   JSON string ready to be wrapped in a [message] for decrypt. *)
let slice_b_make_signed_envelope
    ~sender_alias ~sender_ed_seed ~sender_ed_b64
    ~sender_x_keys ~recipient_alias ~recipient_x_pk_b64
    ~plaintext ~envelope_version =
  let our_sk_seed = sender_x_keys.Relay_enc.private_key_seed in
  let sender_x_pk_b64 = Relay_enc.public_key_b64 sender_x_keys in
  let (ct_b64, nonce_b64) =
    match Relay_e2e.encrypt_for_recipient
            ~pt:plaintext ~recipient_pk_b64:recipient_x_pk_b64 ~our_sk_seed with
    | Some pair -> pair
    | None -> Alcotest.fail "encrypt_for_recipient returned None"
  in
  let recipient =
    { Relay_e2e.alias = recipient_alias
    ; nonce = Some nonce_b64
    ; ciphertext = ct_b64 }
  in
  let env =
    { Relay_e2e.from_ = sender_alias
    ; from_x25519 = Some sender_x_pk_b64
    ; from_ed25519 = (if envelope_version >= 2 then Some sender_ed_b64 else None)
    ; to_ = Some recipient_alias
    ; room = None
    ; ts = 1700000020L
    ; enc = "box-x25519-v1"
    ; recipients = [ recipient ]
    ; sig_b64 = ""
    ; envelope_version }
  in
  let signed = Relay_e2e.set_sig env ~sk_seed:sender_ed_seed in
  Yojson.Safe.to_string (Relay_e2e.envelope_to_json signed)

let slice_b_make_message ~from_alias ~to_alias ~content : C2c_mcp.message =
  { from_alias; to_alias; content
  ; deferrable = false; reply_via = None
  ; enc_status = None; ts = 0.0; ephemeral = false; message_id = None }

(* Slice B test 1: empty pin store + v2 envelope with from_ed25519
   → on success the broker pins the claimed key. *)
let test_slice_b_tofu_first_contact_pins () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-fc" and recipient_alias = "recipient-fc" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (* In-memory keys only — Relay_enc.generate touches no disk and
         needs no env. *)
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-b-first-contact-plaintext-marker" in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:2
      in
      (* Pre-condition: pin store empty for sender. *)
      check (option string) "pre: no pinned ed25519"
        None (C2c_mcp.Broker.get_pinned_ed25519 sender_alias);
      let our_x25519 = Some recipient_x in
      (* Receiver-side ed25519 only gates the decrypt branch (Some _);
         the actual sig verify uses the SENDER's pinned/claimed pubkey,
         so any locally-generated identity satisfies the gate. *)
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check string "first-contact decrypts to plaintext" plaintext decrypted;
      check (option string) "first-contact enc_status = ok"
        (Some "ok") enc_status;
      (* Post-condition: TOFU pinned the claimed Ed25519. *)
      check (option string) "first-contact pins claimed ed25519"
        (Some ed_pk_b64)
        (C2c_mcp.Broker.get_pinned_ed25519 sender_alias)))

(* Slice B test 2: pin already matches → accept, pin unchanged. *)
let test_slice_b_tofu_already_pinned_accepts () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-ap" and recipient_alias = "recipient-ap" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (* Pre-pin the sender's ed25519 to the SAME key the envelope claims. *)
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:ed_pk_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial pin");
      (* In-memory keys only — Relay_enc.generate touches no disk and
         needs no env. *)
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-b-already-pinned-plaintext-marker" in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:2
      in
      let our_x25519 = Some recipient_x in
      (* Receiver-side ed25519 only gates the decrypt branch (Some _);
         the actual sig verify uses the SENDER's pinned/claimed pubkey,
         so any locally-generated identity satisfies the gate. *)
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check string "already-pinned decrypts to plaintext" plaintext decrypted;
      check (option string) "already-pinned enc_status = ok"
        (Some "ok") enc_status;
      check (option string) "pin unchanged after same-key receive"
        (Some ed_pk_b64)
        (C2c_mcp.Broker.get_pinned_ed25519 sender_alias)))

(* Slice B test 3: pinned key X, envelope claims key Y → reject with
   key-changed BEFORE sig verify (so the test does not need a real key
   pair matching the claim). Pin must remain at X (not overwritten). *)
let test_slice_b_tofu_mismatch_rejects () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-mm" and recipient_alias = "recipient-mm" in
      let pinned_b64 = "PINNED-ed25519-b64-stable-key-X" in
      let claimed_b64 = "CLAIMED-ed25519-b64-rotated-key-Y" in
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:pinned_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial pin");
      (* The sender uses a real Ed25519 keypair to sign — but claims a
         DIFFERENT b64 in [from_ed25519]. The mismatch check fires before
         sig verify per Slice B design, so the (real-sig, fake-claim)
         combination is exactly what the production guard rejects. *)
      let (real_seed, _real_pk_raw) = slice_b_gen_ed25519 () in
      (* In-memory keys only — Relay_enc.generate touches no disk and
         needs no env. *)
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-b-mismatch-plaintext-must-not-leak" in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:real_seed ~sender_ed_b64:claimed_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:2
      in
      let our_x25519 = Some recipient_x in
      (* Receiver-side ed25519 only gates the decrypt branch (Some _);
         the actual sig verify uses the SENDER's pinned/claimed pubkey,
         so any locally-generated identity satisfies the gate. *)
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check (option string) "mismatch enc_status = key-changed"
        (Some "key-changed") enc_status;
      check bool "mismatch does not leak plaintext"
        false (decrypted = plaintext);
      check (option string) "pin not overwritten by mismatched claim"
        (Some pinned_b64)
        (C2c_mcp.Broker.get_pinned_ed25519 sender_alias)))

(* Slice B follow-up: structured audit-log line on Ed25519 pin mismatch
   reject. Same fixture as test 3 above but asserts the broker.log line
   is written with the correct event/alias/pinned/claimed fields. Closes
   slate's flagged observability gap from the Slice B PASS. *)
let test_slice_b_followup_pin_mismatch_audit_log () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-mma" and recipient_alias = "recipient-mma" in
      let pinned_b64 = "PINNED-ed25519-b64-stable-key-aud" in
      let claimed_b64 = "CLAIMED-ed25519-b64-rotated-key-aud" in
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:pinned_b64 with
       | `New_pin -> () | _ -> Alcotest.fail "pin");
      let (real_seed, _) = slice_b_gen_ed25519 () in
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:real_seed ~sender_ed_b64:claimed_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext:"x" ~envelope_version:2
      in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (_, _) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log written" true (Sys.file_exists log_path);
      let ic = open_in log_path in
      let log_content =
        try
          let buf = Buffer.create 1024 in
          (try while true do
             Buffer.add_channel buf ic 1024
           done with End_of_file -> ());
          close_in ic;
          Buffer.contents buf
        with e -> close_in ic; raise e
      in
      let contains s sub =
        try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
        with Not_found -> false
      in
      check bool "audit-log has relay_e2e_pin_mismatch event" true
        (contains log_content "\"event\":\"relay_e2e_pin_mismatch\"");
      check bool "audit-log carries alias" true
        (contains log_content (Printf.sprintf "\"alias\":\"%s\"" sender_alias));
      check bool "audit-log carries pinned_ed25519_b64" true
        (contains log_content (Printf.sprintf "\"pinned_ed25519_b64\":\"%s\"" pinned_b64));
      check bool "audit-log carries claimed_ed25519_b64" true
        (contains log_content (Printf.sprintf "\"claimed_ed25519_b64\":\"%s\"" claimed_b64))))

(* TOFU first-contact audit-line test: after a successful first-contact decrypt
   (no prior pin, envelope carries a claimed Ed25519), broker.log must contain
   a [relay_e2e_pin_first_seen] line with the alias and the pinned key. *)
let test_relay_e2e_pin_first_seen_audit_log () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-fsf" and recipient_alias = "recipient-fsf" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (* Pre-condition: pin store empty for sender. *)
      check (option string) "pre: no pinned ed25519"
        None (C2c_mcp.Broker.get_pinned_ed25519 sender_alias);
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext:"first-seen-test" ~envelope_version:2
      in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check string "first-contact decrypts" "first-seen-test" decrypted;
      check (option string) "first-contact enc_status = ok"
        (Some "ok") enc_status;
      (* Post-condition: pin set. *)
      check (option string) "post: pinned ed25519"
        (Some ed_pk_b64)
        (C2c_mcp.Broker.get_pinned_ed25519 sender_alias);
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log written" true (Sys.file_exists log_path);
      let ic = open_in log_path in
      let log_content =
        try
          let buf = Buffer.create 512 in
          (try while true do Buffer.add_channel buf ic 512 done with End_of_file -> ());
          close_in ic;
          Buffer.contents buf
        with e -> close_in ic; raise e
      in
      let contains s sub =
        try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
        with Not_found -> false
      in
      check bool "audit-log has relay_e2e_pin_first_seen event" true
        (contains log_content "\"event\":\"relay_e2e_pin_first_seen\"");
      check bool "audit-log carries alias" true
        (contains log_content (Printf.sprintf "\"alias\":\"%s\"" sender_alias));
      check bool "audit-log carries pinned_ed25519_b64" true
        (contains log_content (Printf.sprintf "\"pinned_ed25519_b64\":\"%s\"" ed_pk_b64))))

(* Slice B test 4: legacy v1 envelope (no from_ed25519, envelope_version=1).
   Pre-pin the sender's real ed25519 — verifier falls back to pinned.
   Existing path must still decrypt; pin must NOT be spuriously rewritten
   (no first-contact write since claim is None). *)
let test_slice_b_tofu_legacy_v1_no_field_accepts_no_tofu_update () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-v1" and recipient_alias = "recipient-v1" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (* Pre-pin to the real key so the legacy fallback (claim absent →
         use pinned for verify) succeeds. *)
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:ed_pk_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial pin");
      (* In-memory keys only — Relay_enc.generate touches no disk and
         needs no env. *)
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-b-legacy-v1-plaintext-marker" in
      (* envelope_version = 1 → from_ed25519 omitted from the envelope and
         from the canonical-blob signature scope. *)
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:1
      in
      let our_x25519 = Some recipient_x in
      (* Receiver-side ed25519 only gates the decrypt branch (Some _);
         the actual sig verify uses the SENDER's pinned/claimed pubkey,
         so any locally-generated identity satisfies the gate. *)
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check string "legacy v1 decrypts to plaintext" plaintext decrypted;
      check (option string) "legacy v1 enc_status = ok"
        (Some "ok") enc_status;
      (* Pin must still be the original pre-pin value; legacy path must
         NOT spuriously write because there was no claim. *)
      check (option string) "legacy v1 pin unchanged"
        (Some ed_pk_b64)
        (C2c_mcp.Broker.get_pinned_ed25519 sender_alias)))

(* --- Slice B-min-version tests (per-peer min-observed-version pin) --- *)

(* Slice B-min-version test 1: first-contact at v2 sets min=2 via the
   bump after successful verify. Drives the full receive path and
   asserts the pin store records min_observed=2 afterward. *)
let test_slice_bmv_first_contact_v2_sets_min_2 () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-bmv-fc" and recipient_alias = "recipient-bmv-fc" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-bmv-first-contact-v2-marker" in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:2
      in
      check (option int) "pre: no min_observed_version pin"
        None (C2c_mcp.Broker.get_min_observed_version sender_alias);
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (_decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check (option string) "v2 first-contact enc_status = ok"
        (Some "ok") enc_status;
      check (option int) "post: min_observed_version pinned to 2"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias)))

(* Slice B-min-version test 2: subsequent v1 envelope from same peer
   rejected with version-downgrade-rejected enc_status. Pre-pin
   min=2 directly via the broker API, then drive a v1 envelope through
   and assert reject. Pin must remain at 2 (NOT lowered). *)
let test_slice_bmv_v1_rejected_after_v2_pin () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-bmv-rej" and recipient_alias = "recipient-bmv-rej" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (* Pre-pin both Ed25519 (so legacy v1 verify path can find a key)
         AND the min-version pin (so the downgrade check fires). *)
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:ed_pk_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial ed pin");
      let _ = C2c_mcp.Broker.bump_min_observed_version
        ~alias:sender_alias ~observed:2 in
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let plaintext = "slice-bmv-downgrade-attempt-marker" in
      (* Build a v1 envelope from the same sender. *)
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext ~envelope_version:1
      in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (decrypted, enc_status) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      check (option string) "v1 after v2 pin → version-downgrade-rejected"
        (Some "version-downgrade-rejected") enc_status;
      check bool "v1 reject does NOT decrypt to plaintext" false
        (decrypted = plaintext);
      check (option int) "min-version pin NOT lowered by reject"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias)))

(* Slice B-min-version test 3: v1→v2→v1 sequence. v1 first sets min=1
   (no defense yet); v2 bumps min to 2; subsequent v1 rejected. *)
let test_slice_bmv_v1_then_v2_then_v1_rejects () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-bmv-seq" and recipient_alias = "recipient-bmv-seq" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:ed_pk_b64 with
       | `New_pin -> ()
       | _ -> Alcotest.fail "expected New_pin on initial ed pin");
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let mk v =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext:"seq-marker" ~envelope_version:v
      in
      (* (1) First envelope is v1: verify succeeds, min bumped to 1. *)
      let (_, status1) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:(mk 1)
      in
      check (option string) "v1 first accepted" (Some "ok") status1;
      check (option int) "min after v1 first = 1"
        (Some 1) (C2c_mcp.Broker.get_min_observed_version sender_alias);
      (* (2) v2 envelope: verify succeeds, min bumped to 2. *)
      let (_, status2) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:(mk 2)
      in
      check (option string) "v2 second accepted" (Some "ok") status2;
      check (option int) "min after v2 second = 2"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias);
      (* (3) Subsequent v1 from same peer rejected. *)
      let (_, status3) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:(mk 1)
      in
      check (option string) "v1 after v2 → version-downgrade-rejected"
        (Some "version-downgrade-rejected") status3;
      check (option int) "min still pinned to 2 after reject"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias)))

(* Slice B-min-version test 4: audit-log line is emitted on reject.
   Asserts a JSON line in broker.log carrying event=version_downgrade_rejected
   with the alias + observed + pinned_min fields. *)
let test_slice_bmv_audit_log_emitted_on_reject () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "sender-bmv-aud" and recipient_alias = "recipient-bmv-aud" in
      let (ed_seed, ed_pk_raw) = slice_b_gen_ed25519 () in
      let ed_pk_b64 = Relay_e2e.b64_encode ed_pk_raw in
      (match C2c_mcp.Broker.pin_ed25519_sync ~alias:sender_alias ~pk:ed_pk_b64 with
       | `New_pin -> () | _ -> Alcotest.fail "pin");
      let _ = C2c_mcp.Broker.bump_min_observed_version
        ~alias:sender_alias ~observed:2 in
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let wire =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:ed_seed ~sender_ed_b64:ed_pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext:"x" ~envelope_version:1
      in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let (_, _) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias ~content:wire
      in
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log written" true (Sys.file_exists log_path);
      let ic = open_in log_path in
      let log_content =
        try
          let buf = Buffer.create 1024 in
          (try while true do
             Buffer.add_channel buf ic 1024
           done with End_of_file -> ());
          close_in ic;
          Buffer.contents buf
        with e -> close_in ic; raise e
      in
      let contains s sub =
        try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
        with Not_found -> false
      in
      check bool "audit-log has version_downgrade_rejected event" true
        (contains log_content "\"event\":\"version_downgrade_rejected\"");
      check bool "audit-log has alias" true
        (contains log_content (Printf.sprintf "\"alias\":\"%s\"" sender_alias));
      check bool "audit-log has observed_envelope_version=1" true
        (contains log_content "\"observed_envelope_version\":1");
      check bool "audit-log has pinned_min_envelope_version=2" true
        (contains log_content "\"pinned_min_envelope_version\":2")))

(* CRIT-2 cross-host divergence: full pin-flow against canonical-alias-form
   senders (alice@hostA → bob@hostB). Sequences three phases against the
   same broker:
   (1) v2 first-contact: TOFU pin + min=2 + relay_e2e_pin_first_seen audit;
   (2) rotated-key v2 from same alias: key-changed reject + pin_mismatch
       audit + pin not overwritten;
   (3) v1 with original key: version-downgrade-rejected + downgrade audit
       + min still 2.
   Confirms pin store keys on the literal alias string, so alice@hostA and
   alice@hostB do not collide. *)
let test_cross_host_divergence_full_pin_flow () =
  with_temp_dir (fun dir ->
    (
      let _broker = C2c_mcp.Broker.create ~root:dir in
      let sender_alias = "alice@hostA" and recipient_alias = "bob@hostB" in
      let (ed_seed1, ed_pk1_raw) = slice_b_gen_ed25519 () in
      let ed_pk1_b64 = Relay_e2e.b64_encode ed_pk1_raw in
      let (ed_seed2, ed_pk2_raw) = slice_b_gen_ed25519 () in
      let ed_pk2_b64 = Relay_e2e.b64_encode ed_pk2_raw in
      let sender_x = Relay_enc.generate ~alias:sender_alias () in
      let recipient_x = Relay_enc.generate ~alias:recipient_alias () in
      let recipient_x_pk_b64 = Relay_enc.public_key_b64 recipient_x in
      let our_x25519 = Some recipient_x in
      let our_ed25519 = Some (Relay_identity.generate ()) in
      let mk ~seed ~pk_b64 ~v =
        slice_b_make_signed_envelope
          ~sender_alias ~sender_ed_seed:seed ~sender_ed_b64:pk_b64
          ~sender_x_keys:sender_x ~recipient_alias
          ~recipient_x_pk_b64 ~plaintext:"crit2-xhost" ~envelope_version:v
      in
      let read_log () =
        let log_path = Filename.concat dir "broker.log" in
        let ic = open_in log_path in
        let buf = Buffer.create 1024 in
        (try while true do Buffer.add_channel buf ic 1024 done
         with End_of_file -> ());
        close_in ic; Buffer.contents buf
      in
      let contains s sub =
        try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
        with Not_found -> false
      in
      (* Phase 1: TOFU first-contact at v2. *)
      let (_, status1) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias
          ~content:(mk ~seed:ed_seed1 ~pk_b64:ed_pk1_b64 ~v:2)
      in
      check (option string) "phase1 enc_status=ok" (Some "ok") status1;
      check (option string) "phase1 pin set to claimed key"
        (Some ed_pk1_b64) (C2c_mcp.Broker.get_pinned_ed25519 sender_alias);
      check (option int) "phase1 min_observed_version=2"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias);
      let log1 = read_log () in
      check bool "phase1 audit: relay_e2e_pin_first_seen" true
        (contains log1 "\"event\":\"relay_e2e_pin_first_seen\"");
      check bool "phase1 audit: alias literal alice@hostA" true
        (contains log1 (Printf.sprintf "\"alias\":\"%s\"" sender_alias));
      (* Phase 2: rotated key from same alias → key-changed reject. *)
      let (_, status2) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias
          ~content:(mk ~seed:ed_seed2 ~pk_b64:ed_pk2_b64 ~v:2)
      in
      check (option string) "phase2 enc_status=key-changed"
        (Some "key-changed") status2;
      check (option string) "phase2 pin NOT overwritten by rotated key"
        (Some ed_pk1_b64) (C2c_mcp.Broker.get_pinned_ed25519 sender_alias);
      let log2 = read_log () in
      check bool "phase2 audit: relay_e2e_pin_mismatch" true
        (contains log2 "\"event\":\"relay_e2e_pin_mismatch\"");
      (* Phase 3: original key but envelope_version=1 → downgrade reject. *)
      let (_, status3) =
        C2c_mcp.decrypt_envelope ~our_x25519 ~our_ed25519
          ~to_alias:recipient_alias
          ~content:(mk ~seed:ed_seed1 ~pk_b64:ed_pk1_b64 ~v:1)
      in
      check (option string) "phase3 enc_status=version-downgrade-rejected"
        (Some "version-downgrade-rejected") status3;
      check (option int) "phase3 min_observed_version still 2"
        (Some 2) (C2c_mcp.Broker.get_min_observed_version sender_alias);
      let log3 = read_log () in
      check bool "phase3 audit: version_downgrade_rejected" true
        (contains log3 "\"event\":\"version_downgrade_rejected\"")))

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

(* #432: case-fold consistency in alias resolution.

   Before #432: register evicted other-session rows with
   case-INSENSITIVE alias_casefold match (c2c_mcp.ml:1572) but
   resolve_live_session_id_by_alias filtered with case-SENSITIVE
   reg.alias = alias (c2c_mcp.ml:1208). A stale row whose alias
   differed from the new alias only in case was NOT found by resolver
   lookups but WAS evicted by registration — leaving the resolver
   blind to a row register would have cleared. Combined with the
   pid-refresh self-heal at L1228-1244, this could resurrect stale
   rows. The audit at .collab/research/2026-04-29-stanza-coder-cross-host-routing-audit.md
   identifies this as the H1' hypothesis shape. *)

let test_resolve_alias_case_insensitive () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let live_pid = Unix.getpid () in
      C2c_mcp.Broker.register broker
        ~session_id:"s-foobar"
        ~alias:"Foo-Bar"
        ~pid:(Some live_pid)
        ~pid_start_time:(C2c_mcp.Broker.read_pid_start_time live_pid)
        ();
      (* Sender uppercase variant must resolve to the same session. *)
      (match C2c_mcp.Broker.resolve_live_session_id_by_alias broker "FOO-BAR" with
       | C2c_mcp.Broker.Resolved sid ->
           check string "uppercase resolves to registered session" "s-foobar" sid
       | C2c_mcp.Broker.Unknown_alias ->
           failwith "expected Resolved, got Unknown_alias"
       | C2c_mcp.Broker.All_recipients_dead ->
           failwith "expected Resolved, got All_recipients_dead");
      (* Mixed-case variant. *)
      (match C2c_mcp.Broker.resolve_live_session_id_by_alias broker "foo-bar" with
       | C2c_mcp.Broker.Resolved sid ->
           check string "lowercase resolves to registered session" "s-foobar" sid
       | _ -> failwith "expected Resolved for lowercase variant"))

let test_resolve_alias_no_match_when_session_dead () =
  (* Register a row with a dead pid + alias differing only in case from
     the lookup; without a fresh process discoverable via the proc
     hooks, the pid-refresh self-heal must NOT resurrect it. The test
     drives resolve directly so we bypass enqueue's heal path; the
     case-fold filter must still reject the dead row as a delivery
     target. *)
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"s-stale"
        ~alias:"Foo-Bar"
        ~pid:(Some dead_pid)
        ~pid_start_time:(Some 99)
        ();
      (* Pre-flight: the row IS discoverable by case-fold (asymmetric
         eviction predicate sees it), confirming we built the right
         test shape. *)
      (let regs = C2c_mcp.Broker.list_registrations broker in
       check int "registry has the stale row" 1 (List.length regs));
      (* Hook the proc scan to return NO live candidate — refresh has
         nothing to bind to. *)
      Fun.protect
        ~finally:C2c_mcp.Broker.clear_proc_hooks_for_test
        (fun () ->
          C2c_mcp.Broker.set_proc_hooks_for_test
            ~scan_pids:(fun () -> [])
            ~read_environ:(fun _ -> None)
            ();
          (* Lookup by case-fold variant. The resolver finds the row
             (case-insensitive filter) but it's dead; heal fails (no
             discovery candidate); result must be All_recipients_dead. *)
          match C2c_mcp.Broker.resolve_live_session_id_by_alias broker "FOO-BAR" with
          | C2c_mcp.Broker.All_recipients_dead -> ()
          | C2c_mcp.Broker.Resolved sid ->
              failwith
                (Printf.sprintf
                   "stale row resurrected: resolver returned Resolved %s for case-fold variant"
                   sid)
          | C2c_mcp.Broker.Unknown_alias ->
              failwith "expected All_recipients_dead, got Unknown_alias"))

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
      check bool "DM is non-deferrable (#307b — handoff pushes immediately)"
        false msg.deferrable;
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

(* #327: every send-memory-handoff attempt is logged to broker.log
   so silent failures (handoff didn't reach recipient inbox despite
   the entry write succeeding) are diagnosable after-the-fact.
   Pre-#327 there was no broker-side trace; the 2026-04-27 incident
   had to be confirmed via inbox archive inspection. *)
let test_notify_logs_each_attempt_to_broker_log () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-log-author" ~alias:"alice-log"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-log-bob" ~alias:"bob-log"
        ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-log" ~name:"logged-note"
          ~shared:false ~shared_with:["bob-log"] ()
      in
      let log_path = Filename.concat dir "broker.log" in
      check bool "broker.log exists after handoff" true
        (Sys.file_exists log_path);
      let log_contents =
        let ic = open_in log_path in
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          let buf = Buffer.create 256 in
          (try while true do
             Buffer.add_string buf (input_line ic);
             Buffer.add_char buf '\n'
           done with End_of_file -> ());
          Buffer.contents buf)
      in
      let contains needle =
        let nl = String.length needle in
        let hl = String.length log_contents in
        let rec scan i = i + nl <= hl
          && (String.sub log_contents i nl = needle || scan (i+1))
        in scan 0
      in
      check bool "log includes send_memory_handoff event" true
        (contains "\"event\":\"send_memory_handoff\"");
      check bool "log includes from alias" true
        (contains "\"from\":\"alice-log\"");
      check bool "log includes to alias" true
        (contains "\"to\":\"bob-log\"");
      check bool "log includes entry name" true
        (contains "\"name\":\"logged-note\"");
      check bool "log marks ok=true on success" true
        (contains "\"ok\":true"))

let test_notify_logs_failure_with_error_field () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-failog-author"
        ~alias:"alice-failog" ~pid:None ~pid_start_time:None ();
      (* Recipient "ghost-failog" not registered → enqueue_message raises →
         logged with ok:false + error string. *)
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-failog" ~name:"failog-note"
          ~shared:false ~shared_with:["ghost-failog"] ()
      in
      check int "unknown recipient is silently dropped" 0 (List.length notified);
      let log_path = Filename.concat dir "broker.log" in
      let log_contents =
        let ic = open_in log_path in
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          let buf = Buffer.create 256 in
          (try while true do
             Buffer.add_string buf (input_line ic);
             Buffer.add_char buf '\n'
           done with End_of_file -> ());
          Buffer.contents buf)
      in
      let contains needle =
        let nl = String.length needle in
        let hl = String.length log_contents in
        let rec scan i = i + nl <= hl
          && (String.sub log_contents i nl = needle || scan (i+1))
        in scan 0
      in
      check bool "log marks ok=false on failure" true
        (contains "\"ok\":false");
      check bool "log includes error field" true
        (contains "\"error\":"))

(* #307b: handoff DM must be visible to drain_inbox_push (the path the
   PostToolUse hook + channel-notification watcher use). With #286's
   original [~deferrable:true], drain_inbox_push filtered the handoff
   out and the recipient only saw it on explicit poll_inbox. *)
let test_notify_shared_with_appears_in_push_drain () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-author6" ~alias:"alice-push"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-bob6" ~alias:"bob-push"
        ~pid:None ~pid_start_time:None ();
      let notified =
        C2c_mcp.notify_shared_with_recipients
          ~broker ~from_alias:"alice-push" ~name:"push-note"
          ~shared:false ~shared_with:["bob-push"] ()
      in
      check int "one recipient notified" 1 (List.length notified);
      let pushed = C2c_mcp.Broker.drain_inbox_push broker ~session_id:"s-bob6" in
      check int "push drain returns the handoff DM" 1 (List.length pushed);
      let msg = List.hd pushed in
      check string "pushed DM is from the author" "alice-push" msg.from_alias;
      check bool "pushed DM is non-deferrable" false msg.deferrable)

(* ─── Rooms ACL slice (H1/H2/H3) ─────────────────────────────────────── *)

let rooms_acl_call_tool ~broker_root ~session_id ~tool_name ~arguments =
  Unix.putenv "C2C_MCP_SESSION_ID" session_id;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "C2C_MCP_SESSION_ID" "")
    (fun () ->
      let request =
        `Assoc
          [ ("jsonrpc", `String "2.0")
          ; ("id", `Int 1)
          ; ("method", `String "tools/call")
          ; ( "params"
            , `Assoc
                [ ("name", `String tool_name)
                ; ("arguments", arguments)
                ] )
          ]
      in
      Lwt_main.run (C2c_mcp.handle_request ~broker_root request))

let rooms_acl_extract_result_text json =
  let open Yojson.Safe.Util in
  json |> member "result" |> member "content" |> index 0
  |> member "text" |> to_string

let rooms_acl_is_error json =
  let open Yojson.Safe.Util in
  match json |> member "result" |> member "isError" with
  | `Bool b -> b
  | _ -> false

(* H1 — room_history membership gate *)

let test_room_history_invite_only_blocks_non_member () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sess-creator"
        ~alias:"creator" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"sess-outsider"
        ~alias:"outsider" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"secret"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret"
        ~from_alias:"creator" ~visibility:Invite_only;
      let _ =
        C2c_mcp.Broker.send_room broker ~from_alias:"creator"
          ~room_id:"secret" ~content:"private chatter"
      in
      let response =
        rooms_acl_call_tool ~broker_root:dir ~session_id:"sess-outsider"
          ~tool_name:"room_history"
          ~arguments:(`Assoc [ ("room_id", `String "secret") ])
      in
      match response with
      | None -> fail "expected room_history response"
      | Some json ->
          check bool "isError set on non-member read" true (rooms_acl_is_error json);
          let text = rooms_acl_extract_result_text json in
          check bool "error text mentions not a member" true
            (string_contains text "not a member of secret"))

let test_room_history_invite_only_allows_member () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sess-creator"
        ~alias:"creator" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"secret"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"secret"
        ~from_alias:"creator" ~visibility:Invite_only;
      let _ =
        C2c_mcp.Broker.send_room broker ~from_alias:"creator"
          ~room_id:"secret" ~content:"insider chatter"
      in
      let response =
        rooms_acl_call_tool ~broker_root:dir ~session_id:"sess-creator"
          ~tool_name:"room_history"
          ~arguments:(`Assoc [ ("room_id", `String "secret") ])
      in
      match response with
      | None -> fail "expected room_history response"
      | Some json ->
          check bool "no isError for member read" false (rooms_acl_is_error json);
          let text = rooms_acl_extract_result_text json in
          let arr = Yojson.Safe.from_string text |> Yojson.Safe.Util.to_list in
          check bool "history non-empty for member" true (List.length arr >= 1))

let test_room_history_public_allows_anyone () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sess-creator"
        ~alias:"creator" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"sess-rando"
        ~alias:"rando" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"plaza"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      let _ =
        C2c_mcp.Broker.send_room broker ~from_alias:"creator"
          ~room_id:"plaza" ~content:"public chatter"
      in
      let response =
        rooms_acl_call_tool ~broker_root:dir ~session_id:"sess-rando"
          ~tool_name:"room_history"
          ~arguments:(`Assoc [ ("room_id", `String "plaza") ])
      in
      match response with
      | None -> fail "expected room_history response"
      | Some json ->
          check bool "no isError on public history read" false (rooms_acl_is_error json);
          let text = rooms_acl_extract_result_text json in
          let arr = Yojson.Safe.from_string text |> Yojson.Safe.Util.to_list in
          check bool "history visible to non-member of public room" true
            (List.length arr >= 1))

(* H2 — list_rooms invite-only filter *)

let test_list_rooms_filters_invite_only_for_non_members () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sess-creator"
        ~alias:"creator" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"sess-outsider"
        ~alias:"outsider" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"plaza"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"backroom"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"backroom"
        ~from_alias:"creator" ~visibility:Invite_only;
      let response =
        rooms_acl_call_tool ~broker_root:dir ~session_id:"sess-outsider"
          ~tool_name:"list_rooms" ~arguments:(`Assoc [])
      in
      match response with
      | None -> fail "expected list_rooms response"
      | Some json ->
          let text = rooms_acl_extract_result_text json in
          let arr = Yojson.Safe.from_string text |> Yojson.Safe.Util.to_list in
          let ids =
            List.map
              (fun r ->
                Yojson.Safe.Util.(r |> member "room_id" |> to_string))
              arr
          in
          check bool "plaza visible to non-member" true (List.mem "plaza" ids);
          check bool "backroom hidden from non-member" false
            (List.mem "backroom" ids))

let test_list_rooms_redacts_invited_pre_join () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"sess-creator"
        ~alias:"creator" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"sess-invitee"
        ~alias:"invitee" ~pid:None ~pid_start_time:None ();
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"club"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      C2c_mcp.Broker.set_room_visibility broker ~room_id:"club"
        ~from_alias:"creator" ~visibility:Invite_only;
      C2c_mcp.Broker.send_room_invite broker ~room_id:"club"
        ~from_alias:"creator" ~invitee_alias:"invitee";
      let response =
        rooms_acl_call_tool ~broker_root:dir ~session_id:"sess-invitee"
          ~tool_name:"list_rooms" ~arguments:(`Assoc [])
      in
      match response with
      | None -> fail "expected list_rooms response"
      | Some json ->
          let text = rooms_acl_extract_result_text json in
          let arr = Yojson.Safe.from_string text |> Yojson.Safe.Util.to_list in
          let club =
            List.find_opt
              (fun r ->
                Yojson.Safe.Util.(r |> member "room_id" |> to_string) = "club")
              arr
          in
          (match club with
           | None -> fail "invited-pre-join: club should be visible"
           | Some r ->
               let open Yojson.Safe.Util in
               let members = r |> member "members" |> to_list in
               check int "members redacted to empty for invited-pre-join" 0
                 (List.length members);
               let invited = r |> member "invited_members" |> to_list in
               check int "invited_members redacted for invited-pre-join" 0
                 (List.length invited)))

(* H3 — delete_room creator-auth *)

let test_delete_room_requires_creator () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"workshop"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"workshop"
          ~alias:"creator"
      in
      check_raises "non-creator delete rejected"
        (Invalid_argument
           "delete_room rejected: only the creator 'creator' may delete room 'workshop'")
        (fun () ->
          C2c_mcp.Broker.delete_room broker ~room_id:"workshop"
            ~caller_alias:"intruder" ()))

let test_delete_room_creator_succeeds () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"workshop"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"workshop"
          ~alias:"creator"
      in
      C2c_mcp.Broker.delete_room broker ~room_id:"workshop"
        ~caller_alias:"creator" ();
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check bool "room deleted by creator" true
        (not (List.exists
                (fun (r : C2c_mcp.Broker.room_info) -> r.ri_room_id = "workshop")
                rooms)))

let test_delete_room_legacy_requires_force () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let _ =
        C2c_mcp.Broker.join_room broker ~room_id:"legacy"
          ~alias:"creator" ~session_id:"sess-creator"
      in
      (* Simulate a legacy room: clear created_by from meta. *)
      let meta = C2c_mcp.Broker.load_room_meta broker ~room_id:"legacy" in
      C2c_mcp.Broker.save_room_meta broker ~room_id:"legacy"
        { meta with created_by = "" };
      let _ =
        C2c_mcp.Broker.leave_room broker ~room_id:"legacy"
          ~alias:"creator"
      in
      (* Without force: rejected even for what looks like the creator. *)
      check_raises "legacy room delete refused without force"
        (Invalid_argument
           "delete_room rejected: room 'legacy' has no recorded creator (legacy room) — pass force=true to delete")
        (fun () ->
          C2c_mcp.Broker.delete_room broker ~room_id:"legacy"
            ~caller_alias:"creator" ());
      (* With force: deletes. *)
      C2c_mcp.Broker.delete_room broker ~room_id:"legacy"
        ~caller_alias:"creator" ~force:true ();
      let rooms = C2c_mcp.Broker.list_rooms broker in
      check bool "legacy room deleted with force" true
        (not (List.exists
                (fun (r : C2c_mcp.Broker.room_info) -> r.ri_room_id = "legacy")
                rooms)))
(* #387 slice B: drained_by archive field --------------------------------- *)

(* Read raw archive JSONL lines and return parsed top-level objects.
   Used by the drained_by tests to inspect a field that the typed
   archive_entry now exposes (ae_drained_by) but pre-#387 entries did
   not carry. *)
let read_raw_archive_records dir session_id =
  let path = Filename.concat dir ("archive/" ^ session_id ^ ".jsonl") in
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | exception End_of_file -> close_in ic; List.rev acc
      | line ->
          let line = String.trim line in
          if line = "" then loop acc
          else
            (match Yojson.Safe.from_string line with
             | exception _ -> loop acc
             | j -> loop (j :: acc))
    in
    loop []

let test_drained_by_recorded_on_poll_inbox () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-sender"
        ~alias:"sender-poll" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-recv"
        ~alias:"recv-poll" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender-poll"
        ~to_alias:"recv-poll" ~content:"hi-poll" ();
      let drained =
        C2c_mcp.Broker.drain_inbox ~drained_by:"poll_inbox" broker
          ~session_id:"s-recv"
      in
      check int "drained one" 1 (List.length drained);
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"s-recv" ~limit:10
      in
      check int "archive has one entry" 1 (List.length entries);
      check string "drained_by recorded" "poll_inbox"
        (List.hd entries).C2c_mcp.Broker.ae_drained_by)

(* --- S2 sticker-react integration tests ----------------------------------- *)

let is_valid_uuid_prefix s =
  String.length s >= 4
  && String.for_all (function '0'..'9' | 'a'..'f' | 'A'..'F' | '-' -> true | _ -> false) s

let test_message_id_assigned_on_local_enqueue () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-alice"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-bob"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"hello bob" ();
      let drained = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-bob" in
      check int "drained one message" 1 (List.length drained);
      let msg = List.hd drained in
      (* drain_inbox returns message records which have message_id *)
      (match msg.message_id with
       | None ->
           check bool "message_id is Some (not None)" true false
       | Some mid ->
           check bool "message_id is non-empty" true (String.length mid > 0);
           check bool "message_id is valid hex (UUID v4)" true (is_valid_uuid_prefix mid);
           let archive_path = C2c_mcp.Broker.archive_path broker ~session_id:"session-bob" in
           check bool "archive file exists" true (Sys.file_exists archive_path);
           let entries = C2c_mcp.Broker.read_archive broker ~session_id:"session-bob" ~limit:10 in
           check int "archive has one entry" 1 (List.length entries);
           match List.hd entries with
           | e ->
               (match e.C2c_mcp.Broker.ae_message_id with
                | None -> check bool "archive entry has message_id (Some)" true false
                | Some amid ->
                    check string "archive message_id matches drained message_id" mid amid)
      ))

let test_reaction_archived_with_target_msg_id () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"session-alice"
        ~alias:"alice" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"session-bob"
        ~alias:"bob" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"alice"
        ~to_alias:"bob" ~content:"original message" ();
      let drained = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-bob" in
      check int "drained original" 1 (List.length drained);
      let orig_msg_id = match (List.hd drained).message_id with
        | Some id -> id | None -> ""
      in
      check bool "original message has message_id" true (orig_msg_id <> "");
      let reaction_body =
        Printf.sprintf "<c2c event=\"reaction\" from=\"bob\" target_msg_id=\"%s\" sticker_id=\"thumbsup\"/>"
          orig_msg_id
      in
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"bob"
        ~to_alias:"alice" ~content:reaction_body ();
      let drained_alice = C2c_mcp.Broker.drain_inbox broker ~session_id:"session-alice" in
      check int "alice drained reaction" 1 (List.length drained_alice);
      let reaction_entry = List.hd drained_alice in
      (* drained message has content field *)
      check bool "reaction content contains target_msg_id" true
        (string_contains reaction_entry.content orig_msg_id);
      let entries = C2c_mcp.Broker.read_archive broker ~session_id:"session-alice" ~limit:10 in
      check int "archive has 1 entry (reaction)" 1 (List.length entries);
      let archived = List.hd entries in
      check string "archived from_alias is bob" "bob" archived.C2c_mcp.Broker.ae_from_alias;
      check bool "archived content is reaction body" true
        (string_contains archived.C2c_mcp.Broker.ae_content "event=\"reaction\"");
      check bool "archived content has target_msg_id" true
        (string_contains archived.C2c_mcp.Broker.ae_content orig_msg_id)
  )

let test_drained_by_recorded_on_watcher () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-w-sender"
        ~alias:"sender-w" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-w-recv"
        ~alias:"recv-w" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender-w"
        ~to_alias:"recv-w" ~content:"hi-watcher" ();
      (* Simulate the channel-watcher call site which uses drain_inbox_push
         with drained_by:"watcher". *)
      let drained =
        C2c_mcp.Broker.drain_inbox_push ~drained_by:"watcher" broker
          ~session_id:"s-w-recv"
      in
      check int "watcher drained one" 1 (List.length drained);
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"s-w-recv" ~limit:10
      in
      check int "archive has one entry" 1 (List.length entries);
      check string "drained_by recorded as watcher" "watcher"
        (List.hd entries).C2c_mcp.Broker.ae_drained_by)

let test_drained_by_default_for_legacy_entries () =
  with_temp_dir (fun dir ->
      (* Hand-write a legacy archive line that omits drained_by, mirroring
         the pre-#387 schema. read_archive must parse it cleanly with
         ae_drained_by defaulted to "unknown". *)
      let archive_dir = Filename.concat dir "archive" in
      Unix.mkdir archive_dir 0o700;
      let path = Filename.concat archive_dir "s-legacy.jsonl" in
      let oc = open_out path in
      output_string oc
        "{\"drained_at\":1.0,\"session_id\":\"s-legacy\",\
         \"from_alias\":\"old-alice\",\"to_alias\":\"old-bob\",\
         \"content\":\"legacy ping\"}\n";
      close_out oc;
      let broker = C2c_mcp.Broker.create ~root:dir in
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"s-legacy" ~limit:10
      in
      check int "legacy entry parsed" 1 (List.length entries);
      let e = List.hd entries in
      check string "from_alias preserved" "old-alice"
        e.C2c_mcp.Broker.ae_from_alias;
      check string "drained_by defaults to unknown" "unknown"
        e.C2c_mcp.Broker.ae_drained_by)

(* Confirm the freshly-written archive line really carries the
   top-level [drained_by] field on disk (not just decoded by us). *)
let test_drained_by_persisted_as_top_level_field () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-p-sender"
        ~alias:"sender-p" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-p-recv"
        ~alias:"recv-p" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender-p"
        ~to_alias:"recv-p" ~content:"persist-me" ();
      let _ =
        C2c_mcp.Broker.drain_inbox ~drained_by:"hook" broker
          ~session_id:"s-p-recv"
      in
      let raw = read_raw_archive_records dir "s-p-recv" in
      check int "one raw line" 1 (List.length raw);
      match List.hd raw with
      | `Assoc fields ->
          (match List.assoc_opt "drained_by" fields with
           | Some (`String s) ->
               check string "top-level drained_by field" "hook" s
           | _ -> fail "drained_by missing or wrong type")
      | _ -> fail "archive line is not a JSON object")

(* #387 slice A2: hook skips drain when session is channel-capable -------- *)

(* The hook executable wraps a small bit of logic around two Broker calls:
   [is_session_channel_capable] and [drain_inbox_push]. We exercise that
   exact pair here instead of forking the binary, since the executable
   reads C2C_MCP_SESSION_ID / C2C_MCP_BROKER_ROOT env vars at startup. *)
let hook_drain_simulating_a2 broker ~session_id =
  if C2c_mcp.Broker.is_session_channel_capable broker ~session_id then
    [] (* skipped — watcher owns delivery *)
  else
    C2c_mcp.Broker.drain_inbox_push ~drained_by:"hook" broker ~session_id

let test_hook_skips_drain_for_channel_capable () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-snd-cc"
        ~alias:"sender-cc" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-rcv-cc"
        ~alias:"recv-cc" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.set_automated_delivery broker
        ~session_id:"s-rcv-cc" ~automated_delivery:true;
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender-cc"
        ~to_alias:"recv-cc" ~content:"channel-test" ();
      let drained = hook_drain_simulating_a2 broker ~session_id:"s-rcv-cc" in
      check int "hook drains nothing on channel-capable" 0 (List.length drained);
      (* Inbox must still hold the message for the watcher. *)
      let remaining =
        C2c_mcp.Broker.read_inbox broker ~session_id:"s-rcv-cc"
      in
      check int "inbox unchanged" 1 (List.length remaining);
      check string "remaining content" "channel-test"
        (List.hd remaining).content)

let test_hook_drains_for_non_channel_capable () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"s-snd-nc"
        ~alias:"sender-nc" ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"s-rcv-nc"
        ~alias:"recv-nc" ~pid:None ~pid_start_time:None ();
      (* NOT setting automated_delivery — defaults to None / false. *)
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"sender-nc"
        ~to_alias:"recv-nc" ~content:"non-channel" ();
      let drained = hook_drain_simulating_a2 broker ~session_id:"s-rcv-nc" in
      check int "hook drains the message" 1 (List.length drained);
      let remaining =
        C2c_mcp.Broker.read_inbox broker ~session_id:"s-rcv-nc"
      in
      check int "inbox empty after hook drain" 0 (List.length remaining);
      let entries =
        C2c_mcp.Broker.read_archive broker ~session_id:"s-rcv-nc" ~limit:10
      in
      check int "archive has the entry" 1 (List.length entries);
      check string "drained_by recorded as hook" "hook"
        (List.hd entries).C2c_mcp.Broker.ae_drained_by)
(* --- H2: peer-pass DM signature verification at broker boundary ----------- *)

(* Build a peer-pass artifact path the way Peer_review does (must match
   ocaml/peer_review.ml:artifact_path). *)
let h2_artifact_path ~sha ~alias =
  let base = match Git_helpers.git_common_dir_parent () with
    | Some parent -> Filename.concat parent ".c2c"
    | None -> ".c2c"
  in
  let dir = Filename.concat base "peer-passes" in
  (try Unix.mkdir base 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Filename.concat dir (Printf.sprintf "%s-%s.json" sha alias)

(* SHA-like hex string (40 chars) unique per call so tests don't collide
   with each other or with real peer-pass artifacts on disk. Must be all
   hex because Peer_review.claim_of_content requires hex digits in SHA=. *)
let h2_unique_sha () =
  Printf.sprintf "%08x%08x%08x%08x%08x"
    (Random.bits ()) (Random.bits ()) (Random.bits ())
    (Random.bits ()) (Random.bits ())

let h2_with_artifact ~sha ~alias ~json f =
  let path = h2_artifact_path ~sha ~alias in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
       let oc = open_out path in
       output_string oc json;
       close_out oc;
       f ())

let h2_send_request ~from_alias ~to_alias ~content =
  `Assoc
    [ ("jsonrpc", `String "2.0")
    ; ("id", `Int 9001)
    ; ("method", `String "tools/call")
    ; ( "params",
        `Assoc
          [ ("name", `String "send")
          ; ( "arguments",
              `Assoc
                [ ("from_alias", `String from_alias)
                ; ("to_alias", `String to_alias)
                ; ("content", `String content)
                ] )
          ] )
    ]

let h2_response_is_error response =
  match response with
  | None -> failwith "expected tools/call response"
  | Some json ->
      let open Yojson.Safe.Util in
      let result = json |> member "result" in
      let is_error = try result |> member "isError" |> to_bool with _ -> false in
      let text =
        try result |> member "content" |> index 0 |> member "text" |> to_string
        with _ -> ""
      in
      (is_error, text)

let test_peer_pass_dm_with_invalid_signature_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2-sender" ~alias:"h2-sender-alias"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2-recv" ~alias:"h2-recv-alias"
        ~pid:None ~pid_start_time:None ();
      (* Forge an artifact: sign with one identity, then tamper the body so
         the signature no longer verifies. verify_claim should return
         Claim_invalid. *)
      let id = Relay_identity.generate ~alias_hint:"h2-forger" () in
      let sha = h2_unique_sha () in
      let art : Peer_review.t = {
        version = 1;
        reviewer = "h2-sender-alias";
        reviewer_pk = "";
        sha;
        verdict = "PASS";
        criteria_checked = [];
        skill_version = "1.0.0";
        commit_range = "0000000.." ^ sha;
        targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
        notes = "test forgery";
        signature = "";
        build_exit_code = None;
        ts = 1234567890.0;
      } in
      let signed = Peer_review.sign ~identity:id art in
      (* Tamper: change verdict but keep the old signature. *)
      let tampered = { signed with Peer_review.verdict = "FAIL" } in
      let json = Peer_review.t_to_string tampered in
      h2_with_artifact ~sha ~alias:"h2-sender-alias" ~json (fun () ->
        let content =
          Printf.sprintf "peer-PASS by h2-sender-alias for SHA=%s — looks good" sha
        in
        let request =
          h2_send_request ~from_alias:"h2-sender-alias"
            ~to_alias:"h2-recv-alias" ~content
        in
        let response =
          Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
        in
        let is_error, text = h2_response_is_error response in
        check bool "send returns isError=true on forged peer-pass" true is_error;
        check bool "error mentions peer-pass verification"
          true (string_contains text "peer-pass");
        (* And the recipient inbox must remain empty. *)
        let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2-recv" in
        check int "forged peer-pass DM is NOT enqueued" 0 (List.length inbox)))

let test_peer_pass_dm_with_valid_signature_accepted () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2v-sender" ~alias:"h2v-sender-alias"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2v-recv" ~alias:"h2v-recv-alias"
        ~pid:None ~pid_start_time:None ();
      let id = Relay_identity.generate ~alias_hint:"h2v-reviewer" () in
      let sha = h2_unique_sha () in
      let art : Peer_review.t = {
        version = 1;
        reviewer = "h2v-sender-alias";
        reviewer_pk = "";
        sha;
        verdict = "PASS";
        criteria_checked = ["builds"];
        skill_version = "1.0.0";
        commit_range = "0000000.." ^ sha;
        targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
        notes = "regression test artifact";
        signature = "";
        build_exit_code = None;
        ts = 1234567890.0;
      } in
      let signed = Peer_review.sign ~identity:id art in
      let json = Peer_review.t_to_string signed in
      h2_with_artifact ~sha ~alias:"h2v-sender-alias" ~json (fun () ->
        let content =
          Printf.sprintf "peer-PASS by h2v-sender-alias for SHA=%s" sha
        in
        let request =
          h2_send_request ~from_alias:"h2v-sender-alias"
            ~to_alias:"h2v-recv-alias" ~content
        in
        let response =
          Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
        in
        let is_error, _text = h2_response_is_error response in
        check bool "valid peer-pass DM is not flagged as error" false is_error;
        let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2v-recv" in
        check int "valid peer-pass DM is enqueued" 1 (List.length inbox)))

(* ---------------------------------------------------------------------- *)
(* #29 H2b — TOFU pin enforcement at the broker boundary.                  *)
(* ---------------------------------------------------------------------- *)

(* Build, sign, and write an artifact for a given (sha, alias) using the
   provided identity. Returns the b64url-encoded reviewer_pk so the caller
   can pre-seed pin store entries that match (or deliberately diverge from)
   it. The artifact file is left on disk; caller wraps with
   [h2_with_artifact_pre_existing] to clean up. *)
let h2b_make_artifact ~sha ~alias ~identity ~verdict =
  let art : Peer_review.t = {
    version = 1;
    reviewer = alias;
    reviewer_pk = "";
    sha;
    verdict;
    criteria_checked = [];
    skill_version = "1.0.0";
    commit_range = "0000000.." ^ sha;
    targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
    notes = "h2b-test";
    signature = "";
    build_exit_code = None;
    ts = 1234567890.0;
  } in
  let signed = Peer_review.sign ~identity art in
  let json = Peer_review.t_to_string signed in
  let path = h2_artifact_path ~sha ~alias in
  let oc = open_out path in
  output_string oc json;
  close_out oc;
  signed

let h2b_remove_artifact ~sha ~alias =
  let path = h2_artifact_path ~sha ~alias in
  try Sys.remove path with _ -> ()

(* Pre-seed the broker pin store at <root>/peer-pass-trust.json with a
   single (alias, pubkey) entry, so subsequent verifies hit Pin_match or
   Pin_mismatch instead of Pin_first_seen. *)
let h2b_seed_pin ~broker_root ~alias ~pubkey =
  let store : Peer_review.Trust_pin.store = {
    version = 1;
    pins = [
      String.lowercase_ascii alias,
      { Peer_review.Trust_pin.pubkey;
        first_seen = 1.0;
        last_seen = 1.0 };
    ];
  } in
  let path = Filename.concat broker_root "peer-pass-trust.json" in
  Peer_review.Trust_pin.save ~path store

(* Forgery vector slate flagged: attacker generates a fresh keypair and
   signs an artifact under the victim alias. Without H2b the broker
   accepted this. With H2b, after a legit pin exists for the alias, the
   forged artifact's pubkey fails to match the pin and the DM is
   rejected. *)
let test_peer_pass_dm_h2b_fresh_key_forgery_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2b-fk-s" ~alias:"h2b-fk-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2b-fk-r" ~alias:"h2b-fk-recv"
        ~pid:None ~pid_start_time:None ();
      (* Seed the pin with the LEGIT reviewer's pubkey for h2b-fk-sender. *)
      let legit_id = Relay_identity.generate ~alias_hint:"h2b-fk-legit" () in
      let legit_pk = Peer_review.b64url_encode legit_id.Relay_identity.public_key in
      h2b_seed_pin ~broker_root:dir ~alias:"h2b-fk-sender" ~pubkey:legit_pk;
      (* Attacker mints a fresh keypair and signs the forgery under the
         victim alias. *)
      let attacker_id = Relay_identity.generate ~alias_hint:"h2b-fk-attacker" () in
      let sha = h2_unique_sha () in
      Fun.protect
        ~finally:(fun () -> h2b_remove_artifact ~sha ~alias:"h2b-fk-sender")
        (fun () ->
          let _ = h2b_make_artifact ~sha ~alias:"h2b-fk-sender"
                    ~identity:attacker_id ~verdict:"PASS" in
          let content =
            Printf.sprintf "peer-PASS by h2b-fk-sender for SHA=%s — forged" sha
          in
          let request =
            h2_send_request ~from_alias:"h2b-fk-sender"
              ~to_alias:"h2b-fk-recv" ~content
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          let is_error, text = h2_response_is_error response in
          check bool "fresh-key forgery rejected (isError=true)" true is_error;
          check bool "user-facing reject text is generic (no pubkey leak)"
            false (string_contains text legit_pk);
          check bool "user-facing reject text is generic (no pin-mismatch leak)"
            false (string_contains text "pin mismatch");
          let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2b-fk-r" in
          check int "forged peer-pass DM is NOT enqueued" 0 (List.length inbox)))

(* Same shape as the fresh-key case but framed as "the legitimate signer's
   key changed and they forgot to --rotate-pin first". Still rejected;
   rotation is a separate operator action. *)
let test_peer_pass_dm_h2b_rotated_key_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2b-rk-s" ~alias:"h2b-rk-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2b-rk-r" ~alias:"h2b-rk-recv"
        ~pid:None ~pid_start_time:None ();
      let old_id = Relay_identity.generate ~alias_hint:"h2b-rk-old" () in
      let old_pk = Peer_review.b64url_encode old_id.Relay_identity.public_key in
      h2b_seed_pin ~broker_root:dir ~alias:"h2b-rk-sender" ~pubkey:old_pk;
      (* New key, same alias, no explicit rotation. *)
      let new_id = Relay_identity.generate ~alias_hint:"h2b-rk-new" () in
      let sha = h2_unique_sha () in
      Fun.protect
        ~finally:(fun () -> h2b_remove_artifact ~sha ~alias:"h2b-rk-sender")
        (fun () ->
          let _ = h2b_make_artifact ~sha ~alias:"h2b-rk-sender"
                    ~identity:new_id ~verdict:"PASS" in
          let content =
            Printf.sprintf "peer-PASS by h2b-rk-sender for SHA=%s" sha
          in
          let request =
            h2_send_request ~from_alias:"h2b-rk-sender"
              ~to_alias:"h2b-rk-recv" ~content
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          let is_error, _text = h2_response_is_error response in
          check bool "silent key rotation is rejected" true is_error;
          let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2b-rk-r" in
          check int "rotated-key peer-pass DM is NOT enqueued" 0 (List.length inbox)))

(* TOFU policy: the FIRST verify for an alias pins the pubkey and accepts
   the DM. Regression that we did not flip first-seen into a hard reject. *)
let test_peer_pass_dm_h2b_first_seen_allowed () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2b-fs-s" ~alias:"h2b-fs-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2b-fs-r" ~alias:"h2b-fs-recv"
        ~pid:None ~pid_start_time:None ();
      let id = Relay_identity.generate ~alias_hint:"h2b-fs-r1" () in
      let sha = h2_unique_sha () in
      Fun.protect
        ~finally:(fun () -> h2b_remove_artifact ~sha ~alias:"h2b-fs-sender")
        (fun () ->
          let _ = h2b_make_artifact ~sha ~alias:"h2b-fs-sender"
                    ~identity:id ~verdict:"PASS" in
          let content =
            Printf.sprintf "peer-PASS by h2b-fs-sender for SHA=%s" sha
          in
          let request =
            h2_send_request ~from_alias:"h2b-fs-sender"
              ~to_alias:"h2b-fs-recv" ~content
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          let is_error, _ = h2_response_is_error response in
          check bool "first-seen pin allows DM" false is_error;
          let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2b-fs-r" in
          check int "first-seen peer-pass DM is enqueued" 1 (List.length inbox);
          (* And the pin file now exists with the artifact's pubkey. *)
          let pin_path = Filename.concat dir "peer-pass-trust.json" in
          check bool "pin file written after first-seen verify"
            true (Sys.file_exists pin_path)))

(* Replay/cross-SHA: an attacker takes a legitimate artifact and DMs a
   peer-PASS naming a DIFFERENT SHA than the one the artifact was signed
   for. The signature still validates (artifact is unmodified) but
   verify_claim_with_pin's sha-equality check rejects. Independent of
   the pin. *)
let test_peer_pass_dm_h2b_sha_mismatch_rejected () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2b-sm-s" ~alias:"h2b-sm-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2b-sm-r" ~alias:"h2b-sm-recv"
        ~pid:None ~pid_start_time:None ();
      let id = Relay_identity.generate ~alias_hint:"h2b-sm" () in
      let real_sha = h2_unique_sha () in
      let claimed_sha = h2_unique_sha () in
      Fun.protect
        ~finally:(fun () -> h2b_remove_artifact ~sha:claimed_sha ~alias:"h2b-sm-sender")
        (fun () ->
          (* The artifact at the path-for claimed_sha actually has
             art.sha = real_sha, so the inner sha check fires. *)
          let art : Peer_review.t = {
            version = 1;
            reviewer = "h2b-sm-sender";
            reviewer_pk = "";
            sha = real_sha;
            verdict = "PASS";
            criteria_checked = [];
            skill_version = "1.0.0";
            commit_range = "0000000.." ^ real_sha;
            targets_built = { c2c = true; c2c_mcp_server = true; c2c_inbox_hook = false };
            notes = "sha-replay";
            signature = "";
            build_exit_code = None;
            ts = 1234567890.0;
          } in
          let signed = Peer_review.sign ~identity:id art in
          let json = Peer_review.t_to_string signed in
          let path = h2_artifact_path ~sha:claimed_sha ~alias:"h2b-sm-sender" in
          let oc = open_out path in
          output_string oc json;
          close_out oc;
          let content =
            Printf.sprintf "peer-PASS by h2b-sm-sender for SHA=%s" claimed_sha
          in
          let request =
            h2_send_request ~from_alias:"h2b-sm-sender"
              ~to_alias:"h2b-sm-recv" ~content
          in
          let response =
            Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
          in
          let is_error, _ = h2_response_is_error response in
          check bool "sha-mismatch DM rejected" true is_error;
          let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2b-sm-r" in
          check int "sha-mismatch peer-pass DM is NOT enqueued" 0 (List.length inbox)))

(* Claim_missing path: a peer-PASS DM whose artifact does not exist at
   the well-known path is informational, not a hard reject — the DM still
   flows. (The recipient sees the receipt note "peer_pass_verification:
   missing: ..." but the message is delivered.) *)
let test_peer_pass_dm_h2b_missing_artifact_allows_dm () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker ~session_id:"h2b-ms-s" ~alias:"h2b-ms-sender"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:"h2b-ms-r" ~alias:"h2b-ms-recv"
        ~pid:None ~pid_start_time:None ();
      let sha = h2_unique_sha () in
      (* No artifact written. *)
      let content =
        Printf.sprintf "peer-PASS by h2b-ms-sender for SHA=%s" sha
      in
      let request =
        h2_send_request ~from_alias:"h2b-ms-sender"
          ~to_alias:"h2b-ms-recv" ~content
      in
      let response =
        Lwt_main.run (C2c_mcp.handle_request ~broker_root:dir request)
      in
      let is_error, _ = h2_response_is_error response in
      check bool "missing-artifact DM is not rejected" false is_error;
      let inbox = C2c_mcp.Broker.read_inbox broker ~session_id:"h2b-ms-r" in
      check int "missing-artifact peer-pass DM is enqueued" 1 (List.length inbox))

(* ───────────────────── #432 §3 with_session helper ───────────────────── *)

let test_with_session_calls_f_with_resolved_session_id () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      C2c_mcp.Broker.register broker
        ~session_id:"with-session-test-a" ~alias:"alpha-bravo"
        ~pid:None ~pid_start_time:None ();
      (* No "session_id" arg — must fall back to override. *)
      let arguments = `Assoc [] in
      let observed = ref None in
      C2c_mcp.with_session
        ~session_id_override:(Some "with-session-test-a") broker arguments
        (fun ~session_id -> observed := Some session_id);
      check (option string) "f received the resolved session_id"
        (Some "with-session-test-a") !observed;
      (* Argument override beats the env-derived id (mirrors
         resolve_session_id's precedence: argument > override > env). *)
      let observed2 = ref None in
      let args_with_sid =
        `Assoc [ ("session_id", `String "with-session-test-a") ]
      in
      C2c_mcp.with_session
        ~session_id_override:(Some "ignored-because-arg-present") broker
        args_with_sid
        (fun ~session_id -> observed2 := Some session_id);
      check (option string) "argument session_id wins over override"
        (Some "with-session-test-a") !observed2)

let test_with_session_touches_session_before_calling_f () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let sid = "with-session-touch-a" in
      C2c_mcp.Broker.register broker ~session_id:sid ~alias:"touch-probe"
        ~pid:None ~pid_start_time:None ();
      let last_activity_of sid =
        C2c_mcp.Broker.list_registrations broker
        |> List.find_opt (fun (r : C2c_mcp.registration) ->
               r.session_id = sid)
        |> (function Some r -> r.last_activity_ts | None -> None)
      in
      (* Pre-call: register does not stamp last_activity_ts. *)
      check bool "last_activity_ts unset before with_session" true
        (last_activity_of sid = None);
      (* Inside f: touch must already have run, so last_activity_ts is
         a Some _. We assert this from inside f to nail down ordering. *)
      let inside = ref None in
      C2c_mcp.with_session ~session_id_override:(Some sid) broker
        (`Assoc []) (fun ~session_id ->
          inside := last_activity_of session_id);
      (match !inside with
       | None ->
           Alcotest.fail
             "touch_session must run BEFORE f — last_activity_ts was \
              still None inside f"
       | Some _ -> ());
      (* Post-call sanity. *)
      check bool "last_activity_ts is Some after with_session" true
        (last_activity_of sid <> None))

let test_with_session_forwards_override () =
  with_temp_dir (fun dir ->
      let broker = C2c_mcp.Broker.create ~root:dir in
      let sid_a = "with-session-fwd-a" in
      let sid_b = "with-session-fwd-b" in
      C2c_mcp.Broker.register broker ~session_id:sid_a ~alias:"alpha"
        ~pid:None ~pid_start_time:None ();
      C2c_mcp.Broker.register broker ~session_id:sid_b ~alias:"beta"
        ~pid:None ~pid_start_time:None ();
      (* No "session_id" argument; override picks the recipient. *)
      let observed = ref None in
      C2c_mcp.with_session ~session_id_override:(Some sid_b) broker
        (`Assoc []) (fun ~session_id -> observed := Some session_id);
      check (option string)
        "override sid_b is the resolved session_id when no arg"
        (Some sid_b) !observed;
      (* Override is honored even when the override session_id does not
         match the env-derived one. resolve_session_id's contract:
         argument > override > env; we verified arg-wins above; here we
         check override vs env by passing None as override and ensuring
         no env-derived id is consulted (would raise). The flow we care
         about: handle_tool_call passes its env-derived id as
         session_id_override, so a Some _ override always shadows the
         caller env in the wrapping helper. *)
      let raised =
        try
          C2c_mcp.with_session ~session_id_override:None broker
            (`Assoc []) (fun ~session_id:_ -> ());
          false
        with Invalid_argument _ -> true
      in
      (* In a unit-test process there is typically no
         CLAUDE_SESSION_ID/C2C_MCP_SESSION_ID set, so resolve_session_id
         falls through to invalid_arg. If the host env happens to set
         one we accept either outcome — the contract under test is "with
         override=Some _, override is forwarded", which is checked
         positively above. *)
      ignore raised)

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
        ; test_case "channel notification ts UTC HH:MM (#157)" `Quick
            test_channel_notification_ts_utc_hhmm
        ; test_case "initialize returns capabilities" `Quick test_initialize_returns_mcp_capabilities
        ; test_case "initialize experimental capability values are objects" `Quick
            test_initialize_experimental_capability_values_are_objects
         ; test_case "initialize reports server version and features" `Quick
             test_initialize_reports_server_version_and_features
         ; test_case "initialize reports server runtime identity" `Quick
             test_initialize_reports_server_runtime_identity
         ; test_case "tools/call server_info reports runtime identity" `Quick
             test_tools_call_server_info_reports_runtime_identity
         ; test_case "initialize reports supported protocol version" `Quick
             test_initialize_reports_supported_protocol_version
         ; test_case "tools/list exposes core tools" `Quick test_tools_list_includes_register_list_send_and_whoami
         ; test_case "tools/list includes debug when build flag enabled" `Quick
             test_tools_list_includes_debug_when_build_flag_enabled
          ; test_case "tools/list makes current-session args optional" `Quick
              test_tools_list_marks_register_and_whoami_session_id_as_optional
          ; test_case "tools/list schema types: send.deferrable+ephemeral bool, set_dnd.on bool, set_dnd.until_epoch number" `Quick
              test_send_and_set_dnd_schema_types_are_correct
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
          ; test_case "tools/call register rejects alias hijack via casefold asymmetry (#432 followup)" `Quick
              test_tools_call_register_rejects_alias_hijack_casefold_asymmetry
          ; test_case "M4: register rejects alias with pending permission from prior owner" `Quick
              test_register_rejects_alias_with_pending_permission_from_alive_owner
          ; test_case "[#432] open_pending_permission concurrent across forks: no lost-update" `Quick
              test_concurrent_open_pending_permission
          ; test_case "[#432 B1] open_pending_reply rejects unregistered caller" `Quick
              test_open_pending_reply_rejects_unregistered_caller
          ; test_case "[#432 B2] check_pending_reply derives reply_from_alias from calling session" `Quick
              test_check_pending_reply_derives_from_session_not_arg
          ; test_case "[#432 B2] check_pending_reply rejects unregistered caller" `Quick
              test_check_pending_reply_rejects_unregistered_caller
          ; test_case "[#432 C] open_pending_permission per-alias cap raises" `Quick
              test_open_pending_permission_per_alias_cap
          ; test_case "[#432 follow-up] pending_permission_exists_for_alias is case-insensitive" `Quick
              test_pending_permission_exists_for_alias_is_case_insensitive
          ; test_case "[#432 C] expired entries don't count toward cap" `Quick
              test_open_pending_permission_expired_dont_count
          ; test_case "[#432 C] open_pending_reply handler returns isError at cap" `Quick
              test_open_pending_reply_handler_returns_error_at_cap
          ; test_case "[#432 Slice E] relay-e2e x25519 pin persists across broker recreate" `Quick
              test_relay_pin_x25519_persists_across_broker_recreate
          ; test_case "[#432 Slice E] relay-e2e ed25519 pin persists across broker recreate" `Quick
              test_relay_pin_ed25519_persists_across_broker_recreate
          ; test_case "[#432 Slice E] relay-e2e concurrent pin_save across forks: no lost-update" `Quick
              test_relay_pin_concurrent_save_no_lost_update
          ; test_case "[#432 TOFU 5 observability] external delete of relay_pins.json clears in-memory" `Quick
              test_relay_pin_external_delete_clears_in_memory
          ; test_case "[#432 TOFU 5 observability] malformed relay_pins.json clears in-memory" `Quick
              test_relay_pin_malformed_json_clears_in_memory
          ; test_case "[CRIT-1 Slice B] TOFU first-contact pins claimed ed25519" `Quick
              test_slice_b_tofu_first_contact_pins
          ; test_case "[CRIT-1 Slice B] TOFU already-pinned same-key accepts, pin unchanged" `Quick
              test_slice_b_tofu_already_pinned_accepts
          ; test_case "[CRIT-1 Slice B] TOFU pinned/claimed mismatch rejects with key-changed" `Quick
              test_slice_b_tofu_mismatch_rejects
          ; test_case "[CRIT-1 Slice B followup] pin mismatch emits broker.log audit line" `Quick
              test_slice_b_followup_pin_mismatch_audit_log
          ; test_case "[CRIT-1 Slice B followup] first-contact pin emits broker.log audit line" `Quick
              test_relay_e2e_pin_first_seen_audit_log
          ; test_case "[CRIT-1 Slice B] TOFU legacy v1 (no from_ed25519) preserves existing path" `Quick
              test_slice_b_tofu_legacy_v1_no_field_accepts_no_tofu_update
          ; test_case "[CRIT-1 Slice B-min-version] v2 first-contact bumps min to 2" `Quick
              test_slice_bmv_first_contact_v2_sets_min_2
          ; test_case "[CRIT-1 Slice B-min-version] v1 after pinned min=2 rejected" `Quick
              test_slice_bmv_v1_rejected_after_v2_pin
          ; test_case "[CRIT-1 Slice B-min-version] v1→v2→v1 sequence: third v1 rejects" `Quick
              test_slice_bmv_v1_then_v2_then_v1_rejects
          ; test_case "[CRIT-1 Slice B-min-version] reject emits broker.log audit line" `Quick
              test_slice_bmv_audit_log_emitted_on_reject
          ; test_case "[CRIT-2] cross-host divergence full pin-flow (TOFU + key-swap + downgrade)" `Quick
              test_cross_host_divergence_full_pin_flow
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
         ; test_case "guard1 pidless zombie does not fire hijack (#345)" `Quick
             test_guard1_pidless_zombie_does_not_fire_hijack
         ; test_case "guard2 pidless zombie does not block post-OOM resume (#345)" `Quick
             test_guard2_pidless_zombie_does_not_block_post_oom_resume
         ; test_case "guard4 pidless zombie does not trigger same-pid alive (#345)" `Quick
             test_guard4_pidless_zombie_does_not_trigger_same_pid_alive
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
         ; test_case "register case-insensitive collision evicts lower (#378)" `Quick
             test_register_case_insensitive_collision_evicts_lower
         ; test_case "register stores original case (#378)" `Quick
             test_register_stores_original_case
         ; test_case "suggest_alias_prime case-insensitive with suffix (#378)" `Quick
             test_suggest_alias_prime_case_insensitive_with_suffix
          ; test_case "register migrates undrained inbox on alias re-register"
              `Quick test_register_migrates_undrained_inbox_on_alias_re_register
          ; test_case "#529 register logs event when session_id differs from alias"
              `Quick test_register_logs_event_when_session_id_differs_from_alias
          ; test_case "#529 register no log when session_id matches alias"
              `Quick test_register_no_log_when_session_id_matches_alias
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
         ; test_case "#344 sweep drops pidless legacy row" `Quick
             test_sweep_drops_pidless_legacy_row
         ; test_case "#344 sweep drops pidless old row" `Quick
             test_sweep_drops_pidless_old_row
         ; test_case "#344 sweep keeps pidless recent drained row" `Quick
             test_sweep_keeps_pidless_recent_drained_row
         ; test_case "#344 sweep keeps alive pid row" `Quick
             test_sweep_keeps_alive_pid_row
         ; test_case "sweep preserves non-empty orphan to dead-letter" `Quick
             test_sweep_preserves_nonempty_orphan_to_dead_letter
         ; test_case "sweep empty orphan writes no dead-letter" `Quick
             test_sweep_empty_orphan_writes_no_dead_letter
         ; test_case "#433 sweep dead-letter write emits broker.log event" `Quick
             test_sweep_dead_letter_write_emits_broker_log_event
         ; test_case "sweep preserves fresh provisional reg" `Quick
             test_sweep_preserves_fresh_provisional_reg
         ; test_case "sweep drops expired provisional reg" `Quick
             test_sweep_drops_expired_provisional_reg
          ; test_case "sweep emits peer_offline for confirmed dead reg" `Quick
              test_sweep_emits_peer_offline_for_confirmed_dead_reg
          ; test_case "sweep does not emit peer_offline for provisional expired" `Quick
              test_sweep_does_not_emit_peer_offline_for_provisional_expired_reg
          ; test_case "sweep peer_offline message format" `Quick
              test_sweep_peer_offline_message_format
          ; test_case "sweep dead alias excluded from self-notification" `Quick
              test_sweep_dead_alias_excluded_from_peer_offline_receipt
          ; test_case "sweep multiple confirmed dead regs each emit peer_offline" `Quick
              test_sweep_multiple_confirmed_dead_regs_each_emit_peer_offline
          ; test_case "confirm_registration sets confirmed_at" `Quick
              test_confirm_registration_sets_confirmed_at
          ; test_case "#344 confirmed pidless old reg swept" `Quick
              test_confirmed_pidless_old_reg_swept
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
          ; test_case "E2E S2: lazy-create Ed25519 key on first register" `Quick
              test_ed25519_lazy_create_on_first_register
          ; test_case "E2E S2: register rejects ed25519 mismatch" `Quick
              test_register_rejects_ed25519_mismatch
          ; test_case "E2E S2: register rejects x25519 mismatch" `Quick
              test_register_rejects_x25519_mismatch
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
         ; test_case "delete_room creator check is case-insensitive" `Quick
             test_delete_room_creator_check_case_insensitive
         ; test_case "delete_room legacy mixed-case created_by" `Quick
             test_delete_room_legacy_mixed_case_creator
         ; test_case "send_room appends history and fans out" `Quick
             test_send_room_appends_history_and_fans_out
         ; test_case "send_room skips sender inbox" `Quick
             test_send_room_skips_sender_inbox
         ; test_case "send_room deduplicates identical content within window" `Quick
             test_send_room_deduplicates_identical_content_within_window
          ; test_case "send_room does not dedup different content" `Quick
              test_send_room_does_not_dedup_different_content
          ; test_case "S1: send_room tag stores bare content, fans out prefixed (#392)" `Quick
              test_send_room_tag_stores_bare_content_fans_out_prefixed
          ; test_case "S2: send_room dedup ignores tag — same bare body = dup (#392)" `Quick
              test_send_room_dedup_on_bare_content_ignores_tag
          ; test_case "list_rooms returns rooms with members" `Quick
             test_list_rooms_returns_room_with_members
          ; test_case "room_history tag survives round-trip" `Quick
              test_room_history_tag_roundtrip
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
         ; test_case "tools/call delete_room rejects impersonation (#432)" `Quick
             test_delete_room_impersonation_rejected
         ; test_case "tools/call leave_room rejects impersonation (#432)" `Quick
             test_leave_room_impersonation_rejected
         ; test_case "tools/call stop_self cannot kill other instance (#432)" `Quick
             test_stop_self_cannot_kill_other
         ; test_case "send_room_invite adds to invite list" `Quick
             test_send_room_invite_adds_to_invite_list
         ; test_case "send_room_invite auto-DMs invitee (#433)" `Quick
             test_send_room_invite_auto_dms_invitee
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
         ; test_case "create public room with auto-join (#394)" `Quick
             test_create_public_room_with_auto_join
         ; test_case "create invite_only with invited members (#394)" `Quick
             test_create_invite_only_with_invited_members
         ; test_case "create with --no-join (#394)" `Quick
             test_create_no_join
         ; test_case "create existing room errors (#394)" `Quick
             test_create_existing_room_errors
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
           ; test_case "[#432 Slice D] open_pending_reply writes pending_open audit line" `Quick
                test_pending_open_audit_log_written
           ; test_case "[#432 Slice D] check_pending_reply unknown_perm outcome audit line" `Quick
                test_pending_check_audit_log_outcome
           ; test_case "[coord-backup-fallthrough] audit line written" `Quick
                test_coord_fallthrough_audit_line_written
           ; test_case "[coord-backup-fallthrough] broadcast-tier audit line shape" `Quick
                test_coord_fallthrough_audit_broadcast_tier
           ; test_case "[coord-backup-scheduler] T1: fires backup at idle threshold" `Quick
                test_coord_fallthrough_fires_at_idle_threshold
           ; test_case "[coord-backup-scheduler] T2: resolved_at skips fallthrough" `Quick
                test_coord_fallthrough_resolved_skips
           ; test_case "[coord-backup-scheduler] T3: skip-and-advance on offline backup" `Quick
                test_coord_fallthrough_skip_and_advance
           ; test_case "[coord-backup-scheduler] T4: chain exhausted broadcasts" `Quick
                test_coord_fallthrough_chain_exhausted_broadcasts
           ; test_case "[coord-backup-scheduler] T5: check_pending_reply writes resolved_at" `Quick
                test_check_pending_reply_writes_resolved_at
           ; test_case "[coord-backup-scheduler] T6: idempotent under double-tick" `Quick
                test_coord_fallthrough_no_double_fire
           ; test_case "[coord-backup-scheduler] T9: resolved blocks backup fire" `Quick
                test_coord_fallthrough_resolved_blocks_fire
           ; test_case "tools/call set_dnd on:\"true\" string enables DND" `Quick
                test_tools_call_set_dnd_on_string_true_enables_dnd
           ; test_case "tools/call set_dnd on:\"false\" string disables DND" `Quick
                test_tools_call_set_dnd_on_string_false_disables_dnd
           ; test_case "tools/call set_dnd on:1 int enables DND" `Quick
                test_tools_call_set_dnd_on_int_one_enables_dnd
           ; test_case "tools/call set_dnd on:0 int disables DND" `Quick
                test_tools_call_set_dnd_on_int_zero_disables_dnd
           ; test_case "tools/call set_dnd on invalid input defaults false" `Quick
                test_tools_call_set_dnd_on_invalid_input_defaults_false
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
           ; test_case "#432 resolve alias is case-insensitive" `Quick
               test_resolve_alias_case_insensitive
           ; test_case "#432 stale dead row not resurrected by case-fold lookup" `Quick
               test_resolve_alias_no_match_when_session_dead
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
           ; test_case "notify_shared_with logs each attempt to broker.log (#327)" `Quick
               test_notify_logs_each_attempt_to_broker_log
           ; test_case "notify_shared_with logs failures with error field (#327)" `Quick
               test_notify_logs_failure_with_error_field
           ; test_case "notify_shared_with appears in drain_inbox_push (#307b)" `Quick
               test_notify_shared_with_appears_in_push_drain
           ; test_case "delivery_mode_histogram counts and by-sender (#307a)" `Quick
               test_delivery_mode_histogram_counts_and_by_sender
           ; test_case "delivery_mode_histogram --last-N filter (#307a)" `Quick
               test_delivery_mode_histogram_last_n_filter
           ; test_case "delivery_mode_histogram empty archive (#307a)" `Quick
               test_delivery_mode_histogram_empty_archive_is_zero
           ; test_case "H1 room_history invite-only blocks non-member" `Quick
               test_room_history_invite_only_blocks_non_member
           ; test_case "H1 room_history invite-only allows member" `Quick
               test_room_history_invite_only_allows_member
           ; test_case "H1 room_history public allows anyone" `Quick
               test_room_history_public_allows_anyone
           ; test_case "H2 list_rooms filters invite-only for non-members" `Quick
               test_list_rooms_filters_invite_only_for_non_members
           ; test_case "H2 list_rooms redacts members for invited-pre-join" `Quick
               test_list_rooms_redacts_invited_pre_join
           ; test_case "H3 delete_room requires creator" `Quick
               test_delete_room_requires_creator
           ; test_case "H3 delete_room creator succeeds" `Quick
               test_delete_room_creator_succeeds
           ; test_case "H3 delete_room legacy requires force" `Quick
               test_delete_room_legacy_requires_force
           ; test_case "drained_by recorded on poll_inbox (#387 B)" `Quick
               test_drained_by_recorded_on_poll_inbox
           ; test_case "drained_by recorded on watcher (#387 B)" `Quick
               test_drained_by_recorded_on_watcher
           ; test_case "drained_by default for legacy entries (#387 B)" `Quick
               test_drained_by_default_for_legacy_entries
           ; test_case "drained_by persisted as top-level field (#387 B)" `Quick
               test_drained_by_persisted_as_top_level_field
           ; test_case "hook skips drain for channel-capable session (#387 A2)" `Quick
               test_hook_skips_drain_for_channel_capable
           ; test_case "hook drains for non-channel-capable session (#387 A2)" `Quick
               test_hook_drains_for_non_channel_capable
           ; test_case "H2: peer-pass DM with invalid signature is rejected" `Quick
               test_peer_pass_dm_with_invalid_signature_rejected
           ; test_case "H2: peer-pass DM with valid signature is accepted" `Quick
               test_peer_pass_dm_with_valid_signature_accepted
           ; test_case "H2b: fresh-key forgery after legit pin is rejected" `Quick
               test_peer_pass_dm_h2b_fresh_key_forgery_rejected
           ; test_case "H2b: rotated-key DM (no rotate-pin op) is rejected" `Quick
               test_peer_pass_dm_h2b_rotated_key_rejected
           ; test_case "H2b: first-seen pin allows the DM" `Quick
               test_peer_pass_dm_h2b_first_seen_allowed
            ; test_case "H2b: artifact sha != claim sha is rejected" `Quick
                test_peer_pass_dm_h2b_sha_mismatch_rejected
            ; test_case "H2b: missing artifact still allows the DM" `Quick
                test_peer_pass_dm_h2b_missing_artifact_allows_dm
            ; test_case "#432 §3 with_session calls f with resolved session_id" `Quick
                test_with_session_calls_f_with_resolved_session_id
            ; test_case "#432 §3 with_session touches session before calling f" `Quick
                test_with_session_touches_session_before_calling_f
            ; test_case "#432 §3 with_session forwards session_id_override" `Quick
                test_with_session_forwards_override
            ; test_case "message_id assigned on local enqueue (#S2 Fix #1)" `Quick
                test_message_id_assigned_on_local_enqueue
            ; test_case "reaction DM archived with target_msg_id for discovery (#S2 Fix #3)" `Quick
                test_reaction_archived_with_target_msg_id
            ] ) ]
