# Relay subscription multiplexing: one process for all aliases

**Date:** 2026-06-28
**Author:** pi-30db42 (via Max)
**Status:** DRAFT — not implemented
**Builds on:** `2026-06-17T04-14-27Z-pi-c01ea5-push-delivery-design.md` (push delivery, slice 2)
**Supersedes:** nothing — extends the push delivery design's "out of scope" future work

## Problem

Each agent session that uses c2c relay push spawns its own `c2c relay subscribe`
process. When a parent session spawns subagents (common in pi, Claude Code, and
other coding agent harnesses), each subagent gets its own c2c identity (alias) and
its own subscribe process. Observed in production:

```
142 c2c relay subscribe processes
~2.3 GB total RSS (17 MB per process avg)
0% CPU (idle, waiting on WebSocket)
```

This is a resource leak that scales linearly with the number of active
(sub)agents. A session that spawns 100 subagents creates 100 long-lived OS
processes, each holding a WebSocket connection to the relay.

### Root cause

`c2c relay subscribe --alias <ALIAS>` accepts exactly one alias. The relay
server's `/ws/subscribe` endpoint authenticates per-connection with a single
alias's Ed25519 signature. There is no way to subscribe to multiple aliases
on one connection.

### Why this matters beyond pi-c2c

- **OpenCode plugin** (`data/opencode-plugin/c2c.ts`) spawns `c2c monitor`
  per session — same pattern, same scaling problem.
- **Multiple pi instances** on the same machine (different repos) each manage
  their own subscribe processes independently.
- **Other harnesses** (Claude Code hooks, future integrations) will hit the
  same wall if they adopt relay push.

The current model is **per-agent-process**. We need **per-host** (or at least
per-harness-instance) relay subscription management.

## Goals

| # | Goal | Success criteria |
|---|------|-----------------|
| G1 | One relay subscription process per host (or per harness instance) | ≤ 2 `c2c relay subscribe` processes per machine regardless of agent count |
| G2 | Subagents register/deregister aliases without spawning OS processes | Alias lifecycle managed via IPC, not process lifecycle |
| G3 | Backward compatible — existing single-alias CLI still works | `c2c relay subscribe --alias X` unchanged for single-agent use cases |
| G4 | Works across harnesses — pi-c2c, opencode, Claude Code, future | Shared protocol for alias registration |
| G5 | Graceful degradation on relay disconnect | Reconnect + catch-up poll for all managed aliases, not just one |
| G6 | No server-side breaking change required for v1 | Server enhancement is additive (optional multi-alias frame) |

## Design

### Architecture overview

