# Wishlist — tools and cleanups worth considering

**Status:** Living doc. Append freely. Don't delete (move to "implemented" or "abandoned" instead).
**Originator:** historical swarm-era + Max (2026-04-25)
**Last reviewed:** 2026-07-14 (post swarm-era reframe)

This is a tracking doc for product/process ideas that we have not built
or finished yet. Older entries may still say "swarm"; treat those as
historical context unless marked open.

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
test that exercises the cmdliner entry point. **Status**: implemented
at `scripts/c2c-command-test-audit.py`, wired into `c2c doctor`;
29/43 Tier 1/2 commands have test references; 14 gaps remain.

### `c2c doctor` "did the docs lie?" check
Periodically diff CLAUDE.md claims (file paths, command surfaces,
script names) against actual repo state. Flag drift.
**Status**: implemented (SHA 7bb6abd, `scripts/c2c-docs-drift.py`) in
slice/doctor-docs-drift (lyra); pending merge to origin/master.

---

## Coordinator ergonomics

### `c2c coord-cherry-pick` helper
Auto-stash dirty state, cherry-pick, restore, build+install — the
workflow I do by hand on every peer-PASS. Recurring friction this
session. **Status**: shipped — OCaml port on origin/master (SHA 96b16ad);
Python prototype (SHA e1cec4e); `c2c coord-cherry-pick` command live.

### Branch-from-origin-master vs local-master mismatch detector
When a peer branches from `origin/master` but coord hasn't pushed in
N commits, their cherry-pick target conflicts. Warn at branch-creation
time or at peer-PASS-DM time. **Status**: shipped — `start_worktree`
warns when origin/master is behind local master by N commits (SHA b80e8e9);
uses `local_master_ahead_of_origin` + `stale_origin_warning`; `check-bases`
subcommand available for on-demand worktree hygiene.

---

## Observability

### `c2c stats` v2 — token cost data per session
Slice 4 of `DRAFT-agent-stats-command.md`. Per-client tokens-in/out
for cost analysis + business-target tracking. **Status**: shipped —
`c2c stats history` (--compact/--csv/--markdown/--bucket flags, SHAs
0012aff/79eb696/9ae19d1/22790c0/c614860) and token cost per session
(stats-s4, SHA ec479e6) both on origin/master.

### Sitrep auto-append from `c2c stats`
Slice 5 of stats. Hourly sitreps gain a swarm-perf section auto-appended.
**Status**: design-stage; depends on stats S2-S4 (S4 now shipped; S5
still design-gated).

### Longitudinal swarm-perf dashboard
Beyond per-sitrep stats: a viewer that shows trends across days/weeks,
correlates CLAUDE.md tweaks → active% changes, etc. **Status**: idea
only. May not need to be in c2c — could be external dashboard reading
the sitrep timeseries.

---

## Integration / interop

### Generic pty/tmux clients
Run any CLI (Gemini, Cursor, etc.) via pty injection or tmux send-keys.
**Status**: shipped — `c2c start pty` and `c2c start tmux` subcommands
live on origin/master (SHAs 54735d0/fb1454a/827dae5/d992412); design at
`.collab/design/DRAFT-generic-pty-tmux-clients.md`.

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
**Status**: shipped — broker auto-verifies peer-pass claims in DM receipts
(SHA a4eb88b); anti-cheat checks at sign + verify (SHA 9983943);
`--warn-only` on list, `--strict` on verify (SHA dacc2b7); self-pass
detector fix (SHA a5c05ad).

### Auto-detect "self-review-via-skill ≠ peer-PASS" violations
The convention has been re-broken three times in one session. Could
the broker detect when a DM says "peer-PASS by <self>" and
gently correct? **Status**: shipped — broker detects self-review-via-skill
violations in DM bodies (SHA 38f5bed) and refuses to record them as
valid peer-PASS.

---

## Post swarm-era (2026-07-14)

### Rename default room id `swarm-lounge`
Install / managed start still default to room id `swarm-lounge`
(`builtin_swarm_social_room`, `C2C_MCP_AUTO_JOIN_ROOMS`). Prefer a neutral
name (`lounge` / `general` / `repo-lounge`) with a compatibility path for
existing memberships. **Status**: open bug —
`.collab/findings/2026-07-14T00-00-00Z-rename-default-room-swarm-lounge.md`.

### Retire swarm-era config, kickoff strings, related legacy
Consider (do not hard-delete): `[swarm]` TOML table, managed kickoff/restart
intro strings that assume multi-agent onboarding, coordinator-named helpers.
Keep rooms/schedules/multi-peer messaging — those are product features.
**Status**: idea only —
`.collab/findings/2026-07-14T00-00-01Z-idea-retire-swarm-era-config-and-kickoff.md`.

---

## How to use this doc

- Add ideas as you have them — short paragraph, status, tags.
- Don't delete entries. Move to "implemented" / "abandoned" sections
  when resolved.
- This is a planning input, not a task queue. Items here are pre-decision.
  When something graduates to "we're doing this", spin up a design doc.
