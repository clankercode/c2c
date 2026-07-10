(* test_nudge_debounce — tests for the PostToolUse hook delivery modes.
 *
 * claude-full-delivery slice: FULL message delivery is now the DEFAULT
 * (push-only drain — deferrable messages wait for the next turn boundary;
 * no debounce, since the drain empties the inbox and repeated fires are
 * cheap no-ops). The legacy debounced nudge (B038) is the opt-out behind
 * C2C_POST_TOOL_NUDGE_ONLY=1; C2C_POST_TOOL_FULL_INJECT=1 (the old opt-in)
 * is still honored and outranks NUDGE_ONLY.
 *
 * Covered here:
 *   - Default = full delivery: drains + emits envelopes, no debounce
 *   - Deferrable messages are HELD mid-turn (push-only drain)
 *   - Channel-capable sessions skip the repo drain (no dual-drain)
 *   - Nudge opt-out: rapid-fire within 60s → nudge fires AT MOST ONCE
 *   - Nudge opt-out: after 60s, nudge may fire again
 *   - Nudge opt-out: after draining inbox, no nudge (0 waiting, reset)
 *   - Stop hook still emits FULL messages (regression check)
 *
 * The nudge debounce rule (opt-out mode only):
 *   - Emit nudge only when: messages_waiting >= 1 AND
 *     (now - last_nudge_ts) >= 60s AND (now - first_waiting_ts) >= 60s
 *   - Reset both timestamps when inbox is drained (0 messages)
 *)

open Alcotest

(* ------------------------------------------------------------------ *)
(* Path resolution                                                    *)
(* ------------------------------------------------------------------ *)

let abs_path p =
  if Filename.is_relative p then Filename.concat (Unix.getcwd ()) p else p

let hook_bin ~name () : string =
  let exe = abs_path Sys.executable_name in
  let exe_dir = Filename.dirname exe in
  let ocaml_dir = Filename.dirname exe_dir in
  let hook = Filename.concat ocaml_dir (Printf.sprintf "tools/%s.exe" name) in
  if not (Sys.file_exists hook) then
    Alcotest.fail
      (Printf.sprintf "hook binary not found at %s (test exe=%s)" hook exe);
  hook

(* ------------------------------------------------------------------ *)
(* Filesystem helpers                                                  *)
(* ------------------------------------------------------------------ *)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-nudge-test-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) ->
     ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
     Unix.mkdir dir 0o700);
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_file path contents =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let json_list_length path =
  let raw = read_file path in
  match Yojson.Safe.from_string (String.trim raw) with
  | `List items -> List.length items
  | _ -> Alcotest.fail ("expected JSON list in " ^ path)

(* ------------------------------------------------------------------ *)
(* Subprocess driver                                                   *)
(* ------------------------------------------------------------------ *)

type env_op = Set of string * string | Unset of string

(* GNU env requires all -u options BEFORE any NAME=VALUE assignment, so emit
   unsets first regardless of input order. Later assignments override earlier
   ones (and an earlier -u for the same key), so base env can be prepended and
   still overridden by a caller that Sets the same key. *)
let env_op_to_args ops =
  let unsets =
    List.filter_map
      (function Unset k -> Some (Printf.sprintf "-u %s" k) | _ -> None) ops
  in
  let sets =
    List.filter_map
      (function
        | Set (k, v) -> Some (Printf.sprintf "%s=%s" k (Filename.quote v))
        | _ -> None)
      ops
  in
  unsets @ sets

type hook_result = {
  rc : int;
  stdout : string;
  stderr : string;
  elapsed_ms : float;
}

(* Hermetic sandbox for the hook subprocess — see the identical helper in
   test_inbox_hook_harness.ml. C2c_hook_lib.resolve_hook_broker_root now falls
   back to the canonical repo-fingerprint broker when C2C_MCP_BROKER_ROOT is
   unset; pointing HOME + C2C_STATE_HOME at a fresh EMPTY temp tree keeps that
   fallback off the developer's live ~/.c2c broker (fp path has no
   registry.json -> helper returns "" -> repo drain skipped). *)
let with_hermetic_home f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-nudge-hermetic-%08x" (Random.bits ()))
  in
  (try Unix.mkdir dir 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let run_hook ?(env=[]) ~stdin_payload ~hook_name () : hook_result =
  let hook = hook_bin ~name:hook_name () in
  let stdin_path = Filename.temp_file "c2c-nudge-test-in" ".json" in
  let out = Filename.temp_file "c2c-nudge-test-out" ".json" in
  let err = Filename.temp_file "c2c-nudge-test-err" ".txt" in
  with_hermetic_home @@ fun hermetic ->
  let base_env =
    [ Unset "C2C_MCP_BROKER_ROOT"
    ; Set ("HOME", hermetic)
    ; Set ("C2C_STATE_HOME", hermetic)
    ]
  in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove stdin_path with _ -> ());
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      write_file stdin_path stdin_payload;
      let env_args = env_op_to_args (base_env @ env) in
      let env_str = String.concat " " env_args in
      let cmd =
        Printf.sprintf
          "env %s %s < %s > %s 2> %s"
          env_str
          (Filename.quote hook)
          (Filename.quote stdin_path)
          (Filename.quote out)
          (Filename.quote err)
      in
      let t0 = Unix.gettimeofday () in
      let rc = Sys.command cmd in
      let t1 = Unix.gettimeofday () in
      let stdout = if Sys.file_exists out then read_file out else "" in
      let stderr = if Sys.file_exists err then read_file err else "" in
      { rc; stdout; stderr; elapsed_ms = (t1 -. t0) *. 1000.0 })

let parse_additional_context result : string option =
  let s = String.trim result.stdout in
  if s = "" then None
  else
    try
      let json = Yojson.Safe.from_string s in
      let open Yojson.Safe.Util in
      match json |> member "hookSpecificOutput" with
      | `Assoc _ ->
          (match json |> member "hookSpecificOutput" |> member "additionalContext"
                |> to_string_option with
           | Some ctx -> Some ctx
           | None -> None)
      | _ -> None
    with _ -> None

