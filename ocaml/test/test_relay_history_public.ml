(* B117 — history_public persisted room-setting tests.

   Covers all four seams:
   1. InMemoryRelay: defaults, set, visibility-downgrade atomic clear.
   2. SqliteRelay: defaults, set, persistence across a restart (reopen), and
      visibility-downgrade atomic clear.
   3. SqliteRelay migration: an old DB whose rooms table lacks history_public
      is upgraded — public/unlisted default open (1), gated/private forced 0.
   4. Signed-op canonical bytes: the boolean IS covered by the signature
      (a flipped value fails verification → not forgeable).

   The HTTP request matrix (anonymous read gated by history_public, member read
   of a closed room, set-true-on-gated rejected) lives in the Python e2e suite
   tests/test_relay_signed_room_ops_gate.py (HistoryPublic* classes). *)

open Alcotest

let decode_exn s =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet s with
  | Ok x -> x
  | Error _ -> Alcotest.fail ("decode failed: " ^ s)

let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let dir = Filename.concat base
      (Printf.sprintf "c2c-relay-b117-%08x" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

(* --- 1. InMemoryRelay --- *)

let register_and_join_mem t ~alias ~room_id ~visibility =
  let _ = Relay.InMemoryRelay.register t
    ~node_id:("n-" ^ alias) ~session_id:("s-" ^ alias) ~alias () in
  match Relay.InMemoryRelay.join_room t ~visibility ~alias ~room_id () with
  | `Ok -> ()
  | `Error (code, msg) -> Alcotest.failf "join failed: %s %s" code msg

let test_mem_public_defaults_true () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"pub-room" ~visibility:"public";
  check bool "public room defaults history_public=true" true
    (Relay.InMemoryRelay.history_public_of t ~room_id:"pub-room")

let test_mem_unlisted_defaults_true () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"unl-room" ~visibility:"unlisted";
  check bool "unlisted room defaults history_public=true" true
    (Relay.InMemoryRelay.history_public_of t ~room_id:"unl-room")

let test_mem_gated_defaults_false () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"gat-room" ~visibility:"gated";
  check bool "gated room defaults history_public=false" false
    (Relay.InMemoryRelay.history_public_of t ~room_id:"gat-room")

let test_mem_private_defaults_false () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"prv-room" ~visibility:"private";
  check bool "private room defaults history_public=false" false
    (Relay.InMemoryRelay.history_public_of t ~room_id:"prv-room")

let test_mem_set_history_public_false () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"pub2" ~visibility:"public";
  Relay.InMemoryRelay.set_room_history_public t ~room_id:"pub2" ~history_public:false;
  check bool "closed public room reads history_public=false" false
    (Relay.InMemoryRelay.history_public_of t ~room_id:"pub2");
  Relay.InMemoryRelay.set_room_history_public t ~room_id:"pub2" ~history_public:true;
  check bool "reopened public room reads history_public=true" true
    (Relay.InMemoryRelay.history_public_of t ~room_id:"pub2")

let test_mem_visibility_downgrade_clears () =
  let t = Relay.InMemoryRelay.create () in
  register_and_join_mem t ~alias:"alice" ~room_id:"flip" ~visibility:"public";
  check bool "starts open" true
    (Relay.InMemoryRelay.history_public_of t ~room_id:"flip");
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"flip" ~visibility:"gated";
  check bool "public->gated atomically clears history_public" false
    (Relay.InMemoryRelay.history_public_of t ~room_id:"flip");
  (* Flipping back to public must NOT silently re-open a cleared room. *)
  Relay.InMemoryRelay.set_room_visibility t ~room_id:"flip" ~visibility:"public";
  check bool "gated->public preserves cleared history_public" false
    (Relay.InMemoryRelay.history_public_of t ~room_id:"flip")

let test_mem_unknown_room_default () =
  let t = Relay.InMemoryRelay.create () in
  (* No such room stored: default is open (public default), matching the
     anonymous empty-history read behaviour. *)
  check bool "unknown room defaults open" true
    (Relay.InMemoryRelay.history_public_of t ~room_id:"ghost")

(* --- 2. SqliteRelay (incl. restart persistence) --- *)

let register_and_join_sqlite t ~alias ~room_id ~visibility =
  let _ = Relay.SqliteRelay.register t
    ~node_id:("n-" ^ alias) ~session_id:("s-" ^ alias) ~alias () in
  match Relay.SqliteRelay.join_room t ~visibility ~alias ~room_id () with
  | `Ok -> ()
  | `Error (code, msg) -> Alcotest.failf "sqlite join failed: %s %s" code msg

let test_sqlite_defaults () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    register_and_join_sqlite t ~alias:"alice" ~room_id:"s-pub" ~visibility:"public";
    register_and_join_sqlite t ~alias:"bob" ~room_id:"s-gat" ~visibility:"gated";
    check bool "sqlite public defaults true" true
      (Relay.SqliteRelay.history_public_of t ~room_id:"s-pub");
    check bool "sqlite gated defaults false" false
      (Relay.SqliteRelay.history_public_of t ~room_id:"s-gat"))

