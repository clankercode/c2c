# Claude Code Wake Delivery Gap

- **Time:** 2026-04-13T11:30:00Z
- **Reporter:** storm-beacon
- **Severity:** medium — affects idle Claude Code sessions in non-loop mode
- **Task source:** Max's TASKS_FROM_MAX.md "quality check: msg delivery to claude"

## Symptom

If a Claude Code session is idle (not actively running tools), the PostToolUse hook
cannot fire. Incoming DMs sit in the inbox unnoticed until the session runs a tool
(any tool) or explicitly calls `mcp__c2c__poll_inbox`.

## Root Cause

Claude Code's c2c delivery has two paths:
1. **PostToolUse hook** (`c2c-inbox-check.sh`): fires after every tool call — reactive,
   near-real-time WHEN TOOLS ARE RUNNING, but cannot wake a truly idle session.
2. **Manual poll**: agent calls `mcp__c2c__poll_inbox` — works always but requires
   the agent to already be running.

Neither path can externally wake a sleeping Claude Code session that's waiting
for user input or idle between turns.

## Existing Mitigations

- **Monitor + /loop setup** (recommended in CLAUDE.md): arms `inotifywait` on the
  broker dir, delivers `<task-notification>` events that wake the loop. This is the
  right solution for active sessions, but requires the agent to set it up at startup.
- **c2c_poker.py**: PTY-injects heartbeat envelopes to keep Claude alive. Does not
  specifically trigger inbox polling.
- **run-claude-inst managed mode**: each iteration starts fresh; prompt includes
  `poll_inbox`. But background managed instances have no PTY, so PTY injection
  can't wake them.

## Fix Implemented: c2c_claude_wake_daemon.py

Added `c2c_claude_wake_daemon.py` (and `c2c-claude-wake` wrapper). For interactive
Claude Code sessions with a known PTY:

```bash
# Watch inbox for session d16034fc, inject wake when DMs arrive
python3 c2c_claude_wake_daemon.py \
  --claude-session d16034fc \
  --session-id d16034fc-5526-414b-a88e-709d1a93e345 \
  --min-inject-gap 15

# Or with explicit PTY coords:
python3 c2c_claude_wake_daemon.py \
  --terminal-pid 12345 --pts 7 \
  --session-id d16034fc-5526-414b-a88e-709d1a93e345
```

The daemon watches the inbox with inotifywait, then PTY-injects:
> "c2c wake: you have pending broker-native DMs. Call mcp__c2c__poll_inbox right now."

Claude Code sees this as user input, responds, runs tools, and the PostToolUse hook
drains the inbox.

## Remaining Gaps

1. **Background managed sessions** (run-claude-inst-outer without PTY): no wake
   mechanism. Each iteration should include `poll_inbox` in the prompt.
2. **Setup burden**: the wake daemon must be started by an operator or the managed
   harness. Not yet auto-started by `c2c setup claude-code`.
3. **pty_inject dependency**: requires the `pty_inject` binary with `cap_sys_ptrace`.
   Not present in all environments.

## Recommended Follow-up

- Add auto-start of `c2c_claude_wake_daemon.py` to `run-claude-inst-outer` (like
  Codex's `run-codex-inst-rearm` starts `c2c_deliver_inbox.py --notify-only`).
- Consider adding a `c2c-claude-wake` invocation to the `c2c setup claude-code`
  output ("to auto-wake on DMs, run: ...").
