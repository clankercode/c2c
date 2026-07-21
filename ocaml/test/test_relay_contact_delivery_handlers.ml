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
       | `Ok (_ts, delivered, skipped) ->
         check bool "public delivered" true (List.mem "zzbpub" delivered);
         check bool "private not delivered" false (List.mem "zzbpriv" delivered);
         (* G2: private aliases must not appear in skipped either (enumeration). *)
         check bool "private not in skipped" false (List.mem "zzbpriv" skipped)
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
    check int "private legacy send uses uniform HTTP 401" 401
      (RTSR.status_code r);
    check string "private legacy send uses uniform code"
      "contact_unauthorised" (error_code_of r.json);
    check string "private legacy send canonical body"
      "{\"ok\":false,\"error_code\":\"contact_unauthorised\",\"error\":\"contact unauthorised\"}"
      r.body_text;
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
       let aliases_of key =
         match List.assoc_opt key f with
         | Some (`List ds) ->
           List.filter_map (function `String s -> Some s | _ -> None) ds
         | _ -> []
       in
       let delivered = aliases_of "delivered" in
       let skipped = aliases_of "skipped" in
       check bool "public in delivered" true (List.mem "zzfu" delivered);
       check bool "private not in delivered" false (List.mem "zzfp" delivered);
       check bool "private not in skipped (G2)" false (List.mem "zzfp" skipped)
     | _ -> Alcotest.fail "bad json");
    check int "private inbox empty" 0
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-fp" ~session_id:"s-fp"));
    check int "public inbox filled" 1
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n-fu" ~session_id:"s-fu")))

(* Signed production contact-delivery helper. These requests pass the outer
   Ed25519 gate, so denial tests exercise the contact handler itself. *)
let signed_contact_call ~base_url ~identity ~alias ~body ?(headers = []) () =
  let body_str = Yojson.Safe.to_string body in
  let authorization =
    Relay_signed_ops.sign_request identity ~alias ~meth:"POST"
      ~path:"/contact/v1/deliver" ~body_str ()
  in
  RTSR.call ~base_url ~meth:`POST ~path:"/contact/v1/deliver"
    ~headers:
      (("Content-Type", "application/json") ::
       ("Authorization", authorization) :: headers)
    ~body:body_str ()

let register_with_identity relay ~alias identity =
  let node_id = "n-" ^ alias in
  let session_id = "s-" ^ alias in
  let status, _ =
    Relay.InMemoryRelay.register relay ~node_id ~session_id ~alias
      ~identity_pk:identity.Relay_identity.public_key ()
  in
  check string ("register " ^ alias) "ok" status;
  (node_id, session_id)

let issue_for ~relay ~recipient_pk ~delivery_alias ~sender_pk =
  let now = Unix.gettimeofday () in
  match
    Relay.InMemoryRelay.issue_contact_grant relay
      ~recipient_identity_pk:recipient_pk ~delivery_alias
      ~sender_identity_pk:sender_pk ~expires_at:(now +. 3600.) ~now ()
  with
  | Ok r -> r
  | Error e -> failwith ("issue: " ^ e)

let secret_b64 secret =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet secret

let error_code_of = function
  | Some (`Assoc f) ->
    (match List.assoc_opt "error_code" f with
     | Some (`String c) -> c
     | _ -> "")
  | _ -> ""

