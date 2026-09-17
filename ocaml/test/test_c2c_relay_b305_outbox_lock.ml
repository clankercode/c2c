(* B305 regression: outbox TOCTOU — write_outbox ran OUTSIDE with_outbox_lock
   and append_outbox_entry (the `c2c send peer@host` enqueue path) never
   locked. Interleaving: sync reads [A] under the lock, spends seconds in the
   HTTP send loop, releases the lock, then truncating-rewrites the whole
   outbox file; an entry appended mid-window is silently deleted.

   The test drives the REAL sync against the scripted relay
   (Relay_test_support): /send is delayed to hold the sync pass open while a
   forked child performs the MCP-side append mid-flight. The appended entry
   must survive the pass and A must be forwarded exactly once. *)

module Conn = C2c_relay_connector
module RTS = Relay_test_support

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b305-test-%d-%d"
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

(* Same shape as the connector suite's eligible-registry fixture: a live
   registration for THIS process so the sync pass actually reaches sync. *)
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
let empty_inbox = {|{"ok":true,"messages":[]}|}

(* The interleaving regression: a concurrent append during a slow sync send
   must survive sync's whole-file rewrite. *)
let test_append_during_slow_sync_survives () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  match Unix.fork () with
  | 0 ->
      let exit_code =
        try
          RTS.with_server
            ~routes:[
              RTS.route ~meth:"POST" ~path:"/heartbeat" [ RTS.response reg_ok ];
              (* Simulate the slow HTTP send: holds the sync pass open. *)
              RTS.route ~meth:"POST" ~path:"/send"
                [ RTS.response ~delay_s:1.0 reg_ok ];
              RTS.route ~meth:"POST" ~path:"/poll_inbox"
                [ RTS.response empty_inbox ];
              RTS.route ~meth:"POST" ~path:"/peek_inbox"
                [ RTS.response empty_inbox ];
            ]
            (fun srv ->
               write_eligible_registry tmp;
               let outbox = Filename.concat tmp "remote-outbox.jsonl" in
               let oc = open_out outbox in
               output_string oc
                 "{\"from_alias\":\"out-sender\",\"to_alias\":\"dst@remote\",\"content\":\"A\"}\n";
               close_out oc;
               let t =
                 Conn.make_state ~relay_url:(RTS.url srv) ~token:None
                   ~identity:None ~broker_root:tmp ~node_id:"b305-test"
                   ~heartbeat_ttl:60.0 ~interval:1.0 ~verbose:false
               in
               t.Conn.registered <- [ "fixture-live" ];
               (* Concurrent MCP-side enqueue, timed to land mid-send-window. *)
               let appender = Unix.fork () in
               if appender = 0 then begin
                 Unix.sleepf 0.3;
                 Conn.append_outbox_entry tmp
                   ~from_alias:"out-sender" ~to_alias:"dst@remote"
                   ~content:"B" ();
                 Unix._exit 0
               end;
               let _r = Lwt_main.run (Conn.sync t) in
               (match waitpid_until ~timeout_s:10.0 appender with
                | Some (Unix.WEXITED 0) -> ()
                | Some _ | None ->
                    (try Unix.kill appender Sys.sigkill with _ -> ());
                    exit 30);
               (* B must have survived sync's truncating rewrite of the
                  outbox file; A was forwarded and removed. *)
               (match Conn.read_outbox tmp with
                | [ e ] when e.Conn.ob_content = "B" -> ()
                | rows ->
                    Printf.eprintf "outbox after sync: %d row(s)\n%!"
                      (List.length rows);
                    List.iter
                      (fun e ->
                         Printf.eprintf "  remaining content=%S\n%!"
                           e.Conn.ob_content)
                      rows;
                    exit 31);
               let sends =
                 List.filter (fun r -> r.RTS.path = "/send")
                   (RTS.requests srv)
               in
               if List.length sends <> 1 then begin
                 Printf.eprintf "expected exactly 1 /send, got %d\n%!"
                   (List.length sends);
                 exit 32
               end;
               0)
        with _ -> 33
      in
      Unix._exit exit_code
  | pid ->
      (match waitpid_until ~timeout_s:20.0 pid with
       | Some (Unix.WEXITED 0) -> ()
       | Some (Unix.WEXITED code) ->
           Alcotest.failf "interleaving child exited %d (31 = appended entry \
                           lost by sync rewrite)" code
       | Some status ->
           Alcotest.failf "interleaving child died: %d"
             (match status with
              | Unix.WSIGNALED n -> n
              | _ -> -1)
       | None ->
           Unix.kill pid Sys.sigkill;
           ignore (Unix.waitpid [] pid);
           Alcotest.fail "interleaving child did not finish in 20s")

let () =
  let open Alcotest in
  run "c2c-relay-b305-outbox-lock"
    [ ("outbox toctou",
       [ test_case "concurrent append during slow sync survives" `Quick
           test_append_during_slow_sync_survives ]) ]
