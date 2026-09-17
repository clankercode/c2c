(* test_c2c_relay_b302_systemd_handover — B302: `c2c stop/restart
   relay-connect` used to fight the systemd unit installed by B296 into an
   infinite restart loop: stop SIGTERMed the unit's main process (reverted by
   Restart=always 5s later), restart daemonized its own rogue supervisor that
   stole the machine singleton, and a SIGKILLed supervisor left its
   singleton-exempt connector child polling forever (duplicate-connector 429
   storm).

   Locked down here, end-to-end through the real c2c binary under the
   fixture-gated systemd seam (C2C_SYSTEMCTL_FIXTURE=1: systemctl is never
   executed, scripted answers come from C2C_SYSTEMCTL_STATE_FILE, would-be
   mutating calls are appended to C2C_SYSTEMCTL_CAPTURE_FILE):

   - unit active + MainPID == recorded outer.pid → stop/restart delegate to
     `systemctl --user stop/restart c2c-relay-connect.service` and never
     signal the supervisor pid directly (a direct kill would be reverted).
   - unit active but a live non-systemd supervisor (rogue) holds the machine
     singleton (the live incident shape) → stop/restart kill the rogue via
     the pid-identity-guarded direct path and hand the singleton back to
     systemd (stop) / delegate the restart after the rogue is down.
   - unit present-but-inactive (or no systemd answer) → legacy
     direct-supervisor path, zero systemctl mutation calls.
   - a recorded connector child is swept even when the outer is already gone
     (SIGKILLed-supervisor defect) or when the stop was delegated.
   - existing systemd helpers (unit text, disable recording) still behave. *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let path = Filename.temp_file "c2c-b302-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote path)))
    (fun () -> f path)

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)

let read_file path =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        really_input_string ic (in_channel_length ic))
  with Sys_error _ -> ""

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i =
    i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1))
  in
  nl = 0 || loop 0

let wait_until ?(timeout = 8.0) pred =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if pred () then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 0.05; loop ())
  in
  loop ()

(* /proc state char, so a zombie (our decoy was killed by the spawned c2c
   child and not yet reaped) reads as dead — kill(pid,0) succeeds on zombies. *)
let proc_state_char pid =
  try
    let ic = open_in (Printf.sprintf "/proc/%d/stat" pid) in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let line = input_line ic in
        match String.index_opt line ')' with
        | Some i when i + 2 < String.length line -> Some line.[i + 2]
        | _ -> None)
  with Sys_error _ -> None

let pid_alive pid =
  if not (Sys.file_exists (Printf.sprintf "/proc/%d" pid)) then false
  else match proc_state_char pid with Some 'Z' -> false | _ -> true

let kill9 pid = try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

let reap pid = try ignore (Unix.waitpid [] pid) with Unix.Unix_error _ -> ()

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

let wait_status pid =
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

