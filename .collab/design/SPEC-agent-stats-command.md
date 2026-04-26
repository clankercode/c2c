# SPEC: `c2c stats` — detailed per-agent activity & resource report

**Status:** implemented
**Shipped:** SHAs 0012aff, 79eb696, 9ae19d1, 22790c0, c614860 (stats history), ec479e6 (token cost)
**Originator:** Max (2026-04-25)
**Coordinator:** coordinator1

## Motivation

We have rich state per agent (statefiles, compacting flags, registrations, room
membership, message archives) but no aggregated way to look at swarm
*performance over time*. We want:

- A way to **analyze how the team is performing** — who's active, who's idle,
  who's burning tokens fast, who's compacting often.
- A way to **evaluate business targets**: e.g. coders should run ~75-90% active,
  coordinators ~50-70%.
- An artifact that **slots into our sitreps** — so each hourly sitrep can append
  the current snapshot, and we get a longitudinal record without extra work.

## Proposed CLI surface

```bash
c2c stats                       # default: all agents, current snapshot
c2c stats --since 1h            # window: last hour
c2c stats --since '2026-04-25T20:00'   # window: from absolute time
c2c stats --alias stanza-coder  # one agent, detailed
c2c stats --json                # machine-readable
c2c stats --append-sitrep       # write to .sitreps/YYYY/MM/DD/HH.md
c2c stats --markdown            # human-readable markdown table (default)
```

CLI-only, no MCP surface — agents don't need to call this on themselves;
coordinator + Max are the consumers.

## Data sources (per agent)

| Field | Source |
|---|---|
| alias, session_id, registered_since | registry YAML |
| live (kill -0 ok) | registry pid + procfs |
| compacting state | registry / statefile compacting flag |
| compaction count (cumulative) | NEW: track each compacting transition in statefile |
| tokens consumed (input/output) | NEW: parse from CLI logs or claude-code state file (TBD per client) |
| messages sent / received | message archive (`<broker_root>/archive/<session_id>.jsonl`) |
| % time active | NEW: requires last_activity_ts tracking (the deferred idle-nudge slice ground laid this) |
| % time idle (>5min between activity) | derived from last_activity_ts series |
| % time compacting | derived from compacting transition log |
| current room memberships | broker rooms state |
| heartbeat config (effective) | layered config resolved view |
| current task (if known) | TaskList API per agent? OR self-reported in DM |

## Output formats

### Markdown (default)

```
## Swarm stats — 2026-04-25 22:00 UTC+10 (window: last 1h)

| alias | active% | idle% | compact% | msgs in/out | toks in/out | compactions | role |
|---|---|---|---|---|---|---|---|
| coordinator1 | 62 | 36 | 2 | 47 / 89 | 312k / 28k | 1 | coordinator |
| stanza-coder | 84 | 14 | 2 | 12 / 18 | 198k / 22k | 0 | coder |
| lyra-quill | 71 | 27 | 2 | 22 / 24 | 245k / 19k | 0 | coder |
| galaxy-coder | 78 | 22 | 0 | 8 / 11 | 167k / 14k | 0 | coder |
| jungle-coder | 81 | 19 | 0 | 14 / 17 | 188k / 16k | 0 | coder |
| test-agent | 45 | 55 | 0 | 6 / 9 | 92k / 7k | 0 | coder |

**Targets**: coders 75-90% active; coordinators 50-70%.
- ✅ stanza, galaxy, jungle, lyra in coder band
- ⚠️ test-agent below band (45%) — quota-shed or genuinely idle?
- ✅ coordinator1 in coordinator band
```

### JSON

Same data shape, machine-readable. For dashboards / longitudinal analysis.

## Sitrep integration

Every hour the coord (or a cron) runs:

```bash
c2c stats --since 1h --append-sitrep
```

Which appends a "## Swarm stats" section to `.sitreps/YYYY/MM/DD/HH.md`. After
N hours we have a real time-series of swarm performance — directly attached to
the human-readable sitreps so context is preserved.

## Slicing suggestion

- **Slice 1**: `c2c stats` skeleton — registry + procfs scan, prints alias/live/
  msgs in/out (from message archive). No tracking-required fields. Markdown +
  JSON output. Lands the command.
- **Slice 2**: compaction count tracking. Statefile schema gets a `compactions:
  int` counter; broker (or hook) increments on each compacting→idle transition.
  `c2c stats` reads it. Backfill: 0 for existing agents.
- **Slice 3**: `last_activity_ts` tracking. Already designed (deferred-marker
  doc in `.collab/design/DRAFT-idle-nudge.md`). Once shipped, derives active% /
  idle% / compact%.
- **Slice 4**: token counts. Per-client investigation — Claude Code stores
  token counts in session state, Codex similar, OpenCode TBD. Best-effort:
  extract what we can per client, mark fields N/A where unavailable.
- **Slice 5**: `--append-sitrep` integration + cron / hourly heartbeat hook.

## Open questions

1. **Granularity of `last_activity_ts`**: per-second is overkill. Per-minute
   buckets are probably enough.
2. **Token cost data**: do we have it locally per client, or do we need to
   parse `cc-quota` output? `cc-quota` aggregates by entire-machine; we want
   per-session.
3. **Should compactions be aggregated daily/hourly?**: probably keep cumulative
   counter + emit derivative ("compactions/hr") in the report.
4. **Targets per role**: hard-coded in the binary, or in config.toml so Max
   can tune? Probably config.toml under `[stats.targets]`.
5. **Privacy / consent**: agents are tracked anyway via the broker; this just
   surfaces existing data. No new consent surface needed.
6. **Should the coordinator's own stats be excluded from team aggregates?**
   Probably keep coord in-line but with the coordinator target band.

## North-star fit

- Direct: more visibility means better swarm coordination, faster detection of
  stuck agents, evidence-based "which patterns are working" analysis.
- Indirect: data feeds into future improvements (which CLAUDE.md tweaks moved
  the active% needle? did the worktree-per-slice directive reduce coord
  cherry-pick friction by N%?).

## Slicing assignment

To be assigned. Slice 1 is small and well-scoped — good warmup or
post-codex-perms slice for any peer.

## See also

- `.collab/design/DRAFT-idle-nudge.md` — last_activity_ts tracking groundwork
- `c2c health` — existing diagnostic; this complements rather than replaces
- `c2c-quota` (Bash) — coarse-grained 5h/7d Claude usage
