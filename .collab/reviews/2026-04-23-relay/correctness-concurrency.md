# Relay correctness + concurrency review — 2026-04-23

## TL;DR

The relay has two parallel implementations (in-memory `RelayImpl` in
`relay.ml` and `SqliteRelay` in both `relay.ml` and `relay_sqlite.ml`).
The in-memory side is internally consistent: all mutable state sits behind
one `Mutex.t` with a `Fun.protect`-based `with_lock`, and critical sections
read-then-write atomically. The SQLite side, however, is broken in several
ways: every call re-opens the DB (`Sqlite3.db_open` on each op), statements
are prepared but never finalized (steady leak), compare-and-swap operations
(register alias-conflict check, nonce check, gc) are multi-statement on a
fresh connection without `BEGIN…COMMIT` — they rely on the in-process
`Mutex.t`, which only serializes within one process. A second relay
process or a crash mid-op loses atomicity. There are also blocking
`Unix.open_process_in` / `Thread.delay` paths called from Lwt handlers
that stall the event loop, and a module-level `with_lock` in
`relay_sqlite.ml` that silently swallows exceptions while still returning
success-shaped `Ok` values. Crash recovery for rate-limit buckets,
register/request nonces (in-memory variant), dedup LRU, and room
membership (memory variant, not persisted) is non-existent — a relay
restart reopens the replay window and drops room joins.

## Critical findings

### C1. SqliteRelay.register: `SELECT then UPDATE` not in a transaction
`ocaml/relay.ml:984-1028`, `ocaml/relay_sqlite.ml:248-294`.
The alias-conflict check reads `leases` for the alias, then conditionally
`INSERT … ON CONFLICT … DO UPDATE`. Both statements execute on a
connection that has no `BEGIN IMMEDIATE` or `BEGIN EXCLUSIVE` around them.
Scenario: two relay processes (or a second thread opening its own
connection — e.g. the GC loop in `gc_loop` at `relay.ml:2799`) race on the
same alias. Process A reads "no live lease" → process B reads same →
both INSERT/UPDATE; last writer wins and silently steals the alias from
the first registrant, whose lease is now attached to someone else's
`node_id`/`identity_pk`. The in-process `Mutex.t` gives no protection
across DB connections.
**Fix**: wrap register in `BEGIN IMMEDIATE; … ; COMMIT;` or use a single
`INSERT … ON CONFLICT(alias) WHERE last_seen+ttl < now DO UPDATE …` with
the conflict condition in SQL. Do the same for `heartbeat`
(`relay_sqlite.ml:405-442`), which also does SELECT then UPDATE.

### C2. SqliteRelay re-opens the DB on every call and leaks statements
`relay_sqlite.ml` lines 251, 298, 311, 322, 337, 352, 368, 389, 407, 446,
474, 535, 576, 604, 628, 667, 680, 690, 739, 762, 785, 821, 855, 866,
885, 895, 904, 913, 922 (and mirrored in `relay.ml:987` etc.).
Every method does `let conn = Sqlite3.db_open t.db_path in …` but never
`db_close` it, and every `Sqlite3.prepare` result is stepped and thrown
away without `finalize`. Under load this leaks file descriptors,
prepared-statement memory, and shared-cache entries. Also, several
functions prepare the same SELECT twice (`identity_pk_of` at
`relay.ml:1036` etc., `relay_sqlite.ml:302-306` prepares the statement
three times on one call path and steps them independently so the column
read is from a *different* statement than the `has_row` probe — see C5).
**Fix**: hold one `Sqlite3.db` handle on `t`, `finalize` every `prepare`
in a `Fun.protect`, or switch to `caqti-lwt.unix` which handles both.

### C3. `relay_sqlite.ml:143` `with_lock` swallows exceptions
```
let with_lock m f =
  Mutex.lock m;
  Lwt.return (try Ok (f ()) with e -> Error e) >>= fun res ->
  Mutex.unlock m;
  Lwt.return res
```
Any exception raised by `f` is boxed into `Error` and then the result
`Ok/Error e` is returned. Callers up the stack destructure as if the
critical section succeeded; the Error path discards `e` entirely (it's
assigned to `res` and `res` is returned as `Lwt.t`, so upstream sees an
`Error` value but none of the call sites in `relay_sqlite.ml` actually
use that module-level helper — they use the synchronous `SqliteRelay.
with_lock` at :211). Dead code that's easy to wire up by mistake; worse,
if an exception *does* escape `Sqlite3.step` via `failwith`, `Mutex.
unlock` is skipped and the mutex is left held forever (deadlock on next
request).
**Fix**: delete the module-level `with_lock`; or use `Lwt.finalize` /
`Fun.protect` so `Mutex.unlock` always runs; and propagate the exception
(`Lwt.fail e`) instead of swallowing.

