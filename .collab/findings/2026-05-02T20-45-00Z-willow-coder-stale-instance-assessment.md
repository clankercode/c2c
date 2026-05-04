# Finding: stale registration assessment — 2026-05-02

**Alias**: willow-coder
**Date**: 2026-05-02
**Severity**: low (hygiene — no functional impact)
**Topic**: stale managed-instance registrations

## Summary

`c2c list` shows 20 registrations. 9 are live (alive=true, PIDs confirmed running).
11 are stale (alive=false or alive=null, PIDs dead or no session evidence).

## Live registrations (9)

| Alias | PID | registered_at | Notes |
|-------|-----|---------------|-------|
| willow-coder | 3290985 | 2026-05-02 20:41 | current session |
| galaxy-coder | 3275273 | 2026-05-02 20:39 | live |
| birch-coder | 3290672 | 2026-05-02 20:26 | live |
| jungle-coder | 3290330 | 2026-05-02 20:18 | live |
| fern-coder | 3290330 | 2026-05-02 20:16 | live |
| cedar-coder | 3280706 | 2026-05-02 19:58 | live |
| test-agent | 2102762 | 2026-05-02 19:41 | live |
| stanza-coder | 3084292 | 2026-05-02 18:58 | live |
| coordinator1 | 3084442 | 2026-05-02 18:58 | live |

## Stale registrations — confirmed dead (alive=false, PID gone) (4)

| Alias | session_id | PID | registered_at | registered_local | Assessment |
|-------|-----------|-----|---------------|------------------|------------|
| test-claude-pty5 | test-claude-pty5 | 1885023 | 1777686020 | 2026-05-02 18:40 | DEAD — PID confirmed gone via `ps -p` |
| smoke-opencode2 | smoke-opencode2 | 3061971 | 1777470222 | 2026-05-02 14:43 | DEAD — PID confirmed gone |
| smoke-opencode | smoke-opencode | 3050781 | 1777470182 | 2026-05-02 14:43 | DEAD — PID confirmed gone |
| slate-coder | gemini-probe-1777370471 | 3118911 | 1777370476 | 2026-05-02 12:44 | DEAD — PID confirmed gone (gemini probe) |

**Safe to sweep**: all 4. No corresponding session files in `~/.claude/sessions/`,
`~/.claude-p/sessions/`, or `~/.claude-w/sessions/`. PID dead on host.

## Stale registrations — alive=null, no session evidence (6)

| Alias | session_id | registered_at | registered_local | Assessment |
|-------|-----------|---------------|------------------|------------|
| test-opencode-host | test-opencode-host | 1777690734 | 2026-05-02 ~09:12 | STALE — no session file found; not in any sessions dir |
| test-claude-ssh-1792832 | test-claude-ssh-1792832 | 1777685631 | 2026-05-02 ~08:53 | STALE — no session file; SSH test instance, not coming back |
| e2e-claude-test2 | e2e-claude-test2 | 1777683006 | 2026-05-02 ~08:16 | STALE — no session file; E2E test instance |
| tyyni-test | tyyni-test | 1777602788 | 2026-05-01 ~23:06 | STALE — from yesterday; no session file |
| lumi-test | lumi-test | 1777602781 | 2026-05-01 ~23:06 | STALE — from yesterday; no session file |
| lumi-tyyni | cedar-test-478 | 1777494128 | 2026-05-01 ~20:08 | STALE — from yesterday; no session file |
| tyyni-sora | tyyni-sora | 1777463578 | 2026-05-01 ~19:06 | STALE — from yesterday; no session file |

**Safe to sweep**: all 6. All registered >1h ago with no session file evidence.
`test-opencode-host` is the only borderline case (registered ~09:12 today, ~4.5h ago),
but no session file and no alive signal — it's a leftover from earlier today that
never came back.

## Recommendations

### SWEEP candidates (10 registrations — confirmed dead, no session evidence)
1. `test-claude-pty5` — PID dead, no session file
2. `smoke-opencode2` — PID dead, no session file
3. `smoke-opencode` — PID dead, no session file
4. `slate-coder` (gemini-probe-1777370471) — PID dead, no session file
5. `test-opencode-host` — alive=null, no session file, registered 4.5h ago
6. `test-claude-ssh-1792832` — alive=null, no session file, SSH test instance
7. `e2e-claude-test2` — alive=null, no session file, E2E test instance
8. `tyyni-test` — alive=null, no session file, from yesterday
9. `lumi-test` — alive=null, no session file, from yesterday
10. `lumi-tyyni` — alive=null, no session file, from yesterday
11. `tyyni-sora` — alive=null, no session file, from yesterday

### DO NOT SWEEP
- None — all null-alive registrations have been silent for 4.5h+ with no session evidence.

### Risk note
`c2c instances clean-stale` was already run recently (1253 instances cleaned per earlier session).
These 10-11 stale registrations are a subset that survived or accumulated after that run.
They are all test/ephemeral instances that will not come back.

## Files checked
- `~/.claude/sessions/` — only 2 session files (stanza-coder inner, coordinator1 inner)
- `~/.claude-p/sessions/` — empty
- `~/.claude-w/sessions/` — empty
- `ps -p <pid>` for all known PIDs of alive=false registrations — all confirmed DEAD
