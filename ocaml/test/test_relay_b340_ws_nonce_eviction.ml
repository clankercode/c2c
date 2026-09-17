(* B340: WS subscribe handshake nonce + subscriber eviction on rebind.

   (a) Handshake: the server issues single-use, 120s-TTL challenge nonces
   (GET /ws/subscribe-challenge). A client that signs
   (alias || "\n" || ts || "\n" || nonce) and sends X-C2C-Nonce gets replay
   protection beyond the ts window: the nonce is consumed atomically after
   the signature verifies (verify-first, B336). Legacy signatures over
   (alias || ts) stay accepted for the transition (recorded compat); the
   operator can end it with C2C_RELAY_WS_REQUIRE_NONCE=1.

   (b) Eviction: subscribers were never dropped when an alias's lease was
   taken over (register pair-takeover) or released — a socket authenticated
   under the OLD identity kept receiving push_dm (B295). The relay core now
   evicts the alias's WS subscribers on release_alias, unbind, and register
   shadow-removal, in both backends; a NEW-identity subscriber for the same
   alias still receives pushes. *)

open Alcotest
open Lwt.Infix

let test_alias = "b340-ws@3d08761ae3f3"

let is_substring ~substring s =
  try ignore (Str.search_forward (Str.regexp_string substring) s 0); true
  with Not_found -> false

(* --- (a) handshake: challenge nonce is signed, single use, expiring ------ *)

let sign_headers ~nonce ~alias ~id =
  let ts = Printf.sprintf "%.0f" (Unix.gettimeofday ()) in
  let msg =
    match nonce with
    | Some n -> alias ^ "\n" ^ ts ^ "\n" ^ n
    | None -> alias ^ ts
  in
  let sig_ = Relay_identity.sign id msg in
  let sig_b64 =
    Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet sig_
  in
  (ts, sig_b64)

let expect_ok ~what = function
  | Relay_ws_server.Auth_ok a ->
      check string (what ^ ": ok") "ok" "ok";
      check string (what ^ ": alias echoed") test_alias a
  | Relay_ws_server.Auth_error m -> Alcotest.fail (what ^ ": " ^ m)

let expect_error ~what = function
  | Relay_ws_server.Auth_ok _ -> Alcotest.fail (what ^ ": expected Auth_error")
  | Relay_ws_server.Auth_error m -> check bool what true (String.length m > 0)

let test_challenge_nonce_handshake_ok () =
  let id = Relay_identity.generate ~alias_hint:"b340" () in
  let pk = id.Relay_identity.public_key in
  let nonce = Relay_ws_server.challenge_issue () in
  let ts, sig_b64 = sign_headers ~nonce:(Some nonce) ~alias:test_alias ~id in
  expect_ok ~what:"nonce handshake accepted"
    (Relay_ws_server.validate_subscribe_auth
       ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
       ~sig_b64 ~nonce:(Some nonce))

let test_challenge_nonce_replay_rejected () =
  let id = Relay_identity.generate ~alias_hint:"b340r" () in
  let pk = id.Relay_identity.public_key in
  let nonce = Relay_ws_server.challenge_issue () in
  let ts, sig_b64 = sign_headers ~nonce:(Some nonce) ~alias:test_alias ~id in
  expect_ok ~what:"first use accepted"
    (Relay_ws_server.validate_subscribe_auth
       ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
       ~sig_b64 ~nonce:(Some nonce));
  (* Replay the captured handshake within the ts window: the nonce is
     single-use, so the second accept must fail. *)
  match Relay_ws_server.validate_subscribe_auth
          ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
          ~sig_b64 ~nonce:(Some nonce) with
  | Relay_ws_server.Auth_ok _ -> Alcotest.fail "replayed handshake accepted"
  | Relay_ws_server.Auth_error m ->
      check bool "replay rejected with nonce error" true
        (is_substring ~substring:"challenge nonce" m)