(* ------------------------------------------------------------------ *)
(* Inbox seeding                                                       *)
(* ------------------------------------------------------------------ *)

let seed_inbox ~dir ~sid n =
  let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
  if n = 0 then begin
    (* Remove inbox file if it exists *)
    (try Sys.remove inbox_path with _ -> ())
  end else begin
    let items = List.init n (fun i ->
      Printf.sprintf
        {|{"from_alias":"sender-%d","to_alias":%S,"content":"msg-%d-for-%s","ts":%d.0}|}
        i sid i sid (i + 1))
    in
    let body = "[" ^ String.concat "," items ^ "]" in
    write_file inbox_path body
  end;
  inbox_path

(* ------------------------------------------------------------------ *)
(* Debounce tests                                                      *)
(* ------------------------------------------------------------------ *)

let test_rapid_fire_within_60s_fires_at_most_one_nudge () =
  with_temp_dir (fun dir ->
    let sid = "nudge-rapid-fire" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* First invocation: should emit nudge *)
    let r1 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "first hook exits 0" 0 r1.rc;
    let ctx1 = parse_additional_context r1 in
    check bool "first invocation emits nudge" true
      (match ctx1 with Some s -> string_contains s "c2c:" | None -> false);
    
    (* Rapid-fire second invocation (within 60s): should NOT emit nudge *)
    let r2 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "second hook exits 0" 0 r2.rc;
    let ctx2 = parse_additional_context r2 in
    check bool "second invocation does NOT emit nudge" true
      (match ctx2 with None -> true | Some s -> not (string_contains s "c2c:"));
    
    (* Rapid-fire third invocation (within 60s): should NOT emit nudge *)
    let r3 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "third hook exits 0" 0 r3.rc;
    let ctx3 = parse_additional_context r3 in
    check bool "third invocation does NOT emit nudge" true
      (match ctx3 with None -> true | Some s -> not (string_contains s "c2c:"));
    
    (* Inbox should NOT be drained (nudge mode doesn't drain) *)
    check int "inbox still has 1 message (nudge doesn't drain)" 1
      (json_list_length inbox))

let test_after_60s_nudge_can_fire_again () =
  with_temp_dir (fun dir ->
    let sid = "nudge-after-60s" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* First invocation: should emit nudge *)
    let r1 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "first hook exits 0" 0 r1.rc;
    let ctx1 = parse_additional_context r1 in
    check bool "first invocation emits nudge" true
      (match ctx1 with Some s -> string_contains s "c2c:" | None -> false);
    
    (* Wait 61 seconds *)
    Unix.sleep 61;
    
    (* After 60s, nudge should fire again *)
    let r2 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "second hook exits 0" 0 r2.rc;
    let ctx2 = parse_additional_context r2 in
    check bool "after 60s, nudge fires again" true
      (match ctx2 with Some s -> string_contains s "c2c:" | None -> false);
    
    (* Inbox should still NOT be drained *)
    check int "inbox still has 1 message" 1 (json_list_length inbox))

