(* B264 — private peer discovery + existence oracles (G2).

   Design freeze:
     .collab/design/2026-07-22-b262-contact-grant-protocol.md §9, §15
   Threat model:
     .collab/research/2026-07-22-relay-private-reachability-threat-model.md (G2)

   Surfaces under test:
   - ordinary [list_peers] vs [list_peers_admin]
   - peer-facing pubkey lookups ([peer_identity_pk_of] …) used by /pubkey
   - registration metadata serialisation (no private alias material)
   - deliberate room visibility preserved; room roster ≠ peer discovery
   - send error uniformity private vs unknown + no content-bearing DLQ
   - /stats and /health do not embed private aliases
   - HTTP /list and /pubkey on production callback (token-configured)

   Until B264 implements real visibility storage + filtering these tests
   must FAIL (red). Do not weaken assertions to green. *)

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
    let dir = tmp_dir "c2c-disc-mem" in
    let t = create ~persist_dir:dir () in
    (t, fun () -> rm_rf dir)
end

module Sqlite : BACKEND = struct
  include Relay.SqliteRelay
  let name = "SqliteRelay"
  let fresh () =
    let dir = tmp_dir "c2c-disc-sqlite" in
    let t = create ~persist_dir:dir () in
    (t, fun () -> rm_rf dir)
end

let contains_alias leases alias =
  List.exists (fun l -> Relay.RegistrationLease.alias l = alias) leases

let json_string_contains hay needle =
  try
    let _ = Str.search_forward (Str.regexp_string needle) hay 0 in
    true
  with Not_found -> false