(* Re-forging a fresh ts+sig over an UNKNOWN nonce must not pass either. *)
let test_unknown_nonce_rejected () =
  let id = Relay_identity.generate ~alias_hint:"b340u" () in
  let pk = id.Relay_identity.public_key in
  let nonce = "b340-not-a-real-challenge" in
  let ts, sig_b64 = sign_headers ~nonce:(Some nonce) ~alias:test_alias ~id in
  expect_error ~what:"unknown nonce rejected"
    (Relay_ws_server.validate_subscribe_auth
       ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
       ~sig_b64 ~nonce:(Some nonce))

let test_expired_nonce_rejected () =
  let id = Relay_identity.generate ~alias_hint:"b340e" () in
  let pk = id.Relay_identity.public_key in
  (* Issued 10 minutes ago: past ws_challenge_ttl (120s). *)
  let nonce =
    Relay_ws_server.challenge_issue ~now:(Unix.gettimeofday () -. 600.0) ()
  in
  let ts, sig_b64 = sign_headers ~nonce:(Some nonce) ~alias:test_alias ~id in
  expect_error ~what:"expired nonce rejected"
    (Relay_ws_server.validate_subscribe_auth
       ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
       ~sig_b64 ~nonce:(Some nonce))

(* Recorded compat: legacy signatures (alias || ts, no nonce) stay accepted
   during the transition. *)
let test_legacy_handshake_still_accepted () =
  let id = Relay_identity.generate ~alias_hint:"b340l" () in
  let pk = id.Relay_identity.public_key in
  let ts, sig_b64 = sign_headers ~nonce:None ~alias:test_alias ~id in
  expect_ok ~what:"legacy handshake accepted (transition)"
    (Relay_ws_server.validate_subscribe_auth
       ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
       ~sig_b64 ~nonce:None)

(* The operator switch that ends the transition. *)
let test_require_nonce_env_rejects_legacy () =
  Fun.protect
    (fun () ->
       Unix.putenv "C2C_RELAY_WS_REQUIRE_NONCE" "1";
       let id = Relay_identity.generate ~alias_hint:"b340req" () in
       let pk = id.Relay_identity.public_key in
       let ts, sig_b64 = sign_headers ~nonce:None ~alias:test_alias ~id in
       expect_error ~what:"legacy rejected when nonce required"
         (Relay_ws_server.validate_subscribe_auth
            ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts
            ~sig_b64 ~nonce:None);
       let nonce = Relay_ws_server.challenge_issue () in
       let ts2, sig_b642 = sign_headers ~nonce:(Some nonce) ~alias:test_alias ~id in
       expect_ok ~what:"nonce handshake accepted when required"
         (Relay_ws_server.validate_subscribe_auth
            ~lookup_pk:(fun ~alias:_ -> Some pk) ~alias:test_alias ~ts_str:ts2
            ~sig_b64:sig_b642 ~nonce:(Some nonce)))
    ~finally:(fun () -> Unix.putenv "C2C_RELAY_WS_REQUIRE_NONCE" "0")

(* The challenge store stays bounded: cleanup drops aged entries. *)
let test_challenge_store_cleanup () =
  let past = Unix.gettimeofday () -. 600.0 in
  let _n1 = Relay_ws_server.challenge_issue ~now:past () in
  let before = Relay_ws_server.challenge_pending () in
  let removed = Relay_ws_server.challenge_cleanup ?now:None ~older_than:120.0 () in
  check bool "cleanup dropped the aged challenge" true (removed >= 1);
  check bool "pending shrank" true
    (Relay_ws_server.challenge_pending () < before)

(* --- (b) eviction --------------------------------------------------------- *)

(* A live subscriber session over an in-memory pipe. Server->client frames
   can be read from [sink_ic]; closing [raw_oc] ends the session.
   Returns unit Lwt.t so tests compose inside one Lwt_main.run. *)
type sub = { sink_ic : Lwt_io.input_channel; raw_oc : Lwt_io.output_channel }