let test_drain_inbox_resets_debounce_window () =
  with_temp_dir (fun dir ->
    let sid = "nudge-drain-reset" in
    let _inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* First invocation: should emit nudge *)
    let r1 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "first hook exits 0" 0 r1.rc;
    let ctx1 = parse_additional_context r1 in
    check bool "first invocation emits nudge" true
      (match ctx1 with Some s -> string_contains s "c2c:" | None -> false);
    
    (* Drain the inbox manually (simulating poll-inbox) *)
    ignore (seed_inbox ~dir ~sid 0);
    
    (* Second invocation: no messages, should NOT emit nudge *)
    let r2 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "second hook exits 0" 0 r2.rc;
    let ctx2 = parse_additional_context r2 in
    check bool "after drain, no nudge" true
      (match ctx2 with None -> true | Some s -> not (string_contains s "c2c:"));
    
    (* Enqueue new message *)
    let _ = seed_inbox ~dir ~sid 1 in
    
    (* Third invocation: should emit nudge (window reset) *)
    let r3 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "third hook exits 0" 0 r3.rc;
    let ctx3 = parse_additional_context r3 in
    check bool "after re-enqueue, nudge fires again" true
      (match ctx3 with Some s -> string_contains s "c2c:" | None -> false))

(* ------------------------------------------------------------------ *)
(* Full-delivery default (claude-full-delivery slice)                  *)
(* ------------------------------------------------------------------ *)

let test_default_is_full_delivery () =
  with_temp_dir (fun dir ->
    let sid = "fdel-default" in
    let inbox = seed_inbox ~dir ~sid 2 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    (* No mode env at all: full delivery must be the default. *)
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Unset "C2C_POST_TOOL_FULL_INJECT"; Unset "C2C_POST_TOOL_NUDGE_ONLY";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected full delivery by default, got no output"
    in
    check bool "default delivers envelope" true (string_contains ctx "<c2c ");
    check bool "default delivers msg-0" true
      (string_contains ctx "msg-0-for-fdel-default");
    check bool "default delivers msg-1" true
      (string_contains ctx "msg-1-for-fdel-default");
    check int "inbox drained by default" 0 (json_list_length inbox))

let test_default_full_delivery_has_no_debounce () =
  with_temp_dir (fun dir ->
    let sid = "fdel-no-debounce" in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    (* First fire delivers. *)
    let _ = seed_inbox ~dir ~sid 1 in
    let r1 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "first hook exits 0" 0 r1.rc;
    check bool "first fire delivers" true
      (match parse_additional_context r1 with
       | Some s -> string_contains s "msg-0-for-fdel-no-debounce"
       | None -> false);
    (* Immediate second fire with a fresh message delivers again — no 60s
       debounce on the full-delivery path (the drain empties the inbox, so
       delivery latency is the only thing a debounce would add). *)
    let inbox = seed_inbox ~dir ~sid 1 in
    let r2 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "second hook exits 0" 0 r2.rc;
    check bool "immediate second fire delivers too" true
      (match parse_additional_context r2 with
       | Some s -> string_contains s "msg-0-for-fdel-no-debounce"
       | None -> false);
    check int "inbox drained after second fire" 0 (json_list_length inbox))

