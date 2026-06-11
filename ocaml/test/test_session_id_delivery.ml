open Alcotest

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-session-id-test-%08x" (Random.bits ()))
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

let json_list_length path =
  match Yojson.Safe.from_string (read_file path) with
  | `List items -> List.length items
  | _ -> Alcotest.fail ("expected JSON list in " ^ path)

let first_json_object path =
  match Yojson.Safe.from_string (read_file path) with
  | `List (`Assoc fields :: _) -> fields
  | _ -> Alcotest.fail ("expected non-empty JSON object list in " ^ path)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let built_c2c = "_build/default/ocaml/cli/c2c.exe"
let built_inbox_hook = "_build/default/ocaml/tools/c2c_inbox_hook.exe"

let test_send_session_writes_global_inbox () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-send-p0" in
    let out = Filename.temp_file "c2c-send-session" ".out" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove out with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check int "send --session exits 0" 0 rc;
        let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
        check bool "session inbox exists" true (Sys.file_exists inbox_path);
        let inbox = read_file inbox_path in
        check bool "inbox contains message" true
          (string_contains inbox "hello world");
        let fields = first_json_object inbox_path in
        match List.assoc_opt "message_id" fields with
        | Some (`String s) ->
            check bool "session send stamps message_id" true (s <> "")
        | _ -> Alcotest.fail "message_id missing from session-send inbox"))

let test_send_session_rejects_invalid_session_id () =
  with_temp_dir (fun dir ->
    let escaped_name =
      Printf.sprintf "c2c-session-id-escape-%08x" (Random.bits ())
    in
    let escaped_path =
      Filename.concat (Filename.dirname dir) (escaped_name ^ ".inbox.json")
    in
    let out = Filename.temp_file "c2c-send-session-invalid" ".out" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove escaped_path with _ -> ()))
      (fun () ->
        let bad_sid = "../" ^ escaped_name in
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote bad_sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check bool "invalid session id exits nonzero" true (rc <> 0);
        check bool "invalid session id does not escape broker root" false
          (Sys.file_exists escaped_path)))

let test_send_session_rejects_reserved_sender () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-reserved-sender-p0" in
    let out = Filename.temp_file "c2c-send-session-reserved" ".out" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove out with _ -> ())
      (fun () ->
        let cmd =
          Printf.sprintf
            "env -u C2C_MCP_SESSION_ID -u C2C_MCP_BROKER_ROOT \
             C2C_CLI_FORCE=1 C2C_SESSIONS_BROKER_ROOT=%s %s \
             send --from c2c --session %s 'hello world' > %s 2>&1"
            (Filename.quote dir) (Filename.quote built_c2c)
            (Filename.quote sid) (Filename.quote out)
        in
        let rc = Sys.command cmd in
        check bool "reserved sender exits nonzero" true (rc <> 0);
        let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
        check bool "reserved sender does not write inbox" false
          (Sys.file_exists inbox_path)))

let test_hook_reads_stdin_session_and_drains_global_inbox () =
  with_temp_dir (fun dir ->
    let sid = "test-sid-hook-p0" in
    let inbox_path = Filename.concat dir (sid ^ ".inbox.json") in
    write_file inbox_path
      {|[{"from_alias":"sender-a","to_alias":"test-sid-hook-p0","content":"hello world","ts":1.0}]|};
    let out = Filename.temp_file "c2c-inbox-hook" ".out" in
    let err = Filename.temp_file "c2c-inbox-hook" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let stdin_payload =
          Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|}
            sid
        in
        let cmd =
          Printf.sprintf
            "printf %%s %s | env -u C2C_MCP_SESSION_ID -u \
             C2C_MCP_BROKER_ROOT C2C_SESSIONS_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote stdin_payload) (Filename.quote dir)
            (Filename.quote built_inbox_hook) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check int "inbox hook exits 0" 0 rc;
        let stdout = read_file out in
        let json = Yojson.Safe.from_string stdout in
        let open Yojson.Safe.Util in
        let context =
          json |> member "hookSpecificOutput" |> member "additionalContext"
          |> to_string
        in
        check bool "additionalContext has c2c envelope" true
          (string_contains context "<c2c ");
        check bool "additionalContext has message content" true
          (string_contains context "hello world");
        check bool "additionalContext closes c2c envelope" true
          (string_contains context "</c2c>");
        check int "global session inbox drained" 0
          (json_list_length inbox_path)))

let test_hook_rejects_invalid_stdin_session_id () =
  with_temp_dir (fun dir ->
    let escaped_name =
      Printf.sprintf "c2c-session-id-hook-escape-%08x" (Random.bits ())
    in
    let escaped_path =
      Filename.concat (Filename.dirname dir) (escaped_name ^ ".inbox.json")
    in
    write_file escaped_path
      (Printf.sprintf
         {|[{"from_alias":"sender-a","to_alias":"../%s","content":"secret outside root","ts":1.0}]|}
         escaped_name);
    let out = Filename.temp_file "c2c-inbox-hook-invalid" ".out" in
    let err = Filename.temp_file "c2c-inbox-hook-invalid" ".err" in
    Fun.protect
      ~finally:(fun () ->
        (try Sys.remove escaped_path with _ -> ());
        (try Sys.remove out with _ -> ());
        (try Sys.remove err with _ -> ()))
      (fun () ->
        let stdin_payload =
          Printf.sprintf {|{"session_id":%S,"hook_event_name":"PostToolUse"}|}
            ("../" ^ escaped_name)
        in
        let cmd =
          Printf.sprintf
            "printf %%s %s | env -u C2C_MCP_SESSION_ID -u \
             C2C_MCP_BROKER_ROOT C2C_SESSIONS_BROKER_ROOT=%s %s > %s 2> %s"
            (Filename.quote stdin_payload) (Filename.quote dir)
            (Filename.quote built_inbox_hook) (Filename.quote out)
            (Filename.quote err)
        in
        let rc = Sys.command cmd in
        check bool "invalid hook session exits nonzero" true (rc <> 0);
        let stdout = read_file out in
        check bool "invalid hook session does not drain escaped inbox" false
          (string_contains stdout "secret outside root");
        check int "escaped inbox remains untouched" 1
          (json_list_length escaped_path)))

let () =
  Alcotest.run "session_id_delivery"
    [ ( "send-session",
        [ ( "writes global sessions inbox", `Quick,
            test_send_session_writes_global_inbox )
        ; ( "rejects invalid session id", `Quick,
            test_send_session_rejects_invalid_session_id )
        ; ( "rejects reserved sender", `Quick,
            test_send_session_rejects_reserved_sender )
        ] )
    ; ( "hook",
        [ ( "reads stdin session_id and drains global inbox", `Quick,
            test_hook_reads_stdin_session_and_drains_global_inbox )
        ; ( "rejects invalid stdin session_id", `Quick,
            test_hook_rejects_invalid_stdin_session_id )
        ] )
    ]
