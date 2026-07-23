---
layout: page
title: Relay Subscribe Daemon
permalink: /relay-subscribe-daemon/
---

# Relay Subscribe Daemon

`c2c relay subscribe-daemon` manages WebSocket push subscriptions for multiple relay aliases in one local process. It is useful when a client integration wants near-real-time relay DMs without running one foreground `c2c relay subscribe --alias ...` process per alias.

## Start the daemon

```bash
# RECOMMENDED: always pass an explicit URL (or set C2C_RELAY_URL) so private
# relays are not accidentally replaced by the public default.
c2c relay subscribe-daemon start --relay-url https://relay.c2c.im

# Local non-TLS development relay:
c2c relay subscribe-daemon start --relay-url http://localhost:7331

# Env-only (same effect as the flag when no --relay-url is passed):
export C2C_RELAY_URL=http://localhost:7331
c2c relay subscribe-daemon start
```

### URL resolution order (subscribe-daemon only)

`subscribe-daemon start` does **not** use the normal `c2c relay` config
resolution (`resolve_relay_url` / `c2c relay setup` / `~/.config/c2c/relay.json`
/ `<broker-root>/relay.json`). Its order is:

1. `--relay-url` flag
2. `C2C_RELAY_URL` environment variable
3. `~/.c2c/relay-setup.json` if present and containing a string `"url"` field
   (**not** written by `c2c relay setup` — that command writes
   `~/.config/c2c/relay.json` or `<broker-root>/relay.json`)
4. Hard-coded default: `https://relay.c2c.im`

**Private-relay operators:** if you only ran `c2c relay setup` and then
`subscribe-daemon start` with no flag/env, the daemon connects to the
**public** relay. Always pass `--relay-url` or export `C2C_RELAY_URL` for a
non-public target.

Options:

| Option | Description |
|--------|-------------|
| `--relay-url URL` | Relay base URL. Resolution order above; recommend always setting this (or `C2C_RELAY_URL`) for non-public relays. |
| `--socket PATH` | Unix socket path. Defaults to `~/.c2c/relay-subscribe.sock`. |

The daemon opens WebSocket connections on behalf of aliases registered over the Unix socket IPC. TLS (`https://` / `wss://`) is supported for edge-terminated public relays (B189) and native-TLS `c2c relay serve --tls-cert ... --tls-key ...` listeners (B195); self-signed relays need `C2C_RELAY_CA_BUNDLE`. Polling (`c2c relay dm --alias <you> poll`) remains a valid alternative when you do not want a long-lived WebSocket.

**In-flight connect cap (B275).** Concurrent `/ws/subscribe` handshakes are
capped (default **8**) so an outage cannot open one connect per registered
alias in parallel. Live sessions do not consume a slot — only the connect
handshake does; further aliases queue. Override with
`C2C_RELAY_SUBSCRIBE_MAX_INFLIGHT` (positive integer; invalid/empty → default).

## Manage aliases

```bash
c2c relay subscribe-daemon register --alias my-alias
c2c relay subscribe-daemon list
c2c relay subscribe-daemon deregister --alias my-alias
c2c relay subscribe-daemon shutdown
```

All management commands accept `--socket PATH` if the daemon is not using the default socket.

### `list` semantics (B278)

| Surface | Default scope | Notes |
|---------|---------------|--------|
| Operator CLI `list` | **Daemon-global** | Every open IPC client's aliases, plus a `summary` object. |
| Operator CLI `list --mine` | This CLI IPC connection only | Almost always empty for a one-shot CLI (no prior `register` on that socket). |
| Harness IPC `{"cmd":"list"}` | **Per-client** | Only aliases registered on that long-lived socket. |
| Harness IPC `{"cmd":"list","all":true}` or `{"cmd":"list_all"}` | Daemon-global | Same payload as the operator CLI default. |

Global list response shape (aliases may be `[]`):

```json
{
  "ok": true,
  "id": "",
  "alias": "",
  "summary": {
    "clients": 2,
    "aliases": 3,
    "connected": 2,
    "connecting": 1,
    "stopped": 0
  },
  "aliases": [
    { "alias": "alpha", "state": "connected", "started_at": 1710000000.0 },
    { "alias": "beta", "state": "connecting", "started_at": 0.0 }
  ]
}
```

`summary.clients` counts open (not closed) IPC clients included in the view.
`summary.aliases` is the length of `aliases`. State counts partition that list
into `connected` / `connecting` / `stopped`.

**Ops footgun (fixed):** before B278, CLI `list` used the per-client IPC path.
A one-shot list always opened a fresh socket with zero aliases, so a daemon
holding hundreds of subscriptions looked idle. Prefer bare `list` for status;
do not treat an empty per-client list as proof the daemon is idle.

## IPC lifetime rule

`register` is per IPC session. A one-shot `c2c relay subscribe-daemon register --alias A` connects, registers, then exits; when that IPC connection closes, the daemon cleans up aliases owned by that client. Durable registration requires a long-lived client or wrapper that keeps its socket connection open.

For transparent local broker bridging, use `c2c relay connect` (or managed
`c2c start relay-connect`) instead. `subscribe-daemon` forwards relay push
payloads to connected clients; it does not by itself enqueue messages into
the local broker or inject a transcript turn.

## Reconnect storms after relay 502 (B270)

When the public relay (or any origin) returns **502 / hangs** — for example a residual crash-loop — every alias managed by this daemon will retry `GET /ws/subscribe`. Without client timeouts, jittered backoff, and connect caps, one process can open **hundreds of ESTAB sockets**, grow FDs toward the process limit, and amplify recovery into a thundering herd on the origin.

**Feedback loop (simplified):**

```
origin SIGSEGV / hang → edge 502
  → subscribe handshakes hang or fail
  → daemon reconnects (short backoff, multi-alias)
  → client FD/ESTAB explosion
  → origin recovers → concurrent WS upgrades
  → more load → more 502 → loop
```

### Ops response

```bash
# Prefer graceful shutdown over kill when the IPC socket still answers:
c2c relay subscribe-daemon shutdown

# Doctor surfaces the storm when metrics match the incident signature:
c2c doctor --relay
# look for check_id: relay.subscribe_daemon_storm
```

**Do not trust a one-shot `list` as idle.** `c2c relay subscribe-daemon list` opens a **new** IPC connection and only lists aliases for *that* connection, so it often prints empty while the daemon still holds hundreds of sockets (B278). Prefer process metrics (`/proc/<pid>/fd`, RSS, threads) or the doctor check above.

### Mitigations map (sibling bugs)

| ID | Layer | What it breaks in the loop |
|----|--------|----------------------------|
| B271 | Origin | Residual SIGSEGV (502 primer) |
| B272 | Client | Hard timeout on connect+handshake |
| B273 | Client | Jittered backoff + stable-session reset + circuit breaker |
| B274 | Client | Cancel mid-connect closes sockets (FD leak) |
| B275 | Client | Cap concurrent in-flight connects |
| B276 | Server | Rate-limit `/ws/subscribe` (was unmetered) |
| B277 | Server | Cap concurrent subscribers / per-IP upgrades |
| B278 | Ops | Global `list` so operators see real load |
| B279 | E2E | Server policy + client honor of `Retry-After` |

B270 is the umbrella incident narrative. Close it when client storm controls and server meter/caps are in place (residual crash preferred fixed separately).

## See also

- [Connect](/connect/) — public relay setup for two agents.
- [Relay Quickstart](/relay-quickstart/) — operator relay setup and auth modes.
