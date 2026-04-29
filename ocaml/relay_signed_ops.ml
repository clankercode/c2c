type signed_proof = {
  identity_pk_b64 : string;
  ts : string;
  nonce : string;
  sig_b64 : string;
}

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* Sign contexts — must match spec §3.4 *)
let request_sign_ctx = "c2c/v1/request"
let register_sign_ctx = "c2c/v1/register"
let room_send_sign_ctx = "c2c/v1/room-send"

(* Build the canonical request blob per spec §5.1. Fields are joined
   with 0x1F, prefixed by the SIGN_CTX literal. *)
let canonical_request_blob ~meth ~path ~query ~body_sha256_b64 ~ts ~nonce =
  Relay_identity.canonical_msg ~ctx:request_sign_ctx
    [ String.uppercase_ascii meth; path; query; body_sha256_b64; ts; nonce ]

let now_rfc3339_utc () = C2c_time.now_iso8601_utc ()

let random_nonce_b64 () =
  Mirage_crypto_rng_unix.use_default ();
  let bytes = Mirage_crypto_rng.generate 16 in
  b64url_nopad bytes

let sign_register identity ~alias ~relay_url =
  let pk_b64 = b64url_nopad identity.Relay_identity.public_key in
  let ts = now_rfc3339_utc () in
  let nonce = random_nonce_b64 () in
  let blob = Relay_identity.canonical_msg ~ctx:register_sign_ctx
    [ alias; String.lowercase_ascii relay_url; pk_b64; ts; nonce ] in
  let sig_ = Relay_identity.sign identity blob in
  { identity_pk_b64 = pk_b64; ts; nonce; sig_b64 = b64url_nopad sig_ }

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
  let blob = Relay_identity.canonical_msg ~ctx:room_send_sign_ctx
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

(** Build the Authorization header value for a peer route request (spec §5.1).
    Returns: "Ed25519 alias=<a>,ts=<t>,nonce=<n>,sig=<s>" for use in the
    Authorization HTTP header. The signature covers the canonical request blob:
    METHOD, path, query, SHA256(body), ts (Unix epoch secs), nonce. *)
let sign_request identity ~alias ~meth ~path ?(query = "") ~body_str () =
  let ts = Printf.sprintf "%.6f" (Unix.gettimeofday ()) in
  let nonce = random_nonce_b64 () in
  let body_hash =
    if body_str = "" then ""
    else b64url_nopad (Digestif.SHA256.to_raw_string (Digestif.SHA256.digest_string body_str))
  in
  let blob = canonical_request_blob
    ~meth:(String.uppercase_ascii meth) ~path ~query ~body_sha256_b64:body_hash
    ~ts ~nonce
  in
  let sig_ = Relay_identity.sign identity blob in
  Printf.sprintf "Ed25519 alias=%s,ts=%s,nonce=%s,sig=%s" alias ts nonce (b64url_nopad sig_)

let verify_history_envelope ~room_id ~from_alias ~content envelope =
  let decode s =
    match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
    | Ok x -> Ok x
    | Error _ -> Error ("b64 decode failed: " ^ s)
  in
  let get_s fields k =
    match List.assoc_opt k fields with
    | Some (`String s) -> Ok s
    | _ -> Error ("missing field: " ^ k)
  in
  match envelope with
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let* ct = get_s fields "ct" in
      let* enc = get_s fields "enc" in
      let* sender_pk_b64 = get_s fields "sender_pk" in
      let* sig_b64 = get_s fields "sig" in
      let* ts = get_s fields "ts" in
      let* nonce = get_s fields "nonce" in
      if enc <> "none" then Error ("unsupported enc: " ^ enc)
      else
        let* ct_bytes = decode ct in
        if ct_bytes <> content then Error "ct does not match content"
        else
          let* sender_pk = decode sender_pk_b64 in
          let* sig_ = decode sig_b64 in
          if String.length sender_pk <> 32 then Error "bad sender_pk length"
          else if String.length sig_ <> 64 then Error "bad sig length"
          else
            let ct_hash =
              let h = Digestif.SHA256.digest_string content in
              b64url_nopad (Digestif.SHA256.to_raw_string h)
            in
            let blob = Relay_identity.canonical_msg
              ~ctx:room_send_sign_ctx
              [ room_id; from_alias; sender_pk_b64; enc; ct_hash; ts; nonce ]
            in
            if Relay_identity.verify ~pk:sender_pk ~msg:blob ~sig_
            then Ok ()
            else Error "signature does not verify"
  | _ -> Error "envelope is not an object"
