# B271: Residual SIGSEGV post-B219 — still sqlite3_finalize UAF (stmt cache fix)

## Symptom
Production relay v0.14.1 `git=e4a988e` (B219 ancestor) still dies with
`child_signaled status=139 signal_number=11 core_dumped=1` every ~4–8 min.
Heartbeat shows `peers=0` while heap/RSS climb (~18→33+ MB). Edge surfaces as
502 (primer for B270 WS reconnect DoS).

## Core evidence (Railway SSH, 2026-07-23)
- Core: `/data/relay-diagnostics/cores/core` (68 MB)
- Binary: `/usr/local/bin/c2c` build 2026-07-22 git=e4a988e
- gdb:
  ```
  #0 sqlite3_finalize
  #1 caml_sqlite3_stmt_finalize (sqlite3_stubs.c:903)
  #3 Relay_sqlite_support.exec_prepared finally (relay_sqlite_support.ml:238)
  #6 relay.ml:2417 register lease SELECT
  #8 handle_register
  ```
- `stmtw->stmt = 0x55a9db4dc5d1` — unmapped, odd address (dangling)
- SQL buffer partially overwritten (first 8 bytes of "SELECT n…" replaced by a
  pointer); rest of SQL intact → classic free/reuse of stmt_wrap / sql alloc
- DB integrity_check: ok; THREADSAFE=1; **7662 leases** in `secure_leases_v2`
  (private default → heartbeat `peers=0` is misleading)
- Second thread: Lwt unix worker pool idle (not concurrent sqlite)

## Root-cause hypothesis
B219 fixed **per-op `db_open` never closed** + missing finalize. Residual crash
is still in `sqlite3_finalize`, but on the **persistent** connection: high-churn
prepare/finalize under `/register` + other load leaves a dangling
`stmt_wrap.stmt` (and freed sql buffer) by the time Fun.protect's finally runs.
Not lease-path-only (peers=0 public); register traffic + WS storm still hit DB.

## Fix (this branch)
1. **Process-lifetime prepared-statement cache** (`Relay_sqlite_support`): under
   `with_lock`, `with_stmt`/`exec_prepared` **reset** cached stmts instead of
   finalize; statements stay OCaml-rooted until `close`.
2. Same-SQL re-entry while busy → ephemeral prepare/finalize (rare).
3. `Sqlite3.db_open ~mutex:\`FULL`.
4. Pairing token SQL routes through shared `with_stmt`.
5. Heartbeat: `leases=` + `stmts=` fields so private-default no longer hides
   lease table size.
6. Supervisor ledger: `corescore` → `cores_<name>` (safe_id strips `/`).

## Residual risk
- Ephemeral finalize path still exists (migrations, reentrant same SQL, tests
  without active cache). Far colder than /register hot path.
- Production confirmation requires deploy + multi-hour clean window (no 139).
- 7662 dead/private leases with `gc: disabled` still grow load — separate ops
  concern.
- B270 client/server storm controls still needed independently.

## Tests
- `test_relay_sqlite_b271_stmt_cache_survives_gc_pressure` (register+nonce under
  forced full_major; cache bounded)
- Existing B219 stress / nonce / mixed-ops tests still green
- Heartbeat formatter unit tests updated for leases=/stmts=