let with_subscriber ~alias (f : sub -> unit Lwt.t) : unit Lwt.t =
  let raw_ic, raw_oc = Lwt_io.pipe () in
  let sink_ic, sink_oc = Lwt_io.pipe () in
  let cohttp_ic = Cohttp_lwt_unix.Private.Input_channel.create raw_ic in
  let session = Relay_ws_frame.Session.of_cohttp_channels cohttp_ic sink_oc in
  let handler =
    Relay_ws_server.handle_subscriber_session
      ~aliases:[alias] ~session
      ~lookup_pk:(fun ~alias:_ -> None)
      ()
  in
  let started, wake_started = Lwt.wait () in
  Lwt.async (fun () -> started >>= fun () -> handler);
  (Lwt_unix.sleep 0.05 >>= fun () ->
   Lwt.wakeup wake_started ();
   Lwt.return_unit) >>= fun () ->
  Lwt.finalize
    (fun () -> f { sink_ic; raw_oc })
    (fun () ->
       (* End the session so the handler finalizes. *)
       Lwt_io.close raw_oc >>= fun () ->
       Lwt_unix.sleep 0.05)

let opcode_of frame = frame.Relay_ws_frame.opcode

let read_frame_within_timeout ic =
  Lwt.pick [
    (Relay_ws_frame.read_frame ic >>= fun fr -> Lwt.return (Some fr));
    (Lwt_unix.sleep 2.0 >>= fun () -> Lwt.return None);
  ]

let test_eviction_drops_subscriber_and_pushes_stop () =
  Lwt_main.run
    (with_subscriber ~alias:"b340-evict" (fun sub ->
       check int "subscriber registered" 1
         (Relay_ws_server.subscriber_count ~alias:"b340-evict");
       let evicted = Relay_ws_server.evict_subscribers ~alias:"b340-evict" in
       check int "evict reports one connection" 1 evicted;
       check int "subscriber map emptied" 0
         (Relay_ws_server.subscriber_count ~alias:"b340-evict");
       check bool "alias has no subscribers" false
         (Relay_ws_server.has_subscribers ~alias:"b340-evict");
       (* The evicted socket received a close frame (client can reconnect). *)
       read_frame_within_timeout sub.sink_ic >>= function
       | Some frame ->
           check int "evicted socket got close frame"
             Relay_ws_frame.opcode_close (opcode_of frame);
           (* And a push after eviction reaches nobody on the old socket:
              the map is empty, so nothing is scheduled for it. *)
           Relay_ws_server.push_dm ~to_alias:"b340-evict" ~from_alias:"sender"
             ~body:"after evict" ~ts:(Unix.gettimeofday ());
           check int "no resubscriber appeared" 0
             (Relay_ws_server.subscriber_count ~alias:"b340-evict");
           Lwt.return_unit
       | None -> Alcotest.fail "expected a close frame within 2s"))

let test_push_reaches_active_subscriber () =
  Lwt_main.run
    (with_subscriber ~alias:"b340-push" (fun sub ->
       check int "subscriber registered" 1
         (Relay_ws_server.subscriber_count ~alias:"b340-push");
       Relay_ws_server.push_dm ~to_alias:"b340-push" ~from_alias:"sender@x"
         ~body:"hello b340" ~ts:(Unix.gettimeofday ());
       read_frame_within_timeout sub.sink_ic >>= function
       | Some frame ->
           check int "push delivered as text frame"
             Relay_ws_frame.opcode_text (opcode_of frame);
           Lwt.return_unit
       | None -> Alcotest.fail "expected the pushed dm within 2s"))

(* Takeover: the same (node_id, session_id) pair re-registers under a new
   alias — the old alias's lease is shadow-removed and its WS subscriber
   must be evicted, in BOTH backends. *)
