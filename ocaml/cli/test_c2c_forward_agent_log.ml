(* test_c2c_forward_agent_log.ml — B193 `c2c forward-agent-log`.

   Covers:
   1. classify_claude_line — keep user text + assistant text; drop thinking,
      tool_use, tool_result, meta/sidechain/system/summary lines, hook and
      c2c-envelope injections, malformed JSON.
   2. split_complete_lines / tail_read — only newline-complete lines are
      consumed; partial trailing writes stay pending; file truncation resets.
   3. format_forward_body — [user]/[agent] labels + UTF-8-safe truncation.
   4. run ~once against the committed fixture transcript
      (test_fixtures/forward_agent_log_claude.jsonl) with a capturing send.
   5. deliver_via_broker against a REAL temp broker (message lands in the
      recipient inbox via the normal send path).
   6. Binary e2e: `c2c forward-agent-log --once` with the repo-standard
      C2C_SEND_MESSAGE_FIXTURE=1 send gate — prints would-send lines, sends
      nothing. *)

open Alcotest
module F = C2c_forward_agent_log
module Broker = C2c_mcp.Broker

let ( // ) = Filename.concat

let fixture_path = "test_fixtures" // "forward_agent_log_claude.jsonl"

(* c2c.exe lives next to this test executable under _build. *)
let c2c_binary = Filename.dirname Sys.executable_name // "c2c.exe"

(* --- helpers -------------------------------------------------------------- *)

let mkdtemp () =
  let base = Filename.get_temp_dir_name () in
  let rec attempt n =
    if n > 50 then failwith "mkdtemp: too many attempts"
    else
      let cand =
        base
        // Printf.sprintf "c2c_fwd_log_test_%d_%d" (Unix.getpid ())
             (Random.int 1_000_000)
      in
      match Unix.mkdir cand 0o700 with
      | () -> cand
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (n + 1)
  in
  attempt 0

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (path // e)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> ( try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

let with_temp_dir f =
  let dir = mkdtemp () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let append_file path s =
  let oc = open_out_gen [ Open_append; Open_creat; Open_binary ] 0o600 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc s)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let event = testable
    (Fmt.of_to_string (fun (role, text) ->
         Printf.sprintf "(%s, %S)" (F.role_label role) text))
    ( = )

let classify = F.classify_claude_line

(* --- 1. classify_claude_line --------------------------------------------- *)

let test_classify_user_plain () =
  check (option event) "plain user string kept"
    (Some (F.User, "fix the bug"))
    (classify
       {|{"type":"user","message":{"role":"user","content":"fix the bug"}}|})

let test_classify_user_text_blocks () =
  check (option event) "user text blocks kept + joined"
    (Some (F.User, "part one\n\npart two"))
    (classify
       {|{"type":"user","message":{"role":"user","content":[{"type":"text","text":"part one"},{"type":"text","text":"part two"}]}}|})

let test_classify_user_tool_result () =
  check (option event) "tool_result content dropped" None
    (classify
       {|{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"out"}]}}|});
  check (option event) "toolUseResult key dropped even with text content" None
    (classify
       {|{"type":"user","toolUseResult":{"stdout":"x"},"message":{"role":"user","content":"echoed"}}|})

