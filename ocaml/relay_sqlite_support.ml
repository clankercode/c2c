open Sqlite3

(* --- SqliteRelay helpers and DDL --- *)

let sqlite_ddl = {sql|
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
    identity_pk TEXT NOT NULL DEFAULT '',
    enc_pubkey TEXT NOT NULL DEFAULT '',
    signed_at REAL NOT NULL DEFAULT 0,
    sig_b64 TEXT NOT NULL DEFAULT '',
    opaque_host_id TEXT NOT NULL DEFAULT ''
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
    visibility TEXT NOT NULL DEFAULT 'public',
    -- B117: history readability policy, persisted separately from visibility.
    -- Default 1 (open) for compatible rollout; forced to 0 for gated/private
    -- on creation and on any visibility downgrade. Migration for older DBs
    -- (SqliteRelay.create) adds the column with DEFAULT 1 then clears it for
    -- pre-existing gated/private rooms.
    history_public INTEGER NOT NULL DEFAULT 1
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

CREATE TABLE IF NOT EXISTS room_knocks (
    room_id TEXT NOT NULL,
    requester_identity_pk_b64 TEXT NOT NULL,
    requester_alias TEXT NOT NULL,
    requested_at REAL NOT NULL,
    PRIMARY KEY (room_id, requester_identity_pk_b64)
);

CREATE TABLE IF NOT EXISTS pairing_tokens (
    binding_id TEXT PRIMARY KEY,
    token_b64 TEXT NOT NULL,
    machine_ed25519_pubkey TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    expires_at REAL NOT NULL
);
|sql}

let exec_no_rows db sql =
  let rc = Sqlite3.exec db sql in
  if Rc.is_success rc then Ok ()
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

let exec_one_row db sql =
  let result = ref None in
  let rc = Sqlite3.exec db ~cb:(fun row _ ->
    result := Some (Array.to_list row)
  ) sql in
  if Rc.is_success rc then Ok !result
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

let exec_many_rows db sql =
  let results = ref [] in
  let rc = Sqlite3.exec db ~cb:(fun row _ ->
    results := (Array.to_list row) :: !results
  ) sql in
  if Rc.is_success rc then Ok (List.rev !results)
  else Error (Printf.sprintf "exec failed: %s" (Rc.to_string rc))

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
  (try Sqlite3.finalize stmt |> ignore with _ -> ());
  has_row
