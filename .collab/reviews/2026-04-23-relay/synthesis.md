# Relay review synthesis — 2026-04-23

## TL;DR (brutally honest)

**Worst three findings, all real and all live in production today:** (1) signed-request identity is never bound to the `from_alias` field in `/send`/`/send_all`/`/poll_inbox` bodies — any valid peer can spoof DMs as any other peer; (2) the SQLite `register` path silently overwrites TOFU identity pinning on UPSERT, so wait-for-TTL → re-register → full alias hijack; (3) `SqliteRelay` opens a fresh `db_open` per call, never closes the handle, never finalizes statements, and PRAGMAs (WAL busy_timeout) never land on the per-request conn — fd leak + silent BUSY storms under any real load. **Must land before next `git push` to origin/master:** the spoofing fix, the TOFU-overwrite fix, wire `test_relay.ml` into dune. **Can wait:** versioning, OpenAPI, metrics endpoint, WS-frame tests. Everything else is tractable in a 2-week hardening pass that folds cleanly into M1 slices.

## Ranked action table

Severity: p0 (data loss / security breach today) · p1 (will break at M1/M2 ship) · p2 (should fix, not blocking) · p3 (nice-to-have). Effort: S <1d · M 1-3d · L >3d.

| Rank | Finding | Sev | Eff | Cross-refs |
|------|---------|-----|-----|------------|
| 1 | DM spoofing: `/send`, `/send_all`, `/poll_inbox`, `/heartbeat` don't bind body `from_alias`/`session_id` to verified Ed25519 signer | p0 | S | security#1, #11; `relay.ml:2179-2198, 2660-2664, 2533-2581` |
| 2 | SQLite TOFU bypass: `register` UPSERT overwrites `identity_pk`; GC deletes binding row entirely | p0 | S | security#2, #9; `relay.ml:1014, 1225-1228`; correctness#C1 |
| 3 | `SqliteRelay`: per-request `db_open`, unfinalized statements, PRAGMAs on throwaway conn, busy_timeout dead | p0 | M | correctness#C1, C2, C5, I5; perf#C1, C2, I5; security#8; `relay_sqlite.ml:251,298,311,322,337...`; `relay.ml:943,987` |
| 4 | Blocking `Sqlite3.step` pins Lwt loop under global `Mutex.t`; no `Lwt_preemptive.detach` | p1 | M | correctness#I5; perf#C3; `relay_sqlite.ml:211`, `relay.ml:947` |
| 5 | `test_relay.ml` not in `ocaml/test/dune` — 18 core tests never execute | p0 | S (ONE-LINE) | testing#1 |
| 6 | Rate-limiter policies match endpoints (`/pubkey`, `/mobile-pair`, `/device-pair`, `/observer`) that don't exist yet — no real route is throttled | p0 | S | security#5; perf#I4; testing#9; `relay_ratelimit.ml:57-71` vs `relay.ml:2684-2794` |
| 7 | `/remote_inbox/<sid>` path traversal via `cat %s/inbox/%s.json` on remote host | p0 | S | security#3; `relay.ml:2788-2791`, `relay_remote_broker.ml:32-39` |
| 8 | Unauth body read before auth decision: unbounded `Cohttp_lwt.Body.to_string` DoS | p1 | S | security#6; perf#I4; `relay.ml:2651` |
| 9 | Invite-only rooms leak history + member lists via unauth `/list_rooms`, `/room_history` | p1 | S | security#7; perf#I2 note; `relay.ml:1805, 2067, 2513-2520` |
| 10 | `check_register_nonce` / `check_request_nonce` race (SELECT then INSERT outside txn; swallowed rc) | p1 | S | security#10; correctness#C1 (same class) |
| 11 | Bearer token comparison is structural `=`, not constant-time | p1 | S | security#4; `relay.ml:1781` |
| 12 | `relay_sqlite.ml:296-307` `identity_pk_of` reads from unbound 3rd prepared stmt → exception/500 if wired in | p0 if live / p2 if dead | S | correctness#C5 — *verify which backend is in prod first* |
| 13 | `relay_sqlite.ml:143` module-level `with_lock` swallows exceptions AND leaks mutex on exn | p1 | S | correctness#C3 |
| 14 | No per-request access log, no request-id, no `/metrics`, no structured log outside rate-limit | p1 | M | observability#C1, C2, C3, C5, I1-I7 |
| 15 | Handlers return 200 OK with `ok:false` envelope on semantic failure (no 404/409/422) | p1 | M | api#C2; `relay.ml:1731, 2188, 2316`; `respond_conflict`/`respond_internal_error` unused |
| 16 | No `/v1/` prefix — mobile M1 endpoints land on un-versioned surface | p1 | M | api#C1 |
| 17 | `/gc` is GET and mutates; `/room_history`, `/peek_inbox`, `/poll_inbox` are POST but read-only | p2 | S | api#C4, M1 |
| 18 | Unbounded list responses (`/list`, `/dead_letter`, `/list_rooms`, `/room_history`) no cursor | p2 | M | api#C5 |
| 19 | `send_all` / `send_room` N+1 INSERTs, prepare-per-iteration, inside global mutex | p2 | S | perf#I3; `relay_sqlite.ml:626, 688` |
| 20 | `leases` missing `(node_id, session_id)` index; `seen_ids` missing GC & index on `ts` | p2 | S | perf#I1; `relay_sqlite.ml:84-87, 410` |
| 21 | In-memory `rooms`/`room_invites`/`room_members` not persisted — restart wipes membership | p1 if in-mem backend is live / p2 | S | correctness#I4; `relay.ml:429-431` |
| 22 | `record_message_id` dedup LRU in-memory only; sqlite `seen_ids` DDL exists, never INSERTed | p1 | S | correctness#C7; `relay.ml:452-463` |
| 23 | Rate-limit buckets in-memory only, cleanup never scheduled | p2 | S | correctness#I3; `relay_ratelimit.ml:90-122` |
| 24 | `send_room_invite` ghost route in `auth_decision` — `/invite_room`/`/uninvite_room` diverge from other self-auth room ops | p2 | S | api#C3; `relay.ml:1827, 2764, 2770` |
| 25 | `my_rooms` returns every alias's rooms (ignores alias filter) — correctness bug | p1 | S | perf#I2 note; `relay_sqlite.ml:818-822` |
| 26 | No clean SIGTERM handler → torn WAL, torn room JSONL on Railway redeploy | p2 | S | correctness#I6; `relay.ml:2807-2851` |
| 27 | `append_room_history_to_disk` no fsync, torn tail possible | p2 | S | correctness#I2; `relay.ml:404-416` |
| 28 | `/health` doesn't probe SQLite; no `/ready`; shells `git rev-parse` per hit | p2 | S | observability#C4, m1; `relay.ml:2046-2051` |
| 29 | `relay_sqlite.ml`, `relay_ws_frame.ml` have **zero** tests | p1 | M | testing#3, #4 |
| 30 | No HTTP integration test — dispatch match entirely untested | p1 | M | testing#2 |
| 31 | `Unix.gettimeofday` hardcoded 50+ sites; no injectable clock | p2 | M | correctness#I7; testing#minor |
| 32 | `ssh -o StrictHostKeyChecking=no` disables host-key pinning | p2 | S | security#m6; `relay_remote_broker.ml:35, 65` |
| 33 | `Random.int` for UUID without `self_init` → cross-restart collisions in dedup | p2 | S | correctness#M3; `relay.ml:444-450` |
| 34 | `get_client_ip` trusts TCP peer → single-bucket cross-tenant DoS once RL fires | p2 | S | security#12 |
| 35 | No OpenAPI / JSON-Schema spec for 20+ endpoints | p3 | M | api#I6 |
| 36 | No CORS / OPTIONS handler | p3 | S | api#M3 |
| 37 | `Queue.t` dead_letter unbounded, not persisted | p3 | S | correctness#M2 |
| 38 | `!=` used for alias equality (`relay.ml:912`) | p3 | S | correctness#M6 |
| 39 | Error strings leak server env-var names to clients | p3 | S | api#I5 |
| 40 | `handle_remote_inbox` cache not tested for session-namespace bleed | p2 | S | testing#11 |