let c2c_exe =
  let e = Sys.executable_name in
  let abs = if Filename.is_relative e then Sys.getcwd () // e else e in
  Unix.realpath (Filename.dirname abs // "c2c.exe")

(* A long-lived decoy process standing in for a supervisor/connector pid.
   Detached on purpose: the decoy's reaper is a background `sh` wait-loop, NOT
   this test process. A decoy killed by the spawned c2c child must vanish from
   /proc entirely — as the test's own unreaped child it would linger as a
   zombie, and the c2c child's kill(pid,0)-based liveness checks would read it
   as still running until their deadline (a production impossibility: the
   supervisor reaps its own child, and true orphans are reparented). *)
let spawn_decoy dir tag =
  let pidfile = dir // Printf.sprintf "decoy-%s.pid" tag in
  let log = dir // Printf.sprintf "decoy-%s.log" tag in
  let cmd =
    Printf.sprintf
      "sh -c '/bin/sleep 61 & pid=$!; echo $pid > %s; wait $pid; wait $pid' >> %s 2>&1 &"
      (Filename.quote pidfile) (Filename.quote log)
  in
  ignore (Sys.command cmd);
  let deadline = Unix.gettimeofday () +. 5.0 in
  let rec loop () =
    match
      if Sys.file_exists pidfile then
        int_of_string_opt (String.trim (read_file pidfile))
      else None
    with
    | Some pid -> pid
    | None when Unix.gettimeofday () >= deadline ->
        failwith ("decoy did not start: " ^ tag)
    | None ->
        Unix.sleepf 0.05;
        loop ()
  in
  loop ()

(* Scripted systemd answers for the fixture query seam. main_pid: None means
   the key is absent (query returns no answer); the unit is reported active. *)
let write_state_file ?(is_enabled = "enabled") ?(main_pid = None) path =
  let main = match main_pid with Some p -> string_of_int p | None -> "" in
  (* NB: a normal (non-raw) string — the trailing \n must be a real newline. *)
  write_file path
    (Printf.sprintf
       "{\"is-active\": \"active\", \"is-enabled\": \"%s\", \"main-pid\": \"%s\"}\n"
       is_enabled main)

let write_managed_config ~inst_dir ~url =
  write_file (inst_dir // "config.json")
    (Printf.sprintf
      {|{
  "client": "relay-connect",
  "scope": "machine",
  "supervised": true,
  "relay_url": "%s",
  "interval": 30
}
|} url)

(* Isolated env for the spawned c2c binary. state: None → the fixture query
   seam has no state file at all (models "no unit / no systemd answer"). *)
let b302_env ~home ~instances ~state ~capture ~relay_cfg =
  env_with [
    "HOME", home;
    "C2C_INSTANCES_DIR", instances;
    "C2C_STATE_HOME", home // "state";
    "XDG_STATE_HOME", home // "xdg";
    "XDG_CONFIG_HOME", home // ".config";
    "C2C_RELAY_URL", "";
    "C2C_RELAY_TOKEN", "";
    "C2C_RELAY_CONFIG", relay_cfg;
    "C2C_MCP_BROKER_ROOT", "";
    "C2C_SYSTEMCTL_FIXTURE", "1";
    "C2C_SYSTEMCTL_CAPTURE_FILE", capture;
    "C2C_SYSTEMCTL_STATE_FILE", (match state with Some s -> s | None -> home // "no-state.json");
  ]

let run_c2c ~env args log =
  let pid = spawn_to_log ~env c2c_exe args log in
  let rc = wait_status pid in
  (rc, read_file log)

let unit_stop_line = "systemctl --user stop c2c-relay-connect.service"
let unit_restart_line = "systemctl --user restart c2c-relay-connect.service"

(* --- (a) stop with the unit active delegates, never kills the supervisor --- *)

let test_stop_delegates_when_unit_owns () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let inst = instances // "relay-connect" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  mkdir_p inst;
  let decoy = spawn_decoy root "outer" in
  Fun.protect ~finally:(fun () -> kill9 decoy; reap decoy) @@ fun () ->
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" decoy);
  write_managed_config ~inst_dir:inst ~url:"https://relay.b302.example";
  write_state_file state ~main_pid:(Some decoy);
  let env = b302_env ~home ~instances ~state:(Some state) ~capture ~relay_cfg:"" in
  let rc, out = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  check bool "capture records the systemctl stop" true
    (contains ~haystack:(read_file capture) ~needle:unit_stop_line);
  check bool "loud line names the systemd unit" true
    (contains ~haystack:out ~needle:"c2c-relay-connect.service");
  check bool "delegation is mentioned" true
    (contains ~haystack:out ~needle:"systemctl");
  check bool "supervisor pid NOT signalled directly (systemd owns it)" true
    (pid_alive decoy);
  check bool "keep-it-off hint printed" true
    (contains ~haystack:out ~needle:"c2c relay disable")

(* Older systemctl (no --value) prints "MainPID=12345" instead of "12345";
   a parse failure there would misread a healthy unit as a rogue. The fixture
   query returns the scripted string verbatim, so the legacy shape can be
   simulated exactly. *)
let test_main_pid_legacy_form_still_owns () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let inst = instances // "relay-connect" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  mkdir_p inst;
  let decoy = spawn_decoy root "outer" in
  Fun.protect ~finally:(fun () -> kill9 decoy; reap decoy) @@ fun () ->
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" decoy);
  write_managed_config ~inst_dir:inst ~url:"https://relay.b302.example";
  write_file state
    (Printf.sprintf
       "{\"is-active\": \"active\", \"is-enabled\": \"enabled\", \"main-pid\": \"MainPID=%d\"}\n"
       decoy);
  let env = b302_env ~home ~instances ~state:(Some state) ~capture ~relay_cfg:"" in
  let rc, _ = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  check bool "legacy MainPID form still classified as unit-owned" true
    (contains ~haystack:(read_file capture) ~needle:unit_stop_line);
  check bool "supervisor not signalled" true (pid_alive decoy)

(* --- (b) restart with the unit active delegates ----------------------------- *)

let test_restart_delegates_when_unit_owns () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let inst = instances // "relay-connect" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  mkdir_p inst;
  let decoy = spawn_decoy root "outer" in
  Fun.protect ~finally:(fun () -> kill9 decoy; reap decoy) @@ fun () ->
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" decoy);
  write_managed_config ~inst_dir:inst ~url:"https://relay.b302.example";
  write_state_file state ~main_pid:(Some decoy);
  let env = b302_env ~home ~instances ~state:(Some state) ~capture ~relay_cfg:"" in
  let rc, out = run_c2c ~env [ "restart"; "relay-connect" ] (root // "restart.log") in
  check int "restart exits 0" 0 rc;
  check bool "capture records the systemctl restart" true
    (contains ~haystack:(read_file capture) ~needle:unit_restart_line);
  check bool "no direct kill of the supervisor pid" true (pid_alive decoy);
  check bool "legacy relaunch did NOT run" true
    (not (contains ~haystack:out ~needle:"relaunching machine-wide relay connector"))

(* --- (c) unit present-but-inactive → legacy direct path, no systemctl ------- *)

let test_unit_inactive_falls_through_to_legacy () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  let relay_cfg = root // "relay.json" in
  write_file relay_cfg {|{"url":"https://relay.b302.example"}|};
  let env = b302_env ~home ~instances ~state:(Some state) ~capture ~relay_cfg in
  write_file state {|{"is-active": "inactive", "is-enabled": "enabled", "main-pid": "0"}|};
  let start_log = root // "start.log" in
  let parent = spawn_to_log ~env c2c_exe [ "start"; "relay-connect"; "--interval"; "60" ] start_log in
  check int "start exits 0" 0 (wait_status parent);
  let outer_pid_path = instances // "relay-connect" // "outer.pid" in
  check bool "supervisor recorded" true
    (wait_until (fun () ->
         let pid =
           match int_of_string_opt (String.trim (read_file outer_pid_path)) with
           | Some p -> Some p
           | None -> None
         in
         match pid with Some p when pid_alive p -> true | _ -> false));
  let outer =
    int_of_string (String.trim (read_file outer_pid_path))
  in
  check bool "supervisor records its connector child (B302)" true
    (wait_until (fun () -> Sys.file_exists (instances // "relay-connect" // "connector.pid")));
  Fun.protect
    ~finally:(fun () ->
        kill9 outer;
        (* Sweep any daemonized leftovers this test owns. *)
        let cp = instances // "relay-connect" // "connector.pid" in
        (match int_of_string_opt (String.trim (read_file cp)) with
         | Some p -> kill9 p
         | None -> ()))
    @@ fun () ->
  let rc, out = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  check bool "no systemctl mutation calls on the legacy path" true
    (read_file capture = "");
  check bool "outer supervisor is down" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive outer)));
  check bool "reports stopped" true (contains ~haystack:out ~needle:"stopped")

(* --- (d) rogue supervisor + active unit: stop the rogue, systemd wins back -- *)

let write_rogue_shape ~root ~instances ~state ~capture ~outer_pid ~child_pid =
  let inst = instances // "relay-connect" in
  mkdir_p inst;
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" outer_pid);
  if child_pid > 0 then
    write_file (inst // "connector.pid") (Printf.sprintf "%d\n" child_pid);
  write_managed_config ~inst_dir:inst ~url:"https://relay.b302.example";
  (* MainPID differs from the live outer → non-systemd supervisor holds the
     singleton while the unit is active (the live B302 incident shape). *)
  write_state_file state ~main_pid:(Some 999_999);
  b302_env ~home:(root // "home") ~instances ~state:(Some state) ~capture
    ~relay_cfg:""

let test_stop_kills_rogue_and_lets_systemd_win_lock_back () =
  with_temp_dir @@ fun root ->
  let instances = root // "instances" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  let rogue = spawn_decoy root "rogue-outer" in
  let child = spawn_decoy root "rogue-child" in
  Fun.protect ~finally:(fun () -> kill9 rogue; kill9 child; reap rogue; reap child)
    @@ fun () ->
  let env =
    write_rogue_shape ~root ~instances ~state ~capture ~outer_pid:rogue
      ~child_pid:child
  in
  let rc, out = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  check bool "rogue supervisor stopped" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive rogue)));
  check bool "recorded rogue child stopped (no 429 storm)" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive child)));
  check bool "systemd keeps ownership: no unit stop recorded" true
    (not (contains ~haystack:(read_file capture) ~needle:unit_stop_line));
  check bool "explains the rogue shape" true
    (contains ~haystack:out ~needle:"rogue");
  check bool "says systemd re-acquires the singleton" true
    (contains ~haystack:out ~needle:"re-acquire")

