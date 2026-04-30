# Finding: Sqlite3 REAL vs TEXT column type inconsistency

**Date**: 2026-05-01
**Agent**: galaxy-coder
**Severity**: High (caused cross-host mesh failure)

## Symptom
Cross-host mesh test (`alice@relay-a → bob@relay-b`) failed with:
```
HF_EXC: Sqlite3.DataTypeError("Expected TEXT or BLOB but got FLOAT <1777575380.744787>")
```
The error occurred in `SqliteRelay.send` when reading `last_seen` and `ttl` columns from the `leases` table.

## Root Cause
The `leases` table stores `last_seen`, `ttl`, and `ts` columns as **REAL** (SQLite float, 8-byte IEEE 754):
```sql
CREATE TABLE leases (
  ...
  last_seen REAL NOT NULL,   -- bind_double
  ttl       REAL NOT NULL,   -- bind_double
  ...
);
CREATE TABLE inboxes (
  ...
  ts REAL NOT NULL,          -- bind_double
  ...
);
```

However, several read paths used:
```ocaml
float_of_string (Sqlite3.Data.to_string_exn (column i))
```

`to_string_exn` raises `DataTypeError` when the column class is REAL (not TEXT/BLOB), causing crashes.

## Fix Applied
Use `Sqlite3.Data.to_float` (returns `float option`) before falling back:
```ocaml
match Sqlite3.Data.to_float (column i) with
| Some f -> f
| None -> float_of_string (Sqlite3.Data.to_string_exn (column i))
```

Fixed in:
- `SqliteRelay.send` — `last_seen` and `ttl` columns
- `SqliteRelay.poll_inbox` — `ts` column
- `SqliteRelay.peek_inbox` — `ts` column
- `SqliteRelay.check_existing` (inside `register`) — `row_last_seen`, `row_ttl` via try/catch

## Remaining Audit Scope (NOT YET FIXED)
The following still use the unsafe `to_string_exn+float_of_string` pattern on columns that may be REAL:

| Function | Columns | Status |
|----------|---------|--------|
| `send_all` | `last_seen`, `ttl`, `node_id`, `session_id` | UNSAFE |
| `gc` | `last_seen`, `ttl` | UNSAFE |
| `alias_of_session` | `node_id`, `session_id` | OK (these are TEXT) |
| `register` (direct insert path) | `registered_at`, `last_seen`, `ttl` | OK (bind_double, not read back) |

## Schema Reference
```sql
leases:       alias TEXT, node_id TEXT, session_id TEXT, client_type TEXT,
              registered_at REAL, last_seen REAL, ttl REAL,
              identity_pk TEXT, enc_pubkey TEXT, signed_at REAL, sig_b64 TEXT

inboxes:       id INTEGER, node_id TEXT, session_id TEXT,
              message_id TEXT, from_alias TEXT, to_alias TEXT,
              content TEXT, ts REAL

allowed_identities: alias TEXT PRIMARY KEY, identity_pk_b64 TEXT
```

## Recommendation
Audit all `float_of_string (Data.to_string_exn ...)` patterns across the codebase and convert to the `to_float`-then-fallback ladder. Consider adding a helper:
```ocaml
let float_of_column col =
  match Sqlite3.Data.to_float col with
  | Some f -> f
  | None -> float_of_string (Sqlite3.Data.to_string_exn col)
```
to make the pattern explicit and searchable.

## Status
- [x] Fixed: `send`, `poll_inbox`, `peek_inbox`, `check_existing`
- [ ] Audit needed: `send_all`, `gc`, and any other float-column reads

---

## Footnote: /forward and /poll_inbox is_self_auth bypass

Both `/forward` and `/poll_inbox` were added to `is_self_auth` in `auth_decision`. This bypasses header-level auth for these routes:

- **`/forward`**: peer-relay mesh uses Ed25519 header auth signed over the body, verified in the handler itself. The `auth_decision` bypass allows the request through so the handler can verify the Ed25519 proof against the peer relay's known identity key.
- **`/poll_inbox`**: Bearer token polling works on mesh topology where a relay may poll its peer's inbox without having an Ed25519 identity on that peer. Bearer auth via `C2C_RELAY_TOKEN` is sufficient for this use case.

Both bypasses are correct and intentional for cross-host mesh operation.