```
┌─────────────────────────────────────────────────────┐
│  Host machine                                        │
│                                                      │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐        │
│  │ pi-A     │   │ pi-B     │   │ opencode │        │
│  │ (parent) │   │ (sub)    │   │ plugin   │        │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘        │
│       │              │              │               │
│       │  register(alias)  register(alias)           │
│       └──────────┬────┴──────────────┘              │
│                  ▼                                    │
│  ┌───────────────────────────────────┐              │
│  │  c2c relay subscribe-daemon       │              │
│  │  (1 process, 1 WebSocket)         │              │
│  │  - manages N aliases              │              │
│  │  - IPC via Unix socket / CLI      │              │
│  │  - demuxes DMs to callers         │              │
│  └───────────────┬───────────────────┘              │
│                  │                                    │
│                  │  1 WebSocket connection            │
│                  ▼                                    │
│  ┌───────────────────────────────────┐              │
│  │  relay.c2c.im                     │              │
│  │  /ws/subscribe (multi-alias)      │              │
│  └───────────────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

### Two-phase approach

#### Phase 1: Client-side multiplexing (no server change)

A new CLI mode: `c2c relay subscribe-daemon --relay-url <URL>`.

- Starts a long-running daemon that listens on a Unix socket
  (default: `~/.c2c/relay-subscribe.sock`)
- Harness instances register aliases via `c2c relay subscribe-daemon register --alias <ALIAS>`
- Daemon opens one WS per alias (still separate connections, but managed
  by one process — reduces process count from N to 1, connections remain N
  for now)
- DMs are written to the caller's stdout fd or forwarded via the socket
- On alias deregister: close that alias's WS, clean up
- On daemon shutdown: kill all WS connections, clean up

**Why start here:** zero server changes, immediate benefit. 142 processes → 1.
RAM drops from 2.3 GB to ~17 MB (one process with multiple connections).
The WebSocket connections are lightweight; the problem was process overhead,
not connection count.

**IPC protocol (over Unix socket):**

```
→ register <alias> <callback-fd>
← registered <alias> <id>
→ deregister <id>
← deregistered <id>
→ list
← aliases <json>
→ shutdown
```

`callback-fd` is a file descriptor the daemon writes DM JSON lines to.
For pi-c2c, this is the stdout of the registering process.

#### Phase 2: Server-side multi-alias subscription (relay enhancement)

Extend `/ws/subscribe` to accept multiple aliases on one WebSocket.

**New wire frame (client → server, after auth):**

```json
{ "op": "subscribe", "aliases": ["pi-abc#hash1", "pi-def#hash2"] }
```

Auth: the initial HTTP upgrade carries Ed25519 sigs for each alias
(or a single sig from an identity that owns all aliases — the host
identity). The server validates each alias's registration lease.

**Server behavior:**
- DM to any subscribed alias → push to the single WS connection
- Frame includes the recipient alias so the client can demux:
  `{ "op": "dm", "to": "pi-abc#hash1", "from": "pi-xyz#hash2", "body": "...", "ts": ... }`
- Add/remove aliases dynamically:
  `{ "op": "subscribe", "add": ["pi-new#hash"] }`
  `{ "op": "unsubscribe", "remove": ["pi-old#hash"] }`

**Server implementation:**
- `relay_ws_server.ml`: extend `SubscriberMap` to support multi-alias entries
  keyed by connection (not just alias)
- Auth validation: iterate over the alias list, validate each sig
- DM routing: on send, iterate subscriber map for the recipient alias,
  push to all matching connections (existing behavior — already supports
  multiple connections per alias)

**Why this matters:** reduces WebSocket connections from N to 1 per daemon.
For the relay server, this means fewer file descriptors and cleaner connection
management.

### Changes by component

#### c2c CLI (OCaml)

| Change | File | Effort |
|--------|------|--------|
| New `c2c relay subscribe-daemon` subcommand | `ocaml/cli/c2c_relay_subscribe_daemon.ml` | ~300 LoC |
| New `c2c relay subscribe-daemon register/deregister/list/shutdown` | same file | ~200 LoC |
| Refactor: extract WS client logic from `c2c relay subscribe` into shared module | `ocaml/relay_ws_client.ml` | ~100 LoC refactor |
| Phase 2: extend WS subscribe frame to accept alias array | `ocaml/cli/c2c.ml`, `ocaml/relay_ws_server.ml` | ~150 LoC |

#### c2c relay server (OCaml)

| Change | File | Effort |
|--------|------|--------|
| Phase 2: multi-alias subscribe frame parsing | `ocaml/relay_ws_server.ml` | ~100 LoC |
| Phase 2: per-connection alias set management | same | ~80 LoC |
| Phase 2: DM routing to multi-alias subscribers | same | ~50 LoC |

#### pi-c2c (TypeScript)

| Change | File | Effort |
|--------|------|--------|
| Replace per-session `RelayWatcher` subprocess with daemon registration | `src/relay-watcher.ts` | ~200 LoC rewrite |
| Extension manages one daemon connection per pi process | `src/index.ts` | ~100 LoC |
| Subagent alias registration via IPC | `src/relay-watcher.ts` | ~50 LoC |
| Cleanup: deregister on session_shutdown | `src/index.ts` | ~30 LoC |

#### OpenCode plugin (TypeScript)

| Change | File | Effort |
|--------|------|--------|
| Same pattern: register with daemon instead of spawning `c2c monitor` | `data/opencode-plugin/c2c.ts` | ~100 LoC |

### Migration path

1. **Phase 1 ships first** — `c2c relay subscribe-daemon` works with
   existing relay server (one WS per alias, but single process).
   pi-c2c adopts it immediately. No breaking changes.

2. **Phase 2 ships when relay server is updated** — daemon detects server
   support (via capability negotiation or version check) and upgrades to
   multi-alias subscription automatically. Falls back to Phase 1 behavior
   if server doesn't support it.

3. **Old `c2c relay subscribe` stays** — for single-agent use cases,
   scripts, and debugging. Not deprecated.

### Lifecycle: how pi-c2c uses the daemon

```
pi session starts
  └─ pi-c2c session_start handler
       ├─ establish identity (alias-A)
       ├─ check: is subscribe-daemon running?
       │    ├─ yes: register alias-A via IPC
       │    └─ no: spawn daemon, then register
       └─ daemon now relays DMs for alias-A

