# Relay observability review — 2026-04-23

## TL;DR

The relay is **nearly blind in production**. Across 3211 LOC of `relay.ml`
there is exactly **one** call to the `Logs` library (a `Logs.warn` for
unsigned room ops) and a handful of `Printf.printf` lines (startup banner +
one `audit: admin_unbind` line + one `allowlist:` line). Every other
endpoint — `/register`, `/send`, `/send_all`, `/poll_inbox`, `/heartbeat`,
all 9 room endpoints, `/admin/unbind`, `/gc`, `/dead_letter` — logs
**nothing** on arrival, nothing on auth success, and nothing on failure.
The newly-landed `Relay_ratelimit.structured_log` is a good pattern but is
wired at exactly one call site (rate-limit-denied). `/health` exists and
reports version + git_hash + auth_mode, which is the one bright spot.
There is no `/metrics`, no `/debug/*`, no request-id correlation, no
structured access log, and no way for an operator to reconstruct a failed
request's journey from the Railway log stream. When prod breaks the
operator has `/health` and `scripts/relay-smoke-test.sh` — nothing else.

## Critical findings

**C1. Endpoint handlers log nothing.**
Locations: `/home/xertrov/src/c2c/ocaml/relay.ml:2684-2800` (the entire
route table). None of the 20+ handlers emit even a one-line access log.
An operator staring at Railway logs during an incident sees the startup
banner, occasional `audit: admin_unbind` lines if an admin fires unbinds,
and silence. 500s, 401s, 400s, signature failures, nonce replays, alias
conflicts — all invisible. This is the single biggest gap. Minimum fix:
one structured log line per request at completion with `path`,
`status`, `duration_ms`, `auth_mode` (bearer/ed25519/none),
`source_ip_prefix`, `alias_prefix` (when known), `error_code` (when
non-2xx).

**C2. No request-ID correlation.** Nothing threads a request ID through
logs. Even if logs existed, an operator could not tie a rate-limit-denied
event (`relay.ml:2611`) to the auth failure that preceded it or the
eventual SQLite write. Add an 8-char `req_id` generated at
`make_callback` entry and include it in every structured log field for
that request.

**C3. Error branches use `Logs.err`/`Printf.eprintf` zero times, but also
never log the failure at all.** For example all `respond_unauthorized`
and `respond_bad_request` sites (40+ in `relay.ml`) silently return the
JSON error to the client and leave no server-side trace. The server has
no way to know that e.g. signature-verification is failing for a
particular peer. Fix: at every `respond_*` non-2xx, emit a structured
`Logs.info` (yes, info, not err — user behavior, see I1) with the error
code and the 8-char prefixes of relevant identifiers.

**C4. `/health` does not actually check health.**
`relay.ml:2038-2057`: returns static `version`, `git_hash`, `auth_mode`.
It does **not** probe SQLite, does not report uptime, does not report
registration count, does not report last successful write, does not
indicate whether the GC loop is alive. From an orchestrator's
perspective this is a liveness probe at best, and not even that — it
returns 200 even if the DB file has been unlinked. Add a `/ready`
endpoint that does a `SELECT 1` against SQLite and returns 503 on
failure, and expand `/health` with `uptime_s`, `registrations_active`,
`last_gc_epoch`, `db_ok`.

**C5. No metrics endpoint.** There is no `/metrics`, no internal
counters, no histogram. An operator has no way to answer "how many
sends per second right now?", "how many rate-limit denials this hour?",
"is the registration count growing?", "is anyone actually using rooms?"
Prometheus text-format at `/metrics` (no auth, or Bearer-gated) is the
industry-standard minimum.

## Important findings

**I1. Log-level miscategorization risk (preventive).** Many of the
error responses are user behavior (malformed body, bad signature, nonce
replay, rate-limit trip, unknown alias) — when logging is added, these
must be `Logs.info` or `Logs.warn`, not `Logs.err`. `Logs.err` should be
reserved for "the server is broken" (SQLite failure, filesystem ENOSPC,
bind failure). The single existing `Logs.warn` at `relay.ml:2249`
("unsigned room op … safe in dev but indicates a client gap in prod")
is correctly categorized — use it as the template.

