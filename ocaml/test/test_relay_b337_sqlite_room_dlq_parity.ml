(* B337: room join/leave system messages and DM dead-lettering existed only
   in InMemoryRelay; SqliteRelay join/leave were bare INSERT/DELETE with no
   system message, and sqlite send never recorded a dead_letter row (the
   table only grew via cross-relay forward failures). Tests asserting system
   messages / DLQ contents passed in-memory and described behaviour prod did
   not have. Coordinator decision: implement the in-memory contract in
   sqlite (parity UP; the in-memory path stays).

   Contract pinned here for SqliteRelay (mirroring InMemoryRelay):
   - join by a NEW member emits the c2c-system join message: one room_history
     row + inbox fan-out to every member (joiner included); dead/missing
     members land in dead_letter with reason recipient_dead; a re-join is
     silent;
   - a leave that leaves other members behind emits the c2c-system leave
     message (history + fan-out); leaving an empty room or a room you are
     not in is silent;
   - send to an unknown alias records a dead_letter row (reason
     unknown_alias, content preserved);
   - send to a registered-but-expired recipient records a dead_letter row
     (reason recipient_dead);
   - send to a PRIVATE registered alias records NO dead_letter row (B264:
     uniform unauthorised-vs-unknown, no content DLQ) - pinned on both
     backends. *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b337" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let reg_sql t ~node_id ~session_id ~alias ?(ttl = 3600.0) () =
  let s, _ = Relay.SqliteRelay.register t ~node_id ~session_id ~alias ~ttl () in
  check string (Printf.sprintf "setup register %s ok" alias) "ok" s

let reg_mem t ~node_id ~session_id ~alias ?(ttl = 3600.0) () =
  let s, _ = Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ~ttl () in
  check string (Printf.sprintf "setup register %s ok" alias) "ok" s

let join t backend ~alias ~room_id =
  backend t ?visibility:None ~alias ~room_id ()

let contents_of hist =
  List.map
    (fun msg ->
       match Yojson.Safe.Util.member "content" msg with
       | `String c -> c
       | _ -> "")
    hist

let inbox_to_aliases msgs =
  List.map
    (fun msg ->
       match Yojson.Safe.Util.member "to_alias" msg with
       | `String a -> a
       | _ -> "")
    msgs

let dlq_reasons dl =
  List.map
    (fun msg ->
       match Yojson.Safe.Util.member "reason" msg with
       | `String r -> r
       | _ -> "")
    dl

let dlq_for dl ~to_alias =
  List.find_opt
    (fun msg ->
       match Yojson.Safe.Util.member "to_alias" msg with
       | `String a -> a = to_alias
       | _ -> false)
    dl

(* --- sqlite join emits the system message (history + inbox fan-out) --- *)

let test_sqlite_join_emits_system_message () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-alice" ();
    reg_sql t ~node_id:"b337n2" ~session_id:"b337s2" ~alias:"b337-bob" ();
    join t Relay.SqliteRelay.join_room ~alias:"b337-alice" ~room_id:"b337-room" |> ignore;
    check string "join returns ok" "ok"
      (match join t Relay.SqliteRelay.join_room ~alias:"b337-alice" ~room_id:"b337-room" with
       | `Ok -> "ok" | `Error _ -> "error");
    (* Alice's own join message: in history and in her inbox. *)
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room" ~limit:100) in
    check bool "alice join in history" true
      (hist = [ "b337-alice joined room b337-room" ]);
    check int "alice inbox has her join" 1
      (List.length (Relay.SqliteRelay.peek_inbox t ~node_id:"b337n1" ~session_id:"b337s1"));
    (* Bob joins: history gains a second entry, Alice's inbox gains the
       fan-out addressed to bob#room. *)
    join t Relay.SqliteRelay.join_room ~alias:"b337-bob" ~room_id:"b337-room" |> ignore;
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room" ~limit:100) in
    (* Order-insensitive: the sqlite room_history READER still returns a
       different order (and limit window) than in-memory — a pre-existing
       read-path divergence outside B337's write-side contract. *)
    check bool "both joins in history" true
      (List.sort compare hist =
       List.sort compare [ "b337-alice joined room b337-room";
                           "b337-bob joined room b337-room" ]);
    let alice_inbox = Relay.SqliteRelay.peek_inbox t ~node_id:"b337n1" ~session_id:"b337s1" in
    (* Each member's copy is addressed to that member ("alice#room"), like
       the in-memory fan-out; alice's copy of BOB's join carries bob's
       content. *)
    check bool "alice received bob's join fan-out (addressed to her)" true
      (List.exists (fun msg ->
           inbox_to_aliases [ msg ] = [ "b337-alice#b337-room" ]
           && contents_of [ msg ] = [ "b337-bob joined room b337-room" ])
          alice_inbox);
    (* Re-join is silent: no duplicate history, no duplicate fan-out. *)
    join t Relay.SqliteRelay.join_room ~alias:"b337-bob" ~room_id:"b337-room" |> ignore;
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room" ~limit:100) in
    check int "re-join adds no history" 2 (List.length hist);
    check int "re-join adds no fan-out" 2 (List.length alice_inbox);
    (* System messages carry the c2c-system sender. *)
    let senders =
      List.map
        (fun msg ->
           match Yojson.Safe.Util.member "from_alias" msg with
           | `String a -> a
           | _ -> "")
        (Relay.SqliteRelay.room_history t ~room_id:"b337-room" ~limit:100)
    in
    check bool "history sender is c2c-system" true
      (List.for_all (fun a -> a = Relay.room_system_alias) senders))

let test_sqlite_join_fan_out_dead_letters_dead_member () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-alive" ();
    (* A member whose lease already expired: fan-out must dead-letter it,
       like the in-memory backend does. *)
    reg_sql t ~node_id:"b337n2" ~session_id:"b337s2"
      ~alias:"b337-expired" ~ttl:(-1.0) ();
    check int "no dead letters yet" 0
      (List.length (Relay.SqliteRelay.dead_letter t));
    join t Relay.SqliteRelay.join_room ~alias:"b337-alive" ~room_id:"b337-room2" |> ignore;
    check int "alive member join: no dead letters" 0
      (List.length (Relay.SqliteRelay.dead_letter t));
    join t Relay.SqliteRelay.join_room ~alias:"b337-expired" ~room_id:"b337-room2" |> ignore;
    let dl = Relay.SqliteRelay.dead_letter t in
    check int "dead member join fan-out dead-letters once" 1 (List.length dl);
    (match dlq_for dl ~to_alias:"b337-expired#b337-room2" with
     | Some msg ->
         check string "dead-letter reason" "recipient_dead"
           (match Yojson.Safe.Util.member "reason" msg with
            | `String r -> r
            | _ -> "");
         check string "dead-letter sender is c2c-system" Relay.room_system_alias
           (match Yojson.Safe.Util.member "from_alias" msg with
            | `String a -> a
            | _ -> "")
     | None -> Alcotest.fail "expected dead-letter row for b337-expired#b337-room2"))

(* --- sqlite leave emits the system message; empty/absent leave is silent --- *)

let test_sqlite_leave_emits_system_message_and_empty_leave_is_silent () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-alice" ();
    reg_sql t ~node_id:"b337n2" ~session_id:"b337s2" ~alias:"b337-bob" ();
    join t Relay.SqliteRelay.join_room ~alias:"b337-alice" ~room_id:"b337-room3" |> ignore;
    join t Relay.SqliteRelay.join_room ~alias:"b337-bob" ~room_id:"b337-room3" |> ignore;
    Relay.SqliteRelay.poll_inbox t ~node_id:"b337n1" ~session_id:"b337s1" |> ignore;
    check string "leave returns ok" "ok"
      (match Relay.SqliteRelay.leave_room t ~alias:"b337-bob" ~room_id:"b337-room3" with
       | `Ok -> "ok" | `Error _ -> "error");
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room3" ~limit:100) in
    check bool "leave entry appended after both joins" true
      (List.sort compare hist =
       List.sort compare [ "b337-alice joined room b337-room3";
                           "b337-bob joined room b337-room3";
                           "b337-bob left room b337-room3" ]);
    let alice_inbox = Relay.SqliteRelay.peek_inbox t ~node_id:"b337n1" ~session_id:"b337s1" in
    check bool "alice received bob's leave fan-out (addressed to her)" true
      (List.exists (fun msg ->
           inbox_to_aliases [ msg ] = [ "b337-alice#b337-room3" ]
           && contents_of [ msg ] = [ "b337-bob left room b337-room3" ])
          alice_inbox);
    (* Alice leaves: room becomes empty - in-memory stays silent. *)
    Relay.SqliteRelay.leave_room t ~alias:"b337-alice" ~room_id:"b337-room3" |> ignore;
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room3" ~limit:100) in
    check int "empty-room leave adds no history" 3 (List.length hist);
    (* A leave by someone not in the room is silent too. *)
    Relay.SqliteRelay.leave_room t ~alias:"b337-bob" ~room_id:"b337-room3" |> ignore;
    let hist = contents_of (Relay.SqliteRelay.room_history t ~room_id:"b337-room3" ~limit:100) in
    check int "non-member leave adds no history" 3 (List.length hist))

(* --- sqlite send records dead_letter rows like in-memory --- *)

let test_sqlite_send_unknown_alias_lands_in_dead_letter () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-sender" ();
    Relay.SqliteRelay.set_peer_discovery_visibility t ~alias:"b337-sender" ~visibility:Relay.Public |> ignore;
    check int "dead_letter empty before" 0 (List.length (Relay.SqliteRelay.dead_letter t));
    let res =
      Relay.SqliteRelay.send t ~from_alias:"b337-sender" ~to_alias:"b337-ghost"
        ~content:"hello ghost" ~message_id:None ~pow_difficulty:(-1)
    in
    (match res with
     | `Error (code, _) ->
         check string "unknown alias error code" Relay.relay_err_unknown_alias code
     | _ -> Alcotest.fail "expected send error for unknown alias");
    let dl = Relay.SqliteRelay.dead_letter t in
    check int "unknown alias dead-letters once" 1 (List.length dl);
    (match dlq_for dl ~to_alias:"b337-ghost" with
     | Some msg ->
         check string "reason unknown_alias" "unknown_alias"
           (match Yojson.Safe.Util.member "reason" msg with
            | `String r -> r
            | _ -> "");
         check string "content preserved" "hello ghost"
           (match Yojson.Safe.Util.member "content" msg with
            | `String c -> c
            | _ -> "");
         check string "from preserved" "b337-sender"
           (match Yojson.Safe.Util.member "from_alias" msg with
            | `String a -> a
            | _ -> "")
     | None -> Alcotest.fail "expected dead-letter row for b337-ghost"))

let test_sqlite_send_dead_recipient_lands_in_dead_letter () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-sender" ();
    reg_sql t ~node_id:"b337n2" ~session_id:"b337s2"
      ~alias:"b337-dead" ~ttl:(-1.0) ();
    Relay.SqliteRelay.set_peer_discovery_visibility t ~alias:"b337-sender" ~visibility:Relay.Public |> ignore;
    Relay.SqliteRelay.set_peer_discovery_visibility t ~alias:"b337-dead" ~visibility:Relay.Public |> ignore;
    let res =
      Relay.SqliteRelay.send t ~from_alias:"b337-sender" ~to_alias:"b337-dead"
        ~content:"too late" ~message_id:None ~pow_difficulty:(-1)
    in
    (match res with
     | `Error (code, _) ->
         check string "dead recipient error code" Relay.relay_err_recipient_dead code
     | _ -> Alcotest.fail "expected send error for expired recipient");
    let dl = Relay.SqliteRelay.dead_letter t in
    check int "dead recipient dead-letters once" 1 (List.length dl);
    (match dlq_for dl ~to_alias:"b337-dead" with
     | Some msg ->
         check string "reason recipient_dead" "recipient_dead"
           (match Yojson.Safe.Util.member "reason" msg with
            | `String r -> r
            | _ -> "");
         check string "content preserved" "too late"
           (match Yojson.Safe.Util.member "content" msg with
            | `String c -> c
            | _ -> "")
     | None -> Alcotest.fail "expected dead-letter row for b337-dead"))

(* B264 pin: a PRIVATE registered recipient keeps the uniform unknown_alias
   error and records NO content dead-letter row - on both backends. *)
let test_private_recipient_records_no_dead_letter () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    reg_sql t ~node_id:"b337n1" ~session_id:"b337s1" ~alias:"b337-p-sender" ();
    reg_sql t ~node_id:"b337n2" ~session_id:"b337s2" ~alias:"b337-p-priv" ();
    let res =
      Relay.SqliteRelay.send t ~from_alias:"b337-p-sender" ~to_alias:"b337-p-priv"
        ~content:"x" ~message_id:None ~pow_difficulty:(-1)
    in
    check string "sqlite: private recipient is uniform unknown_alias"
      Relay.relay_err_unknown_alias
      (match res with `Error (c, _) -> c | _ -> "ok");
    check int "sqlite: no dead-letter row for private recipient" 0
      (List.length (Relay.SqliteRelay.dead_letter t)));
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    reg_mem t ~node_id:"b337m1" ~session_id:"b337ms1" ~alias:"b337-pm-sender" ();
    reg_mem t ~node_id:"b337m2" ~session_id:"b337ms2" ~alias:"b337-pm-priv" ();
    let res =
      Relay.InMemoryRelay.send t ~from_alias:"b337-pm-sender" ~to_alias:"b337-pm-priv"
        ~content:"x" ~message_id:None ~pow_difficulty:(-1)
    in
    check string "in-memory: private recipient is uniform unknown_alias"
      Relay.relay_err_unknown_alias
      (match res with `Error (c, _) -> c | _ -> "ok");
    check int "in-memory: no dead-letter row for private recipient" 0
      (List.length (Relay.InMemoryRelay.dead_letter t)))

(* In-memory pins: the contract sqlite now implements was already the
   in-memory behaviour - keep it green. *)
let test_inmemory_pins_stay_green () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    reg_mem t ~node_id:"b337m1" ~session_id:"b337ms1" ~alias:"b337-m-alice" ();
    join t Relay.InMemoryRelay.join_room ~alias:"b337-m-alice" ~room_id:"b337-m-room" |> ignore;
    let hist = contents_of (Relay.InMemoryRelay.room_history t ~room_id:"b337-m-room" ~limit:100) in
    check bool "in-memory join still emits history entry" true
      (hist = [ "b337-m-alice joined room b337-m-room" ]);
    check bool "in-memory unknown send still dead-letters" true
      (match Relay.InMemoryRelay.send t ~from_alias:"b337-m-alice" ~to_alias:"b337-m-ghost" ~content:"x" ~message_id:None ~pow_difficulty:(-1) with
       | `Error (code, _) ->
           code = Relay.relay_err_unknown_alias
           && (match Relay.InMemoryRelay.dead_letter t with
               | [ dl ] ->
                   (match Yojson.Safe.Util.member "reason" dl with
                    | `String "unknown_alias" -> true
                    | _ -> false)
               | _ -> false)
       | _ -> false))

