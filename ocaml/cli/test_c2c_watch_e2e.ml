(* test_c2c_watch_e2e.ml — END-TO-END round-trip tests for the `c2c watch`
   send path against a REAL on-disk broker (not synthetic-only).

   Where [test_c2c_watch_data.ml] asserts the pure read-projections and the
   send-wrapper ERROR paths, this suite proves the FULL data+broker+send path:
   a message sent via [C2c_watch_data.send_dm] must actually LAND in the
   recipient's inbox (read back via [Broker.read_inbox]), and a room post via
   [send_room_message] must land in the room's history (read back via
   [Broker.read_room_history]). Each test builds a fresh mkdtemp broker root
   (Fun.protect + rm_rf cleanup). Test-only aliases are prefixed "zzte2e-" to
   avoid colliding with real swarm aliases. *)

open Alcotest

module Broker = C2c_mcp.Broker
module Data = C2c_watch_data

(* --- tmpdir helpers (copied from test_c2c_watch_data.ml) ----------------- *)

let mkdtemp () =
  let base = Filename.get_temp_dir_name () in
  let rec attempt n =
    if n > 50 then failwith "mkdtemp: too many attempts"
    else
      let cand =
        Filename.concat base
          (Printf.sprintf "c2c_watch_e2e_test_%d_%d" (Unix.getpid ())
             (Random.int 1_000_000))
      in
      match Unix.mkdir cand 0o700 with
      | () -> cand
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (n + 1)
  in
  attempt 0

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()

(* --- shared aliases / ids ----------------------------------------------- *)

let recipient_alias = "zzte2e-recipient"
let recipient_sid = "zzte2e-recipient-sid"
let room_id = "zzte2e-room"
let room2_id = "zzte2e-room2"

(* Register the recipient as ALIVE (this process's pid + matching
   pid_start_time so registration_liveness_state = Alive). *)
let register_alive_recipient t =
  let self_pid = Unix.getpid () in
  Broker.register t ~session_id:recipient_sid ~alias:recipient_alias
    ~pid:(Some self_pid)
    ~pid_start_time:(Broker.capture_pid_start_time (Some self_pid))
    ~role:(Some "coder") ()

let liveness_eq = function
  | Broker.Alive, Broker.Alive
  | Broker.Dead, Broker.Dead
  | Broker.Unknown, Broker.Unknown -> true
  | _ -> false

let is_send_failed = function Data.Send_failed _ -> true | _ -> false

let with_broker f =
  let root = mkdtemp () in
  Fun.protect
    ~finally:(fun () -> rm_rf root)
    (fun () -> f (Broker.create ~root))

(* --- 1. SNAPSHOT E2E ----------------------------------------------------- *)

(* Register an ALIVE recipient + create a room (auto-joining the recipient);
   build the snapshot and assert the recipient is an Alive peer and the room
   shows up in snapshot.rooms. *)
let test_snapshot_e2e () =
  with_broker (fun t ->
      register_alive_recipient t;
      ignore
        (Broker.create_room t ~room_id ~caller_alias:recipient_alias
           ~caller_session_id:recipient_sid ~visibility:C2c_mcp.Public
           ~invited_members:[] ~auto_join:true);
      let snap = Data.build_snapshot t in
      let peer =
        match
          List.find_opt
            (fun (p : Data.peer_row) -> p.pr_alias = recipient_alias)
            snap.Data.peers
        with
        | Some p -> p
        | None -> failf "recipient %s missing from snapshot.peers" recipient_alias
      in
      check bool "recipient peer is Alive" true
        (liveness_eq (peer.pr_liveness, Broker.Alive));
      check bool "room present in snapshot.rooms" true
        (List.exists
           (fun (rv : Data.room_view) -> rv.rv_info.ri_room_id = room_id)
           snap.Data.rooms))

(* --- 2. DM SEND ROUND-TRIP (the key e2e) -------------------------------- *)

(* send_dm via the watch wrapper -> Sent_dm, THEN read the recipient's inbox
   directly from the broker and confirm the exact message landed. *)
