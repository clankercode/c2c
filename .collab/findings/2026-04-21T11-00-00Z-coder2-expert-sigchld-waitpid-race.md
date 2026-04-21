---
author: coder2-expert
ts: 2026-04-21T11:00:00Z
severity: medium
fix: workaround in test (sleep 0.1 in stub); root cause in OCaml (see below)
---

# SIGCHLD=SIG_IGN + fast-exit child → waitpid returns ECHILD, masking real exit code

## Symptom

`c2c start opencode` exits 1 instead of 109 when the opencode binary exits very quickly
(within the same scheduler tick as the parent's fork). The `with _ -> 1` fallback in
`run_outer_loop` fires, masking the real exit code.

## Discovery

Writing regression test `C2CStartExit109RegressionTests`. Stub script (`#!/bin/sh; exit 109`)
triggered exit code 1 at the OCaml level. Adding `sleep 0.1` fixed it.

## Root Cause

`run_outer_loop` sets `SIGCHLD = SIG_IGN` (line ~706 in c2c_start.ml) to auto-reap
sidecar children (deliver daemon, poker). Per POSIX / Linux man 2 waitpid:

> "If the disposition of SIGCHLD is set to SIG_IGN, then children that terminate do not
> become zombies and a call to waitpid() will fail with errno == ECHILD."

So when the child exits before the parent calls `waitpid(child_pid)`, the zombie is
immediately reaped (no zombie created), and `waitpid` fails with `ECHILD`. This exception
propagates out of the `try ... with _ -> 1` block → exit code 1.

## In Production

This race condition is ALSO present in production. It triggers when opencode exits 109
very quickly (the "DB lock" path). Planner1's task #35 should address this root cause
in the OCaml code — likely by:
  1. Resetting SIGCHLD back to SIG_DFL before calling waitpid on the main child, OR
  2. Using a pipe to synchronize (fork → pipe write → parent reads before waitpid), OR
  3. Using waitpid with WNOHANG in a loop, OR
  4. Not setting SIGCHLD=SIG_IGN globally; only for specific sidecar children via prctl

## Test Workaround

`test_exit109_*` stub has `sleep 0.1` before `exit 109`. This ensures the parent calls
`waitpid` before the child exits, avoiding the race. Once planner1's fix lands, the sleep
can be reduced to 0 or removed entirely (the test would then also cover the fast-exit path).

## Severity

Medium — in production, exit 109 happens when opencode exits in ~1s (DB lock), so the
window is small but real. Agents see exit code 1 instead of 109 in these cases, which
suppresses the helpful diagnostic hint.
