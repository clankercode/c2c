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
  let pid = Unix.getpid () in
  let pid_start_time =
    match C2c_broker.read_pid_start_time pid with
    | Some n -> n
    | None -> failwith "cannot read fixture process start time"
  in
  let oc = open_out (broker // "registry.json") in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    Printf.fprintf oc
      "[{\"session_id\":%S,\"alias\":%S,\"client_type\":%S,\"pid\":%d,\"pid_start_time\":%d}]\n"
      session_id alias client_type pid pid_start_time)

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

let wait_status pid =
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

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

let test_binary_skips_historical_registrations () =
  with_temp_dir @@ fun home ->
  let binary = Filename.dirname Sys.executable_name // "c2c.exe" |> Unix.realpath in
  let port = 20_000 + Random.int 10_000 in
  let url = Printf.sprintf "http://127.0.0.1:%d" port in
  let broker = home // ".c2c" // "repos" // "cccc" // "broker" in
  mkdir_p broker;
  let pid = Unix.getpid () in
  let pid_start_time = Option.get (C2c_broker.read_pid_start_time pid) in
  let live = `Assoc [
    "session_id", `String "b201-live-session";
    "alias", `String "b201-live-alias";
    "client_type", `String "codex";
    "pid", `Int pid; "pid_start_time", `Int pid_start_time;
  ] in
  let history = List.init 64 (fun i -> `Assoc [
    "session_id", `String (Printf.sprintf "b201-dead-%d" i);
    "alias", `String (Printf.sprintf "b201-dead-alias-%d" i);
    "pid", `Int (900_000 + i); "pid_start_time", `Int 1;
  ]) in
  let oc = open_out (broker // "registry.json") in
  Yojson.Safe.to_channel oc (`List (live :: history)); close_out oc;
  let relay_log = home // "relay-b201.log" in
  let connector_log = home // "connector-b201.log" in
  let server = spawn_to_log ~env:(Unix.environment ()) binary
      [ "relay"; "serve"; "--listen"; Printf.sprintf "127.0.0.1:%d" port;
        "--storage"; "memory" ] relay_log in
  Fun.protect ~finally:(fun () -> stop_and_wait server) @@ fun () ->
  check bool "relay ready" true (wait_until (fun () ->
    Sys.command (Printf.sprintf "curl -sf %s/health >/dev/null"
      (Filename.quote url)) = 0));
  let child_env = env_with [
    "HOME", home; "C2C_STATE_HOME", home // "state";
    "XDG_STATE_HOME", home // "xdg";
  ] in
  let connector = spawn_to_log ~env:child_env binary
      [ "relay"; "connect"; "--all-brokers"; "--broker-root"; broker;
        "--relay-url"; url; "--once"; "--verbose" ] connector_log in
  (* Unsigned polling is rejected by design, so --once reports a partial
     failure after successful registration. The relay peer list is the
     authoritative proof of which local rows generated registration calls. *)
  check int "connector partial unsigned-poll result" 2 (wait_status connector);
  let peers = home // "b201-peers.json" in
  check int "peer list fetched" 0 (Sys.command (Printf.sprintf
    "curl -sf %s/list > %s" (Filename.quote url) (Filename.quote peers)));
  let body = read_file peers in
  check bool "live row registered" true
    (try ignore (Str.search_forward (Str.regexp_string "b201-live-alias") body 0); true
     with Not_found -> false);
  check bool "no historical row registered" false
    (try ignore (Str.search_forward (Str.regexp_string "b201-dead-alias-") body 0); true
     with Not_found -> false);
  check bool "skip diagnostic counts all history" true
    (try ignore (Str.search_forward
       (Str.regexp_string "skipped 64 dead/unverified historical")
       (read_file connector_log) 0); true with Not_found -> false)

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

(* B212: `c2c restart relay-connect` resolves its relaunch parameters from the
   connector's persisted supervisor config.json. relay_url comes from the
   config, falling back to $C2C_RELAY_URL when the config stored a null
   (env-driven start), and errors clearly when neither is available — so the
   restart path never crashes with the old uncaught Not_found. *)
(* Set [key] to [value] for the duration of [f], restoring the prior value on
   exit. There is no portable Unix.unsetenv, so an originally-unset var is
   restored to "" — which instances_dir/restart_params treat as unset. *)
let with_env key value f =
  let saved = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect ~finally:(fun () -> Unix.putenv key (Option.value saved ~default:"")) f

let with_relay_url_env value f =
  with_env "C2C_RELAY_URL" (Option.value value ~default:"") f

