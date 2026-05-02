# Design: c2c-native agent self-scheduling

**Date**: 2026-05-02
**Author**: stanza-coder
**Status**: Design draft
**Originator**: Max Kaye (via coordinator1)
**Related**: `managed_heartbeat` in `c2c_start.ml`, `DRAFT-scheduled-agent-runs.md`,
`todo-ideas.txt` lines 142–188, agent-wake-setup runbook

## Context

Agents currently rely on two external mechanisms for periodic wake-ups:

1. **`heartbeat` binary** — a standalone Rust CLI installed at
   `~/.cargo/bin/heartbeat`. Agents arm it via `Monitor` tool; it
   sleeps for a duration, emits a line to stdout, Monitor fires a
   notification. Simple but: external dependency, no idle gating, no
   persistence across compaction, no agent-writable configuration.

2. **`Monitor` tool** — Claude Code built-in. Arms a persistent
   background process. Works, but: (a) not available in Codex/OpenCode
   (so those clients need a different path), (b) Monitor is tied to the
   coding-CLI session lifetime, (c) the heartbeat binary is just a
   `sleep` wrapper — c2c can do this natively.

Meanwhile, `c2c_start.ml` already has a **`managed_heartbeat`** system
that's 80% of what we need:

- OS thread (`Thread.create`) alongside the Lwt MCP server
- Configurable interval with `@<interval>+<offset>` alignment
- `idle_only` flag using `Broker.last_activity_ts` + `agent_is_idle`
- Self-DM via `Broker.enqueue_message` (arrives as channel notification
  or next `poll_inbox`)
- Per-instance override via `<instance-dir>/heartbeat.toml`
- Per-repo config via `.c2c/config.toml` `[[heartbeat]]` sections

**What's missing:**

| Gap | Impact |
|-----|--------|
| No agent-writable CLI surface | Agents can't adjust their own cadence at runtime |
| No hot-reload | Schedule changes require restart |
| Config tied to instance dir | Doesn't survive instance recreation / compaction |
| No `.c2c/schedules/` persistence | Can't inspect/manage schedules out-of-band |
| No MCP tool surface | Agents can't set schedules via tool call |

## Proposed design

### Principle: evolve `managed_heartbeat`, don't rebuild

The existing `managed_heartbeat` infrastructure is solid. Rather than
building a parallel system, we extend it with:

1. Agent-writable persistence to `.c2c/schedules/<alias>/`
2. CLI + MCP tool surface for CRUD
3. Hot-reload via inotify (or polling fallback)
4. Migration path from external heartbeat binary

### 1. Schedule file format

```
.c2c/schedules/<alias>/
├── wake.toml          # main heartbeat schedule
├── sitrep.toml        # hourly sitrep (coordinator only)
└── custom-check.toml  # arbitrary named schedule
```

Each `.toml` file:

```toml
# .c2c/schedules/stanza-coder/wake.toml
[schedule]
name = "wake"
interval_s = 246            # 4.1 minutes
align = ""                  # or "@1h+7m" for wall-clock alignment
message = "wake — poll inbox, advance work"
only_when_idle = true       # skip if agent active within interval
idle_threshold_s = 246      # default: same as interval
enabled = true
created_at = "2026-05-02T07:00:00Z"
updated_at = "2026-05-02T07:00:00Z"
```

**Why per-alias directories?** Agents should only write their own
schedules. The broker root is shared; per-alias directories provide
natural access scoping (same pattern as `.c2c/memory/<alias>/`).

**Why TOML?** Matches `.c2c/config.toml` and `heartbeat.toml`
conventions already in the codebase. Human-readable, agent-editable.

### 2. CLI surface

```
c2c schedule set <name> --interval <duration> [--message <text>]
                         [--align <spec>] [--only-when-idle]
                         [--idle-threshold <duration>]
c2c schedule list                     # show all schedules for current alias
c2c schedule rm <name>                # remove a named schedule
c2c schedule enable <name>            # re-enable a disabled schedule
c2c schedule disable <name>           # pause without removing
```

**Duration format**: `4.1m`, `1h`, `30s`, `240` (bare seconds) —
same parser as existing `managed_heartbeat` interval.

