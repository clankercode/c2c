(* B330: B295 pair-takeover diverges across storage backends.

   (a) The sqlite shadow-DELETE (register's pair takeover) removes the whole
   secure_leases_v2 row — which is where the identity binding and the
   12-month anti-squat reservation live — while the in-memory shadow-removal
   drops only the lease entry and deliberately keeps t.bindings (only
   release_alias clears those). After a rename takeover sqlite therefore lets
   ANY identity claim the shadowed alias immediately; in-memory rejects a
   foreign key with alias_identity_mismatch. Prod is weaker than the tested
   behaviour.

   (b) Precedence: a live lease bound to pk1, re-registered with pk2 from a
   different node — in-memory checks the binding first (alias_identity_mismatch),
   sqlite's conflict scan fires first (alias_conflict). Distinct failure modes
   collapse differently per backend, violating the B293 goal. The binding
   check wins on both backends: it is the stronger contract (a key-drift
   rebind attempt must not be misread as an innocent conflict with someone
   else's lease — the submitted key is simply not this alias's).

   Pinned here, both backends diverge-then-agree:
   - foreign identity cannot claim the shadowed alias after takeover;
   - the ORIGINAL owner can reclaim it (binding still matches);
   - binding mismatch takes precedence over alias conflict;
   - legacy unsigned register from a foreign node still alias_conflicts
     (the reorder must not swallow the plain anti-squat conflict);
   - a database written before alias_reservations existed opens cleanly
     (additive CREATE TABLE IF NOT EXISTS migration). *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b330" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

let pk_owner = "b330-pk-owner"
let pk_new = "b330-pk-new"
let pk_attacker = "b330-pk-attacker"

let expect_status ~what ~expected got =
  check string what expected got

(* Takeover setup: alias bound to pk_owner under (n1, s1); the same pair
   re-registers under a fresh alias with pk_new — the B295 takeover that
   shadows the old alias's lease row. *)
let takeover_sql t ~old_alias ~new_alias =
  let s1, _ =
    Relay.SqliteRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
      ~alias:old_alias ~identity_pk:pk_owner ()
  in
  expect_status ~what:(old_alias ^ ": owner register ok") ~expected:"ok" s1;
  let s2, _ =
    Relay.SqliteRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
      ~alias:new_alias ~identity_pk:pk_new ()
  in
  expect_status ~what:(new_alias ^ ": takeover register ok") ~expected:"ok" s2

let takeover_mem t ~old_alias ~new_alias =
  let s1, _ =
    Relay.InMemoryRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
      ~alias:old_alias ~identity_pk:pk_owner ()
  in
  expect_status ~what:(old_alias ^ ": owner register ok") ~expected:"ok" s1;
  let s2, _ =
    Relay.InMemoryRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
      ~alias:new_alias ~identity_pk:pk_new ()
  in
  expect_status ~what:(new_alias ^ ": takeover register ok") ~expected:"ok" s2

let test_sqlite_reservation_survives_takeover () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    takeover_sql t ~old_alias:"b330-old"
      ~new_alias:"b330-new";
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n3" ~session_id:"b330-s3"
        ~alias:"b330-old" ~identity_pk:pk_attacker ()
    in
    expect_status ~what:"sqlite: foreign identity cannot claim shadowed alias"
      ~expected:Relay.relay_err_alias_identity_mismatch status)

let test_sqlite_owner_can_reclaim_shadowed_alias () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    takeover_sql t ~old_alias:"b330-old"
      ~new_alias:"b330-new";
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n3" ~session_id:"b330-s3"
        ~alias:"b330-old" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"sqlite: original owner reclaims shadowed alias"
      ~expected:"ok" status)

let test_inmemory_reservation_survives_takeover () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    takeover_mem t ~old_alias:"b330-old"
      ~new_alias:"b330-new";
    let status, _ =
      Relay.InMemoryRelay.register t ~node_id:"b330-n3" ~session_id:"b330-s3"
        ~alias:"b330-old" ~identity_pk:pk_attacker ()
    in
    expect_status ~what:"in-memory: foreign identity cannot claim shadowed alias"
      ~expected:Relay.relay_err_alias_identity_mismatch status)

let test_inmemory_owner_can_reclaim_shadowed_alias () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    takeover_mem t ~old_alias:"b330-old"
      ~new_alias:"b330-new";
    let status, _ =
      Relay.InMemoryRelay.register t ~node_id:"b330-n3" ~session_id:"b330-s3"
        ~alias:"b330-old" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"in-memory: original owner reclaims shadowed alias"
      ~expected:"ok" status)

(* (b) precedence: mismatch must outrank conflict on BOTH backends. *)
let test_sqlite_binding_mismatch_outranks_conflict () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let s1, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-pb" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"bound lease registered" ~expected:"ok" s1;
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n2" ~session_id:"b330-s2"
        ~alias:"b330-pb" ~identity_pk:pk_attacker ()
    in
    expect_status ~what:"sqlite: key drift from foreign node is a mismatch"
      ~expected:Relay.relay_err_alias_identity_mismatch status)

