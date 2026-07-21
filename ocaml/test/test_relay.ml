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

let json_get_float json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> f
       | Some (`Int i) -> float_of_int i
       | _ -> fail_fmt "json_get_float: key %S not found or not number" key)
  | _ -> fail_fmt "json_get_float: expected Assoc for key %S" key

let json_get_bool json key =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool b) -> b
       | _ -> fail_fmt "json_get_bool: key %S not found or not bool" key)
  | _ -> fail_fmt "json_get_bool: expected Assoc for key %S" key

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

let test_alias_retention_policy_boundaries () =
  let now = 1_000_000_000.0 in
  let fresh_last_seen = now -. 60.0 in
  if Relay.alias_release_warning ~now ~last_seen:fresh_last_seen then
    fail_fmt "fresh alias should not warn";
  if Relay.alias_released ~now ~last_seen:fresh_last_seen then
    fail_fmt "fresh alias should not be released";
  let warning_last_seen = now -. Relay.alias_warning_after_s -. 1.0 in
  if not (Relay.alias_release_warning ~now ~last_seen:warning_last_seen) then
    fail_fmt "alias should warn after 3 months unseen";
  if Relay.alias_released ~now ~last_seen:warning_last_seen then
    fail_fmt "warning alias should still be reserved";
  let released_last_seen = now -. Relay.alias_release_after_s -. 1.0 in
  if not (Relay.alias_released ~now ~last_seen:released_last_seen) then
    fail_fmt "alias should release after 12 months unseen"

let test_relay_released_alias_hides_identity_before_gc () =
  let t = Relay.InMemoryRelay.create () in
  let identity_pk = "alice-identity-pk" in
  let enc_pubkey = "alice-enc-pk" in
  let sig_b64 = "alice-sig" in
  let (status, lease) =
    Relay.InMemoryRelay.register t
      ~node_id:"n1" ~session_id:"s1" ~alias:"alice"
      ~identity_pk ~enc_pubkey ~signed_at:123.0 ~sig_b64 ()
  in
  if status <> "ok" then fail_fmt "inmemory: setup register failed: %s" status;
  let (_bob_status, _) = Relay.InMemoryRelay.register t ~node_id:"n-bob" ~session_id:"s-bob" ~alias:"bob" () in
  let (_carol_status, carol_lease) =
    Relay.InMemoryRelay.register t ~node_id:"n-carol" ~session_id:"s-carol" ~alias:"carol" ()
  in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"retention-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"retention-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"carol" ~room_id:"retention-room" () in
  if Relay.InMemoryRelay.identity_pk_of t ~alias:"alice" <> Some identity_pk then
    fail_fmt "inmemory: setup identity lookup should succeed before release";
  if not (Relay.InMemoryRelay.is_room_member_alias t ~room_id:"retention-room" ~alias:"alice") then
    fail_fmt "inmemory: setup room membership should be visible before release";
  Relay.RegistrationLease.set_last_seen lease
    (Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
  if Relay.InMemoryRelay.identity_pk_of t ~alias:"alice" <> None then
    fail_fmt "inmemory: released alias should hide identity_pk before gc";
  if Relay.InMemoryRelay.alias_of_identity_pk t ~identity_pk <> None then
    fail_fmt "inmemory: released alias should not reverse-map identity_pk before gc";
  if Relay.InMemoryRelay.alias_of_session t ~node_id:"n1" ~session_id:"s1" <> None then
    fail_fmt "inmemory: released alias should not map session before gc";
  if Relay.InMemoryRelay.enc_pubkey_of t ~alias:"alice" <> None then
    fail_fmt "inmemory: released alias should hide enc_pubkey before gc";
  if Relay.InMemoryRelay.signed_at_of t ~alias:"alice" <> None then
    fail_fmt "inmemory: released alias should hide signed_at before gc";
  if Relay.InMemoryRelay.sig_b64_of t ~alias:"alice" <> None then
    fail_fmt "inmemory: released alias should hide sig before gc";
  if Relay.InMemoryRelay.is_room_member_alias t ~room_id:"retention-room" ~alias:"alice" then
    fail_fmt "inmemory: released alias should not authorize as room member before gc";
  (match Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"retention-room" () with
   | `Error (err, _) when err = Relay.relay_err_unknown_alias -> ()
   | `Error (err, _) -> fail_fmt "inmemory: released alias join should be unknown_alias, got %s" err
   | `Ok -> fail_fmt "inmemory: released alias should not rejoin before gc");
  Relay.RegistrationLease.set_last_seen carol_lease
    (Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
  (match Relay.InMemoryRelay.send_room t ~from_alias:"carol" ~room_id:"retention-room" ~content:"after release" () with
   | `Error (err, _) when err = Relay.relay_err_unknown_alias -> ()
   | `Error (err, _) -> fail_fmt "inmemory: released alias send_room should be unknown_alias, got %s" err
   | `Ok _ -> fail_fmt "inmemory: released alias should not send_room before gc");
  let (hb_status, _) = Relay.InMemoryRelay.heartbeat t ~node_id:"n1" ~session_id:"s1" ?opaque_host_id:None in
  if hb_status <> Relay.relay_err_unknown_alias then
    fail_fmt "inmemory: heartbeat should not revive released alias, got %s" hb_status;
  if Relay.InMemoryRelay.identity_pk_of t ~alias:"alice" <> None then
    fail_fmt "inmemory: heartbeat must not restore released identity"

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
  let (status, lease) = Relay.InMemoryRelay.heartbeat t ~node_id:"n1" ~session_id:"s1" ?opaque_host_id:None in
  if status <> "ok" then fail_fmt "expected ok, got %s" status;
  if not (Relay.RegistrationLease.is_alive lease) then fail_fmt "lease should still be alive"

let test_relay_heartbeat_unknown_session_raises_error () =
  let t = make_test_relay () in
  let (status, _) = Relay.InMemoryRelay.heartbeat t ~node_id:"nope" ~session_id:"nope" ?opaque_host_id:None in
  if status <> Relay.relay_err_unknown_alias then fail_fmt "expected unknown_alias, got %s" status

(* F4: relay-side re-registration inbox migration.
   register A → send to A → A re-registers with new session_id → assert A's new inbox has the messages. *)
let test_relay_reregister_migrates_inbox () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  (* Bob sends 3 messages to alice while alice's lease is n1/s1 *)
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg1" ~message_id:None ~pow_difficulty:(-1) in
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg2" ~message_id:None ~pow_difficulty:(-1) in
  let (_: [> `Ok of float | `Duplicate of float | `Error of string * string]) =
    Relay.InMemoryRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"msg3" ~message_id:None ~pow_difficulty:(-1) in
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
  match Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"hello bob" ~message_id:None ~pow_difficulty:(-1) with
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
  match Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"nobody" ~content:"hello" ~message_id:None ~pow_difficulty:(-1) with
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
  let _ = Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" ~message_id:None ~pow_difficulty:(-1) in
  let first = Relay.InMemoryRelay.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length first <> 1 then fail_fmt "first poll should return 1";
  let second = Relay.InMemoryRelay.poll_inbox t ~node_id:"n2" ~session_id:"s2" in
  if List.length second <> 0 then fail_fmt "second poll should return 0"

let test_relay_peek_inbox_does_not_drain () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.send t ~from_alias:"alice" ~to_alias:"bob" ~content:"msg1" ~message_id:None ~pow_difficulty:(-1) in
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

