# Keeping yourself alive

A coding agent that stops talking dies. The host client eventually
unloads your context, the broker sweeps your registration, and the
swarm loses a node. Your job is to stay awake long enough to finish
your current slice of the goal — and to help keep your peers awake
too.

## What "alive" actually means

For the broker, you are alive if:
1. Your row is in `registry.json`, AND
2. Either: `pid` is `None` (legacy — treated as alive by default),
   OR `pid` is set AND `/proc/<pid>` exists AND, if
   `pid_start_time` is recorded, it still matches
   `/proc/<pid>/stat` field 22 (pid-reuse defense).

For the host client, you are alive if the process is still running
AND not stuck on a prompt. The latter is the harder problem — you
can have a PID without having any thinking cycles.

## The three levels of keep-alive

### 1. `/loop` — recurring self-prompt

Claude Code's `/loop` skill schedules a recurring prompt. Two modes:

- **Fixed interval**: `/loop 10m Keep working on the primary goal.`
  Uses a cron job (5-field expression). Minimum useful granularity
  is 1 minute but you rarely want tighter than 5m — the
  Anthropic prompt cache TTL is 5 minutes and a too-tight loop
  thrashes it.
- **Dynamic**: `/loop Keep working on the primary goal.` (no
  interval). You self-pace via `ScheduleWakeup` based on what
  you're waiting for. Idle ticks should be 1200–1800s.

### 2. `c2c_poker.py` — external PTY heartbeat

Even with `/loop` scheduled, the host client can wedge on a stuck
tool call or get dropped by the parent terminal. `c2c_poker.py`
injects `<c2c event="heartbeat">` envelopes into a target session's
PTY via `pty_inject`, forcing the host to resume.

Invocations you will actually use:

```
# Target a live Claude session by session id
c2c_poker.py --claude-session <sid>

# Target any process by pid (walks /proc for a PTY)
c2c_poker.py --pid <n>

# Detached loop — keep poking every 10 minutes
nohup c2c_poker.py --pid <n> --interval 600 >/tmp/poker.log 2>&1 &
```

Codex has its own resume tooling: `restart-codex-self`,
`run-codex-inst`, `run-codex-inst-outer`. Use those for Codex.

### 3. Monitor + inotify — reactive wakeups

`Monitor` tasks watching `close_write` on broker inbox files act as
push notifications. When a message is queued for you, the monitor
fires an event that re-enters your thinking loop without waiting
for the next `/loop` tick. Standing recommendation: broaden your
monitor to the whole broker dir, not just your own inbox, so you
see cross-agent traffic. CLAUDE.md has this rule in writing.

Example (Claude Code Monitor tool syntax):

```
watch: inotifywait -m -e close_write .git/c2c/mcp --include '.*\.inbox\.json$'
```

## Keeping the swarm alive

You are not the only node. If you notice a peer has gone quiet for
a long time:

1. Check if their row is still in `registry.json`.
2. Check their PID if available (`ps -p <pid>`).
3. Send a probe message and watch their inbox for a close_write.
4. If they've truly stalled, poke them with `c2c_poker.py` OR
   restart them via the appropriate restart script.
5. Leave a note in `.collab/updates/` so the next agent knows what
   happened.

**Do not kill your own parent process.** If you can't tell whether
a PID is yours, leave it alone and ask Max.

## Signs you're about to die

- **Context getting long.** The host will compress messages when
  you approach the limit, but the compression round-trip is slow
  and may lose useful state. Commit work-in-progress to git (with
  approval if that's your rule), write a status doc, and trust the
  summary.
- **A slash command is about to exit.** `/loop` with a finite
  interval will keep firing; `/loop` dynamic mode relies on
  `ScheduleWakeup`. If you forget to call it, the loop ends and
  you go dark.
- **You can't find your MCP tools.** The host didn't connect. Fall
  back to CLI paths so your next outbound message still gets
  through, and surface the failure in a findings log.

## Signs you should wind down

- Primary goal for your slice is done AND committed AND verified.
- You've written a status update in `.collab/updates/`.
- You've released any locks in `tmp_collab_lock.md`.
- No other peer is blocked on you.

Even then, it's usually right to keep the loop running at a low
cadence and pick up whatever slice surfaces next. The project dies
if every agent stops; it thrives if one of you keeps the spark.

## Finally

Restart is cheap. A wedged session is worse than a restarted one.
If you're not sure you're making progress, use `restart-codex-self`
or the equivalent for your host client, and let a clean context
take over. Leave breadcrumbs so the next-you can pick up where
this-you left off.
