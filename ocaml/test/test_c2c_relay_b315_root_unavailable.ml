(* B315 regression: a broker root deleted or made unwritable mid-service
   crashed the machine connector with an unhandled Sys_error. The noop branch
   tolerates a missing dir for READS, but write_connector_state and
   write_connector_state_error do bare open_out on a tmp path under the root —
   and discover_machine_broker_roots always conses the primary, so a deleted
   PRIMARY repo dir was a permanent crash loop at every pass.

   Fix contract: the machine loop skips an unavailable root for that pass —
   missing-directory pre-check plus Sys_error/Unix_error tolerance around the
   per-root sync — names the root on stderr, records NO cooldown (a dir that
   comes back must auto-heal, and a root that left discovery must not
   resurrect the B292 crash loop), and the other roots continue. `--once`
   reports exit 2 for a pass with a skipped root: the same code the old crash
   path produced, so scripts observe no change. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b315-test-%d-%d"
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
      Unix.sleepf 0.05;
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

(* Run one machine --once pass over [unavailable_root :: good] where the
   unavailable root comes FIRST: pre-fix the Sys_error crash on it poisons the
   pass before the good root is ever reached. The good root writes a "G" byte
   per sync; reaching the unavailable root at all after the fix is flagged via
   "X" (it must be skipped, not synced). [check] runs BEFORE the tmpdir is
   removed — the connector state is assertable only in there. *)
let once_pass_with_bad_root ~setup_bad ~cleanup_bad ~label ~check () =
  let tmp = make_tmpdir () in
  Fun.protect
    ~finally:(fun () ->
      cleanup_bad ();
      rmrf tmp)
    @@ fun () ->
  let bad = Filename.concat tmp (label ^ "-broker") in
  let good = Filename.concat tmp "good-broker" in
  setup_bad bad;
  write_eligible_registry good;
  let byte_r, byte_w = Unix.pipe () in
  let code, marks =
    match Unix.fork () with
    | 0 ->
        Unix.close byte_r;
        let sync_once _shutdown t =
          if t.Conn.broker_root = bad then
            ignore (Unix.write_substring byte_w "X" 0 1);
          ignore (Unix.write_substring byte_w "G" 0 1);
          Ok (ok_result ())
        in
        let code =
          Conn.start_machine_impl ~sync_once
            ~discover_roots:(fun ~primary -> [ bad; primary ])
            ~relay_url:"http://unreachable.invalid" ~token:None ~identity:None
            ~primary_broker_root:good ~node_id:"b315-test"
            ~heartbeat_ttl:300.0 ~interval:0.05 ~verbose:false ~once:true
        in
        Unix.close byte_w;
        Unix._exit code
    | pid ->
        Unix.close byte_w;
        let marks = drain_until byte_r ~at_least:1 ~deadline_s:3.0 in
        Unix.close byte_r;
        let code =
          match waitpid_until ~timeout_s:3.0 pid with
          | Some (Unix.WEXITED c) -> c
          | Some status ->
              Unix.kill pid Sys.sigkill;
              (try ignore (Unix.waitpid [] pid) with _ -> ());
              Alcotest.failf "%s pass exited abnormally: %s" label
                (match status with
                 | Unix.WEXITED c -> Printf.sprintf "exit %d" c
                 | Unix.WSIGNALED s -> Printf.sprintf "signal %d" s
                 | Unix.WSTOPPED s -> Printf.sprintf "stopped %d" s)
          | None ->
              Unix.kill pid Sys.sigkill;
              (try ignore (Unix.waitpid [] pid) with _ -> ());
              Alcotest.failf "%s pass did not finish within 3s" label
        in
        (code, marks)
  in
  check ~code ~marks ~good

let test_deleted_root_skipped_not_crash () =
  once_pass_with_bad_root
    ~setup_bad:(fun _ -> ()) (* never created *)
    ~cleanup_bad:(fun _ -> ())
    ~label:"deleted"
    ~check:(fun ~code ~marks ~good ->
      Alcotest.(check bool)
        "good root still synced after an earlier root was skipped"
        (count_char 'G' marks >= 1) true;
      Alcotest.(check bool) "deleted root never reached sync_once" true
        (count_char 'X' marks = 0);
      Alcotest.(check int) "once reports 2 for a pass with a skipped root" 2
        code;
      (* The good root's connector state was still written for its own sync. *)
      match Conn.read_connector_state good with
      | Some st ->
          Alcotest.(check bool) "good root state written" true
            (st.Conn.cs_last_ok_ts > 0.0)
      | None -> Alcotest.fail "good root lost its connector state")
    ()

let test_unwritable_root_skipped_not_crash () =
  let chmod_back = ref (fun () -> ()) in
  once_pass_with_bad_root
    ~setup_bad:(fun bad ->
      (* exists + eligible registry, but the directory denies everything —
         reads fall back to empty (no-op gate) and the state write raises. *)
      write_eligible_registry bad;
      Unix.chmod bad 0o000;
      chmod_back := (fun () ->
          try Unix.chmod bad 0o755 with _ -> ()))
    ~cleanup_bad:(fun () -> !chmod_back ())
    ~label:"unwritable"
    ~check:(fun ~code ~marks ~good ->
      Alcotest.(check bool)
        "good root still synced past an unwritable root"
        (count_char 'G' marks >= 1) true;
      Alcotest.(check int) "once reports 2 with an unusable root" 2 code;
      match Conn.read_connector_state good with
      | Some _ -> ()
      | None -> Alcotest.fail "good root lost its connector state")
    ()

let () =
  Alcotest.run "c2c-relay-b315-root-unavailable"
    [ ( "B315 unavailable broker root"
      , [ Alcotest.test_case "deleted root skipped, others continue" `Quick
            test_deleted_root_skipped_not_crash
        ; Alcotest.test_case "unwritable root skipped, others continue" `Quick
            test_unwritable_root_skipped_not_crash ] ) ]