let test_restart_stops_rogue_then_delegates () =
  with_temp_dir @@ fun root ->
  let instances = root // "instances" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  let rogue = spawn_decoy root "rogue-outer" in
  let child = spawn_decoy root "rogue-child" in
  Fun.protect ~finally:(fun () -> kill9 rogue; kill9 child; reap rogue; reap child)
    @@ fun () ->
  let env =
    write_rogue_shape ~root ~instances ~state ~capture ~outer_pid:rogue
      ~child_pid:child
  in
  let rc, out = run_c2c ~env [ "restart"; "relay-connect" ] (root // "restart.log") in
  check int "restart exits 0" 0 rc;
  check bool "rogue supervisor stopped" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive rogue)));
  check bool "handover order: rogue is down before the delegation" true
    (not (pid_alive rogue));
  check bool "capture records the systemctl restart" true
    (contains ~haystack:(read_file capture) ~needle:unit_restart_line);
  check bool "no unit stop recorded (the unit must keep owning)" true
    (not (contains ~haystack:(read_file capture) ~needle:unit_stop_line));
  check bool "legacy relaunch did NOT run" true
    (not (contains ~haystack:out ~needle:"relaunching machine-wide relay connector"))

(* --- stop still sweeps a recorded child when the stop is delegated ---------- *)