module Make_tests (B : BACKEND) = struct
  let register t ~alias ~pk =
    let node_id = "n-" ^ alias in
    let session_id = "s-" ^ alias in
    let status, _lease =
      B.register t ~node_id ~session_id ~alias ~identity_pk:pk
        ~client_type:"claude" ~client_version:"0.99.0" ~client_os:"linux"
        ~opaque_host_id:(Some "b264aabbccdd") ()
    in
    Alcotest.(check string) (B.name ^ " register " ^ alias) "ok" status;
    (node_id, session_id)

  let mark_private t ~alias =
    match B.set_peer_discovery_visibility t ~alias ~visibility:Private with
    | Ok () -> ()
    | Error e -> Alcotest.failf "set private failed: %s" e

  let mark_public t ~alias =
    match B.set_peer_discovery_visibility t ~alias ~visibility:Public with
    | Ok () -> ()
    | Error e -> Alcotest.failf "set public failed: %s" e

  (* 1. Ordinary list_peers omits private leases. *)
  let test_ordinary_list_omits_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_priv = gen_pk () in
      let pk_pub = gen_pk () in
      let _ = register t ~alias:"zzpriv" ~pk:pk_priv in
      let _ = register t ~alias:"zzpub" ~pk:pk_pub in
      mark_private t ~alias:"zzpriv";
      mark_public t ~alias:"zzpub";
      let peers = B.list_peers t ~include_dead:false in
      Alcotest.(check bool) "private absent from ordinary list" false
        (contains_alias peers "zzpriv");
      Alcotest.(check bool) "public present in ordinary list" true
        (contains_alias peers "zzpub");
      let blob =
        peers
        |> List.map (fun l ->
             Yojson.Safe.to_string (Relay.RegistrationLease.to_json l))
        |> String.concat "|"
      in
      Alcotest.(check bool) "serialised list has no private alias" false
        (json_string_contains blob "zzpriv");
      Alcotest.(check bool) "serialised list has no private session id" false
        (json_string_contains blob "s-zzpriv");
      Alcotest.(check bool) "serialised list has no private node id" false
        (json_string_contains blob "n-zzpriv"))

  (* 2. Admin list may still include private. *)
  let test_admin_list_includes_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzadminp" ~pk in
      mark_private t ~alias:"zzadminp";
      let peers = B.list_peers_admin t ~include_dead:false in
      Alcotest.(check bool) "admin list sees private" true
        (contains_alias peers "zzadminp"))

  (* 3. Visibility reads back after set. *)
  let test_visibility_reads_back_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzvis" ~pk in
      mark_private t ~alias:"zzvis";
      match B.peer_discovery_visibility_of t ~alias:"zzvis" with
      | Some Private -> ()
      | Some Public ->
        Alcotest.fail "visibility must read back Private after set"
      | None -> Alcotest.fail "visibility missing for registered alias")

  (* 4. Peer-facing pubkey lookups hide private (same as unknown).
     Internal [identity_pk_of] remains available for owner routing. *)
  let test_peer_pubkey_lookups_hide_private () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzhid" ~pk in
      mark_private t ~alias:"zzhid";
      Alcotest.(check bool) "peer_identity_pk_of private is None" true
        (B.peer_identity_pk_of t ~alias:"zzhid" = None);
      Alcotest.(check bool) "peer_enc_pubkey_of private is None" true
        (B.peer_enc_pubkey_of t ~alias:"zzhid" = None);
      Alcotest.(check bool) "peer_signed_at_of private is None" true
        (B.peer_signed_at_of t ~alias:"zzhid" = None);
      Alcotest.(check bool) "peer_sig_b64_of private is None" true
        (B.peer_sig_b64_of t ~alias:"zzhid" = None);
      Alcotest.(check bool) "unknown also None" true
        (B.peer_identity_pk_of t ~alias:"zznobody" = None);
      (* Internal owner lookup still sees the key. *)
      match B.identity_pk_of t ~alias:"zzhid" with
      | Some p when p = pk -> ()
      | Some _ -> Alcotest.fail "internal identity_pk mismatch"
      | None ->
        Alcotest.fail
          "internal identity_pk_of must still resolve private for owner paths")

  (* 5. Public opt-in still resolves via peer-facing lookup. *)
  let test_peer_pubkey_public_still_resolves () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzok" ~pk in
      mark_public t ~alias:"zzok";
      match B.peer_identity_pk_of t ~alias:"zzok" with
      | Some p when p = pk -> ()
      | Some _ -> Alcotest.fail "public peer identity_pk mismatch"
      | None -> Alcotest.fail "public alias must resolve peer_identity_pk")

  (* 6. Send to private without grant: uniform error vs unknown; no content DLQ. *)
  let test_send_private_uniform_no_content_dlq () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk_from = gen_pk () in
      let pk_priv = gen_pk () in
      let _ = register t ~alias:"zzfrom" ~pk:pk_from in
      let _ = register t ~alias:"zzprivto" ~pk:pk_priv in
      mark_private t ~alias:"zzprivto";
      let err_priv =
        match
          B.send t ~from_alias:"zzfrom" ~to_alias:"zzprivto" ~content:"nope"
            ~message_id:None ~pow_difficulty:(-1)
        with
        | `Error (code, msg) -> (code, msg)
        | `Ok _ | `Duplicate _ ->
          Alcotest.fail "send to private without grant must not succeed"
      in
      let err_unknown =
        match
          B.send t ~from_alias:"zzfrom" ~to_alias:"zzghost" ~content:"nope"
            ~message_id:None ~pow_difficulty:(-1)
        with
        | `Error (code, msg) -> (code, msg)
        | `Ok _ | `Duplicate _ ->
          Alcotest.fail "send to unknown must error"
      in
      Alcotest.(check string) "error code uniform with unknown" (fst err_unknown)
        (fst err_priv);
      let dl = B.dead_letter t in
      let private_content_dlq =
        List.exists
          (fun j ->
            match j with
            | `Assoc fields ->
              (match
                 ( List.assoc_opt "to_alias" fields,
                   List.assoc_opt "content" fields )
               with
               | Some (`String "zzprivto"), Some (`String c) when c <> "" ->
                 true
               | _ -> false)
            | _ -> false)
          dl
      in
      Alcotest.(check bool) "no content DLQ for private reject" false
        private_content_dlq)

  let test_send_all_does_not_enumerate_private_in_results () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let sender_pk = gen_pk () in
      let private_pk = gen_pk () in
      let public_pk = gen_pk () in
      let _ = register t ~alias:"zzbroadcastsender" ~pk:sender_pk in
      let private_node, private_session =
        register t ~alias:"zzbroadcastprivate" ~pk:private_pk
      in
      let public_node, public_session =
        register t ~alias:"zzbroadcastpublic" ~pk:public_pk
      in
      mark_public t ~alias:"zzbroadcastsender";
      mark_private t ~alias:"zzbroadcastprivate";
      mark_public t ~alias:"zzbroadcastpublic";
      match
        B.send_all t ~from_alias:"zzbroadcastsender" ~content:"broadcast"
          ~message_id:(Some "b264-send-all")
      with
      | `Ok (_ts, delivered, skipped) ->
        Alcotest.(check bool) "public recipient delivered" true
          (List.mem "zzbroadcastpublic" delivered);
        Alcotest.(check bool) "private recipient not delivered" false
          (List.mem "zzbroadcastprivate" delivered);
        Alcotest.(check bool) "private alias absent from skipped oracle" false
          (List.mem "zzbroadcastprivate" skipped);
        Alcotest.(check int) "private inbox empty" 0
          (List.length
             (B.poll_inbox t ~node_id:private_node
                ~session_id:private_session));
        Alcotest.(check int) "public inbox has broadcast" 1
          (List.length
             (B.poll_inbox t ~node_id:public_node ~session_id:public_session)))

  (* 7. Rooms: deliberate public/gated listing preserved; private room omitted. *)
  let test_rooms_policy_preserved () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzroom" ~pk in
      (match B.join_room t ~visibility:"public" ~alias:"zzroom" ~room_id:"r-pub" () with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join public: %s %s" c m);
      (match B.join_room t ~visibility:"gated" ~alias:"zzroom" ~room_id:"r-gat" () with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join gated: %s %s" c m);
      (match
         B.join_room t ~visibility:"private" ~alias:"zzroom" ~room_id:"r-prv" ()
       with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join private room: %s %s" c m);
      let rooms = B.list_rooms t in
      let ids =
        List.filter_map
          (function
            | `Assoc f ->
              (match List.assoc_opt "room_id" f with
               | Some (`String s) -> Some s
               | _ -> None)
            | _ -> None)
          rooms
      in
      Alcotest.(check bool) "public room listed" true (List.mem "r-pub" ids);
      Alcotest.(check bool) "gated room listed" true (List.mem "r-gat" ids);
      Alcotest.(check bool) "private room omitted" false (List.mem "r-prv" ids))

  (* 8. Public room roster does not put private recipient on peer list. *)
  let test_room_roster_not_peer_discovery () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzroster" ~pk in
      mark_private t ~alias:"zzroster";
      (match
         B.join_room t ~visibility:"public" ~alias:"zzroster" ~room_id:"r-show"
           ()
       with
       | `Ok -> ()
       | `Error (c, m) -> Alcotest.failf "join: %s %s" c m);
      let peers = B.list_peers t ~include_dead:false in
      Alcotest.(check bool) "private alias still absent from peer list" false
        (contains_alias peers "zzroster");
      Alcotest.(check bool) "private still hidden from peer_identity_pk_of" true
        (B.peer_identity_pk_of t ~alias:"zzroster" = None))

  (* 9. Stats JSON must not embed the private alias string. *)
  let test_stats_no_private_alias_string () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let pk = gen_pk () in
      let _ = register t ~alias:"zzstatpriv" ~pk in
      mark_private t ~alias:"zzstatpriv";
      let now = Unix.gettimeofday () in
      B.stats_note_activity t ~machine_id:"host-zz" ~alias:"zzstatpriv" ~ts:now
        ();
      let stats = B.stats t ~now in
      let blob = Yojson.Safe.to_string stats in
      Alcotest.(check bool) "stats JSON has no private alias" false
        (json_string_contains blob "zzstatpriv"))

  let cases =
    [
      ( "ordinary list_peers omits private",
        `Quick,
        test_ordinary_list_omits_private );
      ( "admin list_peers includes private",
        `Quick,
        test_admin_list_includes_private );
      ( "visibility reads back Private",
        `Quick,
        test_visibility_reads_back_private );
      ( "peer pubkey lookups hide private",
        `Quick,
        test_peer_pubkey_lookups_hide_private );
      ( "peer pubkey public still resolves",
        `Quick,
        test_peer_pubkey_public_still_resolves );
      ( "send private uniform error, no content DLQ",
        `Quick,
        test_send_private_uniform_no_content_dlq );
      ( "send_all results do not enumerate private aliases",
        `Quick,
        test_send_all_does_not_enumerate_private_in_results );
      ( "rooms policy preserved",
        `Quick,
        test_rooms_policy_preserved );
      ( "room roster is not peer discovery",
        `Quick,
        test_room_roster_not_peer_discovery );
      ( "stats JSON has no private alias",
        `Quick,
        test_stats_no_private_alias_string );
    ]
