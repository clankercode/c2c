(* B319 regression: the machine loop's noop path records progress but must
   ALSO reset the in-memory wedge bookkeeping (wedge_counts / cooldowns),
   exactly like the progress branch does.

   Pre-fix, a root that wedged (count N), went idle (registrations die ->
   B291 noop passes), then re-registered and erred again resumed at N+1:
   the first wedge of the new epoch paid the stale doubling schedule (up to
   the 2h cap) while the state file (which the noop write resets) and the
   in-memory tables disagreed.

   Driven entirely through the start_machine_impl seams (sync_once +
   discover_roots), hermetically, in a forked child:

   pass 1-3  root errors with a watchdog timeout -> wedge #1 (count 1),
             short cooldown via C2C_RELAY_CONNECTOR_WEDGE_COOLDOWN_BASE_S;
   pass 3    sync_once removes the root's eligible registry -> idle epoch;
   pass 4    root takes the NOOP branch (records progress, writes a fresh
             ok state - this is the arm under test);
   pass 4    conductor root observes the ok state and RE-ARMS the root
             (writes an eligible registry back), emitting "R" on the pipe;
   pass 5-7  root errors again -> wedge #2. With the fix the noop pass
             cleared the stale count, so wedge #2 is count 1, not 2. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b319-test-%d-%d"
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

(* The machine loop's B291 gate skips zero-work roots before sync_once runs,
   so every root needs an eligible registration with a LIVE pid - here the
   forked loop child, which stays alive for the whole test. *)
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

(* Drain until at least [at_least] marker bytes arrive or the deadline passes. *)
let drain_until fd ~at_least ~deadline_s =
  Unix.set_nonblock fd;
  let buf = Buffer.create 32 in
  let chunk = Bytes.create 64 in
  let deadline = Unix.gettimeofday () +. deadline_s in
  let rec loop () =
    if Buffer.length buf >= at_least || Unix.gettimeofday () >= deadline then
      Buffer.contents buf
    else begin
      (match Unix.read fd chunk 0 64 with
       | n -> Buffer.add_subbytes buf chunk 0 n
       | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> ());
      Unix.sleepf 0.02;
      loop ()
    end
  in
  loop ()

let count_char c s =
  String.to_seq s |> Seq.filter (fun x -> x = c) |> Seq.length

let ok_result () : Conn.sync_result =
  { registered = []; registered_sessions = []; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; inbound_rejected_note = None;
    alerts_emitted = 0; rate_limited = false; retry_after_s = None;
    last_error = None; errors = [] }

(* True once a NOOP pass has rewritten the root's state: fresh ok state,
   no recorded error, wedge record cleared by write_connector_state. *)
let root_state_is_fresh_ok root =
  match Conn.read_connector_state root with
  | Some st ->
      st.Conn.cs_last_error_op = None && st.Conn.cs_wedge_count = 0
      && st.Conn.cs_wedged_since = None
  | None -> false

let test_noop_pass_resets_wedge_epoch () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let root = Filename.concat tmp "b319-broker" in
  let conductor = Filename.concat tmp "conductor-broker" in
  write_eligible_registry root;
  write_eligible_registry conductor;
  let mark_r, mark_w = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close mark_r;
      Unix.putenv "C2C_RELAY_CONNECTOR_WEDGE_COOLDOWN_BASE_S" "0.02";
      let watchdogs = ref 0 in
      let reg = Filename.concat root "registry.json" in
      let rearmed = ref false in
      let sync_once _shutdown t =
        if t.Conn.broker_root = root then begin
          ignore (Unix.write_substring mark_w "W" 0 1);
          incr watchdogs;
          (* After 3 strikes the root wedges (count 1); go idle so the next
             pass takes the NOOP branch. *)
          if !watchdogs = 3 then Sys.remove reg;
          Error (`Watchdog "simulated hang")
        end
        else begin
          (* Conductor: once the noop pass has written a fresh ok state,
             re-arm the root for a second erroring epoch. *)
          if not !rearmed && root_state_is_fresh_ok root then begin
            write_eligible_registry root;
            rearmed := true;
            ignore (Unix.write_substring mark_w "R" 0 1)
          end;
          Ok (ok_result ())
        end
      in
      let code =
        Conn.start_machine_impl ~sync_once
          ~discover_roots:(fun ~primary -> [ root; primary ])
          ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
          ~primary_broker_root:conductor ~node_id:"b319-noop-wedge"
          ~heartbeat_ttl:300.0 ~interval:0.1 ~verbose:false ~once:false
      in
      Unix.close mark_w;
      Unix._exit code
  | pid ->
      Unix.close mark_w;
      (* 6 "W" = both erroring epochs complete (3 strikes each). *)
      let marks = drain_until mark_r ~at_least:7 ~deadline_s:15.0 in
      Unix.close mark_r;
      Unix.kill pid Sys.sigterm;
      (match waitpid_until ~timeout_s:5.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some (Unix.WEXITED 9) ->
           Alcotest.fail "the idle root reached sync_once (B291 gate violated)"
       | Some status ->
           Alcotest.failf "machine loop exited abnormally: %s"
             (match status with
              | Unix.WEXITED c -> Printf.sprintf "exit %d" c
              | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
              | Unix.WSTOPPED s -> Printf.sprintf "signal %d" s)
       | None ->
           Unix.kill pid Sys.sigkill;
           ignore (Unix.waitpid [] pid);
           Alcotest.fail "machine loop did not exit after SIGTERM");
      Alcotest.(check bool)
        "both erroring epochs ran (6 watchdog strikes)" true
        (count_char 'W' marks >= 6);
      Alcotest.(check bool)
        "idle epoch happened and the root was re-armed (R mark)" true
        (count_char 'R' marks >= 1);
      match Conn.read_connector_state root with
      | None -> Alcotest.fail "no connector-state for the root"
      | Some st ->
          Alcotest.(check bool) "root is wedged from the second epoch" true
            (st.Conn.cs_wedged_since <> None);
          (* The assertion under test: the first wedge of the new epoch is
             count 1, NOT a stale N+1. *)
          Alcotest.(check int)
            "wedge after idle epoch restarts at 1" 1 st.Conn.cs_wedge_count

let () =
  Alcotest.run "B319 noop pass resets the wedge epoch"
    [ ("noop wedge reset",
       [ Alcotest.test_case "wedge -> noop epoch -> wedge counts from 1" `Quick
           test_noop_pass_resets_wedge_epoch
       ]) ]