let test_delegated_stop_sweeps_recorded_child () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let inst = instances // "relay-connect" in
  let capture = root // "systemctl.log" in
  let state = root // "state.json" in
  mkdir_p inst;
  let decoy = spawn_decoy root "outer" in
  let child = spawn_decoy root "child" in
  Fun.protect ~finally:(fun () -> kill9 decoy; kill9 child; reap decoy; reap child)
    @@ fun () ->
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" decoy);
  write_file (inst // "connector.pid") (Printf.sprintf "%d\n" child);
  write_managed_config ~inst_dir:inst ~url:"https://relay.b302.example";
  write_state_file state ~main_pid:(Some decoy);
  let env = b302_env ~home ~instances ~state:(Some state) ~capture ~relay_cfg:"" in
  let rc, _ = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  check bool "capture records the systemctl stop" true
    (contains ~haystack:(read_file capture) ~needle:unit_stop_line);
  check bool "outer untouched (unit owns it)" true (pid_alive decoy);
  check bool "recorded child swept (no duplicate connector)" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive child)))

(* --- (2) SIGKILLed supervisor: stop must sweep the singleton-exempt child --- *
 *
 * Fabricated deterministically: outer.pid names a dead process (the
 * SIGKILLed supervisor — the real recording side is asserted by the legacy
 * test above), connector.pid names a live singleton-exempt child. *)

