(* B336: nonces were burned BEFORE signature/ownership verification.
   check_register_nonce inserted the register nonce before Ed25519
   verification (register, room-op proofs, signed room-send envelopes all
   share the pattern), so a request that FAILED verification permanently
   consumed its nonce — the client's legitimate retry with the same nonce
   then got nonce_replay, which reads as an attack instead of a transient
   failure.

   Pinned here on a real loopback sqlite relay:
   - an attempt that fails signature verification must NOT consume its
     nonce: the retry with the same nonce succeeds;
   - replay protection is unchanged: after a VERIFIED attempt consumed the
     nonce, a third reuse is rejected with nonce_replay;
   - same contract for the /join_room signed proof and the /send_room
     signed envelope. *)

open Alcotest
module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b336" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

(* A well-formed but wrong signature: decodes to 64 bytes, fails verify. *)
let bogus_sig = b64url_nopad (String.make 64 '\000')

let loopback_socket () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  Lwt_unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) >>= fun () ->
  Lwt_unix.listen fd 16;
  match Lwt_unix.getsockname fd with
  | Unix.ADDR_INET (_, port) -> Lwt.return (fd, port)
  | _ -> Lwt.fail_with "loopback_socket: expected INET socket"

let with_sqlite_server f =
  with_temp_dir (fun dir ->
    Lwt_main.run
      (loopback_socket () >>= fun (fd, port) ->
       let relay = Relay.SqliteRelay.create ~persist_dir:dir () in
       let rate_limiter = Relay.Rate_limiter_inst.create ~gc_interval:300.0 () in
       let stop, wake_stop = Lwt.wait () in
       let callback (conn, _) req body =
         RS.make_callback relay None conn req body ?broker_root:None
           ~native_tls:false ~rate_limiter
       in
       let spec = Cohttp_lwt_unix.Server.make ~callback () in
       let server =
         Cohttp_lwt_unix.Server.create ~stop ~mode:(`TCP (`Socket fd)) spec
       in
       Lwt.pause () >>= fun () ->
       let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
       Lwt.finalize
         (fun () -> f ~base_url ~relay ~dir)
         (fun () ->
            Lwt.wakeup_later wake_stop ();
            server)))

let post_json ~path ~body =
  let body_str = Yojson.Safe.to_string body in
  let headers = Cohttp.Header.of_list [ ("Content-Type", "application/json") ] in
  Cohttp_lwt_unix.Client.call `POST (Uri.of_string (path))
    ~headers ~body:(Cohttp_lwt.Body.of_string body_str)
  >>= fun (_resp, b) ->
  Cohttp_lwt.Body.to_string b >>= fun s ->
  match Yojson.Safe.from_string s with
  | json -> Lwt.return json
  | exception Yojson.Json_error m -> Lwt.fail_with ("invalid json: " ^ m)

let json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String s) -> s
     | Some (`Bool b) -> string_of_bool b
     | _ -> "")
  | _ -> ""

(* Sign the register blob with a CALLER-CHOSEN nonce/ts so the retry can
   reuse the exact nonce a failed attempt carried. *)
