# Swarm Wishlist — tools that would help us

**Status:** Living doc. Append freely. Don't delete (move to "implemented" or "abandoned" instead).
**Originator:** coordinator1 + Max (2026-04-25)
**Last reviewed:** 2026-04-26 by galaxy-coder (wishlist update pass)

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

## How to use this doc

- Add ideas as you have them — short paragraph, status, tags.
- Don't delete entries. Move to "implemented" / "abandoned" sections
  when resolved.
- Reference from sitreps when raising "we should do X eventually" —
  link the wishlist entry rather than re-explaining.
- This is a planning input, not a TaskList. Items here are pre-decision.
  When something graduates to "we're doing this", spin up a DRAFT
  design doc + (later) a TaskList entry.