### C4. Blocking `Unix.open_process_in` + `Thread.delay` in the Lwt process
`relay_remote_broker.ml:41,71,119-137`.
`fetch_inbox` and `list_remote_sessions` shell out to `ssh` with a
synchronous `Unix.open_process_in`, blocking until the SSH handshake
returns — seconds under normal conditions, forever if the remote is
unresponsive and StrictHostKeyChecking defaults hang. This runs on a
plain `Thread.create`, which is fine in isolation, but `poll_once` is
invoked from `start_polling` on a POSIX thread without any GIL-style
protection against the Lwt main thread; meanwhile every sqlite call
executes on the Lwt main thread under the same `Mutex.t` used by
`SqliteRelay`, so if any relay code ever calls into remote-broker paths
from the Lwt handler it will block the entire event loop.
**Fix**: use `Lwt_process.pread` (non-blocking) and `Lwt_unix.sleep`; or
at minimum document that `start_polling` must run on its own preemptive
thread and never interact with the Lwt state.

### C5. `identity_pk_of` (sqlite) reads from the wrong prepared statement
`relay_sqlite.ml:296-307`.
```
let has_row = exec_prepared conn "SELECT identity_pk …" [`Text alias] in
if not has_row then None
else
  let rc = Sqlite3.step (Sqlite3.prepare conn "SELECT identity_pk …") in
  if rc = Rc.ROW then
    let pk = … (Sqlite3.column (Sqlite3.prepare conn "…") 0) …