let register_with_nonce ~id ~alias ~relay_url ~nonce ~ts_str ~sig_b64
    ~node_id ~session_id =
  let pk_b64 = b64url_nopad id.Relay_identity.public_key in
  post_json
    ~path:(relay_url ^ "/register")
    ~body:(`Assoc
            [ ("node_id", `String node_id)
            ; ("session_id", `String session_id)
            ; ("alias", `String alias)
            ; ("client_type", `String "cli")
            ; ("identity_pk", `String pk_b64)
            ; ("signature", `String sig_b64)
            ; ("nonce", `String nonce)
            ; ("timestamp", `String ts_str) ])

let test_register_retry_after_failed_verify_reuses_nonce () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let id =
      Relay_identity.load_or_create_at
        ~path:(Filename.concat dir "id.json") ~alias_hint:"b336-alice"
    in
    let alias = "b336-alice" in
    let pk_b64 = b64url_nopad id.Relay_identity.public_key in
    let ts1 = Relay_signed_ops.now_rfc3339_utc () in
    let nonce = Relay_signed_ops.random_nonce_b64 () in
    let blob =
      Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
        [ alias; String.lowercase_ascii base_url; pk_b64; ts1; nonce ]
    in
    (* Attempt 1: good nonce, WRONG signature — must fail verification. *)
    register_with_nonce ~id ~alias ~relay_url:base_url ~nonce ~ts_str:ts1
      ~sig_b64:bogus_sig ~node_id:"n-b336" ~session_id:"s-b336"
    >>= fun first ->
    check string "bad signature rejected" "signature_invalid"
      (json_field "error_code" first);
    (* Attempt 2: the legitimate retry — SAME nonce, now the correct
       signature. Must succeed, not nonce_replay. *)
    let ts2 = Relay_signed_ops.now_rfc3339_utc () in
    let blob2 =
      Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
        [ alias; String.lowercase_ascii base_url; pk_b64; ts2; nonce ]
    in
    let good_sig2 = b64url_nopad (Relay_identity.sign id blob2) in
    register_with_nonce ~id ~alias ~relay_url:base_url ~nonce ~ts_str:ts2
      ~sig_b64:good_sig2 ~node_id:"n-b336" ~session_id:"s-b336"
    >>= fun retry ->
    if json_field "ok" retry <> "true" then
      print_endline ("retry response: " ^ Yojson.Safe.to_string retry);
    check string "retry with same nonce succeeds after failed verify" "true"
      (json_field "ok" retry);
    (* Attempt 3: replay protection retained — the nonce was consumed by
       the successful verification, so reuse is now a replay. *)
    let ts3 = Relay_signed_ops.now_rfc3339_utc () in
    let blob3 =
      Relay_identity.canonical_msg ~ctx:Relay_signed_ops.register_sign_ctx
        [ alias; String.lowercase_ascii base_url; pk_b64; ts3; nonce ]
    in
    let good_sig3 = b64url_nopad (Relay_identity.sign id blob3) in
    register_with_nonce ~id ~alias ~relay_url:base_url ~nonce ~ts_str:ts3
      ~sig_b64:good_sig3 ~node_id:"n-b336" ~session_id:"s-b336"
    >>= fun third ->
    check string "replay after verified use still rejected" "nonce_replay"
      (json_field "error_code" third);
    Lwt.return_unit)

(* --- room ops share the nonce pattern ------------------------------------ *)

let register_signed ~base_url ~id ~alias ~node_id ~session_id =
  let p = Relay_signed_ops.sign_register id ~alias ~relay_url:base_url in
  post_json ~path:(base_url ^ "/register")
    ~body:(`Assoc
            [ ("node_id", `String node_id)
            ; ("session_id", `String session_id)
            ; ("alias", `String alias)
            ; ("client_type", `String "cli")
            ; ("identity_pk", `String p.Relay_signed_ops.identity_pk_b64)
            ; ("signature", `String p.Relay_signed_ops.sig_b64)
            ; ("nonce", `String p.Relay_signed_ops.nonce)
            ; ("timestamp", `String p.Relay_signed_ops.ts) ])
  >>= fun reg ->
  match json_field "ok" reg with
  | "true" -> Lwt.return_unit
  | _ ->
    Printf.ksprintf Lwt.fail_with "register failed: %s"
      (Yojson.Safe.to_string reg)

let join_room_proof ~base_url ~id ~alias ~room_id ~ts ~nonce ~sig_b64 =
  let pk_b64 = b64url_nopad id.Relay_identity.public_key in
  post_json ~path:(base_url ^ "/join_room")
    ~body:(`Assoc
            [ ("alias", `String alias)
            ; ("room_id", `String room_id)
            ; ("identity_pk", `String pk_b64)
            ; ("ts", `String ts)
            ; ("nonce", `String nonce)
            ; ("sig", `String sig_b64) ])

let test_room_op_retry_after_failed_verify_reuses_nonce () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let id =
      Relay_identity.load_or_create_at
        ~path:(Filename.concat dir "id.json") ~alias_hint:"b336-joiner"
    in
    let alias = "b336-joiner" and room_id = "b336-room" in
    register_signed ~base_url ~id ~alias ~node_id:"n-b336-joiner"
      ~session_id:"s-b336-joiner"
    >>= fun () ->
    let ts = Relay_signed_ops.now_rfc3339_utc () in
    let nonce = Relay_signed_ops.random_nonce_b64 () in
    let pk_b64 = b64url_nopad id.Relay_identity.public_key in
    let mk_sig ts_str =
      let blob =
        Relay_identity.canonical_msg ~ctx:Relay_common.room_join_sign_ctx
          [ room_id; alias; pk_b64; ts_str; nonce ]
      in
      b64url_nopad (Relay_identity.sign id blob)
    in
    (* attempt 1: wrong signature *)
    post_json ~path:(base_url ^ "/join_room")
      ~body:(`Assoc
              [ ("alias", `String alias); ("room_id", `String room_id)
              ; ("identity_pk", `String pk_b64); ("ts", `String ts)
              ; ("nonce", `String nonce); ("sig", `String bogus_sig) ])
    >>= fun first ->
    check string "room op bad signature rejected" "signature_invalid"
      (json_field "error_code" first);
    (* attempt 2: legitimate retry, same nonce *)
    let ts2 = Relay_signed_ops.now_rfc3339_utc () in
    join_room_proof ~base_url ~id ~alias ~room_id ~ts:ts2 ~nonce
      ~sig_b64:(mk_sig ts2)
    >>= fun retry ->
    if json_field "ok" retry <> "true" then
      print_endline ("room op retry response: " ^ Yojson.Safe.to_string retry);
    check string "room op retry with same nonce succeeds" "true"
      (json_field "ok" retry);
    (* attempt 3: the nonce was consumed by the verified retry - reuse is a
       replay again (security half of the contract). *)
    let ts3 = Relay_signed_ops.now_rfc3339_utc () in
    join_room_proof ~base_url ~id ~alias ~room_id ~ts:ts3 ~nonce
      ~sig_b64:(mk_sig ts3)
    >>= fun third ->
    check string "room op replay after verified use rejected" "nonce_replay"
      (json_field "error_code" third);
    Lwt.return_unit)

