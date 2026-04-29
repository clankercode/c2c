# #335 — Resume-drain stale-nudge flood (initial investigation)

**Author:** stanza-coder
**Date:** 2026-04-28 13:35 AEST (UTC 03:35)
**Status:** v0 — first-pass investigation, no fix yet
**Reporter:** Max + coordinator1 (DM trail; first-hand confirmation by stanza on session resume post-OOM)

## Symptom

When `c2c start` (or any MCP-spawning client) comes back up after a dark
period, the agent's inbox returns a large batch of `[c2c-nudge]` messages
on the first drain. Buries any peer DMs that arrived in the same window.

- **Max 2026-04-28 ~12:58 AEST**: "bug: when c2c start comes back up,
  there can be like a LOT of messages in the inbox that get drained
  immediately (often just heartbeats or something)"
- **Max ~13:00**: "btw it seems like that message flood affects opencode
  but not claude"
- **Max ~13:01** (possibly related): "also galaxy may be getting double
  delivery" → filed as #337.
- **stanza first-hand**: on post-OOM resume today, my own
  `c2c poll-inbox` returned 18+ consecutive nudge lines.

## Evidence (broker archive at 2026-04-28 03:35 UTC)

Per-alias nudge totals in `archive/<alias>.jsonl`:

| Alias            | Nudge entries | Notes                                  |
|------------------|---------------|----------------------------------------|
| `Lyra-Quill-X`   | **135**       | Long-dead session, never resumed       |
| `stanza-coder`   | 45            | Two batches: 41 yesterday + 4 today    |
| `test-agent-oc`  | 20            |                                        |
| `jungle-coder`   | 20            |                                        |
| `galaxy-coder`   | 19            |                                        |
| `coordinator1`   | 19            |                                        |

stanza-coder's drain timestamps cluster at **two moments**:
- **41 nudges drained at ts 1777249210** (2026-04-27 03:00 UTC, ~13:00
  AEST yesterday — corresponds to my session resume after the previous
  long idle window).
- **4 nudges drained at ts 1777344826** (2026-04-28 02:53 UTC, today's
  session start after the OOM).

Pattern: nudges accumulate in the inbox while the recipient's session
is dead, then drain en masse on resume.

## Root-cause shape (hypothesis, not confirmed)

**The nudge scheduler runs in EVERY active MCP server**, not centrally.
Each session's `c2c_mcp_server.exe` starts its own Lwt loop in
`relay_nudge.start_nudge_scheduler` and iterates the **shared registry**
on every tick. So with N alive peers, every cadence period (default
30 min) fires up to N independent nudge ticks, each able to enqueue a
nudge to every idle session — including each other.

Three contributing problems on top of that:

1. **Multi-broker amplification.** The N-MCP-servers issue means N
   ticks/cadence-period — not one. If the scheduler is meant to be a
   singleton, it isn't currently.
2. **`registration_is_alive` returns `true` when `pid = None`**
   (`ocaml/c2c_mcp.ml:917`). A pidless registration row stays "alive"
   forever and accumulates nudges indefinitely. Lyra-Quill-X's 135
   nudges look consistent with this — registration `alive: null` in
   `c2c list`, no actively-tracked PID.
3. **No de-dupe / no inbox-cap.** Identical nudge texts ("grab a task?
   check the swarm-lounge for open items.") drained 4 times in one
   batch in the recent stanza data. The scheduler picks `random_message`
   each tick with no awareness of what's already queued.

## Why "OpenCode but not Claude"?

Speculative — needs verification:

- **Claude Code's PostToolUse hook drains incrementally** (one tool use
  at a time, via `c2c-inbox-hook-ocaml` — the bash wrapper handles the
  ECHILD race). Even with a queue of 41 messages, the user only sees a
  handful between tool calls; the experience is "trickle, not flood."
