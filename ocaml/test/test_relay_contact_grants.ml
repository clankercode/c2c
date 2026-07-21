(* B262/B263: backend-contract tests for recipient-owned, sender-bound contact
   grants. Design freeze:
   .collab/design/2026-07-22-b262-contact-grant-protocol.md

   These tests pin the shared RELAY surface. Until B263 implements real grant
   storage and atomic admission they must FAIL (red). Do not "fix" by
   weakening assertions. *)

open Relay_backend_contract

let b64url s =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet s

let sha256_raw s =
  Digestif.SHA256.(to_raw_string (digest_string s))

let gen_pk () =
  let id = Relay_identity.generate () in
  id.Relay_identity.public_key

let random_bytes n =
  String.init n (fun _ -> Char.chr (Random.int 256))

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

let read_file_bytes path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
    really_input_string ic (in_channel_length ic))

let persisted_bytes dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter_map (fun name ->
       let path = Filename.concat dir name in
       if Sys.is_directory path then None else Some (read_file_bytes path))
  |> String.concat ""

let contains_literal ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let sqlite_count_where db_path sql bind =
  let db = Sqlite3.db_open db_path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
    let stmt = Sqlite3.prepare db sql in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
      bind stmt;
      if Sqlite3.step stmt = Sqlite3.Rc.ROW then
        match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
        | Some n -> n
        | None -> int_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
      else -1))

let sqlite_table_exists db_path table =
  sqlite_count_where db_path
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
    (fun stmt -> Sqlite3.bind_text stmt 1 table |> ignore)
  = 1

(* --- Functor over both backends ------------------------------------------ *)

module type BACKEND = sig
  include RELAY
  val name : string
  val fresh : unit -> t * (unit -> unit)
  (** [fresh] returns a backend and a cleanup function. *)
end

module In_mem : BACKEND = struct
  include Relay.InMemoryRelay
  let name = "InMemoryRelay"
  let fresh () =
    let dir = tmp_dir "c2c-contact-mem" in
    let t = create ~persist_dir:dir () in
    (t, fun () -> rm_rf dir)
end

module Sqlite : BACKEND = struct
  include Relay.SqliteRelay
  let name = "SqliteRelay"
  let fresh () =
    let dir = tmp_dir "c2c-contact-sqlite" in
    let t = create ~persist_dir:dir () in
    (t, fun () -> rm_rf dir)
end