```
Three separate prepared statements: one to probe `has_row`, one to
step, and a *third* to read the column. The third is unbound (no
`bind_text` for alias) and has never been stepped to ROW — `Sqlite3.
column` on a non-ROW statement returns `Data.NULL` and `to_string_exn`
raises. Result: any caller that hits a registered alias triggers an
exception, which `with_lock` converts to a 500. Likely masked only
because `relay.ml` has its own copy (`relay.ml:1030-1043`) that's
slightly less wrong. Needs verification whether `relay_sqlite.ml` is
wired into the running binary or is dead code — if live, this is a
hard outage for signed requests.
**Fix**: one prepared statement, bind once, step once, read columns,
finalize.

### C6. `check_nonce_in` (in-memory) is O(n) scan every check + no cap
`relay.ml:555-561`.
Every nonce submission iterates the full `register_nonces` or
`request_nonces` Hashtbl to collect expired keys, then checks membership.
Under sustained signed-request load the scan cost grows with traffic
until the TTL (120 s / 600 s) evicts. More importantly, there is no
upper bound — a burst of unique nonces within TTL grows the table without
limit and a client whose clock is stuck in the future can keep the
cutoff from advancing. Crash recovery: on relay restart the tables are
empty, so the entire replay window reopens for TTL seconds.
**Fix**: piggyback eviction on insertion via a bounded LRU (like the
`seen_ids_fifo` pattern at `relay.ml:456-461`), and persist register
nonces to the same SQLite DB (there's already a `register_nonces` table
— it's just only used by the sqlite backend).

### C7. `record_message_id` dedup LRU is in-memory only
`relay.ml:452-463` (and the sqlite backend has `seen_ids` table declared
at `relay_sqlite.ml:84-87` but no code inserts into it — grep shows only
DDL, no INSERT). On relay restart the dedup window empties and a
retrying client's message `message_id` is accepted as "new", delivered
again, and the idempotency contract is broken. Dedup window is 10 000
messages; at current swarm volume that's hours — on a restart loop this
will duplicate.
**Fix**: persist `seen_ids` with `ts` and prune on startup + on insert;
make `record_message_id` actually use the sqlite table in the sqlite
backend.

## Important findings

### I1. GC runs on a fresh DB connection, racing register/send
`relay.ml:2799-2803`, `relay_sqlite.ml:472-530`.
`gc_loop` launches via `Lwt.async` and inside calls `R.gc`, which (sqlite
backend) opens its own connection and does three iterative SELECTs
followed by DELETEs. In between collecting `expired_aliases` (line 477)
and running the DELETE at line 491-493, a concurrent `register` or
`heartbeat` could touch the row and revive the lease. Mutex protection
exists in-process, but if a second relay runs (or the in-memory + sqlite
backends share state incorrectly), the window is real. Also: on gc
failure, `try … with _ -> ()` at `relay.ml:2801` swallows the error
silently — no logging, so a chronic gc failure is invisible.
**Fix**: wrap gc in `BEGIN IMMEDIATE`; log `_` as `Logs.err`.

### I2. `append_room_history_to_disk` write-without-rename
`relay.ml:404-416`. Appends JSONL to `rooms/<id>.jsonl` via
`open_out_gen [Open_creat; Open_append; Open_wronly]` then `close_out`.
On crash mid-write you get a torn final line; `load_room_history_from_
disk` at :391-395 swallows Yojson parse errors per-line so a torn tail
is tolerated for that line, but a line containing a fragment plus the
next startup's first append can produce a single corrupted JSON line
with no recovery path. No `fsync` of the file, no `fsync` of the parent
dir after `mkdir`. Under kernel crash, recent history vanishes even
though the room members think it was delivered.
**Fix**: `Unix.fsync` after write; strongly consider moving room history
into the sqlite DB so it shares a WAL with everything else.

### I3. `rate_limiter` buckets survive in memory only
`relay_ratelimit.ml:90-120`. `Hashtbl` of buckets keyed by client IP,
protected by an internal `Mutex.t`. Relay restart wipes all buckets, so
a caller who just hit their limit gets a fresh burst of 10 `/mobile-pair`
requests immediately on reconnection. Also the `cleanup` function (line
122) is never called from anywhere in the codebase I can see — the
`gc_interval` field is stored but no timer fires it (the `create` at
`relay.ml:2815` does pass `~gc_interval:300.0` but nothing starts a
reaper). The table grows unbounded across the server's lifetime.
**Fix**: schedule `cleanup` from an `Lwt.async` loop; acceptable to
leave persistence out for v1 but document it.

### I4. `room_invites`, `room_members`, `rooms` (memory backend) never persisted
`relay.ml:429-431`. Invites and membership live purely in the in-memory
`RelayImpl.t` Hashtbls, and `create` at :418 only reloads `room_history`
from disk. A relay restart on the memory backend silently kicks every
member out of every room and loses every invite — clients next `send_
room` gets `not_a_member` or `not_invited`. Needs verification whether
production runs the sqlite backend (where this is persisted via the
`room_members` / `room_invites` tables); if so this is a trap for
development use only.

### I5. `Mutex.t` held across `Sqlite3.exec` is a deadlock surface
`relay_sqlite.ml:143-147`, `relay.ml:948-949`.
SQLite uses `busy_timeout = 5000` (5 s). If another writer (another
process, another connection on the GC path, a WAL checkpoint) holds the
DB lock for longer, `Sqlite3.step` returns `BUSY` after 5 s — the code
at :290 / :316 / :428 etc. treats `not Rc.is_success && rc <> DONE` as
`failwith`, which unwinds through `Fun.protect` (fine, unlocks mutex)
and bubbles out as a 500. But the same 5 s window is the entire request
blocking on the global `Mutex.t`, so one slow request stalls every
other relay request behind it.
**Fix**: drop the in-process Mutex and rely on SQLite's WAL + `BEGIN
IMMEDIATE` for serialization; or use `Lwt_preemptive.detach` so the
blocking step doesn't pin the Lwt thread.

### I6. No clean shutdown path
`relay.ml:2807-2851`. `start_server` returns the Lwt promise from
`Cohttp_lwt_unix.Server.create` and never installs a SIGTERM handler.
On shutdown: in-flight requests are cut mid-send, WAL may not be
checkpointed, the `gc_thread` from `Lwt.async` keeps firing until the
process exits, room history append that's mid-write may be torn (see
I2). Railway redeploys send SIGTERM then SIGKILL 30 s later.
**Fix**: `Lwt_unix.on_signal Sys.sigterm` to set a shutdown flag, stop
accepting new connections, `Lwt.join` in-flight handlers with a bounded
timeout, then run a final `PRAGMA wal_checkpoint(TRUNCATE)`.

### I7. Hardcoded `Unix.gettimeofday ()` everywhere
`relay.ml:144, 148, 152, 268, 600, 667, …` (50+ sites),
`relay_ratelimit.ml:22, 26, 45, 77, 124`, `relay_sqlite.ml:125, 129,
…`. No injectable clock. Tests can't exercise TTL edges, nonce-window
boundaries, rate-limit refill without `Unix.sleep`. The module-level
`get_now` in `relay_sqlite.ml:141` hints at an intent but is never used.
**Fix**: thread a `now:(unit -> float)` parameter through `create`; use
it everywhere.

### I8. `try … with _ -> ()` hides real errors
`relay.ml:395, 416, 2591, 2598, 2801, 2549` (parse ts), and `relay_
remote_broker.ml:61, 82, 122-125`. Several are appropriate (best-effort
JSON line parse), but the `get_client_ip` catch-all will mask an
`EBADF` from a closed fd; `gc_loop`'s `with _ -> ()` hides persistent
corruption; remote_broker's `with _ -> []` turns an ssh auth failure
into "zero sessions", which silently stops all cross-broker delivery
with no alert.
**Fix**: log at `Logs.warn` or better; keep the best-effort return
value only for the parse sites where errors are structurally
unavoidable.

## Minor / nits

### M1. `check_existing` recursion in register
`relay_sqlite.ml:261-275`, `relay.ml:995-1007`. Recurses through all
rows for one alias, but `alias` is a PRIMARY KEY so there's at most one
row — the loop can never step to a second ROW. Dead recursion that
confuses the reader; replace with a single `if rc = ROW then … else if
rc <> DONE then failwith …`.

### M2. `Queue.add dl t.dead_letter` unbounded
`relay.ml:609, 617, 684, 738, 821 (approx)`. Dead-letter queue is a
plain `Queue.t` with no cap, not persisted. Leaks memory under sustained
failure; lost on restart.

### M3. `Random.int` (non-cryptographic) for UUIDs
`relay.ml:444-450`. `generate_uuid` uses `Random.int 16`, which on
OCaml 4.x is predictable without a `Random.self_init ()`. Not a crypto
concern for dedup keys, but colliding UUIDs across relay restarts
break `record_message_id`. Use `Uuidm.v `V4` as `relay_sqlite.ml:536`
does.

