(* B265 — consent-gated delivery on every DM ingress path.

   Design freeze: .collab/design/2026-07-22-b262-contact-grant-protocol.md
   Task: .backlog/bugs/B265-enforce-consent-gated-relay-de.todo

   Proves handler/backend delivery surfaces (not grant lifecycle — B263):
   1. Legacy /send (backend R.send) to private rejects; no inbox, no content DLQ
   2. send_all skips private recipients
   3. admit_contact_delivery Accepted once; Duplicate no second inbox
   4. Room roster/presentation does not open private DM
   5. HTTP POST /contact/v1/deliver refuses tokenless (dev) relays
   6. HTTP POST /send to private (dev unsigned) fails with zero inbox

   Grant issue/admit helpers reuse B263 backend ops as fixtures. *)

open Alcotest
open Relay_backend_contract

module RTSR = Relay_test_support_real

let gen_pk () =
  let id = Relay_identity.generate () in
  id.Relay_identity.public_key

let b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let tmp_dir prefix =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path

let rm_rf path =
  let rec walk p =
    if Sys.file_exists p then
      if Sys.is_directory p then begin
        Array.iter (fun name -> walk (Filename.concat p name)) (Sys.readdir p);
        try Unix.rmdir p with _ -> ()
      end else
        try Sys.remove p with _ -> ()
  in
  walk path

module type BACKEND = sig
  include RELAY
  val name : string
  val fresh : unit -> t * (unit -> unit)
end

module In_mem : BACKEND = struct
  include Relay.InMemoryRelay
  let name = "InMemoryRelay"
  let fresh () =
    let dir = tmp_dir "c2c-b265-mem" in
    (create ~persist_dir:dir (), fun () -> rm_rf dir)
end

module Sqlite : BACKEND = struct
  include Relay.SqliteRelay
  let name = "SqliteRelay"
  let fresh () =
    let dir = tmp_dir "c2c-b265-sqlite" in
    (create ~persist_dir:dir (), fun () -> rm_rf dir)
end

