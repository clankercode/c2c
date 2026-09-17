(* test_c2c_relay_b309_disable_consumers — `c2c relay disable` must reach the
   consumers that resolved the relay BEFORE the disable.

   Two classes used to keep going forever:
   (1) a subscribe-daemon started pre-disable retried the parked URL every
       ≤30s (its {"cmd":"shutdown"} IPC command existed but nothing invoked
       it), and
   (2) running `c2c monitor` relay watchers keep the URL they resolved at
       startup (only a restart re-resolves).

   Locked here through the real binary (fixture systemctl, isolated HOME):
   - disable sends {"cmd":"shutdown"} to the subscribe-daemon socket and
     prints ONE line naming both lingering-consumer classes;
   - with no daemon running, the line still names both classes;
   - the durable half: the daemon re-checks Relay_activation each retry
     cycle and stops reconnecting when the relay turned inactive (relay.json
     flipped to enabled:false) instead of retrying the parked URL forever.

   Hermetic: the "daemon" for the disable-side cases is a forked child that
   serves exactly ONE IPC connection from a tmp-dir socket and records the
   received line; the retry-cycle case runs the real daemon binary bound to
   a tmp socket against a closed loopback port (connect-refused, no traffic)
   and SIGTERMs it in a finally handler. *)

open Alcotest

let ( // ) = Filename.concat

let with_temp_dir f =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "c2c-b309-%08x" (Random.bits ()))
  in
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let c2c_exe =
  let e = Sys.executable_name in
  let abs = if Filename.is_relative e then Sys.getcwd () // e else e in
  Filename.dirname (Filename.dirname abs) // "cli" // "c2c.exe"

let read_file_all path =
  if not (Sys.file_exists path) then ""
  else begin
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  end

let write_file path body =
  let rec mkdir_p p =
    if p = "" || p = "/" || Sys.file_exists p then ()
    else (
      mkdir_p (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  output_string oc body;
  close_out oc

let contains ~haystack ~needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec loop i = i + nl <= hl && (String.sub haystack i nl = needle || loop (i + 1)) in
  nl = 0 || loop 0

let count_occurrences ~haystack ~needle =
  let nl = String.length needle in
  let rec loop i acc =
    if i + nl > String.length haystack then acc
    else
      loop (i + 1)
        (if String.sub haystack i nl = needle then acc + 1 else acc)
  in
  loop 0 0

(* Minimal environment (the `env -i` convention of the sibling suites) so no
   C2C_* var of the test runner leaks into the binary under test. *)
let min_env home = [| "PATH=/usr/bin"; "HOME=" ^ home |]

let run_c2c ~home args log =
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process_env c2c_exe (Array.of_list (c2c_exe :: args))
      (min_env home) Unix.stdin fd fd
  in
  Unix.close fd;
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED c -> c
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n

let spawn_c2c ~home args log =
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let pid =
    Unix.create_process_env c2c_exe (Array.of_list (c2c_exe :: args))
      (min_env home) Unix.stdin fd fd
  in
  Unix.close fd;
  pid

let rec wait_until ~what ~deadline_s f =
  if f () then ()
  else if deadline_s <= 0.0 then fail ("timed out waiting for: " ^ what)
  else begin
    Unix.sleepf 0.2;
    wait_until ~what ~deadline_s:(deadline_s -. 0.2) f
  end

let default_socket home = home // ".c2c" // "relay-subscribe.sock"

(* --- (1) disable sends shutdown to a live subscribe-daemon socket --------- *)

(* Forked one-shot IPC daemon: binds the socket, serves exactly ONE
   connection, records the received line, replies ok, exits 0. Watchdog
   alarm exits 3 if disable never connects. *)
let start_fixture_daemon ~socket_path ~capture_path =
  match Unix.fork () with
  | 0 ->
    (try
       (try Unix.unlink socket_path with _ -> ());
       let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Unix.bind sock (Unix.ADDR_UNIX socket_path);
       Unix.listen sock 1;
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> Unix._exit 3));
       Unix.alarm 15 |> ignore;
       let fd, _ = Unix.accept sock in
       Unix.alarm 0 |> ignore;
       let ic = Unix.in_channel_of_descr fd in
       let oc = Unix.out_channel_of_descr fd in
       let line = input_line ic in
       write_file capture_path line;
       output_string oc "{\"ok\":true,\"id\":\"\",\"alias\":\"\"}\n";
       flush oc;
       Unix.close fd;
       Unix.close sock;
       Unix._exit 0
     with _ -> Unix._exit 2)
  | pid -> pid

