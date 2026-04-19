---
title: Claude Code PostToolUse hook fails with ECHILD when c2c hook exits fast
date: 2026-04-19T09:08:00Z
author: opus-host
severity: medium — noisy transcript, but hooks still ran; no messages lost
---

# Symptom

In a scribe tmux session driving Claude Code 2.1.114, every other tool
call surfaced a red hook-error line in the transcript:

```
PostToolUse:ToolSearch hook error
  Failed with non-blocking status code:
  Error occurred while executing hook command: ECHILD: unknown error, waitpid

PostToolUse:mcp__c2c__poll_inbox hook error
  Failed with non-blocking status code:
  Error occurred while executing hook command: ECHILD: unknown error, waitpid
```

Messages still arrived; the hook itself did its work. The error came from
Claude Code's Node.js hook runner trying to `waitpid()` the hook child
after the child had already been reaped by the kernel.

# Root cause

Classic fast-exit race:

1. Claude Code spawns the hook (bash) via Node.js `child_process`.
2. The hook does ~1ms of work and exits.
3. The kernel reaps the zombie before Node's libuv loop gets around to
   calling `waitpid()` on that PID.
4. Node's `waitpid()` returns `ECHILD` ("no such child") and the hook
   runner surfaces the error.

We had already hit this once before and added a 10ms `min_hook_runtime_ms`
floor inside `c2c hook`. Two gaps remained:

- **Fast-exit paths skipped the sleep.** When `C2C_MCP_SESSION_ID` or
  `C2C_MCP_BROKER_ROOT` was empty, `c2c hook` did `exit 0` before the
  floor fired. Exception path same deal.
- **10ms wasn't enough.** On a busy laptop, the kernel still won the
  race frequently enough to produce visible errors.

# Fix

In `ocaml/cli/c2c.ml`:

- Bumped `min_hook_runtime_ms` from 10.0 to 50.0.
- Extracted `sleep_to_min_runtime start_time` helper.
- Called it from every exit path: early-env-empty, normal drain, and
  exception path.
- Updated the canonical `claude_hook_script` bash wrapper so that when
  `c2c` is missing from PATH we still `sleep 0.05` before `exit 0`.
- Dropped the Lwt_main/Lwt_unix.sleep dance — `Unix.sleepf` is simpler
  and adequate at 50ms granularity.

Installed the new wrapper to `~/.claude/hooks/c2c-inbox-check.sh`
directly so the already-running Claude Code session picks it up on
next hook fire (hook scripts are re-read from disk on each invocation).

# Verification

- `time c2c hook` → 63ms total (floor active, no messages in inbox)
- `time bash ~/.claude/hooks/c2c-inbox-check.sh` → 58ms total

If 50ms turns out to be too tight under high load, bump to 100ms. The
ceiling is Claude Code's own timeout on PostToolUse hooks (currently
seconds, not milliseconds).

# Related

- Prior attempt at 10ms floor: commit history on `hook_cmd` in
  `ocaml/cli/c2c.ml` (the original Lwt-based sleep).
- Claude Code version: 2.1.114.
- Node.js / libuv race is well-known — see
  https://github.com/nodejs/node/issues/37037 and similar. The
  mitigation pattern (delay in child) is the standard workaround.