- **OpenCode's plugin (`c2c.ts`) likely drains everything on startup
  and injects all messages into the prompt.** I haven't verified — that's
  next-pass work — but it matches the symptom shape ("flood on resume").

If true, the underlying nudge accumulation is the same in both clients;
the difference is purely the drain-and-display mechanism on the
delivery surface.

## Cardinality matters

Yesterday's 41-nudge batch implies hours-long accumulation. With default
cadence=30min × N alive peers ticking independently, accumulation rate
is likely 30 min ÷ N per nudge. So 6 alive peers → 1 nudge / 5 min while
the recipient is idle-and-dead. 41 nudges = ~3.5 hours dark-and-idle, not
20+ hours as it would be if a single tick.

## Code surfaces of interest

- `ocaml/relay_nudge.ml` — scheduler entry, `nudge_tick`, `nudge_session`.
- `ocaml/c2c_mcp.ml:917` — `registration_is_alive` (pid=None → true).
- `ocaml/c2c_mcp.ml:866` — `discover_live_pid_for_session` / self-heal.
- `.opencode/plugins/c2c.ts` — startup-drain-and-inject path (unverified).
- `~/.local/bin/c2c-deliver-inbox` (OCaml) / `c2c-inbox-hook-ocaml` —
  delivery daemons, may amplify the flood at the display surface.

## Proposed v1 slice — diagnostic-only

Same shape as #327. Don't fix on speculation; instrument the actual
behavior so the next OOM-and-resume self-documents. Concrete proposal:

1. **Log every nudge-tick fire** to broker.log: `event:"nudge_tick"`,
   `from_session_id`, `eligible_recipients` (count of alive+idle), `sent`
   (count actually nudged), `skipped_dnd`, `skipped_dead`, timestamp.
2. **Log every nudge-enqueue** (currently only logs at `Logs.info`,
   which goes to stderr): mirror to broker.log structured-JSON line
   matching `log_handoff_attempt`'s shape from #327.
3. **Add `c2c doctor nudge-flood --alias <a> [--since 1h]`** subcommand
   that reads broker.log + archive and reports: total nudges
   enqueued/drained per alias, batch sizes at drain timestamps, distinct
   nudge-tick fires per cadence period (validates the multi-broker
   hypothesis or refutes it).

After landing, wait for the next OOM-and-resume cycle to capture the
trace, then propose the actual fix.

## Stretch (NOT in v1)

- **Singleton-scheduler refactor**: elect one MCP server as the nudge
  authority (file lock or registry-flag). Big-design slice.
- **Inbox cap for nudges**: skip enqueue if the alias's inbox already
  contains > N pending nudges. Small slice but needs care to avoid
  starving real messages.
- **`pid=None` should not mean alive**: tighten
  `registration_is_alive` (Liveness `Unknown` for pidless rows;
  scheduler treats Unknown as "skip"). Owns the Lyra-Quill-X 135-nudge
  pattern.

## Notes

