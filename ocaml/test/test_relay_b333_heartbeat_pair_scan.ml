(* B333: sqlite heartbeat pair scan is last-row-wins without released-skip —
   the B295 fix covered alias_of_session only.

   find_lease (heartbeat's internal pair scan) SELECTed the rows for
   (node_id, session_id) with no ORDER BY and kept the LAST row, then examined
   only that row for released. On a legacy pre-B295 DB holding a released
   shadow row at a HIGHER rowid than the live row, a heartbeat whose handler
   pre-check passed still failed inside the backend: it released the shadow
   and returned unknown_alias (HTTP 200 / ok:false) without the
   lease_not_found re-register guidance B293 added. Self-healing only after
   one failure per shadow row; permanent when gc is disabled (interval 0).

   Fix under test: the heartbeat scan gets the same ORDER BY last_seen DESC +
   released-skip treatment as alias_of_session. Pinned here:
   - heartbeat succeeds against the live row with a released shadow at a
     higher rowid;
   - heartbeat against a pair whose every row is released still reports
     unknown_alias (unchanged contract). *)

open Alcotest

let with_temp_dir f =
  let dir = Filename.temp_dir "c2c_relay_b333" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote dir)))
    (fun () -> f dir)

(* Legacy-shaped row, inserted directly after the live row so its rowid sorts
   AFTER it (mirrors months-old prod data where the pre-B295 register left a
   shadow row behind). *)
let sqlite_insert_shadow_row dir ~alias ~node_id ~session_id ~last_seen =
  let db_path = Filename.concat dir "c2c_relay.db" in
  let conn = Sqlite3.db_open db_path in
  ignore (Sqlite3.exec conn "PRAGMA busy_timeout = 5000");
  let sql =
    Printf.sprintf
      "INSERT INTO secure_leases_v2 (alias, node_id, session_id, client_type, \
       registered_at, last_seen, ttl, identity_pk, enc_pubkey, signed_at, \
       sig_b64, opaque_host_id, client_version, client_os, discovery_visibility) \
       VALUES ('%s', '%s', '%s', 'unknown', %f, %f, 30.0, '', '', 0.0, '', '', \
       '', '', 'private')"
      alias node_id session_id last_seen last_seen
  in
  if not (Sqlite3.Rc.is_success (Sqlite3.exec conn sql)) then
    fail "legacy shadow row insert failed";
  ignore (Sqlite3.db_close conn)

let test_heartbeat_finds_live_row_despite_released_shadow_at_higher_rowid () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b333-node" ~session_id:"b333-sess"
        ~alias:"b333-live" ()
    in
    check string "live register ok" "ok" status;
    (* Released shadow: same pair, higher rowid, last_seen past the 12-month
       anti-squat window. *)
    sqlite_insert_shadow_row dir ~alias:"b333-shadow"
      ~node_id:"b333-node" ~session_id:"b333-sess"
      ~last_seen:(Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0);
    let hstatus, hlease =
      Relay.SqliteRelay.heartbeat t ~node_id:"b333-node"
        ~session_id:"b333-sess" ~opaque_host_id:""
    in
    check string "heartbeat ok against the live row" "ok" hstatus;
    check string "heartbeat resolved the live lease, not the shadow"
      "b333-live" (Relay.RegistrationLease.alias hlease);
    check (option string) "pair still resolves to the live alias"
      (Some "b333-live")
      (Relay.SqliteRelay.alias_of_session t ~node_id:"b333-node"
         ~session_id:"b333-sess")

  )

(* Pin: an all-released pair still reports unknown_alias. *)
let test_heartbeat_all_rows_released_is_unknown_alias () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    let status, _ =
      Relay.SqliteRelay.register t ~node_id:"b333-node2"
        ~session_id:"b333-sess2" ~alias:"b333-gone" ()
    in
    check string "register ok" "ok" status;
    let old = Unix.gettimeofday () -. Relay.alias_release_after_s -. 60.0 in
    sqlite_insert_shadow_row dir ~alias:"b333-gone-shadow"
      ~node_id:"b333-node2" ~session_id:"b333-sess2" ~last_seen:old;
    let conn = Sqlite3.db_open (Filename.concat dir "c2c_relay.db") in
    (* Age the live row past the release window too: every row released. *)
    if not (Sqlite3.Rc.is_success (Sqlite3.exec conn
      (Printf.sprintf
         "UPDATE secure_leases_v2 SET last_seen = %f, registered_at = %f WHERE alias = 'b333-gone'"
         old old)))
    then fail "aging live row failed";
    ignore (Sqlite3.db_close conn);
    let hstatus, _hlease =
      Relay.SqliteRelay.heartbeat t ~node_id:"b333-node2"
        ~session_id:"b333-sess2" ~opaque_host_id:""
    in
    check string "all-released pair still unknown_alias"
      Relay.relay_err_unknown_alias hstatus)

let () =
  run "B333 sqlite heartbeat pair scan: freshest-first with released-skip"
    [ ("legacy released shadow at higher rowid", [
        test_case "heartbeat succeeds against the live row" `Quick
          test_heartbeat_finds_live_row_despite_released_shadow_at_higher_rowid;
      ])
    ; ("all rows released", [
        test_case "still unknown_alias" `Quick
          test_heartbeat_all_rows_released_is_unknown_alias;
      ])
    ]
