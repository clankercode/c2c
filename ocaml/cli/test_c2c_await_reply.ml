(* test_c2c_await_reply.ml — drives the `c2c await-reply` CLI subcommand
   end-to-end against a temp broker root.

   Slice 1 of #157 (kimi PreToolUse approval hook).

   Coverage:
   - timeout: with no inbox state, await-reply --timeout 1 exits 1
     within ~2 seconds and prints nothing on stdout.
   - allow match: a pre-seeded inbox containing a token+"allow" message
     causes await-reply to exit 0 with stdout = "allow\n".
   - deny match: same with "deny".
   - token isolation: a message that mentions the wrong token is ignored
     (await-reply still times out). *)

let c2c_binary = "./c2c.exe"

let mk_tmp_broker_root () =
  let dir = Filename.temp_file "c2c-await-reply-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir

let write_inbox ~root ~session_id ~messages =
  let path = Filename.concat root (session_id ^ ".inbox.json") in
  let json =
    `List
      (List.map
         (fun (from_alias, content) ->
           `Assoc
             [ ("from_alias", `String from_alias)
             ; ("to_alias", `String "kimi-test")
             ; ("content", `String content)
             ; ("ts", `Float (Unix.gettimeofday ()))
             ; ("deferrable", `Bool false)
             ; ("ephemeral", `Bool false)
             ; ("reply_via", `Null)
             ; ("enc_status", `Null)
             ; ("message_id", `Null)
             ])
         messages)
  in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string json);
  close_out oc

let run_await ~root ~session_id ~token ~timeout_s =
  (* Returns (rc, stdout) *)
  let stdout_path = Filename.temp_file "c2c-await-out-" "" in
  let cmd =
    Printf.sprintf
      "C2C_MCP_BROKER_ROOT=%s %s await-reply --token %s --session-id %s --timeout %.2f --poll-interval 0.1 > %s 2>/dev/null"
      (Filename.quote root) c2c_binary (Filename.quote token)
      (Filename.quote session_id) timeout_s (Filename.quote stdout_path)
  in
  let t0 = Unix.gettimeofday () in
  let rc = Sys.command cmd in
  let elapsed = Unix.gettimeofday () -. t0 in
  let out =
    let ic = open_in stdout_path in
    let buf = Buffer.create 64 in
    (try
       while true do Buffer.add_channel buf ic 1024 done
     with End_of_file -> ());
    close_in ic;
    Sys.remove stdout_path;
    Buffer.contents buf
  in
  (rc, String.trim out, elapsed)

let test_timeout_no_inbox () =
  let root = mk_tmp_broker_root () in
  let rc, out, elapsed =
    run_await ~root ~session_id:"missing-session" ~token:"ka_xyz" ~timeout_s:1.0
  in
  Alcotest.(check int) "exit code is 1 on timeout" 1 rc;
  Alcotest.(check string) "stdout is empty on timeout" "" out;
  Alcotest.(check bool) "elapsed within 2x timeout (no busy-spin, no overrun)"
    true (elapsed >= 0.8 && elapsed < 3.0)

let test_allow_match () =
  let root = mk_tmp_broker_root () in
  let session_id = "kimi-test-session" in
  write_inbox ~root ~session_id
    ~messages:[ ("reviewer", "ka_call_42 allow — looks fine") ];
  let rc, out, _ = run_await ~root ~session_id ~token:"ka_call_42" ~timeout_s:5.0 in
  Alcotest.(check int) "exit code 0 on allow match" 0 rc;
  Alcotest.(check string) "stdout is 'allow'" "allow" out

let test_deny_match () =
  let root = mk_tmp_broker_root () in
  let session_id = "kimi-test-session-2" in
  write_inbox ~root ~session_id
    ~messages:[ ("reviewer", "ka_call_99 deny because dangerous") ];
  let rc, out, _ = run_await ~root ~session_id ~token:"ka_call_99" ~timeout_s:5.0 in
  Alcotest.(check int) "exit code 0 on deny match" 0 rc;
  Alcotest.(check string) "stdout is 'deny'" "deny" out

let test_token_isolation () =
  let root = mk_tmp_broker_root () in
  let session_id = "kimi-test-session-3" in
  write_inbox ~root ~session_id
    ~messages:[ ("reviewer", "ka_other_token allow")
              ; ("reviewer", "ka_other_token deny") ];
  let rc, _, _ =
    run_await ~root ~session_id ~token:"ka_target_token" ~timeout_s:1.0
  in
  Alcotest.(check int) "exit 1: wrong-token messages do not match" 1 rc

let () =
  Alcotest.run "c2c_await_reply" [
    "await_reply", [
      Alcotest.test_case "timeout exits 1 with no stdout" `Quick test_timeout_no_inbox;
      Alcotest.test_case "allow verdict matches and prints 'allow'" `Quick test_allow_match;
      Alcotest.test_case "deny verdict matches and prints 'deny'" `Quick test_deny_match;
      Alcotest.test_case "wrong-token messages do not match" `Quick test_token_isolation;
    ]
  ]
