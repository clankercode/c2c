(* B318 regression: the machine connector scheduled PASS-STARTS-AT =
   pass-end + interval, so each pass's full work time pushed the next start
   later (a 4-6 min pass on a 300s interval made the effective cadence
   interval+pass, drift growing without bound; live on xsm: 5.5-5.8 min
   spacing across 178 roots). The fix starts the next pass at
   last_pass_start + interval — work no longer inflates the cadence — and
   an overrunning pass starts the next one immediately (never a negative
   sleep).

   Driven entirely through the start_machine_impl seams (sync_once +
   discover_roots), hermetically, in a forked child. The injected sync_once
   blocks (like the real one: run_sync_once is a blocking call) for work_s
   and records each pass-start timestamp; the parent asserts on the spacing
   of pass STARTS.

   Timing bounds are deliberately generous (>= 0.15s of slack against the
   modeled values) and robust: under the fixed cadence the observed spacing
   is exactly max(work, interval), so load stalls during the pass cannot
   inflate it beyond the assertion window. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir =
    Filename.concat base
      (Printf.sprintf "c2c-b318-test-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
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
   so the root needs an eligible registration with a LIVE pid — here the
   parent, which stays alive for the whole test (same shape as B319). *)
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

let ok_result () : Conn.sync_result =
  { registered = []; registered_sessions = []; heartbeated = [];
    outbox_forwarded = 0; outbox_failed = 0; outbox_dlqed = 0;
    inbound_delivered = 0; inbound_rejected = 0; inbound_rejected_note = None;
    alerts_emitted = 0; rate_limited = false; retry_after_s = None;
    last_error = None; errors = [] }

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

(* Run [passes] machine passes at [interval] with a sync_once that blocks
   work_s and appends each pass-start timestamp; returns the deltas between
   consecutive pass starts. *)
let measure_pass_start_deltas ~interval ~work_s ~passes ~tmp =
  let root = Filename.concat tmp "broker" in
  write_eligible_registry root;
  let ts_file = Filename.concat tmp "pass-starts.ndjson" in
  match Unix.fork () with
  | 0 ->
      let n = ref 0 in
      let sync_once shutdown _t =
        incr n;
        let oc = open_out_gen [ Open_append; Open_creat ] 0o644 ts_file in
        Printf.fprintf oc "%.6f\n" (Unix.gettimeofday ());
        close_out oc;
        Unix.sleepf work_s;
        if !n >= passes then shutdown := true;
        Ok (ok_result ())
      in
      let code =
        Conn.start_machine_impl ~sync_once
          ~discover_roots:(fun ~primary:_ -> [ root ])
          ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
          ~primary_broker_root:root ~node_id:"b318-cadence"
          ~heartbeat_ttl:300.0 ~interval ~verbose:false ~once:false
      in
      Unix._exit code
  | pid ->
      (match waitpid_until ~timeout_s:60.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some status ->
           Alcotest.failf "machine loop exited abnormally: %s"
             (match status with
              | Unix.WEXITED c -> Printf.sprintf "exit %d" c
              | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
              | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
       | None ->
           Unix.kill pid Sys.sigkill;
           ignore (Unix.waitpid [] pid);
           Alcotest.fail "machine loop did not exit within 60s");
      let ic = open_in ts_file in
      let ts =
        let rec loop acc =
          match input_line ic with
          | line -> loop (float_of_string line :: acc)
          | exception End_of_file -> List.rev acc
        in
        loop []
      in
      close_in ic;
      Alcotest.(check int) "recorded pass count" passes (List.length ts);
      match ts with
      | t0 :: (rest as _tl) ->
          let rec deltas acc = function
            | prev :: next :: tl -> deltas ((next -. prev) :: acc) (next :: tl)
            | [_] | [] -> List.rev acc
          in
          deltas [] (t0 :: rest)
      | [] -> Alcotest.fail "no pass timestamps recorded"

let check_delta name d =
  Alcotest.(check bool) name true (d >= 0.9 && d < 1.2)

let test_cadence_is_interval_between_pass_starts () =
  (* interval 1.0s, pass work 0.3s: pre-fix spacing was interval + work =
     ~1.3s (work inflates the cadence); post-fix it is exactly the interval
     — the sleep shrinks by the work time. *)
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let ds =
    measure_pass_start_deltas ~interval:1.0 ~work_s:0.3 ~passes:3 ~tmp
  in
  List.iteri
    (fun i d -> check_delta (Printf.sprintf "pass %d->%d spaced at interval" i (i + 1)) d)
    ds

let test_overrun_pass_starts_next_immediately () =
  (* interval 0.4s, pass work 0.8s: the pass overruns the interval, so the
     next pass starts immediately (spacing = work, never a negative sleep;
     pre-fix spacing was work + interval = ~1.2s). *)
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let ds =
    measure_pass_start_deltas ~interval:0.4 ~work_s:0.8 ~passes:3 ~tmp
  in
  List.iteri
    (fun i d ->
      Alcotest.(check bool)
        (Printf.sprintf "pass %d->%d starts immediately after overrun" i (i + 1))
        true
        (d >= 0.75 && d < 1.15))
    ds

let () =
  Alcotest.run "c2c-relay-b318-pass-cadence"
    [ ( "machine pass cadence"
      , [ Alcotest.test_case
            "pass N+1 starts at pass N start + interval" `Quick
            test_cadence_is_interval_between_pass_starts;
          Alcotest.test_case
            "pass overrunning the interval starts the next immediately" `Quick
            test_overrun_pass_starts_next_immediately ] ) ]