let[@warning "-21"] test_relay_join_room_adds_member () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  match Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" () with
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
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"test-room" () in
  let _ = Relay.InMemoryRelay.leave_room t ~alias:"alice" ~room_id:"test-room" in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  let members = json_get_list (List.hd rooms) "members" in
  if List.length members <> 1 then fail_fmt "should have 1 member left";
  (* B118: /list_rooms rosters are presentation-only alias#room@relay
     recipient addresses, not bare aliases. bob is still the sole member. *)
  if Yojson.Safe.Util.(List.hd members |> to_string) <> "bob#test-room@relay" then fail_fmt "bob should remain"

let test_relay_send_room_delivers_to_all_except_sender () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"carol" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"test-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"test-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"carol" ~room_id:"test-room" () in
  match Relay.InMemoryRelay.send_room t ~from_alias:"alice" ~room_id:"test-room" ~content:"room msg" () with
  | `Ok (ts, delivered, skipped) ->
      if ts <= 0.0 then fail_fmt "ts should be positive";
      if List.length delivered <> 2 then fail_fmt "should deliver to 2";
      if List.mem "alice" delivered then fail_fmt "alice should not be in delivered";
      if List.length skipped <> 0 then fail_fmt "no skipped"
  | _ -> fail_fmt "expected Ok"

let test_relay_gc_preserves_reserved_expired_leases () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:0.01 () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" ~ttl:300.0 () in
  Unix.sleep 1;
  let (status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"alice" () in
  if status <> Relay.relay_err_alias_conflict then
    fail_fmt "expired delivery lease should remain alias-reserved, got %s" status;
  match Relay.InMemoryRelay.gc t with
  | `Ok (released, _pruned) ->
      if released <> [] then fail_fmt "recently seen alias should not be released by gc";
      let alive_peers = Relay.InMemoryRelay.list_peers ~include_dead:false t in
      if List.length alive_peers <> 1 then fail_fmt "only bob should be alive";
      let peers = Relay.InMemoryRelay.list_peers ~include_dead:true t in
      if List.length peers <> 2 then fail_fmt "alice should remain visible with --dead while reserved"
  | _ -> fail_fmt "gc should return Ok"

let test_relay_list_rooms_shows_all_with_counts () =
  let t = make_test_relay () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status, _lease) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"room-1" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"room-2" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"room-1" () in
  let rooms = Relay.InMemoryRelay.list_rooms t in
  if List.length rooms <> 2 then fail_fmt "should have 2 rooms";
  let room1 = List.find (fun r -> json_get_string r "room_id" = "room-1") rooms in
  if json_get_int room1 "member_count" <> 2 then fail_fmt "room-1 should have 2 members";
  let room2 = List.find (fun r -> json_get_string r "room_id" = "room-2") rooms in
  if json_get_int room2 "member_count" <> 1 then fail_fmt "room-2 should have 1 member"

(* ---- Room visibility: public / unlisted / gated / private (4-level) ---- *)

let test_relay_canonical_visibility_normalizes () =
  let chk input expected =
    match Relay.canonical_visibility input with
    | Some v when v = expected -> ()
    | Some v -> fail_fmt "canonical_visibility %S => %S, expected %S" input v expected
    | None -> fail_fmt "canonical_visibility %S => None, expected Some %S" input expected
  in
  chk "public" "public";
  chk "unlisted" "unlisted";
  chk "gated" "gated";
  chk "private" "private";
  chk "  PUBLIC  " "public";
  chk "  Gated " "gated";
  (* legacy invite* tokens are no longer accepted — rejected like any
     unknown token so callers fail loud instead of silently downgrading *)
  let chk_none input =
    match Relay.canonical_visibility input with
    | None -> ()
    | Some v -> fail_fmt "canonical_visibility %S should be None, got %S" input v
  in
  chk_none "invite";
  chk_none "invite_only";
  chk_none "invite-only";
  chk_none "bogus"