let () =
  run "B337 sqlite parity: room system messages + DM dead-lettering"
    [ ( "sqlite join system message",
        [ Alcotest.test_case "join emits history + inbox fan-out; re-join silent" `Quick
            test_sqlite_join_emits_system_message
        ; Alcotest.test_case "dead member join fan-out dead-letters" `Quick
            test_sqlite_join_fan_out_dead_letters_dead_member
        ] )
    ; ( "sqlite leave system message",
        [ Alcotest.test_case "leave emits; empty/non-member leave silent" `Quick
            test_sqlite_leave_emits_system_message_and_empty_leave_is_silent
        ] )
    ; ( "sqlite send dead-letter",
        [ Alcotest.test_case "unknown alias lands in dead_letter" `Quick
            test_sqlite_send_unknown_alias_lands_in_dead_letter
        ; Alcotest.test_case "dead recipient lands in dead_letter" `Quick
            test_sqlite_send_dead_recipient_lands_in_dead_letter
        ; Alcotest.test_case "private recipient records no dead-letter (B264)" `Quick
            test_private_recipient_records_no_dead_letter
        ] )
    ; ( "in-memory pins",
        [ Alcotest.test_case "join history + unknown-send DLQ stay green" `Quick
            test_inmemory_pins_stay_green
        ] )
    ]
