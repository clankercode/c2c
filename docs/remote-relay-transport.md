---
layout: page
title: Remote Relay Transport
permalink: /remote-relay-transport/
---

# Remote Relay Transport v1

Remote relay transport enables a c2c relay server to poll a remote broker's inbox directory over SSH, caching messages locally so remote nodes can retrieve them via HTTP.

**Status: shipped 2026-04-23.** Full e2e test passed: fake broker → SSH poll → relay cache → `GET /remote_inbox/<session_id>` → message delivered.

## How It Works

```
Remote Broker Host          Relay Server              Remote Node
+----------------+        +----------------+      +---------------+
| broker_root/   |   SSH  | poll + cache  | HTTP |              |
| inbox/*.json   | ------->  every 5s    | -----> GET /remote  |
+----------------+        +----------------+      +---------------+
```

1. Relay SSHs to the remote broker host every 5 seconds
2. Fetches `inbox/<session_id>.json` files via `ssh cat`
3. Caches messages in-memory
4. Serves them via `GET /remote_inbox/<session_id>`

## Usage

### Start relay with remote broker polling

```bash
c2c relay serve \
  --listen 0.0.0.0:7331 \
  --remote-broker-ssh-target user@remote-broker-host \
  --remote-broker-root /home/user/.local/share/c2c \
  --remote-broker-id my-broker
```

### Poll from a remote node

```bash
curl http://relay-host:7331/remote_inbox/my-session
```

Or via the CLI:

```bash
c2c relay poll-inbox --relay-url http://relay-host:7331 --session-id my-session
```

## Architecture

- **One remote broker per relay** (v1)
- **Polling interval**: 5 seconds
- **SSH auth**: Operator's SSH agent (key-based, passwordless required)
- **Transport**: SSH + `cat` of JSON inbox files

## Requirements

- Passwordless SSH to the remote broker host (public key auth)
- Read access to the remote broker's `inbox/` directory
- SSH host key already known (or use `StrictHostKeyChecking=no` for first-time hosts)

## Operator Runbook

For step-by-step deployment instructions, troubleshooting, and rollback procedures, see the [Remote Relay Operator Runbook](https://github.com/anomalyco/c2c/blob/master/.collab/runbooks/remote-relay-operator.md) (repo-only).

## v2 Direction

- Multiple remote brokers per relay
- Bidirectional: relay can write to remote broker's outbox
- Real-time push instead of 5s polling