(* Mirror of the relay HTTP join-admission gate (handle_join_room): public and
   unlisted are open-join; gated and private require the caller to be on the
   invite list. The backend [join_room] itself never gates — the gate lives in
   the handler — so we exercise the gate's data-layer building blocks here. *)
let relay_admitted ~visibility ~is_invited =
  let open_join = visibility = "public" || visibility = "unlisted" in
  open_join || is_invited

let room_ids rooms =
  List.map (fun r -> json_get_string r "room_id") rooms

let test_relay_list_rooms_omits_nonpublic () =
  let t = make_test_relay () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  (* public (listed), gated (listed), unlisted (hidden), private (hidden) *)
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"pub-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"gated" ~alias:"alice" ~room_id:"gated-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"unlisted" ~alias:"alice" ~room_id:"unl-room" () in
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"private" ~alias:"alice" ~room_id:"priv-room" () in
  let listed = room_ids (Relay.InMemoryRelay.list_rooms t) in
  if List.length listed <> 2 then fail_fmt "only public + gated rooms should be listed, got [%s]" (String.concat "; " listed);
  if not (List.mem "pub-room" listed) then fail_fmt "pub-room should be listed";
  if not (List.mem "gated-room" listed) then fail_fmt "gated-room should be listed";
  if List.mem "unl-room" listed then fail_fmt "unl-room (unlisted) must not be listed";
  if List.mem "priv-room" listed then fail_fmt "priv-room (private) must not be listed";
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"priv-room" <> "private" then
    fail_fmt "private should be stored as canonical private"

(* B230: authenticated list_rooms shows unlisted rooms to members (creator
   and non-creator members alike); non-members and anonymous callers still
   must not see them. Private stays hidden on this surface. *)
let test_relay_list_rooms_unlisted_visible_to_members () =
  let t = make_test_relay () in
  let (_s, _l) =
    Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" ()
  in
  let (_s2, _l2) =
    Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"member" ()
  in
  let (_s3, _l3) =
    Relay.InMemoryRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"stranger" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~visibility:"unlisted" ~alias:"creator"
      ~room_id:"unl-b230" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~alias:"member" ~room_id:"unl-b230" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~visibility:"private" ~alias:"creator"
      ~room_id:"priv-b230" ()
  in
  let anon = room_ids (Relay.InMemoryRelay.list_rooms t) in
  if List.mem "unl-b230" anon then
    fail_fmt "anonymous list must not show unlisted room";
  if List.mem "priv-b230" anon then
    fail_fmt "anonymous list must not show private room";
  let as_creator = room_ids (Relay.InMemoryRelay.list_rooms ~for_alias:"creator" t) in
  if not (List.mem "unl-b230" as_creator) then
    fail_fmt "creator must see unlisted room they created";
  if List.mem "priv-b230" as_creator then
    fail_fmt "private room must stay hidden even for creator on list_rooms";
  let as_member = room_ids (Relay.InMemoryRelay.list_rooms ~for_alias:"member" t) in
  if not (List.mem "unl-b230" as_member) then
    fail_fmt "non-creator member must see unlisted room they joined";
  let as_stranger = room_ids (Relay.InMemoryRelay.list_rooms ~for_alias:"stranger" t) in
  if List.mem "unl-b230" as_stranger then
    fail_fmt "non-member must not see unlisted room";
  (* Integration polish: alias comparisons are casefold elsewhere; for_alias
     membership must match mixed-case signed aliases. *)
  let as_member_cf =
    room_ids (Relay.InMemoryRelay.list_rooms ~for_alias:"MEMBER" t)
  in
  if not (List.mem "unl-b230" as_member_cf) then
    fail_fmt "for_alias membership must be case-insensitive"

(* New cell coverage (InMemory): gated is listed + join invite-gated; unlisted
   is open-join but not listed; private is invite-gated + not listed. *)
let test_relay_join_gating_inmemory () =
  let t = make_test_relay () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" () in
  (* gated room: listed, invite-gated join *)
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"gated" ~alias:"creator" ~room_id:"g" () in
  if not (List.mem "g" (room_ids (Relay.InMemoryRelay.list_rooms t))) then
    fail_fmt "gated room must be listed";
  let g_vis = Relay.InMemoryRelay.room_visibility_of t ~room_id:"g" in
  if relay_admitted ~visibility:g_vis ~is_invited:(Relay.InMemoryRelay.is_invited t ~room_id:"g" ~identity_pk_b64:"pk_stranger") then
    fail_fmt "gated: uninvited caller must be rejected";
  Relay.InMemoryRelay.invite_to_room t ~room_id:"g" ~identity_pk_b64:"pk_friend";
  if not (relay_admitted ~visibility:g_vis ~is_invited:(Relay.InMemoryRelay.is_invited t ~room_id:"g" ~identity_pk_b64:"pk_friend")) then
    fail_fmt "gated: invited caller must be admitted";
  (* unlisted room: open join, not listed *)
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"unlisted" ~alias:"creator" ~room_id:"u" () in
  if List.mem "u" (room_ids (Relay.InMemoryRelay.list_rooms t)) then
    fail_fmt "unlisted room must not be listed";
  let u_vis = Relay.InMemoryRelay.room_visibility_of t ~room_id:"u" in
  if not (relay_admitted ~visibility:u_vis ~is_invited:(Relay.InMemoryRelay.is_invited t ~room_id:"u" ~identity_pk_b64:"pk_stranger")) then
    fail_fmt "unlisted: uninvited caller must be admitted (open join)";
  (* private room: invite-gated, not listed *)
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"private" ~alias:"creator" ~room_id:"p" () in
  if List.mem "p" (room_ids (Relay.InMemoryRelay.list_rooms t)) then
    fail_fmt "private room must not be listed";
  let p_vis = Relay.InMemoryRelay.room_visibility_of t ~room_id:"p" in
  if relay_admitted ~visibility:p_vis ~is_invited:(Relay.InMemoryRelay.is_invited t ~room_id:"p" ~identity_pk_b64:"pk_stranger") then
    fail_fmt "private: uninvited caller must be rejected";
  Relay.InMemoryRelay.invite_to_room t ~room_id:"p" ~identity_pk_b64:"pk_friend";
  if not (relay_admitted ~visibility:p_vis ~is_invited:(Relay.InMemoryRelay.is_invited t ~room_id:"p" ~identity_pk_b64:"pk_friend")) then
    fail_fmt "private: invited caller must be admitted"

let test_relay_knock_storage_inmemory () =
  let t = make_test_relay () in
  let (_s, _l) =
    Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~visibility:"gated"
      ~alias:"creator" ~room_id:"club" ()
  in
  (match Relay.InMemoryRelay.knock_room t ~room_id:"club"
           ~requester_alias:"bob" ~requester_pk:"pk-bob" with
   | `Ok already_pending ->
       if already_pending then fail_fmt "first knock should not be already_pending"
   | `Error (code, msg) -> fail_fmt "first knock rejected: %s %s" code msg);
  let knocks = Relay.InMemoryRelay.room_knocks_of t ~room_id:"club" in
  if List.length knocks <> 1 then fail_fmt "expected one knock, got %d" (List.length knocks);
  let knock = List.hd knocks in
  if knock.Relay.requester_alias <> "bob" then
    fail_fmt "requester_alias should roundtrip";
  if knock.Relay.requester_pk <> "pk-bob" then
    fail_fmt "requester_pk should roundtrip";
  if knock.Relay.requested_at <= 0.0 then
    fail_fmt "requested_at should be populated";
  (match Relay.InMemoryRelay.knock_room t ~room_id:"club"
           ~requester_alias:"bob" ~requester_pk:"pk-bob" with
   | `Ok already_pending ->
       if not already_pending then fail_fmt "duplicate knock should be already_pending"
   | `Error (code, msg) -> fail_fmt "duplicate knock rejected: %s %s" code msg);
  let knocks = Relay.InMemoryRelay.room_knocks_of t ~room_id:"club" in
  if List.length knocks <> 1 then
    fail_fmt "duplicate knock should not add a second row";
  match Relay.InMemoryRelay.remove_room_knock t ~room_id:"club" ~requester_pk:"pk-bob" with
  | None -> fail_fmt "remove_room_knock should return removed knock"
  | Some removed ->
      if removed.Relay.requester_alias <> "bob" then
        fail_fmt "removed knock should preserve requester alias";
      if Relay.InMemoryRelay.room_knocks_of t ~room_id:"club" <> [] then
        fail_fmt "remove_room_knock should clear pending knock"

let test_relay_knock_eligibility_inmemory () =
  let t = make_test_relay () in
  let (_s, _l) =
    Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" ()
  in
  let (_s2, _l2) =
    Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" ()
  in
  let _ =
    Relay.InMemoryRelay.join_room t ~visibility:"gated"
      ~alias:"creator" ~room_id:"club" ()
  in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"public-room" () in
  (match Relay.InMemoryRelay.knock_room t ~room_id:"missing"
           ~requester_alias:"bob" ~requester_pk:"pk-bob" with
   | `Error (code, _) when code = Relay.relay_err_not_found -> ()
   | `Error (code, msg) -> fail_fmt "missing room should be hidden not_found, got %s %s" code msg
   | `Ok _ -> fail_fmt "missing room knock should be rejected");
  (match Relay.InMemoryRelay.knock_room t ~room_id:"public-room"
           ~requester_alias:"alice" ~requester_pk:"pk-alice" with
   | `Error (code, _) when code = Relay.relay_err_join_directly -> ()
   | `Error (code, msg) -> fail_fmt "public knock should say join directly, got %s %s" code msg
   | `Ok _ -> fail_fmt "public room knock should be rejected");
  Relay.InMemoryRelay.invite_to_room t ~room_id:"club" ~identity_pk_b64:"pk-invited";
  (match Relay.InMemoryRelay.knock_room t ~room_id:"club"
           ~requester_alias:"invited" ~requester_pk:"pk-invited" with
   | `Error (code, _) when code = Relay.relay_err_already_invited -> ()
   | `Error (code, msg) -> fail_fmt "invited knock should be rejected, got %s %s" code msg
   | `Ok _ -> fail_fmt "invited requester should not need to knock");
  let _ = Relay.InMemoryRelay.join_room t ~alias:"bob" ~room_id:"club" () in
  match Relay.InMemoryRelay.knock_room t ~room_id:"club"
          ~requester_alias:"bob" ~requester_pk:"pk-bob" with
  | `Error (code, _) when code = Relay.relay_err_already_member -> ()
  | `Error (code, msg) -> fail_fmt "member knock should be rejected, got %s %s" code msg
  | `Ok _ -> fail_fmt "member should not be able to knock"

let test_relay_join_visibility_set_on_create () =
  let t = make_test_relay () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"unlisted" ~alias:"alice" ~room_id:"rm" () in
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm" <> "unlisted" then
    fail_fmt "room created with --visibility unlisted should be unlisted";
  (* default join leaves a fresh room public *)
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"rm2" () in
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm2" <> "public" then
    fail_fmt "default room should be public";
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"gated" ~alias:"alice" ~room_id:"rm3" () in
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm3" <> "gated" then
    fail_fmt "room created with --visibility gated should store gated";
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"private" ~alias:"alice" ~room_id:"rm4" () in
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm4" <> "private" then
    fail_fmt "room created with --visibility private should store private"

let test_relay_join_visibility_not_overridden_after_create () =
  let t = make_test_relay () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"unlisted" ~alias:"alice" ~room_id:"rm" () in
  (* A later joiner passing a different visibility must NOT change the room. *)
  let _ = Relay.InMemoryRelay.join_room t ~visibility:"public" ~alias:"bob" ~room_id:"rm" () in
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm" <> "unlisted" then
    fail_fmt "later joiner must not be able to flip visibility (expected still unlisted)"

let test_relay_set_visibility_unlists_and_relists () =
  let t = make_test_relay () in
  let (_s, _l) = Relay.InMemoryRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let _ = Relay.InMemoryRelay.join_room t ~alias:"alice" ~room_id:"rm" () in
  if not (List.mem "rm" (room_ids (Relay.InMemoryRelay.list_rooms t))) then
    fail_fmt "public room should be listed initially";
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"rm" ~visibility:"unlisted";
  if List.mem "rm" (room_ids (Relay.InMemoryRelay.list_rooms t)) then
    fail_fmt "room should be hidden after set_room_visibility unlisted";
  (* gated re-lists the room (listed + invite-gated) *)
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"rm" ~visibility:"gated";
  if not (List.mem "rm" (room_ids (Relay.InMemoryRelay.list_rooms t))) then
    fail_fmt "room should be listed again after set_room_visibility gated";
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"rm" ~visibility:"private";
  if Relay.InMemoryRelay.room_visibility_of t ~room_id:"rm" <> "private" then
    fail_fmt "set_room_visibility private should store canonical private";
  if List.mem "rm" (room_ids (Relay.InMemoryRelay.list_rooms t)) then
    fail_fmt "room should be hidden after set_room_visibility private";
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"rm" ~visibility:"public";
  if not (List.mem "rm" (room_ids (Relay.InMemoryRelay.list_rooms t))) then
    fail_fmt "room should reappear after set_room_visibility public"

(* Same visibility behavior must hold on the SqliteRelay backend (AC: both
   backends). Uses a temp-dir sqlite db, cleaned up after. *)
let with_sqlite_relay_tempdir f =
  let dir = Filename.temp_dir "c2c_relay_vis_test" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f (Relay.SqliteRelay.create ~persist_dir:dir ()))

let with_sqlite_relay_and_dir f =
  let dir = Filename.temp_dir "c2c_relay_alias_retention_test" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir (Relay.SqliteRelay.create ~persist_dir:dir ()))

