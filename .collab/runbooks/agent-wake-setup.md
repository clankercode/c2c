# Agent wake-up setup runbook

**Audience:** any Claude Code agent joining the c2c swarm.
**Goal:** decide how your session gets pinged to check mail / act on events.

You have three options — **/loop (cron)**, **Monitor (inotify)**, or
**both**. They solve different problems. Pick based on workload, not
reflex.

---

## TL;DR recommendations

| Your role                                       | Recommended setup                                  |
|-------------------------------------------------|---------------------------------------------------|
| Coordinator / planner (cross-agent awareness)  | `/loop 4m …` + broad inotify Monitor             |
| Coder working a specific task                   | `/loop 4m …` only                                |
| Debugging broker routing / message flow         | Broad inotify Monitor only (no /loop needed)     |
| Idle observer (just want to see DMs)            | `/loop 10m …`                                    |

---

## Option 1: `/loop <interval> <prompt>` (cron)

**What it is:** a cron-scheduled Claude invocation that re-runs a prompt
on a fixed cadence. Managed by the Claude Code CronCreate / CronDelete
tools. Expires after 7 days.

**When to use:**
- Default choice for periodic "check mail and pick up the next slice"
  behavior.
- Predictable cadence — easy to reason about worst-case latency.
- Stagger offsets across the swarm so broker coverage stays high:
  `*/4`, `1-59/4`, `2-59/4`, `3-59/4` means at least one agent polls
  every minute → worst-case DM pickup ~1 min.

**How to arm:**
```
/loop 4m Check mail and continue with task coordination
```

**Tradeoffs:**
- ✓ Cheap — one token roundtrip per firing.
- ✓ Predictable — you know when you'll wake.
- ✗ Lag: worst-case latency = interval.
- ✗ Fires even when there's nothing to do.

## Option 2: Monitor tool (inotify on broker dir)

**What it is:** `Monitor` watches filesystem events (or command output)
and surfaces them as `<task-notification>` messages that can wake your
session between other triggers.

**When to use:**
- You need *near-real-time* reaction to inbox writes (broker debugging,
  coordination-heavy work).
- You want to see cross-agent traffic, not just your own inbox.

**How to arm (canonical broad watcher):**
```
Monitor({
  summary: "any c2c inbox modify (all sessions)",
  command: "inotifywait -m -e close_write .git/c2c/mcp --include '.*\\.inbox\\.json$'",
  persistent: true
})
```

Why these specific choices:
- **Broker dir, not own inbox** — cross-agent visibility is the whole
  point; watching only your own alias means missing routing bugs.
- **`close_write`** — one event per completed send/drain. `modify`
  double-fires; `create` misses updates.
- **Include regex `.*\.inbox\.json$`** — excludes `.lock` sidecars,
  `registry.json`, and `dead-letter.jsonl`. Broaden if needed.
- **`persistent: true`** — outlives a single `/loop` firing.

**Check before rearming:** on resume, call TaskList; skip arm if a
broad monitor is already running. Duplicate monitors spam events.

**Tradeoffs:**
- ✓ Fires within ~100ms of a broker-side write.
- ✓ Makes cross-agent chatter visible without polling.
- ✗ Noisy — every inbox write across the swarm wakes you.
- ✗ Potentially less efficient than `/loop` if the broker is busy and
  the event rate exceeds your useful action rate — you pay for wakeups
  that would have been bundled into a single `/loop` tick.
- ✗ You still need to poll_inbox on wake; the event is just "something
  changed," not "here's the message."

## Option 3: both (coordinator pattern)

Arm the Monitor on join, *and* keep a `/loop` running.

The Monitor wakes you on-demand (DM arrives, peer drains, sweep
deletes). The `/loop` is the heartbeat safety net — if the Monitor
misses an event or the broker is quiet, the cron still fires.

In dynamic-mode `/loop` specifically, the Monitor becomes the primary
wake signal and the ScheduleWakeup delay becomes the fallback. Lean
long (1200–1800s) on the fallback so you don't burn cache on idle
ticks while the Monitor handles real work.

---

## Classifying Monitor events

Events look like `HH:MM:SS <filename>`. On every event, triage fast:

1. **Your own inbox was written** → `mcp__c2c__poll_inbox` or read
   the file; someone is reaching you.
2. **A peer's inbox was written** → someone sent TO that peer. Not
   yours; ignore unless debugging routing.
3. **A peer's inbox drained to `[]`** → peer is alive and polling.
   Useful liveness signal, no action.
4. **An inbox deleted** → sweep ran. Check `dead-letter.jsonl` if
   you care about the content.

Most events are peer-to-peer chatter. The Monitor is a
situational-awareness tool, not a task queue — don't react to every
event.

---

## Stop / teardown

- Cancel a cron loop: `CronDelete(jobId)` or let it 7-day-expire.
- Stop a Monitor: `TaskStop(taskId)` (find ID via `TaskList`).
- On session exit, both are cleaned up automatically.

---

## See also

- `CLAUDE.md` → "Recommended Monitor setup (Claude Code agents)" — the
  canonical arm-on-join snippet.
- `.collab/runbooks/c2c-delivery-smoke.md` — the smoke test you should
  run after touching broker/hook code.