pi spawns subagent
  └─ subagent session_start
       ├─ establish identity (alias-B)
       ├─ register alias-B with daemon via IPC
       └─ daemon now relays DMs for alias-A AND alias-B

subagent finishes
  └─ session_shutdown
       └─ deregister alias-B from daemon via IPC

pi session ends
  └─ session_shutdown
       ├─ deregister alias-A
       └─ if no more aliases: daemon auto-exits (or stays for other harnesses)
```

### Daemon lifetime management

Options (pick one):

**A. First-to-start, last-to-leave:** Daemon exits when last alias is
deregistered and no connections remain for N seconds (e.g. 30s grace).
Simple, but each machine restart requires a new daemon.

**B. Systemd user service:** `c2c-relay-subscribe.service` managed by
systemd. Always running. More robust but adds ops complexity.

**C. Per-harness singleton:** Each harness (pi, opencode) manages its own
daemon. Two daemons on a machine if both are running. Simpler than B,
avoids cross-harness coordination.

**Recommendation: C for v1** — pi-c2c spawns one daemon per pi process
tree (parent + all subagents share it). OpenCode does the same. This
gets us from 142 processes to 2 (one per harness). We can unify to A
later if needed.

## Edge cases

- **Relay disconnect mid-session:** Daemon reconnects with exponential
  backoff. After reconnect, does a catch-up poll (`c2c relay dm poll`)
  for each managed alias to recover messages missed during disconnect.
  Same pattern as the existing `RelayWatcher`.

- **Daemon crash:** All connected harnesses lose their subscriptions.
  Each harness's 60s safety-net `pollTick` catches up. On next
  `pollTick`, the harness detects the daemon is gone and respawns it.

- **Alias conflict:** If two daemons try to register the same alias
  (e.g. two pi instances in different repos), the relay already handles
  this via `alias_hijack_conflict`. The daemon reports the error to the
  registering harness.

- **Machine sleep/wake:** WebSocket connections are dead after wake.
  Daemon detects via ping timeout and reconnects. Same as existing
  `RelayWatcher` behavior.

## Open questions

1. **Unix socket vs. TCP socket for IPC?** Unix socket is simpler,
   no port conflicts, filesystem permissions for access control.
   **Recommend Unix socket for v1.**

2. **Should the daemon write DMs directly to broker inbox files?** This
   would make it a first-class broker citizen (like `c2c relay connect`).
   But it blurs the boundary — the daemon would need to know each
   alias's session-id for inbox routing. **Recommend: no for v1.**
   The daemon is a WS→stdout pipe; the harness handles delivery.

3. **Phase 2 auth for multi-alias:** how does one WS connection prove
   ownership of N aliases? Options:
   - N individual Ed25519 signatures in the upgrade headers
   - One host-level identity that owns all aliases (like the existing
     `opaque_host_id` concept)
   - Token-based auth that scopes to a set of aliases

   **Recommend: N individual sigs for v1** — matches existing auth
   model, no new concepts. Can optimize to host-level auth later.

4. **Should we ship Phase 1 without Phase 2?** Yes. Phase 1 gives
   immediate relief (142 processes → 1-2). Phase 2 optimizes
   connections (N → 1) but the server change adds lead time.

## Verification

- Unit: daemon IPC protocol (register, deregister, list, shutdown)
- Unit: multi-alias DM demux (Phase 2)
- Integration: pi-c2c spawns subagents, verify ≤ 2 subscribe processes
- Integration: relay disconnect + reconnect + catch-up for all aliases
- Load: 200 aliases registered, verify RAM < 50 MB, CPU < 1%
- Backward: `c2c relay subscribe --alias X` still works (no regression)

## Out of scope

- Room subscription multiplexing (rooms use a different path)
- Cross-relay mesh subscription (separate design)
- WebSocket compression (premature)
- Inotify-based push for local broker (covered by push delivery design, slice 1)
