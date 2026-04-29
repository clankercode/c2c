(* Layer 3 slice 4 — registry schema + first-bind-wins for identity_pk *)

open Relay

let mk_pk b =
  String.make 32 b

let test_register_without_pk_legacy () =
  let r = InMemoryRelay.create () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1" ~alias:"alice" ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "no binding recorded"
    None (InMemoryRelay.identity_pk_of r ~alias:"alice")

let test_first_bind_stores_pk () =
  let r = InMemoryRelay.create () in
  let pk = mk_pk '\x01' in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"alice" ~identity_pk:pk ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "pk recorded"
    (Some pk) (InMemoryRelay.identity_pk_of r ~alias:"alice")

let test_rebind_same_pk_accepted () =
  let r = InMemoryRelay.create () in
  let pk = mk_pk '\x02' in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"bob" ~identity_pk:pk () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"bob" ~identity_pk:pk ()
  in
  Alcotest.(check string) "second register with same pk ok" "ok" status

let test_rebind_different_pk_rejected () =
  let r = InMemoryRelay.create () in
  let pk1 = mk_pk '\x03' in
  let pk2 = mk_pk '\x04' in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"carol" ~identity_pk:pk1 () in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"carol" ~identity_pk:pk2 ()
  in
  Alcotest.(check string) "mismatch rejected"
    relay_err_alias_identity_mismatch status;
  Alcotest.(check (option string)) "binding unchanged"
    (Some pk1) (InMemoryRelay.identity_pk_of r ~alias:"carol")

let test_legacy_then_bind () =
  (* Register without a pk first, then supply one — should bind. *)
  let r = InMemoryRelay.create () in
  let _ = InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
    ~alias:"dave" () in
  Alcotest.(check (option string)) "no binding yet"
    None (InMemoryRelay.identity_pk_of r ~alias:"dave");
  let pk = mk_pk '\x05' in
  let (status, _) =
    InMemoryRelay.register r ~node_id:"n1" ~session_id:"s1"
      ~alias:"dave" ~identity_pk:pk ()
  in
  Alcotest.(check string) "ok status" "ok" status;
  Alcotest.(check (option string)) "binding created on first pk"
    (Some pk) (InMemoryRelay.identity_pk_of r ~alias:"dave")

(* --- L3 slice 2: nonce cache + signed register proof --- *)

let test_nonce_accepts_fresh () =
  let r = InMemoryRelay.create () in
  let now = Unix.gettimeofday () in
  match InMemoryRelay.check_register_nonce r ~nonce:"abc" ~ts:now with
  | Ok () -> ()
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let test_nonce_rejects_replay () =
  let r = InMemoryRelay.create () in
  let now = Unix.gettimeofday () in
  let _ = InMemoryRelay.check_register_nonce r ~nonce:"xyz" ~ts:now in
  match InMemoryRelay.check_register_nonce r ~nonce:"xyz" ~ts:now with
  | Ok () -> Alcotest.fail "expected replay rejection"
  | Error e ->
    Alcotest.(check string) "nonce_replay code"
      relay_err_nonce_replay e

let test_signed_register_blob_roundtrips () =
  (* Simulates a client signing the canonical register blob with Ed25519,
     then the relay reconstructing it and verifying. *)
  let id = Relay_identity.generate ~alias_hint:"coder1" () in
  let relay_url = "https://relay.c2c.im" in
  let identity_pk_b64 = Base64.encode_string ~pad:false
    ~alphabet:Base64.uri_safe_alphabet id.public_key in
  let ts = "2026-04-21T00:05:30Z" in
  let nonce = "YWJjZGVmZ2hpams" in
  let signed = Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
    [ "coder1"; String.lowercase_ascii relay_url;
      identity_pk_b64; ts; nonce ] in
  let sig_ = Relay_identity.sign id signed in
  Alcotest.(check bool) "signature verifies" true
    (Relay_identity.verify ~pk:id.public_key ~msg:signed ~sig_);
  (* mutation: tamper with alias, verification should fail *)
  let tampered = Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
    [ "mallory"; String.lowercase_ascii relay_url;
      identity_pk_b64; ts; nonce ] in
  Alcotest.(check bool) "tampered blob rejected" false
    (Relay_identity.verify ~pk:id.public_key ~msg:tampered ~sig_)

(* --- L3 slice 3: per-request Ed25519 auth helpers --- *)

