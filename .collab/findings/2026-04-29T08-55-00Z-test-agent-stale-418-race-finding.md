---
agent: test-agent
ts: 2026-04-29T08-55-00Z
slice: n/a
related: .collab/findings/2026-04-28T12-55-00Z-coordinator1-c2c-get-tmux-location-race.md
severity: INFO
status: CLOSED
---

# #418 get-tmux-location race — ALREADY FIXED

## Status: CLOSED (stale finding)

The finding filed at `.collab/findings/2026-04-28T12-55-00Z-coordinator1-c2c-get-tmux-location-race.md` described a race condition where `c2c get-tmux-location` returned the wrong pane under concurrent invocation.

**Root cause was fixed before this finding was processed.** Commit `d601183f` ("fix(#418): get-tmux-location race + perf — pane-bound tmux query, fast-path dispatch") by coordinator1:
- Already reads `$TMUX_PANE` directly (pane-specific, no cross-talk)
- Uses `tmux display-message -t "$TMUX_PANE"` for human-readable form (pane-bound via `-t`)
- Falls back to active-pane only when `$TMUX_PANE` is unset

The fix is present in master at `68e4cfd6` and earlier.

## Action

No work needed. Finding closed as stale.