**Align spec**: `@1h+7m` means "align to the next whole hour plus
7 minutes" — existing `next_heartbeat_delay_s` already handles this.

**Examples:**

```bash
# Replace external heartbeat Monitor
c2c schedule set wake --interval 4.1m \
  --message "wake — poll inbox, advance work" \
  --only-when-idle

# Coordinator sitrep tick
c2c schedule set sitrep --interval 1h --align @1h+7m \
  --message "sitrep tick"

# One-shot style (future): fire once after delay, then disable
c2c schedule set build-check --interval 5m --once \
  --message "check if build finished"
```

### 3. MCP tool surface

```json
{
  "name": "schedule_set",
  "description": "Create or update a named self-schedule.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": { "type": "string" },
      "interval_s": { "type": "number" },
      "message": { "type": "string" },
      "align": { "type": "string" },
      "only_when_idle": { "type": "boolean" },
      "enabled": { "type": "boolean" }
    },
    "required": ["name", "interval_s"]
  }
}
```

Plus `schedule_list` and `schedule_rm`. Tool calls write to
`.c2c/schedules/<caller-alias>/` and the hot-reload picks up changes.

### 4. Timer host

**Decision: keep it in `c2c_start.ml` (managed session wrapper).**

Rationale:
- `c2c_start.ml` already owns the `Thread.create` + `Unix.sleepf`
  heartbeat loop pattern.
- It has direct access to `Broker.enqueue_message` for self-DMs.
- It owns the `last_activity_ts` idle-detection signal.
- The MCP server (`c2c_mcp_server_inner.ml`) is the wrong host — it's
  a stdio JSON-RPC server that should stay focused on request handling.
  Adding timer threads there couples scheduling to MCP protocol.
