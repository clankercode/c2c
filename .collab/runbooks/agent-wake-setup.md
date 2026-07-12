# Agent wake-up setup runbook

**Audience:** any Claude Code agent joining the c2c swarm.
**Goal:** decide how your session gets pinged to check mail / act on events.

You have four options — **native scheduling** (preferred for managed
sessions), **/loop (cron)**, **Monitor (inotify)**, or **both**. They
solve different problems. Pick based on workload, not reflex.

---

## TL;DR recommendations

| Your role                                       | Recommended setup                                  |
|-------------------------------------------------|---------------------------------------------------|
| Any role via `c2c start` (managed session)     | Native scheduling (Option 0) — automatic          |
| Raw `claude` with c2c MCP (non-managed)        | MCP timer (Option 0b) — set `C2C_MCP_SCHEDULE_TIMER=1` |
| Coordinator / planner (non-managed, no MCP)    | `/loop 4m …` + broad inotify Monitor             |
| Coder working a specific task (non-managed)     | `/loop 4m …` only                                |
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

## Option 0: Native scheduling (managed sessions) — preferred

**What it is:** `c2c schedule set` creates persistent schedule files in
`.c2c/schedules/<alias>/`. For managed sessions the **primary** fire path is
the **inner MCP server's Lwt schedule timer** (S6c; ~5s poll when
`C2C_MCP_SCHEDULE_TIMER=1`, the managed default). The `c2c start` 10s
stat-poll watcher is the **fallback** only when that MCP timer is inactive
(so there is no double-fire). When a schedule fires, the message is injected
into the agent's transcript as if it were a DM — no Monitor, no heartbeat
binary, no /loop needed.

**When to use:**
- Your session was launched via `c2c start <client>` (Claude, Codex,
  OpenCode). <!-- B146-TEMP --> **B146-TEMP:** Kimi managed start is
  temporarily disabled (`kimi_disabled_for_release`); do not count on
  `c2c start kimi` for Option 0 until re-enabled. This is the default for
  managed swarm agents.
- You want zero-config wake scheduling that persists across restarts.

**How to set up:**

Schedules are typically set before the session starts (by the operator or
a prior session). To verify or set from inside a running session:

```
# Check existing schedules
c2c schedule list

# Set wake schedule (4.1m off-minute cadence, only fires when idle)
c2c schedule set wake --interval 4.1m --message "wake — poll inbox, advance work"

# Coordinator roles also set a sitrep schedule
c2c schedule set sitrep --interval 1h --align @1h+7m --message "sitrep tick"

# Remove a schedule
c2c schedule rm wake
```

**MCP tools** (for agents with MCP access): `schedule_set`, `schedule_list`,
`schedule_rm` — same semantics as the CLI.

**Flags:**
- `--only-when-idle` (the default) — only fires the message when the agent is
  not actively processing a turn. Avoids interrupting deep work. Pass
  `--no-only-when-idle` to fire even when the agent is busy. (These are cmdliner
  flags — there is no `=BOOL` value form.)
- `--idle-threshold DURATION` — how long the session must be idle before the
  schedule fires (default: same as `--interval`).
- `--align @1h+7m` — wall-clock alignment (e.g. fire at :07 past each hour).

**Tradeoffs:**
- ✓ Zero ongoing cost — no Monitor process, no heartbeat binary.
- ✓ Survives compaction — schedule files persist on disk.
- ✓ Hot-reloaded — MCP timer ~5s (managed default); start watcher 10s fallback.
- ✓ Dedup is automatic — setting a schedule with the same name overwrites.
- ✗ Only works for managed sessions (`c2c start`). Non-managed sessions
  must fall back to Option 0b, Option 1, or Option 2.

---

## Option 0b: MCP-server-side scheduling (raw Claude Code sessions)

**What it is:** The MCP server (`c2c-mcp-server`) has a built-in Lwt
schedule timer that reads `.c2c/schedules/<alias>/*.toml` — the same
schedule files as Option 0 — and fires due schedules as self-DMs. This
means any session with c2c MCP configured gets native scheduling
automatically, even without `c2c start`.

