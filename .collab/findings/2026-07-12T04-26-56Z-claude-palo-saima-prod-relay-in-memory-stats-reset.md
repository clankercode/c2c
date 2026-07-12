# Prod relay ran in-memory backend → all state (esp. /stats) reset on every deploy

- **UTC:** 2026-07-12T04:26:56Z
- **Agent:** claude-palo-saima-8fh1
- **Severity:** HIGH (silent data loss on prod relay.c2c.im; every deploy wiped stats + relay identity + durable offline inboxes)
- **Status:** RESOLVED + live-confirmed. Fix `4b45c5a0` deployed; `/data`
  proven to be a persistent volume by a fresh-container redeploy
  (`4b45c5a`→`268db20`) that preserved a live `/stats` baseline of
  `messages:1, aliases:1, machines:1`. Registration/DM on prod (POW+sign)
  succeeded on the sqlite backend, so the write path works in token mode too.

## Symptom

After deploying c2c 0.11.0 (`cc2642ac`, which added `/stats` to the relay
landing page), Max observed the live relay's `/stats` had reset to all
zeros. `curl https://relay.c2c.im/stats` → `1d/7d/28d/ever` all
`{messages:0, unique_aliases:0, unique_machines:0}`.

## Discovery / root cause

The prod relay was running the **InMemoryRelay** backend. `c2c relay
serve` defaults to `--storage memory`; the prod entrypoint never passed
`--storage sqlite`.

Why: `railway.json`'s `deploy.startCommand` **overrides** the Dockerfile
`CMD`. The Dockerfile CMD is correct — it derives `--storage sqlite
--persist-dir` from `C2C_RELAY_PERSIST_DIR`, `chown`s the `/data` volume,
and drops privileges via `setpriv`. But the railway.json override ran a
naive `c2c relay serve` with **no storage flags**. It was stripped of
`--storage sqlite` in commit `f92d347a` (2026-04-22) with the rationale
*"OCaml relay doesn't support it, falls back to deprecated Python
script."* That was true at the time; it is **stale now** — the OCaml
`SqliteRelay` backend is fully implemented and tested
(`ocaml/test/test_relay_stats.ml` + InMemory/Sqlite parity tests).

Because everything was in-memory, **every deploy reset all state.** Peers
and room membership silently repopulate (agents re-register / re-heartbeat
/ re-join on reconnect), which masked the problem — but `/stats` are
historical aggregates that nothing repopulates, so they visibly reset to
zero. The relay-server identity key (`<persist_dir>/relay-server-identity.json`)
and durable offline inboxes were also being lost each deploy.

## Key mechanics learned

- `SqliteRelay.create` takes `?persist_dir` and stores the db at
  `<persist_dir>/c2c_relay.db` (WAL). `--db-path` is **parsed but not
  plumbed into the sqlite backend** — effectively a dead flag with
  `--storage sqlite`. Use `--persist-dir`, not `--db-path`.
- `--persist-dir` alone (with default `--storage memory`) does NOT persist
  stats — InMemoryRelay keeps stats in RAM. You need `--storage sqlite`.
- The auth/POW/signed-registration layer lives in the `Relay_server`
  functor and is backend-agnostic, so switching to sqlite does not change
  token/POW/signing behavior — only storage.

## Fix

`railway.json` startCommand: added `--storage sqlite --persist-dir /data`
to all three token branches (`4b45c5a0`). Requires a persistent Railway
volume mounted at `/data` (the Dockerfile already assumes one).

Validated locally end-to-end (dev mode): serve with the flags → register 2
aliases + send 2 messages → `/stats` = 2/2/2 → kill + restart the process
against the same persist-dir → `/stats` still 2/2/2. Persistence confirmed
at the process-restart level.

## Outstanding for full closure

1. **Verify a persistent volume is mounted at `/data`** on the Railway
   `c2c` service (project `vigilant-laughter`). If none exists, `/data` is
   ephemeral and stats still reset across deploys — a volume must be
   created. (Blocked: railway CLI auth expired, needs `railway login`.)
2. **Live cross-deploy proof:** after the fix deploys, let stats
   accumulate, trigger a `railway redeploy` (fresh container), confirm
   `/stats` survives.

## Follow-up tech debt

Two entrypoints (railway.json startCommand + Dockerfile CMD) drift silently
— this bug is the receipt. Consider deleting the startCommand override and
letting the Dockerfile CMD be the single source of truth (set
`C2C_RELAY_PERSIST_DIR=/data`, ideally as a Dockerfile `ENV` default), which
also gets the `setpriv` privilege-drop the override skips (override runs as
root).
