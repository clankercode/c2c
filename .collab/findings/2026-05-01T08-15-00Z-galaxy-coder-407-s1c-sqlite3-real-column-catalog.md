# Finding: #407 S1c — Sqlite3 REAL column read catalog for sweep authors

**Date**: 2026-05-01
**Agent**: galaxy-coder
**Related**: Finding #535 (original HF_EXC root cause), #407 S1a/S1b (fixes applied)
**Severity**: Medium (latent bugs; crashes on REAL schema)

## Context

`Sqlite3.Data.to_string_exn` raises `DataTypeError` when the column class is REAL
(not TEXT/BLOB). All tables in the relay schema use `bind_double` for timestamp/lease
columns, so every read of those columns must use the `to_float`-first pattern or crash.

This finding is the authoritative catalog for the next sweep author: every call site
is enumerated with FIXED/UNFIXED status, exact line numbers, and the fix recipe.

---

## Schema Reference (source of truth from `sqlite_ddl` in `relay.ml:204-263`)

```sql
leases:         alias TEXT, node_id TEXT, session_id TEXT, client_type TEXT,
                registered_at REAL,   -- bind_double
                last_seen     REAL,   -- bind_double
                ttl           REAL,   -- bind_double
                identity_pk   TEXT,
                ...

inboxes:        id INTEGER, node_id TEXT, session_id TEXT,
                message_id TEXT, from_alias TEXT, to_alias TEXT, content TEXT,
                ts REAL                  -- bind_double

room_history:   id INTEGER, room_id TEXT, message_id TEXT,
                from_alias TEXT, content TEXT,
                ts REAL                  -- bind_double

dead_letter:    id INTEGER, message_id TEXT, from_alias TEXT, to_alias TEXT,
                content TEXT,
                ts REAL,                 -- bind_double
                reason TEXT
```

---

## Complete Call-Site Catalog

Pattern: `float_of_string (Data.to_string_exn ...)` — UNSAFE on REAL columns.
Fix: `to_float`-first ladder:
```ocaml
match Sqlite3.Data.to_float col with
| Some f -> f
| None -> float_of_string (Sqlite3.Data.to_string_exn col)
```

### FIXED (8 locations)

| Function | Lines | Columns | Fix commit |
|----------|-------|---------|------------|
| `check_existing` (inside `register`) | 1436-1437 | `last_seen`, `ttl` (REAL) | S1a `cff2448b` |
| `send` | 1865-1873 | `last_seen`, `ttl` (REAL) | S1a `cff2448b` |
| `gc` | 1794-1801 | `last_seen`, `ttl` (REAL) | S1b `c2b939cf` |
| `poll_inbox` | 1914-1917 | `ts` (REAL) | S1a `cff2448b` |
| `peek_inbox` | 1946-1949 | `ts` (REAL) | S1a `cff2448b` |
| `send_all` | 1973-1981 | `last_seen`, `ttl` (REAL) | S1b `c2b939cf` |
| `gc` (live alias prune) | 1816-1818 | `last_seen`, `ttl` (REAL) | S1b `c2b939cf` |
| `gc` (forward) | 1832-1834 | `last_seen`, `ttl` (REAL) | S1b `c2b939cf` |

### UNFIXED (11 locations)

| Function | Lines | Columns | Table | Priority |
|----------|-------|---------|-------|----------|
| `heartbeat` | 1732-1734 | `registered_at`, `last_seen`, `ttl` | `leases` | HIGH |
| `list_peers` | 1768-1770 | `registered_at`, `last_seen`, `ttl` | `leases` | HIGH |
| `check_existing` (inside `register`) | 1436-1437 | `last_seen`, `ttl` — try/catch workaround in place but raises+recovers | `leases` | MED |
| `query_messages_since` | 1544 | `ts` | `inboxes` | HIGH |
| `room_history` | 2092 | `ts` | `room_history` | HIGH |
| `dead_letter` | 2114 | `ts` | `dead_letter` | HIGH |
| `alias_of_session` (inside `register`) | ~1420s | `node_id`, `session_id` — **TEXT only, SAFE** | `leases` | NONE |