**I2. `audit: admin_unbind` uses `Printf.printf`, not `Logs`.**
`relay.ml:2077`. This is a real audit event and belongs in a structured
log with `event=admin_unbind`, `alias_prefix`, `removed=bool`,
`actor=bearer` (once actor identity is knowable). Same pattern as
`Relay_ratelimit.structured_log` — extend `structured_log` to a
relay-wide helper or inline an equivalent.

**I3. Startup banner is `Printf.printf` stdout only.**
`relay.ml:2814, 2828, 2834, 2836`. Fine for development but means the
version/auth-mode/gc-interval line isn't captured under the same `Logs`
sink that structured logs will use. Convert to `Logs.app` so a single
log sink captures everything.

**I4. No `/debug/*` introspection.** There is no way to:
  - list active observer sockets,
  - dump the `known_keys` / identity-binding table,
  - inspect the rate-limiter bucket for a specific IP,
  - see the room-membership table,
  - dump in-flight signed-op nonces.
All of these exist only as SQLite rows, reachable only by shelling into
the container. An auth-gated `GET /debug/bindings`,
`GET /debug/ratelimit`, `GET /debug/rooms` would close this gap.

**I5. SQLite-lock / EBUSY visibility is zero.** `relay_sqlite.ml` has
three `exec failed: %s` error paths (lines 153/162/171) that return
`Result.Error` to the caller. The caller's eventual 500 (if any) drops
the string on the floor — no log, no counter. If SQLite starts throwing
`SQLITE_BUSY` under load, the operator will see user-visible failures
but no server log hint. Every `Error _` return in `relay_sqlite.ml`
should fire a `Logs.warn` with the Rc code and the operation name.

**I6. Rate-limiter has one log line, zero metrics.** Good that
`structured_log` emits a JSON event on deny — but there's no per-key
deny count, no "top denied IPs", no way to see what 95% of traffic is
being denied from. The existing `structured_log` fields
(`binding_id_prefix`, `phone_pubkey_prefix`, `source_ip_prefix`) are
the right shape; just need aggregation.

**I7. Identity / signed-op failures are invisible.** `relay.ml:2154`
(Ed25519 verify fail), `relay.ml:2565` ("no identity binding"),
`relay.ml:2269` ("ts skew outside window") — all return 400/401 to the
client with no server log. A stuck client signing with the wrong key
will look to the client like "401 unauthorized" forever, and the relay
logs nothing. Add an `Logs.info` at each verify-fail site with
`alias_prefix` + `identity_pk_prefix` + `reason`.

**I8. Remote-broker shell-outs are unlogged.** `relay_remote_broker.ml`
builds commands with `Printf.sprintf` and executes them with no log of
what was run or what exit code came back. If the remote-broker hook
misfires, the operator cannot diagnose it from logs.

**I9. Smoke test is the only health story.**
`scripts/relay-smoke-test.sh` is good but fundamentally is a black-box
end-to-end check. It takes ~10 curl-level steps. There's no cheaper
in-process self-test the relay itself can run (`GET /selftest` that
runs a loopback register+send+poll inside the server) and report on.

## Minor / nits

- `relay.ml:2047` shells out to `git rev-parse` inside `/health`. On a
  hot path this is fine (cached by OS), but is an unnecessary `fork()`
  per health hit. Cache the result at startup.
- `relay.ml:2814` logs `allowlist: %d pinned identities` but the count
  is only visible once at startup — if allowlist is hot-reloaded later
  (if ever), there's no mechanism to log the new count.
- Log-volume / PII: no full aliases, tokens, or IPs are currently
  logged (because nothing is logged). The one pattern that exists
  (`Relay_ratelimit.prefix8`) is the right convention; adopt it
  everywhere new logging is added. `structured_log` currently takes
  raw source_ip and prefixes internally — good. Make sure new call
  sites do the same.
- `structured_log` truncates `reason` at 120 chars
  (`relay_ratelimit.ml:78`) — nice defensive bound, but silent. If a
  reason is ever truncated operators should see a trailing `…`.
- Startup log should include the SQLite DB path and WAL mode status
  (not currently reported).

## What's strong

- `/health` exists, reports git_hash + auth_mode — makes
  Railway-deploy verification feasible (`relay-smoke-test.sh` relies
  on this).
- `Relay_ratelimit.structured_log` (`relay_ratelimit.ml:75-88`) is a
  well-shaped JSON-log helper: fixed 8-char prefix convention,
  reason-truncation, timestamp, event name. This is the template the
  whole relay should adopt.
