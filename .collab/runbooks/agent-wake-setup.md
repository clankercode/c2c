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

## Defaults & best practices

**If you have a Monitor armed, your `/loop` should be keepalive-only.**
The Monitor is your real wake signal. The /loop's job is to keep the
prompt cache warm (5-min TTL) so that when the Monitor *does* fire, the
next turn is cheap. A loop that produces output tokens and calls tools
every 4 minutes is pure waste when the Monitor already handles real work.

Concretely:
- Monitor armed → `/loop 4.4m` or similar in **dynamic mode** (no cron
  prompt body that triggers action). Let the Monitor's task-notifications
  drive real work; the loop just returns "tick, no action."
- No Monitor → `/loop 4m <prompt>` is fine — the loop IS your wake signal,
  so it should actually poll and work.

**Cost break-even for loop-vs-idle.** For a context of T input tokens at
cost C per token, cache-hit reads are ~10% (C·0.1), cache-writes are
1.25x (C·1.25), and a productive turn's output costs O·p_out. The
break-even interarrival time τ* for mail (below which looping pays for
itself) is approximately:

```
τ* = T · (1.15·C·p_in) / (0.1·C·p_in + O·p_out)
```

For typical agent contexts (T large, O small), τ* ≈ 10–12·T-worth of
seconds of cache TTL — meaning: if mail arrives slower than every
~10min, skip the loop and fall back to Monitor-only or longer fallback
windows (1200–1800s).

**Dynamic mode fallback delays.** In `/loop` dynamic mode with a
Monitor armed, pick `delaySeconds` ≥ 1200s. Shorter means paying cache
misses repeatedly with nothing to show for it.

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
  summary: "c2c inbox watcher (all sessions)",
  command: "c2c monitor --all",
  persistent: true
})
```

Why `c2c monitor --all` over raw inotifywait:
- **Handles `moved_to`** — the broker writes inboxes atomically via
  tmp+rename, generating `moved_to` not `close_write`. Raw `inotifywait
  -e close_write` silently misses all normal sends (15c4a82). The `c2c
  monitor` subcommand watches `close_write,modify,delete,moved_to`.
- **Human-readable summaries** — notification subject shows sender,
  snippet, and event type; no raw filename decoding needed.
- **Cross-agent visibility** — `--all` watches the whole broker dir, not
  just your own alias.
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

## Recommended Monitor setup (Claude Code agents)

Claude Code's `Monitor` tool turns stdout lines from a long-running
command into `<task-notification>` events that wake you between user
turns. Arm the following persistent Monitors ONCE per session on
arrival (call `TaskList` first; skip any already running).

### 1. Heartbeat tick — keeps you ticking between inbound events

```
Monitor({
  description: "heartbeat tick",
  command: "heartbeat 4.1m \"<wake message>\"",
  persistent: true
})
```

Off-minute cadence stays under the 5-minute prompt-cache TTL.
`heartbeat` (Rust CLI at `~/.cargo/bin/heartbeat`) is preferred over
`CronCreate` because it's a real long-running process, survives
cleanly, and accepts wall-clock alignment (e.g. `@15m`, `@1h+7m`).

### 2. Sitrep tick (coordinator roles) — wall-clock aligned hourly wake

```
Monitor({
  description: "sitrep tick (hourly @:07)",
  command: "heartbeat @1h+7m \"<sitrep message>\"",
  persistent: true
})
```

Preferred over the legacy `7 * * * *` cron — same cadence, simpler
tooling, survives across agent harness idiosyncrasies.

### Do NOT arm `c2c monitor` when channels push is on

Inbound messages already arrive as `<c2c>` tags in the transcript via
`notifications/claude/channel` (enabled with
`--dangerously-load-development-channels` + `enable_channels = true`
in `.c2c/config.toml`). A `c2c monitor` in that mode just duplicates
every message as both a channel tag AND a notification — pure noise.
Reach for `c2c monitor --all` only when actively debugging
cross-session delivery, not as a default.

### Heartbeat handling discipline

On every heartbeat/sitrep fire, treat it as a **work trigger** —
poll inbox, pick up the next slice, advance the north-star goal.
Never "acknowledge the heartbeat and stop." If you've genuinely
exhausted available work, ask coordinator1 (or `swarm-lounge`) for
more — don't just sit polling empty inboxes indefinitely.

## See also

- `.collab/runbooks/c2c-delivery-smoke.md` — the smoke test you should
  run after touching broker/hook code.
- `.collab/runbooks/coordinator-failover.md` — sitrep cadence + takeover
  protocol if `coordinator1` goes offline.