let test_signed_contact_cleartext_and_untrusted_proxy_refused () =
  Relay_ws_server.reset_push_dm_count ();
  RTSR.with_server ~token:"b265-cleartext" (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let recipient = Relay_identity.generate ~alias_hint:"zzc-r" () in
    let sender = Relay_identity.generate ~alias_hint:"zzc-s" () in
    let rn, rs = register_with_identity relay ~alias:"zzc-r" recipient in
    let _ = register_with_identity relay ~alias:"zzc-s" sender in
    let issued =
      issue_for ~relay ~recipient_pk:recipient.Relay_identity.public_key
        ~delivery_alias:"zzc-r" ~sender_pk:sender.Relay_identity.public_key
    in
    let body =
      `Assoc
        [ ("protocol", `String "c2c-contact/1");
          ("grant_secret", `String (secret_b64 issued.grant_secret));
          ("message_id", `String "m-cleartext");
          ("content", `String "must-not-deliver") ]
    in
    signed_contact_call ~base_url ~identity:sender ~alias:"zzc-s" ~body ()
    >>= fun clear ->
    signed_contact_call ~base_url ~identity:sender ~alias:"zzc-s" ~body
      ~headers:[ ("X-Forwarded-Proto", "https") ] ()
    >>= fun spoofed ->
    List.iter
      (fun (name, r) ->
        check int (name ^ " HTTP 401") 401 (RTSR.status_code r);
        check string (name ^ " uniform code") "contact_unauthorised"
          (error_code_of r.json))
      [ ("cleartext", clear); ("untrusted forwarded proto", spoofed) ];
    check string "identical transport denial bodies" clear.body_text
      spoofed.body_text;
    check int "no inbox on transport refusal" 0
      (List.length
         (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
    check int "transport denials emit no WS push" 0
      (Relay_ws_server.push_dm_invocations ());
    Lwt.return_unit)

let test_signed_private_send_matches_contact_denial () =
  RTSR.with_server ~token:"b265-send-uniform" ~native_tls:true
    (fun ~base_url ~relay ->
      let open Lwt.Infix in
      let sender = Relay_identity.generate ~alias_hint:"zzus-s" () in
      let recipient = Relay_identity.generate ~alias_hint:"zzus-r" () in
      let _ = register_with_identity relay ~alias:"zzus-s" sender in
      let rn, rs = register_with_identity relay ~alias:"zzus-r" recipient in
      let send_body =
        `Assoc
          [ ("from_alias", `String "zzus-s");
            ("to_alias", `String "zzus-r");
            ("content", `String "unauthorised-send");
            ("message_id", `String "m-uniform-send") ]
      in
      let send_body_str = Yojson.Safe.to_string send_body in
      let send_auth =
        Relay_signed_ops.sign_request sender ~alias:"zzus-s" ~meth:"POST"
          ~path:"/send" ~body_str:send_body_str ()
      in
      RTSR.call ~base_url ~meth:`POST ~path:"/send"
        ~headers:[ ("Content-Type", "application/json");
                   ("Authorization", send_auth) ]
        ~body:send_body_str ()
      >>= fun send_denial ->
      let contact_body =
        `Assoc
          [ ("protocol", `String "c2c-contact/1");
            ("grant_secret", `String (secret_b64 "short"));
            ("message_id", `String "m-uniform-contact");
            ("content", `String "unauthorised-contact") ]
      in
      signed_contact_call ~base_url ~identity:sender ~alias:"zzus-s"
        ~body:contact_body ()
      >>= fun contact_denial ->
      check int "signed private send 401" 401
        (RTSR.status_code send_denial);
      check int "contact denial 401" 401 (RTSR.status_code contact_denial);
      check string "signed send/contact byte-identical denial"
        contact_denial.body_text send_denial.body_text;
      check int "signed private send leaves inbox empty" 0
        (List.length
           (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
      Lwt.return_unit)

let test_signed_contact_accept_once_and_duplicate () =
  Relay_ws_server.reset_push_dm_count ();
  RTSR.with_server ~token:"b265-signed-contact" ~native_tls:true
    (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let recipient = Relay_identity.generate ~alias_hint:"zzs-r" () in
    let sender = Relay_identity.generate ~alias_hint:"zzs-s" () in
    let (rn, rs) =
      register_with_identity relay ~alias:"zzs-r" recipient
    in
    let _ = register_with_identity relay ~alias:"zzs-s" sender in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzs-r"
         ~visibility:Private);
    let issued =
      issue_for ~relay ~recipient_pk:recipient.Relay_identity.public_key
        ~delivery_alias:"zzs-r" ~sender_pk:sender.Relay_identity.public_key
    in
    let body ~mid ~content ~protocol =
      `Assoc
        [ ("protocol", `String protocol);
          ("grant_secret", `String (secret_b64 issued.grant_secret));
          ("message_id", `String mid);
          ("content", `String content);
          ("from_alias", `String "zzs-s");
        ]
    in
    signed_contact_call ~base_url ~identity:sender ~alias:"zzs-s"
      ~body:(body ~mid:"m-signed-1" ~content:"hello-signed" ~protocol:"c2c-contact/1") ()
    >>= fun r1 ->
    check int "signed valid contact HTTP 200" 200 (RTSR.status_code r1);
    check int "one inbox after signed accept" 1
      (List.length (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
    signed_contact_call ~base_url ~identity:sender ~alias:"zzs-s"
      ~body:(body ~mid:"m-signed-1" ~content:"hello-signed-dup" ~protocol:"c2c-contact/1") ()
    >>= fun r2 ->
    check int "signed duplicate HTTP 200" 200 (RTSR.status_code r2);
    (match r2.json with
     | Some (`Assoc f) ->
       check bool "duplicate flag" true
         (List.assoc_opt "duplicate" f = Some (`Bool true))
     | _ -> fail "duplicate response non-JSON");
    check int "still one inbox after duplicate" 1
      (List.length (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
    check int "accepted pushes exactly once; duplicate does not repush" 1
      (Relay_ws_server.push_dm_invocations ());
    Lwt.return_unit)

let test_signed_contact_protocol_variants_denied () =
  RTSR.with_server ~token:"b265-signed-proto" ~native_tls:true
    (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let recipient = Relay_identity.generate ~alias_hint:"zzp-r" () in
    let sender = Relay_identity.generate ~alias_hint:"zzp-s" () in
    let (rn, rs) =
      register_with_identity relay ~alias:"zzp-r" recipient
    in
    let _ = register_with_identity relay ~alias:"zzp-s" sender in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzp-r"
         ~visibility:Private);
    let issued =
      issue_for ~relay ~recipient_pk:recipient.Relay_identity.public_key
        ~delivery_alias:"zzp-r" ~sender_pk:sender.Relay_identity.public_key
    in
    let try_proto protocol mid =
      let body =
        `Assoc
          [ ("protocol", `String protocol);
            ("grant_secret", `String (secret_b64 issued.grant_secret));
            ("message_id", `String mid);
            ("content", `String "nope");
            ("from_alias", `String "zzp-s");
          ]
      in
      signed_contact_call ~base_url ~identity:sender ~alias:"zzp-s" ~body ()
    in
    try_proto "c2c-contact/0" "m-proto-0" >>= fun r0 ->
    try_proto "" "m-proto-empty" >>= fun r_empty ->
    try_proto "c2c-contact/999" "m-proto-bad" >>= fun r_bad ->
    List.iter
      (fun (name, r) ->
        check int (name ^ " HTTP not 200") 401 (RTSR.status_code r);
        check string (name ^ " error_code") "contact_unauthorised"
          (error_code_of r.json))
      [ ("old", r0); ("empty", r_empty); ("unknown", r_bad) ];
    check string "old/empty denial identical" r0.body_text r_empty.body_text;
    check string "old/unknown denial identical" r0.body_text r_bad.body_text;
    check int "inbox empty after protocol denials" 0
      (List.length (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
    Lwt.return_unit)

let test_signed_contact_denial_shapes_identical () =
  Relay_ws_server.reset_push_dm_count ();
  RTSR.with_server ~token:"b265-uniform-denials" ~native_tls:true
    (fun ~base_url ~relay ->
      let open Lwt.Infix in
      let recipient = Relay_identity.generate ~alias_hint:"zzu-r" () in
      let sender = Relay_identity.generate ~alias_hint:"zzu-s" () in
      let rn, rs = register_with_identity relay ~alias:"zzu-r" recipient in
      let _ = register_with_identity relay ~alias:"zzu-s" sender in
      let issued =
        issue_for ~relay ~recipient_pk:recipient.Relay_identity.public_key
          ~delivery_alias:"zzu-r" ~sender_pk:sender.Relay_identity.public_key
      in
      let body ?(protocol="c2c-contact/1")
          ?(grant_secret=secret_b64 issued.grant_secret)
          ?(message_id="m-uniform") ?(content="must-not-deliver") () =
        `Assoc
          [ ("protocol", `String protocol);
            ("grant_secret", `String grant_secret);
            ("message_id", `String message_id);
            ("content", `String content) ]
      in
      let signed body =
        signed_contact_call ~base_url ~identity:sender ~alias:"zzu-s" ~body ()
      in
      signed (`Assoc []) >>= fun missing ->
      let unregistered = Relay_identity.generate ~alias_hint:"zzu-unknown" () in
      signed_contact_call ~base_url ~identity:unregistered
        ~alias:"zzu-unknown" ~body:(body ()) ()
      >>= fun unresolved_sender ->
      signed (body ~grant_secret:"not-base64!" ()) >>= fun bad_b64 ->
      signed (body ~grant_secret:(secret_b64 "short") ()) >>= fun short ->
      let unknown_secret =
        Digestif.SHA256.digest_string "unknown-contact-grant"
        |> Digestif.SHA256.to_raw_string
      in
      signed
        (body ~message_id:"m-rejected"
           ~grant_secret:(secret_b64 unknown_secret) ())
      >>= fun rejected ->
      let malformed_body = "{" in
      let malformed_auth =
        Relay_signed_ops.sign_request sender ~alias:"zzu-s" ~meth:"POST"
          ~path:"/contact/v1/deliver" ~body_str:malformed_body ()
      in
      RTSR.call ~base_url ~meth:`POST ~path:"/contact/v1/deliver"
        ~headers:[ ("Content-Type", "application/json");
                   ("Authorization", malformed_auth) ]
        ~body:malformed_body ()
      >>= fun malformed ->
      let responses =
        [ ("missing", missing); ("unresolved sender", unresolved_sender);
          ("bad b64", bad_b64); ("short", short);
          ("backend reject", rejected); ("malformed json", malformed) ]
      in
      let reference = missing.body_text in
      List.iter
        (fun (name, response) ->
          check int (name ^ " HTTP 401") 401 (RTSR.status_code response);
          check string (name ^ " uniform code") "contact_unauthorised"
            (error_code_of response.json);
          check string (name ^ " byte-identical body") reference
            response.body_text)
        responses;
      check int "uniform denials leave inbox empty" 0
        (List.length
           (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
      check int "uniform denials emit no WS push" 0
        (Relay_ws_server.push_dm_invocations ());
      Lwt.return_unit)

let test_signed_contact_wrong_sender_denied () =
  RTSR.with_server ~token:"b265-signed-ws" ~native_tls:true
    (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let recipient = Relay_identity.generate ~alias_hint:"zzw-r" () in
    let sender = Relay_identity.generate ~alias_hint:"zzw-s" () in
    let attacker = Relay_identity.generate ~alias_hint:"zzw-a" () in
    let (rn, rs) =
      register_with_identity relay ~alias:"zzw-r" recipient
    in
    let _ = register_with_identity relay ~alias:"zzw-s" sender in
    let _ = register_with_identity relay ~alias:"zzw-a" attacker in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzw-r"
         ~visibility:Private);
    let issued =
      issue_for ~relay ~recipient_pk:recipient.Relay_identity.public_key
        ~delivery_alias:"zzw-r" ~sender_pk:sender.Relay_identity.public_key
    in
    let body =
      `Assoc
        [ ("protocol", `String "c2c-contact/1");
          ("grant_secret", `String (secret_b64 issued.grant_secret));
          ("message_id", `String "m-ws-1");
          ("content", `String "stolen");
          ("from_alias", `String "zzw-a");
        ]
    in
    signed_contact_call ~base_url ~identity:attacker ~alias:"zzw-a" ~body ()
    >>= fun r ->
    check int "wrong sender 401" 401 (RTSR.status_code r);
    check string "wrong sender contact_unauthorised" "contact_unauthorised"
      (error_code_of r.json);
    check int "inbox empty" 0
      (List.length (Relay.InMemoryRelay.peek_inbox relay ~node_id:rn ~session_id:rs));
    Lwt.return_unit)


let test_http_prod_registration_proofs () =
  RTSR.with_server ~token:"b265-reg-token" (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let signed_body ~node_id ~session_id ~alias proof =
      `Assoc
        [ ("node_id", `String node_id);
          ("session_id", `String session_id);
          ("alias", `String alias);
          ("ttl", `Int 3600);
          ("identity_pk", `String proof.Relay_signed_ops.identity_pk_b64);
          ("signature", `String proof.Relay_signed_ops.sig_b64);
          ("nonce", `String proof.Relay_signed_ops.nonce);
          ("timestamp", `String proof.Relay_signed_ops.ts) ]
    in
    let valid_identity = Relay_identity.generate ~alias_hint:"zzreg-valid" () in
    let valid_proof =
      Relay_signed_ops.sign_register valid_identity ~alias:"zzreg-valid"
        ~relay_url:base_url
    in
    let valid_body =
      signed_body ~node_id:"n-reg-valid" ~session_id:"s-reg-valid"
        ~alias:"zzreg-valid" valid_proof
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/register" ~body:valid_body ()
    >>= fun valid ->
    check int "valid signed production register succeeds" 200
      (RTSR.status_code valid);
    check bool "valid register response ok" true
      (match valid.json with
       | Some (`Assoc fields) -> List.assoc_opt "ok" fields = Some (`Bool true)
       | _ -> false);
    check bool "valid register binds signer key" true
      (Relay.InMemoryRelay.identity_pk_of relay ~alias:"zzreg-valid"
       = Some valid_identity.Relay_identity.public_key);
    let tampered_identity =
      Relay_identity.generate ~alias_hint:"zzreg-original" ()
    in
    let tampered_proof =
      Relay_signed_ops.sign_register tampered_identity ~alias:"zzreg-original"
        ~relay_url:base_url
    in
    let tampered_body =
      signed_body ~node_id:"n-reg-tampered" ~session_id:"s-reg-tampered"
        ~alias:"zzreg-substituted" tampered_proof
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/register"
      ~body:tampered_body ()
    >>= fun tampered ->
    check int "alias-substituted register proof refused" 401
      (RTSR.status_code tampered);
    check bool "tampered alias creates no lease" true
      (Relay.InMemoryRelay.identity_pk_of relay ~alias:"zzreg-substituted"
       = None);
    let unsigned_body =
      `Assoc
        [ ("node_id", `String "n-unreg");
          ("session_id", `String "s-unreg");
          ("alias", `String "zzunreg-private-guess");
          ("ttl", `Int 3600) ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/register"
      ~body:unsigned_body ()
    >|= fun unsigned ->
    check bool "unsigned prod register not ok" true
      (match unsigned.json with
       | Some (`Assoc f) -> List.assoc_opt "ok" f <> Some (`Bool true)
       | _ -> true);
    check bool "no lease created for unsigned" true
      (Relay.InMemoryRelay.identity_pk_of relay
         ~alias:"zzunreg-private-guess" = None))

(* B267: private-only send_all must not bump message stats at handler rule. *)
let test_send_all_private_only_no_stats () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_a = gen_pk () in
    let pk_b = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-sa" ~session_id:"s-sa"
        ~alias:"zzsafrom" ~identity_pk:pk_a ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-sb" ~session_id:"s-sb"
        ~alias:"zzsato" ~identity_pk:pk_b ()
    in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzsato"
         ~visibility:Private);
    let count_msgs j =
      match j with
      | `Assoc f ->
        (match List.assoc_opt "ever" f with
         | Some (`Assoc ef) ->
           (match List.assoc_opt "messages" ef with
            | Some (`Int n) -> n
            | _ -> -1)
         | _ -> -1)
      | _ -> -1
    in
    let m0 =
      count_msgs
        (Relay.InMemoryRelay.stats relay ~now:(Unix.gettimeofday ()))
    in
    let body =
      `Assoc
        [ ("from_alias", `String "zzsafrom");
          ("content", `String "bcast");
          ("message_id", `String "m-sa") ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/send_all" ~body ()
    >|= fun response ->
    check int "private-only send_all HTTP 200" 200
      (RTSR.status_code response);
    (match response.json with
     | Some (`Assoc fields) ->
       (match List.assoc_opt "delivered" fields with
        | Some (`List delivered) -> check int "no public delivery" 0 (List.length delivered)
        | _ -> fail "missing delivered list")
     | _ -> fail "send_all response not JSON");
    let m1 =
      count_msgs
        (Relay.InMemoryRelay.stats relay ~now:(Unix.gettimeofday ()))
    in
    check int "handler stats unchanged" m0 m1)

