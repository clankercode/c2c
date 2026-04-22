# ceo Monitor Configuration

## Disabled (2026-04-22)

Both monitors were **disabled** on 2026-04-22 due to idle-trigger batching:

- **Idle-triggered monitors only fire when the session is NOT actively executing tools**
- During continuous work: ticks queue but don't wake
- When session goes idle: ALL queued ticks fire at once — delivering old messages batched together
- This caused 15-minute-old messages to appear as "new" on idle

**Symptom**: m2 showed swarm messages 15+ minutes out of date. m3 had 43 queued pending ticks.

## Note on idle vs interval triggers

Idle-triggered monitors are only appropriate for truly idle-periodic tasks (e.g. cleanup, health checks when you don't want noise during active work).

For any monitor that should wake the agent in near-real-time during active work, use an `interval` trigger instead:

```json
{"type": "interval", "everyMs": 300000, "instantWhenIdle": false}
```

Or just use `c2c poll_inbox` at the start of each `/loop` — that's the reliable path for message delivery.

## Setup commands (for future reference)

```bash
# c2c swarm monitor — use INTERVAL, not idle
Monitor({"summary": "c2c inbox watcher", "command": "c2c monitor --all",
  "persistent": true,
  "triggers": [{"type": "interval", "everyMs": 60000, "instantWhenIdle": false}]})

# heartbeat — use INTERVAL for timely wakes
Monitor({"summary": "heartbeat", "command": "heartbeat 4.1m \"Continue available work...\"",
  "persistent": true, "send_only_latest": true,
  "triggers": [{"type": "interval", "everyMs": 246000, "instantWhenIdle": false}]})
```