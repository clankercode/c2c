open Sqlite3

(* --- SqliteRelay helpers and DDL --- *)

let sqlite_ddl = {sql|
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);

-- B266: durable feature / migration markers. Presence of private_reachability
-- records that this DB was upgraded under consent-gated defaults. Old binaries
-- that ignore grants still open the file (OCaml has no hard refuse without a
-- schema break); doctor/health surface the marker and refuse to claim secure
-- production state when it is absent on a post-B266 binary.
CREATE TABLE IF NOT EXISTS relay_features (
    feature TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    set_at REAL NOT NULL
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
    opaque_host_id TEXT NOT NULL DEFAULT '',
    client_version TEXT NOT NULL DEFAULT '',
    client_os TEXT NOT NULL DEFAULT '',
    -- B264: peer discovery visibility ("private" | "public"). Default private.
    discovery_visibility TEXT NOT NULL DEFAULT 'private'
);

CREATE TABLE IF NOT EXISTS inboxes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    from_alias TEXT NOT NULL,
    to_alias TEXT NOT NULL,
    content TEXT NOT NULL,
    ts REAL NOT NULL,
    -- B014: sender's PoW difficulty (leading-zero bits) at send-accept time.
    -- -1 = not recorded (relay PoW disabled / sender identity unresolved, or a
    -- send path that does not yet compute it, e.g. broadcast/room). Migration
    -- for older DBs (SqliteRelay.create) adds the column with this default.
    pow_difficulty INTEGER NOT NULL DEFAULT -1
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

-- B116: DELETE /binding/<id> revocation-proof nonces. A DEDICATED table
-- (not request_nonces) so revoke replay state is never touched by the
-- outer Ed25519 request verifier, which consumes header nonces into
-- request_nonces before signature verification. Persisted so replay
-- protection survives a restart within the freshness window.
CREATE TABLE IF NOT EXISTS revoke_nonces (
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

-- B147: usage stats backing GET /stats. stats_message_events holds one row
-- per relay-accepted message (DM /send, /send_all broadcast, /send_room,
-- inbound /forward); gc prunes rows older than the largest window (+ slack),
-- so windowed counts stay cheap. stats_totals ('messages_ever') and the
-- distinct-actor tables survive pruning, which is what makes the 'ever'
-- column meaningful. last_seen upserts let a windowed unique count be
-- "rows with last_seen >= cutoff".
CREATE TABLE IF NOT EXISTS stats_message_events (
    ts REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_stats_message_events_ts ON stats_message_events(ts);

CREATE TABLE IF NOT EXISTS stats_totals (
    key TEXT PRIMARY KEY,
    value INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS stats_seen_aliases (
    alias TEXT PRIMARY KEY,
    last_seen REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS stats_seen_machines (
    machine_id TEXT PRIMARY KEY,
    last_seen REAL NOT NULL
);

-- B149: hourly historical snapshots of the full /stats JSON (one row per
-- snapshot, appended by the server's snapshot loop; also one at startup).
-- ~9k rows/year — no pruning needed.
CREATE TABLE IF NOT EXISTS stats_snapshots (
    ts REAL NOT NULL,
    json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_stats_snapshots_ts ON stats_snapshots(ts);

-- B262/B263: recipient-issued, sender-bound contact grants. Store only the
-- SHA-256 verifier of the 32-byte secret — never the raw secret. Fresh installs
-- get these via CREATE IF NOT EXISTS; additive for existing DBs.
CREATE TABLE IF NOT EXISTS contact_grants (
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
);
CREATE INDEX IF NOT EXISTS idx_contact_grants_recipient
  ON contact_grants(recipient_identity_fp);

-- Monotonic generation survives grant-row GC and relay restart.
CREATE TABLE IF NOT EXISTS contact_grant_generations (
    recipient_identity_fp BLOB PRIMARY KEY,
    generation INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS contact_grant_message_ids (
    verifier BLOB NOT NULL,
    message_id TEXT NOT NULL,
    accepted_at REAL NOT NULL,
    PRIMARY KEY (verifier, message_id)
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

(* --- B271: process-lifetime prepared-statement cache --------------------
   Production cores on e4a988e (post-B219 persistent connection) still died in
   sqlite3_finalize with a dangling stmt pointer and a partially-overwritten
   sql buffer — classic use-after-free of the ocaml-sqlite3 stmt_wrap after a
   high-churn prepare/finalize cycle under register+WS load.

   Strategy: while a relay holds its mutex, route every prepare through a
   per-relay cache. Cached statements are OCaml-rooted for the process
   lifetime and only reset between uses; finalize is deferred to explicit
   teardown. Same-SQL re-entry while a statement is busy still needs a
   second handle (ephemeral prepare/finalize). Outside the active-cache
   window (migrations, unit tests) we keep the B219 Fun.protect finalize. *)

type stmt_cache = {
  by_sql : (string, Sqlite3.stmt) Hashtbl.t;
  busy : (string, int) Hashtbl.t;
}

let make_stmt_cache ?(size = 64) () = {
  by_sql = Hashtbl.create size;
  busy = Hashtbl.create 16;
}

let stmt_cache_size cache = Hashtbl.length cache.by_sql

let active_stmt_cache : stmt_cache option ref = ref None
let active_stmt_db : Sqlite3.db option ref = ref None

let with_active_stmt_cache cache db f =
  let prev_c = !active_stmt_cache in
  let prev_d = !active_stmt_db in
  active_stmt_cache := Some cache;
  active_stmt_db := Some db;
  Fun.protect
    ~finally:(fun () ->
      active_stmt_cache := prev_c;
      active_stmt_db := prev_d)
    f

let finalize_stmt_cache cache =
  Hashtbl.iter
    (fun _ stmt -> try ignore (Sqlite3.finalize stmt) with _ -> ())
    cache.by_sql;
  Hashtbl.clear cache.by_sql;
  Hashtbl.clear cache.busy

let with_stmt_ephemeral db sql f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> (try ignore (Sqlite3.finalize stmt) with _ -> ()))
    (fun () -> f stmt)

let with_stmt db sql f =
  let cache_opt =
    match !active_stmt_cache, !active_stmt_db with
    | Some cache, Some active when active == db -> Some cache
    | _ -> None
  in
  match cache_opt with
  | None -> with_stmt_ephemeral db sql f
  | Some cache ->
    let busy =
      match Hashtbl.find_opt cache.busy sql with Some n -> n | None -> 0
    in
    if busy > 0 then
      (* Nested use of the same SQL string while the outer handle is live —
         SQLite needs a distinct statement object. *)
      with_stmt_ephemeral db sql f
    else
      let stmt =
        match Hashtbl.find_opt cache.by_sql sql with
        | Some s ->
          (try ignore (Sqlite3.reset s) with _ -> ());
          (try ignore (Sqlite3.clear_bindings s) with _ -> ());
          s
        | None ->
          let s = Sqlite3.prepare db sql in
          Hashtbl.add cache.by_sql sql s;
          s
      in
      Hashtbl.replace cache.busy sql 1;
      Fun.protect
        ~finally:(fun () ->
          Hashtbl.remove cache.busy sql;
          (try ignore (Sqlite3.reset stmt) with _ -> ());
          (try ignore (Sqlite3.clear_bindings stmt) with _ -> ()))
        (fun () -> f stmt)

let exec_prepared db sql params =
  with_stmt db sql (fun stmt ->
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
    loop ())