let env_nonce env =
  match env with
  | `Assoc fields ->
    (match List.assoc_opt "nonce" fields with
     | Some (`String s) -> s
     | _ -> "")
  | _ -> ""

let test_room_send_retry_after_failed_verify_reuses_nonce () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let id =
      Relay_identity.load_or_create_at
        ~path:(Filename.concat dir "id.json") ~alias_hint:"b336-sender"
    in
    let alias = "b336-sender" and room_id = "b336-room2" in
    let content = "hello room" in
    register_signed ~base_url ~id ~alias ~node_id:"n-b336-sender"
      ~session_id:"s-b336-sender"
    >>= fun () ->
    (* Join first (correct proof) so the sender is a member. *)
    let ts0 = Relay_signed_ops.now_rfc3339_utc () in
    let nonce0 = Relay_signed_ops.random_nonce_b64 () in
    let pk_b64 = b64url_nopad id.Relay_identity.public_key in
    let join_blob =
      Relay_identity.canonical_msg ~ctx:Relay_common.room_join_sign_ctx
        [ room_id; alias; pk_b64; ts0; nonce0 ]
    in
    post_json ~path:(base_url ^ "/join_room")
      ~body:(`Assoc
              [ ("alias", `String alias); ("room_id", `String room_id)
              ; ("identity_pk", `String pk_b64); ("ts", `String ts0)
              ; ("nonce", `String nonce0)
              ; ("sig", `String (b64url_nopad (Relay_identity.sign id join_blob))) ])
    >>= fun joined ->
    check string "join ok" "true" (json_field "ok" joined);
    let env = Relay_signed_ops.sign_send_room id ~room_id ~from_alias:alias ~content in
    let post_send env =
      post_json ~path:(base_url ^ "/send_room")
        ~body:(`Assoc
                [ ("from_alias", `String alias); ("room_id", `String room_id)
                ; ("content", `String content); ("envelope", env) ])
    in
    (* attempt 1: tampered envelope signature *)
    let tampered =
      match env with
      | `Assoc fields ->
        `Assoc (List.map (fun (k, v) ->
            if k = "sig" then (k, `String bogus_sig) else (k, v)) fields)
      | other -> other
    in
    post_send tampered >>= fun first ->
    check string "room send bad signature rejected" "signature_invalid"
      (json_field "error_code" first);
    (* attempt 2: fresh correct envelope, SAME nonce as the failed one *)
    let ts2 = Relay_signed_ops.now_rfc3339_utc () in
    let ct_hash =
      let h = Digestif.SHA256.digest_string content in
      b64url_nopad (Digestif.SHA256.to_raw_string h)
    in
    let blob2 =
      Relay_identity.canonical_msg ~ctx:Relay_signed_ops.room_send_sign_ctx
        [ room_id; alias; pk_b64; "none"; ct_hash; ts2; env_nonce env ]
    in
    let env2 =
      match env with
      | `Assoc fields ->
        `Assoc (List.map (fun (k, v) ->
            match k with
            | "ts" -> (k, `String ts2)
            | "sig" -> (k, `String (b64url_nopad (Relay_identity.sign id blob2)))
            | _ -> (k, v)) fields)
      | other -> other
    in
    post_send env2 >>= fun retry ->
    if json_field "ok" retry <> "true" then
      print_endline ("room send retry response: " ^ Yojson.Safe.to_string retry);
    check string "room send retry with same nonce succeeds" "true"
      (json_field "ok" retry);
    (* attempt 3: same nonce after the verified use -> replay. *)
    let ts3 = Relay_signed_ops.now_rfc3339_utc () in
    let blob3 =
      Relay_identity.canonical_msg ~ctx:Relay_signed_ops.room_send_sign_ctx
        [ room_id; alias; pk_b64; "none"; ct_hash; ts3; env_nonce env ]
    in
    let env3 =
      match env with
      | `Assoc fields ->
        `Assoc (List.map (fun (k, v) ->
            match k with
            | "ts" -> (k, `String ts3)
            | "sig" -> (k, `String (b64url_nopad (Relay_identity.sign id blob3)))
            | _ -> (k, v)) fields)
      | other -> other
    in
    post_send env3 >>= fun third ->
    check string "room send replay after verified use rejected" "nonce_replay"
      (json_field "error_code" third);
    Lwt.return_unit)

let () =
  run "B336 nonces are consumed only after verification succeeds"
    [ ("register", [ test_case "failed verify does not burn the nonce" `Quick
          test_register_retry_after_failed_verify_reuses_nonce ])
    ; ("room op", [ test_case "failed verify does not burn the nonce" `Quick
          test_room_op_retry_after_failed_verify_reuses_nonce ])
    ; ("room send", [ test_case "failed verify does not burn the nonce" `Quick
          test_room_send_retry_after_failed_verify_reuses_nonce ])
    ]