let sqlite_set_last_seen dir alias last_seen =
  let db_path = Filename.concat dir "c2c_relay.db" in
  let conn = Sqlite3.db_open db_path in
  let stmt = Sqlite3.prepare conn "UPDATE leases SET last_seen = ?, ttl = 1 WHERE alias = ?" in
  Sqlite3.bind_double stmt 1 last_seen |> ignore;
  Sqlite3.bind_text stmt 2 alias |> ignore;
  Sqlite3.step stmt |> ignore;
  Sqlite3.finalize stmt |> ignore;
  Sqlite3.db_close conn |> ignore

let test_relay_sqlite_alias_retention_warns_and_releases () =
  with_sqlite_relay_and_dir (fun dir t ->
    let identity_pk = "alice-identity-pk" in
    let enc_pubkey = "alice-enc-pk" in
    let sig_b64 = "alice-sig" in
    let (_status, _lease) =
      Relay.SqliteRelay.register t
        ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ~ttl:1.0
        ~identity_pk ~enc_pubkey ~signed_at:123.0 ~sig_b64 ()
    in
    let (_status, _lease) =
      Relay.SqliteRelay.register t ~node_id:"n-bob" ~session_id:"s-bob" ~alias:"bob" ()
    in
    let (_status, _lease) =
      Relay.SqliteRelay.register t ~node_id:"n-carol" ~session_id:"s-carol" ~alias:"carol" ()
    in
    let _ = Relay.SqliteRelay.join_room t ~alias:"alice" ~room_id:"retention-room" () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"bob" ~room_id:"retention-room" () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"carol" ~room_id:"retention-room" () in
    (match Relay.SqliteRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"queued-before-release" ~message_id:None ~pow_difficulty:(-1) with
     | `Ok _ -> ()
     | _ -> fail_fmt "sqlite: setup send to alice should queue before release");
    let warning_last_seen = Unix.gettimeofday () -. Relay.alias_warning_after_s -. 60.0 in
    sqlite_set_last_seen dir "alice" warning_last_seen;
    let peers = Relay.SqliteRelay.list_peers t ~include_dead:true in
    let alice =
      match List.find_opt (fun lease -> Relay.RegistrationLease.alias lease = "alice") peers with
      | Some lease -> Relay.RegistrationLease.to_json lease
      | None -> fail_fmt "sqlite: reserved stale alias should remain listed with --dead"
    in
    if not (json_get_bool alice "alias_release_warning") then
      fail_fmt "sqlite: stale reserved alias should carry warning metadata";
    let last_seen = json_get_float alice "last_seen" in
    if abs_float (last_seen -. warning_last_seen) > 5.0 then
      fail_fmt "sqlite: list_peers should preserve stored last_seen, got %.0f expected %.0f"
        last_seen warning_last_seen;
    let release_at = json_get_float alice "alias_release_at" in
    if release_at <= Unix.gettimeofday () then
      fail_fmt "sqlite: warning alias release date should be in the future";
    if Relay.SqliteRelay.identity_pk_of t ~alias:"alice" <> Some identity_pk then
      fail_fmt "sqlite: warning-phase reserved alias should keep identity lookup";
    if Relay.SqliteRelay.alias_of_identity_pk t ~identity_pk <> Some "alice" then
      fail_fmt "sqlite: warning-phase reserved alias should reverse-map identity";
    if Relay.SqliteRelay.alias_of_session t ~node_id:"n1" ~session_id:"s1" <> Some "alice" then
      fail_fmt "sqlite: warning-phase reserved alias should map session";
    (match Relay.SqliteRelay.send_room t ~from_alias:"bob" ~room_id:"retention-room" ~content:"ping" () with
     | `Ok (_ts, delivered, skipped) ->
         if List.mem "alice" delivered then
           fail_fmt "sqlite: expired delivery lease must not receive room fanout";
         if not (List.mem "alice" skipped) then
           fail_fmt "sqlite: expired delivery lease should be reported skipped"
     | _ -> fail_fmt "sqlite: send_room should return Ok");
    let (status, _lease) =
      Relay.SqliteRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"alice" ()
    in
    if status <> Relay.relay_err_alias_conflict then
      fail_fmt "sqlite: warned alias should remain reserved, got %s" status;
    sqlite_set_last_seen dir "alice" (Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
    if Relay.SqliteRelay.identity_pk_of t ~alias:"alice" <> None then
      fail_fmt "sqlite: released alias should hide identity_pk before gc";
    if Relay.SqliteRelay.alias_of_identity_pk t ~identity_pk <> None then
      fail_fmt "sqlite: released alias should not reverse-map identity_pk before gc";
    if Relay.SqliteRelay.alias_of_session t ~node_id:"n1" ~session_id:"s1" <> None then
      fail_fmt "sqlite: released alias should not map session before gc";
    if Relay.SqliteRelay.enc_pubkey_of t ~alias:"alice" <> None then
      fail_fmt "sqlite: released alias should hide enc_pubkey before gc";
    if Relay.SqliteRelay.signed_at_of t ~alias:"alice" <> None then
      fail_fmt "sqlite: released alias should hide signed_at before gc";
    if Relay.SqliteRelay.sig_b64_of t ~alias:"alice" <> None then
      fail_fmt "sqlite: released alias should hide sig before gc";
    if Relay.SqliteRelay.is_room_member_alias t ~room_id:"retention-room" ~alias:"alice" then
      fail_fmt "sqlite: released alias should not authorize as room member before gc";
    (match Relay.SqliteRelay.join_room t ~alias:"alice" ~room_id:"retention-room" () with
     | `Error (err, _) when err = Relay.relay_err_unknown_alias -> ()
     | `Error (err, _) -> fail_fmt "sqlite: released alias join should be unknown_alias, got %s" err
     | `Ok -> fail_fmt "sqlite: released alias should not rejoin before gc");
    sqlite_set_last_seen dir "carol" (Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
    (match Relay.SqliteRelay.send_room t ~from_alias:"carol" ~room_id:"retention-room" ~content:"after release" () with
     | `Error (err, _) when err = Relay.relay_err_unknown_alias -> ()
     | `Error (err, _) -> fail_fmt "sqlite: released alias send_room should be unknown_alias, got %s" err
     | `Ok _ -> fail_fmt "sqlite: released alias should not send_room before gc");
    let (hb_status, _) = Relay.SqliteRelay.heartbeat t ~node_id:"n1" ~session_id:"s1" ?opaque_host_id:None in
    if hb_status <> Relay.relay_err_unknown_alias then
      fail_fmt "sqlite: heartbeat should not revive released alias, got %s" hb_status;
    if Relay.SqliteRelay.identity_pk_of t ~alias:"alice" <> None then
      fail_fmt "sqlite: heartbeat must not restore released identity";
    (match Relay.SqliteRelay.send t ~from_alias:"bob" ~to_alias:"alice" ~content:"after release" ~message_id:None ~pow_difficulty:(-1) with
     | `Error (err, _) ->
         if err <> Relay.relay_err_unknown_alias then
           fail_fmt "sqlite: direct send to released alias should be unknown_alias, got %s" err
     | _ -> fail_fmt "sqlite: direct send to released alias should fail before gc");
    let (status, lease) =
      Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ()
    in
    if status <> "ok" then fail_fmt "sqlite: released alias should be reclaimable before gc, got %s" status;
    if Relay.RegistrationLease.node_id lease <> "n1" then
      fail_fmt "sqlite: released alias should be reclaimed by requested node before gc";
    let old_inbox = Relay.SqliteRelay.poll_inbox t ~node_id:"n1" ~session_id:"s1" in
    if old_inbox <> [] then
      fail_fmt "sqlite: reclaim-before-gc must not expose old released-alias inbox content";
    let rooms_after_reclaim = Relay.SqliteRelay.list_rooms t in
    let room_after_reclaim =
      match List.find_opt (fun r -> json_get_string r "room_id" = "retention-room") rooms_after_reclaim with
      | Some r -> r
      | None -> fail_fmt "sqlite: retention room should still exist after reclaiming alice"
    in
    let members_after_reclaim = json_get_list room_after_reclaim "members" in
    if List.exists (fun m -> Yojson.Safe.Util.to_string m = "alice") members_after_reclaim then
      fail_fmt "sqlite: reclaim-before-gc must not inherit released alias room membership";
    let _ = Relay.SqliteRelay.join_room t ~alias:"alice" ~room_id:"retention-room" () in
    sqlite_set_last_seen dir "alice" (Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
    (match Relay.SqliteRelay.gc t with
     | `Ok (released, _pruned) ->
         if not (List.mem "alice" released) then
           fail_fmt "sqlite: gc should release 12-month-stale alias"
     | _ -> fail_fmt "sqlite: gc should return Ok");
    let rooms = Relay.SqliteRelay.list_rooms t in
    let room =
      match List.find_opt (fun r -> json_get_string r "room_id" = "retention-room") rooms with
      | Some r -> r
      | None -> fail_fmt "sqlite: retention room should still exist after releasing alice"
    in
    let members = json_get_list room "members" in
    if List.exists (fun m -> Yojson.Safe.Util.to_string m = "alice") members then
      fail_fmt "sqlite: released alias should be removed from room membership";
    let (status, lease) =
      Relay.SqliteRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"alice" ()
    in
    if status <> "ok" then fail_fmt "sqlite: released alias should be reclaimable, got %s" status;
    if Relay.RegistrationLease.node_id lease <> "n2" then
      fail_fmt "sqlite: released alias should move to new node")

let test_relay_sqlite_list_rooms_omits_nonpublic () =
  with_sqlite_relay_tempdir (fun t ->
    let (_s, _l) = Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
    let _ = Relay.SqliteRelay.join_room t ~alias:"alice" ~room_id:"pub-room" () in
    let _ = Relay.SqliteRelay.join_room t ~visibility:"gated" ~alias:"alice" ~room_id:"gated-room" () in
    let _ = Relay.SqliteRelay.join_room t ~visibility:"unlisted" ~alias:"alice" ~room_id:"unl-room" () in
    let _ = Relay.SqliteRelay.join_room t ~visibility:"private" ~alias:"alice" ~room_id:"priv-room" () in
    let listed = room_ids (Relay.SqliteRelay.list_rooms t) in
    if not (List.mem "pub-room" listed) then fail_fmt "sqlite: pub-room should be listed, got [%s]" (String.concat "; " listed);
    if not (List.mem "gated-room" listed) then fail_fmt "sqlite: gated-room should be listed, got [%s]" (String.concat "; " listed);
    if List.mem "unl-room" listed then fail_fmt "sqlite: unl-room (unlisted) must not be listed";
    if List.mem "priv-room" listed then fail_fmt "sqlite: priv-room (private) must not be listed";
    if Relay.SqliteRelay.room_visibility_of t ~room_id:"priv-room" <> "private" then
      fail_fmt "sqlite: private should be stored as canonical private")

(* B230 sqlite twin of test_relay_list_rooms_unlisted_visible_to_members. *)
let test_relay_sqlite_list_rooms_unlisted_visible_to_members () =
  with_sqlite_relay_tempdir (fun t ->
    let (_s, _l) =
      Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" ()
    in
    let (_s2, _l2) =
      Relay.SqliteRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"member" ()
    in
    let (_s3, _l3) =
      Relay.SqliteRelay.register t ~node_id:"n3" ~session_id:"s3" ~alias:"stranger" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~visibility:"unlisted" ~alias:"creator"
        ~room_id:"unl-b230" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~alias:"member" ~room_id:"unl-b230" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~visibility:"private" ~alias:"creator"
        ~room_id:"priv-b230" ()
    in
    let anon = room_ids (Relay.SqliteRelay.list_rooms t) in
    if List.mem "unl-b230" anon then
      fail_fmt "sqlite: anonymous list must not show unlisted room";
    if List.mem "priv-b230" anon then
      fail_fmt "sqlite: anonymous list must not show private room";
    let as_creator = room_ids (Relay.SqliteRelay.list_rooms ~for_alias:"creator" t) in
    if not (List.mem "unl-b230" as_creator) then
      fail_fmt "sqlite: creator must see unlisted room they created";
    if List.mem "priv-b230" as_creator then
      fail_fmt "sqlite: private room must stay hidden even for creator";
    let as_member = room_ids (Relay.SqliteRelay.list_rooms ~for_alias:"member" t) in
    if not (List.mem "unl-b230" as_member) then
      fail_fmt "sqlite: non-creator member must see unlisted room they joined";
    let as_stranger = room_ids (Relay.SqliteRelay.list_rooms ~for_alias:"stranger" t) in
    if List.mem "unl-b230" as_stranger then
      fail_fmt "sqlite: non-member must not see unlisted room")

(* New cell coverage (Sqlite): gated listed + invite-gated; unlisted open-join
   not listed; private invite-gated not listed. *)
let test_relay_join_gating_sqlite () =
  with_sqlite_relay_tempdir (fun t ->
    let (_s, _l) = Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" () in
    let _ = Relay.SqliteRelay.join_room t ~visibility:"gated" ~alias:"creator" ~room_id:"g" () in
    if not (List.mem "g" (room_ids (Relay.SqliteRelay.list_rooms t))) then
      fail_fmt "sqlite gated room must be listed";
    let g_vis = Relay.SqliteRelay.room_visibility_of t ~room_id:"g" in
    if relay_admitted ~visibility:g_vis ~is_invited:(Relay.SqliteRelay.is_invited t ~room_id:"g" ~identity_pk_b64:"pk_stranger") then
      fail_fmt "sqlite gated: uninvited caller must be rejected";
    Relay.SqliteRelay.invite_to_room t ~room_id:"g" ~identity_pk_b64:"pk_friend";
    if not (relay_admitted ~visibility:g_vis ~is_invited:(Relay.SqliteRelay.is_invited t ~room_id:"g" ~identity_pk_b64:"pk_friend")) then
      fail_fmt "sqlite gated: invited caller must be admitted";
    let _ = Relay.SqliteRelay.join_room t ~visibility:"unlisted" ~alias:"creator" ~room_id:"u" () in
    if List.mem "u" (room_ids (Relay.SqliteRelay.list_rooms t)) then
      fail_fmt "sqlite unlisted room must not be listed";
    let u_vis = Relay.SqliteRelay.room_visibility_of t ~room_id:"u" in
    if not (relay_admitted ~visibility:u_vis ~is_invited:(Relay.SqliteRelay.is_invited t ~room_id:"u" ~identity_pk_b64:"pk_stranger")) then
      fail_fmt "sqlite unlisted: uninvited caller must be admitted (open join)";
    let _ = Relay.SqliteRelay.join_room t ~visibility:"private" ~alias:"creator" ~room_id:"p" () in
    if List.mem "p" (room_ids (Relay.SqliteRelay.list_rooms t)) then
      fail_fmt "sqlite private room must not be listed";
    let p_vis = Relay.SqliteRelay.room_visibility_of t ~room_id:"p" in
    if relay_admitted ~visibility:p_vis ~is_invited:(Relay.SqliteRelay.is_invited t ~room_id:"p" ~identity_pk_b64:"pk_stranger") then
      fail_fmt "sqlite private: uninvited caller must be rejected";
    Relay.SqliteRelay.invite_to_room t ~room_id:"p" ~identity_pk_b64:"pk_friend";
    if not (relay_admitted ~visibility:p_vis ~is_invited:(Relay.SqliteRelay.is_invited t ~room_id:"p" ~identity_pk_b64:"pk_friend")) then
      fail_fmt "sqlite private: invited caller must be admitted")

let test_relay_sqlite_join_visibility_and_set () =
  with_sqlite_relay_tempdir (fun t ->
    let (_s, _l) = Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
    let (_s, _l) = Relay.SqliteRelay.register t ~node_id:"n2" ~session_id:"s2" ~alias:"bob" () in
    let _ = Relay.SqliteRelay.join_room t ~visibility:"unlisted" ~alias:"alice" ~room_id:"rm" () in
    if Relay.SqliteRelay.room_visibility_of t ~room_id:"rm" <> "unlisted" then
      fail_fmt "sqlite: room created with --visibility unlisted should be unlisted";
    (* a later joiner must not be able to flip visibility (INSERT OR IGNORE) *)
    let _ = Relay.SqliteRelay.join_room t ~visibility:"public" ~alias:"bob" ~room_id:"rm" () in
    if Relay.SqliteRelay.room_visibility_of t ~room_id:"rm" <> "unlisted" then
      fail_fmt "sqlite: later joiner must not flip visibility";
    if List.mem "rm" (room_ids (Relay.SqliteRelay.list_rooms t)) then
      fail_fmt "sqlite: unlisted room must not be listed";
    (* set_room_visibility relists it *)
    Relay.SqliteRelay.set_room_visibility t ~room_id:"rm" ~visibility:"public";
    if not (List.mem "rm" (room_ids (Relay.SqliteRelay.list_rooms t))) then
      fail_fmt "sqlite: room should be listed after set_room_visibility public";
    (* gated is listed *)
    Relay.SqliteRelay.set_room_visibility t ~room_id:"rm" ~visibility:"gated";
    if not (List.mem "rm" (room_ids (Relay.SqliteRelay.list_rooms t))) then
      fail_fmt "sqlite: gated room should be listed";
    Relay.SqliteRelay.set_room_visibility t ~room_id:"rm" ~visibility:"private";
    if Relay.SqliteRelay.room_visibility_of t ~room_id:"rm" <> "private" then
      fail_fmt "sqlite: set_room_visibility private should store canonical private";
    if List.mem "rm" (room_ids (Relay.SqliteRelay.list_rooms t)) then
      fail_fmt "sqlite: room should be hidden after set_room_visibility private");
  let dir = Filename.temp_dir "c2c_relay_legacy_vis_test" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () ->
      let db_path = Filename.concat dir "c2c_relay.db" in
      let conn = Sqlite3.db_open db_path in
      ignore (Sqlite3.exec conn "CREATE TABLE rooms (room_id TEXT PRIMARY KEY)");
      ignore (Sqlite3.exec conn "INSERT INTO rooms (room_id) VALUES ('legacy-room')");
      ignore (Sqlite3.db_close conn);
      let t = Relay.SqliteRelay.create ~persist_dir:dir () in
      if Relay.SqliteRelay.room_visibility_of t ~room_id:"legacy-room" <> "public" then
        fail_fmt "sqlite: legacy rooms should migrate with public visibility";
      let listed = room_ids (Relay.SqliteRelay.list_rooms t) in
      if not (List.mem "legacy-room" listed) then
        fail_fmt "sqlite: legacy public room should be listed after migration";
      let (_s, _l) = Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
      (match Relay.SqliteRelay.join_room t ~visibility:"private" ~alias:"alice" ~room_id:"new-private" () with
       | `Ok -> ()
       | `Error (err, msg) -> fail_fmt "sqlite: migrated db join failed: %s %s" err msg);
      if Relay.SqliteRelay.room_visibility_of t ~room_id:"new-private" <> "private" then
        fail_fmt "sqlite: migrated db should support create-with-private visibility";
      if List.mem "new-private" (room_ids (Relay.SqliteRelay.list_rooms t)) then
        fail_fmt "sqlite: private room should not be listed after migration")