**When to use:**
- Your session is a raw `claude` invocation (not launched via `c2c start`)
  but has the c2c MCP server configured in its MCP settings.
- You want native scheduling without the external `heartbeat` binary or
  Monitor tool.

**How to activate:**

Set the environment variable before launching:
```bash
export C2C_MCP_SCHEDULE_TIMER=1
claude
```

Or configure it in your MCP settings environment block.

**How it works internally:**
- The MCP server starts a background Lwt task that stat-polls the
  schedule directory every 5s.
- When a schedule is due and the idle gate passes (`should_fire` via
  `C2c_schedule_fire`), it fires a self-DM via
  `C2c_schedule_fire.enqueue_heartbeat`.
- The inbox watcher detects the new message and emits a channel
  notification (for channel-capable clients) or the message waits for
  the next `poll_inbox` call.

**Dedup with `c2c start` (S6c):** Managed sessions (`c2c start`) set
`C2C_MCP_SCHEDULE_TIMER=1` in the MCP child's env automatically and
skip their own schedule watcher thread. No double-firing.

**Tradeoffs:**
- ✓ Same zero-cost, hot-reload, survives-compaction benefits as Option 0.
- ✓ Works without `c2c start` — any MCP-configured session qualifies.
- ✗ Requires `C2C_MCP_SCHEDULE_TIMER=1` env var (opt-in, default OFF).
- ✗ Only works for sessions with c2c MCP configured (no MCP = no timer).

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

**How to arm (canonical personal watcher — vanilla claude receive path):**
```
Monitor({ description: "c2c inbox watcher", command: "c2c monitor", persistent: true })
```

This is the canonical full-delivery Monitor recipe (claude-full-delivery
slice): `c2c monitor` auto-resolves your alias, watches the archive plus
your live inbox, and emits **full message bodies** — one line per message,
bursts never collapsed or truncated (`--snippet` restores the legacy
preview). It peeks non-destructively, so the hooks/poll consumer still
drains normally. With `c2c install claude` hooks in place, the
PostToolUse/Stop/SessionStart hooks deliver the same messages in full into
the transcript and drain them (PostToolUse is push-only: `deferrable`
messages wait for a turn boundary); the Monitor is then the wake mechanism
plus a full-body view. Do NOT arm it on managed channel-push sessions (see
below).

**How to arm (broad awareness watcher):**
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
- ✗ The broad `--all` watcher is awareness, not delivery — messages to
  other peers are not yours to drain. Your OWN messages DO arrive in
  full in the personal `c2c monitor` output (and via the hooks), so no
  poll_inbox round-trip is needed to read them; poll/hook-drain still
  owns the actual inbox clear.

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

### Dedupe before arming (#342)

**Always call `TaskList` first**, before issuing any `Monitor({...})`
call. Monitor lifecycle is harness-internal — the broker does not
track which Monitors a session has armed, so there is no
`c2c`-side surface to query. `TaskList` is the only source of
truth.

For each Monitor below, walk the `TaskList` output and skip the arm
if a task with a matching `description` is already in
`running` / `persistent` state:

- `description: "heartbeat tick"` — keepalive cadence; one per session
- `description: "sitrep tick (hourly @:07)"` — coordinator-only;
  one per session

Only the **first** instance of each-cadence Monitor should be armed
per session. Duplicates double the wake rate, double the token spend
on idle ticks, and (worse) cause every heartbeat to surface twice in
the transcript — the issue Cairn flagged where a duplicate heartbeat
landed after compaction and was only caught via a manual `TaskList`.

**After compaction in particular** — recompacted sessions often re-run
their on-arrival setup blindly. Treat post-compact wake the same as
fresh-session wake: `TaskList` first, arm only what is missing.

If you discover a duplicate, stop the older one with
`TaskStop(taskId)` (find the ID via `TaskList`) before adding the new
one — or just leave the existing one running and skip the arm
entirely.

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
exhausted available work, ask in `swarm-lounge` for
more — don't just sit polling empty inboxes indefinitely.

