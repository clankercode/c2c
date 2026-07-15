(* test_c2c_forward_agent_log.ml — B193/B194 `c2c forward-agent-log`.

   Covers:
   1. classify_claude_line — keep user text + assistant text; drop thinking,
      tool_use, tool_result, meta/sidechain/system/summary lines, hook and
      c2c-envelope injections, malformed JSON.
   1b. per-client classifiers (B194): codex event_msg stream, kimi context
      roles, grok <user_query> extraction + synthetic turns, agy message /
      $set journal lines.
   1c. detect_format — path heuristics over the standard session stores and
      first-lines content sniffing.
   1d. opencode directory source — user forwards on appearance, assistant
      waits for time.completed, synthetic/tool/reasoning parts dropped,
      attach-time history not replayed.
   2. split_complete_lines / tail_read — only newline-complete lines are
      consumed; partial trailing writes stay pending; file truncation resets.
   3. format_forward_body — [user]/[agent] labels + UTF-8-safe truncation.
   4. run ~once against the committed fixture transcript
      (test_fixtures/forward_agent_log_claude.jsonl) with a capturing send.
   5. deliver_via_broker against a REAL temp broker (message lands in the
      recipient inbox via the normal send path).
   6. Binary e2e: `c2c forward-agent-log --once` with the repo-standard
      C2C_SEND_MESSAGE_FIXTURE=1 send gate — prints would-send lines, sends
      nothing; --format auto sniffing (codex), opencode dir source, and
      directory/format mismatch rejection. *)

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

(* --- 1b. per-client classifiers (B194) ------------------------------------ *)