let test_relay_sqlite_knock_storage_persists () =
  with_sqlite_relay_and_dir (fun dir t ->
    let (_s, _l) =
      Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1" ~alias:"creator" ()
    in
    let _ =
      Relay.SqliteRelay.join_room t ~visibility:"gated"
        ~alias:"creator" ~room_id:"club" ()
    in
    (match Relay.SqliteRelay.knock_room t ~room_id:"club"
             ~requester_alias:"bob" ~requester_pk:"pk-bob" with
     | `Ok already_pending ->
         if already_pending then fail_fmt "sqlite: first knock should not be already_pending"
     | `Error (code, msg) -> fail_fmt "sqlite: first knock rejected: %s %s" code msg);
    (match Relay.SqliteRelay.knock_room t ~room_id:"club"
             ~requester_alias:"bob" ~requester_pk:"pk-bob" with
     | `Ok already_pending ->
         if not already_pending then fail_fmt "sqlite: duplicate should be already_pending"
     | `Error (code, msg) -> fail_fmt "sqlite: duplicate knock rejected: %s %s" code msg);
    let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
    let knocks = Relay.SqliteRelay.room_knocks_of t2 ~room_id:"club" in
    if List.length knocks <> 1 then
      fail_fmt "sqlite: expected persisted knock, got %d" (List.length knocks);
    let knock = List.hd knocks in
    if knock.Relay.requester_alias <> "bob" || knock.Relay.requester_pk <> "pk-bob" then
      fail_fmt "sqlite: knock fields did not persist";
    match Relay.SqliteRelay.remove_room_knock t2 ~room_id:"club" ~requester_pk:"pk-bob" with
    | None -> fail_fmt "sqlite: remove_room_knock should return row"
    | Some _ ->
        if Relay.SqliteRelay.room_knocks_of t2 ~room_id:"club" <> [] then
          fail_fmt "sqlite: removed knock should be gone")

