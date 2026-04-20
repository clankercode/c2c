type signed_proof = {
  identity_pk_b64 : string;
  ts : string;
  nonce : string;
  sig_b64 : string;
}

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let now_rfc3339_utc () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let random_nonce_b64 () =
  Mirage_crypto_rng_unix.use_default ();
  let bytes = Mirage_crypto_rng.generate 16 in
  b64url_nopad bytes

let sign_room_op identity ~ctx ~room_id ~alias =
  let pk_b64 = b64url_nopad identity.Relay_identity.public_key in
  let ts = now_rfc3339_utc () in
  let nonce = random_nonce_b64 () in
  let blob = Relay_identity.canonical_msg ~ctx
    [ room_id; alias; pk_b64; ts; nonce ] in
  let sig_ = Relay_identity.sign identity blob in
  { identity_pk_b64 = pk_b64; ts; nonce; sig_b64 = b64url_nopad sig_ }

let sign_send_room identity ~room_id ~from_alias ~content =
  let pk_b64 = b64url_nopad identity.Relay_identity.public_key in
  let ct_bytes = content in
  let ct_b64 = b64url_nopad ct_bytes in
  let ct_hash =
    let h = Digestif.SHA256.digest_string ct_bytes in
    b64url_nopad (Digestif.SHA256.to_raw_string h)
  in
  let enc = "none" in
  let ts = now_rfc3339_utc () in
  let nonce = random_nonce_b64 () in
  let blob = Relay_identity.canonical_msg ~ctx:Relay.room_send_sign_ctx
    [ room_id; from_alias; pk_b64; enc; ct_hash; ts; nonce ] in
  let sig_ = Relay_identity.sign identity blob in
  `Assoc [
    ("ct", `String ct_b64);
    ("enc", `String enc);
    ("sender_pk", `String pk_b64);
    ("sig", `String (b64url_nopad sig_));
    ("ts", `String ts);
    ("nonce", `String nonce);
  ]
