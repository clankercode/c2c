open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let path = Filename.temp_file "c2c-relay-managed-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)

let write_executable_atomic path body =
  let tmp = path ^ ".new" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc body);
  Unix.chmod tmp 0o700;
  Unix.rename tmp path

let wait_until ?(timeout = 5.0) pred =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 0.05; loop ())
  in
  loop ()

let read_file path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))
  with Sys_error _ -> ""

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let write_registry broker ~session_id ~alias ~client_type =
  mkdir_p broker;
  let oc = open_out (broker // "registry.json") in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    Printf.fprintf oc
      "[{\"session_id\":%S,\"alias\":%S,\"client_type\":%S}]\n"
      session_id alias client_type)

let env_with overrides =
  let keys = List.map fst overrides in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun row ->
      not (List.exists (fun key -> String.starts_with ~prefix:(key ^ "=") row) keys))
  in
  Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) overrides @ inherited)

let spawn_to_log ~env binary args log =
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600 in
  let pid = Unix.create_process_env binary (Array.of_list (binary :: args)) env
      Unix.stdin fd fd in
  Unix.close fd;
  pid

let stop_and_wait pid =
  (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()

let test_binary_discovers_two_repos_and_late_broker () =
  with_temp_dir @@ fun home ->
  let binary = Filename.dirname Sys.executable_name // "c2c.exe" |> Unix.realpath in
  let port = 20_000 + Random.int 10_000 in
  let url = Printf.sprintf "http://127.0.0.1:%d" port in
  let repo_a = home // ".c2c" // "repos" // "aaaa" // "broker" in
  let repo_b = home // ".c2c" // "repos" // "bbbb" // "broker" in
  let relay_log = home // "relay.log" in
  let connector_log = home // "connector.log" in
  write_registry repo_a ~session_id:"b200-sess-a" ~alias:"b200-alpha"
    ~client_type:"codex";
  let server = spawn_to_log ~env:(Unix.environment ()) binary
      [ "relay"; "serve"; "--listen"; Printf.sprintf "127.0.0.1:%d" port;
        "--storage"; "memory" ] relay_log in
  Fun.protect ~finally:(fun () -> stop_and_wait server) @@ fun () ->
  let peers = home // "peers.json" in
  let fetch_peers alias =
    Sys.command (Printf.sprintf "curl -sf %s/list > %s"
      (Filename.quote url) (Filename.quote peers)) = 0
    && String.contains (read_file peers) (String.get alias 0)
    && let body = read_file peers in
       try ignore (Str.search_forward (Str.regexp_string alias) body 0); true
       with Not_found -> false
  in
  check bool "relay ready" true
    (wait_until (fun () -> Sys.command
       (Printf.sprintf "curl -sf %s/health >/dev/null" (Filename.quote url)) = 0));
  let connector_env = env_with [
    "HOME", home;
    "C2C_STATE_HOME", home // "state";
    "XDG_STATE_HOME", home // "xdg";
  ] in
  let connector = spawn_to_log ~env:connector_env binary
      [ "relay"; "connect"; "--all-brokers"; "--broker-root"; repo_a;
        "--relay-url"; url; "--interval"; "1" ] connector_log in
  Fun.protect ~finally:(fun () -> stop_and_wait connector) @@ fun () ->
  check bool "startup broker alias registered" true
    (wait_until (fun () -> fetch_peers "b200-alpha"));
  write_registry repo_b ~session_id:"b200-sess-b" ~alias:"b200-beta"
    ~client_type:"claude";
  check bool "later broker alias dynamically registered" true
    (wait_until ~timeout:8.0 (fun () -> fetch_peers "b200-beta"))

let test_machine_lock_is_name_independent () =
  let old_home = Sys.getenv_opt "HOME" in
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
      Unix.putenv "HOME" "/tmp/c2c-b200-home";
      check string "one machine resource"
        "/tmp/c2c-b200-home/.local/share/c2c/relay-connect"
        (C2c_relay_managed.machine_lock_resource ()))

let test_binary_stamp_detects_atomic_update () =
  with_temp_dir @@ fun dir ->
  let binary = dir // "c2c" in
  write_executable_atomic binary "#!/bin/sh\nexit 0\n";
  let before = C2c_relay_managed.binary_stamp binary in
  write_executable_atomic binary "#!/bin/sh\n# replacement\nexit 0\n";
  let after = C2c_relay_managed.binary_stamp binary in
  check bool "replacement detected" true
    (C2c_relay_managed.binary_changed ~before ~after)

let test_managed_argv_captures_root_and_machine_mode () =
  let argv = C2c_relay_managed.connector_argv
      ~self:"/opt/c2c" ~broker_root:"/repo-a/broker"
      ~relay_url:(Some "https://relay.example") ~interval:17
      ~extra_args:[ "--verbose" ]
  in
  check (list string) "explicit machine connector argv"
    [ "/opt/c2c"; "relay"; "connect"; "--all-brokers";
      "--broker-root"; "/repo-a/broker"; "--relay-url";
      "https://relay.example"; "--interval"; "17"; "--verbose" ] argv

let test_supervisor_restarts_child_on_binary_update () =
  with_temp_dir @@ fun dir ->
  let binary = dir // "fake-c2c" in
  let starts = dir // "starts" in
  let pid_path = dir // "outer.pid" in
  let log_path = dir // "log" in
  let script label =
    Printf.sprintf
      "#!/bin/sh\nprintf '%%s\\n' %s >> %s\ntrap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n"
      (Filename.quote label) (Filename.quote starts)
  in
  write_executable_atomic binary (script "v1");
  match Unix.fork () with
  | 0 ->
      C2c_relay_managed.write_pidfile pid_path (Unix.getpid ());
      exit (C2c_relay_managed.supervise ~self:binary ~argv:[ binary ]
              ~log_path ~pid_path ~foreground:false)
  | supervisor ->
      Fun.protect
        ~finally:(fun () -> try Unix.kill supervisor Sys.sigkill with Unix.Unix_error _ -> ())
        (fun () ->
          check bool "first connector started" true
            (wait_until (fun () -> String.contains (read_file starts) '1'));
          write_executable_atomic binary (script "v2");
          check bool "updated connector started" true
            (wait_until (fun () -> String.contains (read_file starts) '2'));
          Unix.kill supervisor Sys.sigterm;
          let _, status = Unix.waitpid [] supervisor in
          check int "supervisor stops cleanly" 0
            (C2c_relay_managed.child_status_code status))

let () =
  run "c2c relay managed" [
    "machine singleton", [ test_case "resource ignores instance name" `Quick test_machine_lock_is_name_independent ];
    "machine brokers", [ test_case "captures root and enables discovery" `Quick test_managed_argv_captures_root_and_machine_mode ];
    "binary machine brokers", [
      test_case "two repos + late broker" `Slow
        test_binary_discovers_two_repos_and_late_broker;
    ];
    "binary updates", [
      test_case "atomic replacement changes stamp" `Quick test_binary_stamp_detects_atomic_update;
      test_case "supervisor restarts connector" `Slow test_supervisor_restarts_child_on_binary_update;
    ];
  ]
