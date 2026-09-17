(* B334: /send and /send_all bound the body from_alias to the verified
   signer BYTE-EXACTLY while heartbeat/register compares in the same family
   are case-insensitive (alias comparisons are case-insensitive everywhere
   else; the alias pool is lowercase but a client may hold a mixed-case
   registration from an older config or hand-entered alias).

   Symmetry pinned here: with the Authorization-header alias matching the
   stored lease case (so the outer verifier's identity_pk_of lookup
   succeeds), a body from_alias differing only in case must be ACCEPTED and
   delivered, exactly as the same casing difference is accepted on
   heartbeat. A genuinely different name must still be rejected. Both
   /send and /send_all, on a real loopback sqlite relay. *)

open Alcotest
module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b334" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

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

(* The stored alias is lowercase; the signer proves the stored-case alias in
   the Authorization header (required: the outer identity_pk_of lookup keys
   by exact case) and then uses a MIXED-CASE from_alias in the body. *)
let stored_alias = "b334-alice"

let register_alice ~base_url ~dir =
  let id =
    Relay_identity.load_or_create_at
      ~path:(Filename.concat dir "id-alice.json")
      ~alias_hint:stored_alias
  in
  let p = Relay_signed_ops.sign_register id ~alias:stored_alias ~relay_url:base_url in
  let client = Relay.Relay_client.make ~timeout:5.0 base_url in
  Relay.Relay_client.register_signed client ~node_id:"n-b334-alice"
    ~session_id:"s-b334-alice" ~alias:stored_alias ~client_type:"cli"
    ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
    ~sig_b64:p.Relay_signed_ops.sig_b64 ~nonce:p.Relay_signed_ops.nonce
    ~ts:p.Relay_signed_ops.ts ()
  >>= fun reg ->
  match reg with
  | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) ->
    Lwt.return (client, id)
  | other ->
    Printf.ksprintf Lwt.fail_with "register alice failed: %s"
      (Yojson.Safe.to_string other)

