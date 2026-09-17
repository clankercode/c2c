(* B306 regression: append_to_local_inbox bypassed the broker per-inbox lock.

   The connector's inbound handoff did an unlocked read-merge-tmp-rename on
   <sid>.inbox.json while every broker drain path runs under with_inbox_lock
   (c2c_broker.ml: fcntl lockf on the <sid>.inbox.lock sidecar). Interleaving
   (b): broker load_inbox reads [X] -> connector appends Y -> broker saves
   [] -> Y silently lost, and the relay poll is destructive so the row is
   gone (unrecoverable for --ephemeral).

   The test replays that interleaving deterministically: a forked child holds
   the BROKER lock (same sidecar path + Unix.lockf primitive as
   C2c_broker.with_inbox_lock), reads the inbox, holds, then saves the
   drained result — while the parent calls Conn.append_to_local_inbox
   mid-window. The appended row must survive. *)

module Conn = C2c_relay_connector

let make_tmpdir () =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
    (Printf.sprintf "c2c-b306-test-%d-%d"
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

let read_rows root sid =
  let path = Filename.concat root (sid ^ ".inbox.json") in
  match C2c_io.read_json_opt path with
  | None -> []
  | Some (`List rows) -> rows
  | Some _ -> []

let msg_row ~mid ~content =
  `Assoc [ "message_id", `String mid;
           "from_alias", `String "peer@remote";
           "to_alias", `String "fixture-alias";
           "content", `String content;
           "ts", `Float (Unix.gettimeofday ()) ]

let write_rows root sid rows =
  let path = Filename.concat root (sid ^ ".inbox.json") in
  let oc = open_out path in
  Yojson.Safe.to_channel oc (`List rows);
  close_out oc

let row_id row =
  match Yojson.Safe.Util.member "message_id" row with
  | `String s -> s
  | _ -> ""

let read_json_list path =
  match C2c_io.read_json_opt path with
  | Some (`List rows) -> rows
  | _ -> []

(* The interleaving regression: a broker drain (lock holder) racing the
   connector merge must not drop the appended row. *)
let test_append_survives_concurrent_broker_drain () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let sid = "fixture-live" in
  let lock_path = Filename.concat tmp (sid ^ ".inbox.lock") in
  let saw_path = Filename.concat tmp "drain-saw.json" in
  write_rows tmp sid [ msg_row ~mid:"m-x" ~content:"x" ];
  (* Fork the broker-drain side: lock via the broker's exact sidecar
     construction + Unix.lockf, read, hold 0.4s, save the drained result. *)
  let drain = Unix.fork () in
  if drain = 0 then begin
    let exit_code =
      try
        let fd = Unix.openfile lock_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
        Unix.lockf fd Unix.F_LOCK 0;
        (* load_inbox: read what is on disk BEFORE the merge lands *)
        let saw = read_rows tmp sid in
        let oc = open_out saw_path in
        Yojson.Safe.to_channel oc (`List saw);
        close_out oc;
        Unix.sleepf 0.4;
        (* save_inbox: the drain replaces the file with what it archived *)
        write_rows tmp sid [];
        ignore (Unix.lockf fd Unix.F_ULOCK 0);
        Unix.close fd;
        0
      with _ -> 40
    in
    Unix._exit exit_code
  end;
  (* Let the drain acquire the lock and enter its hold window. *)
  Unix.sleepf 0.1;
  let t0 = Unix.gettimeofday () in
  let n = Conn.append_to_local_inbox tmp sid [ msg_row ~mid:"m-y" ~content:"y" ] in
  let append_blocked_for = Unix.gettimeofday () -. t0 in
  (match waitpid_until ~timeout_s:10.0 drain with
   | Some (Unix.WEXITED 0) -> ()
   | Some (Unix.WEXITED code) ->
       Alcotest.failf "drain child exited %d" code
   | _ ->
       (try Unix.kill drain Sys.sigkill with _ -> ());
       Alcotest.fail "drain child died");
  Alcotest.(check int) "append reports one delivered row" 1 n;
  (* The drain must have observed only the pre-merge row X. *)
  Alcotest.(check (list string)) "drain archived exactly X"
    [ "m-x" ] (List.map row_id (read_json_list saw_path));
  (* THE assertion: the appended row Y survived the drain's rewrite. *)
  Alcotest.(check (list string)) "appended row survives concurrent drain"
    [ "m-y" ] (List.map row_id (read_rows tmp sid));
  (* Exclusion proof: the merge could only run after the drain released the
     lock, so append_to_local_inbox must have blocked for the hold window. *)
  Alcotest.(check bool) "append waited for the broker lock (blocked >= 0.25s)"
    true (append_blocked_for >= 0.25)

(* Sanity guard: empty append is a no-op and never creates state; append to
   a fresh root creates the inbox file with exactly the new rows. *)
let test_append_empty_and_fresh_root () =
  let tmp = make_tmpdir () in
  Fun.protect ~finally:(fun () -> rmrf tmp) @@ fun () ->
  let sid = "fresh-session" in
  Alcotest.(check int) "empty append is a no-op" 0
    (Conn.append_to_local_inbox tmp sid []);
  Alcotest.(check bool) "no inbox file created for empty append"
    false (Sys.file_exists (Filename.concat tmp (sid ^ ".inbox.json")));
  let n =
    Conn.append_to_local_inbox tmp sid
      [ msg_row ~mid:"m-1" ~content:"a"; msg_row ~mid:"m-2" ~content:"b" ]
  in
  Alcotest.(check int) "append reports row count" 2 n;
  Alcotest.(check (list string)) "fresh-root append lands both rows"
    [ "m-1"; "m-2" ] (List.map row_id (read_rows tmp sid))

let () =
  let open Alcotest in
  run "c2c-relay-b306-inbox-lock"
    [ ("inbox merge lock",
       [ test_case "append survives concurrent broker drain" `Quick
           test_append_survives_concurrent_broker_drain;
         test_case "empty append no-op + fresh-root append" `Quick
           test_append_empty_and_fresh_root ]) ]
