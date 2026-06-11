open Alcotest

let () = Random.self_init ()

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base (Printf.sprintf "c2c-sessions-test-%08x" (Random.bits ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    Unix.mkdir dir 0o755);
  Fun.protect
    ~finally:(fun () -> Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let string_contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let json_of_string s =
  try Some (Yojson.Safe.from_string s)
  with _ -> None

(* --- helpers ------------------------------------------------------------- *)

(* Read the session_id field from a Yojson object. *)
let sid_of json = Yojson.Safe.Util.(json |> member "session_id" |> to_string)

let live_bool_of json =
  match Yojson.Safe.Util.(json |> member "alive") with
  | `Bool b -> Some b
  | `Null -> None
  | _ -> Alcotest.fail "alive field is not bool/null"

let string_opt_of json field =
  match Yojson.Safe.Util.(json |> member field) with
  | `String s -> Some s
  | `Null -> None
  | _ -> Alcotest.fail (field ^ " field is not string/null")

let with_registered_session ~dir ~session_id ~alias ~pid ~pid_start_time ?client_type ?cwd ?role f =
  let broker = C2c_mcp.Broker.create ~root:dir in
  C2c_mcp.Broker.register broker
    ~session_id ~alias ~pid ~pid_start_time ?client_type ?cwd ?role ();
  let regs = C2c_mcp.Broker.list_registrations broker in
  f regs

(* --- tests --------------------------------------------------------------- *)

(* 1. JSON output: per-session shape, with all optional fields exercised. *)
let test_sessions_json_full_shape () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-gamma-003"
      ~alias:"zzz-test-gamma"
      ~pid:(Some 99999)
      ~pid_start_time:None
      ~client_type:(Some "claude")
      ~cwd:(Some "/tmp/work")
      ~role:(Some "coordinator")
      (fun regs ->
        let json = C2c_sessions_format.sessions_to_json regs in
        let str = Yojson.Safe.to_string json in
        match json_of_string str with
        | Some (`List items) ->
          check int "one item" 1 (List.length items);
          let gamma = List.hd items in
          check string "session_id" "sid-gamma-003" (sid_of gamma);
          (* alias: Broker.register auto-populates canonical_alias, so
             expect the fully-qualified form, not the bare alias. *)
          (match string_opt_of gamma "alias" with
           | Some a when string_contains a "zzz-test-gamma" -> ()
           | Some a -> Alcotest.fail ("alias should contain 'zzz-test-gamma', got: " ^ a)
           | None -> Alcotest.fail "alias should be present");
          check string "client_type" "claude" (Option.get (string_opt_of gamma "client_type"));
          check string "cwd" "/tmp/work" (Option.get (string_opt_of gamma "cwd"));
          check string "role" "coordinator" (Option.get (string_opt_of gamma "role"));
          (* pid=99999 is not a real PID; liveness should be Dead or Unknown *)
          (match live_bool_of gamma with
           | Some true -> Alcotest.fail "fake pid should not be alive"
           | _ -> ())
        | _ -> Alcotest.fail "failed to parse sessions_to_json output"))

(* 2. JSON output: missing optional fields should be `null`, not omitted. *)
let test_sessions_json_optional_fields_null () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-delta-004"
      ~alias:"zzz-test-delta"
      ~pid:None
      ~pid_start_time:None
      ~client_type:None
      ~cwd:None
      ~role:None
      (fun regs ->
        let json = C2c_sessions_format.sessions_to_json regs in
        match json with
        | `List [item] ->
          check bool "client_type is null" true
            (match Yojson.Safe.Util.(item |> member "client_type") with `Null -> true | _ -> false);
          check bool "cwd is null" true
            (match Yojson.Safe.Util.(item |> member "cwd") with `Null -> true | _ -> false);
          check bool "role is omitted" true
            (match Yojson.Safe.Util.(item |> member "role") with `Null -> true | _ -> false);
          (* no canonical_alias was set; alias should fall back to bare alias *)
          (match string_opt_of item "alias" with
           | Some a when string_contains a "zzz-test-delta" -> ()
           | Some a -> Alcotest.fail ("alias should contain 'zzz-test-delta', got: " ^ a)
           | None -> Alcotest.fail "alias should be present")
        | _ -> Alcotest.fail "expected one-item list"))

(* 3. JSON output: alive=true for own-pid registration. *)
let test_sessions_json_alive_for_own_pid () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-self-pid"
      ~alias:"zzz-test-self"
      ~pid:(Some (Unix.getpid ()))
      ~pid_start_time:(C2c_broker.read_pid_start_time (Unix.getpid ()))
      ~client_type:(Some "opencode")
      ~cwd:None
      ~role:None
      (fun regs ->
        let json = C2c_sessions_format.sessions_to_json regs in
        match json with
        | `List [item] ->
          (match live_bool_of item with
           | Some true -> ()
           | _ -> Alcotest.fail "own pid should be alive")
        | _ -> Alcotest.fail "expected one-item list"))

(* 4. Human output: header + per-session fields. *)
let test_sessions_human_full_shape () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-alpha-001"
      ~alias:"zzz-test-alpha"
      ~pid:(Some 99999)
      ~pid_start_time:None
      ~client_type:(Some "opencode")
      ~cwd:(Some "/home/user/proj")
      ~role:None
      (fun regs ->
        let out = C2c_sessions_format.format_human regs in
        (* Column header *)
        check bool "header has SESSION_ID" true (string_contains out "SESSION_ID");
        check bool "header has ALIAS" true (string_contains out "ALIAS");
        check bool "header has STATE" true (string_contains out "STATE");
        check bool "header has CWD" true (string_contains out "CWD");
        (* Separator row *)
        check bool "separator dashes" true (string_contains out "------------------------------------");
        (* Data row: session_id, alias, client_type, cwd, role absent *)
        check bool "row has session_id" true (string_contains out "sid-alpha-001");
        check bool "row has alias" true (string_contains out "zzz-test-alpha");
        check bool "row has opencode" true (string_contains out "opencode");
        check bool "row has cwd" true (string_contains out "/home/user/proj");
        check bool "row has dead liveness" true (string_contains out "dead");
        (* role is None: last column is empty (just trailing spaces before \n).
           Compare with role=Some "coordinator" test below to assert the column
           actually renders when populated. *)
        let lines = String.split_on_char '\n' out in
        let data_lines = List.filter (fun l ->
          String.length l > 0
          && not (string_contains l "SESSION_ID")
          && not (string_contains l "----")
        ) lines in
        check int "one data row" 1 (List.length data_lines);
        let row = List.hd data_lines in
        (* When role=None, the line should not contain "coordinator" *)
        check bool "row has no role text when role=None"
          false (string_contains row "coordinator")))

(* 5. Human output: own-pid row is labelled "alive". *)
let test_sessions_human_alive_for_own_pid () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-self-pid"
      ~alias:"zzz-test-self"
      ~pid:(Some (Unix.getpid ()))
      ~pid_start_time:(C2c_broker.read_pid_start_time (Unix.getpid ()))
      ~client_type:(Some "opencode")
      ~cwd:None
      ~role:None
      (fun regs ->
        let out = C2c_sessions_format.format_human regs in
        check bool "row has alive liveness" true (string_contains out "alive")))

(* 5b. Human output: role=Some renders the role column. *)
let test_sessions_human_role_rendered () =
  with_temp_dir (fun dir ->
    with_registered_session
      ~dir
      ~session_id:"sid-role-005"
      ~alias:"zzz-test-role"
      ~pid:(Some 99999)
      ~pid_start_time:None
      ~client_type:(Some "claude")
      ~cwd:(Some "/tmp")
      ~role:(Some "coordinator")
      (fun regs ->
        let out = C2c_sessions_format.format_human regs in
        check bool "row has role text" true (string_contains out "coordinator")))

(* 6. Human output: empty registry prints "No sessions.". *)
let test_sessions_human_empty () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    let regs = C2c_mcp.Broker.list_registrations broker in
    check int "empty" 0 (List.length regs);
    let out = C2c_sessions_format.format_human regs in
    check string "no sessions msg" "No sessions.\n" out)

