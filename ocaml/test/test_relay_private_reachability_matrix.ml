(* B267 — end-to-end private-reachability attack matrix (hermetic).

   Maps B262 §15 abuse rows to dual-backend + HTTP cases. Complements:
   - test_relay_contact_grants (lifecycle)
   - test_relay_contact_delivery_handlers (ingress attacks)
   - test_relay_private_discovery (oracles)
   - test_relay_private_migration (upgrade)

   Does not replace live tmux dogfood or independent security review. *)

open Alcotest
open Relay
open Relay_backend_contract

module RTSR = Relay_test_support_real

let gen_pk () =
  let id = Relay_identity.generate () in
  id.Relay_identity.public_key

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
    let dir = tmp_dir "c2c-b267-mem" in
    (create ~persist_dir:dir (), fun () -> rm_rf dir)
end

module Sqlite : BACKEND = struct
  include Relay.SqliteRelay
  let name = "SqliteRelay"
  let fresh () =
    let dir = tmp_dir "c2c-b267-sql" in
    (create ~persist_dir:dir (), fun () -> rm_rf dir)
end

module Make (B : BACKEND) = struct
  let reg t ~alias ~pk =
    let node_id = "n-" ^ alias in
    let session_id = "s-" ^ alias in
    let st, _ = B.register t ~node_id ~session_id ~alias ~identity_pk:pk () in
    check string (B.name ^ " reg " ^ alias) "ok" st;
    (node_id, session_id)

  let set_vis t ~alias vis =
    match B.set_peer_discovery_visibility t ~alias ~visibility:vis with
    | Ok () -> ()
    | Error e -> failf "set vis: %s" e

  let issue t ~recipient_pk ~delivery_alias ~sender_pk ~expires_at ?now () =
    match
      B.issue_contact_grant t ~recipient_identity_pk:recipient_pk
        ~delivery_alias ~sender_identity_pk:sender_pk ~expires_at ?now ()
    with
    | Ok r -> r
    | Error e -> failf "issue: %s" e

  let content_dlq_has t needle =
    List.exists
      (function
        | `Assoc f ->
          (match List.assoc_opt "content" f with
           | Some (`String s) when s = needle -> true
           | _ -> false)
        | _ -> false)
      (B.dead_letter t)

  (* A1: public recipient still accepts legacy send without grant. *)
  let test_public_legacy_send_ok () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_a = gen_pk () in
      let pk_b = gen_pk () in
      let _ = reg t ~alias:"zzpubfrom" ~pk:pk_a in
      let n_b, s_b = reg t ~alias:"zzpubto" ~pk:pk_b in
      set_vis t ~alias:"zzpubto" Public;
      (match
         B.send t ~from_alias:"zzpubfrom" ~to_alias:"zzpubto" ~content:"hi-public"
           ~message_id:(Some "m-pub") ~pow_difficulty:(-1)
       with
       | `Ok _ -> ()
       | `Duplicate _ -> ()
       | `Error (c, m) -> failf "public send failed: %s %s" c m);
      check int "public inbox has msg" 1
        (List.length (B.poll_inbox t ~node_id:n_b ~session_id:s_b)))

  (* A2: private send reject does not bump message stats. *)
  let test_private_reject_no_stats_bump () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_a = gen_pk () in
      let pk_b = gen_pk () in
      let _ = reg t ~alias:"zzstfrom" ~pk:pk_a in
      let _ = reg t ~alias:"zzstto" ~pk:pk_b in
      set_vis t ~alias:"zzstto" Private;
      let now = 2_000_000. in
      let before = B.stats t ~now in
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
      let m0 = count_msgs before in
      (match
         B.send t ~from_alias:"zzstfrom" ~to_alias:"zzstto" ~content:"nope"
           ~message_id:(Some "m-st") ~pow_difficulty:(-1)
       with
       | `Error _ -> ()
       | _ -> fail "private send must fail");
      (* Explicit note would be wrong; reject path must not call stats_note. *)
      let after = B.stats t ~now in
      let m1 = count_msgs after in
      if m0 >= 0 && m1 >= 0 then
        check int "stats messages unchanged on reject" m0 m1)

  (* A3: guessed unknown alias — same error class as private; no content DLQ. *)
  let test_guessed_alias_uniform_with_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_a = gen_pk () in
      let pk_b = gen_pk () in
      let _ = reg t ~alias:"zzgfrom" ~pk:pk_a in
      let _ = reg t ~alias:"zzgpriv" ~pk:pk_b in
      set_vis t ~alias:"zzgpriv" Private;
      let err_priv =
        match
          B.send t ~from_alias:"zzgfrom" ~to_alias:"zzgpriv" ~content:"p"
            ~message_id:(Some "m-gp") ~pow_difficulty:(-1)
        with
        | `Error (c, _) -> c
        | _ -> fail "private must error"
      in
      let err_guess =
        match
          B.send t ~from_alias:"zzgfrom" ~to_alias:"zznobody-b267" ~content:"g"
            ~message_id:(Some "m-gg") ~pow_difficulty:(-1)
        with
        | `Error (c, _) -> c
        | _ -> fail "unknown must error"
      in
      check string "error code class matches" err_guess err_priv;
      check bool "no private content in DLQ" false
        (content_dlq_has t "p"))

  (* A4: authorised admit then restart preserves delivery + denies second mid. *)
  let test_authorised_admit_survives_restart () =
    match B.name with
    | "SqliteRelay" ->
      let dir = tmp_dir "c2c-b267-restart" in
      Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
        let pk_r = gen_pk () in
        let pk_s = gen_pk () in
        let t1 = B.create ~persist_dir:dir () in
        let n_r, s_r =
          let st, _ =
            B.register t1 ~node_id:"n-r" ~session_id:"s-r" ~alias:"zzrr"
              ~identity_pk:pk_r ()
          in
          check string "reg r" "ok" st;
          ("n-r", "s-r")
        in
        let _ =
          let st, _ =
            B.register t1 ~node_id:"n-s" ~session_id:"s-s" ~alias:"zzrs"
              ~identity_pk:pk_s ()
          in
          check string "reg s" "ok" st
        in
        set_vis t1 ~alias:"zzrr" Private;
        let now = Unix.gettimeofday () in
        let issued =
          issue t1 ~recipient_pk:pk_r ~delivery_alias:"zzrr" ~sender_pk:pk_s
            ~expires_at:(now +. 3600.) ()
        in
        (match
           B.admit_contact_delivery t1 ~verified_sender_alias:"zzrs"
             ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
             ~message_id:"mid-restart" ~content:"persisted-ok" ~now ()
         with
         | `Accepted _ -> ()
         | _ -> fail "first admit must Accept");
        let t2 = B.create ~persist_dir:dir () in
        (match
           B.admit_contact_delivery t2 ~verified_sender_alias:"zzrs"
             ~verified_sender_identity_pk:pk_s ~grant_secret:issued.grant_secret
             ~message_id:"mid-restart" ~content:"dup" ~now:(now +. 1.) ()
         with
         | `Duplicate _ -> ()
         | `Accepted _ -> fail "restart must preserve message_id"
         | `Rejected -> fail "should Duplicate not Reject");
        check int "one inbox after restart path" 1
          (List.length (B.poll_inbox t2 ~node_id:n_r ~session_id:s_r)))
    | _ -> ()

  (* A5: room co-membership does not grant private DM (duplicate of handlers, both backends). *)
  let test_room_not_dm_route () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_a = gen_pk () in
      let pk_b = gen_pk () in
      let _ = reg t ~alias:"zzrmfrom" ~pk:pk_a in
      let n_b, s_b = reg t ~alias:"zzrmto" ~pk:pk_b in
      set_vis t ~alias:"zzrmto" Private;
      (match
         B.join_room t ~visibility:"public" ~alias:"zzrmfrom" ~room_id:"b267-r"
           ()
       with
       | `Ok -> ()
       | `Error (c, m) -> failf "join a: %s %s" c m);
      (match
         B.join_room t ~visibility:"public" ~alias:"zzrmto" ~room_id:"b267-r" ()
       with
       | `Ok -> ()
       | `Error (c, m) -> failf "join b: %s %s" c m);
      (match
         B.send t ~from_alias:"zzrmfrom" ~to_alias:"zzrmto" ~content:"via-room"
           ~message_id:(Some "m-room") ~pow_difficulty:(-1)
       with
       | `Ok _ | `Duplicate _ -> fail "private DM must fail despite shared room"
       | _ -> ());
      let inbox = B.poll_inbox t ~node_id:n_b ~session_id:s_b in
      let has_dm =
        List.exists
          (function
            | `Assoc f ->
              (match List.assoc_opt "content" f with
               | Some (`String "via-room") -> true
               | _ -> false)
            | _ -> false)
          inbox
      in
      check bool "no private DM content (room system msgs ok)" false has_dm)

  (* A6: grant scope — list metadata never contains raw secret. *)
  let test_list_grants_redacts_secret () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_r = gen_pk () in
      let pk_s = gen_pk () in
      let _ = reg t ~alias:"zzlr" ~pk:pk_r in
      let _ = reg t ~alias:"zzls" ~pk:pk_s in
      let now = Unix.gettimeofday () in
      let issued =
        issue t ~recipient_pk:pk_r ~delivery_alias:"zzlr" ~sender_pk:pk_s
          ~expires_at:(now +. 3600.) ()
      in
      let metas = B.list_contact_grants t ~recipient_identity_pk:pk_r in
      let blob =
        metas
        |> List.map (fun m ->
             Printf.sprintf "%s|%s|%s" m.grant_id m.delivery_alias
               m.sender_fp_prefix)
        |> String.concat ";"
      in
      check bool "secret absent from list meta" false
        (try
           ignore
             (Str.search_forward (Str.regexp_string issued.grant_secret) blob 0);
           true
         with Not_found -> false))

  let cases =
    [ ("public legacy send still works", `Quick, test_public_legacy_send_ok);
      ("private reject does not bump stats", `Quick,
       test_private_reject_no_stats_bump);
      ("guessed alias error class matches private", `Quick,
       test_guessed_alias_uniform_with_private);
      ("authorised admit survives restart (sqlite)", `Quick,
       test_authorised_admit_survives_restart);
      ("room co-membership is not DM route", `Quick, test_room_not_dm_route);
      ("list_contact_grants redacts secret", `Quick,
       test_list_grants_redacts_secret);
    ]
