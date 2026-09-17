(* B317 regression: inbound relay handoff was at-most-once across a crash or
   watchdog kill — the poll arm cleared rows on the relay (destructive
   /poll_inbox), filtered in memory, and only THEN appended locally, so a
   kill between relay-clear and local append silently lost the batch
   (unrecoverable for --ephemeral rows, which have no archive copy).

   Fix contract (same persist-first ordering the repo mandates for the
   Hermes/agy delivery paths): peek (non-destructive) -> persist locally ->
   poll (clear). Rows arriving between peek and poll come back in the poll
   result and must also be appended; rows present in both results are
   deduplicated by message id so nothing is appended twice. *)

module Conn = C2c_relay_connector
module RTS = Relay_test_support

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b317-test-%d-%d"
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

let reg_ok = {|{"ok":true,"result":"ok"}|}

let relay_row ~mid ~content =
  Printf.sprintf
    {|{"message_id":"%s","from_alias":"peer@remote","to_alias":"fixture-alias","content":"%s","ts":1.0}|}
    mid content

let messages_json rows =
  "{\"ok\":true,\"messages\":[" ^ String.concat "," rows ^ "]}"

let read_inbox_ids root sid =
  let path = Filename.concat root (sid ^ ".inbox.json") in
  match C2c_io.read_json_opt path with
  | None -> []
  | Some (`List rows) ->
      List.filter_map
        (fun row ->
           match Yojson.Safe.Util.member "message_id" row with
           | `String s -> Some s
           | _ -> None)
        rows
  | Some _ -> []

(* Run one real sync pass against a scripted relay in a forked child; the
   child exits 0 and returns the sync_result via a JSON side file. *)
let run_sync_with ~tmp ~routes ~expected_note =
  match Unix.fork () with
  | 0 ->
      let exit_code =
        try
          RTS.with_server ~routes (fun srv ->
              write_eligible_registry tmp;
              let t =
                Conn.make_state ~relay_url:(RTS.url srv) ~token:None
                  ~identity:None ~broker_root:tmp ~node_id:"b317-test"
                  ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false
              in
              t.Conn.registered <- [ "fixture-live" ];
              let r = Lwt_main.run (Conn.sync t) in
              let oc = open_out (Filename.concat tmp "sync-result.json") in
              Yojson.Safe.to_channel oc
                (`Assoc [ "inbound_delivered", `Int r.Conn.inbound_delivered ]);
              close_out oc;
              (* contract check from the task: peek must hit the relay
                 before the destructive poll *)
              let paths = List.map (fun r -> r.RTS.path) (RTS.requests srv) in
              let peek_pos =
                let rec idx i = function
                  | [] -> None
                  | p :: rest -> if p = "/peek_inbox" then Some i else idx (i + 1) rest
                in
                idx 0 paths
              in
              let poll_pos =
                let rec idx i = function
                  | [] -> None
                  | p :: rest -> if p = "/poll_inbox" then Some i else idx (i + 1) rest
                in
                idx 0 paths
              in
              (match peek_pos, poll_pos with
               | Some a, Some b when a < b -> ()
               | _ ->
                   Printf.eprintf "expected /peek_inbox before /poll_inbox, got %s\n%!"
                     (String.concat "," paths);
                   exit 50);
              0)
        with e ->
          Printf.eprintf "child failed: %s (expected %s)\n%!"
            (Printexc.to_string e) expected_note;
          51
      in
      Unix._exit exit_code
  | pid ->
      (match waitpid_until ~timeout_s:20.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some (Unix.WEXITED code) ->
           Alcotest.failf "sync child exited %d (%s)" code expected_note
       | Some status ->
           Alcotest.failf "sync child died: %d"
             (match status with Unix.WSIGNALED n -> n | _ -> -1)
       | None ->
           Unix.kill pid Sys.sigkill;
           ignore (Unix.waitpid [] pid);
           Alcotest.fail "sync child did not finish in 20s")

let read_delivered tmp =
  match C2c_io.read_json_opt (Filename.concat tmp "sync-result.json") with
  | Some (`Assoc fields) ->
      (match List.assoc_opt "inbound_delivered" fields with
       | Some (`Int n) -> n
       | _ -> -1)
  | _ -> -1

