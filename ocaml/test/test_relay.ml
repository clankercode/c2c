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
  let lease = Relay.RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" () in
  if Relay.RegistrationLease.node_id lease <> "n1" then fail_fmt "node_id";
  if Relay.RegistrationLease.session_id lease <> "s1" then fail_fmt "session_id";
  if Relay.RegistrationLease.alias lease <> "a1" then fail_fmt "alias"

let test_lease_is_alive_fresh_lease () =
  let lease = Relay.RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:300.0 () in
  if not (Relay.RegistrationLease.is_alive lease) then fail_fmt "fresh lease should be alive"

let test_lease_is_alive_after_ttl_expires () =
  let lease = Relay.RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:0.01 () in
  Unix.sleep 1;
  if Relay.RegistrationLease.is_alive lease then fail_fmt "expired lease should be dead"

let test_lease_touch_updates_last_seen () =
  let lease = Relay.RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" ~ttl:300.0 () in
  let before = Unix.gettimeofday () in
  Unix.sleep 1;
  Relay.RegistrationLease.touch lease;
  let last_seen = Yojson.Safe.Util.(Relay.RegistrationLease.to_json lease |> member "last_seen" |> to_float) in
  if last_seen <= before then fail_fmt "last_seen should be updated"

(* ---- InMemoryRelay tests ---- *)

let make_test_relay () = Relay.InMemoryRelay.create ()