end

module Mem = Make (In_mem)
module Sql = Make (Sqlite)

(* HTTP: anonymous probe surfaces on token-configured relay. *)
let test_http_anonymous_probes_denied () =
  RTSR.with_server ~token:"b267-matrix-token" (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n" ~session_id:"s"
        ~alias:"zzpriv" ~identity_pk:pk ()
    in
    ignore
      (Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzpriv"
         ~visibility:Private);
    RTSR.call_json ~base_url ~meth:`GET ~path:"/list" () >>= fun list_r ->
    RTSR.call_json ~base_url ~meth:`GET ~path:"/pubkey/zzpriv" ()
    >>= fun pk_r ->
    RTSR.call_json ~base_url ~meth:`POST ~path:"/send"
      ~body:
        (`Assoc
           [ ("from_alias", `String "evil");
             ("to_alias", `String "zzpriv");
             ("content", `String "x");
           ])
      ()
    >|= fun send_r ->
    check bool "anon list not 200" true (RTSR.status_code list_r <> 200);
    check bool "anon pubkey not 200 with keys" true
      (RTSR.status_code pk_r <> 200
       || not (String.contains pk_r.RTSR.body_text 'e'
               &&
               try
                 ignore
                   (Str.search_forward
                      (Str.regexp_string "ed25519_pubkey")
                      pk_r.RTSR.body_text 0);
                 true
               with Not_found -> false));
    check bool "anon send not success" true
      (RTSR.status_code send_r <> 200
       ||
       match send_r.json with
       | Some (`Assoc f) -> List.assoc_opt "ok" f <> Some (`Bool true)
       | _ -> true);
    check int "inbox empty" 0
      (List.length
         (Relay.InMemoryRelay.poll_inbox relay ~node_id:"n" ~session_id:"s")))

let test_http_health_prod_ads () =
  RTSR.with_server ~token:"b267-matrix-token" (fun ~base_url ~relay:_ ->
    let open Lwt.Infix in
    RTSR.call_json ~base_url ~meth:`GET ~path:"/health" () >|= fun r ->
    check int "200" 200 (RTSR.status_code r);
    match r.json with
    | Some (`Assoc f) ->
      check bool "prod" true
        (List.assoc_opt "auth_mode" f = Some (`String "prod"));
      check bool "contact_protocol" true
        (List.assoc_opt "contact_protocol" f = Some (`Int 1));
      check bool "private_reachability" true
        (List.assoc_opt "private_reachability" f
         = Some (`String "consent_gated"))
    | _ -> fail "bad health")

let () =
  Random.self_init ();
  Alcotest.run "relay_private_reachability_matrix"
    [ ("InMemoryRelay", Mem.cases);
      ("SqliteRelay", Sql.cases);
      ( "HTTP matrix",
        [ test_case "anonymous probes denied on token relay" `Quick
            test_http_anonymous_probes_denied;
          test_case "prod health ads consent_gated" `Quick
            test_http_health_prod_ads;
        ] );
    ]