let json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String s) -> s
     | Some (`Bool b) -> string_of_bool b
     | _ -> "")
  | _ -> ""

let post_signed ~client_body_path ~base_url ~id ~alias ~body_json =
  let body_str = Yojson.Safe.to_string body_json in
  let auth =
    Relay_signed_ops.sign_request id ~alias ~meth:"POST" ~path:client_body_path
      ~body_str ()
  in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "application/json"); ("Authorization", auth) ]
  in
  Cohttp_lwt_unix.Client.call `POST (Uri.of_string (base_url ^ client_body_path))
    ~headers ~body:(Cohttp_lwt.Body.of_string body_str)
  >>= fun (resp, b) ->
  Cohttp_lwt.Body.to_string b >>= fun s ->
  match Yojson.Safe.from_string s with
  | json -> Lwt.return json
  | exception Yojson.Json_error m -> Lwt.fail_with ("invalid json: " ^ m)

let setup_victim relay =
  let st, _ =
    Relay.SqliteRelay.register relay ~node_id:"n-b334-bob"
      ~session_id:"s-b334-bob" ~alias:"b334-bob" ()
  in
  check string "victim registered" "ok" st;
  (match
     Relay.SqliteRelay.set_peer_discovery_visibility relay ~alias:"b334-bob"
       ~visibility:Relay_backend_contract.Public
   with
   | Ok () -> ()
   | Error e -> failf "mark victim public: %s" e)

let test_send_accepts_case_variant_of_verified_signer () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    setup_victim relay;
    register_alice ~base_url ~dir >>= fun (_client, alice_id) ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "B334-ALICE")
        ; ("to_alias", `String "b334-bob")
        ; ("content", `String "case-variant hello") ]
    in
    post_signed ~client_body_path:"/send" ~base_url ~id:alice_id
      ~alias:stored_alias ~body_json
    >>= fun json ->
    if json_field "ok" json <> "true" then
      print_endline ("send response: " ^ Yojson.Safe.to_string json);
    check string "case-variant from_alias accepted on /send" "true"
      (json_field "ok" json);
    let inbox =
      Relay.SqliteRelay.peek_inbox relay ~node_id:"n-b334-bob"
        ~session_id:"s-b334-bob"
    in
    check int "delivered to the victim" 1 (List.length inbox);
    (* Delivered under the verified lease's case so a recipient replying to
       the delivered name hits the exact-case lease lookup (review round). *)
    (match inbox with
     | msg :: _ ->
       check string "delivered from_alias is the canonical lease case"
         stored_alias (json_field "from_alias" msg)
     | [] -> ());
    (* And the reply to the canonical name is deliverable (alice must be
       publicly reachable for bob's send to pass B264). *)
    (match
       Relay.SqliteRelay.set_peer_discovery_visibility relay
         ~alias:stored_alias ~visibility:Relay_backend_contract.Public
     with
     | Ok () -> ()
     | Error e -> failf "mark alice public: %s" e);
    (match
       Relay.SqliteRelay.send relay ~from_alias:"b334-bob"
         ~to_alias:stored_alias ~content:"reply" ~message_id:(Some "b334-reply")
         ~pow_difficulty:(-1)
     with
     | `Ok _ -> ()
     | _ -> fail "reply to the canonical alias should deliver");
    Lwt.return_unit)

let test_send_still_rejects_different_name () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    setup_victim relay;
    register_alice ~base_url ~dir >>= fun (_client, alice_id) ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "b334-not-alice")
        ; ("to_alias", `String "b334-bob")
        ; ("content", `String "spoof") ]
    in
    post_signed ~client_body_path:"/send" ~base_url ~id:alice_id
      ~alias:stored_alias ~body_json
    >>= fun json ->
    check string "different name still rejected" "false"
      (json_field "ok" json);
    check string "rejected as signature_invalid" "signature_invalid"
      (json_field "error_code" json);
    Lwt.return_unit)

let test_send_all_accepts_case_variant_of_verified_signer () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    setup_victim relay;
    register_alice ~base_url ~dir >>= fun (_client, alice_id) ->
    let body_json =
      `Assoc
        [ ("from_alias", `String "B334-alice")
        ; ("content", `String "case-variant broadcast") ]
    in
    post_signed ~client_body_path:"/send_all" ~base_url ~id:alice_id
      ~alias:stored_alias ~body_json
    >>= fun json ->
    if json_field "ok" json <> "true" then
      print_endline ("send_all response: " ^ Yojson.Safe.to_string json);
    check string "case-variant from_alias accepted on /send_all" "true"
      (json_field "ok" json);
    Lwt.return_unit)

let test_signed_request_baseline () =
  (* Baseline control: a signed request whose header alias matches the
     stored case passes auth on this relay. The B334 ticket notes the outer
     verifier (identity_pk_of) keys by exact case, so a case-variant BODY
     from_alias is the only reachable case-mismatch on send routes; this
     pins that the send rejections above are binding failures, not auth
     breakage. *)
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    setup_victim relay;
    register_alice ~base_url ~dir >>= fun (_client, alice_id) ->
    let body_json =
      `Assoc
        [ ("node_id", `String "n-b334-alice")
        ; ("session_id", `String "s-b334-alice") ]
    in
    post_signed ~client_body_path:"/heartbeat" ~base_url ~id:alice_id
      ~alias:stored_alias ~body_json
    >>= fun hb ->
    check string "signed heartbeat accepted" "true" (json_field "ok" hb);
    Lwt.return_unit)

let () =
  run "B334 send-family alias binding is case-insensitive"
    [ ("case-variant /send", [ test_case "accepted like heartbeat" `Quick
          test_send_accepts_case_variant_of_verified_signer ])
    ; ("different name /send", [ test_case "still rejected" `Quick
          test_send_still_rejects_different_name ])
    ; ("case-variant /send_all", [ test_case "accepted like heartbeat" `Quick
          test_send_all_accepts_case_variant_of_verified_signer ])
    ; ("signed-request baseline", [ test_case "auth works for stored-case header" `Quick
          test_signed_request_baseline ])
    ]
