[@@@warning "-33-16-32-26"]
(* relay_sqlite.ml — SQLite-backed relay implementing the RELAY signature *)

open Lwt.Infix
module R = Result
open Sqlite3

(* Error codes — must match relay.ml *)
let relay_err_unknown_alias = "unknown_alias"
let relay_err_alias_conflict = "alias_conflict"
let relay_err_alias_identity_mismatch = "alias_identity_mismatch"
let relay_err_recipient_dead = "recipient_dead"
let relay_err_signature_invalid = "signature_invalid"
let relay_err_timestamp_out_of_window = "timestamp_out_of_window"
let relay_err_nonce_replay = "nonce_replay"
let relay_err_missing_proof_field = "missing_proof_field"
let relay_err_unsupported_enc = "unsupported_enc"
let relay_err_not_invited = "not_invited"
let relay_err_not_a_member = "not_a_member"

(* Schema version for migrations *)
let schema_version = 1

(* Schema initialization *)
let ddl = {sql|
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS leases (
    alias TEXT PRIMARY KEY,
    node_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    client_type TEXT NOT NULL DEFAULT 'unknown',
    registered_at REAL NOT NULL,
    last_seen REAL NOT NULL,
    ttl REAL NOT NULL,
    identity_pk TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS inboxes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    from_alias TEXT NOT NULL,
    to_alias TEXT NOT NULL,
    content TEXT NOT NULL,
    ts REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_inboxes_session ON inboxes(node_id, session_id);

CREATE TABLE IF NOT EXISTS dead_letter (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id TEXT NOT NULL,
    from_alias TEXT NOT NULL,
    to_alias TEXT NOT NULL,
    content TEXT NOT NULL,
    ts REAL NOT NULL,
    reason TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rooms (
    room_id TEXT PRIMARY KEY,
    visibility TEXT NOT NULL DEFAULT 'public'
);

CREATE TABLE IF NOT EXISTS room_members (
    room_id TEXT NOT NULL,
    alias TEXT NOT NULL,
    PRIMARY KEY (room_id, alias)
);

CREATE TABLE IF NOT EXISTS room_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    room_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    from_alias TEXT NOT NULL,
    content TEXT NOT NULL,
    ts REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_room_history_room ON room_history(room_id);

CREATE TABLE IF NOT EXISTS seen_ids (
    message_id TEXT PRIMARY KEY,
    ts REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS allowed_identities (
    alias TEXT PRIMARY KEY,
    identity_pk_b64 TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS register_nonces (
    nonce TEXT PRIMARY KEY,
    ts REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS request_nonces (
    nonce TEXT PRIMARY KEY,
    ts REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS room_invites (
    room_id TEXT NOT NULL,
    identity_pk_b64 TEXT NOT NULL,
    PRIMARY KEY (room_id, identity_pk_b64)
);
|sql}

(* Local Lease type mirroring RegistrationLease from relay.ml *)
module Lease = struct
  type t = {
    node_id : string;
    session_id : string;
    alias : string;
    client_type : string;
    registered_at : float;
    mutable last_seen : float;
    ttl : float;
    identity_pk : string;
  }

  let make ~node_id ~session_id ~alias ?(client_type = "unknown") ?(ttl = 300.0) ?(identity_pk = "") () =
    let now = Unix.gettimeofday () in
    { node_id; session_id; alias; client_type; registered_at = now; last_seen = now; ttl; identity_pk }

  let is_alive t =
    let now = Unix.gettimeofday () in
    (t.last_seen +. t.ttl) >= now

  let touch t =
    t.last_seen <- Unix.gettimeofday ()

  let node_id t = t.node_id
  let session_id t = t.session_id
  let alias t = t.alias
  let identity_pk t = t.identity_pk
end

let get_now = fun () -> Unix.gettimeofday ()

let with_lock m f =
  Mutex.lock m;
  Lwt.return (try Ok (f ()) with e -> Error e) >>= fun res ->
  Mutex.unlock m;
  Lwt.return res

(* Execute a SQL statement that doesn't return rows (INSERT, UPDATE, DELETE) *)
let exec_no_rows db sql =
  let rc = Sqlite3.exec db sql in
  if Rc.is_success rc then Ok ()
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

(* Execute a SQL statement with one optional row result (SELECT returning 0 or 1 row) *)
let exec_one_row db sql =
  let result = ref None in
  let rc = Sqlite3.exec db ~cb:(fun row _ ->
    result := Some (Array.to_list row)
  ) sql in
  if Rc.is_success rc then Ok !result
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

(* Execute a SQL statement with multiple row results (SELECT returning 0+ rows) *)
let exec_many_rows db sql =
  let results = ref [] in
  let rc = Sqlite3.exec db ~cb:(fun row _ ->
    results := (Array.to_list row) :: !results
  ) sql in
  if Rc.is_success rc then Ok (List.rev !results)
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

(* Prepare and step a statement with parameters *)
let exec_prepared db sql params =
  let stmt = Sqlite3.prepare db sql in
  List.iteri (fun idx param ->
    let idx' = idx + 1 in
    let rc = match param with
      | `Text s -> Sqlite3.bind_text stmt idx' s
      | `Int i -> Sqlite3.bind_int stmt idx' i
      | `Float f -> Sqlite3.bind_double stmt idx' f
      | `Null -> Sqlite3.bind stmt idx' Sqlite3.Data.NULL
    in
    if not (Rc.is_success rc) then failwith ("bind failed: " ^ Rc.to_string rc)
  ) params;
  let rec loop () =
    let rc = Sqlite3.step stmt in
    if rc = Rc.ROW then true
    else if rc = Rc.DONE then false
    else failwith ("step failed: " ^ Rc.to_string rc)
  in
  let has_row = loop () in
  has_row

module SqliteRelay = struct
  type t = {
    db_path : string;
    dedup_window : int;
    mutex : Mutex.t;
  }

  let create ?(dedup_window=10000) ?(persist_dir="") () =
    let db_path = Filename.concat persist_dir "c2c_relay.db" in
    let mutex = Mutex.create () in
    let conn = Sqlite3.db_open db_path in
    Sqlite3.exec conn "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;"
    |> ignore;
    Sqlite3.exec conn ddl |> ignore;
    { db_path; dedup_window; mutex }

  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let get_lease_row_fields row =
    match row with
    | [alias; node_id; session_id; client_type; registered_at; last_seen; ttl; identity_pk] ->
      let alias = match alias with Some s -> s | None -> "" in
      let node_id = match node_id with Some s -> s | None -> "" in
      let session_id = match session_id with Some s -> s | None -> "" in
      let client_type = match client_type with Some s -> s | None -> "unknown" in
      let registered_at = match registered_at with Some s -> float_of_string s | None -> 0.0 in
      let last_seen = match last_seen with Some s -> float_of_string s | None -> 0.0 in
      let ttl = match ttl with Some s -> float_of_string s | None -> 300.0 in
      let identity_pk = match identity_pk with Some s -> s | None -> "" in
      (alias,
       Lease.make
         ~node_id
         ~session_id
         ~alias
         ~client_type
         ~ttl
         ~identity_pk
         ())
    | _ -> failwith "Invalid lease row"

  let lease_of_row row =
    let (_alias, lease) = get_lease_row_fields row in lease

  let is_alive_lease_row row =
    try
      let lease = lease_of_row row in
      Lease.is_alive lease
    with _ -> false

  let row_to_string_opt = function Some s -> s | None -> ""

  let register t ~node_id ~session_id ~alias ?(client_type="unknown") ?(ttl=300.0) ?(identity_pk="") () =
    with_lock t (fun () ->
      let open Sqlite3 in
      let conn = db_open t.db_path in
      let now = Unix.gettimeofday () in
      let effective_pk = if identity_pk <> "" then identity_pk else ""
      in
      let existing_stmt = prepare conn "SELECT node_id, last_seen, ttl FROM leases WHERE alias = ?" in
      bind_text existing_stmt 1 alias |> ignore;
      let has_row = exec_prepared conn "SELECT node_id, last_seen, ttl FROM leases WHERE alias = ?" [`Text alias] in
      let _existing = if has_row then Some (Sqlite3.step existing_stmt) else None in
      let conflict_lease = ref None in
      let step_result = ref Rc.DONE in
      let rec check_existing () =
        step_result := Sqlite3.step existing_stmt;
        if !step_result = Rc.ROW then (
          let row_node_id = Sqlite3.Data.to_string_exn (Sqlite3.column existing_stmt 0) in
          let row_last_seen = Sqlite3.Data.to_string_exn (Sqlite3.column existing_stmt 1) in
          let row_ttl = Sqlite3.Data.to_string_exn (Sqlite3.column existing_stmt 2) in
          let alive = (float_of_string row_last_seen +. float_of_string row_ttl) >= now in
          if alive && row_node_id <> node_id then (
            let lease = Lease.make ~node_id:row_node_id ~session_id ~alias ~client_type ~ttl ~identity_pk () in
            conflict_lease := Some lease
          ) else
            check_existing ()
        ) else if !step_result <> Rc.DONE then
          failwith ("step error: " ^ Rc.to_string !step_result)
      in
      check_existing ();
      match !conflict_lease with
      | Some lease -> (relay_err_alias_conflict, lease)
      | None ->
        let stmt = prepare conn "INSERT INTO leases (alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(alias) DO UPDATE SET node_id=excluded.node_id, session_id=excluded.session_id, client_type=excluded.client_type, last_seen=excluded.last_seen, ttl=excluded.ttl, identity_pk=excluded.identity_pk" in
        bind_text stmt 1 alias |> ignore;
        bind_text stmt 2 node_id |> ignore;
        bind_text stmt 3 session_id |> ignore;
        bind_text stmt 4 client_type |> ignore;
        bind_double stmt 5 now |> ignore;
        bind_double stmt 6 now |> ignore;
        bind_double stmt 7 ttl |> ignore;
        bind_text stmt 8 effective_pk |> ignore;
        let rc = Sqlite3.step stmt in
        if not (Rc.is_success rc) && rc <> Rc.DONE then
          failwith ("register insert failed: " ^ Rc.to_string rc);
        let lease = Lease.make ~node_id ~session_id ~alias ~client_type ~ttl ~identity_pk:effective_pk () in
        ("ok", lease)
    )

  let identity_pk_of t ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let has_row = exec_prepared conn "SELECT identity_pk FROM leases WHERE alias = ?" [`Text alias] in
      if not has_row then None
      else
        let rc = Sqlite3.step (Sqlite3.prepare conn "SELECT identity_pk FROM leases WHERE alias = ?") in
        if rc = Rc.ROW then
          let pk = Sqlite3.Data.to_string_exn (Sqlite3.column (Sqlite3.prepare conn "SELECT identity_pk FROM leases WHERE alias = ?") 0) in
          if pk = "" then None else Some pk
        else None
    )

  let set_allowed_identity t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT INTO allowed_identities (alias, identity_pk_b64) VALUES (?, ?) ON CONFLICT(alias) DO UPDATE SET identity_pk_b64=excluded.identity_pk_b64" in
      Sqlite3.bind_text stmt 1 alias |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      let rc = Sqlite3.step stmt in
      if not (Rc.is_success rc) && rc <> Rc.DONE then
        failwith ("set_allowed_identity failed: " ^ Rc.to_string rc)
    )

  let allowed_identity_of t ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then None
      else
        let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          Some pk
        else None
    )

  let check_allowlist t ~alias ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let has_row = exec_prepared conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" [`Text alias] in
      if not has_row then `Unlisted
      else
        let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM allowed_identities WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pinned = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          if identity_pk_b64 = pinned then `Allowed else `Mismatch
        else `Unlisted
    )

  let unbind_alias t ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let before = ref false in
      let stmt = Sqlite3.prepare conn "SELECT alias FROM leases WHERE alias = ?" in
      Sqlite3.bind_text stmt 1 alias |> ignore;
      let rc = Sqlite3.step stmt in
      before := (rc = Rc.ROW);
      if !before then (
        let del = Sqlite3.prepare conn "DELETE FROM leases WHERE alias = ?" in
        Sqlite3.bind_text del 1 alias |> ignore;
        Sqlite3.step del |> ignore
      );
      !before
    )

  let check_nonce db ~ttl ~nonce ~ts =
    let cutoff = ts -. ttl in
    let conn = Sqlite3.db_open db in
    let del_stmt = Sqlite3.prepare conn "DELETE FROM register_nonces WHERE ts < ?" in
    Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
    Sqlite3.step del_stmt |> ignore;
    let has_row = exec_prepared conn "SELECT nonce FROM register_nonces WHERE nonce = ?" [`Text nonce] in
    if has_row then R.Error relay_err_nonce_replay
    else (
      let ins_stmt = Sqlite3.prepare conn "INSERT INTO register_nonces (nonce, ts) VALUES (?, ?)" in
      Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
      Sqlite3.bind_double ins_stmt 2 ts |> ignore;
      Sqlite3.step ins_stmt |> ignore;
      R.Ok ()
    )

  let check_register_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      check_nonce t.db_path ~ttl:600.0 ~nonce ~ts
    )

  let check_request_nonce t ~nonce ~ts =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let cutoff = ts -. 120.0 in
      let del_stmt = Sqlite3.prepare conn "DELETE FROM request_nonces WHERE ts < ?" in
      Sqlite3.bind_double del_stmt 1 cutoff |> ignore;
      Sqlite3.step del_stmt |> ignore;
      let has_row = exec_prepared conn "SELECT nonce FROM request_nonces WHERE nonce = ?" [`Text nonce] in
      if has_row then R.Error relay_err_nonce_replay
      else (
        let ins_stmt = Sqlite3.prepare conn "INSERT INTO request_nonces (nonce, ts) VALUES (?, ?)" in
        Sqlite3.bind_text ins_stmt 1 nonce |> ignore;
        Sqlite3.bind_double ins_stmt 2 ts |> ignore;
        Sqlite3.step ins_stmt |> ignore;
        R.Ok ()
      )
    )

  let heartbeat t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let found_lease = ref None in
      let stmt = Sqlite3.prepare conn "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk FROM leases WHERE node_id = ? AND session_id = ?" in
      Sqlite3.bind_text stmt 1 node_id |> ignore;
      Sqlite3.bind_text stmt 2 session_id |> ignore;
      let rec find_lease () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let node_id' = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let session_id' = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let client_type = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let registered_at = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4)) in
          let last_seen = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 5)) in
          let ttl = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 6)) in
          let identity_pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 7) in
          let lease = { Lease.node_id = node_id'; Lease.session_id = session_id'; Lease.alias; Lease.client_type; Lease.registered_at; Lease.last_seen; Lease.ttl; Lease.identity_pk } in
          found_lease := Some lease;
          find_lease ()
        ) else if rc <> Rc.DONE then
          failwith ("heartbeat step failed: " ^ Rc.to_string rc)
      in
      find_lease ();
      match !found_lease with
      | None ->
        let dummy = Lease.make ~node_id ~session_id ~alias:"_error" () in
        (relay_err_unknown_alias, dummy)
      | Some lease ->
        lease.Lease.last_seen <- now;
        let up_stmt = Sqlite3.prepare conn "UPDATE leases SET last_seen = ? WHERE alias = ?" in
        Sqlite3.bind_double up_stmt 1 now |> ignore;
        Sqlite3.bind_text up_stmt 2 lease.Lease.alias |> ignore;
        Sqlite3.step up_stmt |> ignore;
        ("ok", lease)
    )

  let list_peers t ?(include_dead=false) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let leases = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias, node_id, session_id, client_type, registered_at, last_seen, ttl, identity_pk FROM leases" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let client_type = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let registered_at = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4)) in
          let last_seen = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 5)) in
          let ttl = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 6)) in
          let identity_pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 7) in
          let lease = { Lease.node_id; Lease.session_id; Lease.alias; Lease.client_type; Lease.registered_at; Lease.last_seen; Lease.ttl; Lease.identity_pk } in
          let alive = (last_seen +. ttl) >= now in
          if include_dead || alive then leases := lease :: !leases;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("list_peers step failed: " ^ Rc.to_string rc)
      in
      loop ();
      !leases
    )

  let gc t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let expired_aliases = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl FROM leases" in
      let rec collect_expired () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)) in
          let ttl = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2)) in
          if (last_seen +. ttl) < now then expired_aliases := alias :: !expired_aliases;
          collect_expired ()
        ) else if rc <> Rc.DONE then
          failwith ("gc collect step failed: " ^ Rc.to_string rc)
      in
      collect_expired ();
      List.iter (fun alias ->
        let del = Sqlite3.prepare conn "DELETE FROM leases WHERE alias = ?" in
        Sqlite3.bind_text del 1 alias |> ignore;
        Sqlite3.step del |> ignore
      ) !expired_aliases;
      let live_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases" in
      let live_keys = ref [] in
      let rec collect_live () =
        let rc = Sqlite3.step live_stmt in
        if rc = Rc.ROW then (
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column live_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column live_stmt 1) in
          live_keys := (node_id, session_id) :: !live_keys;
          collect_live ()
        ) else if rc <> Rc.DONE then
          failwith ("gc live step failed: " ^ Rc.to_string rc)
      in
      collect_live ();
      let inbox_stmt = Sqlite3.prepare conn "SELECT DISTINCT node_id, session_id FROM inboxes" in
      let stale_keys = ref [] in
      let rec collect_stale () =
        let rc = Sqlite3.step inbox_stmt in
        if rc = Rc.ROW then (
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column inbox_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column inbox_stmt 1) in
          if not (List.mem (node_id, session_id) !live_keys) then
            stale_keys := (node_id, session_id) :: !stale_keys;
          collect_stale ()
        ) else if rc <> Rc.DONE then
          failwith ("gc stale step failed: " ^ Rc.to_string rc)
      in
      collect_stale ();
      let pruned = List.length !stale_keys in
      List.iter (fun (node_id, session_id) ->
        let del = Sqlite3.prepare conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" in
        Sqlite3.bind_text del 1 node_id |> ignore;
        Sqlite3.bind_text del 2 session_id |> ignore;
        Sqlite3.step del |> ignore
      ) !stale_keys;
      `Ok (List.rev !expired_aliases, pruned)
    )

  (* Phase 1 stub implementations for remaining functions *)
  let send t ~from_alias ~to_alias ~content ?(message_id=None) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v `V4) in
      let ts = Unix.gettimeofday () in
      let has_row = exec_prepared conn "SELECT alias, last_seen, ttl FROM leases WHERE alias = ?" [`Text to_alias] in
      if not has_row then
        `Error (relay_err_unknown_alias, Printf.sprintf "no registration for alias %S" to_alias)
      else
        let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl FROM leases WHERE alias = ?" in
        Sqlite3.bind_text stmt 1 to_alias |> ignore;
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let _alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)) in
          let ttl = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2)) in
          if (last_seen +. ttl) < ts then
            `Error (relay_err_recipient_dead, Printf.sprintf "alias %S is registered but lease has expired" to_alias)
          else
            let recv_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases WHERE alias = ?" in
            Sqlite3.bind_text recv_stmt 1 to_alias |> ignore;
            let rc2 = Sqlite3.step recv_stmt in
            if rc2 = Rc.ROW then
              let recv_node_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 0) in
              let recv_session_id = Sqlite3.Data.to_string_exn (Sqlite3.column recv_stmt 1) in
              let ins_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
              Sqlite3.bind_text ins_stmt 1 recv_node_id |> ignore;
              Sqlite3.bind_text ins_stmt 2 recv_session_id |> ignore;
              Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
              Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
              Sqlite3.bind_text ins_stmt 5 to_alias |> ignore;
              Sqlite3.bind_text ins_stmt 6 content |> ignore;
              Sqlite3.bind_double ins_stmt 7 ts |> ignore;
              Sqlite3.step ins_stmt |> ignore;
              `Ok ts
            else
              `Error (relay_err_unknown_alias, "recipient lease not found")
        else
          `Error (relay_err_unknown_alias, "recipient lease not found")
    )

  let poll_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let sel_stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" in
      Sqlite3.bind_text sel_stmt 1 node_id |> ignore;
      Sqlite3.bind_text sel_stmt 2 session_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step sel_stmt in
        if rc = Rc.ROW then (
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 3) in
          let ts = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column sel_stmt 4)) in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("poll_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ();
      let del_stmt = Sqlite3.prepare conn "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?" in
      Sqlite3.bind_text del_stmt 1 node_id |> ignore;
      Sqlite3.bind_text del_stmt 2 session_id |> ignore;
      Sqlite3.step del_stmt |> ignore;
      List.rev !msgs
    )

  let peek_inbox t ~node_id ~session_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts FROM inboxes WHERE node_id = ? AND session_id = ? ORDER BY id" in
      Sqlite3.bind_text stmt 1 node_id |> ignore;
      Sqlite3.bind_text stmt 2 session_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then (
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let ts = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4)) in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        ) else if rc <> Rc.DONE then
          failwith ("peek_inbox step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let send_all t ~from_alias ~content ?(message_id=None) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let now = Unix.gettimeofday () in
      let sent_to = ref [] in
      let skipped = ref [] in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v `V4) in
      let stmt = Sqlite3.prepare conn "SELECT alias, last_seen, ttl, node_id, session_id FROM leases WHERE alias != ?" in
      Sqlite3.bind_text stmt 1 from_alias |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let last_seen = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1)) in
          let ttl = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2)) in
          let alive = (last_seen +. ttl) >= now in
          if alive then (
            let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
            let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4) in
            let ins_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
            Sqlite3.bind_text ins_stmt 1 node_id |> ignore;
            Sqlite3.bind_text ins_stmt 2 session_id |> ignore;
            Sqlite3.bind_text ins_stmt 3 msg_id |> ignore;
            Sqlite3.bind_text ins_stmt 4 from_alias |> ignore;
            Sqlite3.bind_text ins_stmt 5 alias |> ignore;
            Sqlite3.bind_text ins_stmt 6 content |> ignore;
            Sqlite3.bind_double ins_stmt 7 now |> ignore;
            Sqlite3.step ins_stmt |> ignore;
            sent_to := alias :: !sent_to
          ) else
            skipped := (alias, "not_alive") :: !skipped;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("send_all step failed: " ^ Rc.to_string rc)
      in
      loop ();
      `Ok (now, List.rev !sent_to, List.map fst (List.rev !skipped))
    )

  let join_room t ~alias ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let room_stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO rooms (room_id) VALUES (?)" in
      Sqlite3.bind_text room_stmt 1 room_id |> ignore;
      Sqlite3.step room_stmt |> ignore;
      let mem_stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO room_members (room_id, alias) VALUES (?, ?)" in
      Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
      Sqlite3.bind_text mem_stmt 2 alias |> ignore;
      Sqlite3.step mem_stmt |> ignore;
      `Ok
    )

  let leave_room t ~alias ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "DELETE FROM room_members WHERE room_id = ? AND alias = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 alias |> ignore;
      Sqlite3.step stmt |> ignore;
      `Ok
    )

  let send_room t ~from_alias ~room_id ~content ?(message_id=None) ?(envelope=None) () =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msg_id = match message_id with Some id -> id | None -> Uuidm.to_string (Uuidm.v `V4) in
      let ts = Unix.gettimeofday () in
      let delivered_to = ref [] in
      let skipped = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ? AND alias != ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 from_alias |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let member_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          delivered_to := member_alias :: !delivered_to;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("send_room members step failed: " ^ Rc.to_string rc)
      in
      loop ();
      let hist_stmt = Sqlite3.prepare conn "INSERT INTO room_history (room_id, message_id, from_alias, content, ts) VALUES (?, ?, ?, ?, ?)" in
      Sqlite3.bind_text hist_stmt 1 room_id |> ignore;
      Sqlite3.bind_text hist_stmt 2 msg_id |> ignore;
      Sqlite3.bind_text hist_stmt 3 from_alias |> ignore;
      Sqlite3.bind_text hist_stmt 4 content |> ignore;
      Sqlite3.bind_double hist_stmt 5 ts |> ignore;
      Sqlite3.step hist_stmt |> ignore;
      List.iter (fun to_alias ->
        let node_stmt = Sqlite3.prepare conn "SELECT node_id, session_id FROM leases WHERE alias = ?" in
        Sqlite3.bind_text node_stmt 1 to_alias |> ignore;
        let rc = Sqlite3.step node_stmt in
        if rc = Rc.ROW then
          let node_id = Sqlite3.Data.to_string_exn (Sqlite3.column node_stmt 0) in
          let session_id = Sqlite3.Data.to_string_exn (Sqlite3.column node_stmt 1) in
          let inbox_stmt = Sqlite3.prepare conn "INSERT INTO inboxes (node_id, session_id, message_id, from_alias, to_alias, content, ts) VALUES (?, ?, ?, ?, ?, ?, ?)" in
          Sqlite3.bind_text inbox_stmt 1 node_id |> ignore;
          Sqlite3.bind_text inbox_stmt 2 session_id |> ignore;
          Sqlite3.bind_text inbox_stmt 3 msg_id |> ignore;
          Sqlite3.bind_text inbox_stmt 4 from_alias |> ignore;
          Sqlite3.bind_text inbox_stmt 5 (to_alias ^ "#" ^ room_id) |> ignore;
          Sqlite3.bind_text inbox_stmt 6 content |> ignore;
          Sqlite3.bind_double inbox_stmt 7 ts |> ignore;
          Sqlite3.step inbox_stmt |> ignore
        else
          skipped := to_alias :: !skipped
      ) !delivered_to;
      `Ok (ts, List.rev !delivered_to, List.rev !skipped)
    )

  let room_history t ~room_id ?(limit=50) =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, content, ts FROM room_history WHERE room_id = ? ORDER BY id DESC LIMIT ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_int stmt 2 limit |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let ts = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3)) in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("content", `String content); ("ts", `Float ts)] :: !msgs;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("room_history step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let dead_letter t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let msgs = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT message_id, from_alias, to_alias, content, ts, reason FROM dead_letter" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let message_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let from_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 1) in
          let to_alias = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 2) in
          let content = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 3) in
          let ts = float_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column stmt 4)) in
          let reason = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 5) in
          msgs := `Assoc [("message_id", `String message_id); ("from_alias", `String from_alias); ("to_alias", `String to_alias); ("content", `String content); ("ts", `Float ts); ("reason", `String reason)] :: !msgs;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("dead_letter step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !msgs
    )

  let list_rooms t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let rooms = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT room_id FROM rooms" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let mem_stmt = Sqlite3.prepare conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
          let rc2 = Sqlite3.step mem_stmt in
          let member_count = if rc2 = Rc.ROW then int_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column mem_stmt 0)) else 0 in
          let alias_stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
          let aliases = ref [] in
          let rec collect_aliases () =
            let rc3 = Sqlite3.step alias_stmt in
            if rc3 = Rc.ROW then
              let alias = Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0) in
              aliases := alias :: !aliases;
              collect_aliases ()
            else if rc3 <> Rc.DONE then
              failwith ("list_rooms aliases step failed: " ^ Rc.to_string rc3)
          in
          collect_aliases ();
          rooms := `Assoc [("room_id", `String room_id); ("member_count", `Int member_count); ("members", `List (List.map (fun a -> `String a) !aliases))] :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("list_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !rooms
    )

  let my_rooms t =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let rooms = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT DISTINCT room_id FROM room_members" in
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let room_id = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          let mem_stmt = Sqlite3.prepare conn "SELECT COUNT(*) FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text mem_stmt 1 room_id |> ignore;
          let rc2 = Sqlite3.step mem_stmt in
          let member_count = if rc2 = Rc.ROW then int_of_string (Sqlite3.Data.to_string_exn (Sqlite3.column mem_stmt 0)) else 0 in
          let alias_stmt = Sqlite3.prepare conn "SELECT alias FROM room_members WHERE room_id = ?" in
          Sqlite3.bind_text alias_stmt 1 room_id |> ignore;
          let aliases = ref [] in
          let rec collect_aliases () =
            let rc3 = Sqlite3.step alias_stmt in
            if rc3 = Rc.ROW then
              let alias = Sqlite3.Data.to_string_exn (Sqlite3.column alias_stmt 0) in
              aliases := alias :: !aliases;
              collect_aliases ()
            else if rc3 <> Rc.DONE then
              failwith ("my_rooms aliases step failed: " ^ Rc.to_string rc3)
          in
          collect_aliases ();
          rooms := `Assoc [("room_id", `String room_id); ("member_count", `Int member_count); ("members", `List (List.map (fun a -> `String a) !aliases))] :: !rooms;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("my_rooms step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !rooms
    )

  let room_visibility_of t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT visibility FROM rooms WHERE room_id = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rc = Sqlite3.step stmt in
      if rc = Rc.ROW then
        Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0)
      else "public"
    )

  let room_invites_of t ~room_id =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let invites = ref [] in
      let stmt = Sqlite3.prepare conn "SELECT identity_pk_b64 FROM room_invites WHERE room_id = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Rc.ROW then
          let pk = Sqlite3.Data.to_string_exn (Sqlite3.column stmt 0) in
          invites := pk :: !invites;
          loop ()
        else if rc <> Rc.DONE then
          failwith ("room_invites_of step failed: " ^ Rc.to_string rc)
      in
      loop ();
      List.rev !invites
    )

  let is_invited t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT 1 FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      let rc = Sqlite3.step stmt in
      rc = Rc.ROW
    )

  let set_room_visibility t ~room_id ~visibility =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT INTO rooms (room_id, visibility) VALUES (?, ?) ON CONFLICT(room_id) DO UPDATE SET visibility=excluded.visibility" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 visibility |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let invite_to_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "INSERT OR IGNORE INTO room_invites (room_id, identity_pk_b64) VALUES (?, ?)" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let uninvite_from_room t ~room_id ~identity_pk_b64 =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "DELETE FROM room_invites WHERE room_id = ? AND identity_pk_b64 = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 identity_pk_b64 |> ignore;
      Sqlite3.step stmt |> ignore
    )

  let is_room_member_alias t ~room_id ~alias =
    with_lock t (fun () ->
      let conn = Sqlite3.db_open t.db_path in
      let stmt = Sqlite3.prepare conn "SELECT 1 FROM room_members WHERE room_id = ? AND alias = ?" in
      Sqlite3.bind_text stmt 1 room_id |> ignore;
      Sqlite3.bind_text stmt 2 alias |> ignore;
      let rc = Sqlite3.step stmt in
      rc = Rc.ROW
    )
end