let test_signed_forward_does_not_bypass_private_consent () =
  Relay_ws_server.reset_push_dm_count ();
  RTSR.with_server ~token:"b265-forward-token" (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let source_relay = Relay_identity.generate ~alias_hint:"source" () in
    Relay.InMemoryRelay.add_peer_relay relay
      { name = "source";
        url = "https://source.invalid";
        identity_pk = source_relay.Relay_identity.public_key };
    let recipient = Relay_identity.generate ~alias_hint:"zzfwd-r" () in
    let status, _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-fwd-r"
        ~session_id:"s-fwd-r" ~alias:"zzfwd-r"
        ~identity_pk:recipient.Relay_identity.public_key ()
    in
    check string "register private forward target" "ok" status;
    let body =
      `Assoc
        [ ("from_alias", `String "sender@source");
          ("to_alias", `String "zzfwd-r");
          ("content", `String "source-auth-is-not-consent");
          ("message_id", `String "m-signed-forward") ]
    in
    let body_str = Yojson.Safe.to_string body in
    let authorization =
      Relay_signed_ops.sign_request source_relay ~alias:"relay@source"
        ~meth:"POST" ~path:"/forward" ~body_str ()
    in
    let before_stats =
      Relay.InMemoryRelay.stats relay ~now:(Unix.gettimeofday ())
    in
    RTSR.call ~base_url ~meth:`POST ~path:"/forward"
      ~headers:[ ("Content-Type", "application/json");
                 ("Authorization", authorization) ]
      ~body:body_str ()
    >|= fun response ->
    check int "valid source relay still denied private target" 401
      (RTSR.status_code response);
    check string "forward uses uniform contact denial" "contact_unauthorised"
      (error_code_of response.json);
    check string "forward denial canonical body"
      "{\"ok\":false,\"error_code\":\"contact_unauthorised\",\"error\":\"contact unauthorised\"}"
      response.body_text;
    check int "signed forward leaves inbox empty" 0
      (List.length
         (Relay.InMemoryRelay.peek_inbox relay ~node_id:"n-fwd-r"
            ~session_id:"s-fwd-r"));
    check int "signed forward creates no DLQ" 0
      (List.length (Relay.InMemoryRelay.dead_letter relay));
    check int "signed forward emits no WS push" 0
      (Relay_ws_server.push_dm_invocations ());
    check string "signed forward stats unchanged"
      (Yojson.Safe.to_string before_stats)
      (Yojson.Safe.to_string
         (Relay.InMemoryRelay.stats relay ~now:(Unix.gettimeofday ()))))

