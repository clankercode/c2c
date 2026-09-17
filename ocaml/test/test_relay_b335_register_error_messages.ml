(* B335: every non-ok register result carried the hardcoded human message
   "alias conflict with existing lease" (relay_server_json.json_of_register_result),
   so operators misread invalid_alias / alias_not_allowed /
   alias_identity_mismatch as lease conflicts. The error_code field was
   always correct; the message now threads the backend's actual status.

   HTTP status decision (client-side audit before changing anything): the
   in-repo clients parse the JSON ok/error_code fields — Relay_client
   reconcile_status passes an honest ok:false body through with http_status
   appended; the connector (response_error_code) and the monitor classifier
   switch on error_code, reading http_status only for 429 backoff; `c2c
   init` / doctor switch on ok. No client keys register handling on the
   HTTP status, so the failure statuses also map to honest codes:
   invalid_alias -> 400, alias_not_allowed / alias_identity_mismatch ->
   403, alias_conflict -> 409, unknown statuses stay 200 (legacy). *)

open Alcotest
module RS = Relay.Relay_server (Relay.SqliteRelay)
open Lwt.Infix

let rm_rf dir = ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b335" "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let b64url_nopad s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let dummy_lease () =
  Relay.RegistrationLease.make ~node_id:"n" ~session_id:"s" ~alias:"a" ()

let contains ~needle hay =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then true
  else
    let rec go i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else go (i + 1)
    in
    go 0

(* --- pure: the message comes from the backend status --------------------- *)

let test_message_per_status () =
  let body_of status =
    match Relay_server_json.json_of_register_result (status, dummy_lease ()) with
    | `Assoc fields -> fields
    | _ -> []
  in
  let err_of status =
    match List.assoc_opt "error" (body_of status) with
    | Some (`String m) -> m
    | _ -> ""
  in
  check bool "conflict keeps its conflict message"
    (contains ~needle:"conflict" (err_of Relay.relay_err_alias_conflict)) true;
  check bool "invalid_alias no longer claims a conflict"
    (not (contains ~needle:"conflict" (err_of "invalid_alias"))) true;
  check bool "alias_not_allowed no longer claims a conflict"
    (not (contains ~needle:"conflict" (err_of "alias_not_allowed"))) true;
  check bool "identity mismatch no longer claims a conflict"
    (not (contains ~needle:"conflict"
            (err_of Relay.relay_err_alias_identity_mismatch)))
    true;
  check int "messages are distinct per status" 4
    (List.length
       (List.sort_uniq String.compare
          [ err_of "invalid_alias"; err_of "alias_not_allowed";
            err_of Relay.relay_err_alias_identity_mismatch;
            err_of Relay.relay_err_alias_conflict ]))

(* --- e2e: statuses and messages over a real loopback sqlite relay -------- *)

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

let fresh_identity dir name alias =
  Relay_identity.load_or_create_at
    ~path:(Filename.concat dir (name ^ ".json")) ~alias_hint:alias

let signed_register ~base_url ~alias ~id ~node_id ~session_id =
  let p = Relay_signed_ops.sign_register id ~alias ~relay_url:base_url in
  let client = Relay.Relay_client.make ~timeout:5.0 base_url in
  Relay.Relay_client.register_signed client ~node_id ~session_id ~alias
    ~client_type:"cli" ~identity_pk_b64:p.Relay_signed_ops.identity_pk_b64
    ~sig_b64:p.Relay_signed_ops.sig_b64 ~nonce:p.Relay_signed_ops.nonce
    ~ts:p.Relay_signed_ops.ts ()