let test_restart_params_uses_config_relay_url () =
  with_relay_url_env None @@ fun () ->
  let fields =
    [ ("client", `String "relay-connect");
      ("relay_url", `String "https://relay.example");
      ("interval", `Int 17) ]
  in
  match C2c_relay_managed.restart_params_of_config fields with
  | Ok (url, interval) ->
      check (option string) "relay url from config" (Some "https://relay.example") url;
      check int "interval from config" 17 interval
  | Error msg -> failf "expected Ok, got Error: %s" msg

let test_restart_params_falls_back_to_env () =
  with_relay_url_env (Some "https://env-relay.example") @@ fun () ->
  (* Connector started from $C2C_RELAY_URL persists relay_url as null. *)
  let fields = [ ("client", `String "relay-connect"); ("relay_url", `Null) ] in
  match C2c_relay_managed.restart_params_of_config fields with
  | Ok (url, interval) ->
      check (option string) "relay url from env fallback"
        (Some "https://env-relay.example") url;
      check int "interval defaults to 30" 30 interval
  | Error msg -> failf "expected Ok, got Error: %s" msg

let test_restart_params_errors_without_url () =
  with_relay_url_env None @@ fun () ->
  let fields = [ ("client", `String "relay-connect"); ("relay_url", `Null) ] in
  match C2c_relay_managed.restart_params_of_config fields with
  | Ok _ -> fail "expected Error when no relay URL is known"
  | Error msg ->
      check bool "error names the explicit-restart command" true
        (try ignore (Str.search_forward
                       (Str.regexp_string "c2c start relay-connect") msg 0); true
         with Not_found -> false)

(* B212: the connector's supervisor-lifecycle paths (outer.pid, machine lock)
   must honor $C2C_INSTANCES_DIR with the same resolution `c2c restart` uses to
   find config.json. Otherwise restart reads config from the override dir but
   signals the outer.pid under $HOME — killing the real machine supervisor. *)
let test_instances_dir_honors_env () =
  with_env "C2C_INSTANCES_DIR" "/tmp/c2c-b212-custom/instances" @@ fun () ->
  check string "instances_dir honors C2C_INSTANCES_DIR"
    "/tmp/c2c-b212-custom/instances" (C2c_relay_managed.instances_dir ());
  check string "machine lock isolated under the override base"
    "/tmp/c2c-b212-custom/relay-connect"
    (C2c_relay_managed.machine_lock_resource ());
  let home_default =
    Filename.concat (Sys.getenv "HOME") (".local" // "share" // "c2c" // "instances")
  in
  check bool "connector pid path is NOT under the real HOME default" false
    (String.starts_with ~prefix:home_default
       (C2c_relay_managed.connector_pid_path ~name:"relay-connect"))

let test_instances_dir_defaults_to_home_when_unset () =
  with_env "HOME" "/tmp/c2c-b212-home" @@ fun () ->
  with_env "C2C_INSTANCES_DIR" "" @@ fun () ->
  check string "instances_dir falls back to HOME default (production unchanged)"
    "/tmp/c2c-b212-home/.local/share/c2c/instances"
    (C2c_relay_managed.instances_dir ());
  check string "machine lock unchanged under HOME default"
    "/tmp/c2c-b212-home/.local/share/c2c/relay-connect"
    (C2c_relay_managed.machine_lock_resource ())

(* Behavioral proof: restart's stop step signals ONLY the supervisor recorded
   under $C2C_INSTANCES_DIR (via connector_pid_path) and never touches an
   outer.pid under the HOME-based path. *)
let test_restart_stop_targets_only_env_instances_dir () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let custom_inst = root // "custom" // "instances" in
  with_env "HOME" home @@ fun () ->
  with_env "C2C_INSTANCES_DIR" custom_inst @@ fun () ->
  let name = "relay-connect" in
  let env_pid_path = C2c_relay_managed.connector_pid_path ~name in
  let home_pid_path =
    home // ".local" // "share" // "c2c" // "instances" // name // "outer.pid"
  in
  mkdir_p (Filename.dirname env_pid_path);
  mkdir_p (Filename.dirname home_pid_path);
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let spawn () = Unix.create_process "sleep" [| "sleep"; "30" |] devnull devnull devnull in
  let env_pid = spawn () in
  let home_pid = spawn () in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close devnull with _ -> ());
      List.iter
        (fun p ->
          (try Unix.kill p Sys.sigkill with _ -> ());
          (try ignore (Unix.waitpid [] p) with _ -> ()))
        [ env_pid; home_pid ])
    (fun () ->
      C2c_relay_managed.write_pidfile env_pid_path env_pid;
      C2c_relay_managed.write_pidfile home_pid_path home_pid;
      (* stop resolves its pid path exactly as restart does *)
      C2c_relay_managed.stop_supervisor ~name
        ~pid_path:(C2c_relay_managed.connector_pid_path ~name) ~timeout_s:1.0;
      let env_reaped, _ = Unix.waitpid [ Unix.WNOHANG ] env_pid in
      check bool "env-instances-dir supervisor was stopped" true (env_reaped = env_pid);
      let home_reaped, _ = Unix.waitpid [ Unix.WNOHANG ] home_pid in
      check int "HOME-path supervisor untouched (still running)" 0 home_reaped;
      check bool "connector pid path resolves under the override" true
        (String.starts_with ~prefix:custom_inst env_pid_path);
      check bool "connector pid path is NOT under HOME" false
        (String.starts_with ~prefix:(home // ".local") env_pid_path))

let () =
  run "c2c relay managed" [
    "B212 restart params", [
      test_case "relay url from config" `Quick test_restart_params_uses_config_relay_url;
      test_case "relay url falls back to env" `Quick test_restart_params_falls_back_to_env;
      test_case "clear error when no url" `Quick test_restart_params_errors_without_url;
    ];
    "B212 instances-dir isolation", [
      test_case "instances_dir + lock honor C2C_INSTANCES_DIR" `Quick test_instances_dir_honors_env;
      test_case "unset falls back to HOME default" `Quick test_instances_dir_defaults_to_home_when_unset;
      test_case "restart stop targets only the env instances dir" `Slow test_restart_stop_targets_only_env_instances_dir;
    ];
    "machine singleton", [ test_case "resource ignores instance name" `Quick test_machine_lock_is_name_independent ];
    "machine brokers", [ test_case "captures root and enables discovery" `Quick test_managed_argv_captures_root_and_machine_mode ];
    "binary machine brokers", [
      test_case "two repos + late broker" `Slow
        test_binary_discovers_two_repos_and_late_broker;
    ];
    "B201 binary relay eligibility", [
      test_case "64 historical rows never reach relay" `Slow
        test_binary_skips_historical_registrations;
    ];
    "binary updates", [
      test_case "atomic replacement changes stamp" `Quick test_binary_stamp_detects_atomic_update;
      test_case "supervisor restarts connector" `Slow test_supervisor_restarts_child_on_binary_update;
    ];
  ]