(* THE B317 regression: the clear step dies after the local persist — the
   persisted rows must already be on disk (pre-fix, the relay was cleared
   first and the append never ran, losing the batch silently). *)
let test_persist_survives_crash_before_clear () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let rows = [ relay_row ~mid:"m-1" ~content:"one";
               relay_row ~mid:"m-2" ~content:"two" ] in
  run_sync_with ~tmp
    ~routes:[
      RTS.route ~meth:"POST" ~path:"/heartbeat" [ RTS.response reg_ok ];
      RTS.route ~meth:"POST" ~path:"/peek_inbox"
        [ RTS.response (messages_json rows) ];
      (* the clear attempt crashes mid-handoff (watchdog kill / OOM /
         connection drop): nothing survives after the persist *)
      RTS.route ~meth:"POST" ~path:"/poll_inbox"
        [ RTS.response ~close_without_response:true "" ];
    ]
    ~expected_note:"persist-before-clear crash window";
  Alcotest.(check (list string)) "rows persisted despite dead clear step"
    [ "m-1"; "m-2" ] (read_inbox_ids tmp "fixture-live");
  Alcotest.(check int) "delivered counts both rows" 2 (read_delivered tmp)

(* The documented repair pattern: rows arriving between the peek and the
   poll come back in the poll result and must be appended too — while rows
   present in BOTH results are deduplicated by message id. *)
let test_peek_poll_race_repair_dedupes () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  run_sync_with ~tmp
    ~routes:[
      RTS.route ~meth:"POST" ~path:"/heartbeat" [ RTS.response reg_ok ];
      RTS.route ~meth:"POST" ~path:"/peek_inbox"
        [ RTS.response (messages_json [ relay_row ~mid:"m-1" ~content:"one" ]) ];
      (* m-1 is still queued (peek did not clear it); m-2 arrived during
         the peek->poll window *)
      RTS.route ~meth:"POST" ~path:"/poll_inbox"
        [ RTS.response (messages_json
            [ relay_row ~mid:"m-1" ~content:"one";
              relay_row ~mid:"m-2" ~content:"two" ]) ];
    ]
    ~expected_note:"peek/poll race repair";
  Alcotest.(check (list string))
    "m-2 repaired from poll result; m-1 appended exactly once"
    [ "m-1"; "m-2" ] (read_inbox_ids tmp "fixture-live");
  Alcotest.(check int) "delivered counts each row once" 2 (read_delivered tmp)

(* Review-fix regression (blocker): persist-first must be idempotent across
   passes. A batch that was persisted but NOT cleared (poll failed) stays
   queued on the relay; the next pass re-peeks the identical rows and must
   not append them again. Without a persisted seen-id ledger, a persistently
   peek-ok/poll-failing relay grows the inbox by the whole batch every pass. *)
