# Peer-PASS — d87b3557 (stanza-coder)

**Reviewer**: test-agent
**Date**: 2026-05-03
**Commits**: 68984a43 (S6c) + d87b3557 (S6d)
**Branch**: s6c-start-dedup
**Criteria checked**:
- `build-clean-IN-worktree-rc=0` (dune build @root — no output, exit 0)
- `test-suite=340/340` (dune exec test_c2c_mcp.exe)
- `diff-reviewed` (both commits)

---

## Commit 1: 68984a43 — feat(S6c): dedup c2c start timer with MCP server schedule timer

### What it does

When `c2c start` launches a managed session:
1. Sets `C2C_MCP_SCHEDULE_TIMER=1` in the MCP child's env (via `build_env`)
2. Also sets it in the parent's own env
3. Parent skips its own schedule watcher thread (via `mcp_schedule_timer_active()` guard) to avoid duplicate heartbeats

### Code quality

- `mcp_schedule_timer_active()`: correct boolean parsing of env var (same pattern as `schedule_timer_enabled` in S6b)
- `putenv` only called when env var not already set — respects operator overrides
- Guard check `if not (mcp_schedule_timer_active ())` correctly skips the watcher thread only when MCP timer is active
- Fallback preserved: if operator explicitly sets `C2C_MCP_SCHEDULE_TIMER=0`, watcher thread still runs
- Comments are accurate and explain the dedup rationale

---

## Commit 2: d87b3557 — docs(S6d): add MCP-server-side scheduling to agent-wake-setup runbook

### What it does

Documents Option 0b — MCP-server-side scheduling for raw `claude` sessions (non-managed, with c2c MCP configured).

### Coverage

- TL;DR table: new row for "Raw claude with c2c MCP (non-managed)"
- Option 0b section: what it is, when to use, how to activate (`C2C_MCP_SCHEDULE_TIMER=1`), internal mechanics (5s stat poll, self-DM via enqueue_heartbeat), dedup with c2c start (S6c), tradeoffs
- Option 0 tradeoffs updated to reference Option 0b as fallback

### Code quality

- Accurate: describes the 5s poll interval vs 10s wrapper, Option A delivery (self-DM), idle gating
- Correct: notes that managed sessions get automatic dedup via S6c

## Verdict

**PASS** — S6c: correct dedup logic, respects operator overrides, clean env var propagation. S6d: accurate runbook documentation matching S6b/S6c behavior.