let test_parse_ed25519_auth_happy () =
  let s = "alias=foo,ts=1776698000,nonce=AAA,sig=BBB" in
  match parse_ed25519_auth_params s with
  | Ok (a, t, n, sg) ->
    Alcotest.(check string) "alias" "foo" a;
    Alcotest.(check string) "ts" "1776698000" t;
    Alcotest.(check string) "nonce" "AAA" n;
    Alcotest.(check string) "sig" "BBB" sg
  | Error e -> Alcotest.failf "expected Ok, got %s" e

let test_parse_ed25519_auth_missing_field () =
  let s = "alias=foo,ts=1,nonce=AAA" in
  match parse_ed25519_auth_params s with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error on missing sig"

let test_sorted_query_string () =
  let u1 = Uri.of_string "https://relay/path?zulu=1&alpha=2" in
  Alcotest.(check string) "sorted alphabetically"
    "alpha=2&zulu=1" (sorted_query_string u1);
  let u2 = Uri.of_string "https://relay/path" in
  Alcotest.(check string) "empty query" "" (sorted_query_string u2)

let test_body_sha256_b64 () =
  Alcotest.(check string) "empty body" "" (body_sha256_b64 "");
  (* SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
     base64url-nopad: ungFv48Bz-pBFEDeXa4iI7ADYaOWF3qctBD_YfIAFa0 *)
  Alcotest.(check string) "abc hash"
    "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
    (body_sha256_b64 "abc")

let test_request_blob_roundtrip () =
  let id = Relay_identity.generate () in
  let ts = "1776698000" in
  let nonce = "cmFuZG9tbm9uY2U" in
  let blob =
    Relay_signed_ops.canonical_request_blob ~meth:"POST" ~path:"/send"
      ~query:"" ~body_sha256_b64:"hashhash" ~ts ~nonce
  in
  let sig_ = Relay_identity.sign id blob in
  Alcotest.(check bool) "request sig verifies" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob ~sig_);
  let tampered =
    Relay_signed_ops.canonical_request_blob ~meth:"GET" ~path:"/send"
      ~query:"" ~body_sha256_b64:"hashhash" ~ts ~nonce
  in
  Alcotest.(check bool) "mutation on method rejected" false
    (Relay_identity.verify ~pk:id.public_key ~msg:tampered ~sig_)

let test_request_nonce_cache () =
  let r = InMemoryRelay.create () in
  let now = Unix.gettimeofday () in
  (match InMemoryRelay.check_request_nonce r ~nonce:"n1" ~ts:now with
   | Ok () -> () | Error e -> Alcotest.failf "fresh rejected: %s" e);
  match InMemoryRelay.check_request_nonce r ~nonce:"n1" ~ts:now with
  | Error e ->
    Alcotest.(check string) "nonce_replay code" relay_err_nonce_replay e
  | Ok () -> Alcotest.fail "replay accepted"

(* --- L4 slice 1: signed room join / leave --- *)

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let test_room_join_signed_ok () =
  let id = Relay_identity.generate () in
  let pk_b64 = b64url_nopad id.public_key in
  let ts = "2026-04-21T02:00:00Z" in
  let nonce = "room-nonce-1" in
  let blob = Relay_identity.canonical_msg ~ctx:room_join_sign_ctx
    [ "lounge"; "alice"; pk_b64; ts; nonce ] in
  let sig_ = Relay_identity.sign id blob in
  Alcotest.(check bool) "signed join sig verifies" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob ~sig_);
  let tampered = Relay_identity.canonical_msg ~ctx:room_leave_sign_ctx
    [ "lounge"; "alice"; pk_b64; ts; nonce ] in
  Alcotest.(check bool) "wrong ctx rejected" false
    (Relay_identity.verify ~pk:id.public_key ~msg:tampered ~sig_)

let test_room_leave_ctx_distinct () =
  let id = Relay_identity.generate () in
  let pk_b64 = b64url_nopad id.public_key in
  let ts = "2026-04-21T02:00:00Z" in
  let nonce = "n2" in
  let join_blob = Relay_identity.canonical_msg ~ctx:room_join_sign_ctx
    [ "r"; "a"; pk_b64; ts; nonce ] in
  let leave_blob = Relay_identity.canonical_msg ~ctx:room_leave_sign_ctx
    [ "r"; "a"; pk_b64; ts; nonce ] in
  Alcotest.(check bool) "join and leave blobs differ" true
    (join_blob <> leave_blob)