- Filing v0 finding now per coord directive ("file your initial
  observations as a finding doc before instrumentation"). This is
  observe-only.
- Live-repro plan: spin up an OpenCode test session, send peer DMs
  while idle, kill it, resume, capture the drain. Pair-loop galaxy if
  it gets into `c2c.ts`.
- This is the "investigation slice" cousin of #327 — same loop:
  observe → instrument → narrow → maybe-fix.

## Pre-instrumentation evidence (added 2026-04-28 13:55 AEST)

After committing v1a instrumentation (SHA `b6ce5348`), I checked the
existing registry data — **hypothesis 2 (`pid=None → alive=true`) is
already empirically confirmed without waiting for new traces.**

Direct evidence from `<broker_root>/registry.json`:

```
$ jq '[.[] | select(.pid == null)] | length' registry.json
13
$ jq 'length' registry.json
20
```

**13 of 20 registrations have `pid: null`.** Including:

```json
{
  "alias": "lyra-quill",
  "session_id": "Lyra-Quill-X",
  "pid": null,
  "pid_start_time": null,
  "last_activity_ts": 1777202235.868845    // 2026-04-25 21:00 UTC, ~3 days ago
}
{
  "alias": "Lyra-Quill",
  "session_id": "Lyra-Quill",
  "pid": null,
  "pid_start_time": null,
  "last_activity_ts": null                 // never had activity recorded
}
```

`Lyra-Quill-X` is the alias with **135 archived nudges** — the dominant
flood signal. Per `Broker.registration_is_alive` (c2c_mcp.ml:917):

```ocaml
match reg.pid with
| None -> true                  (* THIS BRANCH *)
| Some pid -> ...
```

So the schedule:
- Lyra-Quill-X has been registered with `pid: null` since ~2026-04-25.
- `last_activity_ts` is from 2026-04-25 21:00 UTC.
- `is_alive` returns `true` for this row.
- Idle threshold (25 min) was exceeded ~25 minutes after registration.
- Every nudge_tick fired by every alive MCP server has been enqueueing
  to Lyra-Quill-X for ~3 days.
- Nudges accumulate in inbox until next drain. No drain ever happens
  because Lyra-Quill-X session has been gone.

**This refutes the "nudges only fire to alive sessions" assumption I
had earlier.** They DO fire — `pid=None` is a "we don't know, assume
alive" branch that the scheduler never re-evaluates. Combined with no
inbox-cap, the result is unbounded accumulation per zombie row.

**Multi-broker amplification (hypothesis 1)** is still on the table.

**Correction (added 14:00 AEST, post Max-flag):** Lyra-Quill-X is a
codex test session that was active yesterday, not a 3-day-dark zombie.
Re-ran the archive timing:

```
$ jq -r 'select(.from_alias=="c2c-nudge") | .drained_at' \
       archive/Lyra-Quill-X.jsonl | sort -n | uniq -c | tail
   1 1777182960   # 2026-04-26 ~16:36 UTC
   1 1777183054
   1 1777183415
   1 1777183777
   1 1777198135   # ~20:35 UTC
   1 1777198207
   2 1777204570   # 22:16 UTC
 127 1777254550   # 2026-04-27 04:29 UTC = 14:29 AEST (her resume)
```

So 127 nudges drained in ONE batch at her resume yesterday, spanning
~19.9 hours of dark accumulation. At single-broker 30min cadence that's
~40 expected ticks. She got 127. **~3x amplification.**

**Hypothesis 1 (multi-broker / multi-tick) is contributing.** Two
candidate mechanisms:
- ≥3 alive peers were running their own nudge schedulers in parallel,
  ticking at her independently every cadence period.
- #340 double-spawn (filed by coord1 same day) — post-OOM resumes
  ended up with 2x MCP servers per OpenCode alias, each running its
  own nudge tick. With multiple OpenCode peers in this state, single-
  apparent-peers contribute multiple tick events.

Probably both. The v2a fix (alive-check tightening) addresses the
Lyra-class accumulation but won't take 127 down to ~40 — the multi-
tick amplifier is its own slice (#340 helper-cleanup). Together they
explain the full picture.

**Implications for v2 (fix slice):**

1. **Tighten `registration_is_alive`** so `pid: None` returns `false`
   (or `Unknown` treated as skip-by-scheduler). That alone would stop
   the Lyra-Quill-X-class flood. Single-line behavior change with
   sweep-side cleanup as follow-up.
2. The fix should land BEFORE multi-broker investigation — it removes
   the dominant signal so the trace data for hypothesis #1 is cleaner.
3. **Sweeper hardening**: pidless rows older than some TTL should be
   GC'd. Otherwise even with the alive-check fix, the rows persist as
   junk. Probably its own slice.

I'll DM coordinator1 with this and propose v2 as a one-line behavior
flip plus tests, no further instrumentation needed for the Lyra-class
case.

— stanza-coder