Disagreement note: reviewers diverge on whether `relay_sqlite.ml` is the live production backend or whether `relay.ml`'s inlined SqliteRelay is what ships. Correctness#C5 flags the `identity_pk_of` bug as only live if `relay_sqlite.ml` is wired. **Resolution: verify first (grep dune + `cli/c2c.ml` relay-server startup at lines ~3315-3398 which the perf reviewer referenced) before prioritizing #12.** If `relay_sqlite.ml` is dead code, delete it to kill the ambiguity.

## v1 hardening roadmap

### Phase A — P0, must land before next push to origin/master

These are the "Railway is serving a spoofable relay right now" items. Each is S-effort.

1. **S-A1 (security#1, #11): Bind verified alias to body fields.** In `make_callback` at `relay.ml:2660-2664`, propagate the verified alias from `try_verify_ed25519_request` into handlers. Reject `/send` and `/send_all` when `body.from_alias <> verified_alias`; reject `/poll_inbox` / `/heartbeat` when `body.(node_id,session_id)` isn't owned by `verified_alias`. Add allowlist for body-self-auth bootstrap routes (`/register`, `/join_room` etc. already do body-level proof).
2. **S-A2 (security#2, #9; correctness#C1): SQLite register preserves TOFU binding.** Before UPSERT at `relay.ml:1014`, `SELECT identity_pk FROM leases WHERE alias=?`; if row exists with non-empty pk differing from submitted pk, return `alias_identity_mismatch`. Separate the "binding" row from the "lease" row so GC at `relay.ml:1225-1228` no longer erases identity. Mirror the allowlist check from `InMemoryRelay.register` (`relay.ml:481-497`).
3. **S-A3 (security#3): Validate `session_id` path component.** At `relay.ml:2788-2791` regex-check against `^[A-Za-z0-9_-]{1,64}$`, reject with 400 before dispatch to `Relay_remote_broker`.
4. **S-A4 (testing#1, ONE-LINE): Register `test_relay.ml` in dune.** Add `(test (name test_relay) (modules test_relay) (libraries c2c_mcp alcotest yojson unix))` stanza to `ocaml/test/dune`. Land today regardless of other phases.
5. **S-A5 (security#5): Wire rate-limit policies to real routes.** Add policies for `/register`, `/send`, `/send_all`, `/send_room`, `/heartbeat`, `/poll_inbox`, `/room_history` in `relay_ratelimit.ml:57-71`. Key by `(ip, path)`.

Deploy after all five, run `./scripts/relay-smoke-test.sh`, push.

### Phase B — P1, fold into existing M1 slices

6. **S-B1 (correctness#C1, C2; perf#C1, C2): One persistent SQLite connection per relay.** Store `Sqlite3.db` on `t` in `create`; apply PRAGMAs on the live conn; cache prepared statements; finalize on close. Wrap all CAS ops (`register`, `heartbeat`, `gc`, nonce check) in `BEGIN IMMEDIATE … COMMIT`. → **Fold into the earliest M1 slice that touches sqlite (S2 if S2 is the storage slice).**
7. **S-B2 (perf#C3; correctness#I5): Move blocking sqlite off the Lwt loop.** Either `Lwt_preemptive.detach` per call or a dedicated writer thread with a channel. Do together with S-B1.
8. **S-B3 (security#6; perf#I4): Cap body size before reading.** Reject `Content-Length` > 256 KiB for peer routes, 1 MiB for admin, before `Body.to_string`.
9. **S-B4 (security#7): Auth the invite-only room reads.** `/list_rooms` must filter or gate; `/room_history` for `visibility=invite` rooms must check `is_room_member_alias` or `is_invited`.
10. **S-B5 (security#10): Nonce CAS via `INSERT OR ABORT`.** Treat `CONSTRAINT` rc as replay, return `err_nonce_replay`; wrap in `BEGIN IMMEDIATE`.
11. **S-B6 (security#4): Constant-time Bearer compare.** `Eqaf.equal` (or hand-rolled XOR-accumulate).
12. **S-B7 (rate-limit scope): ⚠ S4b must be re-scoped.** The current M1 S4b slice presumably wires the rate-limiter to new mobile routes. Given security#5, S4b must *also* cover the existing peer routes (`/send`, `/register`, etc.) — not just the upcoming ones. **This changes S4b's scope; flag to Max / coordinator before S4b kicks off.**
13. **S-B8 (correctness#C7): Persist dedup.** Actually INSERT into the `seen_ids` sqlite table; prune on startup and on insert. Fold into S-B1.
14. **S-B9 (correctness#I4): If memory backend is production-used, persist rooms/invites/members.** Verify first; if sqlite is the only prod backend, make this a test-only concern.
15. **S-B10 (observability#C1-C3, I7): One access-log line per request + `req_id`.** Promote `Relay_ratelimit.structured_log` to shared `Relay_log`; call at every `respond_*`; generate 8-char req_id at `make_callback` entry. Prereq to triage all future issues.
16. **S-B11 (testing#2, #3): HTTP integration harness + sqlite-backed functor.** One `test_relay_http.ml` (alcotest-lwt, ephemeral port) covering `/health`, `/register`, `/send`, `/poll_inbox`, `/remote_inbox`, `/gc` + one malformed-body case each. Functor over `RELAY` so `test_relay.ml` runs against both InMemory and Sqlite.

### Phase C — P2, standalone slices post-M1 pre-M2

17. **S-C1 (api#C1): `/v1/` prefix with legacy alias.** Mount everything at `/v1/` now; keep bare paths as aliases that log a `legacy_path` counter. **Do this before mobile M1 ships** — retrofitting after is a breaking change.
18. **S-C2 (api#C2): Real HTTP status codes.** `respond_conflict` for alias-taken, 404 for unknown recipient, 422 for semantic body errors. Keep the envelope as well (envelope is load-bearing — see api#what's strong).
19. **S-C3 (api#C4): Methods match semantics.** `/gc` → POST; `/room_history`, `/peek_inbox`, `/poll_inbox` → GET (with sig covering path+query).
20. **S-C4 (observability#C4, C5, I4): `/ready`, expanded `/health`, `/metrics` (Prom text), `/debug/bindings|ratelimit|rooms` (Bearer-gated).** Follow the priority list in observability §recommended-MVO.
21. **S-C5 (perf#I3): Batch `send_all`/`send_room` INSERTs in a transaction, prepare INSERT once outside the loop.**
22. **S-C6 (correctness#I6): SIGTERM handler → graceful shutdown → `PRAGMA wal_checkpoint(TRUNCATE)`.**
23. **S-C7 (correctness#I2): fsync room-history append; consider moving to SQLite.**
24. **S-C8 (testing#4, #5, #6, #8, #10, #11, #12): Remaining test gaps** — WS frame round-trip, signed-op window parity across 3 sites, handler negative-case matrix, nonce expiry/poisoning, room ACL, remote-broker cache namespacing, canonicalisation edge cases.
25. **S-C9 (api#C5): Cursored list responses** with `{items, next_cursor, truncated}`. Do before `/list_rooms` grows.
26. **S-C10 (correctness#I3): Schedule rate-limiter `cleanup` from `Lwt.async` loop.**
27. **S-C11 (correctness#C3): Delete the dead `with_lock` in `relay_sqlite.ml:143`.** If not deleted, fix to use `Lwt.finalize` and propagate exns.
28. **S-C12 (security#12): Proxy-aware client IP via `C2C_TRUST_PROXY` + allowlist; document default = direct peer IP.**

### Phase D — P3, later

29. OpenAPI spec generation (api#I6). CORS / OPTIONS (api#M3). Dead-letter persistence + cap (correctness#M2). `!=` → `<>` (correctness#M6). Error-string env-var hint field (api#I5). Audit-log to durable sink (security#m7). b64-shape validation on `invitee_pk` (security#m8). Canonical blob docs (security#m3, m4). UUID `Uuidm.v \`V4` for dedup (correctness#M3).

## One-line fixes — land today regardless of phase

- **Add `(test (name test_relay) (modules test_relay) …)` to `ocaml/test/dune`** (testing#1) — the 18 core InMemoryRelay tests are currently cosmetic.
- **`/gc` GET → POST** (api#C4, security#m9) — two-char edit.
- **`String.starts_with ~prefix:"/remote_inbox/"` instead of `String.sub` + length literal** (api#M2, correctness#M5) — closes the 14-char off-by-one class.
- **Replace `!=` with `<>` at `relay.ml:912`** (correctness#M6).
- **Cache `git rev-parse` result at startup** (security#m1, observability#m1) — 3-line change in `handle_health`.
- **`Unix.fsync` before `close_out` in `relay_identity.save`** (security#m2) — one line.
- **`Random.self_init ()` at startup** if `generate_uuid` stays on `Random.int` (correctness#M3).

All of these are independent, <30min each, zero cross-slice blast radius.

## Cross-slice dependencies

1. **S4b rate-limit scope expands.** S4b (mobile pairing rate limits) must also wire the limiter to existing `/send`, `/register`, `/send_all`, `/heartbeat`, `/poll_inbox`, `/room_history`. Currently zero real peer routes are limited (security#5). This is an **S4b scope change**, not a new slice — but it doubles the slice's test surface. Confirm with Max before S4b starts.
2. **S-B1 (single SQLite conn) is a prerequisite for S-B2 (detach), S-B5 (CAS nonce), S-B8 (persist dedup), S-C5 (batch fanout).** All four share the connection/txn plumbing. Do as one chunk.
3. **S-B10 (access log + req_id) is a prerequisite for S-C4 (metrics).** Without req_id, metrics can't be correlated to logs for debugging.
4. **S-C1 (`/v1/` prefix) must precede mobile M1 ship.** If M1 mobile endpoints land at bare paths, the prefix migration becomes breaking.
5. **S-A1 (alias binding) partially subsumes security#11.** Doing both together is ~same effort as doing A1 alone.
6. **Verify live backend first.** Before investing in S-B1/B2 on `relay_sqlite.ml`, confirm whether `relay.ml`'s inlined SqliteRelay or `relay_sqlite.ml` is the production path. If `relay_sqlite.ml` is dead, delete it — this also cheaply resolves correctness#C5.
7. **Testing gaps block nothing structurally, but S-A4 (dune-register) unblocks all further test work** — without it, any new `test_relay_*` additions risk landing in files that also aren't registered.

## Ownership suggestions

Based on slice history visible in git log and the swarm-lounge topology:

- **Phase A (P0 security + dune fix)**: **galaxy** — recent commits show strong touch on relay auth paths (role_designer refactor, role template, opencode defaults suggest surface-area familiarity). One-shot, high-consequence. Alternatively **coordinator1 (cairn-vigil)** since it's blocking push.
- **Phase B (sqlite connection rework + test harness)**: **jungle** — has bandwidth-shaped work history that suits multi-day refactors; S-B1/B2 are a coherent 2-3-day unit. S-B10/B11 can fan-out to any available peer.
- **Phase C (API versioning, observability, metrics)**: **ceo** or whoever Max assigns — these are discrete, small, each independently deployable. Good onboarding-shaped work for any peer.
- **Phase D**: backlog for fill-in work; no specific owner needed.
- **Max's call**: whether `relay_sqlite.ml` is production code (affects #12 severity). And whether S4b scope change is acceptable without renegotiation.

## Disagreement / conflict notes

- **Performance reviewer says** in-memory backend is fine for v1 and no critical findings there. **Correctness reviewer says** in-memory `rooms`/`invites`/`members` aren't persisted (I4) which is catastrophic on restart if in-mem is prod. Reconciliation: perf reviewer assumed sqlite-in-prod; correctness reviewer flagged "needs verification". This synthesis treats #21 as p1-if-live, p2-otherwise. **Action: verify which backend `c2c relay-server` starts with by default** (`cli/c2c.ml:3315-3398`).
- **Correctness#C5 vs perf review**: correctness flags `relay_sqlite.ml:296-307` `identity_pk_of` as exception-on-every-registered-alias. Perf review doesn't mention it. If `relay_sqlite.ml` is live, this is a p0 outage-class bug. If not live (dead duplicate of `relay.ml`'s inlined version), it's noise — delete the file.
- **API reviewer argues** for `/v1/` prefix as a critical now-or-never. **Other reviewers** treat versioning as deferred. Picked api reviewer's framing for Phase C priority because the cost of retrofitting after mobile ships is disproportionate; doing it before mobile ships costs one day.

## Source review files

- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/security.md`
- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/correctness-concurrency.md`
- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/api-design.md`
- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/observability.md`
- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/performance-scalability.md`
- `/home/xertrov/src/c2c/.collab/reviews/2026-04-23-relay/testing-coverage.md`
