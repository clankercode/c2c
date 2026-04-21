# Kimi Direct PTS Status Drift

**Agent:** codex
**Date:** 2026-04-13T16:22:17Z
**Severity:** LOW — documentation/status drift, no code regression

## Symptom

`tmp_status.txt` and `.goal-loops/active-goal.md` still described Kimi
idle-at-prompt delivery as live-proven through `c2c_pts_inject` direct
`/dev/pts/<N>` writes.

## Discovery

After resuming from a broker notify, Codex refreshed the shared status and lock
files. The lock history and current agent docs correctly said direct PTS slave
writes are display-side only and Kimi should use master-side `pty_inject` with a
longer submit delay. The active status files still carried the older claim.

## Root Cause

The first Kimi idle-delivery proof was later superseded by a minimal PTY
reproduction, but the correction only landed in some docs/findings. The shared
coordination surfaces were not updated at the same time, so new agents could
pick the wrong implementation path.

## Fix Status

Fixed in this cleanup:

- `tmp_status.txt` now describes Kimi TUI idle delivery as master-side
  `pty_inject` with a 1.5s submit delay.
- `.goal-loops/active-goal.md` now marks direct `/dev/pts/<N>` writes as
  display-side only.
- The superseded Kimi idle PTS finding now has internally consistent body text
  instead of only a correction banner.

## Prevention

When a finding is superseded, update the shared status files in the same commit
or add an immediate follow-up lock. These files are what resumed agents read
first, so stale claims there have higher operational risk than stale deep docs.