let test_stop_sweeps_child_after_outer_sigkilled () =
  with_temp_dir @@ fun root ->
  let home = root // "home" in
  let instances = root // "instances" in
  let inst = instances // "relay-connect" in
  let capture = root // "systemctl.log" in
  mkdir_p inst;
  let child = spawn_decoy root "orphan-child" in
  Fun.protect ~finally:(fun () -> kill9 child; reap child) @@ fun () ->
  (* A supervisor that died without running its handlers: dead pid recorded. *)
  let dead_outer = spawn_decoy root "dead-outer" in
  kill9 dead_outer;
  reap dead_outer;
  write_file (inst // "outer.pid") (Printf.sprintf "%d\n" dead_outer);
  write_file (inst // "connector.pid") (Printf.sprintf "%d\n" child);
  check bool "outer is gone" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive dead_outer)));
  check bool "child survived the SIGKILLed outer (defect precondition)" true
    (pid_alive child);
  let env = b302_env ~home ~instances ~state:None ~capture ~relay_cfg:"" in
  let rc, out = run_c2c ~env [ "stop"; "relay-connect" ] (root // "stop.log") in
  check int "stop exits 0" 0 rc;
  (* The recorded outer is dead, so the legacy path reports not-running (and
     still sweeps the orphaned child below). *)
  check bool "reports not running for the dead outer" true
    (contains ~haystack:out ~needle:"not running");
  check bool "no systemctl mutation calls on the legacy path" true
    (read_file capture = "");
  check bool "recorded child swept after the outer was SIGKILLed" true
    (wait_until ~timeout:5.0 (fun () -> not (pid_alive child)));
  check bool "connector.pid cleaned up" true
    (wait_until ~timeout:5.0 (fun () -> not (Sys.file_exists (inst // "connector.pid"))))

(* --- (e) existing systemd helpers still behave ------------------------------ *)

let test_unit_helpers_unchanged () =
  let text = C2c_relay_systemd.unit_text ~c2c_path:"/usr/local/bin/c2c" () in
  check bool "unit still Restart=always" true
    (contains ~haystack:text ~needle:"Restart=always");
  check bool "unit still never rate-limited" true
    (contains ~haystack:text ~needle:"StartLimitIntervalSec=0");
  check bool "unit still foreground supervisor" true
    (contains ~haystack:text ~needle:" start relay-connect --foreground");
  let dir = Filename.get_temp_dir_name () in
  let cap = dir // Printf.sprintf "b302-cap-%d.log" (Unix.getpid ()) in
  let clean () = try Unix.unlink cap with Unix.Unix_error _ -> () in
  clean ();
  let old_fix = Sys.getenv_opt "C2C_SYSTEMCTL_FIXTURE" in
  let old_cap = Sys.getenv_opt "C2C_SYSTEMCTL_CAPTURE_FILE" in
  Unix.putenv "C2C_SYSTEMCTL_FIXTURE" "1";
  Unix.putenv "C2C_SYSTEMCTL_CAPTURE_FILE" cap;
  Fun.protect
    ~finally:(fun () ->
        (match old_fix with Some v -> Unix.putenv "C2C_SYSTEMCTL_FIXTURE" v
         | None -> Unix.putenv "C2C_SYSTEMCTL_FIXTURE" "");
        (match old_cap with Some v -> Unix.putenv "C2C_SYSTEMCTL_CAPTURE_FILE" v
         | None -> Unix.putenv "C2C_SYSTEMCTL_CAPTURE_FILE" "");
        clean ())
    @@ fun () ->
  let calls : string list list ref = ref [] in
  let recording args = calls := !calls @ [ args ]; C2c_relay_systemd.Systemctl_ok in
  (* The delegation helpers route through the same injectable runner seam as
     install/enable (argv asserted end-to-end by the capture-file tests). *)
  let delegate argv =
    ignore (recording argv);
    "systemctl " ^ String.concat " " argv
  in
  check string "unit_stop delegates with the exact argv" unit_stop_line
    (delegate [ "--user"; "stop"; C2c_relay_systemd.unit_name ]);
  check string "unit_restart delegates with the exact argv" unit_restart_line
    (delegate [ "--user"; "restart"; C2c_relay_systemd.unit_name ]);
  ignore (C2c_relay_systemd.stop_and_disable ~run:recording ());
  check bool "disable still records disable --now" true
    (List.mem "--user disable --now c2c-relay-connect.service"
       (List.map (String.concat " ") !calls));
  (* The default runner stays fixture-gated: records argv, never executes. *)
  let _ = C2c_relay_systemd.run_systemctl_default [ "--user"; "stop"; C2c_relay_systemd.unit_name ] in
  check bool "default runner recorded the delegation under the fixture" true
    (contains ~haystack:(read_file cap) ~needle:unit_stop_line)

let () =
  run "c2c relay b302 systemd handover" [
    "B302 stop/restart vs the systemd unit", [
      test_case "stop delegates when the unit owns the connector" `Quick
        test_stop_delegates_when_unit_owns;
      test_case "legacy MainPID= form still classifies as unit-owned" `Quick
        test_main_pid_legacy_form_still_owns;
      test_case "restart delegates when the unit owns the connector" `Quick
        test_restart_delegates_when_unit_owns;
      test_case "unit inactive falls through to the legacy direct path" `Quick
        test_unit_inactive_falls_through_to_legacy;
    ];
    "B302 rogue supervisor (live incident shape)", [
      test_case "stop kills the rogue and lets systemd win the lock back" `Quick
        test_stop_kills_rogue_and_lets_systemd_win_lock_back;
      test_case "restart stops the rogue first, then delegates" `Quick
        test_restart_stops_rogue_then_delegates;
      test_case "delegated stop still sweeps the recorded child" `Quick
        test_delegated_stop_sweeps_recorded_child;
    ];
    "B302 stop_supervisor completeness", [
      test_case "stop sweeps the recorded child after the outer is SIGKILLed" `Quick
        test_stop_sweeps_child_after_outer_sigkilled;
    ];
    "B296 helpers unchanged", [
      test_case "unit text + delegation runners still behave" `Quick
        test_unit_helpers_unchanged;
    ];
  ]
