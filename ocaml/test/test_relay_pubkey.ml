(* test_relay_pubkey.ml — S2 signed pubkey lookup tests *)

open Relay

let fail_fmt fmt = Printf.ksprintf (fun s -> failwith s) fmt

(* ---- RegistrationLease signed_at / sig_b64 tests ---- *)

let test_lease_make_with_signed_fields () =
  let now = Unix.gettimeofday () in
  let lease = RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1"
    ~signed_at:now ~sig_b64:"sig_test" () in
  if RegistrationLease.signed_at lease <> now then fail_fmt "signed_at mismatch";
  if RegistrationLease.sig_b64 lease <> "sig_test" then fail_fmt "sig_b64 mismatch"

let test_lease_make_without_signed_fields_defaults_to_zero () =
  let lease = RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" () in
  if RegistrationLease.signed_at lease <> 0.0 then fail_fmt "signed_at should default to 0.0";
  if RegistrationLease.sig_b64 lease <> "" then fail_fmt "sig_b64 should default to \"\""

let test_lease_to_json_includes_signed_fields () =
  let now = 1234567890.5 in
  let lease = RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1"
    ~signed_at:now ~sig_b64:"sig_abc" () in
  let json = RegistrationLease.to_json lease in
  match json with
  | `Assoc fields ->
    let sa = List.assoc_opt "signed_at" fields in
    let sb = List.assoc_opt "sig_b64" fields in
    if sa <> Some (`Float now) then fail_fmt "to_json signed_at missing or wrong";
    if sb <> Some (`String "sig_abc") then fail_fmt "to_json sig_b64 missing or wrong"
  | _ -> fail_fmt "to_json should return Assoc"

let test_lease_to_json_omits_zero_signed_at () =
  let lease = RegistrationLease.make ~node_id:"n1" ~session_id:"s1" ~alias:"a1" () in
  let json = RegistrationLease.to_json lease in
  match json with
  | `Assoc fields ->
    if List.mem_assoc "signed_at" fields then fail_fmt "signed_at should be omitted when 0.0";
    if List.mem_assoc "sig_b64" fields then fail_fmt "sig_b64 should be omitted when \"\""
  | _ -> fail_fmt "to_json should return Assoc"

(* ---- InMemoryRelay lookup functions ---- *)

let test_identity_pk_of_unknown_alias () =
  let t = InMemoryRelay.create () in
  match InMemoryRelay.identity_pk_of t ~alias:"nobody" with
  | None -> ()
  | Some _ -> fail_fmt "unknown alias should return None"

let test_enc_pubkey_of_unknown_alias () =
  let t = InMemoryRelay.create () in
  match InMemoryRelay.enc_pubkey_of t ~alias:"nobody" with
  | None -> ()
  | Some _ -> fail_fmt "unknown alias should return None for enc_pubkey"

let test_signed_at_of_unknown_alias () =
  let t = InMemoryRelay.create () in
  match InMemoryRelay.signed_at_of t ~alias:"nobody" with
  | None -> ()
  | Some _ -> fail_fmt "unknown alias should return None for signed_at"

let test_sig_b64_of_unknown_alias () =
  let t = InMemoryRelay.create () in
  match InMemoryRelay.sig_b64_of t ~alias:"nobody" with
  | None -> ()
  | Some _ -> fail_fmt "unknown alias should return None for sig_b64"

(* ---- SqliteRelay lookup functions ---- *)

let test_sqlite_identity_pk_of_unknown () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  (match SqliteRelay.identity_pk_of t ~alias:"ghost" with
   | Some _ -> fail_fmt "unknown alias should return None"
   | None -> ());
  Sys.remove tmpfile

let test_sqlite_enc_pubkey_of_unknown () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  (match SqliteRelay.enc_pubkey_of t ~alias:"ghost" with
   | Some _ -> fail_fmt "unknown alias enc_pubkey should return None"
   | None -> ());
  Sys.remove tmpfile

let test_sqlite_signed_at_of_unknown () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  (match SqliteRelay.signed_at_of t ~alias:"ghost" with
   | Some _ -> fail_fmt "unknown alias signed_at should return None"
   | None -> ());
  Sys.remove tmpfile

let test_sqlite_sig_b64_of_unknown () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  (match SqliteRelay.sig_b64_of t ~alias:"ghost" with
   | Some _ -> fail_fmt "unknown alias sig_b64 should return None"
   | None -> ());
  Sys.remove tmpfile

(* ---- SqliteRelay DDL includes new columns ---- *)

let test_sqlite_ddl_has_signed_at_column () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  let conn = Sqlite3.db_open (Printf.sprintf "%s/c2c_relay.db" (Filename.dirname tmpfile)) in
  let stmt = Sqlite3.prepare conn "PRAGMA table_info(leases)" in
  let has_signed_at = ref false in
  (try
    while true do
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        (match Sqlite3.Data.to_string (Sqlite3.column stmt 1) with
         | Some "signed_at" -> has_signed_at := true
         | _ -> ())
      | _ -> raise Exit
    done
  with Exit -> ());
  if not !has_signed_at then fail_fmt "leases table should have signed_at column";
  Sqlite3.finalize stmt |> ignore;
  Sys.remove tmpfile

let test_sqlite_ddl_has_sig_b64_column () =
  let tmpfile = Filename.temp_file "c2c_test" ".db" in
  let t = SqliteRelay.create ~persist_dir:(Filename.dirname tmpfile) () in
  let conn = Sqlite3.db_open (Printf.sprintf "%s/c2c_relay.db" (Filename.dirname tmpfile)) in
  let stmt = Sqlite3.prepare conn "PRAGMA table_info(leases)" in
  let has_sig_b64 = ref false in
  (try
    while true do
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        (match Sqlite3.Data.to_string (Sqlite3.column stmt 1) with
         | Some "sig_b64" -> has_sig_b64 := true
         | _ -> ())
      | _ -> raise Exit
    done
  with Exit -> ());
  if not !has_sig_b64 then fail_fmt "leases table should have sig_b64 column";
  Sqlite3.finalize stmt |> ignore;
  Sys.remove tmpfile

(* ---- Run tests ---- *)

let tests = [
  "lease make with signed fields", test_lease_make_with_signed_fields;
  "lease make defaults to zero", test_lease_make_without_signed_fields_defaults_to_zero;
  "lease to_json includes signed fields", test_lease_to_json_includes_signed_fields;
  "lease to_json omits zero signed_at", test_lease_to_json_omits_zero_signed_at;
  "identity_pk_of unknown alias", test_identity_pk_of_unknown_alias;
  "enc_pubkey_of unknown alias", test_enc_pubkey_of_unknown_alias;
  "signed_at_of unknown alias", test_signed_at_of_unknown_alias;
  "sig_b64_of unknown alias", test_sig_b64_of_unknown_alias;
  "sqlite identity_pk_of unknown", test_sqlite_identity_pk_of_unknown;
  "sqlite enc_pubkey_of unknown", test_sqlite_enc_pubkey_of_unknown;
  "sqlite signed_at_of unknown", test_sqlite_signed_at_of_unknown;
  "sqlite sig_b64_of unknown", test_sqlite_sig_b64_of_unknown;
  "sqlite DDL has signed_at column", test_sqlite_ddl_has_signed_at_column;
  "sqlite DDL has sig_b64 column", test_sqlite_ddl_has_sig_b64_column;
]

let () =
  let passed = ref 0 in
  let failed = ref 0 in
  List.iter (fun (name, test) ->
    try
      test ();
      Printf.printf "[PASS] %s\n%!" name;
      incr passed
    with e ->
      Printf.printf "[FAIL] %s: %s\n%!" name (Printexc.to_string e);
      incr failed
  ) tests;
  Printf.printf "\n%d passed, %d failed\n%!" !passed !failed;
  if !failed > 0 then exit 1