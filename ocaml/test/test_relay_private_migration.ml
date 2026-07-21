(* B266 — fail-closed migration / feature markers for private reachability.

   Covers:
   - Fresh SqliteRelay creates discovery_visibility default private + feature markers
   - Legacy DB without discovery_visibility migrates fail-closed (ALTER default private)
   - Migration is idempotent across reopen
   - contact_grants presence is required after open
   - Interrupted migration retry (re-open after partial legacy schema)
   - Health advertises contact_protocol + private_reachability

   Design: B262 §13, B261 migration constraints, B266 todo. *)

open Alcotest
open Relay
open Relay_backend_contract

module RTSR = Relay_test_support_real

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

let exec_ok db sql =
  let rc = Sqlite3.exec db sql in
  if not (Sqlite3.Rc.is_success rc) then
    failwith ("sqlite exec: " ^ Sqlite3.Rc.to_string rc ^ " sql=" ^ sql)

let column_exists db ~table ~column =
  let st =
    Sqlite3.prepare db (Printf.sprintf "PRAGMA table_info(%s)" table)
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize st))
    (fun () ->
      let found = ref false in
      let rec loop () =
        match Sqlite3.step st with
        | Sqlite3.Rc.ROW ->
          let name = Sqlite3.Data.to_string_exn (Sqlite3.column st 1) in
          if name = column then found := true;
          loop ()
        | _ -> ()
      in
      loop ();
      !found)

let feature_value db feature =
  let st =
    Sqlite3.prepare db "SELECT value FROM relay_features WHERE feature = ?"
  in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize st))
    (fun () ->
      Sqlite3.bind_text st 1 feature |> ignore;
      if Sqlite3.step st = Sqlite3.Rc.ROW then
        Some (Sqlite3.Data.to_string_exn (Sqlite3.column st 0))
      else None)

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

(* Minimal pre-B264 schema: leases without discovery_visibility, no grants. *)
let create_legacy_db path =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
      exec_ok db
        {|CREATE TABLE leases (
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
          )|};
      exec_ok db
        {|INSERT INTO leases
            (alias, node_id, session_id, client_type, registered_at, last_seen, ttl)
          VALUES ('legacy-alice', 'n1', 's1', 'claude', 1.0, 9999999999.0, 86400.0)|};
      (* Rooms table stub so later room migrations don't fail hard if touched. *)
      exec_ok db
        {|CREATE TABLE IF NOT EXISTS rooms (
            room_id TEXT PRIMARY KEY,
            visibility TEXT NOT NULL DEFAULT 'public'
          )|};
      exec_ok db
        {|CREATE TABLE IF NOT EXISTS inboxes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            from_alias TEXT NOT NULL,
            to_alias TEXT NOT NULL,
            content TEXT NOT NULL,
            ts REAL NOT NULL
          )|})

let test_fresh_sqlite_markers_and_private_default () =
  with_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let _ =
      Relay.SqliteRelay.register t ~node_id:"n" ~session_id:"s" ~alias:"zzfresh"
        ~identity_pk:(String.make 32 'A') ()
    in
    (match
       Relay.SqliteRelay.peer_discovery_visibility_of t ~alias:"zzfresh"
     with
     | Some Private -> ()
     | Some Public -> Alcotest.fail "fresh register must default Private"
     | None -> Alcotest.fail "lease missing");
    let ordinary = Relay.SqliteRelay.list_peers t ~include_dead:false in
    check bool "private not listed" false
      (List.exists
         (fun l -> RegistrationLease.alias l = "zzfresh")
         ordinary);
    let db = Sqlite3.db_open (db_path dir) in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        check bool "discovery_visibility column" true
          (column_exists db ~table:"secure_leases_v2" ~column:"discovery_visibility");
        check bool "relay_features table" true (table_exists db "relay_features");
        check bool "contact_grants table" true (table_exists db "contact_grants");
        check (option string) "private_reachability marker" (Some "consent_gated")
          (feature_value db "private_reachability");
        check (option string) "contact_protocol marker" (Some "1")
          (feature_value db "contact_protocol")))

let test_legacy_migration_defaults_private_idempotent () =
  with_dir (fun dir ->
    create_legacy_db (db_path dir);
    (* First open migrates. *)
    let t1 = Relay.SqliteRelay.create ~persist_dir:dir () in
    (match
       Relay.SqliteRelay.peer_discovery_visibility_of t1 ~alias:"legacy-alice"
     with
     | Some Private -> ()
     | Some Public -> Alcotest.fail "migrated lease must be Private"
     | None -> Alcotest.fail "legacy lease missing after migrate");
    check bool "legacy private omitted from ordinary list" false
      (List.exists
         (fun l -> RegistrationLease.alias l = "legacy-alice")
         (Relay.SqliteRelay.list_peers t1 ~include_dead:false));
    (* Re-open: idempotent. *)
    let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
    (match
       Relay.SqliteRelay.peer_discovery_visibility_of t2 ~alias:"legacy-alice"
     with
     | Some Private -> ()
     | _ -> Alcotest.fail "visibility unstable after reopen");
    let db = Sqlite3.db_open (db_path dir) in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        check (option string) "marker after retry" (Some "consent_gated")
          (feature_value db "private_reachability");
        (* Explicit public opt-in still works post-migration. *)
        ());
    (match
       Relay.SqliteRelay.set_peer_discovery_visibility t2 ~alias:"legacy-alice"
         ~visibility:Public
     with
     | Ok () -> ()
     | Error e -> Alcotest.failf "set public: %s" e);
    check bool "public listed after opt-in" true
      (List.exists
         (fun l -> RegistrationLease.alias l = "legacy-alice")
         (Relay.SqliteRelay.list_peers t2 ~include_dead:false)))