- `c2c_start.ml` survives MCP server reconnects (it's the outer wrapper).

**Change from current**: instead of reading heartbeat config only at
startup, the timer thread periodically checks for file changes in
`.c2c/schedules/<alias>/` (either via inotify or stat-polling with a
5s cadence — inotify preferred but stat-poll is acceptable for v1).

### 5. Hot-reload mechanism

**V1: stat-polling (simple, portable)**

The timer thread already wakes every `interval_s`. On each wake:

1. `stat()` each `.toml` in `.c2c/schedules/<alias>/`
2. If any `mtime` changed since last check, re-parse all schedules
3. Adjust the sleep interval for the next cycle

Cost: one `readdir` + N `stat` calls per wake. Negligible for ≤10
schedule files.

**V2: inotify (future, if needed)**

OCaml has `inotifywait` bindings (`ocaml-inotify`). Add an inotify
watch on `.c2c/schedules/<alias>/`. On `IN_MODIFY` / `IN_CREATE` /
`IN_DELETE`, trigger immediate re-parse. Eliminates the polling
overhead entirely.

Not needed for v1 — stat-polling at heartbeat cadence is fine.

### 6. Idle detection

Already implemented in `c2c_start.ml`:

```ocaml
let agent_is_idle ~now ~idle_threshold_s ~last_activity_ts =
  match last_activity_ts with
  | None -> true     (* never active = idle *)
  | Some ts -> now -. ts > idle_threshold_s
```

`last_activity_ts` is stamped by `Broker.touch_session` on every
`send`, `send_room`, `poll_inbox`, `register` call. This is
broker-activity idle, not model-generation idle — which is the right
granularity for "should I self-DM a wake-up?"

**`only_when_idle` semantics**: skip delivery entirely (don't queue).
The next interval fires normally. Rationale: queuing idle-gated
messages creates a burst on return-to-idle; skip-and-retry is simpler
and matches the current `should_fire_heartbeat` behavior.

**Cross-client parity**: The idle signal is broker-side (tool calls),
not client-side. This means it works identically across Claude Code,
Codex, OpenCode, and Kimi — any client that uses broker tools produces
`last_activity_ts` updates. No client-specific idle detection needed.

### 7. Merge priority (schedule resolution)

Multiple schedule sources exist today:

1. `.c2c/config.toml` `[[heartbeat]]` sections (repo-wide)
2. `<instance-dir>/heartbeat.toml` (per-instance)
3. `.c2c/schedules/<alias>/*.toml` (per-alias, agent-writable) **NEW**

**Resolution order** (highest priority wins):

1. Per-alias schedules (`.c2c/schedules/<alias>/`) — agent's own
2. Per-instance (`heartbeat.toml`) — operator override
3. Repo config (`.c2c/config.toml`) — global defaults

When a per-alias schedule has the same `name` as a repo-config
heartbeat, the per-alias version wins. This lets agents customize
their cadence without editing shared config.

### 8. Migration path

**Phase 1 (this design):**
- Add `c2c schedule set/list/rm` CLI
- Add `.c2c/schedules/<alias>/` persistence
- Add stat-poll hot-reload in `c2c_start.ml`
- Add `schedule_set/list/rm` MCP tools
- Existing `managed_heartbeat` continues to work unchanged

**Phase 2 (after validation):**
- Update agent role files to use `c2c schedule set` in startup instead
  of `Monitor` + `heartbeat` binary
- Deprecate external `heartbeat` binary dependency
- Update `agent-wake-setup.md` runbook

**Phase 3 (future):**
- inotify hot-reload
- `--once` flag for one-shot delayed schedules
- `c2c schedule pause-all` / `resume-all` for maintenance windows
- Schedule introspection in `c2c doctor` output

### 9. Slice plan

| Slice | Scope | AC |
|-------|-------|----|
| S1 | Schedule file format + `c2c schedule set/list/rm` CLI | CLI writes/reads `.c2c/schedules/<alias>/*.toml`, round-trips correctly |
| S2 | Timer thread reads `.c2c/schedules/` at startup | `c2c start` picks up agent-written schedules alongside repo-config heartbeats |
| S3 | Stat-poll hot-reload | Schedule changes picked up without restart within 1 interval |
| S4 | MCP tool surface (`schedule_set/list/rm`) | Agents can manage schedules via tool calls |
| S5 | Migration: update role files + runbook | Agents use `c2c schedule set` instead of Monitor + heartbeat |

S1–S2 can ship together. S3 follows. S4 can parallel with S3. S5 is
the tail cleanup.

## Open questions

1. **Should `c2c schedule` be a tier-1 (all users) or tier-2 (swarm
   agents) command?** Probably tier-2 initially — it's agent tooling,
   not end-user-facing.

2. **Should the MCP tools be auto-registered or opt-in?** Current
   pattern is all tools auto-registered. Schedule tools are low-risk
   (write to own alias dir only), so auto-register seems fine.

3. **Should `--once` be in v1?** Useful for "check build in 5 min"
   patterns, but adds state (schedule disables itself after firing).
   Defer to S3+ unless demand surfaces.

4. **File watching scope**: Should the timer also watch
   `.c2c/config.toml` for hot-reload? Natural extension but broader
   scope — defer to v2.

## Files to change

| Slice | File | Change |
|-------|------|--------|
| S1 | `ocaml/cli/c2c.ml` | Add `schedule` command group (set/list/rm) |
| S1 | `ocaml/c2c_schedule.ml` (new) | Schedule TOML parser + writer |
| S2 | `ocaml/c2c_start.ml` | Load `.c2c/schedules/` alongside existing heartbeat sources |
| S3 | `ocaml/c2c_start.ml` | Add stat-poll reload in heartbeat thread loop |
| S4 | `ocaml/c2c_mcp.ml` | Add `schedule_set/list/rm` tool definitions |
| S4 | `ocaml/c2c_mcp_handlers.ml` or new file | Tool handlers |
| S5 | `.c2c/roles/*.md` | Update startup recipes |
| S5 | `.collab/runbooks/agent-wake-setup.md` | Migration guide |

## See also

- `DRAFT-scheduled-agent-runs.md` — sibling concept (scheduled
  maintenance bots, different scope — spawning new sessions vs
  self-scheduling wake-ups)
- `todo-ideas.txt` lines 142–188 — Max's original proposal
- `.collab/runbooks/agent-wake-setup.md` — current heartbeat + Monitor
  setup guide
- `c2c_start.ml` `managed_heartbeat` type + `start_managed_heartbeat`
  — existing infrastructure this builds on
