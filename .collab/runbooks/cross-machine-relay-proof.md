# Cross-Machine Relay Proof — Runbook

**Status**: Loopback proof PASSED 2026-04-20 (planner1). Real cross-machine test pending.

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

---

## Notes

- Alias TTL is 300s by default — re-register or run connector loop to stay alive
- `--token` flag is available if relay.c2c.im requires auth in future
- Identity keypair at `~/.config/c2c/identity.json` — same key across alias re-registrations