### M4. `list rooms` aliases list reversal bug
`relay_sqlite.ml:808-809`, `:843-844`. `aliases := alias :: !aliases`
but never `List.rev` before embedding into ``List (List.map…)`` — so
member list order flips on every call. Cosmetic, but tests that compare
membership by order will be flaky.

### M5. `String.length path > 14 && String.sub path 0 14 = "/remote_inbox/"`
`relay.ml:2788`. Off-by-one-friendly prefix check; a `String.starts_
with ~prefix:"/remote_inbox/" path` from OCaml 4.13+ is safer.

### M6. `!=` used for alias comparison
`relay.ml:912`: `Hashtbl.replace t.rooms _room_id (List.filter ((!=) alias) members)`. `!=` is physical inequality. Works by accident when the
strings are interned (string literals) but *will* retain a string that
was built by `^` or deserialization even when structurally equal. Use
`<>`.

## What's strong

- In-memory `RelayImpl` uses a single mutex consistently and avoids
  read/write tearing; `record_message_id` + `seen_ids_fifo` is a clean
  bounded LRU pattern (`relay.ml:452-463`).
- `TokenBucket` in `relay_ratelimit.ml` is textbook correct: refill,
  decrement, and `last_seen` touch all happen within the internal mutex.
- `ed25519` signature verification (`try_verify_ed25519_request`,
  `relay.ml:2534-2581`) threads Result through every step and never
  falls through to success on an error branch.
- `append_room_history_to_disk`'s JSONL format + per-line parse
  tolerance (`relay.ml:391-395`) is the right shape for crash recovery
  even though the fsync is missing.

## Scope of review

Files read: `relay.ml` (spot-read 1-500, 540-700, 930-1200, 2540-2852),
`relay_sqlite.ml` (full), `relay_ratelimit.ml` (full), `relay_remote_
broker.ml` (full). `relay_identity.ml`, `relay_signed_ops.ml`, and
`relay_enc.ml` were in scope but the time budget went to the concurrency
hotspots above; they are pure-crypto wrappers whose correctness mostly
rides on upstream `mirage-crypto-ec` — spot-checking recommended in a
follow-up but no red flags visible from the call-site usage in
`relay.ml`. Performance, security (authn/authz policy, replay-window
sizing, TLS config), and deployment concerns deferred to sibling
reviews.