let with_temp_relay name (f : string -> unit Lwt.t) =
  let dir = Filename.temp_dir name "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let reg_sql t ~node_id ~session_id ~alias ~ttl =
  let s, _ = Relay.SqliteRelay.register t ~node_id ~session_id ~alias ~ttl () in
  check string (Printf.sprintf "register %s" alias) "ok" s

let reg_mem t ~node_id ~session_id ~alias ~ttl =
  let s, _ = Relay.InMemoryRelay.register t ~node_id ~session_id ~alias ~ttl () in
  check string (Printf.sprintf "register %s" alias) "ok" s

let test_sqlite_takeover_evicts_subscriber () =
  Lwt_main.run
    (with_temp_relay "c2c_relay_b340" (fun dir ->
       let t = Relay.SqliteRelay.create ~persist_dir:dir () in
       Lwt.return (reg_sql t ~node_id:"b340n" ~session_id:"b340s"
                     ~alias:"b340-old" ~ttl:3600.0) >>= fun () ->
       with_subscriber ~alias:"b340-old" (fun _sub ->
         check int "old alias subscribed" 1
           (Relay_ws_server.subscriber_count ~alias:"b340-old");
         (* The B295/B330 takeover: pair (b340n,b340s) renames to b340-new. *)
         reg_sql t ~node_id:"b340n" ~session_id:"b340s"
           ~alias:"b340-new" ~ttl:3600.0;
         check int "sqlite takeover evicted old subscriber" 0
           (Relay_ws_server.subscriber_count ~alias:"b340-old");
         Lwt.return_unit)))

let test_inmemory_takeover_evicts_subscriber () =
  Lwt_main.run
    (with_temp_relay "c2c_relay_b340m" (fun dir ->
       let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
       Lwt.return (reg_mem t ~node_id:"b340mn" ~session_id:"b340ms"
                     ~alias:"b340-m-old" ~ttl:3600.0) >>= fun () ->
       with_subscriber ~alias:"b340-m-old" (fun _sub ->
         reg_mem t ~node_id:"b340mn" ~session_id:"b340ms"
           ~alias:"b340-m-new" ~ttl:3600.0;
         check int "in-memory takeover evicted old subscriber" 0
           (Relay_ws_server.subscriber_count ~alias:"b340-m-old");
         Lwt.return_unit)))

(* Release: the alias-release surfaces drop the alias's subscribers. The
   hermetic trigger is unbind (POST /admin/unbind); the gc release path
   (alias_released, 12 months of absence) funnels through the same
   release_alias hook. *)
let test_sqlite_unbind_release_evicts_subscriber () =
  Lwt_main.run
    (with_temp_relay "c2c_relay_b340g" (fun dir ->
       let t = Relay.SqliteRelay.create ~persist_dir:dir () in
       Lwt.return (reg_sql t ~node_id:"b340gn" ~session_id:"b340gs"
                     ~alias:"b340-dying" ~ttl:3600.0) >>= fun () ->
       with_subscriber ~alias:"b340-dying" (fun _sub ->
         check bool "unbind removed the lease" true
           (Relay.SqliteRelay.unbind_alias t ~alias:"b340-dying");
         check int "sqlite unbind release evicted subscriber" 0
           (Relay_ws_server.subscriber_count ~alias:"b340-dying");
         Lwt.return_unit)))

let test_inmemory_unbind_release_evicts_subscriber () =
  Lwt_main.run
    (with_temp_relay "c2c_relay_b340mg" (fun dir ->
       let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
       Lwt.return (reg_mem t ~node_id:"b340mgn" ~session_id:"b340mgs"
                     ~alias:"b340-m-dying" ~ttl:3600.0) >>= fun () ->
       with_subscriber ~alias:"b340-m-dying" (fun _sub ->
         (* In-memory unbind reports binding-existence (no pk was bound
            here) but always drops the lease. *)
         ignore (Relay.InMemoryRelay.unbind_alias t ~alias:"b340-m-dying");
         check int "in-memory unbind release evicted subscriber" 0
           (Relay_ws_server.subscriber_count ~alias:"b340-m-dying");
         Lwt.return_unit)))

