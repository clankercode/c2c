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

# Full mitigation (2026-04-20)

Both upstream classes are now mitigated end-to-end so the transcript is
clean in production:

1. **`UserPromptSubmit` / `Stop` / `PreCompact` ECHILD from `idle-info`
   plugin** — plugin's `hooks.json` now wraps each node invocation
   through `bash -c 'node <script> <&0; rc=$?; sleep 0.05; exit $rc'`.
   The 50ms sleep floor gives Claude Code's libuv `waitpid()` room to
   register the child before the kernel reaps it, same pattern as our
   own hook.
   - File: `~/.claude/plugins/marketplaces/idle-info/hooks/hooks.json`
   - Caveat: plugin updates will overwrite this. Re-apply by patching
     the file again.

2. **`PostToolUse:mcp__*` ECHILD** — Claude Code 2.1.114 has a distinct
   race on `PostToolUse:mcp__*` that fires regardless of hook content
   (verified with a 500ms stub). Fixed by narrowing the hook matcher
   from `.*` to `^(?!mcp__).*`, so the hook no longer runs for MCP
   tools. This is safe because:
   - `mcp__c2c__*` responses already drain the broker inbox
     synchronously server-side.
   - Other MCP tools (Gmail, Calendar, Drive) don't produce c2c
     traffic, so missing the PostToolUse trigger for them loses
     nothing.
   - Applied in both writers: OCaml `configure_claude_hook`
     (`ocaml/cli/c2c.ml`) and Python `c2c_configure_claude_code.py`
     (`HOOK_MATCHER = "^(?!mcp__).*"`).
   - Upgrade path (commit `dff5192`): `c2c install claude --force` now
     detects a stale `.*` matcher on an already-registered hook entry
     and rewrites it to `^(?!mcp__).*` in place. Prior behaviour was
     "hook already registered — no changes made", which silently left
     existing installs exposed to the race.

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
