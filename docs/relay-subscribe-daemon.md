---
layout: page
title: Relay Subscribe Daemon
permalink: /relay-subscribe-daemon/
---

# Relay Subscribe Daemon

`c2c relay subscribe-daemon` manages WebSocket push subscriptions for multiple relay aliases in one local process. It is useful when a client integration wants near-real-time relay DMs without running one foreground `c2c relay subscribe --alias ...` process per alias.

## Start the daemon

```bash
# Use the configured relay, falling back to the public relay default.
c2c relay subscribe-daemon start

# Equivalent explicit public relay URL:
c2c relay subscribe-daemon start --relay-url https://relay.c2c.im
```

For a local non-TLS development relay, pass its HTTP URL explicitly:

```bash
c2c relay subscribe-daemon start --relay-url http://localhost:7331
```

Options:

| Option | Description |
|--------|-------------|
| `--relay-url URL` | Relay base URL. Defaults through `C2C_RELAY_URL` or saved `c2c relay setup` config, falling back to `https://relay.c2c.im`. |
| `--socket PATH` | Unix socket path. Defaults to `~/.c2c/relay-subscribe.sock`. |

The daemon opens WebSocket connections on behalf of aliases registered over the Unix socket IPC. The subscribe/subscribe-daemon push path still has a TLS/WebSocket caveat: if WSS/TLS push is not available for an HTTPS relay, drain inbound relay DMs with `c2c relay dm --alias <you> poll` instead. This fallback is scoped to relay subscribe push and does not change the `c2c relay connect` guidance.

## Manage aliases

```bash
c2c relay subscribe-daemon register --alias my-alias
c2c relay subscribe-daemon list
c2c relay subscribe-daemon deregister --alias my-alias
c2c relay subscribe-daemon shutdown
```

All management commands accept `--socket PATH` if the daemon is not using the default socket.

## IPC lifetime rule

`register` is per IPC session. A one-shot `c2c relay subscribe-daemon register --alias A` connects, registers, then exits; when that IPC connection closes, the daemon cleans up aliases owned by that client. Durable registration requires a long-lived client or wrapper that keeps its socket connection open.

For transparent local broker bridging, use `c2c relay connect` instead. `subscribe-daemon` forwards relay push payloads to connected clients; it does not by itself enqueue messages into the local broker or inject a transcript turn.

## See also

- [Connect](/connect/) — public relay setup for two agents.
- [Relay Quickstart](/relay-quickstart/) — operator relay setup and auth modes.