let test_disable_sends_shutdown_to_daemon () =
  with_temp_dir @@ fun home ->
  write_file (home // ".config" // "c2c" // "relay.json")
    {|{"url":"https://r.b309.example","enabled":true}|};
  (* The real daemon creates ~/.c2c before binding; mirror that for the
     fixture child. *)
  (try Unix.mkdir (home // ".c2c") 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sock = default_socket home in
  let capture = home // "ipc-capture.txt" in
  let child = start_fixture_daemon ~socket_path:sock ~capture_path:capture in
  wait_until ~what:"fixture daemon socket to appear" ~deadline_s:5.0
    (fun () -> Sys.file_exists sock);
  Unix.sleepf 0.2;
  let reaped = ref false in
  let child_status = ref None in
  Fun.protect
    ~finally:(fun () ->
      if not !reaped then begin
        (try Unix.kill child Sys.sigkill with _ -> ());
        (try ignore (Unix.waitpid [] child); reaped := true with _ -> ())
      end)
    (fun () ->
       let out = home // "disable.out" in
       let code = run_c2c ~home [ "relay"; "disable" ] out in
       check bool ("disable exits 0: " ^ read_file_all out) true (code = 0);
       (* Wait for the child to exit on its own, reaping EXACTLY once. *)
       wait_until ~what:"fixture daemon to exit" ~deadline_s:5.0 (fun () ->
         match Unix.waitpid [ Unix.WNOHANG ] child with
         | (0, _) -> false
         | (_, st) ->
             child_status := Some st;
             reaped := true;
             true);
       check bool "fixture daemon answered" true
         (match !child_status with
          | Some (Unix.WEXITED 0) -> true
          | _ -> false);
       let captured = read_file_all capture in
       check bool "shutdown IPC line received by the daemon" true
         (contains ~haystack:captured ~needle:"\"cmd\":\"shutdown\"");
       let output = read_file_all out in
       check bool "consumers line names the daemon as stopped" true
         (contains ~haystack:output ~needle:"subscribe-daemon stopped"))

let test_disable_prints_consumers_line_without_daemon () =
  with_temp_dir @@ fun home ->
  let out = home // "disable.out" in
  let code = run_c2c ~home [ "relay"; "disable" ] out in
  check bool ("disable exits 0: " ^ read_file_all out) true (code = 0);
  let output = read_file_all out in
  check bool "one line names both lingering-consumer classes" true
    (contains ~haystack:output ~needle:"subscribe-daemon"
    && contains ~haystack:output ~needle:"monitor");
  check bool "daemon reported as not running" true
    (contains ~haystack:output ~needle:"no subscribe-daemon running");
  check bool "monitor watchers named as needing restart" true
    (contains ~haystack:output ~needle:"until restarted")

(* --- (2) the daemon stops retrying when the relay turns inactive ----------- *)

(* Forked long-lived IPC client: registers [alias] and HOLDS the connection
   open — aliases die with their IPC client, and the retry-forever defect
   this ticket fixes is only observable with a persistent client (the shape
   of a real harness like pi-c2c's DaemonClient). Watchdog exits 0. *)
let start_fixture_client ~socket_path ~alias ~hold_s =
  match Unix.fork () with
  | 0 ->
    (try
       let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Unix.connect fd (Unix.ADDR_UNIX socket_path);
       let oc = Unix.out_channel_of_descr fd in
       output_string oc
         (Printf.sprintf "{\"cmd\":\"register\",\"alias\":\"%s\",\"id\":\"b309fixture\"}\n"
            alias);
       flush oc;
       Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> Unix._exit 0));
       Unix.alarm hold_s |> ignore;
       let ic = Unix.in_channel_of_descr fd in
       (try while true do ignore (input_line ic) done with _ -> ());
       Unix._exit 0
     with _ -> Unix._exit 2)
  | pid -> pid

let reap ?(kill_first = false) pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | (0, _) ->
      if kill_first then (try Unix.kill pid Sys.sigkill with _ -> ());
      ignore (Unix.waitpid [] pid)
  | (_, _) -> ()

let test_daemon_stops_retries_when_relay_disabled () =
  with_temp_dir @@ fun home ->
  write_file (home // ".config" // "c2c" // "relay.json")
    {|{"url":"http://127.0.0.1:1","enabled":true}|};
  check bool "identity init exits 0" true
    ((run_c2c ~home [ "relay"; "identity"; "init" ]
        (home // "identity.out")) = 0);
  let sock = home // "daemon.sock" in
  let log = home // "daemon.log" in
  let pid =
    spawn_c2c ~home
      [ "relay"; "subscribe-daemon"; "start"; "--socket"; sock ]
      log
  in
  let client =
    ref None (* the long-lived IPC client, started once the daemon listens *)
  in
  Fun.protect
    ~finally:(fun () ->
      (* Hard-bounded cleanup: TERM (the daemon exits cleanly), then KILL. *)
      (try Unix.kill pid Sys.sigterm with _ -> ());
      let dead = ref false in
      for _ = 1 to 20 do
        if not !dead then
          match Unix.waitpid [ Unix.WNOHANG ] pid with
          | (0, _) -> Unix.sleepf 0.25
          | (_, _) -> dead := true
      done;
      if not !dead then begin
        (try Unix.kill pid Sys.sigkill with _ -> ());
        ignore (Unix.waitpid [] pid)
      end;
      match !client with Some c -> reap ~kill_first:true c | None -> ())
    (fun () ->
       wait_until ~what:"daemon to listen" ~deadline_s:10.0
         (fun () ->
            contains ~haystack:(read_file_all log) ~needle:"listening on");
       check bool "daemon pidfile written" true (Sys.file_exists (sock ^ ".pid"));
       client := Some (start_fixture_client ~socket_path:sock ~alias:"b309probe" ~hold_s:60);
       wait_until ~what:"first reconnect attempt" ~deadline_s:15.0
         (fun () ->
            contains ~haystack:(read_file_all log) ~needle:"reconnecting");
       (* The operator flips the relay off (c2c relay disable semantics). *)
       write_file (home // ".config" // "c2c" // "relay.json")
         {|{"url":"http://127.0.0.1:1","enabled":false}|};
       wait_until ~what:"daemon to give up reconnecting" ~deadline_s:20.0
         (fun () ->
            contains ~haystack:(read_file_all log)
              ~needle:"no longer active");
       let before = count_occurrences ~haystack:(read_file_all log) ~needle:"reconnecting" in
       Unix.sleepf 3.0;
       let after = count_occurrences ~haystack:(read_file_all log) ~needle:"reconnecting" in
       check bool "no reconnect attempts after the relay turned inactive"
         true (after = before))

(* --- (3) B341: IPC verbs exit 0 after a successful exchange ---------------- *)

(* B341: each IPC verb opens one connection whose Lwt_io.of_fd channels own
   the fd; the verbs closed the channels AND the raw fd, so the second close
   raised EBADF and cmdliner reported its internal-error exit code 125 after
   the exchange had already succeeded. Reuses the one-shot fixture daemon
   from (1): reads the request, replies ok, exits 0 — so a non-zero verb
   exit here is the close bug, not a failed exchange. Hermetic: tmp-dir
   socket via --socket, never the default ~/.c2c/relay-subscribe.sock. *)
let with_fixture_daemon socket_path capture_path f =
  let child = start_fixture_daemon ~socket_path ~capture_path in
  wait_until ~what:"fixture daemon socket to appear" ~deadline_s:5.0
    (fun () -> Sys.file_exists socket_path);
  Unix.sleepf 0.2;
  let reaped = ref false in
  let child_status = ref None in
  Fun.protect
    ~finally:(fun () ->
      if not !reaped then begin
        (try Unix.kill child Sys.sigkill with _ -> ());
        (try ignore (Unix.waitpid [] child); reaped := true with _ -> ())
      end)
    (fun () ->
       f ();
       (* Wait for the child to exit on its own, reaping EXACTLY once. *)
       wait_until ~what:"fixture daemon to exit" ~deadline_s:5.0 (fun () ->
         match Unix.waitpid [ Unix.WNOHANG ] child with
         | (0, _) -> false
         | (_, st) ->
             child_status := Some st;
             reaped := true;
             true);
       check bool "fixture daemon answered" true
         (match !child_status with
          | Some (Unix.WEXITED 0) -> true
          | _ -> false))

let test_ipc_verb_exits_zero ~cmd ~extra_args () =
  with_temp_dir @@ fun home ->
  let sock = home // "ipc.sock" in
  let capture = home // "ipc-capture.txt" in
  let args =
    [ "relay"; "subscribe-daemon"; cmd ] @ extra_args @ [ "--socket"; sock ]
  in
  with_fixture_daemon sock capture (fun () ->
    let out = home // "verb.out" in
    let code = run_c2c ~home args out in
    check bool
      (Printf.sprintf "%s exits 0 after a successful exchange: %s" cmd
         (read_file_all out))
      true (code = 0);
    check bool (cmd ^ " prints the daemon response") true
      (contains ~haystack:(read_file_all out) ~needle:"\"ok\": true");
    check bool (cmd ^ " request reached the daemon") true
      (contains ~haystack:(read_file_all capture)
         ~needle:("\"cmd\":\"" ^ cmd ^ "\"")))

let test_register_verb_exits_zero () =
  test_ipc_verb_exits_zero ~cmd:"register"
    ~extra_args:[ "--alias"; "b341probe" ] ()

let test_deregister_verb_exits_zero () =
  test_ipc_verb_exits_zero ~cmd:"deregister"
    ~extra_args:[ "--alias"; "b341probe" ] ()

let test_list_verb_exits_zero () =
  test_ipc_verb_exits_zero ~cmd:"list" ~extra_args:[] ()

let test_shutdown_verb_exits_zero () =
  test_ipc_verb_exits_zero ~cmd:"shutdown" ~extra_args:[] ()

let () =
  Random.self_init ();
  run "c2c relay b309 disable consumers"
    [ ( "disable reaches lingering consumers",
        [ test_case "disable sends shutdown to the subscribe-daemon" `Quick
            test_disable_sends_shutdown_to_daemon
        ; test_case "disable prints the consumers line without a daemon" `Quick
            test_disable_prints_consumers_line_without_daemon
        ] )
    ; ( "daemon recheck per retry cycle",
        [ test_case "daemon stops retrying when relay.json flips to enabled:false" `Quick
            test_daemon_stops_retries_when_relay_disabled
        ] )
    ; ( "IPC verbs exit 0 after a successful exchange (B341)",
        [ test_case "register exits 0 after a successful exchange" `Quick
            test_register_verb_exits_zero
        ; test_case "deregister exits 0 after a successful exchange" `Quick
            test_deregister_verb_exits_zero
        ; test_case "list exits 0 after a successful exchange" `Quick
            test_list_verb_exits_zero
        ; test_case "shutdown exits 0 after a successful exchange" `Quick
            test_shutdown_verb_exits_zero
        ] )
    ]