let test_room_op_constants () =
  Alcotest.(check string) "join ctx" "c2c/v1/room-join" room_join_sign_ctx;
  Alcotest.(check string) "leave ctx" "c2c/v1/room-leave" room_leave_sign_ctx

(* --- L4 slice 2: signed send_room envelope --- *)

let test_room_send_blob_roundtrips () =
  let id = Relay_identity.generate () in
  let pk_b64 = b64url_nopad id.public_key in
  let ct = "hello room" in
  let ct_hash = body_sha256_b64 ct in
  let ts = "2026-04-21T03:00:00Z" in
  let nonce = "sn-1" in
  let blob = Relay_identity.canonical_msg ~ctx:Relay_signed_ops.room_send_sign_ctx
    [ "lounge"; "alice"; pk_b64; "none"; ct_hash; ts; nonce ] in
  let sig_ = Relay_identity.sign id blob in
  Alcotest.(check bool) "send envelope sig verifies" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob ~sig_);
  (* Tampered ct hash: signature must fail. *)
  let tampered = Relay_identity.canonical_msg ~ctx:Relay_signed_ops.room_send_sign_ctx
    [ "lounge"; "alice"; pk_b64; "none"; body_sha256_b64 "different"; ts; nonce ] in
  Alcotest.(check bool) "ct tampering rejected" false
    (Relay_identity.verify ~pk:id.public_key ~msg:tampered ~sig_)

let test_room_send_ctx_distinct () =
  Alcotest.(check string) "send ctx" "c2c/v1/room-send" Relay_signed_ops.room_send_sign_ctx;
  Alcotest.(check bool) "distinct from join/leave" true
    (Relay_signed_ops.room_send_sign_ctx <> room_join_sign_ctx
     && Relay_signed_ops.room_send_sign_ctx <> room_leave_sign_ctx)

let test_unsupported_enc_code () =
  Alcotest.(check string) "unsupported_enc code"
    "unsupported_enc" relay_err_unsupported_enc

(* --- L4 slice 3: envelope in history + fan-out --- *)

