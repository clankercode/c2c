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

let capture_stdout f =
  let tmp = Filename.temp_file "c2c-sessions" ".out" in
  let old_stdout = Unix.dup Unix.stdout in
  Fun.protect
    ~finally:(fun () ->
      Unix.dup2 old_stdout Unix.stdout;
      Unix.close old_stdout;
      (try Sys.remove tmp with _ -> ()))
    (fun () ->
      let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
      Unix.dup2 fd Unix.stdout;
      Unix.close fd;
      f ();
      flush stdout;
      let ic = open_in tmp in
      Fun.protect ~finally:(fun () -> close_in ic)
        (fun () -> really_input_string ic (in_channel_length ic)))

let json_of_string s =
  try Some (Yojson.Safe.from_string s)
  with _ -> None

let test_sessions_human_output () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    C2c_mcp.Broker.register broker
      ~session_id:"sid-alpha-001"
      ~alias:"zzz-test-alpha"
      ~pid:(Some 99999)
      ~pid_start_time:None
      ~client_type:(Some "opencode")
      ~cwd:(Some "/home/user/proj")
      ();
    C2c_mcp.Broker.register broker
      ~session_id:"sid-beta-002"
      ~alias:"zzz-test-beta"
      ~pid:None
      ~pid_start_time:None
      ();
    let regs = C2c_mcp.Broker.list_registrations broker in
    let output = capture_stdout (fun () ->
      List.iter (fun (r : C2c_mcp.registration) ->
        let live_str = match C2c_mcp.Broker.registration_liveness_state r with
          | C2c_mcp.Broker.Alive -> "alive"
          | C2c_mcp.Broker.Dead -> "dead"
          | C2c_mcp.Broker.Unknown -> "?"
        in
        let ct = Option.value r.client_type ~default:"?" in
        let cwd = Option.value r.cwd ~default:"-" in
        Printf.printf "%s\t%s\t%s\t%s\t%s\n"
          r.session_id r.alias ct cwd live_str
      ) regs
    ) in
    check bool "contains sid-alpha-001" true (string_contains output "sid-alpha-001");
    check bool "contains zzz-test-alpha" true (string_contains output "zzz-test-alpha");
    check bool "contains opencode" true (string_contains output "opencode");
    check bool "contains /home/user/proj" true (string_contains output "/home/user/proj");
    check bool "contains sid-beta-002" true (string_contains output "sid-beta-002");
    check bool "contains zzz-test-beta" true (string_contains output "zzz-test-beta"))

let test_sessions_json_output () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    C2c_mcp.Broker.register broker
      ~session_id:"sid-gamma-003"
      ~alias:"zzz-test-gamma"
      ~pid:(Some 99999)
      ~pid_start_time:None
      ~client_type:(Some "claude")
      ~cwd:(Some "/tmp/work")
      ~role:(Some "coordinator")
      ();
    C2c_mcp.Broker.register broker
      ~session_id:"sid-delta-004"
      ~alias:"zzz-test-delta"
      ~pid:None
      ~pid_start_time:None
      ();
    let regs = C2c_mcp.Broker.list_registrations broker in
    let json_items = List.map (fun (r : C2c_mcp.registration) ->
      let live_val = match C2c_mcp.Broker.registration_liveness_state r with
        | C2c_mcp.Broker.Alive -> `Bool true
        | C2c_mcp.Broker.Dead -> `Bool false
        | C2c_mcp.Broker.Unknown -> `Null
      in
      let fields =
        [ ("session_id", `String r.session_id)
        ; ("alias", `String r.alias)
        ; ("client_type", (match r.client_type with Some ct -> `String ct | None -> `Null))
        ; ("cwd", (match r.cwd with Some c -> `String c | None -> `Null))
        ; ("live", live_val)
        ]
      in
      let fields = match r.role with
        | Some role -> fields @ [("role", `String role)]
        | None -> fields
      in
      `Assoc fields
    ) regs in
    let json_str = Yojson.Safe.to_string (`List json_items) in
    (match json_of_string json_str with
     | Some (`List items) ->
        check int "2 items" 2 (List.length items);
        let gamma = List.find (fun item ->
          match Yojson.Safe.Util.(item |> member "session_id") with
          | `String s -> s = "sid-gamma-003"
          | _ -> false) items in
        check string "gamma alias" "zzz-test-gamma"
          Yojson.Safe.Util.(gamma |> member "alias" |> to_string);
        check string "gamma client_type" "claude"
          Yojson.Safe.Util.(gamma |> member "client_type" |> to_string);
        check string "gamma cwd" "/tmp/work"
          Yojson.Safe.Util.(gamma |> member "cwd" |> to_string);
        check string "gamma role" "coordinator"
          Yojson.Safe.Util.(gamma |> member "role" |> to_string);
        let delta = List.find (fun item ->
          match Yojson.Safe.Util.(item |> member "session_id") with
          | `String s -> s = "sid-delta-004"
          | _ -> false) items in
        check string "delta alias" "zzz-test-delta"
          Yojson.Safe.Util.(delta |> member "alias" |> to_string);
        (match Yojson.Safe.Util.(delta |> member "client_type") with
         | `Null -> ()
         | _ -> Alcotest.fail "delta client_type should be null");
        (match Yojson.Safe.Util.(delta |> member "cwd") with
         | `Null -> ()
         | _ -> Alcotest.fail "delta cwd should be null")
     | _ -> Alcotest.fail "failed to parse JSON output"))

let test_sessions_liveness_with_own_pid () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    let my_pid = Unix.getpid () in
    C2c_mcp.Broker.register broker
      ~session_id:"sid-self-pid"
      ~alias:"zzz-test-self"
      ~pid:(Some my_pid)
      ~pid_start_time:(C2c_broker.read_pid_start_time my_pid)
      ~client_type:(Some "opencode")
      ();
    let regs = C2c_mcp.Broker.list_registrations broker in
    check int "one reg" 1 (List.length regs);
    let r = List.hd regs in
    let live = C2c_mcp.Broker.registration_liveness_state r in
    check bool "own pid is alive" true (live = C2c_mcp.Broker.Alive))

let test_sessions_empty_registry () =
  with_temp_dir (fun dir ->
    let broker = C2c_mcp.Broker.create ~root:dir in
    let regs = C2c_mcp.Broker.list_registrations broker in
    check int "empty" 0 (List.length regs);
    let output = capture_stdout (fun () ->
      if regs = [] then Printf.printf "No sessions.\n"
      else List.iter (fun (r : C2c_mcp.registration) ->
        Printf.printf "%s\n" r.session_id) regs
    ) in
    check bool "no sessions msg" true (string_contains output "No sessions"))

let () =
  Alcotest.run
    "c2c sessions"
    [ ( "sessions"
      , [ test_case "human output has session_id + alias + client_type + cwd + liveness"
            `Quick test_sessions_human_output
        ; test_case "json output has expected fields"
            `Quick test_sessions_json_output
        ; test_case "liveness with own pid is alive"
            `Quick test_sessions_liveness_with_own_pid
        ; test_case "empty registry"
            `Quick test_sessions_empty_registry
        ] )
    ]