end

module Mem_tests = Make_tests (In_mem)
module Sqlite_tests = Make_tests (Sqlite)

(* --- HTTP oracles against production make_callback (InMemory) ------------ *)

let peers_from_list_json = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt "peers" fields with
     | Some (`List ps) -> ps
     | _ -> [])
  | _ -> []

let peer_aliases_json peers =
  List.filter_map
    (function
      | `Assoc f ->
        (match List.assoc_opt "alias" f with
         | Some (`String a) -> Some a
         | _ -> None)
      | _ -> None)
    peers

let test_http_list_omits_private () =
  RTSR.with_server ~token:"b264-disc-token" (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_priv = gen_pk () in
    let pk_pub = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-hp" ~session_id:"s-hp"
        ~alias:"zzhttppriv" ~identity_pk:pk_priv ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-hu" ~session_id:"s-hu"
        ~alias:"zzhttppub" ~identity_pk:pk_pub ()
    in
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay
         ~alias:"zzhttppriv" ~visibility:Private
     with
     | Ok () -> ()
     | Error e -> failwith ("set private: " ^ e));
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzhttppub"
         ~visibility:Public
     with
     | Ok () -> ()
     | Error e -> failwith ("set public: " ^ e));
    (* Token-configured peer route: unsigned /list is rejected (auth matrix).
       Dev-mode (token=None) is out of production claims; use tokenless only
       to exercise body shape after auth is satisfied. Here we drive the
       backend-seeded relay via unsigned access is blocked — re-run with
       token=None for body inspection of the ordinary peer view. *)
    RTSR.call_json ~base_url ~meth:`GET ~path:"/list" () >|= fun r ->
    (* Production: unsigned list must not disclose peers. *)
    Alcotest.(check bool) "prod unsigned /list not 200 with peers" true
      (RTSR.status_code r <> 200
       || not (List.mem "zzhttppriv" (peer_aliases_json (peers_from_list_json r.json)))))

let test_http_list_dev_mode_body_omits_private () =
  (* Body-shape check: tokenless bracket (dev) still must not list private
     once B264 filters are on — same ordinary list_peers path. *)
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk_priv = gen_pk () in
    let pk_pub = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-dp" ~session_id:"s-dp"
        ~alias:"zzdevpriv" ~identity_pk:pk_priv ()
    in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-du" ~session_id:"s-du"
        ~alias:"zzdevpub" ~identity_pk:pk_pub ()
    in
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzdevpriv"
         ~visibility:Private
     with
     | Ok () -> ()
     | Error e -> failwith e);
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzdevpub"
         ~visibility:Public
     with
     | Ok () -> ()
     | Error e -> failwith e);
    RTSR.call_json ~base_url ~meth:`GET ~path:"/list" () >|= fun r ->
    Alcotest.(check int) "dev /list 200" 200 (RTSR.status_code r);
    let aliases = peer_aliases_json (peers_from_list_json r.json) in
    Alcotest.(check bool) "dev /list omits private" false
      (List.mem "zzdevpriv" aliases);
    Alcotest.(check bool) "dev /list includes public" true
      (List.mem "zzdevpub" aliases);
    Alcotest.(check bool) "body has no private alias string" false
      (json_string_contains r.RTSR.body_text "zzdevpriv"))

let test_http_pubkey_private_matches_unknown () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-pk" ~session_id:"s-pk"
        ~alias:"zzpkpriv" ~identity_pk:pk ()
    in
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay ~alias:"zzpkpriv"
         ~visibility:Private
     with
     | Ok () -> ()
     | Error e -> failwith e);
    RTSR.call_json ~base_url ~meth:`GET ~path:"/pubkey/zzpkpriv" ()
    >>= fun r_priv ->
    RTSR.call_json ~base_url ~meth:`GET ~path:"/pubkey/zzpknobody" ()
    >|= fun r_unk ->
    Alcotest.(check int) "private pubkey status" 404 (RTSR.status_code r_priv);
    Alcotest.(check int) "unknown pubkey status" 404 (RTSR.status_code r_unk);
    (* Existence oracle: status must match; error_code must match. *)
    let code_of r =
      match r.RTSR.json with
      | Some (`Assoc f) ->
        (match List.assoc_opt "error_code" f with
         | Some (`String c) -> c
         | _ -> "")
      | _ -> ""
    in
    Alcotest.(check string) "error_code uniform" (code_of r_unk) (code_of r_priv);
    Alcotest.(check bool) "private body must not include ed25519_pubkey" false
      (json_string_contains r_priv.RTSR.body_text "ed25519_pubkey"))

let test_http_health_and_stats_no_private_alias () =
  RTSR.with_server (fun ~base_url ~relay ->
    let open Lwt.Infix in
    let pk = gen_pk () in
    let _ =
      Relay.InMemoryRelay.register relay ~node_id:"n-hs" ~session_id:"s-hs"
        ~alias:"zzhealthpriv" ~identity_pk:pk
        ~client_version:"0.99.0" ~client_os:"linux" ()
    in
    (match
       Relay.InMemoryRelay.set_peer_discovery_visibility relay
         ~alias:"zzhealthpriv" ~visibility:Private
     with
     | Ok () -> ()
     | Error e -> failwith e);
    let now = Unix.gettimeofday () in
    Relay.InMemoryRelay.stats_note_activity relay ~machine_id:"m-hs"
      ~alias:"zzhealthpriv" ~ts:now ();
    RTSR.call_json ~base_url ~meth:`GET ~path:"/health" () >>= fun h ->
    RTSR.call_json ~base_url ~meth:`GET ~path:"/stats" () >|= fun s ->
    Alcotest.(check int) "health 200" 200 (RTSR.status_code h);
    Alcotest.(check int) "stats 200" 200 (RTSR.status_code s);
    Alcotest.(check bool) "health has no private alias" false
      (json_string_contains h.RTSR.body_text "zzhealthpriv");
    Alcotest.(check bool) "stats has no private alias" false
      (json_string_contains s.RTSR.body_text "zzhealthpriv");
    (* Health must still expose auth_mode for diagnostics. *)
    Alcotest.(check bool) "health has auth_mode" true
      (json_string_contains h.RTSR.body_text "auth_mode"))

let () =
  Random.self_init ();
  Alcotest.run "relay_private_discovery"
    [
      ("InMemoryRelay", Mem_tests.cases);
      ("SqliteRelay", Sqlite_tests.cases);
      ( "HTTP oracles",
        [
          Alcotest.test_case "prod unsigned /list does not disclose private"
            `Quick test_http_list_omits_private;
          Alcotest.test_case "dev /list body omits private" `Quick
            test_http_list_dev_mode_body_omits_private;
          Alcotest.test_case "pubkey private matches unknown" `Quick
            test_http_pubkey_private_matches_unknown;
          Alcotest.test_case "health/stats omit private alias" `Quick
            test_http_health_and_stats_no_private_alias;
        ] );
    ]