module Make_tests (B : BACKEND) = struct
  let register_peer t ~alias ~pk =
    let node_id = "n-" ^ alias in
    let session_id = "s-" ^ alias in
    let status, _lease =
      B.register t ~node_id ~session_id ~alias ~identity_pk:pk ()
    in
    Alcotest.(check string) (B.name ^ " register " ^ alias) "ok" status;
    (node_id, session_id)

  let issue_ok t ~recipient_pk ~delivery_alias ~sender_pk ~expires_at ?label ?now () =
    match
      B.issue_contact_grant t ~recipient_identity_pk:recipient_pk
        ~delivery_alias ~sender_identity_pk:sender_pk ~expires_at ?label ?now ()
    with
    | Ok r -> r
    | Error e -> Alcotest.failf "%s issue_contact_grant failed: %s" B.name e

  (* ---- issuance -------------------------------------------------------- *)

  let test_issue_returns_32_byte_secret_and_grant_id () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let _ = register_peer t ~alias:"zzrecv" ~pk:recipient_pk in
      let now = Unix.gettimeofday () in
      let r =
        issue_ok t ~recipient_pk ~delivery_alias:"zzrecv" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      Alcotest.(check int) "secret length 32" 32 (String.length r.grant_secret);
      Alcotest.(check bool) "grant_id non-empty" true (String.length r.grant_id > 0);
      let expected_id = b64url (sha256_raw r.grant_secret) in
      Alcotest.(check string) "grant_id is b64url(SHA-256(secret))" expected_id
        r.grant_id;
      Alcotest.(check (float 1e-6)) "expires_at preserved" (now +. 3600.)
        r.expires_at)

  let test_issue_secret_not_in_list_meta () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let _ = register_peer t ~alias:"zzrecv2" ~pk:recipient_pk in
      let now = Unix.gettimeofday () in
      let r =
        issue_ok t ~recipient_pk ~delivery_alias:"zzrecv2" ~sender_pk
          ~expires_at:(now +. 3600.) ~label:"friend" ~now ()
      in
      let metas = B.list_contact_grants t ~recipient_identity_pk:recipient_pk in
      Alcotest.(check int) "one grant listed" 1 (List.length metas);
      let m = List.hd metas in
      Alcotest.(check string) "grant_id matches" r.grant_id m.grant_id;
      Alcotest.(check (option string)) "label preserved" (Some "friend") m.label;
      (* Redaction: list metadata must never contain the raw secret. *)
      let blob =
        String.concat "|"
          [ m.grant_id; m.sender_fp_prefix; m.delivery_alias;
            Option.value m.label ~default:"" ]
      in
      Alcotest.(check bool) "list meta does not contain raw secret" false
        (let secret = r.grant_secret in
         try
           let _ = Str.search_forward (Str.regexp_string secret) blob 0 in
           true
         with Not_found -> false);
      Alcotest.(check bool) "list meta does not contain b64 secret" false
        (let s = b64url r.grant_secret in
         try
           let _ = Str.search_forward (Str.regexp_string s) blob 0 in
           true
         with Not_found -> false))

  let test_issue_rejects_foreign_owner_for_delivery_alias () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let real_owner_pk = gen_pk () in
      let foreign_owner_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let _ = register_peer t ~alias:"zzowned" ~pk:real_owner_pk in
      let now = Unix.gettimeofday () in
      match
        B.issue_contact_grant t ~recipient_identity_pk:foreign_owner_pk
          ~delivery_alias:"zzowned" ~sender_identity_pk:sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      with
      | Error _ -> ()
      | Ok _ ->
        Alcotest.fail
          "foreign recipient identity must not issue a grant for another owner's alias")

  (* ---- admission happy path -------------------------------------------- *)

  let test_admit_happy_path_delivers_once () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      let mid = "msg-happy-1" in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom"
           ~verified_sender_identity_pk:sender_pk ~grant_secret:issued.grant_secret
           ~message_id:mid ~content:"hello-contact" ~now ()
       with
       | `Accepted _ -> ()
       | `Duplicate _ -> Alcotest.fail "first admit must be Accepted, not Duplicate"
       | `Rejected -> Alcotest.fail "first admit must be Accepted, not Rejected");
      let inbox = B.poll_inbox t ~node_id:rn ~session_id:rs in
      Alcotest.(check int) "one inbox message" 1 (List.length inbox);
      let content =
        match List.hd inbox with
        | `Assoc fields ->
          (match List.assoc_opt "content" fields with
           | Some (`String s) -> s
           | _ -> "")
        | _ -> ""
      in
      Alcotest.(check string) "content delivered" "hello-contact" content;
      (* No content-bearing dead letter on accept. *)
      Alcotest.(check int) "dead_letter empty after accept" 0
        (List.length (B.dead_letter t)))

  (* ---- sender / recipient scoping -------------------------------------- *)

  let test_admit_wrong_sender_rejected_no_side_effects () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let attacker_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-ws" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-ws" ~pk:sender_pk in
      let _ = register_peer t ~alias:"zzatt-ws" ~pk:attacker_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-ws" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzatt-ws"
           ~verified_sender_identity_pk:attacker_pk
           ~grant_secret:issued.grant_secret ~message_id:"m-wrong-sender"
           ~content:"evil" ~now ()
       with
       | `Rejected -> ()
       | `Accepted _ | `Duplicate _ ->
         Alcotest.fail "wrong sender must be Rejected");
      Alcotest.(check int) "inbox empty" 0
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs));
      Alcotest.(check int) "no content DLQ on reject" 0
        (List.length (B.dead_letter t)))

  let test_admit_unknown_or_malformed_secret_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-unk" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-unk" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let _ =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-unk" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      let junk = random_bytes 32 in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-unk"
           ~verified_sender_identity_pk:sender_pk ~grant_secret:junk
           ~message_id:"m-junk" ~content:"x" ~now ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "unknown secret must Reject");
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-unk"
           ~verified_sender_identity_pk:sender_pk ~grant_secret:"tooshort"
           ~message_id:"m-short" ~content:"x" ~now ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "malformed secret must Reject");
      Alcotest.(check int) "inbox empty" 0
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs));
      Alcotest.(check int) "no DLQ" 0 (List.length (B.dead_letter t)))

  (* ---- expiry / revocation / rotation ---------------------------------- *)

  let test_admit_expired_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-exp" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-exp" ~pk:sender_pk in
      let now = 1_000_000. in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-exp" ~sender_pk
          ~expires_at:(now +. 10.) ~now ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-exp"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:issued.grant_secret ~message_id:"m-exp"
           ~content:"late" ~now:(now +. 11.) ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "expired grant must Reject");
      Alcotest.(check int) "inbox empty" 0
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs)))

  let test_revoke_then_admit_rejected () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-rev" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-rev" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-rev" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      (match
         B.revoke_contact_grant t ~recipient_identity_pk:recipient_pk
           ~grant_id:issued.grant_id ~now ()
       with
       | Ok () -> ()
       | Error e -> Alcotest.failf "revoke failed: %s" e);
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-rev"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:issued.grant_secret ~message_id:"m-rev"
           ~content:"after-revoke" ~now:(now +. 1.) ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "revoked grant must Reject");
      Alcotest.(check int) "inbox empty" 0
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs)))

  let test_rotate_old_secret_rejected_new_accepted () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-rot" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-rot" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let old =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-rot" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      let neu =
        match
          B.rotate_contact_grant t ~recipient_identity_pk:recipient_pk
            ~grant_id:old.grant_id ~sender_identity_pk:sender_pk
            ~expires_at:(now +. 7200.) ~now:(now +. 1.) ()
        with
        | Ok r -> r
        | Error e -> Alcotest.failf "rotate failed: %s" e
      in
      Alcotest.(check bool) "rotate yields new secret" true
        (neu.grant_secret <> old.grant_secret);
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-rot"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:old.grant_secret ~message_id:"m-old"
           ~content:"old" ~now:(now +. 2.) ()
       with
       | `Rejected -> ()
       | _ -> Alcotest.fail "old secret after rotate must Reject");
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-rot"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:neu.grant_secret ~message_id:"m-new"
           ~content:"new" ~now:(now +. 2.) ()
       with
       | `Accepted _ -> ()
       | _ -> Alcotest.fail "new secret after rotate must Accept");
      Alcotest.(check int) "one delivered" 1
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs)))

  let test_rotate_one_grant_does_not_revoke_sibling () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_a_pk = gen_pk () in
      let sender_b_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-rot-sibling" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-rot-a" ~pk:sender_a_pk in
      let _ = register_peer t ~alias:"zzfrom-rot-b" ~pk:sender_b_pk in
      let now = Unix.gettimeofday () in
      let grant_a =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-rot-sibling"
          ~sender_pk:sender_a_pk ~expires_at:(now +. 3600.) ~now ()
      in
      let grant_b =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-rot-sibling"
          ~sender_pk:sender_b_pk ~expires_at:(now +. 3600.) ~now ()
      in
      let _rotated_a =
        match
          B.rotate_contact_grant t ~recipient_identity_pk:recipient_pk
            ~grant_id:grant_a.grant_id ~sender_identity_pk:sender_a_pk
            ~expires_at:(now +. 7200.) ~now:(now +. 1.) ()
        with
        | Ok r -> r
        | Error e -> Alcotest.failf "rotate sibling fixture failed: %s" e
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-rot-b"
           ~verified_sender_identity_pk:sender_b_pk
           ~grant_secret:grant_b.grant_secret ~message_id:"m-sibling"
           ~content:"sibling-still-valid" ~now:(now +. 2.) ()
       with
       | `Accepted _ -> ()
       | `Duplicate _ | `Rejected ->
         Alcotest.fail "rotating grant A must not revoke sibling grant B");
      Alcotest.(check int) "sibling delivered once" 1
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs)))

  (* ---- replay / idempotency -------------------------------------------- *)

  let test_duplicate_message_id_at_most_one_delivery () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-dup" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-dup" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-dup" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      let mid = "msg-dup-1" in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-dup"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:issued.grant_secret ~message_id:mid ~content:"once"
           ~now ()
       with
       | `Accepted _ -> ()
       | _ -> Alcotest.fail "first must Accept");
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-dup"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:issued.grant_secret ~message_id:mid ~content:"twice"
           ~now:(now +. 0.1) ()
       with
       | `Duplicate _ -> ()
       | `Accepted _ -> Alcotest.fail "second must Duplicate, not Accept"
       | `Rejected -> Alcotest.fail "second must Duplicate, not Reject");
      Alcotest.(check int) "exactly one inbox row" 1
        (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs)))

  (* ---- restart persistence (SQLite-meaningful; InMemory with persist_dir) *)

  let test_restart_preserves_grant_and_message_id () =
    match B.name with
    | "SqliteRelay" ->
      let dir = tmp_dir "c2c-contact-restart" in
      Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
        let recipient_pk = gen_pk () in
        let sender_pk = gen_pk () in
        let issued, mid =
          let t1 = B.create ~persist_dir:dir () in
          let _ = register_peer t1 ~alias:"zzto-rs" ~pk:recipient_pk in
          let _ = register_peer t1 ~alias:"zzfrom-rs" ~pk:sender_pk in
          let now = Unix.gettimeofday () in
          let issued =
            issue_ok t1 ~recipient_pk ~delivery_alias:"zzto-rs" ~sender_pk
              ~expires_at:(now +. 3600.) ~now ()
          in
          let mid = "msg-restart-1" in
          (match
             B.admit_contact_delivery t1 ~verified_sender_alias:"zzfrom-rs"
               ~verified_sender_identity_pk:sender_pk
               ~grant_secret:issued.grant_secret ~message_id:mid
               ~content:"persist-me" ~now ()
           with
           | `Accepted _ -> ()
           | _ -> Alcotest.fail "pre-restart admit must Accept");
          (issued, mid)
        in
        (* New process-like open of the same DB. *)
        let t2 = B.create ~persist_dir:dir () in
        let _ = register_peer t2 ~alias:"zzto-rs" ~pk:recipient_pk in
        let _ = register_peer t2 ~alias:"zzfrom-rs" ~pk:sender_pk in
        let now = Unix.gettimeofday () in
        (match
           B.admit_contact_delivery t2 ~verified_sender_alias:"zzfrom-rs"
             ~verified_sender_identity_pk:sender_pk
             ~grant_secret:issued.grant_secret ~message_id:mid
             ~content:"again" ~now ()
         with
         | `Duplicate _ -> ()
         | `Accepted _ -> Alcotest.fail "post-restart same message_id must Duplicate"
         | `Rejected ->
           Alcotest.fail "post-restart grant must still exist (not Reject)"))
    | _ ->
      (* In-memory process restart is not durable by design; skip-as-pass only
         if list is empty after a fresh create — assert the API exists. *)
      let t, cleanup = B.fresh () in
      Fun.protect ~finally:cleanup (fun () ->
        Alcotest.(check int) "fresh in-memory has no grants" 0
          (List.length (B.list_contact_grants t ~recipient_identity_pk:"x")))

  let test_sqlite_fresh_schema_has_all_grant_tables () =
    match B.name with
    | "SqliteRelay" ->
      let dir = tmp_dir "c2c-contact-schema" in
      Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
        let _t = B.create ~persist_dir:dir () in
        let db_path = Filename.concat dir "c2c_relay.db" in
        List.iter
          (fun table ->
            Alcotest.(check bool) ("fresh schema has " ^ table) true
              (sqlite_table_exists db_path table))
          [ "contact_grants"; "contact_grant_generations";
            "contact_grant_message_ids" ])
    | _ -> ()

  let test_sqlite_never_persists_raw_grant_secret () =
    match B.name with
    | "SqliteRelay" ->
      let dir = tmp_dir "c2c-contact-secret-at-rest" in
      Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
        let recipient_pk = gen_pk () in
        let sender_pk = gen_pk () in
        let t1 = B.create ~persist_dir:dir () in
        let _ = register_peer t1 ~alias:"zzto-secret" ~pk:recipient_pk in
        let _ = register_peer t1 ~alias:"zzfrom-secret" ~pk:sender_pk in
        let now = Unix.gettimeofday () in
        let first =
          issue_ok t1 ~recipient_pk ~delivery_alias:"zzto-secret" ~sender_pk
            ~expires_at:(now +. 3600.) ~now ()
        in
        let secrets = ref [first.grant_secret] in
        let assert_redacted stage verifier =
          let bytes = persisted_bytes dir in
          Alcotest.(check bool) (stage ^ ": persisted verifier proves DB inspected")
            true (contains_literal ~needle:verifier bytes);
          List.iter (fun secret ->
            Alcotest.(check bool) (stage ^ ": no raw secret") false
              (contains_literal ~needle:secret bytes);
            Alcotest.(check bool) (stage ^ ": no base64url secret") false
              (contains_literal ~needle:(b64url secret) bytes)) !secrets
        in
        assert_redacted "issue" (sha256_raw first.grant_secret);
        (match
           B.admit_contact_delivery t1 ~verified_sender_alias:"zzfrom-secret"
             ~verified_sender_identity_pk:sender_pk
             ~grant_secret:first.grant_secret ~message_id:"m-secret"
             ~content:"persisted-content-not-secret" ~now ()
         with
         | `Accepted _ -> ()
         | _ -> Alcotest.fail "secret-at-rest fixture admit must accept");
        assert_redacted "admit" (sha256_raw first.grant_secret);
        let t2 = B.create ~persist_dir:dir () in
        (match
           B.admit_contact_delivery t2 ~verified_sender_alias:"zzfrom-secret"
             ~verified_sender_identity_pk:sender_pk
             ~grant_secret:first.grant_secret ~message_id:"m-secret"
             ~content:"duplicate" ~now:(now +. 1.) ()
         with
         | `Duplicate _ -> ()
         | _ -> Alcotest.fail "restart must preserve idempotency fixture");
        assert_redacted "restart" (sha256_raw first.grant_secret);
        let rotated =
          match
            B.rotate_contact_grant t2 ~recipient_identity_pk:recipient_pk
              ~grant_id:first.grant_id ~sender_identity_pk:sender_pk
              ~expires_at:(now +. 7200.) ~now:(now +. 2.) ()
          with
          | Ok r -> r
          | Error e -> Alcotest.failf "secret-at-rest rotate failed: %s" e
        in
        secrets := rotated.grant_secret :: !secrets;
        assert_redacted "rotate" (sha256_raw rotated.grant_secret);
        (match
           B.revoke_contact_grant t2 ~recipient_identity_pk:recipient_pk
             ~grant_id:rotated.grant_id ~now:(now +. 3.) ()
         with
         | Ok () -> ()
         | Error e -> Alcotest.failf "secret-at-rest revoke failed: %s" e);
        assert_redacted "revoke" (sha256_raw rotated.grant_secret))
    | _ -> ()

  let test_gc_retention_and_generation_monotonic () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-gc" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-gc" ~pk:sender_pk in
      let wall_now = Unix.gettimeofday () in
      let ancient = 1_000. in
      let stale =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-gc" ~sender_pk
          ~expires_at:(ancient +. 10.) ~now:ancient ()
      in
      (match
         B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-gc"
           ~verified_sender_identity_pk:sender_pk
           ~grant_secret:stale.grant_secret ~message_id:"m-gc-stale"
           ~content:"old" ~now:(ancient +. 1.) ()
       with
       | `Accepted _ -> ()
       | _ -> Alcotest.fail "stale GC fixture must first accept");
      ignore (B.poll_inbox t ~node_id:rn ~session_id:rs);
      let recently_revoked =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-gc" ~sender_pk
          ~expires_at:(ancient +. 20.) ~now:ancient ()
      in
      (match
         B.revoke_contact_grant t ~recipient_identity_pk:recipient_pk
           ~grant_id:recently_revoked.grant_id ~now:(wall_now -. 60.) ()
       with
       | Ok () -> ()
       | Error e -> Alcotest.failf "recent revoke fixture failed: %s" e);
      let active =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-gc" ~sender_pk
          ~expires_at:(wall_now +. 3600.) ~now:wall_now ()
      in
      ignore (B.gc t);
      let listed = B.list_contact_grants t ~recipient_identity_pk:recipient_pk in
      Alcotest.(check bool) "stale expired grant removed" false
        (List.exists (fun m -> m.grant_id = stale.grant_id) listed);
      Alcotest.(check bool) "recently revoked grant retained for replay window" true
        (List.exists (fun m -> m.grant_id = recently_revoked.grant_id) listed);
      Alcotest.(check bool) "active grant retained" true
        (List.exists (fun m -> m.grant_id = active.grant_id) listed);
      let after_gc =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-gc" ~sender_pk
          ~expires_at:(wall_now +. 7200.) ~now:(wall_now +. 1.) ()
      in
      Alcotest.(check bool) "generation remains monotonic across GC" true
        (after_gc.generation > active.generation))

  let test_sqlite_malformed_persisted_grant_fails_closed () =
    match B.name with
    | "SqliteRelay" ->
      let dir = tmp_dir "c2c-contact-malformed" in
      Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
        let recipient_pk = gen_pk () in
        let sender_pk = gen_pk () in
        let (rn, rs) =
          let t = B.create ~persist_dir:dir () in
          register_peer t ~alias:"zzto-malformed" ~pk:recipient_pk
        in
        let t = B.create ~persist_dir:dir () in
        let _ = register_peer t ~alias:"zzfrom-malformed" ~pk:sender_pk in
        let secret = random_bytes 32 in
        let verifier = sha256_raw secret in
        let db = Sqlite3.db_open (Filename.concat dir "c2c_relay.db") in
        Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () ->
          let stmt = Sqlite3.prepare db
            "INSERT INTO contact_grants
               (verifier, recipient_identity_fp, delivery_alias, sender_fp,
                scope, generation, created_at, expires_at, revoked_at, label)
             VALUES (?, ?, ?, ?, 'invalid-scope', 1, ?, ?, NULL, NULL)"
          in
          Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
            Sqlite3.bind_blob stmt 1 verifier |> ignore;
            Sqlite3.bind_blob stmt 2 (sha256_raw recipient_pk) |> ignore;
            Sqlite3.bind_text stmt 3 "zzto-malformed" |> ignore;
            Sqlite3.bind_blob stmt 4 (sha256_raw sender_pk) |> ignore;
            Sqlite3.bind_double stmt 5 (Unix.gettimeofday ()) |> ignore;
            Sqlite3.bind_double stmt 6 (Unix.gettimeofday () +. 3600.) |> ignore;
            Alcotest.(check bool) "malformed row inserted" true
              (Sqlite3.step stmt = Sqlite3.Rc.DONE)));
        (match
           B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-malformed"
             ~verified_sender_identity_pk:sender_pk ~grant_secret:secret
             ~message_id:"m-malformed-row" ~content:"must-not-deliver" ()
         with
         | `Rejected -> ()
         | `Accepted _ | `Duplicate _ ->
           Alcotest.fail "malformed persisted grant must fail closed");
        Alcotest.(check int) "malformed row creates no inbox side effect" 0
          (List.length (B.poll_inbox t ~node_id:rn ~session_id:rs));
        Alcotest.(check int) "malformed row creates no dead letter" 0
          (List.length (B.dead_letter t)))
    | _ -> ()

  (* ---- concurrency: revoke vs admit under lock ------------------------- *)

  let test_concurrent_revoke_and_admit_linearised () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let (rn, rs) = register_peer t ~alias:"zzto-c" ~pk:recipient_pk in
      let _ = register_peer t ~alias:"zzfrom-c" ~pk:sender_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-c" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      let accept_count = Atomic.make 0 in
      let reject_count = Atomic.make 0 in
      let barrier = Atomic.make 0 in
      let thr_admit =
        Thread.create
          (fun () ->
            Atomic.incr barrier;
            while Atomic.get barrier < 2 do Thread.yield () done;
            match
              B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-c"
                ~verified_sender_identity_pk:sender_pk
                ~grant_secret:issued.grant_secret ~message_id:"m-race"
                ~content:"race" ~now ()
            with
            | `Accepted _ -> Atomic.incr accept_count
            | `Duplicate _ -> Atomic.incr accept_count
            | `Rejected -> Atomic.incr reject_count)
          ()
      in
      let thr_revoke =
        Thread.create
          (fun () ->
            Atomic.incr barrier;
            while Atomic.get barrier < 2 do Thread.yield () done;
            ignore
              (B.revoke_contact_grant t ~recipient_identity_pk:recipient_pk
                 ~grant_id:issued.grant_id ~now ()))
          ()
      in
      Thread.join thr_admit;
      Thread.join thr_revoke;
      let a = Atomic.get accept_count in
      let r = Atomic.get reject_count in
      Alcotest.(check bool) "exactly one of accept/reject" true
        ((a = 1 && r = 0) || (a = 0 && r = 1));
      let n = List.length (B.poll_inbox t ~node_id:rn ~session_id:rs) in
      Alcotest.(check bool) "inbox rows match accept count" true (n = a))

  (* ---- owner scoping: foreign revoke fails ----------------------------- *)

  let test_foreign_owner_cannot_revoke () =
    let t, cleanup = B.fresh () in
    Fun.protect ~finally:cleanup (fun () ->
      let recipient_pk = gen_pk () in
      let other_pk = gen_pk () in
      let sender_pk = gen_pk () in
      let _ = register_peer t ~alias:"zzto-fo" ~pk:recipient_pk in
      let now = Unix.gettimeofday () in
      let issued =
        issue_ok t ~recipient_pk ~delivery_alias:"zzto-fo" ~sender_pk
          ~expires_at:(now +. 3600.) ~now ()
      in
      (match
         B.revoke_contact_grant t ~recipient_identity_pk:other_pk
           ~grant_id:issued.grant_id ~now ()
       with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "foreign owner must not revoke");
      (* Grant still usable by real sender. *)
      let _ = register_peer t ~alias:"zzfrom-fo" ~pk:sender_pk in
      match
        B.admit_contact_delivery t ~verified_sender_alias:"zzfrom-fo"
          ~verified_sender_identity_pk:sender_pk
          ~grant_secret:issued.grant_secret ~message_id:"m-fo"
          ~content:"still-ok" ~now ()
      with
      | `Accepted _ -> ()
      | _ -> Alcotest.fail "grant must still work after failed foreign revoke")

  let cases =
    [ ("issue returns 32-byte secret + grant_id",
       `Quick, test_issue_returns_32_byte_secret_and_grant_id);
      ("issue secret redacted from list meta",
       `Quick, test_issue_secret_not_in_list_meta);
      ("issue rejects foreign owner for delivery alias",
       `Quick, test_issue_rejects_foreign_owner_for_delivery_alias);
      ("admit happy path delivers once",
       `Quick, test_admit_happy_path_delivers_once);
      ("admit wrong sender rejected, no side effects",
       `Quick, test_admit_wrong_sender_rejected_no_side_effects);
      ("admit unknown/malformed secret rejected",
       `Quick, test_admit_unknown_or_malformed_secret_rejected);
      ("admit expired rejected",
       `Quick, test_admit_expired_rejected);
      ("revoke then admit rejected",
       `Quick, test_revoke_then_admit_rejected);
      ("rotate: old rejected, new accepted",
       `Quick, test_rotate_old_secret_rejected_new_accepted);
      ("rotate one grant preserves sibling grant",
       `Quick, test_rotate_one_grant_does_not_revoke_sibling);
      ("duplicate message_id at most one delivery",
       `Quick, test_duplicate_message_id_at_most_one_delivery);
      ("restart preserves grant + message_id (sqlite)",
       `Quick, test_restart_preserves_grant_and_message_id);
      ("sqlite fresh schema has all grant tables",
       `Quick, test_sqlite_fresh_schema_has_all_grant_tables);
      ("sqlite never persists raw grant secret",
       `Quick, test_sqlite_never_persists_raw_grant_secret);
      ("gc retention + generation monotonic",
       `Quick, test_gc_retention_and_generation_monotonic);
      ("sqlite malformed persisted grant fails closed",
       `Quick, test_sqlite_malformed_persisted_grant_fails_closed);
      ("concurrent revoke vs admit linearised",
       `Quick, test_concurrent_revoke_and_admit_linearised);
      ("foreign owner cannot revoke",
       `Quick, test_foreign_owner_cannot_revoke);
    ]
end

module Mem_tests = Make_tests (In_mem)
module Sqlite_tests = Make_tests (Sqlite)

let () =
  Random.self_init ();
  Alcotest.run "relay_contact_grants"
    [ ("InMemoryRelay", Mem_tests.cases);
      ("SqliteRelay", Sqlite_tests.cases);
    ]
