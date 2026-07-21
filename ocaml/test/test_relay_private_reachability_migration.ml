(* B266 — fail-closed private-reachability migration.

   Design: .collab/design/2026-07-22-b262-contact-grant-protocol.md §13–14
   Ticket: B266

   Proves:
   1. Fresh SQLite create stamps private_reachability + contact_protocol markers
      and creates contact_grants / discovery_visibility.
   2. Re-open (idempotent retry) keeps markers and private default.
   3. Legacy DB without discovery_visibility migrates fail-closed to private.
   4. New registration is private by default (ordinary list_peers omits).
   5. Interrupted-style re-create after partial legacy open still fails closed.
*)

open Alcotest
open Relay
open Relay_backend_contract

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

let with_dir f =
  let dir = tmp_dir "c2c-b266-mig" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let db_path dir = Filename.concat dir "c2c_relay.db"

let table_exists db name =
  let st =
    Sqlite3.prepare db
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize st))
    (fun () ->
      Sqlite3.bind_text st 1 name |> ignore;
      Sqlite3.step st = Sqlite3.Rc.ROW)

let column_exists db ~table ~column =
  let st = Sqlite3.prepare db (Printf.sprintf "PRAGMA table_info(%s)" table) in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize st))
    (fun () ->
      let found = ref false in
      let rec loop () =
        match Sqlite3.step st with
        | Sqlite3.Rc.ROW ->
          let name =
            match Sqlite3.Data.to_string (Sqlite3.column st 1) with
            | Some s -> s
            | None -> ""
          in
          if name = column then found := true;
          loop ()
        | _ -> ()
      in
      loop ();
      !found)

let feature_value db feature =
  let st =
    Sqlite3.prepare db
      "SELECT value FROM relay_features WHERE feature = ?"
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize st))
    (fun () ->
      Sqlite3.bind_text st 1 feature |> ignore;
      if Sqlite3.step st = Sqlite3.Rc.ROW then
        match Sqlite3.Data.to_string (Sqlite3.column st 0) with
        | Some s -> Some s
        | None -> None
      else None)

let gen_pk () =
  let id = Relay_identity.generate () in
  id.Relay_identity.public_key

let test_fresh_create_stamps_markers () =
  with_dir (fun dir ->
    let _t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let db = Sqlite3.db_open (db_path dir) in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        check bool "contact_grants exists" true (table_exists db "contact_grants");
        check bool "contact_grant_message_ids exists" true
          (table_exists db "contact_grant_message_ids");
        check bool "relay_features exists" true (table_exists db "relay_features");
        check bool "discovery_visibility column" true
          (column_exists db ~table:"leases" ~column:"discovery_visibility");
        check
          (option string)
          "private_reachability marker"
          (Some "consent_gated")
          (feature_value db "private_reachability");
        check
          (option string)
          "contact_protocol marker"
          (Some "1")
          (feature_value db "contact_protocol")))

let test_reopen_idempotent () =
  with_dir (fun dir ->
    let _t1 = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
    let db = Sqlite3.db_open (db_path dir) in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        check
          (option string)
          "marker survives reopen"
          (Some "consent_gated")
          (feature_value db "private_reachability");
        (* New registration still private by default. *)
        let t = Relay.SqliteRelay.create ~persist_dir:dir () in
        let pk = gen_pk () in
        let st, _ =
          Relay.SqliteRelay.register t ~node_id:"n1" ~session_id:"s1"
            ~alias:"zzmigpriv" ~identity_pk:pk ()
        in
        check string "register ok" "ok" st;
        (match Relay.SqliteRelay.peer_discovery_visibility_of t ~alias:"zzmigpriv" with
         | Some Private -> ()
         | Some Public -> Alcotest.fail "fresh registration must default Private"
         | None -> Alcotest.fail "visibility missing");
        let peers = Relay.SqliteRelay.list_peers t ~include_dead:false in
        check bool "ordinary list omits default-private" false
          (List.exists
             (fun l -> Relay.RegistrationLease.alias l = "zzmigpriv")
             peers)))