let test_deferrable_held_mid_turn () =
  with_temp_dir (fun dir ->
    let sid = "fdel-deferrable" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      (Printf.sprintf
         {|[{"from_alias":"peer-a","to_alias":%S,"content":"urgent push body","ts":1.0},{"from_alias":"peer-b","to_alias":%S,"content":"no rush deferrable body","ts":2.0,"deferrable":true}]|}
         sid sid);
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    let ctx = match parse_additional_context r with
      | Some s -> s
      | None -> Alcotest.fail "expected push message delivery"
    in
    check bool "push message delivered mid-turn" true
      (string_contains ctx "urgent push body");
    check bool "deferrable message HELD mid-turn" false
      (string_contains ctx "no rush deferrable body");
    check int "deferrable message still queued" 1 (json_list_length inbox_path);
    (* The held message is the deferrable one. *)
    let remaining = read_file inbox_path in
    check bool "remaining message is the deferrable one" true
      (string_contains remaining "no rush deferrable body"))

let test_channel_capable_session_skips_repo_drain () =
  with_temp_dir (fun global_dir ->
    with_temp_dir (fun repo_dir ->
      let sid = "fdel-chancap" in
      let alias = "zz-fdel-chancap" in
      let broker = C2c_mcp.Broker.create ~root:repo_dir in
      C2c_mcp.Broker.register broker ~session_id:sid ~alias ~pid:None
        ~pid_start_time:None ();
      ignore
        (C2c_mcp.Broker.register broker ~session_id:"fdel-chancap-peer"
           ~alias:"zz-fdel-chancap-peer" ~pid:None ~pid_start_time:None ());
      (* Mark the session channel-capable: the MCP watcher owns delivery. *)
      C2c_mcp.Broker.set_automated_delivery broker ~session_id:sid
        ~automated_delivery:true;
      C2c_mcp.Broker.enqueue_message broker ~from_alias:"zz-fdel-chancap-peer"
        ~to_alias:alias ~content:"channel owned body" ();
      let repo_inbox = Filename.concat repo_dir (sid ^ ".inbox.json") in
      check int "repo inbox seeded" 1 (json_list_length repo_inbox);
      let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
      let env = [ Set ("C2C_MCP_SESSION_ID", sid);
                  Set ("C2C_MCP_BROKER_ROOT", repo_dir);
                  Set ("C2C_SESSIONS_BROKER_ROOT", global_dir) ] in
      let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
      check int "hook exits 0" 0 r.rc;
      (* No dual-drain: the message stays in the repo inbox for the watcher,
         and the hook must not emit its body. *)
      (match parse_additional_context r with
       | Some s ->
           check bool "hook does not emit channel-owned message" false
             (string_contains s "channel owned body")
       | None -> ());
      check int "repo inbox NOT drained (watcher owns delivery)" 1
        (json_list_length repo_inbox)))

let test_full_inject_env_outranks_nudge_only () =
  with_temp_dir (fun dir ->
    let sid = "fdel-both-envs" in
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1");
                Set ("C2C_POST_TOOL_FULL_INJECT", "1") ] in
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    check bool "FULL_INJECT outranks NUDGE_ONLY" true
      (match parse_additional_context r with
       | Some s -> string_contains s "msg-0-for-fdel-both-envs"
       | None -> false);
    check int "inbox drained" 0 (json_list_length inbox))

let test_full_inject_mode_emits_full_messages () =
  with_temp_dir (fun dir ->
    let sid = "nudge-full-inject" in
    let inbox = seed_inbox ~dir ~sid 2 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_FULL_INJECT", "1") ] in
    
    (* Full inject mode: should drain and emit full messages *)
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    let ctx = parse_additional_context r in
    check bool "full inject emits full messages" true
      (match ctx with
       | Some s -> string_contains s "msg-0-for-nudge-full-inject"
       | None -> false);
    
    (* Inbox should be drained in full inject mode *)
    check int "inbox drained in full inject mode" 0 (json_list_length inbox))

let parse_stop_hook_reason result : string option =
  let s = String.trim result.stdout in
  if s = "" then None
  else
    try
      let json = Yojson.Safe.from_string s in
      let open Yojson.Safe.Util in
      match json |> member "decision" |> to_string_option with
      | Some "block" ->
          json |> member "reason" |> to_string_option
      | _ -> None
    with _ -> None