(* ---- #330 V1: cross_host_not_implemented error-path seam tests ---- *)

(* Simulate the handle_send cross-host validation seam at InMemoryRelay level.
   Matches relay.ml:3170-3191: split alias@host, check host_acceptable,
   write dead_letter on rejection. This is the seam the forwarder (V2) will
   replace with a relay-to-relay POST. *)
let send_with_cross_host_check relay ~from_alias ~to_alias ~content =
  let stripped, host_opt = Relay.split_alias_host to_alias in
  let opaque_host_route =
    match host_opt with
    | Some h -> C2c_name.is_opaque_host_id h
    | None -> false
  in
  let self_host = Relay.InMemoryRelay.self_host relay in
  if (not opaque_host_route) && not (Relay.host_acceptable ~self_host host_opt) then begin
    (* Mirror relay.ml:3177-3187: generate dead_letter entry with reason
       cross_host_not_implemented before returning the error. *)
    let msg_id = Uuidm.to_string (Uuidm.v4_gen (Random.State.make_self_init ()) ()) in
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
    let deliver_to_alias = if opaque_host_route then to_alias else stripped in
    match Relay.InMemoryRelay.send relay ~from_alias ~to_alias:deliver_to_alias ~content ~message_id:None ~pow_difficulty:(-1) with
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

let test_cross_host_opaque_host_id_route_is_local () =
  let relay = Relay.InMemoryRelay.create ~self_host:(Some "relay.c2c.im") () in
  let (_status_a, _lease_a) = Relay.InMemoryRelay.register relay
    ~node_id:"n1" ~session_id:"s1" ~alias:"alice" () in
  let (_status_b, _lease_b) = Relay.InMemoryRelay.register relay
    ~node_id:"n2" ~session_id:"s2" ~alias:"bob@3d08761ae3f3" () in
  match send_with_cross_host_check relay
    ~from_alias:"alice" ~to_alias:"bob@3d08761ae3f3" ~content:"hello opaque bob" with
  | `Cross_host_rejected reason ->
      fail_fmt "bob@3d08761ae3f3 should be accepted as a local opaque reply route, got: %s" reason
  | `Ok _ts ->
      let inbox = Relay.InMemoryRelay.poll_inbox relay ~node_id:"n2" ~session_id:"s2" in
      if List.length inbox <> 1 then fail_fmt "expected 1 message, got %d" (List.length inbox);
      let msg = List.hd inbox in
      Alcotest.(check string) "content" "hello opaque bob"
        (json_get_string msg "content");
      Alcotest.(check string) "to_alias keeps opaque reply route"
        "bob@3d08761ae3f3" (json_get_string msg "to_alias")
  | `Duplicate _ts -> fail_fmt "unexpected Duplicate"
  | `Error (err, msg) -> fail_fmt "bob@3d08761ae3f3 send failed: %s %s" err msg

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

let test_effective_lease_ttl () =
  (* below/at the floor -> floored to the 24h default *)
  assert (Relay.effective_lease_ttl ~client_ttl:300.0 = Relay.default_lease_ttl);
  assert (Relay.effective_lease_ttl ~client_ttl:0.0 = Relay.default_lease_ttl);
  assert (Relay.effective_lease_ttl ~client_ttl:Relay.default_lease_ttl = Relay.default_lease_ttl);
  (* above the floor, under the cap -> honored verbatim *)
  assert (Relay.effective_lease_ttl ~client_ttl:(Relay.default_lease_ttl +. 1000.0) = Relay.default_lease_ttl +. 1000.0);
  (* above the cap -> capped *)
  assert (Relay.effective_lease_ttl ~client_ttl:1.0e9 = Relay.max_lease_ttl)

(* B219 (GH #79): the relay reuses ONE persistent SQLite connection under its
   mutex, and every prepared statement is finalized explicitly. The production
   crash was a use-after-free inside sqlite3_finalize under load, on the
   check_request_nonce path. The nonce test below makes the open-once contract
   deterministic on Linux by holding off GC and bounding /proc/self/fd growth;
   it also verifies the generic exec_prepared bind-error cleanup path. *)

let proc_fd_count () =
  if Sys.file_exists "/proc/self/fd" then
    Some (Array.length (Sys.readdir "/proc/self/fd"))
  else None

let assert_exec_prepared_finalizes_on_bind_error () =
  let db = Sqlite3.db_open ":memory:" in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !closed then begin
        Gc.full_major ();
        ignore (Sqlite3.db_close db)
      end)
    (fun () ->
      let raised =
        try
          ignore (Relay_sqlite_support.exec_prepared db "SELECT ?" [`Text "one"; `Text "too many"]);
          false
        with _ -> true
      in
      Alcotest.(check bool) "invalid bind raises" true raised;
      closed := Sqlite3.db_close db;
      Alcotest.(check bool) "bind-error statement is finalized before close" true !closed)

(* Drive many sequential DB ops (send / heartbeat / request-nonce / poll / gc)
   on ONE relay t. Asserts every op succeeds and delivery is exact. *)
let test_relay_sqlite_persistent_connection_stress () =
  with_sqlite_relay_tempdir (fun t ->
    let (s1, _) =
      Relay.SqliteRelay.register t ~node_id:"nStrA" ~session_id:"sStrA" ~alias:"zzstressa" ()
    in
    let (s2, _) =
      Relay.SqliteRelay.register t ~node_id:"nStrB" ~session_id:"sStrB" ~alias:"zzstressb" ()
    in
    Alcotest.(check string) "register a ok" "ok" s1;
    Alcotest.(check string) "register b ok" "ok" s2;
    let n = 2000 in
    for i = 0 to n - 1 do
      (match Relay.SqliteRelay.send t ~from_alias:"zzstressa" ~to_alias:"zzstressb"
               ~content:(Printf.sprintf "msg-%d" i) ~message_id:None ~pow_difficulty:(-1) with
       | `Ok _ -> ()
       | `Error (e, m) -> fail_fmt "send %d failed: %s %s" i e m
       | _ -> fail_fmt "send %d unexpected result" i);
      let (hb, _) =
        Relay.SqliteRelay.heartbeat t ~node_id:"nStrB" ~session_id:"sStrB" ?opaque_host_id:None
      in
      Alcotest.(check string) "heartbeat stays ok" "ok" hb;
      (* the exact crash path: prepare/step/finalize a request-nonce every op *)
      let ts = Unix.gettimeofday () in
      let nonce = Printf.sprintf "nonce-%d" i in
      (match Relay.SqliteRelay.check_request_nonce t ~nonce ~ts with
       | Ok () -> () | Error e -> fail_fmt "nonce %d first use should be Ok, got %s" i e);
      (match Relay.SqliteRelay.check_request_nonce t ~nonce ~ts with
       | Error _ -> () | Ok () -> fail_fmt "nonce %d replay should be rejected" i)
    done;
    let inbox = Relay.SqliteRelay.poll_inbox t ~node_id:"nStrB" ~session_id:"sStrB" in
    Alcotest.(check int) "all messages delivered" n (List.length inbox);
    let inbox2 = Relay.SqliteRelay.poll_inbox t ~node_id:"nStrB" ~session_id:"sStrB" in
    Alcotest.(check int) "inbox drained (poll deletes)" 0 (List.length inbox2);
    (match Relay.SqliteRelay.gc t with `Ok _ -> ()))

(* Hammer check_request_nonce in isolation — the function whose finalize
   SIGSEGV'd in the core dump. Holding off GC makes the old per-operation
   db_open implementation retain one or more file descriptors per call, while
   the persistent connection stays within a small fixed descriptor budget. *)
let test_relay_sqlite_request_nonce_no_leak_under_load () =
  with_sqlite_relay_tempdir (fun t ->
    assert_exec_prepared_finalizes_on_bind_error ();
    (match proc_fd_count () with
     | None -> ()
     | Some before ->
       let gc_control = Gc.get () in
       Fun.protect
         ~finally:(fun () -> Gc.set gc_control)
         (fun () ->
           Gc.set { gc_control with
                    minor_heap_size = max gc_control.minor_heap_size (4 * 1024 * 1024) };
           for i = 0 to 63 do
             let ts = Unix.gettimeofday () in
             let nonce = Printf.sprintf "fd-probe-%d" i in
             match Relay.SqliteRelay.check_request_nonce t ~nonce ~ts with
             | Ok () -> ()
             | Error e -> fail_fmt "fd probe %d should be accepted, got %s" i e
           done;
           let after = Option.get (proc_fd_count ()) in
           if after > before + 8 then
             fail_fmt "shared connection leaked file descriptors: before=%d after=%d" before after));
    let iters = 5000 in
    for i = 0 to iters - 1 do
      let ts = Unix.gettimeofday () in
      let nonce = Printf.sprintf "req-%d" i in
      (match Relay.SqliteRelay.check_request_nonce t ~nonce ~ts with
       | Ok () -> ()
       | Error e -> fail_fmt "request nonce %d should be accepted, got %s" i e)
    done;
    let ts = Unix.gettimeofday () in
    (match Relay.SqliteRelay.check_request_nonce t ~nonce:"req-fresh" ~ts with
     | Ok () -> () | Error e -> fail_fmt "fresh nonce should be ok: %s" e);
    (match Relay.SqliteRelay.check_request_nonce t ~nonce:"req-fresh" ~ts with
     | Error _ -> () | Ok () -> fail_fmt "in-window replay should be rejected"))

(* Register/heartbeat/gc churn plus room writes on one connection — exercises
   the lease + room + inbox statement paths together so a finalize regression
   in any of them surfaces. *)
let test_relay_sqlite_mixed_ops_on_shared_connection () =
  with_sqlite_relay_tempdir (fun t ->
    for i = 0 to 199 do
      let alias = Printf.sprintf "zzmix%d" i in
      let (st, _) =
        Relay.SqliteRelay.register t ~node_id:(Printf.sprintf "n%d" i)
          ~session_id:(Printf.sprintf "s%d" i) ~alias ()
      in
      Alcotest.(check string) "register ok" "ok" st;
      (match Relay.SqliteRelay.join_room t ~alias ~room_id:"zzmixroom" () with
       | `Ok -> () | `Error (e, m) -> fail_fmt "join %d failed: %s %s" i e m);
      let (hb, _) =
        Relay.SqliteRelay.heartbeat t ~node_id:(Printf.sprintf "n%d" i)
          ~session_id:(Printf.sprintf "s%d" i) ?opaque_host_id:None
      in
      Alcotest.(check string) "heartbeat ok" "ok" hb
    done;
    (* room fanout across all members, then a gc pass *)
    (match Relay.SqliteRelay.send_room t ~from_alias:"zzmix0" ~room_id:"zzmixroom"
             ~content:"hello room" () with
     | `Ok _ -> () | `Error (e, m) -> fail_fmt "send_room failed: %s %s" e m);
    let peers = Relay.SqliteRelay.list_peers t ~include_dead:false in
    Alcotest.(check int) "all 200 peers listed" 200 (List.length peers);
    (match Relay.SqliteRelay.gc t with `Ok _ -> ());
    let rooms = Relay.SqliteRelay.list_rooms t in
    Alcotest.(check bool) "room listed" true
      (List.exists (fun r -> json_get_string r "room_id" = "zzmixroom") rooms))

(* ---- Run tests ---- *)

let tests = [
  "relay effective_lease_ttl floors and caps", test_effective_lease_ttl;
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
  "alias retention policy boundaries", test_alias_retention_policy_boundaries;
  "relay released alias hides identity before gc", test_relay_released_alias_hides_identity_before_gc;
  "relay gc preserves reserved expired", test_relay_gc_preserves_reserved_expired_leases;
  "relay list_rooms with counts", test_relay_list_rooms_shows_all_with_counts;
  (* room visibility: public / unlisted / gated / private (4-level) *)
  "relay canonical_visibility normalizes", test_relay_canonical_visibility_normalizes;
  "relay list_rooms omits non-public", test_relay_list_rooms_omits_nonpublic;
  "relay list_rooms unlisted visible to members (B230)", test_relay_list_rooms_unlisted_visible_to_members;
  "relay join gating (inmemory)", test_relay_join_gating_inmemory;
  "relay knock storage (inmemory)", test_relay_knock_storage_inmemory;
  "relay knock eligibility (inmemory)", test_relay_knock_eligibility_inmemory;
  "relay join --visibility set on create", test_relay_join_visibility_set_on_create;
  "relay join visibility not overridden after create", test_relay_join_visibility_not_overridden_after_create;
  "relay set_room_visibility unlists/relists", test_relay_set_visibility_unlists_and_relists;
  "relay sqlite list_rooms omits non-public", test_relay_sqlite_list_rooms_omits_nonpublic;
  "relay sqlite list_rooms unlisted visible to members (B230)", test_relay_sqlite_list_rooms_unlisted_visible_to_members;
  "relay sqlite join gating", test_relay_join_gating_sqlite;
  "relay sqlite join visibility + set", test_relay_sqlite_join_visibility_and_set;
  "relay sqlite knock storage persists", test_relay_sqlite_knock_storage_persists;
  "relay sqlite alias retention warns and releases", test_relay_sqlite_alias_retention_warns_and_releases;
  (* B219 (GH #79): persistent-connection lifecycle + finalize-all *)
  "relay sqlite persistent connection stress", test_relay_sqlite_persistent_connection_stress;
  "relay sqlite request_nonce no leak under load", test_relay_sqlite_request_nonce_no_leak_under_load;
  "relay sqlite mixed ops on shared connection", test_relay_sqlite_mixed_ops_on_shared_connection;
  (* #330 V1 cross_host_not_implemented error-path seam tests *)
  "cross_host bare alias works when self_host is set", test_cross_host_bare_alias_works_when_self_host_is_set;
  "cross_host alias@matching self_host accepted", test_cross_host_alias_matching_self_host_accepted;
  "cross_host alias@opaque host id accepted locally", test_cross_host_opaque_host_id_route_is_local;
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
