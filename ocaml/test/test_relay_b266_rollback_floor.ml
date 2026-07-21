(* B266: enforceable old-binary rollback floor.

   A secure open atomically renames the durable registration table to
   [secure_leases_v2] and leaves an empty [leases] compatibility view. A
   pre-B266 binary therefore cannot rediscover recipients or write new global
   registrations. Fault injection proves the rename/view migration rolls back
   completely and retry is idempotent. *)

open Alcotest

let tmp_dir prefix =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path

let rm_rf path = ignore (Sys.command ("rm -rf " ^ Filename.quote path))
let db_path dir = Filename.concat dir "c2c_relay.db"

let exec_ok db sql =
  let rc = Sqlite3.exec db sql in
  if not (Sqlite3.Rc.is_success rc) then
    failf "SQL failed (%s): %s" (Sqlite3.Rc.to_string rc) sql

let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db)) (fun () -> f db)

let object_type db name =
  let stmt = Sqlite3.prepare db
      "SELECT type FROM sqlite_master WHERE name = ? LIMIT 1" in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    Sqlite3.bind_text stmt 1 name |> ignore;
    if Sqlite3.step stmt = Sqlite3.Rc.ROW then
      Some (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0))
    else None)

let count_rows db table =
  let stmt = Sqlite3.prepare db ("SELECT COUNT(*) FROM " ^ table) in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
    if Sqlite3.step stmt <> Sqlite3.Rc.ROW then fail "count did not return row";
    match Sqlite3.Data.to_int (Sqlite3.column stmt 0) with
    | Some n -> n
    | None -> fail "count was not integer")

let create_legacy_db dir =
  with_db (db_path dir) (fun db ->
    exec_ok db
      "CREATE TABLE leases (
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
         sig_b64 TEXT NOT NULL DEFAULT '')";
    let now = Unix.gettimeofday () in
    exec_ok db
      (Printf.sprintf
         "INSERT INTO leases
            (alias,node_id,session_id,registered_at,last_seen,ttl,identity_pk)
          VALUES ('legacy-recipient','legacy-node','legacy-session',%.6f,%.6f,3600,'pk')"
         now now))

let with_legacy_db prefix f =
  let dir = tmp_dir prefix in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    create_legacy_db dir;
    f dir)

let test_new_binary_preserves_migrated_registration () =
  with_legacy_db "c2c-b266-floor-preserve" (fun dir ->
    let relay = Relay.SqliteRelay.create ~persist_dir:dir () in
    let peers = Relay.SqliteRelay.list_peers_admin relay ~include_dead:true in
    check bool "new binary sees migrated recipient" true
      (List.exists
         (fun lease ->
           Relay.RegistrationLease.alias lease = "legacy-recipient")
         peers);
    with_db (db_path dir) (fun db ->
      check (option string) "secure table exists" (Some "table")
        (object_type db "secure_leases_v2");
      check (option string) "legacy name is view" (Some "view")
        (object_type db "leases");
      check int "secure row preserved" 1 (count_rows db "secure_leases_v2")))

let test_old_binary_reads_empty_and_cannot_write () =
  with_legacy_db "c2c-b266-floor-old" (fun dir ->
    ignore (Relay.SqliteRelay.create ~persist_dir:dir ());
    with_db (db_path dir) (fun db ->
      check int "old SELECT sees no recipients" 0 (count_rows db "leases");
      let insert_rc =
        Sqlite3.exec db
          "INSERT INTO leases
             (alias,node_id,session_id,client_type,registered_at,last_seen,ttl,
              identity_pk,enc_pubkey,signed_at,sig_b64,opaque_host_id,
              client_version,client_os,discovery_visibility)
           VALUES ('rollback-attacker','n','s','old',1,1,3600,'','','', '', '', '', '', 'public')"
      in
      check bool "old INSERT into compatibility view fails" true
        (not (Sqlite3.Rc.is_success insert_rc));
      check int "secure table unchanged after old write" 1
        (count_rows db "secure_leases_v2")))

let with_env name value f =
  let previous = Sys.getenv_opt name in
  let restore () =
    match previous with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Unix.putenv name value;
  Fun.protect ~finally:restore f

let test_interrupted_rename_rolls_back () =
  with_legacy_db "c2c-b266-floor-interrupt" (fun dir ->
    let failed =
      with_env "C2C_RELAY_MIGRATION_FAULT_FIXTURE" "after-lease-rename"
        (fun () ->
          try
            ignore (Relay.SqliteRelay.create ~persist_dir:dir ());
            false
          with Failure msg ->
            String.starts_with ~prefix:"B266 fixture:" msg)
    in
    check bool "fault injection reached migration" true failed;
    with_db (db_path dir) (fun db ->
      check (option string) "legacy table restored" (Some "table")
        (object_type db "leases");
      check (option string) "secure rename rolled back" None
        (object_type db "secure_leases_v2");
      check int "legacy row survived rollback" 1 (count_rows db "leases")))