let test_stop_hook_delivers_deferrable_at_turn_boundary () =
  with_temp_dir (fun dir ->
    let sid = "stop-defer-boundary" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      (Printf.sprintf
         {|[{"from_alias":"peer-a","to_alias":%S,"content":"stop push body","ts":1.0},{"from_alias":"peer-b","to_alias":%S,"content":"stop deferrable body","ts":2.0,"deferrable":true}]|}
         sid sid);
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"Stop"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    (* Stop is a turn boundary: FULL drain — deferrable delivered too. *)
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_stop_hook" () in
    check int "stop hook exits 0" 0 r.rc;
    (match parse_stop_hook_reason r with
     | None -> Alcotest.fail "expected stop hook to block with messages"
     | Some reason ->
         check bool "stop delivers push message" true
           (string_contains reason "stop push body");
         check bool "stop delivers deferrable message (turn boundary)" true
           (string_contains reason "stop deferrable body"));
    check int "stop hook drains everything" 0 (json_list_length inbox_path))

let test_stop_hook_still_emits_full_messages () =
  with_temp_dir (fun dir ->
    let sid = "nudge-stop-hook" in
    let inbox = seed_inbox ~dir ~sid 2 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"Stop"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* Stop hook should still emit full messages *)
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_stop_hook" () in
    check int "stop hook exits 0" 0 r.rc;
    let reason = parse_stop_hook_reason r in
    check bool "stop hook emits full messages" true
      (match reason with
       | Some s -> string_contains s "msg-0-for-nudge-stop-hook"
       | None -> false);
    
    (* Stop hook should drain the inbox *)
    check int "stop hook drains inbox" 0 (json_list_length inbox))

let test_nudge_format_is_short_line () =
  with_temp_dir (fun dir ->
    let sid = "nudge-format" in
    let _inbox = seed_inbox ~dir ~sid 3 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* Should emit a short nudge line *)
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    let ctx = parse_additional_context r in
    match ctx with
    | None -> Alcotest.fail "expected nudge line, got no output"
    | Some s ->
        (* Should be a single line, not multiple message bodies *)
        check bool "nudge is single line" true
          (not (string_contains s "<c2c "));
        check bool "nudge contains message count" true
          (string_contains s "3 message(s) waiting"))

let test_empty_inbox_no_nudge () =
  with_temp_dir (fun dir ->
    let sid = "nudge-empty" in
    (* No inbox file written *)
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir);
                Set ("C2C_POST_TOOL_NUDGE_ONLY", "1") ] in
    
    (* Empty inbox: should NOT emit nudge *)
    let r = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "hook exits 0" 0 r.rc;
    let ctx = parse_additional_context r in
    check bool "empty inbox no nudge" true
      (match ctx with None -> true | Some s -> not (string_contains s "c2c:")))

(* ------------------------------------------------------------------ *)
(* Test runner                                                         *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run "nudge_debounce"
    [ ( "full-delivery-default",
        [ ( "default (no env) is full delivery", `Quick,
            test_default_is_full_delivery )
        ; ( "full delivery has no debounce", `Quick,
            test_default_full_delivery_has_no_debounce )
        ; ( "deferrable messages are held mid-turn", `Quick,
            test_deferrable_held_mid_turn )
        ; ( "channel-capable session skips repo drain", `Quick,
            test_channel_capable_session_skips_repo_drain )
        ; ( "FULL_INJECT outranks NUDGE_ONLY", `Quick,
            test_full_inject_env_outranks_nudge_only )
        ; ( "legacy FULL_INJECT env still emits full messages", `Quick,
            test_full_inject_mode_emits_full_messages )
        ] )
    ; ( "nudge-opt-out",
        [ ( "rapid-fire within 60s fires at most one nudge", `Quick,
            test_rapid_fire_within_60s_fires_at_most_one_nudge )
        ; ( "after 60s nudge can fire again", `Slow,
            test_after_60s_nudge_can_fire_again )
        ; ( "drain inbox resets debounce window", `Quick,
            test_drain_inbox_resets_debounce_window )
        ; ( "stop hook still emits full messages", `Quick,
            test_stop_hook_still_emits_full_messages )
        ; ( "stop hook delivers deferrable at turn boundary", `Quick,
            test_stop_hook_delivers_deferrable_at_turn_boundary )
        ; ( "nudge format is short line", `Quick,
            test_nudge_format_is_short_line )
        ; ( "empty inbox no nudge", `Quick,
            test_empty_inbox_no_nudge )
        ] )
    ]