let test_classify_codex () =
  let c = F.classify_codex_line in
  check (option event) "user_message kept" (Some (F.User, "do the thing"))
    (c
       {|{"timestamp":"2026-07-15T00:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"do the thing"}}|});
  check (option event) "agent_message kept" (Some (F.Agent, "done"))
    (c
       {|{"timestamp":"2026-07-15T00:00:01Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}|});
  List.iter
    (fun (name, l) -> check (option event) ("noise dropped: " ^ name) None (c l))
    [ ( "token_count"
      , {|{"type":"event_msg","payload":{"type":"token_count","info":{}}}|} )
    ; ( "task_started"
      , {|{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}|} )
    ; ( "session_meta"
      , {|{"type":"session_meta","payload":{"id":"s"}}|} )
    ; ( "response_item user mirror"
      , {|{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"mirrored"}]}}|} )
    ; ( "injected user_instructions"
      , {|{"type":"event_msg","payload":{"type":"user_message","message":"<user_instructions>be nice</user_instructions>"}}|} )
    ; ( "injected environment_context"
      , {|{"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>linux</environment_context>"}}|} )
    ; ("empty message", {|{"type":"event_msg","payload":{"type":"agent_message","message":"  "}}|})
    ; ("malformed", "{nope")
    ]

let test_classify_kimi () =
  let c = F.classify_kimi_line in
  check (option event) "user string kept" (Some (F.User, "fix it"))
    (c {|{"role":"user","content":"fix it"}|});
  check (option event) "assistant string kept" (Some (F.Agent, "done"))
    (c {|{"role":"assistant","content":"done","tool_calls":[]}|});
  check (option event) "assistant text block kept" (Some (F.Agent, "hello"))
    (c
       {|{"role":"assistant","content":[{"type":"think","think":"private"},{"type":"text","text":"hello"}]}|});
  List.iter
    (fun (name, l) -> check (option event) ("noise dropped: " ^ name) None (c l))
    [ ( "think-only assistant"
      , {|{"role":"assistant","content":[{"type":"think","think":"private"}]}|} )
    ; ("tool result", {|{"role":"tool","content":"out","tool_call_id":"1"}|})
    ; ("_system_prompt", {|{"role":"_system_prompt","content":"You are Kimi"}|})
    ; ("_checkpoint", {|{"role":"_checkpoint","id":"c1"}|})
    ; ("_usage", {|{"role":"_usage","token_count":12}|})
    ; ( "injected system-reminder"
      , {|{"role":"user","content":"<system-reminder>hook</system-reminder>"}|} )
    ; ("malformed", "]")
    ]

let test_classify_grok () =
  let c = F.classify_grok_line in
  check (option event) "user_query inner text extracted"
    (Some (F.User, "fix the bug"))
    (c
       {|{"type":"user","content":[{"type":"text","text":"<user_query>\nfix the bug\n</user_query>"}],"prompt_index":0}|});
  check (option event) "assistant text kept" (Some (F.Agent, "on it"))
    (c
       {|{"type":"assistant","content":"on it","tool_calls":[],"model_id":"grok-4.5"}|});
  List.iter
    (fun (name, l) -> check (option event) ("noise dropped: " ^ name) None (c l))
    [ ( "synthetic user turn"
      , {|{"type":"user","content":[{"type":"text","text":"<user_query>continue</user_query>"}],"synthetic_reason":"auto"}|} )
    ; ( "user line without user_query (injected reminder)"
      , {|{"type":"user","content":[{"type":"text","text":"<system-reminder>skills</system-reminder>"}]}|} )
    ; ( "assistant tool-only empty content"
      , {|{"type":"assistant","content":"","tool_calls":[{"id":"x"}]}|} )
    ; ("system prompt", {|{"type":"system","content":"You are Grok"}|})
    ; ("tool_result", {|{"type":"tool_result","content":"out","tool_call_id":"x"}|})
    ; ("reasoning", {|{"type":"reasoning","id":"r","summary":null}|})
    ; ("malformed", "not json")
    ]

let test_classify_agy () =
  let c = F.classify_agy_line in
  check (option event) "user part kept" (Some (F.User, "review this"))
    (c
       {|{"id":"1","timestamp":"2026-07-15T00:00:00Z","type":"user","content":[{"text":"review this"}]}|});
  check (option event) "gemini text kept" (Some (F.Agent, "CLEAR-TO-MERGE"))
    (c
       {|{"id":"2","timestamp":"2026-07-15T00:00:01Z","type":"gemini","content":"CLEAR-TO-MERGE","thoughts":[{"subject":"s","description":"d"}]}|});
  List.iter
    (fun (name, l) -> check (option event) ("noise dropped: " ^ name) None (c l))
    [ ( "session header"
      , {|{"sessionId":"s","projectHash":"p","startTime":"t","kind":"main"}|} )
    ; ("$set journal op", {|{"$set":{"lastUpdated":"t"}}|})
    ; ( "injected session_context"
      , {|{"id":"0","type":"user","content":[{"text":"<session_context>\nThis is the Gemini CLI.\n</session_context>"}]}|} )
    ; ( "thoughts-only gemini turn"
      , {|{"id":"3","type":"gemini","content":"","thoughts":[{"subject":"s"}]}|} )
    ; ("malformed", "{") ]

(* --- 1c. format auto-detection --------------------------------------------- *)

let test_detect_format_by_path () =
  let d p = F.detect_format ~is_dir:false ~head:[] p in
  check (option string) "codex store"
    (Some "codex")
    (d "/home/u/.codex/sessions/2026/07/15/rollout-2026-07-15T01-38-13-x.jsonl");
  check (option string) "rollout basename anywhere" (Some "codex")
    (d "/tmp/copies/rollout-foo.jsonl");
  check (option string) "grok chat_history" (Some "grok")
    (d "/home/u/.grok/sessions/%2Fhome/019f-uuid/chat_history.jsonl");
  check (option string) "kimi context" (Some "kimi")
    (d "/home/u/.kimi/sessions/hash/uuid/context.jsonl");
  check (option string) "agy chats" (Some "agy")
    (d "/home/u/.gemini/tmp/proj/chats/session-2026-05-30T16-08-x.jsonl");
  check (option string) "claude projects" (Some "claude")
    (d "/home/u/.claude/projects/-home-u-src-p/sid.jsonl");
  check (option string) "claude-w variant" (Some "claude")
    (d "/home/u/.claude-w/projects/-home-u-src-p/sid.jsonl");
  check (option string) "opencode storage path" (Some "opencode")
    (d "/home/u/.local/share/opencode/storage/message/ses_x");
  check (option string) "directory -> opencode" (Some "opencode")
    (F.detect_format ~is_dir:true ~head:[] "/anywhere/at/all");
  check (option string) "unknown path, no sniff" None (d "/tmp/whatever.jsonl")

let test_detect_format_by_sniff () =
  let d line =
    F.detect_format ~is_dir:false ~head:[ line ] "/tmp/x.jsonl"
  in
  check (option string) "codex session_meta" (Some "codex")
    (d {|{"timestamp":"t","type":"session_meta","payload":{"id":"s"}}|});
  check (option string) "agy header" (Some "agy")
    (d {|{"sessionId":"s","projectHash":"p","startTime":"t"}|});
  check (option string) "kimi role line" (Some "kimi")
    (d {|{"role":"_system_prompt","content":"You are Kimi"}|});
  check (option string) "claude line" (Some "claude")
    (d {|{"type":"summary","summary":"s","message":null,"leafUuid":"x"}|});
  check (option string) "claude user line" (Some "claude")
    (d {|{"type":"user","message":{"role":"user","content":"hi"}}|});
  check (option string) "grok system line" (Some "grok")
    (d {|{"type":"system","content":"You are Grok"}|});
  check (option string) "garbage" None (d "not json")

(* --- 1d. opencode directory source ----------------------------------------- *)

(* Build a minimal opencode storage tree:
   <root>/storage/message/<sid>/msg_*.json + <root>/storage/part/<msgid>/... *)
let write_file path s =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc s)

let mk_opencode_session root =
  let storage = root // "storage" in
  let msg_dir = storage // "message" // "ses_test" in
  let part_root = storage // "part" in
  List.iter
    (fun d -> ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d))))
    [ msg_dir; part_root ];
  (msg_dir, part_root)

