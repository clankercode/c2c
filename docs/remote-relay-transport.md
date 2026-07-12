---
layout: page
title: Remote Relay Transport
permalink: /remote-relay-transport/
---

# Remote Relay Transport v1

Remote relay transport enables a c2c relay server to poll a remote host's
inbox export directory over SSH, caching messages locally so other nodes can
retrieve them via HTTP.

**Status: shipped 2026-04-23.** Full e2e test passed: remote export dir → SSH
poll → relay cache → `GET /remote_inbox/<session_id>` → message delivered.

## How It Works

```
Remote host (export layout)     Relay Server              Remote Node
+------------------------+    +----------------+      +---------------+
| remote_broker_root/    |SSH | poll + cache  | HTTP |              |
|   inbox/<session>.json |--->|  every 5s     |----->| GET /remote_  |
+------------------------+    +----------------+      | inbox/<sid>   |
                                                      +---------------+
```

1. Relay SSHs to the remote host every 5 seconds
2. Lists `inbox/*.json` under `--remote-broker-root` and `cat`s each file
3. Caches messages in-memory
4. Serves them via `GET /remote_inbox/<session_id>`

### On-disk layout the poller expects

The SSH poller reads:

```text
<remote-broker-root>/inbox/<session_id>.json
```

That is **not** the canonical local c2c broker inbox layout. A live broker
stores inboxes as:

```text
<broker_root>/<session_id>.inbox.json
```

(for example `$HOME/.c2c/repos/<fp>/broker/<session_id>.inbox.json`).

Pointing `--remote-broker-root` at a real broker root therefore yields empty
caches unless something stages files into the `inbox/<session_id>.json`
export layout the poller expects. Treat the remote path as a purpose-built
export directory (or a shim that mirrors broker inboxes into that shape),
not as the stock broker root.

## Usage

### Start relay with remote broker polling

```bash
# Export dir on the SSH host must contain inbox/<session_id>.json files.
# Example root is an operator-chosen path on that host — not the default
# local broker path.
c2c relay serve \
  --listen 0.0.0.0:7331 \
  --token "$TOKEN" \
  --remote-broker-ssh-target user@remote-broker-host \
  --remote-broker-root /var/lib/c2c/remote-broker-export \
  --remote-broker-id my-broker
```

### Poll from a remote node

`GET /remote_inbox/<session_id>` is a **Bearer admin** route when the relay
was started with `--token` (prod mode). Unauthenticated `curl` only works
against a tokenless (dev) serve.

```bash
# Prod mode (token required):
curl -H "Authorization: Bearer $TOKEN" \
  "http://relay-host:7331/remote_inbox/my-session"

# Dev mode only (no --token on serve):
curl "http://relay-host:7331/remote_inbox/my-session"
```

Or via the CLI (token resolves like other relay admin commands:
`--token` → `C2C_RELAY_TOKEN` → saved relay config):

```bash
c2c relay poll-inbox \
  --relay-url http://relay-host:7331 \
  --token "$TOKEN" \
  --session-id my-session
```

## Architecture

- **One remote broker per relay** (v1)
- **Broker identifier**: `--remote-broker-id ID` labels the remote broker in cached relay state; defaults to `default` when omitted.
- **Polling interval**: 5 seconds
- **SSH auth**: Operator's SSH agent (key-based, passwordless required)
- **Transport**: SSH + `cat` of JSON inbox files under `inbox/<session_id>.json`
- **HTTP auth**: `/remote_inbox/*` requires Bearer admin when serve has a token

## Requirements

- Passwordless SSH to the remote host (public key auth)
- Read access to `<remote-broker-root>/inbox/` on that host (export layout above)
- SSH host key already known (or use `StrictHostKeyChecking=no` for first-time hosts)
- Admin Bearer token for clients calling `/remote_inbox` against a prod-mode relay

## Operator Runbook

For step-by-step deployment instructions, troubleshooting, and rollback procedures, see the [Remote Relay Operator Runbook](https://github.com/clankercode/c2c/blob/master/.collab/runbooks/remote-relay-operator.md) (repo-only).

## v2 Direction

- Multiple remote brokers per relay
- Bidirectional: relay can write to remote broker's outbox
- Real-time push instead of 5s polling
- Optional adapter from stock `*.inbox.json` broker roots