let test_send_room_persists_envelope_in_history () =
  let r = InMemoryRelay.create () in
  (* Need two members for send_room to actually fan out; we only check
     the history path here. Register both with aliases. *)
  let _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s1" ~alias:"alice" () in
  let _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s2" ~alias:"bob" () in
  let _ = InMemoryRelay.join_room r ~alias:"alice" ~room_id:"rm" in
  let _ = InMemoryRelay.join_room r ~alias:"bob" ~room_id:"rm" in
  let env = `Assoc [
    ("ct", `String "aGVsbG8");
    ("enc", `String "none");
    ("sender_pk", `String "pkb64");
    ("sig", `String "sigb64");
    ("ts", `String "2026-04-21T05:00:00Z");
    ("nonce", `String "nc");
  ] in
  let _ = InMemoryRelay.send_room r ~from_alias:"alice" ~room_id:"rm"
    ~content:"hello" ~envelope:env () in
  let hist = InMemoryRelay.room_history r ~room_id:"rm" ~limit:10 in
  (* hist contains system join messages plus one send message; find the
     send (non-system, from_alias=alice with content=hello). *)
  let send_entry =
    List.find_opt (fun entry -> match entry with
      | `Assoc l ->
        (match List.assoc_opt "content" l with
         | Some (`String "hello") -> true | _ -> false)
      | _ -> false) hist
  in
  match send_entry with
  | None -> Alcotest.fail "send history entry not found"
  | Some (`Assoc l) ->
    Alcotest.(check bool) "envelope in history" true
      (List.assoc_opt "envelope" l <> None)
  | Some _ -> Alcotest.fail "entry not an object"

let test_send_room_without_envelope_legacy_history () =
  let r = InMemoryRelay.create () in
  let _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s1" ~alias:"a1" () in
  let _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s2" ~alias:"a2" () in
  let _ = InMemoryRelay.join_room r ~alias:"a1" ~room_id:"rm" in
  let _ = InMemoryRelay.join_room r ~alias:"a2" ~room_id:"rm" in
  let _ = InMemoryRelay.send_room r ~from_alias:"a1" ~room_id:"rm"
    ~content:"legacy" () in
  let hist = InMemoryRelay.room_history r ~room_id:"rm" ~limit:10 in
  let send_entry =
    List.find (fun entry -> match entry with
      | `Assoc l ->
        (match List.assoc_opt "content" l with
         | Some (`String "legacy") -> true | _ -> false)
      | _ -> false) hist
  in
  match send_entry with
  | `Assoc l ->
    Alcotest.(check bool) "no envelope key on legacy send" false
      (List.assoc_opt "envelope" l <> None)
  | _ -> Alcotest.fail "unexpected shape"

(* --- S4: WebSocket handshake RFC 6455 test vector --- *)
(* RFC 6455 §4.2.2: key "dGhlIHNhbXBsZSBub25jZQ==" must produce
   accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" *)

let test_ws_handshake_rfc6455_vector () =
  let key = "dGhlIHNhbXBsZSBub25jZQ==" in
  let resp = Relay_ws_frame.make_handshake_response key in
  let expected_accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" in
  let resp_has_correct_accept =
    try
      let rec search i =
        if i + String.length expected_accept > String.length resp then false
        else if String.sub resp i (String.length expected_accept) = expected_accept then true
        else search (i + 1)
      in
      search 0
    with _ -> false
  in
  Alcotest.(check bool) "RFC 6455 test vector" true resp_has_correct_accept

(* --- S5a: Observer binding management --- *)

let test_observer_binding_add_get () =
  let r = InMemoryRelay.create () in
  let binding_id = "obs-001" in
  let phone_ed = String.make 32 '\x02' in
  let phone_x = String.make 32 '\x03' in
  InMemoryRelay.add_observer_binding r ~binding_id
    ~phone_ed25519_pubkey:phone_ed ~phone_x25519_pubkey:phone_x
    ~machine_ed25519_pubkey:"" ~provenance_sig:"";
  let result = InMemoryRelay.get_observer_binding r ~binding_id in
  Alcotest.(check bool) "binding found" true (result <> None);
  match result with
  | Some (ed, x, _, _) ->
      Alcotest.(check string) "phone_ed25519 preserved" phone_ed ed;
      Alcotest.(check string) "phone_x25519 preserved" phone_x x
  | None -> Alcotest.fail "expected binding"

let test_observer_binding_remove () =
  let r = InMemoryRelay.create () in
  let binding_id = "obs-002" in
  let phone_ed = String.make 32 '\x04' in
  let phone_x = String.make 32 '\x05' in
  InMemoryRelay.add_observer_binding r ~binding_id
    ~phone_ed25519_pubkey:phone_ed ~phone_x25519_pubkey:phone_x
    ~machine_ed25519_pubkey:"" ~provenance_sig:"";
  InMemoryRelay.remove_observer_binding r ~binding_id;
  let result = InMemoryRelay.get_observer_binding r ~binding_id in
  Alcotest.(check bool) "binding removed" true (result = None)

let test_observer_binding_nonexistent () =
  let r = InMemoryRelay.create () in
  let result = InMemoryRelay.get_observer_binding r ~binding_id:"no-such" in
  Alcotest.(check bool) "nonexistent binding returns None" true (result = None)

(* --- L4 slice 5: invited_members ACL --- *)

let test_default_visibility_public () =
  let r = InMemoryRelay.create () in
  Alcotest.(check string) "default is public"
    "public" (InMemoryRelay.room_visibility_of r ~room_id:"lounge")

let test_invite_list_roundtrip () =
  let r = InMemoryRelay.create () in
  let pk1 = "pk1_b64" and pk2 = "pk2_b64" in
  InMemoryRelay.invite_to_room r ~room_id:"r" ~identity_pk_b64:pk1;
  InMemoryRelay.invite_to_room r ~room_id:"r" ~identity_pk_b64:pk2;
  (* Idempotent — second invite of pk1 is a no-op. *)
  InMemoryRelay.invite_to_room r ~room_id:"r" ~identity_pk_b64:pk1;
  Alcotest.(check bool) "pk1 invited" true
    (InMemoryRelay.is_invited r ~room_id:"r" ~identity_pk_b64:pk1);
  Alcotest.(check bool) "pk2 invited" true
    (InMemoryRelay.is_invited r ~room_id:"r" ~identity_pk_b64:pk2);
  Alcotest.(check bool) "random not invited" false
    (InMemoryRelay.is_invited r ~room_id:"r" ~identity_pk_b64:"other");
  InMemoryRelay.uninvite_from_room r ~room_id:"r" ~identity_pk_b64:pk1;
  Alcotest.(check bool) "pk1 removed" false
    (InMemoryRelay.is_invited r ~room_id:"r" ~identity_pk_b64:pk1);
  Alcotest.(check bool) "pk2 still invited" true
    (InMemoryRelay.is_invited r ~room_id:"r" ~identity_pk_b64:pk2)

let test_set_visibility () =
  let r = InMemoryRelay.create () in
  InMemoryRelay.set_room_visibility r ~room_id:"r" ~visibility:"invite";
  Alcotest.(check string) "invite"
    "invite" (InMemoryRelay.room_visibility_of r ~room_id:"r");
  InMemoryRelay.set_room_visibility r ~room_id:"r" ~visibility:"public";
  Alcotest.(check string) "public"
    "public" (InMemoryRelay.room_visibility_of r ~room_id:"r")

let test_invite_ctx_constants () =
  Alcotest.(check string) "invite ctx" "c2c/v1/room-invite" room_invite_sign_ctx;
  Alcotest.(check string) "uninvite ctx" "c2c/v1/room-uninvite" room_uninvite_sign_ctx;
  Alcotest.(check string) "set-visibility ctx"
    "c2c/v1/room-set-visibility" room_set_visibility_sign_ctx;
  Alcotest.(check string) "not_invited code"
    "not_invited" relay_err_not_invited;
  Alcotest.(check string) "not_a_member code"
    "not_a_member" relay_err_not_a_member

(* --- L3/5: operator allowlist + admin unbind --- *)

let b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let test_allowlist_unlisted_falls_through () =
  (* No allowlist entry → normal first-mover registration. *)
  let r = InMemoryRelay.create () in
  let pk = String.make 32 'A' in
  let code, _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s"
    ~alias:"alice" ~identity_pk:pk () in
  Alcotest.(check string) "unlisted alias ok" "ok" code

let test_allowlist_matching_pk_accepted () =
  let r = InMemoryRelay.create () in
  let pk = String.make 32 'A' in
  InMemoryRelay.set_allowed_identity r ~alias:"alice"
    ~identity_pk_b64:(b64url pk);
  let code, _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s"
    ~alias:"alice" ~identity_pk:pk () in
  Alcotest.(check string) "allowlist match accepted" "ok" code

let test_allowlist_mismatched_pk_rejected () =
  let r = InMemoryRelay.create () in
  let pinned = String.make 32 'A' in
  let wrong = String.make 32 'B' in
  InMemoryRelay.set_allowed_identity r ~alias:"alice"
    ~identity_pk_b64:(b64url pinned);
  let code, _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s"
    ~alias:"alice" ~identity_pk:wrong () in
  Alcotest.(check string) "allowlist mismatch rejected"
    "alias_not_allowed" code

let test_allowlist_listed_no_pk_rejected () =
  (* Listed aliases require a signed registration — legacy unsigned
     register of a pinned alias must fail. *)
  let r = InMemoryRelay.create () in
  InMemoryRelay.set_allowed_identity r ~alias:"alice"
    ~identity_pk_b64:(b64url (String.make 32 'A'));
  let code, _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s"
    ~alias:"alice" () in
  Alcotest.(check string) "allowlist needs pk" "alias_not_allowed" code

let test_allowlist_query_roundtrip () =
  let r = InMemoryRelay.create () in
  Alcotest.(check (option string)) "no entry initially" None
    (InMemoryRelay.allowed_identity_of r ~alias:"alice");
  InMemoryRelay.set_allowed_identity r ~alias:"alice"
    ~identity_pk_b64:"pinnedpkb64";
  Alcotest.(check (option string)) "entry roundtrips"
    (Some "pinnedpkb64")
    (InMemoryRelay.allowed_identity_of r ~alias:"alice");
  (* check_allowlist variants *)
  let s = InMemoryRelay.check_allowlist r ~alias:"bob"
    ~identity_pk_b64:"anything" in
  Alcotest.(check bool) "bob unlisted" true (s = `Unlisted);
  let s = InMemoryRelay.check_allowlist r ~alias:"alice"
    ~identity_pk_b64:"pinnedpkb64" in
  Alcotest.(check bool) "alice allowed" true (s = `Allowed);
  let s = InMemoryRelay.check_allowlist r ~alias:"alice"
    ~identity_pk_b64:"wrongpk" in
  Alcotest.(check bool) "alice mismatch" true (s = `Mismatch)