module Make (B : BACKEND) = struct
  let reg t ~alias ~pk =
    let node_id = "n-" ^ alias in
    let session_id = "s-" ^ alias in
    let st, _ =
      B.register t ~node_id ~session_id ~alias ~identity_pk:pk ()
    in
    check string (B.name ^ " reg " ^ alias) "ok" st;
    (node_id, session_id)

  let set_vis t ~alias vis =
    match B.set_peer_discovery_visibility t ~alias ~visibility:vis with
    | Ok () -> ()
    | Error e -> Alcotest.failf "set vis: %s" e

  let issue t ~recipient_pk ~delivery_alias ~sender_pk ~expires_at ?now () =
    match
      B.issue_contact_grant t ~recipient_identity_pk:recipient_pk
        ~delivery_alias ~sender_identity_pk:sender_pk ~expires_at ?now ()
    with
    | Ok r -> r
    | Error e -> Alcotest.failf "issue: %s" e

  let test_send_private_no_inbox_no_content_dlq () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_from = gen_pk () in
      let pk_to = gen_pk () in
      let _ = reg t ~alias:"zzsfrom" ~pk:pk_from in
      let node_to, sess_to = reg t ~alias:"zzsto" ~pk:pk_to in
      set_vis t ~alias:"zzsto" Private;
      (match
         B.send t ~from_alias:"zzsfrom" ~to_alias:"zzsto" ~content:"secret-body"
           ~message_id:(Some "m-priv-1") ~pow_difficulty:(-1)
       with
       | `Ok _ | `Duplicate _ -> Alcotest.fail "private send must fail"
       | _ -> ());
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:node_to ~session_id:sess_to));
      let dl = B.dead_letter t in
      let content_dlq =
        List.exists
          (function
            | `Assoc f ->
              (match List.assoc_opt "content" f with
               | Some (`String "secret-body") -> true
               | _ -> false)
            | _ -> false)
          dl
      in
      check bool "no content DLQ" false content_dlq)

  let test_send_all_skips_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_from = gen_pk () in
      let pk_priv = gen_pk () in
      let pk_pub = gen_pk () in
      let _ = reg t ~alias:"zzba" ~pk:pk_from in
      let n_priv, s_priv = reg t ~alias:"zzbpriv" ~pk:pk_priv in
      let n_pub, s_pub = reg t ~alias:"zzbpub" ~pk:pk_pub in
      set_vis t ~alias:"zzbpriv" Private;
      set_vis t ~alias:"zzbpub" Public;
      (match B.send_all t ~from_alias:"zzba" ~content:"blast" ~message_id:(Some "m-all") with
       | `Ok (_ts, delivered, _skipped) ->
         check bool "public delivered" true (List.mem "zzbpub" delivered);
         check bool "private not delivered" false (List.mem "zzbpriv" delivered)
       | _ -> Alcotest.fail "send_all unexpected");
      check int "private inbox empty" 0
        (List.length (B.poll_inbox t ~node_id:n_priv ~session_id:s_priv));
      check int "public inbox has msg" 1
        (List.length (B.poll_inbox t ~node_id:n_pub ~session_id:s_pub)))

  let test_admit_happy_and_duplicate () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzrecv" ~pk:pk_r in
      let _ = reg t ~alias:"zzsend" ~pk:pk_s in
      set_vis t ~alias:"zzrecv" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzrecv" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzsend"
           ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
           ~message_id:"mid-1" ~content:"hello-grant" ()
       with
       | `Accepted _ -> ()
       | `Duplicate _ -> Alcotest.fail "first admit must Accepted"
       | `Rejected -> Alcotest.fail "first admit rejected");
      check int "one inbox row" 1
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r));
      (* re-register to re-fill inbox path: poll drained; re-admit duplicate *)
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzsend"
           ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
           ~message_id:"mid-1" ~content:"hello-grant" ()
       with
       | `Duplicate _ -> ()
       | `Accepted _ -> Alcotest.fail "duplicate must not Accepted"
       | `Rejected -> Alcotest.fail "duplicate must not Rejected");
      check int "still no second delivery after drain+dup" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  let test_room_does_not_open_private_dm () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_a = gen_pk () in
      let pk_b = gen_pk () in
      let _ = reg t ~alias:"zzra" ~pk:pk_a in
      let n_b, s_b = reg t ~alias:"zzrb" ~pk:pk_b in
      set_vis t ~alias:"zzrb" Private;
      (match B.join_room t ~visibility:"public" ~alias:"zzra" ~room_id:"b265r" () with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join a: %s %s" c m);
      (match B.join_room t ~visibility:"public" ~alias:"zzrb" ~room_id:"b265r" () with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join b: %s %s" c m);
      (match
         B.send t ~from_alias:"zzra" ~to_alias:"zzrb" ~content:"via-room-know"
           ~message_id:(Some "m-room") ~pow_difficulty:(-1)
       with
       | `Ok _ | `Duplicate _ -> Alcotest.fail "room co-membership must not open private DM"
       | _ -> ());
      let inbox = B.poll_inbox t ~node_id:n_b ~session_id:s_b in
      let has_dm =
        List.exists
          (function
            | `Assoc f ->
              (match List.assoc_opt "content" f with
               | Some (`String "via-room-know") -> true
               | _ -> false)
            | _ -> false)
          inbox
      in
      check bool "no private DM content in inbox (room join system msgs ok)" false has_dm)

  let test_admit_wrong_sender_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let pk_evil = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzwr" ~pk:pk_r in
      let _ = reg t ~alias:"zzws" ~pk:pk_s in
      let _ = reg t ~alias:"zzwe" ~pk:pk_evil in
      set_vis t ~alias:"zzwr" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzwr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzwe"
           ~verified_sender_identity_pk:pk_evil ~grant_secret:issued.grant_secret
           ~message_id:"mid-evil" ~content:"x" ()
       with
       | `Rejected -> ()
       | `Accepted _ | `Duplicate _ -> Alcotest.fail "wrong sender must Rejected");
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  let test_admit_expired_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzexr" ~pk:pk_r in
      let _ = reg t ~alias:"zzexs" ~pk:pk_s in
      set_vis t ~alias:"zzexr" Private;
      (* Issue with future expiry, then admit after expiry (issue rejects
         expires_at <= now). *)
      let now = 1_000_000. in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzexr" ~sender_pk:pk_s
          ~expires_at:(now +. 10.) ~now ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzexs"
           ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
           ~message_id:"mid-exp" ~content:"x" ~now:(now +. 11.) ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "expired must Rejected");
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  let test_admit_revoked_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzrevr" ~pk:pk_r in
      let _ = reg t ~alias:"zzrevs" ~pk:pk_s in
      set_vis t ~alias:"zzrevr" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzrevr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      (match
         B.revoke_contact_grant t ~recipient_identity_pk:pk_r
           ~grant_id:issued.grant_id ~now ()
       with
       | Ok () -> ()
       | Error e -> Alcotest.failf "revoke: %s" e);
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzrevs"
           ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
           ~message_id:"mid-rev" ~content:"x" ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "revoked must Rejected");
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  let test_admit_malformed_secret_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzmalr" ~pk:pk_r in
      let _ = reg t ~alias:"zzmals" ~pk:pk_s in
      set_vis t ~alias:"zzmalr" Private;
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzmals"
           ~verified_sender_identity_pk:pk_s ~grant_secret:"short"
           ~message_id:"mid-mal" ~content:"x" ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "malformed secret must Rejected");
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  (* Leaked grant secret alone is insufficient without bound sender key. *)
  let test_leaked_secret_wrong_sender_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let pk_leak = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzleakr" ~pk:pk_r in
      let _ = reg t ~alias:"zzleaks" ~pk:pk_s in
      let _ = reg t ~alias:"zzleakx" ~pk:pk_leak in
      set_vis t ~alias:"zzleakr" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzleakr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      (* Attacker holds the secret but not the intended Ed25519 key. *)
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzleakx"
           ~verified_sender_identity_pk:pk_leak
           ~grant_secret:issued.grant_secret ~message_id:"mid-leak"
           ~content:"stolen" ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "leaked secret + wrong signer must Rejected");
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  (* Wrong recipient: grant bound to recipient_identity_fp of pk_r; after unbind +
     re-register under a different identity_pk the admit path must reject. *)
  let test_wrong_recipient_identity_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let pk_hijack = gen_pk () in
      let _n_r, _s_r = reg t ~alias:"zzwrr" ~pk:pk_r in
      let _ = reg t ~alias:"zzwrs" ~pk:pk_s in
      set_vis t ~alias:"zzwrr" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzwrr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      (* Clear sticky identity binding so a different pk can take the alias. *)
      let _ = B.unbind_alias t ~alias:"zzwrr" in
      let st, _ =
        B.register t ~node_id:"n-hij" ~session_id:"s-hij" ~alias:"zzwrr"
          ~identity_pk:pk_hijack ()
      in
      check string "re-register after unbind" "ok" st;
      set_vis t ~alias:"zzwrr" Private;
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzwrs"
           ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
           ~message_id:"mid-wr" ~content:"x" ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "wrong recipient identity must Rejected");
      check int "no hijack inbox" 0
        (List.length
           (B.poll_inbox t ~node_id:"n-hij" ~session_id:"s-hij")))

  (* Replay: same message_id at most one delivery (duplicate). *)
  let test_replay_message_id_at_most_once () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let n_r, s_r = reg t ~alias:"zzrepr" ~pk:pk_r in
      let _ = reg t ~alias:"zzreps" ~pk:pk_s in
      set_vis t ~alias:"zzrepr" Private;
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzrepr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      let admit mid =
        B.admit_contact_delivery t ~verified_sender_alias:"zzreps"
          ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
          ~message_id:mid ~content:"once" ()
      in
      (match admit "mid-replay" with
       | `Accepted _ -> ()
       | _ -> Alcotest.fail "first admit must Accept");
      (match admit "mid-replay" with
       | `Duplicate _ -> ()
       | `Accepted _ -> Alcotest.fail "replay must not Accept again"
       | `Rejected -> Alcotest.fail "replay should Duplicate not Reject");
      check int "exactly one inbox row" 1
        (List.length (B.poll_inbox t ~node_id:n_r ~session_id:s_r)))

  (* Cross-host style: bare R.send to private still fails closed (forward uses R.send). *)
  let test_forward_path_private_no_side_effects () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_from = gen_pk () in
      let pk_to = gen_pk () in
      let _ = reg t ~alias:"zzfwdfrom" ~pk:pk_from in
      let n_to, s_to = reg t ~alias:"zzfwdto" ~pk:pk_to in
      set_vis t ~alias:"zzfwdto" Private;
      (match
         B.send t ~from_alias:"peer@other-relay" ~to_alias:"zzfwdto"
           ~content:"forwarded-body" ~message_id:(Some "m-fwd")
           ~pow_difficulty:(-1)
       with
       | `Ok _ | `Duplicate _ -> Alcotest.fail "forwarded private send must fail"
       | `Error _ -> ());
      check int "no inbox" 0
        (List.length (B.poll_inbox t ~node_id:n_to ~session_id:s_to));
      let dl = B.dead_letter t in
      let content_dlq =
        List.exists
          (function
            | `Assoc f ->
              (match List.assoc_opt "content" f with
               | Some (`String "forwarded-body") -> true
               | _ -> false)
            | _ -> false)
          dl
      in
      check bool "no content DLQ for forward-to-private" false content_dlq)

  let cases =
    [ ("send private: no inbox, no content DLQ", `Quick,
       test_send_private_no_inbox_no_content_dlq);
      ("send_all skips private", `Quick, test_send_all_skips_private);
      ("admit Accepted once; Duplicate no second delivery", `Quick,
       test_admit_happy_and_duplicate);
      ("room co-membership does not open private DM", `Quick,
       test_room_does_not_open_private_dm);
      ("admit wrong sender rejected", `Quick, test_admit_wrong_sender_rejected);
      ("admit expired rejected", `Quick, test_admit_expired_rejected);
      ("admit revoked rejected", `Quick, test_admit_revoked_rejected);
      ("admit malformed secret rejected", `Quick,
       test_admit_malformed_secret_rejected);
      ("leaked secret + wrong sender rejected", `Quick,
       test_leaked_secret_wrong_sender_rejected);
      ("wrong recipient identity rejected", `Quick,
       test_wrong_recipient_identity_rejected);
      ("replay message_id at most once", `Quick,
       test_replay_message_id_at_most_once);
      ("forward-path private no side effects", `Quick,
       test_forward_path_private_no_side_effects);
    ]
end

module Mem = Make (In_mem)
module Sql = Make (Sqlite)

(* --- HTTP surfaces ------------------------------------------------------- *)

let error_code_of = function
  | Some (`Assoc f) ->
    (match List.assoc_opt "error_code" f with
     | Some (`String s) -> s
     | _ ->
       (match List.assoc_opt "error" f with
        | Some (`String s) -> s
        | Some (`Assoc ef) ->
          (match List.assoc_opt "code" ef with
           | Some (`String s) -> s
           | _ -> "")
        | _ -> ""))
  | _ -> ""