let test_classify_user_noise_prefixes () =
  List.iter
    (fun body ->
      check (option event) ("noise dropped: " ^ String.sub body 0 12) None
        (classify
           (Printf.sprintf
              {|{"type":"user","message":{"role":"user","content":%s}}|}
              (Yojson.Safe.to_string (`String body)))))
    [ "<system-reminder>hook noise</system-reminder>"
    ; "<local-command-stdout>ls</local-command-stdout>"
    ; "<local-command-stderr>err</local-command-stderr>"
    ; "<c2c event=\"message\" from=\"a\" to=\"b\">mail</c2c>"
    ; "[Request interrupted by user]"
    ]

let test_classify_user_mixed_noise_blocks () =
  (* A user turn mixing an injected system-reminder block with typed text
     keeps the typed text and drops only the noise block. *)
  check (option event) "noise block dropped, typed text kept"
    (Some (F.User, "real question"))
    (classify
       {|{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"},{"type":"text","text":"real question"}]}}|});
  check (option event) "all-noise blocks -> dropped entirely" None
    (classify
       {|{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>"}]}}|})

let test_classify_user_command_wrapper_kept () =
  (* A slash command IS user input — kept verbatim. *)
  let body = "<command-message>go</command-message>\n<command-name>/go</command-name>" in
  check (option event) "slash-command wrapper kept" (Some (F.User, body))
    (classify
       (Printf.sprintf
          {|{"type":"user","message":{"role":"user","content":%s}}|}
          (Yojson.Safe.to_string (`String body))))

let test_classify_assistant () =
  check (option event) "assistant text kept"
    (Some (F.Agent, "done, tests pass"))
    (classify
       {|{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done, tests pass"}]}}|});
  check (option event) "thinking dropped" None
    (classify
       {|{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private"}]}}|});
  check (option event) "tool_use dropped" None
    (classify
       {|{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}|});
  check (option event) "mixed array keeps only text"
    (Some (F.Agent, "running tests"))
    (classify
       {|{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running tests"},{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}|});
  check (option event) "empty text dropped" None
    (classify
       {|{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"  "}]}}|})

let test_classify_meta_and_other_types () =
  check (option event) "isMeta dropped" None
    (classify
       {|{"type":"user","isMeta":true,"message":{"role":"user","content":"caveat"}}|});
  check (option event) "isSidechain dropped" None
    (classify
       {|{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}|});
  List.iter
    (fun l -> check (option event) ("non-conversation type dropped: " ^ l) None (classify l))
    [ {|{"type":"system","subtype":"stop"}|}
    ; {|{"type":"summary","summary":"s"}|}
    ; {|{"type":"attachment","attachment":{}}|}
    ; {|{"type":"file-history-snapshot"}|}
    ]

let test_classify_malformed () =
  List.iter
    (fun l -> check (option event) ("malformed skipped: " ^ l) None (classify l))
    [ ""; "   "; "not json"; {|{"type":"user","message":{|}; "[1,2,3]"; "42" ]

(* --- 2. line consumption / tailing ---------------------------------------- *)

let test_split_complete_lines () =
  check (pair (list string) string) "no newline -> all pending"
    ([], "partial") (F.split_complete_lines "partial");
  check (pair (list string) string) "complete + partial"
    ([ "a"; "b" ], "cde") (F.split_complete_lines "a\nb\ncde");
  check (pair (list string) string) "trailing newline -> empty pending"
    ([ "a" ], "") (F.split_complete_lines "a\n");
  check (pair (list string) string) "empty input" ([], "")
    (F.split_complete_lines "")

let test_tail_read_incremental () =
  with_temp_dir (fun dir ->
      let path = dir // "session.jsonl" in
      append_file path "";
      let st = F.initial_tail_state ~from_start:true path in
      (* partial write: nothing consumable *)
      append_file path {|{"type":"user"|};
      let lines, st = F.tail_read ~path st in
      check (list string) "partial write yields no lines" [] lines;
      (* completing the line makes exactly one line available *)
      append_file path ",\"message\":{\"content\":\"hi\"}}\n";
      let lines, st = F.tail_read ~path st in
      check (list string) "completed line consumed"
        [ {|{"type":"user","message":{"content":"hi"}}|} ]
        lines;
      (* nothing new -> nothing read *)
      let lines, st = F.tail_read ~path st in
      check (list string) "steady state" [] lines;
      (* two appends between polls arrive together, in order *)
      append_file path "l1\nl2\n";
      let lines, st = F.tail_read ~path st in
      check (list string) "batched appends in order" [ "l1"; "l2" ] lines;
      ignore st)

let test_tail_read_truncation_reset () =
  with_temp_dir (fun dir ->
      let path = dir // "session.jsonl" in
      append_file path "old1\nold2\npartial-old";
      let st = F.initial_tail_state ~from_start:true path in
      let lines, st = F.tail_read ~path st in
      check (list string) "reads existing complete lines" [ "old1"; "old2" ]
        lines;
      (* rotate: replace with a shorter file; stale pending must be dropped *)
      let oc = open_out_bin path in
      output_string oc "new1\n";
      close_out oc;
      let lines, _st = F.tail_read ~path st in
      check (list string) "shrunk file resets to start, drops stale partial"
        [ "new1" ] lines)

let test_tail_read_missing_file () =
  let st = F.initial_tail_state "/nonexistent/nope.jsonl" in
  let lines, st' = F.tail_read ~path:"/nonexistent/nope.jsonl" st in
  check (list string) "missing file yields nothing" [] lines;
  check bool "state unchanged" true (st = st')

(* --- 3. formatting --------------------------------------------------------- *)

let test_format_labels () =
  check string "user label" "[user] hello"
    (F.format_forward_body ~role:F.User ~max_bytes:100 "hello");
  check string "agent label" "[agent] hi"
    (F.format_forward_body ~role:F.Agent ~max_bytes:100 "hi")

let test_format_truncation () =
  let long = String.make 50 'x' in
  let out = F.format_forward_body ~role:F.Agent ~max_bytes:10 long in
  check string "truncated with note"
    "[agent] xxxxxxxxxx… [truncated: 10 of 50 bytes shown]" out;
  (* UTF-8 boundary: é is 2 bytes; a cut landing mid-sequence backs off *)
  let s = "aé" ^ String.make 20 'z' in
  let out = F.format_forward_body ~role:F.User ~max_bytes:2 s in
  check string "utf8-safe cut backs off continuation byte"
    (Printf.sprintf "[user] a… [truncated: 1 of %d bytes shown]"
       (String.length s))
    out

(* --- 4. fixture transcript end-to-end (capturing send) --------------------- *)

let expected_fixture_bodies =
  [ "[user] please fix the login bug"
  ; "[agent] I found the bug in auth.ml — the token check was inverted."
  ; "[user] thanks, also add a test please"
  ; "[agent] Running the tests now."
  ; "[user] <command-message>pirfl</command-message>\n<command-name>/pirfl</command-name>"
  ]

let test_run_once_fixture () =
  let sent = ref [] in
  let send body = sent := body :: !sent; Ok () in
  let stats =
    F.run ~path:fixture_path ~classify:F.classify_claude_line ~max_bytes:2000
      ~interval:0.01 ~from_start:true ~once:true ~send
  in
  check (list string) "fixture forwards exactly the conversation, in order"
    expected_fixture_bodies (List.rev !sent);
  check int "forwarded count" (List.length expected_fixture_bodies)
    stats.F.forwarded;
  check int "no send failures" 0 stats.F.send_failures;
  (* the fixture's trailing partial line must never be forwarded *)
  check bool "partial trailing line not consumed" false
    (List.exists
       (fun b ->
         try ignore (Str.search_forward (Str.regexp_string "PARTIAL") b 0); true
         with Not_found -> false)
       !sent)

let test_run_once_counts_send_failures () =
  let send _ = Error "broker says no" in
  let stats =
    F.run ~path:fixture_path ~classify:F.classify_claude_line ~max_bytes:2000
      ~interval:0.01 ~from_start:true ~once:true ~send
  in
  check int "all sends failed" (List.length expected_fixture_bodies)
    stats.F.send_failures;
  check int "none forwarded" 0 stats.F.forwarded

(* --- 5. real-broker delivery ----------------------------------------------- *)

let test_deliver_via_broker_lands_in_inbox () =
  with_temp_dir (fun root ->
      let broker = Broker.create ~root in
      let self_pid = Unix.getpid () in
      let sid = "zztfwd-observer-sid" in
      Broker.register broker ~session_id:sid ~alias:"zztfwd-observer"
        ~pid:(Some self_pid)
        ~pid_start_time:(Broker.capture_pid_start_time (Some self_pid))
        ();
      let body =
        F.format_forward_body ~role:F.User ~max_bytes:2000 "hello observer"
      in
      (match
         F.deliver_via_broker ~broker ~from_alias:"zztfwd-sender"
           ~to_alias:"zztfwd-observer" body
       with
      | Ok () -> ()
      | Error e -> fail ("deliver_via_broker failed: " ^ e));
      let inbox = Broker.read_inbox broker ~session_id:sid in
      check int "one message delivered" 1 (List.length inbox);
      let msg = List.hd inbox in
      check string "labeled body delivered verbatim" "[user] hello observer"
        msg.C2c_mcp.content;
      check string "sender alias" "zztfwd-sender" msg.C2c_mcp.from_alias)

let test_deliver_via_broker_unknown_alias_errors () =
  with_temp_dir (fun root ->
      let broker = Broker.create ~root in
      match
        F.deliver_via_broker ~broker ~from_alias:"zztfwd-sender"
          ~to_alias:"zztfwd-nobody" "[user] hi"
      with
      | Ok () -> fail "expected Error for unknown local alias"
      | Error _ -> ())

(* --- 6. binary e2e (fixture-gated send) ------------------------------------ *)

let test_binary_once_fixture_gated () =
  with_temp_dir (fun dir ->
      let out = dir // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary)
          (Filename.quote fixture_path)
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      let content = read_file out in
      check int (Printf.sprintf "exit 0 (output: %s)" content) 0 rc;
      List.iter
        (fun body ->
          (* would-send lines are one-per-message; multi-line bodies keep
             their newlines, so match on the first line of each body. *)
          let first_line =
            match String.index_opt body '\n' with
            | Some i -> String.sub body 0 i
            | None -> body
          in
          let needle =
            "[c2c-forward-agent-log] would send -> zztfwd-target: "
            ^ first_line
          in
          check bool ("output contains: " ^ first_line) true
            (try
               ignore
                 (Str.search_forward (Str.regexp_string needle) content 0);
               true
             with Not_found -> false))
        expected_fixture_bodies;
      check bool "summary line reports 5 forwarded" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "forwarded 5 message(s), 0 failure(s)")
                content 0);
           true
         with Not_found -> false);
      check bool "partial trailing line not forwarded" false
        (try
           ignore (Str.search_forward (Str.regexp_string "PARTIAL") content 0);
           true
         with Not_found -> false))

let test_binary_rejects_unknown_format () =
  with_temp_dir (fun dir ->
      let out = dir // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --format codex --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary)
          (Filename.quote fixture_path)
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      check bool "unsupported format exits non-zero" true (rc <> 0);
      let content = read_file out in
      check bool "mentions unsupported format" true
        (try
           ignore
             (Str.search_forward
                (Str.regexp_string "unsupported transcript format") content 0);
           true
         with Not_found -> false))

let test_binary_missing_file_errors () =
  with_temp_dir (fun dir ->
      let out = dir // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary)
          (Filename.quote (dir // "does-not-exist.jsonl"))
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      check bool "missing file exits non-zero" true (rc <> 0);
      let content = read_file out in
      check bool "mentions file not found" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "not found") content 0);
           true
         with Not_found -> false))

(* --------------------------------------------------------------------------- *)

let () =
  Random.self_init ();
  run "c2c_forward_agent_log"
    [ ( "classify"
      , [ test_case "user plain string" `Quick test_classify_user_plain
        ; test_case "user text blocks" `Quick test_classify_user_text_blocks
        ; test_case "user tool_result" `Quick test_classify_user_tool_result
        ; test_case "user noise prefixes" `Quick
            test_classify_user_noise_prefixes
        ; test_case "user mixed noise blocks" `Quick
            test_classify_user_mixed_noise_blocks
        ; test_case "user slash-command kept" `Quick
            test_classify_user_command_wrapper_kept
        ; test_case "assistant blocks" `Quick test_classify_assistant
        ; test_case "meta/sidechain/other types" `Quick
            test_classify_meta_and_other_types
        ; test_case "malformed lines" `Quick test_classify_malformed
        ] )
    ; ( "tail"
      , [ test_case "split_complete_lines" `Quick test_split_complete_lines
        ; test_case "incremental reads" `Quick test_tail_read_incremental
        ; test_case "truncation reset" `Quick test_tail_read_truncation_reset
        ; test_case "missing file" `Quick test_tail_read_missing_file
        ] )
    ; ( "format"
      , [ test_case "labels" `Quick test_format_labels
        ; test_case "truncation" `Quick test_format_truncation
        ] )
    ; ( "run-once"
      , [ test_case "fixture transcript" `Quick test_run_once_fixture
        ; test_case "send failures counted" `Quick
            test_run_once_counts_send_failures
        ] )
    ; ( "broker"
      , [ test_case "delivers to inbox" `Quick
            test_deliver_via_broker_lands_in_inbox
        ; test_case "unknown alias errors" `Quick
            test_deliver_via_broker_unknown_alias_errors
        ] )
    ; ( "binary"
      , [ test_case "once + fixture gate" `Quick
            test_binary_once_fixture_gated
        ; test_case "unknown format rejected" `Quick
            test_binary_rejects_unknown_format
        ; test_case "missing file rejected" `Quick
            test_binary_missing_file_errors
        ] )
    ]
