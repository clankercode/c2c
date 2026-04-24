# Destructive `git checkout HEAD -- <file>` in shared working tree

**Reporter**: coordinator1 (Cairn-Vigil)
**Date**: 2026-04-24T02:10 UTC (12:10 AEST)
**Severity**: high — silently destroys peer uncommitted work; not reflog-recoverable

## Symptom

test-agent (OpenCode session, alias `test-agent`), working on **#121**
(poll_inbox session_id enforcement), ran:

```
git checkout HEAD -- ocaml/c2c_mcp.ml && echo "reset done"
```

visible in tmux pane `0:1.6`. This file was concurrently being edited by
Max (had uncommitted modifications visible in `git status` at session start
~11:03 AEST). The checkout cleanly reset the file to `HEAD`, silently
discarding those unstaged changes.

## Detection

coordinator1 peeked the pane via `tmux capture-pane -p -t 0:1.6` during a
routine swarm liveness check (idle time filled with useful work per Max's
nudge). Noticed `git checkout HEAD -- ocaml/c2c_mcp.ml` in the visible
scrollback and immediately raised alarm in a DM to test-agent and alerted
Max in the primary channel.

Recovery surface is limited:
- `git reflog` does **not** track unstaged edits — only HEAD moves.
- `_build/default/ocaml/c2c_mcp.ml` was a regular file (not a symlink) at
  size 169643 bytes with mtime 12:01 — but dune may have regenerated/copied
  post-reset; not a guaranteed backup.
- Editor buffers (if Max had the file open) are the only remaining hope.

## Root cause

test-agent is a new peer joining the swarm fresh from a pristine role
scaffold. The existing `CLAUDE.md` rule *"Do not delete or reset shared
files without checking"* and the `feedback_conflict_resolution_protocol`
memory entry were not surfaced strongly enough at the moment of running
a destructive git op.

This is the **second** destructive-git incident in the last 24h:
1. 2026-04-23 (storm-ember): `mcp__c2c__sweep` dropped managed-session
   registrations mid-run.
2. Earlier today: git-stash pre-commit rule was mis-added to CLAUDE.md
   (reverted d538e53) and the PATH-shim fork-bomb required a surgical
   revert with `git apply -R`.

Pattern: destructive git ops keep finding their way into the swarm
despite the rule being written down.

## Fix status

- Immediate: test-agent held, acknowledged protocol violation publicly
  in swarm-lounge + DM, no further changes committed.
- Recovery: pending Max's assessment of what was lost.
- Systemic fixes proposed (open for design):
  1. **Pre-op guard on destructive git subcommands**: wrap
     `git checkout HEAD -- …`, `git reset --hard`, `git stash`, `git
     clean -f`, `git restore` in the `c2c git` proxy shim (task #122
     redesign). Refuse or prompt if the target path has unstaged peer
     edits touched by another registered alias in the last N minutes.
  2. **Auto-backup on modify**: a filesystem watcher on hot-contention
     files (`c2c_mcp.ml`, `c2c_start.ml`) that snapshots uncommitted
     changes into `.c2c/backups/<file>.<ts>.bak` on every save. Cheap
     insurance, reflog-independent.
  3. **Role-onboarding surface**: add the conflict-resolution protocol
     as a mandatory read-aloud in the role scaffold for any agent
     whose role class touches shared code. Current `.c2c/roles/` does
     not auto-inject the rule.
  4. **Shared-file contention signal in `c2c list`**: show which peer
     has unstaged edits in which shared files; agents run `c2c list`
     before editing.

## Severity rationale

High — silently destroys work, no reflog recovery, repeated pattern
despite written rule. This is protocol-on-paper failing to become
protocol-in-practice. The swarm's productivity depends on trusting
that peers will not nuke each other's work; that trust is being eroded.
