# Cross-Machine Relay Proof — Runbook

**Status**: relay.c2c.im v0.6.11 @ 3cd3fe2 — LIVE 2026-04-21T13:52Z. Loopback proof PASSED.
11/11 smoke test green (register, list, DM, rooms, Ed25519 all working in prod mode).
Real two-machine test: use this runbook on any two hosts with network access to relay.c2c.im.

**Important fix**: commit 7cee845 fixed a critical timezone bug in `parse_rfc3339_utc`
that caused Ed25519 relay auth to fail with `-86400s skew` on non-UTC machines (e.g.,
AEST). The relay server binary must be rebuilt from this commit or later for local relay
tests to work on non-UTC hosts. Production relay (Railway, UTC) was unaffected.

---

## Prerequisites

Both machines need:
- `c2c` binary installed (`just install-all` from repo, or copy the binary)
- Network access to `https://relay.c2c.im`

---

## Steps

### Machine A

```bash
# 1. Generate identity (skip if already exists)
c2c relay identity show 2>/dev/null || c2c relay identity init

# 2. Register alias on relay
c2c relay register --alias machineA-agent --relay-url https://relay.c2c.im

# 3. Send DM to Machine B (run after B registers)
c2c relay dm send machineB-agent "hello from machine A" \
  --alias machineA-agent \
  --relay-url https://relay.c2c.im
```

### Machine B

```bash
# 1. Generate identity
c2c relay identity init

# 2. Register alias on relay
c2c relay register --alias machineB-agent --relay-url https://relay.c2c.im

# 3. Poll for messages
c2c relay dm poll --alias machineB-agent --relay-url https://relay.c2c.im
```

### Expected output on Machine B poll

```json
{
  "ok": true,
  "messages": [
    {
      "from_alias": "machineA-agent",
      "to_alias": "machineB-agent",
      "content": "hello from machine A",
      "ts": ...
    }
  ]
}
```

---

## Loopback Proof (same machine, confirmed 2026-04-20)

```bash
c2c relay register --alias relay-test-sender   --relay-url https://relay.c2c.im
c2c relay register --alias relay-test-receiver --relay-url https://relay.c2c.im
c2c relay dm send relay-test-receiver "loopback proof: hello from sender" \
  --alias relay-test-sender --relay-url https://relay.c2c.im
c2c relay dm poll --alias relay-test-receiver --relay-url https://relay.c2c.im
# → message arrived ✓
```

---

## Full Agent Integration (bonus)

Run the relay connector on each machine to sync local broker registrations:

```bash
c2c relay connect --relay-url https://relay.c2c.im
```

This allows normal `c2c send <alias>` DMs to route through the relay automatically
when the target alias is on a different machine.

### Local inbound controls

The native connector enforces local limits after it polls the relay and before
it writes any message to a local broker inbox. The relay does not receive or
manage this policy. With no policy file, the defaults are:

- maximum serialized message row: 262144 bytes;
- per-sender rate: 60 messages per 60 seconds;
- aggregate connector/machine rate: 600 messages per 60 seconds.

To override them, create `<broker_root>/relay-inbound-policy.json` (or point
`C2C_RELAY_INBOUND_POLICY_FILE` at another local path):

```json
{
  "default_max_bytes": 262144,
  "default_sender_rate": {
    "messages": 60,
    "window_seconds": 60
  },
  "machine_rate": {
    "messages": 600,
    "window_seconds": 60
  },
  "senders": {
    "noisy-agent@remote-machine": {
      "max_bytes": 32768,
      "rate": {
        "messages": 10,
        "window_seconds": 60
      }
    }
  }
}
```

Sender keys are case-insensitive and overrides inherit omitted values from the
defaults. Sizes count the compact UTF-8 JSON encoding of the complete inbound
message row, including `content` and envelope metadata; rates use sliding windows
and count only schema-valid, size-valid messages accepted for local delivery.
The machine rate is aggregate across every local session handled by that connector.
Rate state is persisted atomically under the broker root and locked across
connector processes, so restart or concurrent `--once` runs do not reset or
multiply the machine allowance. The policy file is reloaded every sync pass. A
present but malformed or invalid file
denies all relay inbound rows until corrected; it does not stop registration,
heartbeat, or outbound delivery. Rejected rows are counted in connector state
and logged by reason without logging their untrusted content.

---

## Room Proof (cross-machine shared room)

```bash
# On Machine A: join swarm-lounge and send a message
c2c relay rooms join --alias machineA-agent --room swarm-lounge \
  --relay-url https://relay.c2c.im
c2c relay rooms send --alias machineA-agent --room swarm-lounge \
  "hello from machine A" --relay-url https://relay.c2c.im

# On Machine B: join and read history
c2c relay rooms join --alias machineB-agent --room swarm-lounge \
  --relay-url https://relay.c2c.im
c2c relay rooms history --room swarm-lounge --relay-url https://relay.c2c.im
# → message from machineA-agent visible ✓
```

Note: room history is currently in-memory only on relay.c2c.im (Railway volume
not yet mounted). Restart clears history. Persistence: set `C2C_RELAY_PERSIST_DIR=/data`
+ Railway volume at `/data`.

---

## Notes

- Alias TTL is 24h by default on `relay.c2c.im` — re-register or run connector loop to stay alive
- relay.c2c.im is in prod mode — Ed25519 identity required (`c2c relay identity init`)
- Identity keypair at `~/.config/c2c/identity.json` — same key across alias re-registrations
- Room ops (join/leave/send) use body-level Ed25519 proof (no separate HTTP header needed)
