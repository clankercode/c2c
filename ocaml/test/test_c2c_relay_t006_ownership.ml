open Alcotest
open Lwt.Infix

module RTSR = Relay_test_support_real

let json_field key = function
  | `Assoc fields -> Option.value (List.assoc_opt key fields) ~default:`Null
  | _ -> `Null

let test_owner_can_publish_and_republish () =
  (* Production auth mode still admits the body-signed owner operation without
     a Bearer token; the alias key is the only authority. *)
  RTSR.with_server ~token:"t006-token" (fun ~base_url ~relay ->
    let owner = Relay_identity.generate () in
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    let reg = Relay_signed_ops.sign_register owner ~alias:"t006-publish" ~relay_url:base_url in
    Relay.Relay_client.register_signed client
      ~node_id:"t006-node" ~session_id:"t006-session" ~alias:"t006-publish"
      ~client_type:"t3-service"
      ~identity_pk_b64:reg.identity_pk_b64 ~sig_b64:reg.sig_b64
      ~nonce:reg.nonce ~ts:reg.ts ()
    >>= fun response ->
    check bool "registration succeeds" true (json_field "ok" response = `Bool true);
    let proof = Relay_signed_ops.sign_peer_visibility owner
      ~alias:"t006-publish" ~visibility:"public" in
    Relay.Relay_client.set_peer_discovery_visibility_signed client
      ~alias:"t006-publish" ~visibility:"public"
      ~identity_pk:proof.identity_pk_b64 ~ts:proof.ts ~nonce:proof.nonce
      ~sig_:proof.sig_b64
    >>= fun response ->
    check bool "publication succeeds" true (json_field "ok" response = `Bool true);
    check bool "backend is public" true
      (Relay.InMemoryRelay.peer_discovery_visibility_of relay ~alias:"t006-publish"
       = Some Relay_backend_contract.Public);
    Lwt.return_unit)

let test_foreign_owner_cannot_publish () =
  RTSR.with_server (fun ~base_url ~relay ->
    let owner = Relay_identity.generate () in
    let foreign = Relay_identity.generate () in
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    let reg = Relay_signed_ops.sign_register owner ~alias:"t006-foreign" ~relay_url:base_url in
    Relay.Relay_client.register_signed client
      ~node_id:"t006-node-f" ~session_id:"t006-session-f" ~alias:"t006-foreign"
      ~client_type:"t3-service" ~identity_pk_b64:reg.identity_pk_b64
      ~sig_b64:reg.sig_b64 ~nonce:reg.nonce ~ts:reg.ts ()
    >>= fun response ->
    check bool "registration succeeds" true (json_field "ok" response = `Bool true);
    let proof = Relay_signed_ops.sign_peer_visibility foreign
      ~alias:"t006-foreign" ~visibility:"public" in
    Relay.Relay_client.set_peer_discovery_visibility_signed client
      ~alias:"t006-foreign" ~visibility:"public"
      ~identity_pk:proof.identity_pk_b64 ~ts:proof.ts ~nonce:proof.nonce
      ~sig_:proof.sig_b64
    >>= fun response ->
    check bool "foreign publication rejected" true (json_field "ok" response = `Bool false);
    check string "foreign error" "alias_identity_mismatch"
      (match json_field "error_code" response with `String s -> s | _ -> "");
    check bool "lease remains private" true
      (Relay.InMemoryRelay.peer_discovery_visibility_of relay ~alias:"t006-foreign"
       = Some Relay_backend_contract.Private);
    Lwt.return_unit)

let test_publication_nonce_is_single_use () =
  RTSR.with_server (fun ~base_url ~relay ->
    let owner = Relay_identity.generate () in
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    let reg = Relay_signed_ops.sign_register owner ~alias:"t006-replay" ~relay_url:base_url in
    Relay.Relay_client.register_signed client
      ~node_id:"t006-node-r" ~session_id:"t006-session-r" ~alias:"t006-replay"
      ~client_type:"t3-service" ~identity_pk_b64:reg.identity_pk_b64
      ~sig_b64:reg.sig_b64 ~nonce:reg.nonce ~ts:reg.ts ()
    >>= fun _ ->
    let proof = Relay_signed_ops.sign_peer_visibility owner
      ~alias:"t006-replay" ~visibility:"public" in
    let publish () =
      Relay.Relay_client.set_peer_discovery_visibility_signed client
        ~alias:"t006-replay" ~visibility:"public"
        ~identity_pk:proof.identity_pk_b64 ~ts:proof.ts ~nonce:proof.nonce
        ~sig_:proof.sig_b64
    in
    publish () >>= fun first ->
    check bool "first publication succeeds" true (json_field "ok" first = `Bool true);
    publish () >|= fun second ->
    check bool "replay rejected" true (json_field "ok" second = `Bool false);
    check string "replay error" "nonce_replay"
      (match json_field "error_code" second with `String s -> s | _ -> "");
    check bool "replay does not undo publication" true
      (Relay.InMemoryRelay.peer_discovery_visibility_of relay ~alias:"t006-replay"
       = Some Relay_backend_contract.Public))

let test_invalid_remote_route_is_rejected () =
  RTSR.with_server (fun ~base_url ~relay:_ ->
    let owner = Relay_identity.generate () in
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    let proof = Relay_signed_ops.sign_peer_visibility owner
      ~alias:"t006-route@deadbeefdead" ~visibility:"public" in
    Relay.Relay_client.set_peer_discovery_visibility_signed client
      ~alias:"t006-route@deadbeefdead" ~visibility:"public"
      ~identity_pk:proof.identity_pk_b64 ~ts:proof.ts ~nonce:proof.nonce
      ~sig_:proof.sig_b64
    >|= fun response ->
    check bool "remote route publication rejected" true
      (json_field "ok" response = `Bool false);
    check string "bad alias" "bad_request"
      (match json_field "error_code" response with `String s -> s | _ -> ""))

let () =
  run "T006 relay ownership publication"
    [ ("signed publication",
       [ test_case "owner can publish" `Quick test_owner_can_publish_and_republish;
         test_case "foreign owner refused" `Quick test_foreign_owner_cannot_publish;
         test_case "nonce is single-use" `Quick test_publication_nonce_is_single_use;
         test_case "remote route rejected" `Quick test_invalid_remote_route_is_rejected ]) ]