- The single `Logs.warn` at `relay.ml:2249` about unsigned room ops is
  correctly leveled and genuinely useful — it telegraphs a
  dev-vs-prod-drift condition without spamming err.
- `auth_mode=prod` vs `auth_mode=dev` surfaced in `/health` is a nice
  operator signal.
- `scripts/relay-smoke-test.sh` exists, tests real user paths,
  returns non-zero on failure — a good safety net post-deploy.

## Recommended minimum-viable observability set

In rough priority order — each item is small, independent, and
deployable incrementally:

1. **Per-request access log line.** One `Logs.info` in `make_callback`
   on response emit, with `req_id`, `path`, `status`,
   `duration_ms`, `auth_mode`, `source_ip_prefix`, `alias_prefix?`,
   `error_code?`. This alone recovers ~80% of operational visibility.
2. **Request-ID generation** at `make_callback` entry, propagated to
   every structured log within that request. 8-char random hex is
   enough.
3. **Promote `structured_log` out of `Relay_ratelimit`** into a shared
   `Relay_log` module; use it at every non-2xx response site and at
   all the currently-unlogged audit points (`admin_unbind`,
   `register` success, alias rebind, room create/leave, signed-op
   verify fail).
4. **`/ready` endpoint** that does `SELECT 1` against SQLite and
   returns 503 on failure; orchestrator uses `/ready` for traffic
   gating and `/health` for liveness.
5. **Expand `/health`** with `uptime_s`, `registrations_active`,
   `last_gc_epoch_s`, `db_ok:bool`, `rooms_count`,
   `dead_letter_count`. All cheap.
6. **`/metrics` (Prometheus text format)**, minimum set:
   `c2c_relay_requests_total{path,status}`,
   `c2c_relay_request_duration_seconds{path}` (histogram),
   `c2c_relay_ratelimit_denied_total{path}`,
   `c2c_relay_signature_failures_total{ctx}`,
   `c2c_relay_registrations_active`,
   `c2c_relay_rooms_active`,
   `c2c_relay_dead_letter_depth`,
   `c2c_relay_observer_connections_active`.
7. **SQLite-failure logging.** Every `Error _` from `relay_sqlite.ml`
   emits `Logs.warn` with op name + Rc. Surface `SQLITE_BUSY` as a
   dedicated metric counter because it's the most likely prod symptom.
8. **Auth-failure log at verify-fail sites.** `relay.ml:2154, 2269,
   2565` and peers — one structured `Logs.info` each with the 8-char
   prefixes and the failing reason. Distinguishes "client bug" from
   "attack attempt" in aggregate.
9. **`/debug/bindings` and `/debug/ratelimit`** (Bearer-gated).
   Read-only dumps of the identity binding table and current
   rate-limit buckets.
10. **Runbook entry** in `.collab/runbooks/` linking symptom →
    `/metrics` query / log grep / `/debug/*` endpoint. Without a
    runbook the new logs/metrics still require archaeology.

## Scope of review

Files read in full or in part:
- `/home/xertrov/src/c2c/ocaml/relay.ml` (scanned; focused reads of
  lines ~1700–1900 response helpers, 2038–2160 `/health` and
  `/register`, 2580–2700 `make_callback` and routes, 2700–2800 route
  table, 2800–2840 startup banner)
- `/home/xertrov/src/c2c/ocaml/relay_ratelimit.ml` (full read)
- `/home/xertrov/src/c2c/ocaml/relay_sqlite.ml` (grep of error paths
  at 153/162/171/540/550; not exhaustive)
- `/home/xertrov/src/c2c/ocaml/relay_identity.ml` (grep for logging —
  none found; error strings only)
- `/home/xertrov/src/c2c/ocaml/relay_signed_ops.ml` (grep — no
  logging)
- `/home/xertrov/src/c2c/ocaml/relay_enc.ml` (grep — no logging)
- `/home/xertrov/src/c2c/ocaml/relay_remote_broker.ml` (grep — shell
  commands with no logging)
- `/home/xertrov/src/c2c/scripts/relay-smoke-test.sh` (full read)

Security, performance, correctness, and architectural concerns are
explicitly **out of scope** for this file and live in the sibling
review files in this directory.
