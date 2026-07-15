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

(* B210: the connector singleton is enforced at the bare `c2c relay connect`
   CLI too (not only the supervisor), so stray connectors cannot storm the
   relay with 429s. Verify exemption for supervised children, exclusive
   acquisition, second-acquire refusal, and release-on-close. *)
let with_home dir f =
  let old_home = Sys.getenv_opt "HOME" in
  let old_env = Sys.getenv_opt C2c_relay_managed.supervised_child_env in
  Fun.protect
    ~finally:(fun () ->
      (match old_home with Some h -> Unix.putenv "HOME" h | None -> ());
      match old_env with
      | Some v -> Unix.putenv C2c_relay_managed.supervised_child_env v
      | None -> (try Unix.putenv C2c_relay_managed.supervised_child_env "" with _ -> ()))
    (fun () -> Unix.putenv "HOME" dir; f ())

let test_singleton_supervised_child_is_exempt () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    Unix.putenv C2c_relay_managed.supervised_child_env "1";
    match C2c_relay_managed.acquire_connector_singleton () with
    | `Exempt -> ()
    | `Acquired _ -> fail "supervised child should be exempt, not acquire"
    | `Already_running -> fail "supervised child should be exempt")

(* POSIX record locks are per-PROCESS, so a second acquire in the same process
   never conflicts. In production every `c2c relay connect` is a separate
   process, so the guard must be exercised ACROSS processes: a child holds the
   lock while the parent attempts to acquire and must be refused. *)
let test_singleton_second_acquire_refused () =
  with_temp_dir @@ fun dir ->
  with_home dir (fun () ->
    Unix.putenv C2c_relay_managed.supervised_child_env "";
    let held_r, held_w = Unix.pipe () in
    let done_r, done_w = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
        (* Child: own the lock, tell the parent, wait for release signal. *)
        Unix.close held_r; Unix.close done_w;
        (match C2c_relay_managed.acquire_connector_singleton () with
         | `Acquired _ ->
             ignore (Unix.write_substring held_w "1" 0 1);
             let b = Bytes.create 1 in
             ignore (Unix.read done_r b 0 1)
         | _ -> ());
        exit 0
    | child ->
        Unix.close held_w; Unix.close done_r;
        Fun.protect
          ~finally:(fun () ->
            (try ignore (Unix.write_substring done_w "1" 0 1) with _ -> ());
            (try Unix.close done_w with _ -> ());
            (try Unix.close held_r with _ -> ());
            (try ignore (Unix.waitpid [] child) with _ -> ()))
          (fun () ->
            let b = Bytes.create 1 in
            check int "child acquired the lock" 1 (Unix.read held_r b 0 1);
            match C2c_relay_managed.acquire_connector_singleton () with
            | `Already_running -> ()
            | `Acquired _ -> fail "second acquire must be refused while child holds it"
            | `Exempt -> fail "unexpected Exempt without env"))

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

(* B212: `c2c restart relay-connect` used to raise an uncaught Not_found because
   the supervised relay-connect config omits the session_id/alias/resume fields
   the harness restart path requires. The fix routes relay-connect through the
   machine lifecycle, gated on [parse_managed_config]/[read_managed_config]. *)

let relay_connect_json ?(relay_url = Some "https://relay.example") ?(interval = 30) () =
  `Assoc [
    ("client", `String "relay-connect");
    ("scope", `String "machine");
    ("supervised", `Bool true);
    ("created_at", `Float 1234.0);
    ("relay_url", (match relay_url with Some u -> `String u | None -> `Null));
    ("interval", `Int interval);
  ]

let test_parse_managed_config_recognises_relay_connect () =
  (match C2c_relay_managed.parse_managed_config
           (relay_connect_json ~relay_url:(Some "https://r.example") ~interval:17 ()) with
   | Some mc ->
       check (option string) "relay url extracted" (Some "https://r.example") mc.C2c_relay_managed.mc_relay_url;
       check int "interval extracted" 17 mc.C2c_relay_managed.mc_interval
   | None -> failf "expected relay-connect config to be recognised");
  (* supervised:true without an explicit relay_url still classifies (url None). *)
  (match C2c_relay_managed.parse_managed_config (relay_connect_json ~relay_url:None ()) with
   | Some mc -> check (option string) "no relay url" None mc.C2c_relay_managed.mc_relay_url
   | None -> failf "expected supervised config to be recognised")

let test_parse_managed_config_rejects_harness_client () =
  (* A harness-client (claude) instance config must NOT be treated as a managed
     relay connector — otherwise restart would hijack it into the daemon path. *)
  let claude_json = `Assoc [
    ("name", `String "sunny"); ("client", `String "claude");
    ("session_id", `String "sid"); ("resume_session_id", `String "sid");
    ("alias", `String "sunny"); ("auto_join_rooms", `String "");
    ("created_at", `Float 1.0);
  ] in
  check bool "claude config is not a managed relay connector" true
    (C2c_relay_managed.parse_managed_config claude_json = None);
  check bool "non-object json rejected" true
    (C2c_relay_managed.parse_managed_config (`String "nope") = None)

let test_read_managed_config_roundtrip () =
  with_temp_dir @@ fun home ->
  let old_home = Sys.getenv_opt "HOME" in
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
      Unix.putenv "HOME" home;
      let name = "relay-connect" in
      let inst = home // ".local" // "share" // "c2c" // "instances" // name in
      mkdir_p inst;
      C2c_relay_managed.write_config ~config_path:(inst // "config.json")
        ~relay_url:(Some "https://relay.example") ~interval:42;
      (match C2c_relay_managed.read_managed_config ~name with
       | Some mc ->
           check (option string) "url round-trips" (Some "https://relay.example")
             mc.C2c_relay_managed.mc_relay_url;
           check int "interval round-trips" 42 mc.C2c_relay_managed.mc_interval
       | None -> failf "expected written relay-connect config to be read back");
      (* Absent instance dir → None, never raises. *)
      check bool "missing instance yields None" true
        (C2c_relay_managed.read_managed_config ~name:"does-not-exist-b212" = None))

let test_stop_supervisor_noop_when_absent () =
  with_temp_dir @@ fun home ->
  let old_home = Sys.getenv_opt "HOME" in
  Fun.protect
    ~finally:(fun () -> match old_home with Some h -> Unix.putenv "HOME" h | None -> ())
    (fun () ->
      Unix.putenv "HOME" home;
      (* No outer.pid recorded → nothing to stop → true, no exception. *)
      check bool "stop with no supervisor returns true" true
        (C2c_relay_managed.stop_supervisor ~name:"relay-connect" ~timeout_s:0.5))

(* Defence-in-depth: the harness config loader must degrade a foreign/managed
   config to None rather than raising Not_found (the original crash site). *)
let test_load_config_opt_degrades_on_relay_connect_shape () =
  let name = Printf.sprintf "b212-loadcfg-%d" (Unix.getpid ()) in
  let dir = C2c_start.instance_dir name in
  mkdir_p dir;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () ->
      let oc = open_out (C2c_start.config_path name) in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc (Yojson.Safe.pretty_to_string (relay_connect_json ())));
      (* Previously raised Not_found (uncaught); must now return None cleanly. *)
      check bool "relay-connect config yields None from harness loader" true
        (C2c_start.load_config_opt name = None))

let () =
  run "c2c relay managed" [
    "B212 relay-connect restart routing", [
      test_case "parse recognises relay-connect config" `Quick
        test_parse_managed_config_recognises_relay_connect;
      test_case "parse rejects harness-client config" `Quick
        test_parse_managed_config_rejects_harness_client;
      test_case "read_managed_config round-trips" `Quick
        test_read_managed_config_roundtrip;
      test_case "stop_supervisor no-op when absent" `Quick
        test_stop_supervisor_noop_when_absent;
      test_case "load_config_opt degrades, no Not_found" `Quick
        test_load_config_opt_degrades_on_relay_connect_shape;
    ];
    "machine singleton", [
      test_case "resource ignores instance name" `Quick test_machine_lock_is_name_independent;
      test_case "B210 supervised child exempt" `Quick test_singleton_supervised_child_is_exempt;
      test_case "B210 second acquire refused, released reacquire" `Quick test_singleton_second_acquire_refused;
    ];
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