let test_sqlite_persists_across_restart () =
  with_temp_dir (fun dir ->
    (let t = Relay.SqliteRelay.create ~persist_dir:dir () in
     register_and_join_sqlite t ~alias:"alice" ~room_id:"persist" ~visibility:"public";
     Relay.SqliteRelay.set_room_history_public t ~room_id:"persist" ~history_public:false;
     check bool "closed before restart" false
       (Relay.SqliteRelay.history_public_of t ~room_id:"persist"));
    (* Reopen a fresh relay handle on the same on-disk DB — the setting must
       survive. *)
    let t2 = Relay.SqliteRelay.create ~persist_dir:dir () in
    check bool "history_public=false survives restart" false
      (Relay.SqliteRelay.history_public_of t2 ~room_id:"persist"))

let test_sqlite_visibility_downgrade_clears () =
  with_temp_dir (fun dir ->
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    register_and_join_sqlite t ~alias:"alice" ~room_id:"s-flip" ~visibility:"public";
    check bool "starts open" true
      (Relay.SqliteRelay.history_public_of t ~room_id:"s-flip");
    Relay.SqliteRelay.set_room_visibility t ~room_id:"s-flip" ~visibility:"private";
    check bool "public->private atomically clears" false
      (Relay.SqliteRelay.history_public_of t ~room_id:"s-flip");
    Relay.SqliteRelay.set_room_visibility t ~room_id:"s-flip" ~visibility:"public";
    check bool "private->public preserves cleared value" false
      (Relay.SqliteRelay.history_public_of t ~room_id:"s-flip"))

(* --- 3. SqliteRelay migration of an old DB without the column --- *)

let test_sqlite_migration_old_db () =
  with_temp_dir (fun dir ->
    let db_path = Filename.concat dir "c2c_relay.db" in
    (* Hand-build an OLD rooms table (no history_public column) with a public
       and a gated room already present. *)
    (let conn = Sqlite3.db_open db_path in
     Sqlite3.exec conn
       "CREATE TABLE rooms (room_id TEXT PRIMARY KEY, visibility TEXT NOT NULL DEFAULT 'public');"
       |> ignore;
     Sqlite3.exec conn
       "INSERT INTO rooms (room_id, visibility) VALUES ('old-pub','public'), \
        ('old-unl','unlisted'), ('old-gat','gated'), ('old-prv','private');"
       |> ignore;
     ignore (Sqlite3.db_close conn));
    (* Opening via SqliteRelay.create runs the migration. *)
    let t = Relay.SqliteRelay.create ~persist_dir:dir () in
    check bool "migrated old public → open (1)" true
      (Relay.SqliteRelay.history_public_of t ~room_id:"old-pub");
    check bool "migrated old unlisted → open (1)" true
      (Relay.SqliteRelay.history_public_of t ~room_id:"old-unl");
    check bool "migrated old gated → forced closed (0)" false
      (Relay.SqliteRelay.history_public_of t ~room_id:"old-gat");
    check bool "migrated old private → forced closed (0)" false
      (Relay.SqliteRelay.history_public_of t ~room_id:"old-prv"))

(* --- 4. Signed-op canonical bytes cover the boolean --- *)

let test_signed_bytes_cover_boolean () =
  let id = Relay_identity.generate () in
  let proof = Relay_signed_ops.sign_room_op_with_history_public id
    ~ctx:Relay.room_set_history_public_sign_ctx
    ~room_id:"lounge" ~alias:"alice" ~history_public:true in
  let sig_ = decode_exn proof.Relay_signed_ops.sig_b64 in
  let blob_true = Relay_identity.canonical_msg
    ~ctx:Relay.room_set_history_public_sign_ctx
    [ "lounge"; "alice"; "true"; proof.identity_pk_b64; proof.ts; proof.nonce ] in
  let blob_false = Relay_identity.canonical_msg
    ~ctx:Relay.room_set_history_public_sign_ctx
    [ "lounge"; "alice"; "false"; proof.identity_pk_b64; proof.ts; proof.nonce ] in
  check bool "proof verifies with the signed boolean (true)" true
    (Relay_identity.verify ~pk:id.public_key ~msg:blob_true ~sig_);
  check bool "proof rejects a flipped boolean (false)" false
    (Relay_identity.verify ~pk:id.public_key ~msg:blob_false ~sig_)

let () =
  run "test_relay_history_public"
    [ "InMemoryRelay", [
        test_case "public defaults true" `Quick test_mem_public_defaults_true;
        test_case "unlisted defaults true" `Quick test_mem_unlisted_defaults_true;
        test_case "gated defaults false" `Quick test_mem_gated_defaults_false;
        test_case "private defaults false" `Quick test_mem_private_defaults_false;
        test_case "set history_public false/true" `Quick test_mem_set_history_public_false;
        test_case "visibility downgrade clears" `Quick test_mem_visibility_downgrade_clears;
        test_case "unknown room default" `Quick test_mem_unknown_room_default;
      ];
      "SqliteRelay", [
        test_case "defaults per visibility" `Quick test_sqlite_defaults;
        test_case "persists across restart" `Quick test_sqlite_persists_across_restart;
        test_case "visibility downgrade clears" `Quick test_sqlite_visibility_downgrade_clears;
      ];
      "SqliteRelay migration", [
        test_case "old DB without column migrated" `Quick test_sqlite_migration_old_db;
      ];
      "Signed-op canonical bytes", [
        test_case "boolean covered by signature" `Quick test_signed_bytes_cover_boolean;
      ];
    ]