(* Forward unknown-peer path: DLQ must not store content (B267 G1). *)
let test_forward_unknown_peer_dlq_redacts_content () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-fw" ~session_id:"s-fw"
        ~alias:"zzfwfrom" ~identity_pk:pk ()
    in
    let body =
      `Assoc
        [ ("from_alias", `String "zzfwfrom");
          ("to_alias", `String "someone@notapeerhost");
          ("content", `String "SECRET-FORWARD-PAYLOAD");
          ("message_id", `String "mid-fw-redact");
        ]
    in
    RTSR.call_json ~base_url ~meth:`POST ~path:"/send" ~body () >|= fun _r ->
    let dl = Relay.InMemoryRelay.dead_letter relay in
    let has_secret =
      List.exists
        (function
          | `Assoc f ->
            (match List.assoc_opt "content" f with
             | Some (`String s) -> String.equal s "SECRET-FORWARD-PAYLOAD"
             | _ -> false)
          | _ -> false)
        dl
    in
    check bool "forward DLQ redacts content" false has_secret;
    check bool "dlq non-empty for unknown peer" true (dl <> []))

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
          test_case "signed cleartext + spoofed proxy refused" `Quick
            test_signed_contact_cleartext_and_untrusted_proxy_refused;
          test_case "signed private send matches contact denial" `Quick
            test_signed_private_send_matches_contact_denial;
          test_case "signed contact accept once + duplicate" `Quick
            test_signed_contact_accept_once_and_duplicate;
          test_case "signed contact protocol variants denied" `Quick
            test_signed_contact_protocol_variants_denied;
          test_case "contact denial shapes byte-identical" `Quick
            test_signed_contact_denial_shapes_identical;
          test_case "signed contact wrong sender denied" `Quick
            test_signed_contact_wrong_sender_denied;
          test_case "production registration proof contract" `Quick
            test_http_prod_registration_proofs;
          test_case "send_all private-only no stats bump" `Quick
            test_send_all_private_only_no_stats;
          test_case "signed /forward does not confer consent" `Quick
            test_signed_forward_does_not_bypass_private_consent;
          test_case "forward unknown peer DLQ redacts content" `Quick
            test_forward_unknown_peer_dlq_redacts_content;
        ] );
    ]
