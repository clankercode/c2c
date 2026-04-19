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

**First attempt (commit `7d06b40`)** — bumped `min_hook_runtime_ms` from
10.0 to 50.0 in `ocaml/cli/c2c.ml`, extracted `sleep_to_min_runtime`,
applied it to every exit path. This turned out to be a red herring for
the main cause.

**Real fix (commit `c34d168`)** — in the canonical bash wrapper
(`claude_hook_script` in `c2c.ml` and the installed
`~/.claude/hooks/c2c-inbox-check.sh`), replace:

```bash
exec c2c hook
```

with:

```bash
c2c hook
exit 0
```

`exec` replaces the bash process image with the c2c binary at the same
PID. Claude Code's Node.js hook runner tracks the initially-spawned
bash PID and its libuv pidfd/SIGCHLD state is tied to that specific
process image. When bash morphs into the c2c OCaml binary mid-flight,
the runner's waitpid() bookkeeping surfaces ECHILD on exit — every
single time. Running c2c as a bash child and exiting bash normally
keeps the tracked process stable.

# Verification

After the exec fix, triggered Bash/ls/arithmetic tool calls in a fresh
scribe session — **no more `PostToolUse:Bash` or `PostToolUse:Tool`
ECHILD errors** for non-MCP tools.

# Remaining upstream issues (not ours)

Two ECHILD classes still surface and are **not** caused by c2c:

1. `UserPromptSubmit` / `Stop` hook ECHILD — comes from the
   `idle-info` plugin's Node.js hooks
   (`~/.claude/plugins/marketplaces/idle-info/hooks/hooks.json`).
   Verified by stubbing c2c hook to `sleep 0.1; exit 0` — errors
   persisted unchanged.
2. `PostToolUse:mcp__*` ECHILD — even with our hook stubbed to a
   500ms plain sleep, `PostToolUse:mcp__c2c__list` still reports
   ECHILD. So MCP tool PostToolUse hook invocations have an
   additional Claude Code 2.1.114 race that sleep duration does not
   mitigate. Non-MCP tools (Bash, Edit, Grep, etc.) are clean.

These are Claude Code bugs, not c2c bugs. Worth filing upstream if
they become annoying; for now they're cosmetic (hooks still run, no
messages lost).

# Attribution test procedure

To confirm whether a given ECHILD error is ours:

```bash
# Disable our hook
cat > ~/.claude/hooks/c2c-inbox-check.sh <<'EOF'
#!/bin/bash
sleep 0.1
exit 0
EOF

# Trigger tool calls in a live Claude Code session. If ECHILD still
# shows for the same hook type (UserPromptSubmit, Stop,
# PostToolUse:mcp__*), it's upstream. Restore the hook when done.
```

# Related

- Prior attempt at 10ms floor: commit history on `hook_cmd` in
  `ocaml/cli/c2c.ml` (the original Lwt-based sleep).
- Claude Code version: 2.1.114.
- Node.js / libuv race is well-known — see
  https://github.com/nodejs/node/issues/37037 and similar. The
  mitigation pattern (delay in child) is the standard workaround.