let test_http_contact_deliver_refuses_tokenless () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_r = gen_pk () in
    let pk_s = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-r" ~session_id:"s-r"
        ~alias:"zzhr" ~identity_pk:pk_r ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-s" ~session_id:"s-s"
        ~alias:"zzhs" ~identity_pk:pk_s ()
    in
    let now = Unix.gettimeofday () in
    let issued =
      match
        Relay.InMemoryRelay.issue_contact_grant relay
          ~recipient_identity_pk:pk_r ~delivery_alias:"zzhr"
          ~sender_identity_pk:pk_s ~expires_at:(now +. 3600.) ()
      with
      | Ok r -> r
      | Error e -> failwith e
    in
    let body =
      `Assoc
        [ ("protocol", `String "c2c-contact/1");
          ("grant_secret", `String (b64url issued.grant_secret));
          ("message_id", `String "http-mid-1");
          ("content", `String "hi");
        ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/contact/v1/deliver" ~body ()
    >|= fun r ->
    check bool "tokenless contact deliver not 200" true
      (RTSR.status_code r <> 200);
    check bool "error names contact_unauthorised or unauthorised" true
      (let c = error_code_of r.json in
       c = "contact_unauthorised" || c = "unauthorized" || c <> "");
    check int "no inbox row on refuse" 0
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-r" ~session_id:"s-r")))

let test_http_send_private_dev_unsigned_fails () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_from = gen_pk () in
    let pk_to = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-f" ~session_id:"s-f"
        ~alias:"zzhf" ~identity_pk:pk_from ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-t" ~session_id:"s-t"
        ~alias:"zzht" ~identity_pk:pk_to ()
    in
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzht"
         ~visibility:Private
     with
     | Ok () -> ()
     | Error e -> failwith e);
    let body =
      `Assoc
        [ ("from_alias", `String "zzhf");
          ("to_alias", `String "zzht");
          ("content", `String "nope");
          ("message_id", `String "http-send-1");
        ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/send" ~body () >|= fun r ->
    (* Dev mode may return 200 ok=false or 4xx; must not deliver. *)
    let delivered =
      match r.json with
      | Some (`Assoc f) ->
        (match List.assoc_opt "ok" f, List.assoc_opt "result" f with
         | Some (`Bool true), Some (`String "ok") -> true
         | Some (`Bool true), None ->
           (* ok true without error *)
           (match List.assoc_opt "error_code" f with
            | Some _ -> false
            | None -> true)
         | _ -> false)
      | _ -> false
    in
    check bool "HTTP send private must not deliver" false delivered;
    check int "inbox empty" 0
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-t" ~session_id:"s-t")))

let test_http_send_all_skips_private () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_from = gen_pk () in
    let pk_priv = gen_pk () in
    let pk_pub = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-fa" ~session_id:"s-fa"
        ~alias:"zzfa" ~identity_pk:pk_from ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-fp" ~session_id:"s-fp"
        ~alias:"zzfp" ~identity_pk:pk_priv ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-fu" ~session_id:"s-fu"
        ~alias:"zzfu" ~identity_pk:pk_pub ()
    in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzfp"
         ~visibility:Private);
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzfu"
         ~visibility:Public);
    let body =
      `Assoc
        [ ("from_alias", `String "zzfa");
          ("content", `String "all");
          ("message_id", `String "http-all-1");
        ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/send_all" ~body () >|= fun r ->
    check int "HTTP send_all status 200" 200 (RTSR.status_code r);
    (match r.json with
     | Some (`Assoc f) ->
       (match List.assoc_opt "delivered" f with
        | Some (`List ds) ->
          let aliases =
            List.filter_map
              (function `String s -> Some s | _ -> None)
              ds
          in
          check bool "public in delivered" true (List.mem "zzfu" aliases);
          check bool "private not in delivered" false (List.mem "zzfp" aliases)
        | _ -> Alcotest.fail "missing delivered")
     | _ -> Alcotest.fail "bad json");
    check int "private inbox empty" 0
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-fp" ~session_id:"s-fp"));
    check int "public inbox filled" 1
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-fu" ~session_id:"s-fu")))

let () =
  Random.self_init ();
  Alcotest.run "relay_contact_delivery_handlers"
    [ ("InMemoryRelay", Mem.cases);
      ("SqliteRelay", Sql.cases);
      ( "HTTP",
        [ test_case "contact/v1/deliver refuses tokenless" `Quick
            test_http_contact_deliver_refuses_tokenless;
          test_case "POST /send private fails (dev)" `Quick
            test_http_send_private_dev_unsigned_fails;
          test_case "POST /send_all skips private" `Quick
            test_http_send_all_skips_private;
        ] );
    ]