let add_opencode_message ~msg_dir ~part_root ~id ~role ~completed parts =
  let time = if completed then {|{"created":1,"completed":2}|} else {|{"created":1}|} in
  write_file (msg_dir // (id ^ ".json"))
    (Printf.sprintf {|{"id":"%s","sessionID":"ses_test","role":"%s","time":%s}|}
       id role time);
  let pdir = part_root // id in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote pdir)));
  List.iteri
    (fun i part -> write_file (pdir // Printf.sprintf "prt_%02d.json" i) part)
    parts

let test_opencode_once_forwards_conversation () =
  with_temp_dir (fun root ->
      let msg_dir, part_root = mk_opencode_session root in
      add_opencode_message ~msg_dir ~part_root ~id:"msg_01" ~role:"user"
        ~completed:false
        [ {|{"id":"p1","type":"text","text":"build the app"}|} ];
      add_opencode_message ~msg_dir ~part_root ~id:"msg_02" ~role:"assistant"
        ~completed:true
        [ {|{"id":"p2","type":"step-start"}|}
        ; {|{"id":"p3","type":"reasoning","text":"let me think"}|}
        ; {|{"id":"p4","type":"text","text":"starting now"}|}
        ; {|{"id":"p5","type":"tool","tool":"bash","state":{}}|}
        ];
      (* synthetic text part on a user message is injected context: NOISE *)
      add_opencode_message ~msg_dir ~part_root ~id:"msg_03" ~role:"user"
        ~completed:false
        [ {|{"id":"p6","type":"text","synthetic":true,"text":"injected context"}|} ];
      let sent = ref [] in
      let send b = sent := b :: !sent; Ok () in
      let stats =
        F.run_opencode ~message_dir:msg_dir ~max_bytes:2000 ~interval:0.01
          ~from_start:false ~once:true ~send
      in
      check (list string) "user + completed assistant forwarded, noise dropped"
        [ "[user] build the app"; "[agent] starting now" ]
        (List.rev !sent);
      check int "forwarded count" 2 stats.F.forwarded)

let test_opencode_assistant_waits_for_completion () =
  with_temp_dir (fun root ->
      let msg_dir, part_root = mk_opencode_session root in
      add_opencode_message ~msg_dir ~part_root ~id:"msg_01" ~role:"assistant"
        ~completed:false
        [ {|{"id":"p1","type":"text","text":"half a sent"}|} ];
      let sent = ref [] in
      let send b = sent := b :: !sent; Ok () in
      let st = F.opencode_initial_state ~from_start:true msg_dir in
      let stats = { F.forwarded = 0; send_failures = 0 } in
      let stats =
        F.opencode_step ~message_dir:msg_dir ~max_bytes:2000 ~send st stats
      in
      check (list string) "in-flight assistant not forwarded" [] !sent;
      (* the turn completes (message file rewritten with time.completed,
         part text grown) -> forwarded exactly once *)
      add_opencode_message ~msg_dir ~part_root ~id:"msg_01" ~role:"assistant"
        ~completed:true
        [ {|{"id":"p1","type":"text","text":"half a sentence, now whole"}|} ];
      let stats =
        F.opencode_step ~message_dir:msg_dir ~max_bytes:2000 ~send st stats
      in
      let stats =
        F.opencode_step ~message_dir:msg_dir ~max_bytes:2000 ~send st stats
      in
      check (list string) "forwarded once after completion"
        [ "[agent] half a sentence, now whole" ]
        (List.rev !sent);
      check int "forwarded count" 1 stats.F.forwarded)

let test_opencode_attach_skips_existing () =
  with_temp_dir (fun root ->
      let msg_dir, part_root = mk_opencode_session root in
      add_opencode_message ~msg_dir ~part_root ~id:"msg_01" ~role:"user"
        ~completed:false
        [ {|{"id":"p1","type":"text","text":"old history"}|} ];
      (* default attach = everything present is consumed unsent *)
      let st = F.opencode_initial_state msg_dir in
      let sent = ref [] in
      let send b = sent := b :: !sent; Ok () in
      let stats = { F.forwarded = 0; send_failures = 0 } in
      let stats =
        F.opencode_step ~message_dir:msg_dir ~max_bytes:2000 ~send st stats
      in
      check (list string) "history not replayed" [] !sent;
      add_opencode_message ~msg_dir ~part_root ~id:"msg_02" ~role:"user"
        ~completed:false
        [ {|{"id":"p2","type":"text","text":"new message"}|} ];
      let stats =
        F.opencode_step ~message_dir:msg_dir ~max_bytes:2000 ~send st stats
      in
      check (list string) "only post-attach messages forwarded"
        [ "[user] new message" ]
        (List.rev !sent);
      check int "forwarded count" 1 stats.F.forwarded)

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
           --file %s --format nosuchclient --once zztfwd-target > %s 2>&1"
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

let contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let test_binary_auto_detects_codex_by_sniff () =
  with_temp_dir (fun dir ->
      (* a codex rollout copied to a nondescript path: the path heuristics
         miss, the first-line sniff must hit *)
      let transcript = dir // "copied-transcript.jsonl" in
      write_file transcript
        (String.concat "\n"
           [ {|{"timestamp":"t","type":"session_meta","payload":{"id":"s"}}|}
           ; {|{"timestamp":"t","type":"event_msg","payload":{"type":"user_message","message":"ship it"}}|}
           ; {|{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{}}}|}
           ; {|{"timestamp":"t","type":"event_msg","payload":{"type":"agent_message","message":"shipped"}}|}
           ]
        ^ "\n");
      let out = dir // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary)
          (Filename.quote transcript)
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      let content = read_file out in
      check int (Printf.sprintf "exit 0 (output: %s)" content) 0 rc;
      check bool "user forwarded" true
        (contains ~needle:"would send -> zztfwd-target: [user] ship it" content);
      check bool "agent forwarded" true
        (contains ~needle:"would send -> zztfwd-target: [agent] shipped" content);
      check bool "token_count not forwarded" false
        (contains ~needle:"token_count" content))

let test_binary_auto_detects_opencode_dir () =
  with_temp_dir (fun root ->
      let msg_dir, part_root = mk_opencode_session root in
      add_opencode_message ~msg_dir ~part_root ~id:"msg_01" ~role:"user"
        ~completed:false
        [ {|{"id":"p1","type":"text","text":"hello opencode"}|} ];
      let out = root // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary)
          (Filename.quote msg_dir)
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      let content = read_file out in
      check int (Printf.sprintf "exit 0 (output: %s)" content) 0 rc;
      check bool "user message forwarded from dir source" true
        (contains ~needle:"would send -> zztfwd-target: [user] hello opencode"
           content))

let test_binary_rejects_dir_for_jsonl_format () =
  with_temp_dir (fun dir ->
      let out = dir // "out.txt" in
      let cmd =
        Printf.sprintf
          "C2C_SEND_MESSAGE_FIXTURE=1 C2C_CLI_FORCE=1 %s forward-agent-log \
           --file %s --format claude --once zztfwd-target > %s 2>&1"
          (Filename.quote c2c_binary) (Filename.quote dir)
          (Filename.quote out)
      in
      let rc = Sys.command cmd in
      check bool "directory with jsonl format exits non-zero" true (rc <> 0);
      check bool "mentions directory" true
        (contains ~needle:"is a directory" (read_file out)))

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
    ; ( "classify-clients"
      , [ test_case "codex" `Quick test_classify_codex
        ; test_case "kimi" `Quick test_classify_kimi
        ; test_case "grok" `Quick test_classify_grok
        ; test_case "agy" `Quick test_classify_agy
        ] )
    ; ( "detect-format"
      , [ test_case "path heuristics" `Quick test_detect_format_by_path
        ; test_case "first-line sniff" `Quick test_detect_format_by_sniff
        ] )
    ; ( "opencode"
      , [ test_case "once forwards conversation" `Quick
            test_opencode_once_forwards_conversation
        ; test_case "assistant waits for completion" `Quick
            test_opencode_assistant_waits_for_completion
        ; test_case "attach skips existing" `Quick
            test_opencode_attach_skips_existing
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
        ; test_case "auto-detects codex by sniff" `Quick
            test_binary_auto_detects_codex_by_sniff
        ; test_case "auto-detects opencode dir" `Quick
            test_binary_auto_detects_opencode_dir
        ; test_case "dir rejected for jsonl format" `Quick
            test_binary_rejects_dir_for_jsonl_format
        ] )
    ]