let test_unbind_removes_binding () =
  let r = InMemoryRelay.create () in
  let pk = String.make 32 'A' in
  let _ = InMemoryRelay.register r ~node_id:"n" ~session_id:"s"
    ~alias:"alice" ~identity_pk:pk () in
  Alcotest.(check bool) "binding present before unbind" true
    (InMemoryRelay.identity_pk_of r ~alias:"alice" <> None);
  let removed = InMemoryRelay.unbind_alias r ~alias:"alice" in
  Alcotest.(check bool) "unbind reports removed" true removed;
  Alcotest.(check (option string)) "binding gone" None
    (InMemoryRelay.identity_pk_of r ~alias:"alice");
  (* After unbind, a different pk can claim the alias. *)
  let pk2 = String.make 32 'B' in
  let code, _ = InMemoryRelay.register r ~node_id:"n2" ~session_id:"s2"
    ~alias:"alice" ~identity_pk:pk2 () in
  Alcotest.(check string) "fresh bind after unbind" "ok" code

let test_unbind_missing_alias_is_noop () =
  let r = InMemoryRelay.create () in
  Alcotest.(check bool) "unbind of unknown alias returns false" false
    (InMemoryRelay.unbind_alias r ~alias:"ghost")

let tests = [
  "register_without_pk_legacy",    `Quick, test_register_without_pk_legacy;
  "first_bind_stores_pk",          `Quick, test_first_bind_stores_pk;
  "rebind_same_pk_accepted",       `Quick, test_rebind_same_pk_accepted;
  "rebind_different_pk_rejected",  `Quick, test_rebind_different_pk_rejected;
  "legacy_then_bind",              `Quick, test_legacy_then_bind;
  "nonce_accepts_fresh",           `Quick, test_nonce_accepts_fresh;
  "nonce_rejects_replay",          `Quick, test_nonce_rejects_replay;
  "signed_register_blob_roundtrips", `Quick, test_signed_register_blob_roundtrips;
  "parse_ed25519_auth_happy",      `Quick, test_parse_ed25519_auth_happy;
  "parse_ed25519_auth_missing_field", `Quick, test_parse_ed25519_auth_missing_field;
  "sorted_query_string",           `Quick, test_sorted_query_string;
  "body_sha256_b64",               `Quick, test_body_sha256_b64;
  "request_blob_roundtrip",        `Quick, test_request_blob_roundtrip;
  "request_nonce_cache",           `Quick, test_request_nonce_cache;
  "room_join_signed_ok",           `Quick, test_room_join_signed_ok;
  "room_leave_ctx_distinct",       `Quick, test_room_leave_ctx_distinct;
  "room_op_constants",             `Quick, test_room_op_constants;
  "room_send_blob_roundtrips",     `Quick, test_room_send_blob_roundtrips;
  "room_send_ctx_distinct",        `Quick, test_room_send_ctx_distinct;
  "unsupported_enc_code",          `Quick, test_unsupported_enc_code;
  "default_visibility_public",     `Quick, test_default_visibility_public;
  "invite_list_roundtrip",         `Quick, test_invite_list_roundtrip;
  "set_visibility",                `Quick, test_set_visibility;
  "invite_ctx_constants",          `Quick, test_invite_ctx_constants;
  "allowlist_unlisted_falls_through", `Quick, test_allowlist_unlisted_falls_through;
  "allowlist_matching_pk_accepted",   `Quick, test_allowlist_matching_pk_accepted;
  "allowlist_mismatched_pk_rejected", `Quick, test_allowlist_mismatched_pk_rejected;
  "allowlist_listed_no_pk_rejected",  `Quick, test_allowlist_listed_no_pk_rejected;
  "allowlist_query_roundtrip",     `Quick, test_allowlist_query_roundtrip;
  "unbind_removes_binding",        `Quick, test_unbind_removes_binding;
  "unbind_missing_alias_is_noop",  `Quick, test_unbind_missing_alias_is_noop;
  "send_room_persists_envelope",   `Quick, test_send_room_persists_envelope_in_history;
  "send_room_legacy_no_envelope",  `Quick, test_send_room_without_envelope_legacy_history;
  "ws_handshake_rfc6455_vector",  `Quick, test_ws_handshake_rfc6455_vector;
  "observer_binding_add_get", `Quick, test_observer_binding_add_get;
  "observer_binding_remove", `Quick, test_observer_binding_remove;
  "observer_binding_nonexistent", `Quick, test_observer_binding_nonexistent;
]

let () =
  Alcotest.run "relay_bindings" [ "layer3_slice4", tests ]
