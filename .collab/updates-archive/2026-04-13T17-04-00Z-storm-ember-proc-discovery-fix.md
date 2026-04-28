# storm-ember: /proc-based session discovery fix + opencode delivery bootstrap

Author: storm-ember
Time: 2026-04-13T17:04:00Z

## Summary

Fixed the root cause of persistent `missing session_id` MCP errors in Claude
Code sessions, and bootstrapped auto-delivery of broker messages to the live
opencode TUI.

## 1. Real root cause of MCP session discovery failures

Previous finding (64c978b / `2026-04-13T16-35-00Z-storm-ember-mcp-session-discovery-race.md`)
diagnosed the problem as a race between Claude Code starting and its session
file being written. **This was wrong.** After restarting and checking:

- `/proc/<my-claude-pid>/environ` had NO `C2C_MCP_SESSION_ID`
- `~/.claude-*/sessions/` does NOT EXIST on current Claude Code builds
- `claude_list_sessions.iter_session_files()` always returned `[]`
- `default_session_id()` always timed out regardless of timeout length

**Real fix** (commit `6704691`): Added `iter_live_claude_processes()` to
`claude_list_sessions.py` which:
1. Scans `/proc` for processes whose `comm == "claude"`
2. Parses `--resume <uuid>` from each process's `cmdline` (primary path)
3. Falls back to newest `.jsonl` under `~/.claude-*/projects/<cwd-slug>/`
   for fresh sessions without `--resume`
4. Keeps the legacy `sessions/*.json` path as a second pass for old builds

**Verification**: After restart, `mcp__c2c__poll_inbox` and `mcp__c2c__whoami`
both worked without explicit `session_id` argument. Finding updated in the
addendum at `.collab/findings/2026-04-13T16-35-00Z-storm-ember-mcp-session-discovery-race.md`.

**161 Python tests pass.**

## 2. opencode-local delivery bootstrap

The TUI opencode (pid 1337045, ses_283b6f0daffe4Z0L0avo1Jo6ox, pts/22) has
been running since 13:20 but was never c2c-registered with its actual PID.
Registry had stale pid 1976330 (dead `opencode run` instance).

Actions taken:
- Updated broker registry to point opencode-local → pid=1337045, pid_start_time=25746123
- Sent game DM to opencode-local (queued successfully)
- Started `c2c_deliver_inbox.py` daemon (pid 2000127) targeting:
  - `--terminal-pid 3725367` (PTY master for pts/22)
  - `--pts 22`
  - `--session-id opencode-local`
  - `--client opencode --file-fallback --loop --interval 2`
  - pidfile: `run-opencode-inst.d/c2c-opencode-local.deliver.pid`
- Daemon drained the inbox (inbox went to `[]`)

Whether pty_inject successfully wrote into the TUI's PTY depends on whether
the process has `cap_sys_ptrace`. The daemon log was empty (no error reported).

## 3. Opencode prompt update (commit 7ab0f8b)

Updated `run-opencode-inst.d/c2c-opencode-local.json` prompt to instruct
opencode-local to poll inbox and respond to DMs on startup.

## Next steps

- Max relayed: opencode doesn't auto-receive messages; we need to implement
  this for the north star. The deliver daemon is the first attempt — it handles
  the broker→PTY delivery direction. We still need to verify injection works.
- If PTY injection fails (cap_sys_ptrace issue), next approach: have opencode
  TUI watch the inbox file directly (via filesystem events or polling).
- The game password hasn't been obtained yet — waiting for opencode's response.
