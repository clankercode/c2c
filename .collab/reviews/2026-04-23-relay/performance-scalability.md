# Relay performance + scalability review — 2026-04-23

## TL;DR

The in-memory backend will comfortably serve v1 scale (dozens of
agents, a few mobile apps) without optimisation — it's a single-loop
Cohttp server with per-request `Hashtbl` lookups and that's fine.

The **SQLite backend, however, is a trap**. It opens a fresh
`Sqlite3.db_open` per request (often several per request), prepares
statements per call instead of caching them, and executes them inside
a plain `Mutex.lock` held across blocking C calls on the Lwt event
loop. PRAGMAs (WAL, busy_timeout) are set on the throwaway connection
opened at `create` and **never on the per-request connections** — so
the configured WAL mode and 5s busy timeout are effectively dead
code. This is probably already the slowest thing in the system and
will be the first bottleneck the moment the sqlite backend is used in
anger.

Plus: `register`, `heartbeat`, `poll_inbox`, `send` each call
`db_open` → prepare → step → (implicit close at GC). At a sustained
~20 rps you'd churn hundreds of MBs of C-heap connection handles per
hour.

No critical issues in the in-memory path. Several real issues in the
sqlite path, one blocking-IO-on-Lwt-loop concern that affects both.

## Expected scale

v1: ~1 relay (relay.c2c.im on Railway), a dozen-ish active agents
peering through it, hopefully a few mobile/desktop observers in the
near future. Peak <5 rps sustained, bursts maybe ~50 rps when a swarm
wakes on `send_all`. The relay does NOT need to handle 1k rps; it
does need to not fall over at 50 rps and not quadratically degrade
as rooms/members grow past ~20.

## Critical findings

### C1. SQLite: fresh `db_open` per request, no prepared-statement cache
Every public method in `SqliteRelay` / `relay_sqlite.ml` starts with
`let conn = Sqlite3.db_open t.db_path in` and then `Sqlite3.prepare`
for each statement. E.g. `relay.ml:987`, `relay_sqlite.ml:251, 298,
311, 322, 337, 352, 368, 389, 407, 446, 474, 535, 576, 603, 628,
666, 680, 689, …`. **Every** method does this. Several methods
open the DB and then prepare the same statement text twice
(`register` at `relay_sqlite.ml:255` then `257` — the first prepare
is orphaned).

Cost per request: filesystem `open(2)` on the db file, sqlite schema
lookup, prepare (parse+plan the SQL), step, then the connection
leaks until the OCaml GC frees it. This alone probably costs
>1ms/request; at peak load it dominates the critical path.

Fix: store a single `Sqlite3.db` on `t`, and either (a) keep a
statement cache keyed by SQL text, or (b) use a small connection
pool (1–2 connections is plenty for this workload).

### C2. WAL mode / busy_timeout silently disabled on real traffic
`relay.ml:943` and `relay_sqlite.ml:206` set
`PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000` on the
transient connection opened in `create` — not on the per-request
connections opened by every method. `journal_mode=WAL` on an
sqlite *database* persists, so WAL is actually on disk — that's
fine. But `busy_timeout` is **per-connection**, which means every
request uses the default (0ms), so any contending write under load
will return `SQLITE_BUSY` instantly instead of retrying.

Combined with the single process-wide `Mutex.t` serialising all
DB access, this is currently masked — but the moment anyone
introduces a second writer (replica, test harness, `sqlite3` CLI
attached), writes will fail at random.

### C3. Blocking sqlite calls on the Lwt event loop
`SqliteRelay.with_lock` uses plain `Mutex.lock` (OCaml stdlib, not
`Lwt_mutex`) and runs the callback synchronously
(`relay_sqlite.ml:211`, `relay.ml:947`). The callback calls
`Sqlite3.step`, which is a blocking C call. Because the HTTP
callback (`make_callback`, `relay.ml:2601`) is invoked directly by
Cohttp on the single Lwt loop, every sqlite call **pins the whole
server thread** until it returns. Every concurrent client waits.

At v1 scale this probably stays invisible (<1ms queries on a tiny
DB), but the architecture has no headroom: a 50ms query (e.g. a
large `/list` after a few weeks of accumulated inboxes, or a
`/send_all` fanout) will stall every other peer's heartbeat for
50ms. No backpressure signal.

For v1: leave as-is but **know this is the ceiling**. Fix when you
cross ~50 active peers: either run sqlite via `Lwt_preemptive.detach`
or move the SQLite writer to a dedicated thread with a message
queue.

## Important findings

### I1. Missing indices on very-hot columns
`inboxes` has `idx_inboxes_session(node_id, session_id)` — good.
But:

- `leases` has **no index on `node_id, session_id`**, yet
  `heartbeat` queries by that pair every time
  (`relay_sqlite.ml:410`). PK is `alias`. At ~100 registered
  peers the full scan is trivial; at 10k (never, probably) it
  hurts.
- `leases` has no index on `(last_seen+ttl)` — GC does a full
  scan, which is fine and expected.
- `room_members` PK is `(room_id, alias)`, so `WHERE room_id = ?`
  uses the PK prefix — good. But the reverse lookup in
  `my_rooms` (`SELECT DISTINCT room_id FROM room_members`) has
  no way to filter by alias in the existing query — and
  actually the current implementation (`relay_sqlite.ml:822`)
  returns EVERY alias's rooms, not the caller's. That's a
  correctness bug, not just a perf one — worth flagging.
- `seen_ids` has no index on `ts`, but GC would need it to
  expire old entries. Currently I don't see GC touching
  `seen_ids` at all — it'll grow unbounded.
