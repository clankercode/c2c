(* test_nudge_debounce — tests for the PostToolUse hook debounce logic (B038).
 *
 * Tests the debounced nudge behavior in c2c_inbox_hook:
 *   - Rapid-fire invocations within 60s → nudge fires AT MOST ONCE
 *   - After 60s, nudge may fire again
 *   - After draining inbox, no nudge (0 waiting, window reset)
 *   - Stop hook still emits FULL messages (regression check)
 *
 * The debounce rule:
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

let env_op_to_args ops =
  List.map (function
      | Set (k, v) ->
          Printf.sprintf "%s=%s" k (Filename.quote v)
      | Unset k -> Printf.sprintf "-u %s" k)
    ops

type hook_result = {
  rc : int;
  stdout : string;
  stderr : string;
  elapsed_ms : float;
}

let run_hook ?(env=[]) ~stdin_payload ~hook_name () : hook_result =
  let hook = hook_bin ~name:hook_name () in
  let stdin_path = Filename.temp_file "c2c-nudge-test-in" ".json" in
  let out = Filename.temp_file "c2c-nudge-test-out" ".json" in
  let err = Filename.temp_file "c2c-nudge-test-err" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove stdin_path with _ -> ());
      (try Sys.remove out with _ -> ());
      (try Sys.remove err with _ -> ()))
    (fun () ->
      write_file stdin_path stdin_payload;
      let env_args = env_op_to_args env in
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
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
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
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
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
    let inbox = seed_inbox ~dir ~sid 1 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
    (* First invocation: should emit nudge *)
    let r1 = run_hook ~env ~stdin_payload:payload ~hook_name:"c2c_inbox_hook" () in
    check int "first hook exits 0" 0 r1.rc;
    let ctx1 = parse_additional_context r1 in
    check bool "first invocation emits nudge" true
      (match ctx1 with Some s -> string_contains s "c2c:" | None -> false);
    
    (* Drain the inbox manually (simulating poll-inbox) *)
    seed_inbox ~dir ~sid 0;
    
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

let test_stop_hook_still_emits_full_messages () =
  with_temp_dir (fun dir ->
    let sid = "nudge-stop-hook" in
    let inbox = seed_inbox ~dir ~sid 2 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"Stop"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
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
    let inbox = seed_inbox ~dir ~sid 3 in
    let payload = Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|} sid in
    let env = [ Unset "C2C_MCP_SESSION_ID"; Unset "C2C_MCP_BROKER_ROOT";
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
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
                Set ("C2C_SESSIONS_BROKER_ROOT", dir) ] in
    
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
    [ ( "debounce",
        [ ( "rapid-fire within 60s fires at most one nudge", `Quick,
            test_rapid_fire_within_60s_fires_at_most_one_nudge )
        ; ( "after 60s nudge can fire again", `Slow,
            test_after_60s_nudge_can_fire_again )
        ; ( "drain inbox resets debounce window", `Quick,
            test_drain_inbox_resets_debounce_window )
        ; ( "full inject mode emits full messages", `Quick,
            test_full_inject_mode_emits_full_messages )
        ; ( "stop hook still emits full messages", `Quick,
            test_stop_hook_still_emits_full_messages )
        ; ( "nudge format is short line", `Quick,
            test_nudge_format_is_short_line )
        ; ( "empty inbox no nudge", `Quick,
            test_empty_inbox_no_nudge )
        ] )
    ]