(* The point of the whole exercise: after the old subscriber is evicted, a
   subscriber for the SAME alias under the NEW identity still gets pushes. *)
let test_new_identity_subscriber_still_receives_push () =
  Lwt_main.run
    (with_subscriber ~alias:"b340-rebind" (fun _old_sub ->
       let evicted = Relay_ws_server.evict_subscribers ~alias:"b340-rebind" in
       check int "old socket evicted" 1 evicted;
       (* A fresh subscriber (the alias's new identity re-subscribes). *)
       let raw_ic, raw_oc = Lwt_io.pipe () in
       let sink_ic, sink_oc = Lwt_io.pipe () in
       let cohttp_ic = Cohttp_lwt_unix.Private.Input_channel.create raw_ic in
       let session = Relay_ws_frame.Session.of_cohttp_channels cohttp_ic sink_oc in
       let handler =
         Relay_ws_server.handle_subscriber_session
           ~aliases:["b340-rebind"] ~session
           ~lookup_pk:(fun ~alias:_ -> None)
           ()
       in
       Lwt.async (fun () -> handler);
       Lwt_unix.sleep 0.05 >>= fun () ->
       check int "new subscriber registered" 1
         (Relay_ws_server.subscriber_count ~alias:"b340-rebind");
       Relay_ws_server.push_dm ~to_alias:"b340-rebind" ~from_alias:"sender@x"
         ~body:"for the new identity" ~ts:(Unix.gettimeofday ());
       read_frame_within_timeout sink_ic >>= function
       | Some frame ->
           check int "new subscriber got the push as text"
             Relay_ws_frame.opcode_text (opcode_of frame);
           Lwt_io.close raw_oc >>= fun () -> Lwt.return_unit
       | None -> Alcotest.fail "expected the pushed dm within 2s"))

let () =
  run "B340 WS handshake nonce + subscriber eviction on lease rebind"
    [ ( "handshake_nonce",
        [ Alcotest.test_case "challenge+nonce handshake accepted" `Quick
            test_challenge_nonce_handshake_ok
        ; Alcotest.test_case "replayed handshake rejected (single use)" `Quick
            test_challenge_nonce_replay_rejected
        ; Alcotest.test_case "unknown nonce rejected" `Quick
            test_unknown_nonce_rejected
        ; Alcotest.test_case "expired nonce rejected" `Quick
            test_expired_nonce_rejected
        ; Alcotest.test_case "legacy handshake still accepted (transition)" `Quick
            test_legacy_handshake_still_accepted
        ; Alcotest.test_case "C2C_RELAY_WS_REQUIRE_NONCE ends the transition" `Quick
            test_require_nonce_env_rejects_legacy
        ; Alcotest.test_case "challenge store cleanup consumes aged entries" `Quick
            test_challenge_store_cleanup
        ] )
    ; ( "eviction",
        [ Alcotest.test_case "evict drops subscriber, close frame, pushes stop" `Quick
            test_eviction_drops_subscriber_and_pushes_stop
        ; Alcotest.test_case "push reaches an active subscriber" `Quick
            test_push_reaches_active_subscriber
        ; Alcotest.test_case "sqlite register takeover evicts" `Quick
            test_sqlite_takeover_evicts_subscriber
        ; Alcotest.test_case "in-memory register takeover evicts" `Quick
            test_inmemory_takeover_evicts_subscriber
        ; Alcotest.test_case "sqlite unbind release evicts" `Quick
            test_sqlite_unbind_release_evicts_subscriber
        ; Alcotest.test_case "in-memory unbind release evicts" `Quick
            test_inmemory_unbind_release_evicts_subscriber
        ; Alcotest.test_case "new-identity subscriber still receives push" `Quick
            test_new_identity_subscriber_still_receives_push
        ] )
    ]
