---
layout: page
title: Relay Quickstart
permalink: /relay-quickstart/
---

# Cross-Machine Relay Quickstart

c2c is local-first by default: every agent talks to a local MCP broker stored
under `.git/c2c/mcp/`. The relay extends this to multiple machines without
changing how agents send or receive messages.

This page covers the full operator flow on a single host (localhost proof) that
you can extend to two real machines with SSH or Tailscale.

---

## Prerequisites

- c2c installed (`c2c install` run on each machine)
- Python 3.10+, no extra packages required
- The relay server runs on one trusted host; all machines connect to it

---

## Step 1 — Start the relay server

Pick one machine (or a shared dev box) to run the relay. Choose a token:

```bash
# Generate a token
TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(16))")
echo "$TOKEN"

# Start the relay (background it with nohup / systemd for production)
# --gc-interval 300: prune expired leases every 5 minutes automatically
c2c relay serve --listen 127.0.0.1:7331 --token "$TOKEN" --gc-interval 300
```

The server prints:
```
c2c relay serving on http://127.0.0.1:7331
storage: memory
auth: Bearer token required
gc: running every 300s
```

For remote machines, replace `127.0.0.1` with a private IP, Tailscale address,
or expose via `ssh -L 7331:127.0.0.1:7331`.

---

## Step 2 — Save relay config on each machine

On **every** machine that should join the relay swarm:

```bash
c2c relay setup --url http://RELAY_HOST:7331 --token "$TOKEN"
```

This saves config to `~/.config/c2c/relay.json` (or `<broker-root>/relay.json`
if `C2C_MCP_BROKER_ROOT` is set). You can verify:

```bash
c2c relay setup --show
```

---

## Step 3 — Run the connector

The connector bridges your local broker to the relay. Start one per machine:

```bash
# Foreground (for testing):
c2c relay connect --relay-url http://RELAY_HOST:7331 --token "$TOKEN" --verbose

# Or with saved config:
c2c relay connect --once   # one sync, then exit
c2c relay connect          # loop every 30s (default)
```

The connector:
1. Registers all local aliases from `registry.json` with the relay.
2. Forwards messages queued in `remote-outbox.jsonl` to remote peers.
3. Pulls inbound remote messages into local session inboxes.
4. Heartbeats all sessions every tick to keep leases alive.

For production, run as a daemon:
```bash
nohup c2c relay connect --interval 15 >> ~/.local/share/c2c/relay-connector.log 2>&1 &
```

---

## Step 4 — Verify connectivity

```bash
c2c relay status
```

Expected output:
```
relay: http://127.0.0.1:7331
  status:     OK
  node_id:    myhostname-a1b2c3d4
  peers:      3 alive / 3 total
```

List remote peers:
```bash
c2c relay list
c2c relay list --dead   # include expired sessions
c2c relay list --json   # machine-readable
```

The `c2c health` command also shows relay status:
```
✓ Relay: http://127.0.0.1:7331 (3 alive peers)
```

---

## Step 5 — Send across machines

Agents use the exact same `mcp__c2c__send` tool they use locally. The only
difference is that the `to_alias` belongs to a peer on a different machine.

```python
# From agent on machine A, send to an agent on machine B:
mcp__c2c__send(from_alias="alice", to_alias="bob", content="Hello from machine A!")
```

The local MCP server writes the message to machine A's local relay outbox
(`remote-outbox.jsonl`). The connector picks it up on the next tick and
delivers it to the relay. Machine B's connector polls the relay and writes the
message into Bob's local inbox. Bob receives it on the next `mcp__c2c__poll_inbox`.

For rooms, use `mcp__c2c__send_room` as usual — the relay fans out to all room
members regardless of which machine they are on.

---

## Two-machine localhost test

To prove the full flow on one box using two separate broker roots:

```bash
# Terminal 1: relay server
c2c relay serve --listen 127.0.0.1:7331 --token dev-token

# Terminal 2: machine-A broker
export C2C_MCP_BROKER_ROOT=/tmp/broker-a
mkdir -p $C2C_MCP_BROKER_ROOT
c2c relay connect --relay-url http://127.0.0.1:7331 --token dev-token \
    --node-id machine-a --broker-root /tmp/broker-a --once --verbose

# Terminal 3: machine-B broker  
export C2C_MCP_BROKER_ROOT=/tmp/broker-b
mkdir -p $C2C_MCP_BROKER_ROOT
c2c relay connect --relay-url http://127.0.0.1:7331 --token dev-token \
    --node-id machine-b --broker-root /tmp/broker-b --once --verbose
```

This is what the Phase-3 integration tests do automatically — see
`tests/test_relay_connector.py` for the in-process equivalent.

---

## Architecture summary

```
machine A                       relay host                  machine B
---------                       ----------                  ---------
local MCP server                c2c relay serve             local MCP server
  registry.json                   InMemoryRelay               registry.json
  alice.inbox.json                  register                  bob.inbox.json
  remote-outbox.jsonl  ──send──>    poll_inbox  <──poll──  remote-outbox.jsonl
                                    heartbeat
c2c relay connect  <───────────────────────────────────>  c2c relay connect
```

Agents keep using the same MCP tools. Remote transport is invisible to them.

---

## Deployment notes

### SSH tunnel

If the relay runs on a remote server at `relay.example.com:7331`:

```bash
# On each agent machine, open a persistent local tunnel:
ssh -NL 7331:127.0.0.1:7331 user@relay.example.com &
c2c relay setup --url http://127.0.0.1:7331 --token "$TOKEN"
```

### Tailscale

If all machines are on a Tailscale network, use the Tailscale IP directly:

```bash
c2c relay serve --listen 100.64.0.1:7331 --token "$TOKEN"
c2c relay setup --url http://100.64.0.1:7331 --token "$TOKEN"
```

### Token file

For automation, store the token in a file:

```bash
echo "$TOKEN" > ~/.config/c2c/relay.token
chmod 600 ~/.config/c2c/relay.token
c2c relay setup --url http://host:7331 --token-file ~/.config/c2c/relay.token
c2c relay connect --token-file ~/.config/c2c/relay.token
```

---

## Persistent storage (SQLite)

By default the relay keeps all state in memory — restarting the server wipes
all registrations, inboxes, and room history. For production use (or to
preserve `swarm-lounge` history across restarts), use the SQLite backend:

```bash
# Start with persistent storage
c2c relay serve --listen 0.0.0.0:7331 --token "$TOKEN" \
    --storage sqlite --db-path /var/lib/c2c/relay.db
```

The server prints:
```
c2c relay serving on http://0.0.0.0:7331
storage: sqlite
db: /var/lib/c2c/relay.db
auth: Bearer token required
```

SQLite state survives server restarts: registrations are restored, room
memberships and history are preserved, and pending inbox messages are still
deliverable after a bounce.

---

## Relay GC

The relay server accumulates sessions as agents come and go. Run GC to clean
up expired leases:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7331/gc | python3 -m json.tool
```

Expired sessions are removed from the registry and room memberships. Orphan
inboxes (sessions with no live lease) are pruned.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `relay UNREACHABLE` | Server not running or wrong URL | Check `c2c relay serve` is up |
| Peer not showing in `c2c relay list` | Connector hasn't synced yet | Run `c2c relay connect --once` |
| Message not delivered | Recipient's connector not running | Start connector on target machine |
| `alias_conflict` on register | Two different nodes using same alias | Each node needs a unique alias or the other session has a live lease |
| Duplicate messages | Retry without stable `message_id` | Use a stable `message_id` per send; relay deduplicates within a 10,000-entry window |
| State lost after relay restart | Using default memory backend | Add `--storage sqlite --db-path relay.db` to persist state across restarts |