- `room_history(room_id, id)` — ordering by `id DESC` with a
  `WHERE room_id=?` filter is backed by the `idx_room_history_room`
  index but sort still needs a scan of the matching rows. Fine
  at current history sizes; reconsider if `room_history` grows
  past ~10k rows per room.

### I2. `list_rooms` / `my_rooms`: classic N+1
`relay_sqlite.ml:783` and `:818` loop over rooms, and for each
room run TWO additional prepared statements (COUNT + alias
list). With N rooms and M average members that's `N*(1 + M)`
round-trips through sqlite. Rewrite as a single
`LEFT JOIN room_members GROUP BY room_id` or two queries (rooms,
then all members) joined in OCaml.

Note also that `list_rooms` does not filter out private rooms
the caller isn't invited to — not a perf concern but flagged
for the security pass.

### I3. `send_all` is N+1 INSERTs under the global mutex
`relay_sqlite.ml:626` loops live leases and does a `Sqlite3.prepare`
+ step per recipient, inside the serialising mutex. Same for
`send_room` at `:688`. At 50 peers that's 50 sequential prepare+step
cycles holding the mutex — every other request blocks for the
entire fanout.

Fix: batch into a single transaction (BEGIN/COMMIT), and prepare
the INSERT once outside the loop. Easy win.

### I4. Per-request JSON parse of entire body before auth check
`relay.ml:2651` reads the whole body via `Cohttp_lwt.Body.to_string`
unconditionally, then computes sha256, **then** runs the auth /
rate-limit decision. Rate-limit check happens first (`:2609`), good —
but the body-read is before rate-limit. A spammer sending large
bodies pays nothing; the server pays the allocation. Consider a max
body size cap (Cohttp doesn't enforce one by default).

### I5. `check_nonce` opens a new connection inside a locked section
`relay_sqlite.ml:366` uses `db_open` (not `t.db_path`'s cached
conn) AND allocates TWO statements (delete-old, insert-new) per
`/register` or `/send`. Same pattern everywhere — see C1.

## Minor / nits

- **M1. `prefix8` allocates `String.sub` every log line**
  (`relay_ratelimit.ml:54`). Not hot enough to matter; just noting.
- **M2. Rate-limiter Hashtbl is unbounded** until the
  `gc_interval=300s` cleanup runs; no bound on distinct client IPs.
  At v1 this is fine. Someone driving random source IPs via proxy
  chain could balloon it; low priority.
- **M3. `prefix` detection in `policy_of_endpoint`
  (`relay_ratelimit.ml:58`) re-slices and compares per request.** For
  5 known prefixes this is negligible; listing as a nit.
- **M4. `InMemoryRelay.Hashtbl.create 16`** for `bindings`,
  `rooms`, etc. (`relay.ml:423`) — fine, auto-grows. No issue.
- **M5. `Yojson.Safe.to_string (Yojson.Safe.from_string …)`
  round-trip in `require_field`** (`relay.ml:1854`) — serialises the
  parsed value back to string for the return type. Trivial cost,
  but surprising.
- **M6. In-memory `room_history` persistence** appends to a
  per-room JSONL file on every `send_room` (`relay.ml:404`,
  `676`, `725`, `852`) with a synchronous `open + write + close`
  per message. On the Lwt loop. Same class of issue as C3 but
  much smaller — opening a file is ~50µs. Fine at v1. Switch to
  an append-only `Out_channel` kept open per room when it starts
  to matter.
- **M7. `seen_ids` table has no GC** (noted above in I1). At
  dozen-agents scale with modest send rates this grows by a few
  hundred rows/day — not urgent but worth adding to the GC loop.
- **M8. `String.split_on_char ' ' h` for every auth check**
  (`relay.ml:1780`) — trivial, ignore.

## What's strong

- **The two-backend split is well-designed.** `RELAY` signature
  cleanly abstracts the storage; the functor
  `Relay_server(R : RELAY)` gives you zero-cost backend swap.
- **Rate limiter per-endpoint token buckets
  (`relay_ratelimit.ml`)** are the right shape for this — cheap,
  bounded work per request, reasonable defaults. Good that
  mobile-pairing routes have strict buckets.
- **The mutex guards the right invariants in-memory.** Nothing
  to do there.
- **WAL mode is at least *intended*** — a common footgun at this
  tier is missing it entirely.
- **GC loop is separate and bounded** (`Lwt_unix.sleep` +
  non-blocking scan). Idiomatic.
- **`include_dead` gate on `/list` forces admin auth**
  (`relay.ml:1810`) — prevents unauthed full-peer enumeration
  without needing pagination. Smart.

## Scope of review

Files read in full or skimmed:
- `ocaml/relay.ml` (lines 1–3211, spot-sampled
  180–940 sqlite block, 1665–2800 HTTP layer)
- `ocaml/relay_sqlite.ml` (full read)
- `ocaml/relay_ratelimit.ml` (full read)
- `ocaml/cli/c2c.ml` relay-server startup (3315–3398)
- Skimmed names only: `relay_identity.ml`, `relay_signed_ops.ml`,
  `relay_enc.ml`, `relay_remote_broker.ml` — no perf findings
  pulled from these; Ed25519 verify is one of the costlier
  per-request ops but it's a single `mirage-crypto-ec` call
  per signed request and not worth optimising at v1 scale.

Not reviewed: Cohttp/Conduit TLS path tuning, remote-broker
polling cadence, on-disk room-history format beyond M6.

Primary recommendation for v1: **fix C1+C2 together** (one persistent
connection per relay with PRAGMAs applied, reused prepared
statements) and **I3** (batch send_all/send_room in a transaction).
That's probably a day of work and removes every near-term
scalability cliff. Everything else can wait until a real load
signal appears.
