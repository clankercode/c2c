# Swarm Wishlist — tools that would help us

**Status:** Living doc. Append freely. Don't delete (move to "implemented" or "abandoned" instead).
**Originator:** coordinator1 + Max (2026-04-25)

This is a tracking doc for things that would make the swarm work better
but that we haven't built or integrated yet. It feeds future
build-vs-integrate decisions and ensures we don't lose ideas to
sitrep churn.

Format: brief title, one-paragraph context, current status. Group by
theme.

---

## Maintenance / quality

### Scheduled agent runs (security audits, refactor hunts, doc drift checks)
Maintenance work nobody owns: security/secret scans, dep audits,
duplication hunts, doc-vs-reality drift, complexity outliers. Want
cron-scheduled bots that do their pass and file findings/backlog
items. **Status**: draft at `.collab/design/DRAFT-scheduled-agent-runs.md`.
Blocker: in-c2c vs external vs integrate-existing decision pending.

### Code-duplication / refactor-hunt bot
Specific instance of scheduled agents — a bot that flags
copy-pasted-with-tweaks code, missing abstractions, inconsistent naming
across the codebase. **Status**: subset of scheduled-agent-runs draft;
would want it weekly or on-demand.

### Untested-public-surface scanner
For every Tier-1/Tier-2 c2c subcommand, verify there's at least one
test that exercises the cmdliner entry point. **Status**: not started;
would belong in `c2c doctor` extensions.

### `c2c doctor` "did the docs lie?" check
Periodically diff CLAUDE.md claims (file paths, command surfaces,
script names) against actual repo state. Flag drift.
**Status**: not started.

---

## Coordinator ergonomics

### `c2c coord-cherry-pick` helper
Auto-stash dirty state, cherry-pick, restore, build+install — the
workflow I do by hand on every peer-PASS. Recurring friction this
session. **Status**: not started; would slot into `c2c worktree` or
new `c2c coord` subgroup.

### Branch-from-origin-master vs local-master mismatch detector
When a peer branches from `origin/master` but coord hasn't pushed in
N commits, their cherry-pick target conflicts. Warn at branch-creation
time or at peer-PASS-DM time. **Status**: not started; ~30 LoC in `c2c
worktree start`?

---

## Observability

### `c2c stats` v2 — token cost data per session
Slice 4 of `DRAFT-agent-stats-command.md`. Per-client tokens-in/out
for cost analysis + business-target tracking. **Status**: design-stage.

### Sitrep auto-append from `c2c stats`
Slice 5 of stats. Hourly sitreps gain a swarm-perf section auto-appended.
**Status**: design-stage; depends on stats S2-S4.

### Longitudinal swarm-perf dashboard
Beyond per-sitrep stats: a viewer that shows trends across days/weeks,
correlates CLAUDE.md tweaks → active% changes, etc. **Status**: idea
only. May not need to be in c2c — could be external dashboard reading
the sitrep timeseries.

---

## Integration / interop

### Generic pty/tmux clients
Run any CLI (Gemini, Cursor, etc.) via pty injection or tmux send-keys.
**Status**: shipping in 4 slices, design at
`.collab/design/DRAFT-generic-pty-tmux-clients.md`. Slices 2 + S1
in flight.

### Codex interactive-TUI server-request fds
Permission forwarding for normal interactive Codex blocked on upstream
flag support. **Status**: feature request drafted at
`./x-codex-interactive-tui-server-request-fds.md.tmp` for Max to
forward upstream.

---

## Process

### Peer-PASS verification (anti-cheat)
The `c2c peer-pass sign` flow exists but we don't verify the signing
matches the actual review-and-fix invocation. Could add a
broker-side check that the sig + claim are consistent.
**Status**: idea only.

### Auto-detect "self-review-via-skill ≠ peer-PASS" violations
The convention has been re-broken three times in one session. Could
the broker detect when a DM says "peer-PASS by <self>" and
gently correct? **Status**: idea only.

---

## How to use this doc

- Add ideas as you have them — short paragraph, status, tags.
- Don't delete entries. Move to "implemented" / "abandoned" sections
  when resolved.
- Reference from sitreps when raising "we should do X eventually" —
  link the wishlist entry rather than re-explaining.
- This is a planning input, not a TaskList. Items here are pre-decision.
  When something graduates to "we're doing this", spin up a DRAFT
  design doc + (later) a TaskList entry.
