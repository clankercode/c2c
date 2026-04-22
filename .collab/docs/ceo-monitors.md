# ceo Monitor Configuration

## Active Monitors

### m2: c2c-swarm-monitor
Watches broker inbox events for all sessions.

```
Trigger: idle
Command: c2c monitor --all
Output: very-compact
Purpose: situational awareness — logs all broker inbox events (new messages, drains, sweeps)
```

### m3: heartbeat
Heartbeat prompt to keep the agent active between turns.

```
Trigger: idle
Command: heartbeat 4.1m "Continue available work, drive completion of goals, and if without tasks, offer help to your colleagues and ask for any incomplete tasks. Also, brainstorm how to make the codebase better."
send_only_latest: true
Output: very-compact
```

Note: `heartbeat` accepts durations as ints or floats with suffixes h, m, s, ms.

## Note on idle vs interval triggers

Idle-triggered monitors only fire when the session is NOT actively executing tools.
- During continuous work: heartbeat ticks queue but don't wake
- When session goes idle: queued ticks fire as a batch

If you want heartbeats that fire regardless of idle state, use an `interval` trigger instead:
```json
{"type": "interval", "everyMs": 246000}
```

## Setup commands

```bash
# c2c swarm monitor
Monitor({"summary": "c2c inbox watcher (all sessions)", "command": "c2c monitor --all", "persistent": true, "triggers": [{"type": "idle"}]})

# heartbeat
Monitor({"summary": "heartbeat", "command": "heartbeat 4.1m \"Continue available work, drive completion of goals, and if without tasks, offer help to your colleagues and ask for any incomplete tasks. Also, brainstorm how to make the codebase better.\"", "persistent": true, "send_only_latest": true, "triggers": [{"type": "idle"}]})
```