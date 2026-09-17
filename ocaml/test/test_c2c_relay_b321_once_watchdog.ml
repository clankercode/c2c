(* B321 regression: single-root `c2c relay connect --once` ran bare
   Lwt_main.run (sync t) with no SIGALRM and no run_sync_once — against a
   hanging relay it blocked forever (scripts and CI hang). The machine --once
   path already went through run_sync_once.

   Fix contract: single-root --once goes through run_sync_once too, so the
   sync watchdog bounds the pass and a hang force-exits 3 — and (B307) the
   handler persists the hang-wedge before exiting, so even the one-shot path
   leaves the cooldown basis behind. C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S
   keeps the deadline testable. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b321-test-%d-%d"
       (Unix.getpid ()) (Random.int 1_000_000)) in
  Unix.mkdir dir 0o755;
  dir

let rmrf path =
  let rec aux p =
    match (Unix.lstat p).st_kind with
    | Unix.S_DIR ->
        let entries = Sys.readdir p in
        Array.iter (fun e -> aux (Filename.concat p e)) entries;
        Unix.rmdir p
    | _ -> Unix.unlink p
    | exception _ -> ()
  in
  try aux path with _ -> ()

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let write_eligible_registry broker =
  mkdir_p broker;
  let pid = Unix.getpid () in
  let start =
    match Conn.read_pid_start_time_local pid with
    | Some n -> n
    | None -> failwith "current process must have a readable start time"
  in
  let oc = open_out (Filename.concat broker "registry.json") in
  Yojson.Safe.to_channel oc
    (`List [ `Assoc [ "session_id", `String "fixture-live";
                      "alias", `String "fixture-alias";
                      "pid", `Int pid;
                      "pid_start_time", `Int start ] ]);
  close_out oc

let waitpid_until ~timeout_s pid =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ when Unix.gettimeofday () < deadline ->
        Unix.sleepf 0.02;
        loop ()
    | 0, _ -> None
    | _, status -> Some status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

(* Accept-backlog-only socket: the handshake completes, the request is
   written, nothing ever answers — the relay side of a stuck connection. *)
let hang_socket () =
  let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt sock Unix.SO_REUSEADDR true;
  Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen sock 16;
  let port =
    match Unix.getsockname sock with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "hang_socket: expected INET socket"
  in
  (sock, Printf.sprintf "http://127.0.0.1:%d" port)

let test_once_against_hung_relay_exits_3 () =
  let lsock, url = hang_socket () in
  let tmp = make_tmpdir () in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close lsock with _ -> ();
      rmrf tmp)
    @@ fun () ->
  (* An eligible registration makes the pass actually hit the relay (register
     -> heartbeat path); a zero-work root would never hang. *)
  write_eligible_registry tmp;
  match Unix.fork () with
  | 0 ->
      (* 2s watchdog: the pass must be bounded by it, not by the inline HTTP
         deadline (10s) or by forever. *)
      Unix.putenv "C2C_RELAY_CONNECTOR_SYNC_WATCHDOG_S" "2";
      let code =
        Conn.start ~relay_url:url ~token:None ~identity:None
          ~broker_root:tmp ~node_id:"b321-test" ~heartbeat_ttl:300.0
          ~interval:30.0 ~verbose:false ~once:true
      in
      exit code
  | pid ->
      match waitpid_until ~timeout_s:12.0 pid with
      | Some (Unix.WEXITED 3) -> ()
      | Some (Unix.WEXITED c) ->
          Alcotest.failf
            "--once against a hung relay exited %d — the sync watchdog must \
             force-exit 3 (B321)" c
      | Some status ->
          Alcotest.failf "--once exited abnormally: %s"
            (match status with
             | Unix.WEXITED c -> Printf.sprintf "exit %d" c
             | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
             | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
      | None ->
          Unix.kill pid Sys.sigkill;
          ignore (Unix.waitpid [] pid);
          Alcotest.fail
            "--once against a hung relay blocked forever (no watchdog, B321)";
      (* B307 interplay: the force-exit persisted the hang-wedge first. *)
      match Conn.read_connector_state tmp with
      | Some st ->
          Alcotest.(check bool)
            "--once hang persisted the wedge record before exiting" true
            (st.Conn.cs_wedged_since <> None)
      | None ->
          Alcotest.fail "--once hang left no connector state at all"

let () =
  Alcotest.run "c2c-relay-b321-once-watchdog"
    [ ( "B321 single-root --once watchdog"
      , [ Alcotest.test_case
              "--once against a hung relay force-exits 3" `Quick
              test_once_against_hung_relay_exits_3 ] ) ]