let test_failed_poll_pass_redelivers_without_duplicates () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let rows = [ relay_row ~mid:"m-1" ~content:"one";
               relay_row ~mid:"m-2" ~content:"two" ] in
  match Unix.fork () with
  | 0 ->
      let exit_code =
        try
          RTS.with_server
            ~routes:[
              RTS.route ~meth:"POST" ~path:"/heartbeat" [ RTS.response reg_ok ];
              RTS.route ~meth:"POST" ~path:"/peek_inbox"
                [ RTS.response (messages_json rows) ];
              (* pass 1: the clear step dies; pass 2: it succeeds *)
              RTS.route ~meth:"POST" ~path:"/poll_inbox"
                [ RTS.response ~close_without_response:true "";
                  RTS.response (messages_json []) ];
            ]
            (fun srv ->
               write_eligible_registry tmp;
               let t =
                 Conn.make_state ~relay_url:(RTS.url srv) ~token:None
                   ~identity:None ~broker_root:tmp ~node_id:"b317-test"
                   ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false
               in
               t.Conn.registered <- [ "fixture-live" ];
               let r1 = Lwt_main.run (Conn.sync t) in
               let r2 = Lwt_main.run (Conn.sync t) in
               let oc = open_out (Filename.concat tmp "sync-result.json") in
               Yojson.Safe.to_channel oc
                 (`Assoc [ "delivered1", `Int r1.Conn.inbound_delivered;
                           "delivered2", `Int r2.Conn.inbound_delivered ]);
               close_out oc;
               0)
        with e ->
          Printf.eprintf "child failed: %s\n%!" (Printexc.to_string e);
          51
      in
      Unix._exit exit_code
  | pid ->
      (match waitpid_until ~timeout_s:30.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some (Unix.WEXITED code) ->
           Alcotest.failf "two-pass sync child exited %d" code
       | _ ->
           (try Unix.kill pid Sys.sigkill with _ -> ());
           Alcotest.fail "two-pass sync child died")
  ;
  Alcotest.(check (list string))
    "redelivered batch appended exactly once across passes"
    [ "m-1"; "m-2" ] (read_inbox_ids tmp "fixture-live");
  let get_delivered key =
    match C2c_io.read_json_opt (Filename.concat tmp "sync-result.json") with
    | Some (`Assoc fields) ->
        (match List.assoc_opt key fields with Some (`Int n) -> n | _ -> -1)
    | _ -> -1
  in
  Alcotest.(check int) "pass 1 delivered both rows" 2 (get_delivered "delivered1");
  Alcotest.(check int) "pass 2 delivered nothing (already seen)"
    0 (get_delivered "delivered2")

(* Deliberate contract (reviewed and kept): when the peek fails GENERICALLY
   (relay without /peek_inbox — version skew — or a transient connection
   error), the destructive poll is still attempted so mail keeps flowing;
   poll rows are processed through the same filter+persist path. Only a 429
   or a dropped registration skips the poll. (A peek-only outage therefore
   degrades to the pre-B317 at-most-once window rather than going dark.) *)
let test_failed_peek_falls_back_to_poll () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  match Unix.fork () with
  | 0 ->
      let exit_code =
        try
          RTS.with_server
            ~routes:[
              RTS.route ~meth:"POST" ~path:"/heartbeat" [ RTS.response reg_ok ];
              RTS.route ~meth:"POST" ~path:"/peek_inbox"
                [ RTS.response ~close_without_response:true "" ];
              RTS.route ~meth:"POST" ~path:"/poll_inbox"
                [ RTS.response (messages_json
                    [ relay_row ~mid:"m-1" ~content:"one" ]) ];
            ]
            (fun srv ->
               write_eligible_registry tmp;
               let t =
                 Conn.make_state ~relay_url:(RTS.url srv) ~token:None
                   ~identity:None ~broker_root:tmp ~node_id:"b317-test"
                   ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false
               in
               t.Conn.registered <- [ "fixture-live" ];
               let r = Lwt_main.run (Conn.sync t) in
               if r.Conn.inbound_delivered <> 1 then begin
                 Printf.eprintf "expected poll fallback to deliver 1 row, got %d\n%!"
                   r.Conn.inbound_delivered;
                 exit 52
               end;
               let polls =
                 List.length
                   (List.filter (fun r -> r.RTS.path = "/poll_inbox")
                      (RTS.requests srv))
               in
               if polls <> 1 then begin
                 Printf.eprintf "expected /poll_inbox fallback after failed peek, got %d\n%!"
                   polls;
                 exit 55
               end;
               0)
        with _ -> 53
      in
      Unix._exit exit_code
  | pid ->
      (match waitpid_until ~timeout_s:20.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some (Unix.WEXITED code) ->
           Alcotest.failf "failed-peek child exited %d (52 = fallback poll \
                           did not deliver)" code
       | _ ->
           (try Unix.kill pid Sys.sigkill with _ -> ());
           Alcotest.fail "failed-peek child died")

let () =
  let open Alcotest in
  run "c2c-relay-b317-persist-first"
    [ ("inbound handoff ordering",
       [ test_case "persist survives crash before relay clear" `Quick
           test_persist_survives_crash_before_clear;
         test_case "peek/poll race repair dedupes by message id" `Quick
           test_peek_poll_race_repair_dedupes;
         test_case "failed poll pass redelivers without duplicates" `Quick
           test_failed_poll_pass_redelivers_without_duplicates;
         test_case "failed peek falls back to the destructive poll" `Quick
           test_failed_peek_falls_back_to_poll ]) ]
