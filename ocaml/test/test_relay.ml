(* test_relay.ml — unit tests for InMemoryRelay *)

let fail_fmt fmt = Printf.ksprintf (fun s -> failwith s) fmt

let json_get_string json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | _ -> fail_fmt "json_get_string: key %S not found or not string" key)
  | _ -> fail_fmt "json_get_string: expected Assoc for key %S" key

let json_get_int json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Int i) -> i
       | _ -> fail_fmt "json_get_int: key %S not found or not int" key)
  | _ -> fail_fmt "json_get_int: expected Assoc for key %S" key

let json_get_list json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List l) -> l
       | _ -> fail_fmt "json_get_list: key %S not found or not list" key)
  | _ -> fail_fmt "json_get_list: expected Assoc for key %S" key

(* ---- RegistrationLease tests ---- *)

let test_lease_make_creates_correct_fields () =
  let R = C2c_relay.RegistrationLease in
  let lease = R.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" () in
  if R.node_id lease <> "n1" then fail_fmt "node_id";
  if R.session_id lease <> "s1" then fail_fmt "session_id";
  if R.alias lease <> "a1" then fail_fmt "alias"

let test_lease_is_alive_fresh_lease () =
  let R = C2c_relay.RegistrationLease in
  let lease = R.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:300.0 () in
  if not (R.is_alive lease) then fail_fmt "fresh lease should be alive"

let test_lease_is_alive_after_ttl_expires () =
  let R = C2c_relay.RegistrationLease in
  let lease = R.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:0.01 () in
  Unix.sleep 1;
  if R.is_alive lease then fail_fmt "expired lease should be dead"

let test_lease_touch_updates_last_seen () =
  let R = C2c_relay.RegistrationLease in
  let lease = R.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:300.0 () in
  let before = Unix.gettimeofday () in
  Unix.sleep 1;
  R.touch lease;
  let last_seen = Yojson.Safe.Util.(lease |> R.to_json |> Yojson.Safe.Util.member "last_seen" |> Yojson.Safe.Util.to_float) in
  if last_seen <= before then fail_fmt "last_seen should be updated"

(* ---- InMemoryRelay tests ---- *)

let make_test_relay () = C2c_relay.InMemoryRelay.create ()