let test_interrupted_retry_adds_missing_column () =
  with_dir (fun dir ->
    (* Simulate interrupted pre-migration DB: leases without discovery column,
       but contact_grants already present from partial DDL apply. *)
    let path = db_path dir in
    let db = Sqlite3.db_open path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db))
      (fun () ->
        exec_ok db
          {|CREATE TABLE leases (
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
            )|};
        exec_ok db
          {|INSERT INTO leases
              (alias, node_id, session_id, registered_at, last_seen, ttl)
            VALUES ('partial', 'n', 's', 1.0, 9999999999.0, 86400.0)|};
        exec_ok db
          {|CREATE TABLE contact_grants (
              verifier BLOB PRIMARY KEY,
              recipient_identity_fp BLOB NOT NULL,
              delivery_alias TEXT NOT NULL,
              sender_fp BLOB NOT NULL,
              scope TEXT NOT NULL,
              generation INTEGER NOT NULL,
              created_at REAL NOT NULL,
              expires_at REAL NOT NULL,
              revoked_at REAL,
              label TEXT
            )|};
        exec_ok db
          {|CREATE TABLE IF NOT EXISTS rooms (
              room_id TEXT PRIMARY KEY,
              visibility TEXT NOT NULL DEFAULT 'public'
            )|};
        exec_ok db
          {|CREATE TABLE IF NOT EXISTS inboxes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              node_id TEXT NOT NULL,
              session_id TEXT NOT NULL,
              message_id TEXT NOT NULL,
              from_alias TEXT NOT NULL,
              to_alias TEXT NOT NULL,
              content TEXT NOT NULL,
              ts REAL NOT NULL
            )|});
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    (match Relay.SqliteRelay.peer_discovery_visibility_of t ~alias:"partial" with
     | Some Private -> ()
     | _ -> Alcotest.fail "partial migration must end Private");
    let db2 = Sqlite3.db_open path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close db2))
      (fun () ->
        check bool "column added on retry" true
          (column_exists db2 ~table:"secure_leases_v2" ~column:"discovery_visibility");
        check (option string) "markers after partial recovery"
          (Some "consent_gated")
          (feature_value db2 "private_reachability")))

let test_health_advertises_contact_and_private_reachability () =
  RTSR.with_server ~token:"b266-mig-token" (fun ~base_url ~relay:_ ->
    let open Lwt.Infix in
    RTSR.call_json ~base_url ~meth:`GET ~path:"/health" () >|= fun r ->
    check int "health 200" 200 (RTSR.status_code r);
    match r.json with
    | Some (`Assoc f) ->
      check bool "auth_mode prod" true
        (List.assoc_opt "auth_mode" f = Some (`String "prod"));
      check bool "contact_protocol 1" true
        (List.assoc_opt "contact_protocol" f = Some (`Int 1));
      (* RTSR uses InMemoryRelay: durable claim is process_local, not consent_gated. *)
      check bool "private_reachability process_local (in-memory)" true
        (List.assoc_opt "private_reachability" f
         = Some (`String "process_local"))
    | _ -> Alcotest.fail "health not object")

let test_health_dev_mode_still_advertises_but_doctor_fails () =
  (* Tokenless health still advertises protocol fields; doctor Fail is on
     auth_mode=dev, not on missing ads. *)
  RTSR.with_server (fun ~base_url ~relay:_ ->
    let open Lwt.Infix in
    RTSR.call_json ~base_url ~meth:`GET ~path:"/health" () >|= fun r ->
    check int "health 200" 200 (RTSR.status_code r);
    match r.json with
    | Some (`Assoc f) ->
      check bool "auth_mode dev" true
        (List.assoc_opt "auth_mode" f = Some (`String "dev"));
      check bool "still has contact_protocol" true
        (List.assoc_opt "contact_protocol" f = Some (`Int 1))
    | _ -> Alcotest.fail "health not object")

let () =
  Random.self_init ();
  Alcotest.run "relay_private_migration"
    [ ( "sqlite migration",
        [ test_case "fresh markers + private default" `Quick
            test_fresh_sqlite_markers_and_private_default;
          test_case "legacy ALTER defaults private, idempotent" `Quick
            test_legacy_migration_defaults_private_idempotent;
          test_case "interrupted retry recovers column + markers" `Quick
            test_interrupted_retry_adds_missing_column;
        ] );
      ( "health ads",
        [ test_case "prod health contact + private_reachability (in-memory)" `Quick
            test_health_advertises_contact_and_private_reachability;
          test_case "dev health still ads protocol" `Quick
            test_health_dev_mode_still_advertises_but_doctor_fails;
        ] );
    ]
