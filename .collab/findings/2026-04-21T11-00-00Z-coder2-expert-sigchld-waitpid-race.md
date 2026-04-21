---
author: coder2-expert
ts: 2026-04-21T11:00:00Z
severity: medium
fix: FIXED in 6f22f5e (planner1, 2026-04-21T11:10)
---

# SIGCHLD=SIG_IGN + fast-exit child → waitpid returns ECHILD, masking real exit code

**STATUS: FIXED in 6f22f5e** — planner1 removed `SIGCHLD=SIG_IGN` from
`run_outer_loop` and also fixed absolute-path `--bin` lookup. Regression tests
(94cda9c, `C2CStartExit109RegressionTests`) confirm the fix.

## Symptom

`c2c start opencode` exits 1 instead of 109 when opencode exits very quickly.
The `with _ -> 1` fallback in `run_outer_loop` fires, masking the real exit code.

## Root Cause

`run_outer_loop` set `SIGCHLD = SIG_IGN` to auto-reap sidecar children. Per POSIX:

> "If the disposition of SIGCHLD is set to SIG_IGN, children that terminate do not
> become zombies and waitpid() fails with ECHILD."

So: fast-exiting child → zombie immediately reaped → `waitpid` → ECHILD → `with _ -> 1`.

## Fix (6f22f5e)

Removed `SIGCHLD=SIG_IGN` entirely. Sidecar zombie cleanup is deferred to outer
process exit (short-lived; acceptable). Also fixed `find_binary` to accept absolute
paths directly (leading `/`).

## Discovery Context

Documented during regression test writing for bd41f9e (exit-109 diagnostic hint).
Tests were written at 94cda9c; fix landed at 6f22f5e (1 min later, parallel work).