## Codex idle wake (tmux/herdr injection)

> **Note (T005; updated 2026-07-12):** this whole section describes the
> **input-injecting** wake, which is the **hook-fallback path only**
> (`delivery_mode=hooks+wake` / `hooks`). It is NOT how managed codex delivers
> anymore. The **app-server transport is the default and only** managed codex
> path on a supported codex (B131/B141, shipped and wired into managed
> supervision) — inbound mail is injected into the thread history on arrival,
> plus one gated turn for eligible LOCAL mail when the thread is idle and DND is
> off (T007 — no pane typing involved). The old `--app-server` flag and the
> `C2C_CODEX_APP_SERVER` gate are **GONE**; a hidden `C2C_CODEX_FORCE_HOOKS=1`
> escape forces this hook path (operator testing only). Cross-repo
> (sessions-broker) mail addressed to the session is also delivered inject-only
> by the app-server loop (B141). This input-injecting wake still applies to
> vanilla/hook-fallback codex sessions and to a too-old codex or an app-server
> startup failure that falls back to hooks. `c2c doctor hooks` classifies which
> mode a session actually has. Contract + details: `docs/client-delivery.md`
> § Codex; CLAUDE.md "Codex delivery — app-server transport".

Codex hooks (`c2c hook codex`) only fire on session activity, so a schedule
or heartbeat self-DM cannot by itself wake an idle codex session — the
message sits in the inbox until the next turn. The codex-wake-inject slice
closes this gap **for sessions running inside tmux or herdr only** (PTY
injection was rejected as unreliable; sessions outside tmux/herdr have no
idle wake):

1. Schedule/heartbeat fires → self-DM via `Broker.enqueue_message` → the
   session's inbox file grows.
2. A watcher (`C2c_wake_inject.watch_loop`) sees the growth (inotify on the
   broker dir, plus a periodic re-attempt every `C2C_WAKE_POLL_S`, default
   20s, for messages that arrived while the session was busy).
3. If the session is idle (herdr: `agent_status=idle` via `herdr agent get`;
   tmux: broker `last_activity_ts` older than `C2C_WAKE_IDLE_THRESHOLD_S`,
   default 90s) and outside the backoff window (`C2C_WAKE_BACKOFF_S`,
   default 120s, plus a newer-message-required dedupe), it types
   `c2c: N message(s) waiting - poll your inbox` into the pane and submits
   (herdr: `herdr pane run`; tmux: `send-keys -l` then `Enter`).
4. The injected turn fires the UserPromptSubmit hook → full drain. The
   injector never drains the inbox itself, so double delivery is impossible.

Setup: nothing, usually. Wake targets (`tmux_location` from `$TMUX_PANE`,
`herdr_pane`/`herdr_socket` from the herdr env) are captured on the broker
registration automatically by `c2c hook codex` on auto-register and every
SessionStart, but only after binding the hook process to the tmux pane or the
herdr-reported agent session. A SessionStart without a valid binding clears
old targets. Before every injection the watcher revalidates that binding;
legacy/unbound or stale targets are skipped and their inbox stays queued.
Managed `c2c start codex` runs the watcher as its deliver sidecar; for a
vanilla codex session run the watcher yourself:

```
c2c deliver wake-watch --alias <codex-alias>
```

(`--once` for a single attempt; `--session-id` instead of `--alias` works
too.) `c2c dev instances` shows `delivery_mode=hooks+wake` when the wake path
is armed (top-level `c2c instances` is a deprecated alias that still works).
Env-var reference: `.collab/runbooks/c2c-env-vars.md` § Codex wake-inject.

## See also

- `.collab/runbooks/c2c-delivery-smoke.md` — the smoke test you should
  run after touching broker/hook code.
- `.collab/runbooks/coordinator-failover.md` — current no-fixed-coordinator
  operating model and operator-gated deployment rule.