let test_dm_round_trip () =
  with_broker (fun t ->
      register_alive_recipient t;
      let r =
        Data.send_dm t ~from_alias:"operator" ~to_alias:recipient_alias
          ~content:"e2e ping 12345"
      in
      (match r with
       | Data.Sent_dm | Data.Sent_dm_offline -> ()
       | Data.Sent_room _ -> failf "send_dm returned Sent_room"
       | Data.Send_failed m -> failf "send_dm returned Send_failed: %s" m);
      let inbox = Broker.read_inbox t ~session_id:recipient_sid in
      let landed =
        List.exists
          (fun (m : C2c_mcp.message) ->
             m.content = "e2e ping 12345" && m.from_alias = "operator")
          inbox
      in
      check bool "DM landed in recipient inbox (content + from)" true landed)

(* --- 3. DM ERROR PATHS (real broker) ------------------------------------ *)

(* send_dm to an UNREGISTERED alias -> Send_failed, and the message must not
   appear in any inbox on disk. *)
let test_dm_unregistered_recipient () =
  with_broker (fun t ->
      register_alive_recipient t;
      let r =
        Data.send_dm t ~from_alias:"operator" ~to_alias:"zzte2e-nobody"
          ~content:"e2e to nobody 99999"
      in
      check bool "unregistered recipient => Send_failed" true (is_send_failed r);
      (* the registered recipient's inbox must not have absorbed it either *)
      let inbox = Broker.read_inbox t ~session_id:recipient_sid in
      check bool "no inbox contains the failed message" false
        (List.exists
           (fun (m : C2c_mcp.message) -> m.content = "e2e to nobody 99999")
           inbox))

(* self-send (from = to) -> Send_failed, guarded before the broker call. *)
let test_dm_self_send () =
  with_broker (fun t ->
      let r =
        Data.send_dm t ~from_alias:"operator" ~to_alias:"operator"
          ~content:"talking to myself"
      in
      check bool "self-send => Send_failed" true (is_send_failed r))

(* --- 4. ROOM SEND ROUND-TRIP -------------------------------------------- *)

(* Register the recipient + create room2 with the recipient auto-joined; the
   recipient (a member) posts to the room; read history back and confirm the
   post landed in history.jsonl. *)
let test_room_round_trip () =
  with_broker (fun t ->
      register_alive_recipient t;
      ignore
        (Broker.create_room t ~room_id:room2_id ~caller_alias:recipient_alias
           ~caller_session_id:recipient_sid ~visibility:C2c_mcp.Public
           ~invited_members:[] ~auto_join:true);
      let r =
        Data.send_room_message t ~from_alias:recipient_alias ~room_id:room2_id
          ~content:"e2e room hello"
      in
      (match r with
       | Data.Sent_room _ -> ()
       | Data.Sent_dm | Data.Sent_dm_offline ->
           failf "send_room_message returned a DM result"
       | Data.Send_failed m -> failf "send_room_message => Send_failed: %s" m);
      let history = Broker.read_room_history t ~room_id:room2_id ~limit:100 () in
      let landed =
        List.exists
          (fun (m : C2c_mcp.room_message) -> m.rm_content = "e2e room hello")
          history
      in
      check bool "room post landed in history.jsonl" true landed)

let snapshot_tests =
  [ "snapshot e2e (alive peer + room)", `Quick, test_snapshot_e2e ]

let dm_tests =
  [ "dm round-trip lands in inbox", `Quick, test_dm_round_trip
  ; "dm unregistered => Send_failed", `Quick, test_dm_unregistered_recipient
  ; "dm self-send => Send_failed",    `Quick, test_dm_self_send
  ]

let room_tests =
  [ "room round-trip lands in history", `Quick, test_room_round_trip ]

let () =
  Random.self_init ();
  Alcotest.run "c2c_watch_e2e"
    [ "snapshot", snapshot_tests
    ; "dm_round_trip", dm_tests
    ; "room_round_trip", room_tests
    ]
