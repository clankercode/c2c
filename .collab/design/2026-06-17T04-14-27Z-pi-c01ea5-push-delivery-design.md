# Push delivery: WebSocket (relay) + inotify (broker) for instant e2e

**Date:** 2026-06-17
**Author:** pi-c01ea5
**Status:** DRAFT — not implemented
**Supersedes:** none (complements existing designs)
**Builds on:** `SPEC-delivery-latency.md` (galaxy), `2026-05-05T19-35-00Z-willow-coder-deliver-watch-inotify-sketch.md` (willow), `2026-04-26T13-59-00Z-stanza-coder-push-aware-heartbeat.md` (stanza)
**Slice size:** 3 slices (broker inotify reuse, relay WS server, client WS client + integration)

## Context

Per Max (2026-06-17, after the via-the-relay e2e latency test): add a plan for WebSocket push on the relay and the same for the broker. Goal is to make message delivery feel instant — drop from current worst-case 5s+ (pollTick) to ~50ms (push) on all three delivery paths.

This is the natural follow-on to:
- `ca0bcbd` — `DEFAULT_POLL_INTERVAL_MS` 30s → 5s (already landed in pi-c2c, narrows the worst case from 35s to 6s but doesn't go to zero)
- `a215bb8` — e2e latency tests (broker round-trip mean=30ms p50=26ms p95=48ms — broker drain is already fast, the 5s is the pollTick wait)

## Current State

### Three delivery paths, all poll-based today

| Path | Mechanism | Latency | Code |
|------|-----------|---------|------|
| Per-repo broker (local) | `pollTick` calls `c2c poll-inbox` every 5s | worst 5s + 30ms drain ≈ 5.03s | `src/index.ts:pollTick` |
| Sessions broker (cross-repo) | `pollTick` calls `c2c poll-inbox --broker-root <sessions>` every 5s | worst 5s + 30ms drain ≈ 5.03s | `src/index.ts:pollTick` (sessions branch) |
| Public relay (cross-machine) | `pollTick` calls `c2c relay dm poll` every 5s | worst 5s + 30ms drain + network ≈ 5.5s | `src/index.ts:pollTick` (relay branch) |

### What push infrastructure already exists

- **Local broker → client** (NOT push, but close): `c2c-deliver-inbox` daemon + `c2c monitor --alias` subprocess with `inotifywait -m`. OpenCode plugin spawns `c2c monitor` per session. Claude Code uses PostToolUse hook. **These only work for managed sessions started via `c2c start` — not for ad-hoc pi-c2c or c2c_pi_send users.**
- **Kimi**: `C2c_kimi_notifier` writes inbound messages to Kimi's notification store. Kimi reads on its own cadence (~2-3s).
- **Relay → client**: nothing. The relay only has HTTP request/response; clients must poll. This is the gap.
- **Relay ↔ relay (mesh)**: `c2c_relay_connector.ml` already does pull-based sync between local broker and remote relay (registers, heartbeats, polls for DMs, forwards outbox). The connector is the natural place to slot a WS client into.

### In-flight design proposals

- **willow's inotify sketch** (`2026-05-05T19-35-00Z-willow-coder-deliver-watch-inotify-sketch.md`) — hand-rolled inotify parser + position-based dedup + atomic checkpoint sidecar for `c2c-deliver-inbox`. DRAFT, not shipped. Covers the LOCAL BROKER path. **This doc reuses that design; no need to redo it.**
- **galaxy's SPEC-delivery-latency.md** — focused on watcher delay (5s→2s) and poker interval (600s→180s). Already shipped at 8171bc6, pending origin/master. Out of scope for "push": the inotify/WS work.
- **stanza's push-aware heartbeat** (`2026-04-26T13-59-00Z-stanza-coder-push-aware-heartbeat.md`) — `automated_delivery` field on registrations; heartbeat body drops "Poll your C2C inbox" for push-capable clients. Landed. Provides the registry-side signal for "is this peer push-aware?".

### Why the relay needs WebSocket (the new piece)

The per-repo and sessions brokers are file-based on local disk. `inotify` (willow's design) is the right push primitive — sub-millisecond event latency, zero CPU waste, no protocol overhead.

The relay is a remote HTTP service. `inotify` doesn't apply (no local file). Push has to be a network protocol:
- **Long-poll**: keeps a connection open until a DM arrives. One connection per subscriber. Simple but connection-heavy.
- **Server-Sent Events (SSE)**: one-way server→client stream. Works over plain HTTP. No bidirectional frames.
- **WebSocket**: full-duplex, RFC 6455. Standard, well-understood, already half-implemented (`ocaml/relay_ws_frame.ml` is server-side frame handling). **Pick this.**

## Goal

Worst-case e2e latency on all three paths, sender→recipient:

| Path | Today (poll) | After this design (push) |
|------|--------------|--------------------------|
| Per-repo broker | 5.03s | **~50ms** |
| Sessions broker | 5.03s | **~50ms** |
| Relay | 5.5s | **~80ms** (network adds ~30ms) |

The pollTick becomes a **fallback** that runs at a much longer interval (60s?) to catch missed events from a crashed watcher.

## Design

### Slice 1: Per-repo + sessions broker inotify push (small, builds on willow)

Adopt willow's `c2c-deliver-inbox` inotify design with minimal changes. New `c2c inbox watch --broker-root <path>` subcommand (or extend the existing `c2c monitor --alias` to support custom paths).

**New behavior:**
- Watch `<broker_root>/<alias>.inbox.json` for `IN_MODIFY`
- Position-based dedup against `last_seen_count` (atomic sidecar)
- On new messages: write to stdout in the same shape as `c2c poll-inbox --json` (one JSON line per message)
- pi-c2c spawns this for per-repo broker AND sessions broker concurrently
- pollTick demoted to a 60s safety net (catches missed events from a crashed watcher)

**For pi-c2c specifically:**
- Add a new `BrokerWatcher` class in `src/broker-watcher.ts` that spawns `c2c inbox watch` and pipes stdout into the existing drain pipeline
- Replace the per-repo and sessions branches of `pollTick` with watcher subscription
- Keep the relay branch as poll-based (slice 2)
- Keep the 60s pollTick as fallback

**Files:**
- New: `ocaml/cli/c2c_inbox_watch.ml` (hand-rolled inotify + position dedup, ~150 lines following willow's sketch)
- New: `pi-c2c/src/broker-watcher.ts` (subprocess management + pipe parser)
- Modified: `pi-c2c/src/index.ts` (replace per-repo + sessions branches of pollTick)
- Modified: `pi-c2c/src/spool.ts` (already handles "where to write the sidecar" — generalize)

**Why this is small:** the inotify parser and dedup logic already exist in willow's sketch. Just port + integrate.

### Slice 2: Relay WebSocket push (the new piece)

Add a `GET /ws/subscribe` endpoint to the relay. Clients subscribe with their `alias#host_hash` and Ed25519 signature; server pushes DMs as JSON frames.

**Wire protocol:**

```
Client → Server (HTTP upgrade request):
  GET /ws/subscribe HTTP/1.1
  Host: relay.c2c.im
  Upgrade: websocket
  Connection: Upgrade
  Sec-WebSocket-Key: <base64>
  Sec-WebSocket-Version: 13
  Sec-WebSocket-Protocol: c2c-v1
  X-C2C-Alias: pi-abc#3d08761ae3f3
  X-C2C-Timestamp: 1781668000
  X-C2C-Signature: <ed25519 over (alias || ts || nonce)>

Server → Client (101 Switching Protocols):
  HTTP/1.1 101 Switching Protocols
  Upgrade: websocket
  ...
  Sec-WebSocket-Accept: <hashed key>

Then over the WS connection:

Client → Server (subscribe frame, once):
  { "op": "subscribe", "alias": "pi-abc#3d08761ae3f3" }

Server → Client (push frame, on DM arrival):
  { "op": "dm", "from": "pi-xyz#hash", "body": "hello", "ts": 1781668001 }

Server → Client (ping, every 30s):
  WS ping frame (standard)

Client → Server (pong, within 10s of ping):
  WS pong frame (standard)

Server → Client (close, on shutdown or auth failure):
  WS close frame with code 1000 (normal) or 4001 (auth failed)
```

**Server-side implementation (ocaml/relay.ml):**

```ocaml
(* New module: Relay_ws_server.ml — wraps the existing Relay_ws_frame
   primitives with a cohttp-lwt upgrade handler. *)

let ws_subscribe_handler _req body =
  let alias = read_header "X-C2C-Alias" in
  let ts = read_header "X-C2C-Timestamp" in
  let sig_b64 = read_header "X-C2C-Signature" in
  let* lease = validate_subscribe auth alias ts sig_b64 in
  Lwt.return (
    Dream.upgrade ~websocket:(Relay_ws_server.handle alias lease) body
  )

(* Inside handle: maintain a Lwt_pipe of DM frames; the relay's
   dm-send path writes to the pipe for any connected subscriber
   matching the recipient. *)
```

**Client-side implementation (c2c binary):**

New subcommand `c2c relay subscribe --alias <me> --relay-url <url>`:
- Opens WS to relay
- Sends subscribe frame with Ed25519 sig
- On DM frame: writes to stdout as JSON line `{ from, body, ts }`
- On close/error: exits non-zero (caller restarts with backoff)

The existing `c2c_relay_connector.ml` (which already pulls from relay and delivers to local broker inbox) is the natural place to add this — replace the `relayDmPoll` call with a `relaySubscribe` subprocess piped to the same local-inbox deliver function.

**Why this is the right shape:**
- Ed25519 auth matches the existing relay lease/registration auth (no new crypto)
- `alias#host_hash` is the existing opaque_host_id form (slice 1 already plumbed this)
- WS frames are JSON for human-readability (can be binary later)
- pi-c2c's `c2c_pi_send` extension routes via the connector, which now subscribes for the local alias

### Slice 3: pi-c2c integration

Replace `pollTick`'s relay branch with WS subscription via the connector. The broker branches (slice 1) and the relay branch (slice 2) both become push-based.

**For pi-c2c specifically:**
- Add `RelayWatcher` class in `src/relay-watcher.ts` (mirrors BrokerWatcher for symmetry)
- `pollTick` shrinks to: drain spool + heartbeat + 60s safety poll
- `inject()` unchanged
- Delivery mode (triggerTurn+steer) unchanged

**Per-agent memory:**
- `relay_ws_state` tracked in the local extension: `connected | reconnecting | fallback-polling`
- Surfaced in `c2c_pi_local_info` for debug

### Wire details: how this composes with existing pieces

```
Sender (pi-A)                       Relay (relay.c2c.im)              Receiver (pi-B)
  │                                       │                              │
  ├─ c2c_pi_send pi-B#hash "hi"           │                              │
  ├─→ c2c send ... (over per-repo)        │                              │
  ├─→ connector forwards via /send        ├─→ validate, store in lease   │
  │                                       │                              │
  │                                       ├─→ WS push to subscribers ────┼─→ c2c relay subscribe stdout
  │                                       │                              ├─→ c2c_relay_connector
  │                                       │                              ├─→ writes to local broker inbox
  │                                       │                              ├─→ broker inotify fires
  │                                       │                              ├─→ c2c inbox watch stdout
  │                                       │                              ├─→ pi-c2c BrokerWatcher pipes
  │                                       │                              ├─→ inject() → triggerTurn+steer
  │                                       │                              ├─→ LLM sees <c2c> envelope
```

**Total latency: ~30-80ms for a single hop.**

## Auth

- **Subscribe request**: Ed25519 sig over `(alias || ts || nonce)` where nonce is from a server-side `/ws/challenge` pre-handshake OR a one-shot included in the upgrade request
- **Why not JWT or API tokens**: the relay already uses Ed25519 for everything (registrations, lease renewals, sends). Don't add a new auth scheme.
- **Replay protection**: ts must be within 60s of server clock; nonce is single-use server-side

## Reconnection

- **Client backoff**: 1s, 2s, 4s, 8s, 16s, 30s (cap). Reset on successful connect.
- **Lease refresh**: on WS reconnect, re-send the subscribe frame with a fresh sig (avoids the 60s window expiring during long disconnects)
- **Missed events during disconnect**: the connector's local broker inbox still has the messages (the relay doesn't drop on store — it just doesn't push to a disconnected subscriber). On reconnect, do a one-shot `c2c relay dm poll` to catch up, then resume WS subscription
- **Server-side cleanup**: WS connection dead → remove subscriber from the in-memory map. Lease is unaffected (TTL is 24h, so transient disconnects don't drop the lease)

## Fallback

- If WS connect fails 3 times in a row, the connector falls back to `c2c relay dm poll` at a 30s interval (much longer than current 5s — the WS should be the primary path; polling is for when the relay doesn't support WS)
- The 60s pollTick in pi-c2c acts as a final safety net for any messages the broker watcher missed
- `C2C_RELAY_DISABLE_WS=1` env var forces polling-only mode (for ops debugging)

## Risks

1. **WS connection churn on flaky networks**: backoff + lease refresh handle this, but a flapping connection could spam the relay. Mitigate with the 30s backoff cap.
2. **Inotify queue overflow** (willow already covers): `IN_Q_OVERFLOW` → fall back to stat-poll until caught up.
3. **Multiple subscribers with the same alias** (multi-machine, same user): the relay maintains a per-subscriber set keyed by `alias#host_hash`. A DM goes to all matching subscribers (broadcast) — last write wins on the receiver's broker. **Open question:** is broadcast the right behavior, or should we route to the most-recently-active subscriber only?
4. **Stale WS connections (half-open)**: server pings every 30s, requires pong within 10s. Connection dropped if no pong. Matches typical WS health check.
5. **Backpressure**: if the receiver is slow, the WS frame queue grows. Server caps at 100 frames; on overflow, close with code 1011 (server error) and rely on reconnect + catch-up poll.

## Open Questions

1. **Multi-subscriber broadcast vs. active-only routing** (Risk 3) — broadcast is simpler; active-only matches user intent better. **Recommend broadcast for v1**; can refine to active-only once we have telemetry.
2. **Where does the WS server bind?** Currently the relay is one process; adding WS to the same port (443 with cohttp upgrade) is cleaner than a second port. **Recommend same port.**
3. **Should the WS subscribe replace `c2c relay dm poll` entirely, or run in parallel?** Replace. The poll command stays for ops debugging but the connector doesn't use it.
4. **Cross-relay mesh**: when a DM is forwarded between relays, does the destination relay push to its subscribers, or store-and-forward only? **Recommend destination pushes** — the source relay has already validated and stored, no need to keep it in source's hands.
5. **Inotify on macOS / non-Linux dev machines**: inotify is Linux-only. The c2c-cli fallback path should use `fs.watch` (FSEvents) for cross-platform. For production, the relay is Linux-only and most agents are Linux. **Document the limitation, defer macOS support.**

## Slices

1. **Slice 1: Broker inotify (small, ~300 LoC)** — port willow's sketch into `c2c_inbox_watch.ml`; new `BrokerWatcher` in pi-c2c; replaces per-repo + sessions branches of pollTick. Latency: 5s → 50ms on local.
2. **Slice 2: Relay WebSocket (medium, ~600 LoC)** — new `Relay_ws_server.ml` (server) + `c2c relay subscribe` (client). Wire protocol, auth, reconnect. Latency: 5.5s → 80ms on relay.
3. **Slice 3: pi-c2c relay watcher (small, ~150 LoC)** — `RelayWatcher` class, replace relay branch of pollTick with subscription. Per-agent memory field for connection state. Wire it all up.

**Total: ~1050 LoC across 3 slices.** Each independently testable; slice 1 is the lowest-risk win.

## Verification

- e2e latency tests (already in `pi-c2c/tests/latency-e2e.test.ts`) — extend to measure push latency, not poll latency
- New: `ocaml/test/test_relay_ws_server.ml` — WS handshake, subscribe frame, push frame, close codes
- New: `ocaml/test/test_inbox_watch.ml` — inotify event parsing, position dedup, checkpoint sidecar
- Manual: send a DM from pi-A to pi-B, watch the LLM transcript on pi-B receive within ~100ms

## Out of Scope (Future)

- WS compression (permessage-deflate) — premature for v1
- Multiplexed subscriptions (one WS for many aliases) — premature
- Room push via WS — separate slice; rooms are already on a different path
- Relay → relay WS mesh — defer to the cross-relay work already in flight