let test_inmemory_binding_mismatch_outranks_conflict () =
  with_temp_dir (fun dir ->
    let t = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let s1, _ =
      Relay.InMemoryRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-pb" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"bound lease registered" ~expected:"ok" s1;
    let status, _ =
      Relay.InMemoryRelay.register t ~node_id:"b330-n2" ~session_id:"b330-s2"
        ~alias:"b330-pb" ~identity_pk:pk_attacker ()
    in
    expect_status ~what:"in-memory: key drift from foreign node is a mismatch"
      ~expected:Relay.relay_err_alias_identity_mismatch status)

(* Guard: the reorder must not swallow the plain anti-squat conflict. *)
let test_legacy_unsigned_foreign_register_still_conflicts () =
  with_temp_dir (fun dir ->
    let sq = Relay.SqliteRelay.create ~persist_dir:dir () in
    let s1, _ =
      Relay.SqliteRelay.register sq ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-lg" ()
    in
    expect_status ~what:"sqlite: first register ok" ~expected:"ok" s1;
    let status, _ =
      Relay.SqliteRelay.register sq ~node_id:"b330-n2" ~session_id:"b330-s2"
        ~alias:"b330-lg" ()
    in
    expect_status ~what:"sqlite: unsigned foreign register still conflicts"
      ~expected:Relay.relay_err_alias_conflict status);
  with_temp_dir (fun dir ->
    let im = Relay.InMemoryRelay.create ~persist_dir:dir () in
    let s1, _ =
      Relay.InMemoryRelay.register im ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-lg" ()
    in
    expect_status ~what:"in-memory: first register ok" ~expected:"ok" s1;
    let status, _ =
      Relay.InMemoryRelay.register im ~node_id:"b330-n2" ~session_id:"b330-s2"
        ~alias:"b330-lg" ()
    in
    expect_status ~what:"in-memory: unsigned foreign register still conflicts"
      ~expected:Relay.relay_err_alias_conflict status)

(* Review follow-up (B330): unbind is the sanctioned binding-clearer. With
   alias_reservations in place, sqlite unbind_alias must clear the
   reservation too, or no foreign identity could ever reclaim the alias —
   the escape hatch in-memory's unbind provides ("after unbind, a different
   pk can claim"). *)
let test_sqlite_unbind_clears_reservation () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let s1, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-ub" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"bound lease registered" ~expected:"ok" s1;
    check bool "unbind reports removed" true
      (Relay.SqliteRelay.unbind_alias t ~alias:"b330-ub");
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n2" ~session_id:"b330-s2"
        ~alias:"b330-ub" ~identity_pk:pk_attacker ()
    in
    expect_status ~what:"foreign identity can claim after unbind" ~expected:"ok"
      status)

(* Migration: a pre-B330 database has no alias_reservations table. Simulated
   by creating the DB with the current schema and dropping the new table —
   exactly the on-disk shape an older binary leaves — then reopening. *)
let test_pre_b330_database_opens_cleanly () =
  with_temp_dir (fun dir ->
    ignore (Relay.SqliteRelay.create ~persist_dir:dir ());
    let db_path = Filename.concat dir "c2c_relay.db" in
    let conn = Sqlite3.db_open db_path in
    ignore (Sqlite3.exec conn "PRAGMA busy_timeout = 5000");
    if not (Sqlite3.Rc.is_success (Sqlite3.exec conn "DROP TABLE IF EXISTS alias_reservations"))
    then fail "drop pre-B330 simulation failed";
    ignore (Sqlite3.db_close conn);
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b330-n1" ~session_id:"b330-s1"
        ~alias:"b330-mig" ~identity_pk:pk_owner ()
    in
    expect_status ~what:"register works on migrated database" ~expected:"ok"
      status)

let () =
  run "B330 takeover parity: binding reservation survives, mismatch outranks conflict"
    [ ("sqlite reservation survives pair takeover", [
        test_case "foreign identity cannot claim shadowed alias" `Quick
          test_sqlite_reservation_survives_takeover;
        test_case "original owner can reclaim shadowed alias" `Quick
          test_sqlite_owner_can_reclaim_shadowed_alias;
      ])
    ; ("in-memory reservation survives pair takeover (pin)", [
        test_case "foreign identity cannot claim shadowed alias" `Quick
          test_inmemory_reservation_survives_takeover;
        test_case "original owner can reclaim shadowed alias" `Quick
          test_inmemory_owner_can_reclaim_shadowed_alias;
      ])
    ; ("precedence: binding mismatch outranks conflict", [
        test_case "sqlite" `Quick test_sqlite_binding_mismatch_outranks_conflict;
        test_case "in-memory" `Quick test_inmemory_binding_mismatch_outranks_conflict;
      ])
    ; ("guards", [
        test_case "legacy unsigned foreign register still conflicts" `Quick
          test_legacy_unsigned_foreign_register_still_conflicts;
        test_case "unbind clears the reservation" `Quick
          test_sqlite_unbind_clears_reservation;
        test_case "pre-B330 database opens cleanly" `Quick
          test_pre_b330_database_opens_cleanly;
      ])
    ]