let test_relay_register_creates_new_registration () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (status, lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  if status <> "ok" then fail_fmt "expected ok, got %s" status;
  if C2c_relay.RegistrationLease.alias lease <> "alice" then fail_fmt "alias mismatch"

let test_relay_register_same_alias_different_node_raises_conflict () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (status, _) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"alice" () in
  if status <> C2c_relay.relay_err_alias_conflict then fail_fmt "expected alias_conflict, got %s" status

let test_relay_heartbeat_refreshes_existing () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:1.0 () in
  Unix.sleep 1;
  let (status, lease) = R.heartbeat t ~node_id:"n1" ~session_id:"s1" in
  if status <> "ok" then fail_fmt "expected ok, got %s" status;
  if not (C2c_relay.RegistrationLease.is_alive lease) then fail_fmt "lease should still be alive"

let test_relay_heartbeat_unknown_session_raises_error () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (status, _) = R.heartbeat t ~node_id:"nope" ~session_id:"nope" in
  if status <> C2c_relay.relay_err_unknown_alias then fail_fmt "expected unknown_alias, got %s" status

let test_relay_send_delivers_to_recipient () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  match R.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"hello bob" () with
  | `Ok ts ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      let inbox = R.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
      if List.length inbox <> 1 then fail_fmt "inbox should have 1 message";
      let msg = List.hd inbox in
      if json_get_string msg "content" <> "hello bob" then fail_fmt "content mismatch";
      if json_get_string msg "from_alias" <> "alice" then fail_fmt "from_alias mismatch"
  | _ -> fail_fmt "expected Ok"

let test_relay_send_to_unknown_alias_goes_to_dead_letter () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  match R.send t ~from_alias:"alice" ~to_alias:"nobody" ~content:"hello" () with
  | `Error (err, _) ->
      if err <> C2c_relay.relay_err_unknown_alias then fail_fmt "expected unknown_alias, got %s" err;
      let dl = R.dead_letter t in
      if List.length dl <> 1 then fail_fmt "dead letter should have 1 entry";
      if json_get_string (List.hd dl) "reason" <> "unknown_alias" then fail_fmt "reason mismatch"
  | _ -> fail_fmt "expected Error"

let test_relay_poll_inbox_drains () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = R.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" () in
  let first = R.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length first <> 1 then fail_fmt "first poll should return 1";
  let second = R.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length second <> 0 then fail_fmt "second poll should return 0"

let test_relay_peek_inbox_does_not_drain () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = R.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" () in
  let first = R.peek_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length first <> 1 then fail_fmt "first peek should return 1";
  let second = R.peek_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length second <> 1 then fail_fmt "second peek should return 1"

let test_relay_send_all_broadcasts_to_all_except_sender () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let (_status, _lease) = R.register t ~node_id:"n3" ~session_id:"s3" ~alias:"carol" () in
  match R.send_all t ~from_alias:"alice" ~content:"broadcast" () with
  | `Ok (ts, delivered, skipped) ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      if List.length delivered <> 2 then fail_fmt "should deliver to 2";
      if List.mem "alice" delivered then fail_fmt "alice should not be in delivered";
      if not (List.mem "bob" delivered && List.mem "carol" delivered) then fail_fmt "bob and carol should be delivered";
      if List.length skipped <> 0 then fail_fmt "no skipped"
  | _ -> fail_fmt "expected Ok"

let test_relay_join_room_adds_member () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  match R.join_room t ~alias:"alice" ~room_id:"test-room" () with
  | `Ok -> ()
  | `Error (err, msg) -> fail_fmt "join_room failed: %s %s" err msg;
  let rooms = R.list_rooms t in
  if List.length rooms <> 1 then fail_fmt "should have 1 room";
  let room = List.hd rooms in
  if json_get_string room "room_id" <> "test-room" then fail_fmt "room_id mismatch";
  if json_get_int room "member_count" <> 1 then fail_fmt "member_count should be 1"

let test_relay_leave_room_removes_member () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = R.join_room t ~alias:"alice" ~room_id:"test-room" () in
  let _ = R.join_room t ~alias:"bob" ~room_id:"test-room" () in
  let _ = R.leave_room t ~alias:"alice" ~room_id:"test-room" () in
  let rooms = R.list_rooms t in
  let members = json_get_list (List.hd rooms) "members" in
  if List.length members <> 1 then fail_fmt "should have 1 member left";
  if Yojson.Safe.Util.(List.hd members |> to_string) <> "bob" then fail_fmt "bob should remain"

let test_relay_send_room_delivers_to_all_except_sender () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let (_status, _lease) = R.register t ~node_id:"n3" ~session_id:"s3" ~alias:"carol" () in
  let _ = R.join_room t ~alias:"alice" ~room_id:"test-room" () in
  let _ = R.join_room t ~alias:"bob" ~room_id:"test-room" () in
  let _ = R.join_room t ~alias:"carol" ~room_id:"test-room" () in
  match R.send_room t ~from_alias:"alice" ~room_id:"test-room" ~content:"room msg" () with
  | `Ok (ts, delivered, skipped) ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      if List.length delivered <> 2 then fail_fmt "should deliver to 2";
      if List.mem "alice" delivered then fail_fmt "alice should not be in delivered";
      if List.length skipped <> 0 then fail_fmt "no skipped"
  | _ -> fail_fmt "expected Ok"

let test_relay_gc_removes_expired_leases () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:0.01 () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" ~ttl:300.0 () in
  Unix.sleep 1;
  match R.gc t with
  | `Ok (expired, pruned) ->
      if List.length expired <> 1 then fail_fmt "should have 1 expired";
      if List.hd expired <> "alice" then fail_fmt "alice should be expired";
      let peers = R.list_peers ~include_dead:true t in
      if List.length peers <> 1 then fail_fmt "only bob should remain"
  | _ -> fail_fmt "gc should return Ok"

let test_relay_list_rooms_shows_all_with_counts () =
  let t = make_test_relay () in
  let R = C2c_relay.InMemoryRelay in
  let (_status, _lease) = R.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = R.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = R.join_room t ~alias:"alice" ~room_id:"room-1" () in
  let _ = R.join_room t ~alias:"alice" ~room_id:"room-2" () in
  let _ = R.join_room t ~alias:"bob" ~room_id:"room-1" () in
  let rooms = R.list_rooms t in
  if List.length rooms <> 2 then fail_fmt "should have 2 rooms";
  let room1 = List.find (fun r -> json_get_string r "room_id" = "room-1") rooms in
  if json_get_int room1 "member_count" <> 2 then fail_fmt "room-1 should have 2 members";
  let room2 = List.find (fun r -> json_get_string r "room_id" = "room-2") rooms in
  if json_get_int room2 "member_count" <> 1 then fail_fmt "room-2 should have 1 member"

(* ---- Run tests ---- *)

let tests = [
  "lease make creates correct fields", test_lease_make_creates_correct_fields;
  "lease is_alive fresh", test_lease_is_alive_fresh_lease;
  "lease is_alive expired", test_lease_is_alive_after_ttl_expires;
  "lease touch updates last_seen", test_lease_touch_updates_last_seen;
  "relay register creates new", test_relay_register_creates_new_registration;
  "relay register conflict", test_relay_register_same_alias_different_node_raises_conflict;
  "relay heartbeat ok", test_relay_heartbeat_refreshes_existing;
  "relay heartbeat unknown", test_relay_heartbeat_unknown_session_raises_error;
  "relay send delivers", test_relay_send_delivers_to_recipient;
  "relay send unknown to dead_letter", test_relay_send_to_unknown_alias_goes_to_dead_letter;
  "relay poll_inbox drains", test_relay_poll_inbox_drains;
  "relay peek_inbox does not drain", test_relay_peek_inbox_does_not_drain;
  "relay send_all broadcasts", test_relay_send_all_broadcasts_to_all_except_sender;
  "relay join_room adds member", test_relay_join_room_adds_member;
  "relay leave_room removes member", test_relay_leave_room_removes_member;
  "relay send_room delivers", test_relay_send_room_delivers_to_all_except_sender;
  "relay gc removes expired", test_relay_gc_removes_expired_leases;
  "relay list_rooms with counts", test_relay_list_rooms_shows_all_with_counts;
]

let () =
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      Printf.printf "[PASS] %s\n%!" name;
      incr passed
    with e ->
      Printf.printf "[FAIL] %s: %s\n%!" name (Printexc.to_string e);
      incr failed
  ) tests;
  Printf.printf "\n%d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1