(* 7. JSON output: empty registry is `[]`. *)
let test_sessions_json_empty () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    let regs = C2c_mcp.Broker.list_registrations broker in
    check int "empty" 0 (List.length regs);
    let json = C2c_sessions_format.sessions_to_json regs in
    check string "empty json" "[]" (Yojson.Safe.to_string json))

let json_of_string s =
  try Some (Yojson.Safe.from_string s)
  with _ -> None

let () =
  Alcotest.run
    "c2c sessions"
    [ ( "sessions"
      , [ test_case "json: full shape with all fields populated"
            `Quick test_sessions_json_full_shape
        ; test_case "json: missing optional fields are null"
            `Quick test_sessions_json_optional_fields_null
        ; test_case "json: own-pid registration is alive"
            `Quick test_sessions_json_alive_for_own_pid
        ; test_case "json: empty registry is []"
            `Quick test_sessions_json_empty
        ; test_case "human: full shape with header + data row"
            `Quick test_sessions_human_full_shape
        ; test_case "human: own-pid registration labelled alive"
            `Quick test_sessions_human_alive_for_own_pid
        ; test_case "human: role=Some renders the role column"
            `Quick test_sessions_human_role_rendered
        ; test_case "human: empty registry prints 'No sessions.'"
            `Quick test_sessions_human_empty
        ] )
    ]