let test_retry_and_reopen_are_idempotent () =
  with_legacy_db "c2c-b266-floor-retry" (fun dir ->
    ignore
      (with_env "C2C_RELAY_MIGRATION_FAULT_FIXTURE" "after-lease-rename"
         (fun () ->
           try ignore (Relay.SqliteRelay.create ~persist_dir:dir ())
           with Failure _ -> ()));
    let first = Relay.SqliteRelay.create ~persist_dir:dir () in
    let second = Relay.SqliteRelay.create ~persist_dir:dir () in
    check int "first secure open sees one row" 1
      (List.length
         (Relay.SqliteRelay.list_peers_admin first ~include_dead:true));
    check int "second secure open sees one row" 1
      (List.length
         (Relay.SqliteRelay.list_peers_admin second ~include_dead:true));
    with_db (db_path dir) (fun db ->
      check (option string) "legacy view remains" (Some "view")
        (object_type db "leases");
      check int "no duplicate migration rows" 1
        (count_rows db "secure_leases_v2")))

let create_split_brain_db dir legacy_object =
  with_db (db_path dir) (fun db ->
    exec_ok db
      "CREATE TABLE secure_leases_v2 (
         alias TEXT PRIMARY KEY, node_id TEXT NOT NULL,
         session_id TEXT NOT NULL, client_type TEXT NOT NULL DEFAULT 'unknown',
         registered_at REAL NOT NULL, last_seen REAL NOT NULL,
         ttl REAL NOT NULL, identity_pk TEXT NOT NULL DEFAULT '',
         enc_pubkey TEXT NOT NULL DEFAULT '', signed_at REAL NOT NULL DEFAULT 0,
         sig_b64 TEXT NOT NULL DEFAULT '', opaque_host_id TEXT NOT NULL DEFAULT '',
         client_version TEXT NOT NULL DEFAULT '', client_os TEXT NOT NULL DEFAULT '',
         discovery_visibility TEXT NOT NULL DEFAULT 'private')";
    match legacy_object with
    | `Missing -> ()
    | `Table ->
      exec_ok db
        "CREATE TABLE leases (alias TEXT PRIMARY KEY, node_id TEXT)"
    | `Triggered_view ->
      exec_ok db
        "CREATE VIEW leases AS
           SELECT alias,node_id,session_id,client_type,registered_at,last_seen,
                  ttl,identity_pk,enc_pubkey,signed_at,sig_b64,opaque_host_id,
                  client_version,client_os,discovery_visibility
             FROM secure_leases_v2 WHERE 0";
      exec_ok db
        "CREATE TRIGGER legacy_lease_write INSTEAD OF INSERT ON leases
         BEGIN
           INSERT INTO secure_leases_v2
             (alias,node_id,session_id,registered_at,last_seen,ttl)
           VALUES (NEW.alias,NEW.node_id,NEW.session_id,0,0,3600);
         END")

let secure_open_fails dir =
  try ignore (Relay.SqliteRelay.create ~persist_dir:dir ()); false
  with Failure _ | Sqlite3.Error _ -> true

let test_secure_plus_legacy_table_refused () =
  let dir = tmp_dir "c2c-b266-floor-split-table" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    create_split_brain_db dir `Table;
    check bool "secure + writable legacy table refused" true
      (secure_open_fails dir))

let test_secure_plus_missing_legacy_view_refused () =
  let dir = tmp_dir "c2c-b266-floor-split-missing" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    create_split_brain_db dir `Missing;
    (* sqlite_ddl recreates a legacy table; validation must still reject it. *)
    check bool "secure + missing refusal view refused" true
      (secure_open_fails dir))

let test_triggered_legacy_view_refused () =
  let dir = tmp_dir "c2c-b266-floor-trigger" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    create_split_brain_db dir `Triggered_view;
    check bool "write-triggered legacy view refused" true
      (secure_open_fails dir))

let test_concurrent_secure_opens_serialize () =
  with_legacy_db "c2c-b266-floor-concurrent" (fun dir ->
    let start = Atomic.make false in
    let open_once () =
      while not (Atomic.get start) do Domain.cpu_relax () done;
      Relay.SqliteRelay.create ~persist_dir:dir ()
    in
    let d1 = Domain.spawn open_once in
    let d2 = Domain.spawn open_once in
    Atomic.set start true;
    let r1 = Domain.join d1 in
    let r2 = Domain.join d2 in
    check int "first concurrent open sees row" 1
      (List.length (Relay.SqliteRelay.list_peers_admin r1 ~include_dead:true));
    check int "second concurrent open sees row" 1
      (List.length (Relay.SqliteRelay.list_peers_admin r2 ~include_dead:true));
    with_db (db_path dir) (fun db ->
      check (option string) "one legacy view" (Some "view")
        (object_type db "leases");
      check int "one secure row after concurrent opens" 1
        (count_rows db "secure_leases_v2")))

let () =
  Random.self_init ();
  Alcotest.run "relay_b266_rollback_floor"
    [ ("rollback floor",
       [ test_case "new binary preserves migrated registration" `Quick
           test_new_binary_preserves_migrated_registration;
         test_case "old binary reads empty and cannot write" `Quick
           test_old_binary_reads_empty_and_cannot_write;
         test_case "interrupted rename rolls back" `Quick
           test_interrupted_rename_rolls_back;
         test_case "retry/reopen idempotent" `Quick
           test_retry_and_reopen_are_idempotent;
         test_case "concurrent secure opens serialize" `Quick
           test_concurrent_secure_opens_serialize;
         test_case "secure + legacy table refused" `Quick
           test_secure_plus_legacy_table_refused;
         test_case "secure + missing refusal view refused" `Quick
           test_secure_plus_missing_legacy_view_refused;
         test_case "write-triggered refusal view refused" `Quick
           test_triggered_legacy_view_refused ]) ]
