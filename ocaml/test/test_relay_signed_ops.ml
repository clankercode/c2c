(* Layer 4 client-side signer tests. Produces proofs/envelopes that the
   server-side verifiers in relay.ml accept. *)

open Relay

let decode_exn s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok x -> x
  | Error _ -> Alcotest.fail ("decode failed: " ^ s)

let test_nonce_fresh_each_call () =
  let n1 = Relay_signed_ops.random_nonce_b64 () in
  let n2 = Relay_signed_ops.random_nonce_b64 () in
  Alcotest.(check bool) "distinct nonces" true (n1 <> n2);
  (* 16 raw bytes → 22 b64url chars (nopad). *)
  Alcotest.(check int) "22 char nonce" 22 (String.length n1)

let test_rfc3339_shape () =
  let s = Relay_signed_ops.now_rfc3339_utc () in
  Alcotest.(check int) "20 char rfc3339" 20 (String.length s);
  Alcotest.(check char) "ends Z" 'Z' s.[19]

let test_sign_join_accepted_by_server_verify () =
  let id = Relay_identity.generate () in
  let proof = Relay_signed_ops.sign_room_op id
    ~ctx:room_join_sign_ctx ~room_id:"lounge" ~alias:"alice" in
  let blob = Relay_identity.canonical_msg ~ctx:room_join_sign_ctx
    [ "lounge"; "alice"; proof.identity_pk_b64; proof.ts; proof.nonce ] in
  let sig_ = decode_exn proof.sig_b64 in
  Alcotest.(check bool) "server-side verify ok" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob ~sig_)

let test_sign_leave_distinct_from_join () =
  let id = Relay_identity.generate () in
  (* Same room_id + alias should still produce a valid leave proof that
     does NOT validate under the join context. *)
  let p_leave = Relay_signed_ops.sign_room_op id
    ~ctx:room_leave_sign_ctx ~room_id:"lounge" ~alias:"alice" in
  let sig_ = decode_exn p_leave.sig_b64 in
  let join_blob = Relay_identity.canonical_msg ~ctx:room_join_sign_ctx
    [ "lounge"; "alice"; p_leave.identity_pk_b64; p_leave.ts; p_leave.nonce ] in
  Alcotest.(check bool) "leave sig rejected under join ctx" false
    (Relay_identity.verify ~pk:id.public_key ~msg:join_blob ~sig_)

let test_sign_send_envelope_accepted () =
  let id = Relay_identity.generate () in
  let env = Relay_signed_ops.sign_send_room id
    ~room_id:"lounge" ~from_alias:"alice" ~content:"hi there" in
  let get_s k = match env with
    | `Assoc l -> (match List.assoc_opt k l with
                   | Some (`String s) -> s | _ -> Alcotest.fail ("missing " ^ k))
    | _ -> Alcotest.fail "not an object"
  in
  let ct = get_s "ct" in
  let enc = get_s "enc" in
  let sender_pk = get_s "sender_pk" in
  let sig_b64 = get_s "sig" in
  let ts = get_s "ts" in
  let nonce = get_s "nonce" in
  Alcotest.(check string) "enc=none" "none" enc;
  Alcotest.(check string) "ct matches content b64"
    "hi there" (decode_exn ct);
  (* Reconstruct the exact server-side sign-blob and verify. *)
  let ct_hash =
    let h = Digestif.SHA256.digest_string "hi there" in
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
      (Digestif.SHA256.to_raw_string h)
  in
  let blob = Relay_identity.canonical_msg ~ctx:room_send_sign_ctx
    [ "lounge"; "alice"; sender_pk; enc; ct_hash; ts; nonce ] in
  let sig_ = decode_exn sig_b64 in
  Alcotest.(check bool) "send envelope verifies" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob ~sig_)

let tests = [
  "nonce_fresh_each_call",        `Quick, test_nonce_fresh_each_call;
  "rfc3339_shape",                `Quick, test_rfc3339_shape;
  "sign_join_accepted",           `Quick, test_sign_join_accepted_by_server_verify;
  "sign_leave_ctx_distinct",      `Quick, test_sign_leave_distinct_from_join;
  "sign_send_envelope_accepted",  `Quick, test_sign_send_envelope_accepted;
]

let () = Alcotest.run "relay_signed_ops" [ "layer4_client_signer", tests ]