let json_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`String s) -> s
     | Some (`Bool b) -> string_of_bool b
     | Some (`Int i) -> string_of_int i
     | _ -> "")
  | _ -> ""

(* Non-conflict failures: honest status, real message, no legacy conflict
   text. *)
let expect_real_failure ~name ~http_status ~error_substring json =
  check bool (name ^ ": ok:false") false (json_field "ok" json = "true");
  check string (name ^ ": honest http status") http_status
    (json_field "http_status" json);
  check bool (name ^ ": message names the real failure")
    (contains ~needle:error_substring (json_field "error" json)) true;
  check bool (name ^ ": message is not the generic conflict text")
    (not (contains ~needle:"alias conflict with existing lease"
            (json_field "error" json)))
    true

let test_invalid_alias_is_400_with_real_message () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let id = fresh_identity dir "inv" "b335-holder" in
    signed_register ~base_url ~alias:"b335 not a valid alias!!" ~id
      ~node_id:"n-b335-inv" ~session_id:"s-b335-inv"
    >>= fun json ->
    expect_real_failure ~name:"invalid_alias" ~http_status:"400"
      ~error_substring:"not a valid" json;
    Lwt.return_unit)

let test_alias_not_allowed_is_403_with_real_message () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    (* Pin the alias to the owner's key; a signed register with a different
       key must surface the allowlist failure. *)
    let owner = fresh_identity dir "owner" "b335-pinned" in
    let attacker = fresh_identity dir "att" "b335-pinned" in
    Relay.SqliteRelay.set_allowed_identity relay ~alias:"b335-pinned"
      ~identity_pk_b64:(b64url_nopad owner.Relay_identity.public_key);
    ignore attacker;
    signed_register ~base_url ~alias:"b335-pinned" ~id:attacker
      ~node_id:"n-b335-att" ~session_id:"s-b335-att"
    >>= fun json ->
    expect_real_failure ~name:"alias_not_allowed" ~http_status:"403"
      ~error_substring:"pinned" json;
    Lwt.return_unit)

let test_identity_mismatch_is_403_with_real_message () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let first = fresh_identity dir "first" "b335-bound" in
    let second = fresh_identity dir "second" "b335-bound" in
    signed_register ~base_url ~alias:"b335-bound" ~id:first
      ~node_id:"n-b335-first" ~session_id:"s-b335-first"
    >>= fun ok_reg ->
    if json_field "ok" ok_reg <> "true" then
      print_endline ("first register response: " ^ Yojson.Safe.to_string ok_reg);
    check bool "first register ok" true (json_field "ok" ok_reg = "true");
    (* Key drift on the same (node_id, session_id): a different key for the
       same pair. (A different node_id now also yields alias_identity_mismatch
       on both backends: B330 made the binding check precede the conflict scan
       everywhere; sqlite used to answer alias_conflict there.) *)
    signed_register ~base_url ~alias:"b335-bound" ~id:second
      ~node_id:"n-b335-first" ~session_id:"s-b335-first"
    >>= fun json ->
    expect_real_failure ~name:"alias_identity_mismatch" ~http_status:"403"
      ~error_substring:"bound to a different identity" json;
    Lwt.return_unit)

let test_alias_conflict_is_409_and_keeps_conflict_message () =
  with_sqlite_server (fun ~base_url ~relay ~dir ->
    ignore relay;
    let a = fresh_identity dir "ca" "b335-conflict" in
    signed_register ~base_url ~alias:"b335-conflict" ~id:a
      ~node_id:"n-b335-a" ~session_id:"s-b335-a"
    >>= fun ok_reg ->
    if json_field "ok" ok_reg <> "true" then
      print_endline ("holder register response: " ^ Yojson.Safe.to_string ok_reg);
    check bool "holder registered" true (json_field "ok" ok_reg = "true");
    (* Legacy unsigned register from a different node: a genuine conflict
       with the live lease (no identity_pk to rebind with). *)
    let client = Relay.Relay_client.make ~timeout:5.0 base_url in
    Relay.Relay_client.register client ~node_id:"n-b335-b"
      ~session_id:"s-b335-b" ~alias:"b335-conflict" ~client_type:"cli" ()
    >>= fun json ->
    check bool "alias_conflict: ok:false" false
      (json_field "ok" json = "true");
    check string "alias_conflict: honest http status" "409"
      (json_field "http_status" json);
    check bool "alias_conflict: conflict message kept"
      (contains ~needle:"alias conflict with existing lease"
         (json_field "error" json))
      true;
    Lwt.return_unit)

let () =
  run "B335 register failure messages thread the backend status"
    [ ("pure mapping", [ test_case "one message per status" `Quick
          test_message_per_status ])
    ; ("invalid_alias", [ test_case "400 + real message" `Quick
          test_invalid_alias_is_400_with_real_message ])
    ; ("alias_not_allowed", [ test_case "403 + real message" `Quick
          test_alias_not_allowed_is_403_with_real_message ])
    ; ("alias_identity_mismatch", [ test_case "403 + real message" `Quick
          test_identity_mismatch_is_403_with_real_message ])
    ; ("alias_conflict", [ test_case "409 keeps conflict message" `Quick
          test_alias_conflict_is_409_and_keeps_conflict_message ])
    ]