(* #379: cross-host alias@host helper unit tests *)
let test_split_alias_host_bare () =
  let alias, host = Relay.split_alias_host "alice" in
  Alcotest.(check string) "bare alias" "alice" alias;
  Alcotest.(check (option string)) "no host" None host

let test_split_alias_host_with_relay () =
  let alias, host = Relay.split_alias_host "alice@relay" in
  Alcotest.(check string) "alias stripped" "alice" alias;
  Alcotest.(check (option string)) "host relay" (Some "relay") host

let test_split_alias_host_with_real_host () =
  let alias, host = Relay.split_alias_host "alice@relay.c2c.im" in
  Alcotest.(check string) "alias stripped" "alice" alias;
  Alcotest.(check (option string)) "host real" (Some "relay.c2c.im") host

let test_host_acceptable_no_host_always_ok () =
  Alcotest.(check bool) "no host ok (self_host=None)" true
    (Relay.host_acceptable ~self_host:None None);
  Alcotest.(check bool) "no host ok (self_host=Some)" true
    (Relay.host_acceptable ~self_host:(Some "relay.c2c.im") None)

let test_host_acceptable_backcompat_relay_literal () =
  Alcotest.(check bool) "empty host ok" true
    (Relay.host_acceptable ~self_host:None (Some ""));
  Alcotest.(check bool) "relay literal ok" true
    (Relay.host_acceptable ~self_host:None (Some "relay"));
  Alcotest.(check bool) "relay literal ok even with self_host" true
    (Relay.host_acceptable ~self_host:(Some "relay.c2c.im") (Some "relay"))

let test_host_acceptable_rejects_unknown_host () =
  Alcotest.(check bool) "unknown host rejected (self_host=None)" false
    (Relay.host_acceptable ~self_host:None (Some "evil.example"));
  Alcotest.(check bool) "unknown host rejected (self_host=Some)" false
    (Relay.host_acceptable ~self_host:(Some "relay.c2c.im") (Some "evil.example"))

let test_host_acceptable_accepts_matching_self_host () =
  (* When self_host is set, the matching host is accepted *)
  Alcotest.(check bool) "matching self_host accepted" true
    (Relay.host_acceptable ~self_host:(Some "relay.c2c.im") (Some "relay.c2c.im"));
  (* When self_host is None, non-relay hosts are always rejected *)
  Alcotest.(check bool) "no self_host rejects non-relay host" false
    (Relay.host_acceptable ~self_host:None (Some "relay.c2c.im"))

let test_relay_register_creates_new_registration () =
  let t = make_test_relay () in
  let (status, lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  if status <> "ok" then fail_fmt "expected ok, got %s" status;
  if Relay.RegistrationLease.alias lease <> "alice" then fail_fmt "alias mismatch"

(* #578: registration receipt tests *)

let b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let json_get_field_exn json name =
  match List.assoc_opt name json with
  | Some v -> v
  | None -> fail_fmt "receipt: missing field %S" name

let json_string_exn = function
  | `String s -> s
  | _ -> fail_fmt "expected String"

let test_build_registration_receipt_json_has_all_fields () =
  let relay_identity = Relay_identity.generate ~alias_hint:"test-relay" () in
  let client_pk = Mirage_crypto_ec.Ed25519.generate () |> snd |> Mirage_crypto_ec.Ed25519.pub_to_octets in
  let client_pk_b64 = b64url client_pk in
  let ts = "2026-01-01T00:00:00Z" in
  let nonce = "test_nonce_b64_url_saf" in
  let receipt = Relay_signed_ops.build_registration_receipt_json
    ~identity:relay_identity
    ~alias:"test-alias"
    ~client_identity_pk_b64:client_pk_b64
    ~nonce
    ~ts
  in
  match receipt with
  | `Assoc fields ->
      let alias_s = json_string_exn (json_get_field_exn fields "alias") in
      if alias_s <> "test-alias" then fail_fmt "alias mismatch: %s" alias_s;
      let c_pk = json_string_exn (json_get_field_exn fields "client_identity_pk") in
      if c_pk <> client_pk_b64 then fail_fmt "client_identity_pk mismatch";
      let r_pk = json_string_exn (json_get_field_exn fields "relay_identity_pk") in
      if r_pk <> b64url relay_identity.Relay_identity.public_key
      then fail_fmt "relay_identity_pk mismatch";
      let ts_s = json_string_exn (json_get_field_exn fields "ts") in
      if ts_s <> ts then fail_fmt "ts mismatch";
      let nonce_s = json_string_exn (json_get_field_exn fields "nonce") in
      if nonce_s <> nonce then fail_fmt "nonce mismatch";
      let sig_s = json_string_exn (json_get_field_exn fields "sig") in
      if sig_s = "" then fail_fmt "sig must be non-empty"
  | _ -> fail_fmt "receipt should be Assoc"

let test_build_registration_receipt_json_sig_verifies () =
  let relay_identity = Relay_identity.generate ~alias_hint:"test-relay" () in
  let client_pk = Mirage_crypto_ec.Ed25519.generate () |> snd |> Mirage_crypto_ec.Ed25519.pub_to_octets in
  let client_pk_b64 = b64url client_pk in
  let ts = "2026-01-01T00:00:00Z" in
  let nonce = "test_nonce_b64_url_saf" in
  let receipt = Relay_signed_ops.build_registration_receipt_json
    ~identity:relay_identity
    ~alias:"test-alias"
    ~client_identity_pk_b64:client_pk_b64
    ~nonce
    ~ts
  in
  match receipt with
  | `Assoc fields ->
      let relay_pk = json_string_exn (json_get_field_exn fields "relay_identity_pk") in
      let sig_s = json_string_exn (json_get_field_exn fields "sig") in
      (* reconstruct the blob and verify the signature *)
      let blob = Relay_identity.canonical_msg ~ctx:Relay_signed_ops.receipt_sign_ctx
        [ "test-alias"; client_pk_b64; relay_pk; ts; nonce ]
      in
      let sig_bytes = match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_s with
        | Ok s -> s | Error _ -> fail_fmt "sig b64 decode failed"
      in
      let relay_pk_bytes = match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet relay_pk with
        | Ok s -> s | Error _ -> fail_fmt "relay_pk b64 decode failed"
      in
      if not (Relay_identity.verify ~pk:relay_pk_bytes ~msg:blob ~sig_:sig_bytes)
      then fail_fmt "receipt signature failed to verify"
  | _ -> fail_fmt "receipt should be Assoc"

let test_receipt_sign_ctx_is_unique () =
  if Relay_signed_ops.receipt_sign_ctx = Relay_signed_ops.register_sign_ctx
  then fail_fmt "receipt_sign_ctx must differ from register_sign_ctx";
  if Relay_signed_ops.receipt_sign_ctx = Relay_signed_ops.request_sign_ctx
  then fail_fmt "receipt_sign_ctx must differ from request_sign_ctx"

let test_relay_register_same_alias_different_node_raises_conflict () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (status, _) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"alice" () in
  if status <> Relay.relay_err_alias_conflict then fail_fmt "expected alias_conflict, got %s" status

let test_relay_heartbeat_refreshes_existing () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:1.0 () in
  Unix.sleep 1;
  let (status, lease) = Relay.InMemoryRelay.heartbeat t ~node_id:"n1" ~session_id:"s1" in
  if status <> "ok" then fail_fmt "expected ok, got %s" status;
  if not (Relay.RegistrationLease.is_alive lease) then fail_fmt "lease should still be alive"

let test_relay_heartbeat_unknown_session_raises_error () =
  let t = make_test_relay () in
  let (status, _) = Relay.InMemoryRelay.heartbeat t ~node_id:"nope" ~session_id:"nope" in
  if status <> Relay.relay_err_unknown_alias then fail_fmt "expected unknown_alias, got %s" status

(* F4: relay-side re-registration inbox migration.
   register A → send to A → A re-registers with new session_id → assert A's new inbox has the messages. *)
let test_relay_reregister_migrates_inbox () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  (* Bob sends 3 messages to alice while alice's lease is n1/s1 *)
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg1" ~message_id:None in
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg2" ~message_id:None in
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg3" ~message_id:None in
  (* Alice re-registers with same node_id but new session_id (simulates restart/reconnect) *)
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1_new" ~alias:"alice" () in
  (* Alice polls her NEW session — with the F4 fix she should get all 3 migrated messages.
     Note: send prepends (msg :: inbox), so order is newest-first: [msg3; msg2; msg1]. *)
  let inbox = Relay.InMemoryRelay.poll_inbox t ~node_id:"n1" ~session_id:"s1_new" in
  if List.length inbox <> 3 then fail_fmt "alice inbox should have 3 messages after re-reg, got %d" (List.length inbox);
  let contents = List.map (fun m -> json_get_string m "content") inbox in
  if contents <> ["msg3"; "msg2"; "msg1"] then fail_fmt "content mismatch: %s" (String.concat "," contents)

let test_relay_send_delivers_to_recipient () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  match Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"hello bob" ~message_id:None with
  | `Ok ts ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      let inbox = Relay.InMemoryRelay.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
      if List.length inbox <> 1 then fail_fmt "inbox should have 1 message";
      let msg = List.hd inbox in
      if json_get_string msg "content" <> "hello bob" then fail_fmt "content mismatch";
      if json_get_string msg "from_alias" <> "alice" then fail_fmt "from_alias mismatch"
  | _ -> fail_fmt "expected Ok"

let test_relay_send_to_unknown_alias_goes_to_dead_letter () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  match Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"nobody" ~content:"hello" ~message_id:None with
  | `Error (err, _) ->
      if err <> Relay.relay_err_unknown_alias then fail_fmt "expected unknown_alias, got %s" err;
      let dl = Relay.InMemoryRelay.dead_letter t in
      if List.length dl <> 1 then fail_fmt "dead letter should have 1 entry";
      if json_get_string (List.hd dl) "reason" <> "unknown_alias" then fail_fmt "reason mismatch"
  | _ -> fail_fmt "expected Error"

let test_relay_poll_inbox_drains () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" ~message_id:None in
  let first = Relay.InMemoryRelay.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length first <> 1 then fail_fmt "first poll should return 1";
  let second = Relay.InMemoryRelay.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length second <> 0 then fail_fmt "second poll should return 0"

let test_relay_peek_inbox_does_not_drain () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" ~message_id:None in
  let first = Relay.InMemoryRelay.peek_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length first <> 1 then fail_fmt "first peek should return 1";
  let second = Relay.InMemoryRelay.peek_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length second <> 1 then fail_fmt "second peek should return 1"

let test_relay_send_all_broadcasts_to_all_except_sender () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"carol" () in
  match Relay.InMemoryRelay.send_all t ~from_alias:"alice" ~content:"broadcast" ~message_id:None with
  | `Ok (ts, delivered, skipped) ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      if List.length delivered <> 2 then fail_fmt "should deliver to 2";
      if List.mem "alice" delivered then fail_fmt "alice should not be in delivered";
      if not (List.mem "bob" delivered && List.mem "carol" delivered) then fail_fmt "bob and carol should be delivered";
      if List.length skipped <> 0 then fail_fmt "no skipped"
  | _ -> fail_fmt "expected Ok"

let test_relay_join_room_adds_member () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  match Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" with
  | `Ok -> ()
  | `Error (err, msg) -> fail_fmt "join_room failed: %s %s" err msg;
  let rooms = Relay.InMemoryRelay.list_rooms t in
  if List.length rooms <> 1 then fail_fmt "should have 1 room";
  let room = List.hd rooms in
  if json_get_string room "room_id" <> "test-room" then fail_fmt "room_id mismatch";
  if json_get_int room "member_count" <> 1 then fail_fmt "member_count should be 1"

let test_relay_leave_room_removes_member () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"test-room" in
  let _ = Relay.InMemoryRelay.leave_room t ~alias:"alice" ~room_id:"test-room" in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  let members = json_get_list (List.hd rooms) "members" in
  if List.length members <> 1 then fail_fmt "should have 1 member left";
  if Yojson.Safe.Util.(List.hd members |> to_string) <> "bob" then fail_fmt "bob should remain"

let test_relay_send_room_delivers_to_all_except_sender () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"carol" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"test-room" in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"carol" ~room_id:"test-room" in
  match Relay.InMemoryRelay.send_room t ~from_alias:"alice" ~room_id:"test-room" ~content:"room msg" () with
  | `Ok (ts, delivered, skipped) ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      if List.length delivered <> 2 then fail_fmt "should deliver to 2";
      if List.mem "alice" delivered then fail_fmt "alice should not be in delivered";
      if List.length skipped <> 0 then fail_fmt "no skipped"
  | _ -> fail_fmt "expected Ok"

let test_relay_gc_removes_expired_leases () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:0.01 () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" ~ttl:300.0 () in
  Unix.sleep 1;
  match Relay.InMemoryRelay.gc t with
  | `Ok (expired, pruned) ->
      if List.length expired <> 1 then fail_fmt "should have 1 expired";
      if List.hd expired <> "alice" then fail_fmt "alice should be expired";
      let peers = Relay.InMemoryRelay.list_peers ~include_dead:true t in
      if List.length peers <> 1 then fail_fmt "only bob should remain"
  | _ -> fail_fmt "gc should return Ok"

let test_relay_list_rooms_shows_all_with_counts () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"room-1" in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"room-2" in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"room-1" in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  if List.length rooms <> 2 then fail_fmt "should have 2 rooms";
  let room1 = List.find (fun r -> json_get_string r "room_id" = "room-1") rooms in
  if json_get_int room1 "member_count" <> 2 then fail_fmt "room-1 should have 2 members";
  let room2 = List.find (fun r -> json_get_string r "room_id" = "room-2") rooms in
  if json_get_int room2 "member_count" <> 1 then fail_fmt "room-2 should have 1 member"

(* ---- #330 V1: cross_host_not_implemented error-path seam tests ---- *)

(* Simulate the handle_send cross-host validation seam at InMemoryRelay level.
   Matches relay.ml:3170-3191: split alias@host, check host_acceptable,
   write dead_letter on rejection. This is the seam the forwarder (V2) will
   replace with a relay-to-relay POST. *)
let send_with_cross_host_check relay ~from_alias ~to_alias ~content =
  let stripped, host_opt = Relay.split_alias_host to_alias in
  let self_host = Relay.InMemoryRelay.self_host relay in
  if not (Relay.host_acceptable ~self_host host_opt) then begin
    (* Mirror relay.ml:3177-3187: generate dead_letter entry with reason
       cross_host_not_implemented before returning the error. *)
    let msg_id = Uuidm.to_string (Uuidm.v `V4) in
    let ts = Unix.gettimeofday () in
    let dl = `Assoc [
      ("ts", `Float ts);
      ("message_id", `String msg_id);
      ("from_alias", `String from_alias);
      ("to_alias", `String to_alias);
      ("content", `String content);
      ("reason", `String "cross_host_not_implemented");
    ] in
    Relay.InMemoryRelay.add_dead_letter relay dl;
    `Cross_host_rejected
      (Printf.sprintf "cross-host send to %S not supported (relay does not forward to other hosts)" to_alias)
  end else
    match Relay.InMemoryRelay.send relay ~from_alias ~to_alias:stripped ~content ~message_id:None with
    | `Ok ts -> `Ok ts
    | `Duplicate ts -> `Duplicate ts
    | `Error (err, msg) -> `Error (err, msg)

(* #330 V1 S6: back-compat bare alias send still works when self_host is set.
   Regression test: setting self_host must NOT break bare-alias sends (the
   host_acceptable check passes when host_opt=None, so bare alias → normal delivery). *)
let test_cross_host_bare_alias_works_when_self_host_is_set () =
  let relay = Relay.InMemoryRelay.create ~self_host:(Some "hostA") () in
  let (_status_a, _lease_a) = Relay.InMemoryRelay.register relay
    ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status_b, _lease_b) = Relay.InMemoryRelay.register relay
    ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  (* bare alias send — host_opt=None, host_acceptable returns true regardless
     of self_host, so this goes through as a normal local delivery *)
  match send_with_cross_host_check relay
    ~from_alias:"alice" ~to_alias:"bob" ~content:"hello bob" with
  | `Cross_host_rejected reason ->
      fail_fmt "bare alias 'bob' should NOT be rejected when self_host is set, got: %s" reason
  | `Ok _ts ->
      let inbox = Relay.InMemoryRelay.poll_inbox relay ~node_id:"n2" ~session_id:"s2" in
      if List.length inbox <> 1 then fail_fmt "expected 1 message in bob's inbox, got %d" (List.length inbox);
      Alcotest.(check string) "content" "hello bob" (json_get_string (List.hd inbox) "content");
      Alcotest.(check string) "from_alias" "alice" (json_get_string (List.hd inbox) "from_alias")
  | `Duplicate _ts -> fail_fmt "unexpected Duplicate for fresh bare-alias send"
  | `Error (err, msg) -> fail_fmt "bare alias send failed: %s %s" err msg

(* #330 V1 S2: alias@matching_self_host accepted, alias@unknown_host rejected.
   When self_host=Some "hostA", bob@hostA is accepted (matching) and delivered
   to bare alias "bob"; bob@hostZ is rejected with cross_host_not_implemented
   and the rejection is written to dead_letter. *)
let test_cross_host_alias_matching_self_host_accepted () =
  let relay = Relay.InMemoryRelay.create ~self_host:(Some "hostA") () in
  let (_status_a, _lease_a) = Relay.InMemoryRelay.register relay
    ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status_b, _lease_b) = Relay.InMemoryRelay.register relay
    ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  (* bob@hostA matches self_host=Some "hostA" — host_acceptable returns true,
     send goes through to bare alias "bob" *)
  match send_with_cross_host_check relay
    ~from_alias:"alice" ~to_alias:"bob@hostA" ~content:"hello bob via hostA" with
  | `Cross_host_rejected reason ->
      fail_fmt "bob@hostA should be accepted (matches self_host), got: %s" reason
  | `Ok _ts ->
      let inbox = Relay.InMemoryRelay.poll_inbox relay ~node_id:"n2" ~session_id:"s2" in
      if List.length inbox <> 1 then fail_fmt "expected 1 message, got %d" (List.length inbox);
      Alcotest.(check string) "content" "hello bob via hostA"
        (json_get_string (List.hd inbox) "content")
  | `Duplicate _ts -> fail_fmt "unexpected Duplicate"
  | `Error (err, msg) -> fail_fmt "bob@hostA send failed: %s %s" err msg

let test_cross_host_alias_unknown_host_rejected () =
  let relay = Relay.InMemoryRelay.create ~self_host:(Some "hostA") () in
  let (_status_a, _lease_a) = Relay.InMemoryRelay.register relay
    ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status_b, _lease_b) = Relay.InMemoryRelay.register relay
    ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  (* bob@hostZ is unknown (hostZ != self_host="hostA") — host_acceptable
     returns false, dead_letter is written, error is returned *)
  match send_with_cross_host_check relay
    ~from_alias:"alice" ~to_alias:"bob@hostZ" ~content:"hello bob via hostZ" with
  | `Cross_host_rejected reason ->
      if not (String.length reason > 0) then fail_fmt "expected non-empty rejection reason";
      let dl = Relay.InMemoryRelay.dead_letter relay in
      if List.length dl <> 1 then
        fail_fmt "expected 1 dead_letter entry after cross-host rejection, got %d" (List.length dl);
      let entry = List.hd dl in
      Alcotest.(check string) "dead_letter reason" "cross_host_not_implemented"
        (json_get_string entry "reason");
      Alcotest.(check string) "dead_letter to_alias" "bob@hostZ"
        (json_get_string entry "to_alias");
      Alcotest.(check string) "dead_letter from_alias" "alice"
        (json_get_string entry "from_alias");
      Alcotest.(check bool) "rejection reason non-empty" true (String.length reason > 0)
  | `Ok _ts -> fail_fmt "bob@hostZ should be rejected but got Ok"
  | `Duplicate _ts -> fail_fmt "bob@hostZ should be rejected but got Duplicate"
  | `Error (err, msg) -> fail_fmt "bob@hostZ should be rejected with Cross_host_rejected, got Error: %s %s" err msg

(* ---- Run tests ---- *)

let tests = [
  "lease make creates correct fields", test_lease_make_creates_correct_fields;
  "lease is_alive fresh", test_lease_is_alive_fresh_lease;
  "lease is_alive expired", test_lease_is_alive_after_ttl_expires;
  "lease touch updates last_seen", test_lease_touch_updates_last_seen;
  "relay register creates new", test_relay_register_creates_new_registration;
  "relay register conflict", test_relay_register_same_alias_different_node_raises_conflict;
  (* #578 signed registration receipt *)
  "receipt build has all fields", test_build_registration_receipt_json_has_all_fields;
  "receipt sig verifies", test_build_registration_receipt_json_sig_verifies;
  "receipt_sign_ctx is unique", test_receipt_sign_ctx_is_unique;
  "relay heartbeat ok", test_relay_heartbeat_refreshes_existing;
  "relay heartbeat unknown", test_relay_heartbeat_unknown_session_raises_error;
  (* F4: relay-side re-registration inbox migration *)
  "relay reregister migrates inbox", test_relay_reregister_migrates_inbox;
  "relay send delivers", test_relay_send_delivers_to_recipient;
  "relay send unknown to dead_letter", test_relay_send_to_unknown_alias_goes_to_dead_letter;
  (* #379 cross-host alias@host unit tests *)
  "split bare alias", test_split_alias_host_bare;
  "split alias@relay", test_split_alias_host_with_relay;
  "split alias@real.host", test_split_alias_host_with_real_host;
  "host_acceptable no host always ok", test_host_acceptable_no_host_always_ok;
  "host_acceptable relay literal backcompat", test_host_acceptable_backcompat_relay_literal;
  "host_acceptable rejects unknown host", test_host_acceptable_rejects_unknown_host;
  "host_acceptable accepts matching self_host", test_host_acceptable_accepts_matching_self_host;
  "relay poll_inbox drains", test_relay_poll_inbox_drains;
  "relay peek_inbox does not drain", test_relay_peek_inbox_does_not_drain;
  "relay send_all broadcasts", test_relay_send_all_broadcasts_to_all_except_sender;
  "relay join_room adds member", test_relay_join_room_adds_member;
  "relay leave_room removes member", test_relay_leave_room_removes_member;
  "relay send_room delivers", test_relay_send_room_delivers_to_all_except_sender;
  "relay gc removes expired", test_relay_gc_removes_expired_leases;
  "relay list_rooms with counts", test_relay_list_rooms_shows_all_with_counts;
  (* #330 V1 cross_host_not_implemented error-path seam tests *)
  "cross_host bare alias works when self_host is set", test_cross_host_bare_alias_works_when_self_host_is_set;
  "cross_host alias@matching self_host accepted", test_cross_host_alias_matching_self_host_accepted;
  "cross_host alias@unknown host rejected to dead_letter", test_cross_host_alias_unknown_host_rejected;
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
