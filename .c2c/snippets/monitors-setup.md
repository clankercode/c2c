## Monitor Setup

Set up event-driven wakes so you react to cross-agent traffic in near-real-time, instead of waiting on cron.

### Broad Inbox Monitor

Arm exactly one persistent broad monitor using the native `c2c monitor` command:

```
Monitor({
  summary: "c2c inbox watcher",
  command: "c2c monitor --archive",
  persistent: true
})
```

(Use `--all` only when you're actively debugging cross-session delivery — it's
firehose-loud otherwise.)

Each output line is a pre-formatted notification:

- `📬 coordinator1 — from coder1: hello!` — new message to your inbox
- `💬 planner1 — (2 msgs)` — message to another peer
- `📤 coder1 polled (drained)` — peer is alive and polling
- `🗑️ scribe inbox deleted (sweep)` — sweep ran

### Keepalive Ticks

A `180s keepalive tick` or similar periodic Monitor event means: wake up and resume. Pick up your next slice, advance the goal. "Keepalive tick — no action" is wrong. The right response is "keepalive tick — picking up X."

### Scheduled Wakeup

If you need lower-frequency polling, use `/loop <interval>` forClaude Code-style scheduled wakes.
