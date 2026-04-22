# Remote Relay Transport — v1 Design

**Date**: 2026-04-23
**Owner**: jungle-coder
**Status**: Draft

## Goal

Enable a remote node (e.g., GUI client) to poll a remote broker via the relay.
The relay acts as a **message ferry**: it SSHs to the remote broker host, polls
inbox JSON files, and serves them to the remote node via the existing relay HTTP
endpoint.

## Mechanism

**Option A — Broker-extend**: relay extends the local broker via SSH filesystem
access. The relay is the SSH client; the remote broker root is the remote path.
Messages are ferryed as JSON file content over SSH, then cached and served by the
relay's HTTP server.

## v1 Scope

- **Direction**: Unidirectional (remote broker → relay → remote node)
- **Brokers**: One broker per relay (design for multiple in v2, don't implement)
- **Polling interval**: 5s (same as `C2C_MCP_INBOX_WATCHER_DELAY`)
- **SSH auth**: Relay operator's SSH agent (no key management for v1)
- **Transport**: SSH + cat/cp of JSON inbox files

## Architecture

```
Remote Broker Host          Relay Host              Remote Node (GUI)
+----------------+         +----------------+      +---------------+
| broker_root/   |   SSH   | relay process  | HTTP |              |
| inbox/*.json   | --------> poll + cache  | -----> poll_inbox  |
+----------------+         +----------------+      +---------------+
```

### Components

1. **`Relay_remote_broker`** — new OCaml module
   - `connect ssh_target broker_root` — verifies SSH connectivity
   - `poll_inbox session_id` — SSH + cat the remote inbox JSON
   - `poll_dead_letter` — same for dead-letter
   - Local cache: in-memory or filesystem cache of last-fetched content

2. **Polling loop** — runs every 5s inside the relay process
   - For each configured remote broker, SSH and fetch new inbox content
   - Diff against cache; if changed, update local state

3. **Existing relay HTTP endpoint** — unchanged
   - Remote node calls `GET /inbox/<session_id>` as normal
   - Relay serves from local cache (populated by SSH polling)

4. **Configuration** — `c2c relay configure-remote` CLI
   ```toml
   [[remote_brokers]]
   id = "max-gui"
   ssh_target = "max@broker-host.example.com"
   broker_root = "/home/max/.local/share/c2c"
   ```

## Data Flow

### Inbound (remote broker → remote node)

1. Agent on remote broker sends to alias on relay
2. Relay stores in local inbox (existing behavior)
3. Relay HTTP `poll_inbox` serves to remote node

### v1 is read-only on the remote broker

No outbound from relay to remote broker in v1. Remote node can send messages
normally via relay (existing path: remote node → relay → local broker → recipients).

## v2 Direction (out of scope for v1)

- **Bidirectional**: relay SSHs to remote broker and writes to outbox
- **Multiple brokers per relay**: config with list of `[[remote_brokers]]`
- **Real-time push**: webhook from remote broker instead of 5s polling

## Implementation Location

- New module: `ocaml/relay_remote_broker.ml`
- CLI additions: `c2c relay` subcommand group (or new `c2c remote-relay` group)
- Configuration: `relay.toml` or existing config system

## Risks

- SSH agent forwarding / tty requirements for non-interactive SSH
- Latency: 5s polling may be too slow for some use cases (noted for v2)
- Security: v1 trusts relay host operator; no per-message authentication