### Notes on UNFIXED items

**`heartbeat` (line 1717)**: Reads `registered_at`, `last_seen`, `ttl`. Used when a node sends a heartbeat to refresh its lease. Crash would take down the relay for that node's traffic.

**`list_peers` (line 1755)**: Reads all three REAL columns. Used by the relay's peer enumeration. Crash would break `list_peers` HTTP responses.

**`check_existing` try/catch (line 1431)**: The current code wraps `to_string_exn` in try/catch, catches `DataTypeError`, and treats the row as non-conflicting. This means a REAL column on a conflict row causes silent exception-then-retry per row — slow but not fatal. Fixing to the `to_float` ladder would eliminate the exception entirely.

**`query_messages_since` (line 1524)**: Reads `ts` from `inboxes`. Used for history queries. Crash would break message-history retrieval.

**`room_history` (line 2079)**: Reads `ts` from `room_history`. Used by `/room_history` endpoint.

**`dead_letter` (line 2102)**: Reads `ts` from `dead_letter`. Used by `/dead_letter` endpoint.

---

## `alias_of_session` — SAFE

`alias_of_session` (inside `register`, ~1420s) reads `node_id` (col 0) and `session_id` (col 1) from `leases`. Both are `TEXT` columns. `to_string_exn` is correct here. No change needed.

---

## All 19 grep hits annotated

```
relay.ml:1436  check_existing   last_seen    REAL  FIXED    to_float-first
relay.ml:1437  check_existing   ttl          REAL  FIXED    to_float-first
relay.ml:1544  query_msgs_since ts           REAL  UNFIXED  ← needs fix
relay.ml:1732  heartbeat        registered_at REAL  UNFIXED  ← needs fix
relay.ml:1733  heartbeat        last_seen     REAL  UNFIXED  ← needs fix
relay.ml:1734  heartbeat        ttl           REAL  UNFIXED  ← needs fix
relay.ml:1768  list_peers      registered_at REAL  UNFIXED  ← needs fix
relay.ml:1769  list_peers      last_seen     REAL  UNFIXED  ← needs fix
relay.ml:1770  list_peers      ttl           REAL  UNFIXED  ← needs fix
relay.ml:1796  gc (expired)     last_seen     REAL  FIXED    to_float-first
relay.ml:1801  gc (expired)     ttl           REAL  FIXED    to_float-first
relay.ml:1868  send             last_seen     REAL  FIXED    to_float-first
relay.ml:1873  send            ttl           REAL  FIXED    to_float-first
relay.ml:1917  poll_inbox      ts           REAL  FIXED    to_float-first
relay.ml:1949  peek_inbox      ts           REAL  FIXED    to_float-first
relay.ml:1976  send_all        last_seen     REAL  FIXED    to_float-first
relay.ml:1981  send_all        ttl           REAL  FIXED    to_float-first
relay.ml:2092  room_history    ts           REAL  UNFIXED  ← needs fix
relay.ml:2114  dead_letter     ts           REAL  UNFIXED  ← needs fix
```

---

## Next Sweep Author Checklist

- [ ] Apply `to_float`-first ladder to `heartbeat` (3 columns)
- [ ] Apply `to_float`-first ladder to `list_peers` (3 columns)
- [ ] Replace try/catch workaround in `check_existing` with `to_float`-first ladder
- [ ] Apply `to_float`-first ladder to `query_messages_since` (1 column)
- [ ] Apply `to_float`-first ladder to `room_history` (1 column)
- [ ] Apply `to_float`-first ladder to `dead_letter` (1 column)
- [ ] Run `dune runtest` — all tests pass
- [ ] Verify cross-host mesh still works after fixes

---

## Status

- Finding #535 (root cause + first 4 fixes): FILED
- S1a (send/poll_inbox/peek_inbox/check_existing): FIXED + peer-PASS
- S1b (send_all/gc): FIXED + peer-PASS
- S1c (this catalog): COMPLETE — this finding
- S1d (remaining 6 functions): PENDING next sweep author