let test_legacy_db_migrates_private () =
  with_dir (fun dir ->
    (* Build a minimal pre-B264 leases table without discovery_visibility. *)
    let path = db_path dir in
    let db = Sqlite3.db_open path in
    let sql =
      {|
CREATE TABLE leases (
  alias TEXT PRIMARY KEY,
  node_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'unknown',
  registered_at REAL NOT NULL,
  last_seen REAL NOT NULL,
  ttl REAL NOT NULL,
  identity_pk TEXT NOT NULL DEFAULT '',
  enc_pubkey TEXT NOT NULL DEFAULT '',
  signed_at REAL NOT NULL DEFAULT 0,
  sig_b64 TEXT NOT NULL DEFAULT '',
  opaque_host_id TEXT NOT NULL DEFAULT '',
  client_version TEXT NOT NULL DEFAULT '',
  client_os TEXT NOT NULL DEFAULT ''
);
INSERT INTO leases (alias, node_id, session_id, registered_at, last_seen, ttl)
VALUES ('legacy-alice', 'n-leg', 's-leg', 1.0, 9999999999.0, 86400.0);
|}
    in
    let rc = Sqlite3.exec db sql in
    check bool "seed legacy db" true (Sqlite3.Rc.is_success rc);
    ignore (Sqlite3.db_close db);
    (* Open with modern binary — must migrate. *)
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let db2 = Sqlite3.db_open path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db2))
      (fun () ->
        check bool "migrated discovery_visibility" true
          (column_exists db2 ~table:"leases" ~column:"discovery_visibility");
        check bool "contact_grants after migrate" true
          (table_exists db2 "contact_grants");
        check
          (option string)
          "marker after migrate"
          (Some "consent_gated")
          (feature_value db2 "private_reachability"));
    (* Legacy lease must be private (default on ALTER). *)
    match
      Relay.SqliteRelay.peer_discovery_visibility_of t ~alias:"legacy-alice"
    with
    | Some Private -> ()
    | Some Public -> Alcotest.fail "legacy lease must migrate to Private"
    | None -> Alcotest.fail "legacy lease disappeared";
    let peers = Relay.SqliteRelay.list_peers t ~include_dead:false in
    check bool "legacy private omitted from ordinary list" false
      (List.exists
         (fun l -> Relay.RegistrationLease.alias l = "legacy-alice")
         peers);
    let admin = Relay.SqliteRelay.list_peers_admin t ~include_dead:true in
    check bool "admin still sees legacy" true
      (List.exists
         (fun l -> Relay.RegistrationLease.alias l = "legacy-alice")
         admin))

let test_repeated_migration_idempotent () =
  with_dir (fun dir ->
    let path = db_path dir in
    let seed () =
      let db = Sqlite3.db_open path in
      ignore
        (Sqlite3.exec db
           {|CREATE TABLE IF NOT EXISTS leases (
               alias TEXT PRIMARY KEY,
               node_id TEXT NOT NULL,
               session_id TEXT NOT NULL,
               client_type TEXT NOT NULL DEFAULT 'unknown',
               registered_at REAL NOT NULL,
               last_seen REAL NOT NULL,
               ttl REAL NOT NULL,
               identity_pk TEXT NOT NULL DEFAULT '',
               enc_pubkey TEXT NOT NULL DEFAULT '',
               signed_at REAL NOT NULL DEFAULT 0,
               sig_b64 TEXT NOT NULL DEFAULT '',
               opaque_host_id TEXT NOT NULL DEFAULT '',
               client_version TEXT NOT NULL DEFAULT '',
               client_os TEXT NOT NULL DEFAULT ''
             );|});
      ignore (Sqlite3.db_close db)
    in
    seed ();
    let _ = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ = Relay.SqliteRelay.create ~persist_dir:dir () in
    let db = Sqlite3.db_open path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        check
          (option string)
          "marker stable after 3 creates"
          (Some "consent_gated")
          (feature_value db "private_reachability");
        check bool "still has contact_grants" true
          (table_exists db "contact_grants")))

let () =
  Alcotest.run "relay_private_reachability_migration"
    [ ( "SqliteRelay",
        [ test_case "fresh create stamps markers + tables" `Quick
            test_fresh_create_stamps_markers;
          test_case "reopen idempotent + private default" `Quick
            test_reopen_idempotent;
          test_case "legacy DB migrates to private" `Quick
            test_legacy_db_migrates_private;
          test_case "repeated migration idempotent" `Quick
            test_repeated_migration_idempotent;
        ] );
    ]
