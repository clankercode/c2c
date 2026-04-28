# Finding: Kimi managed harness lacks PTY-based wake delivery

**Alias:** kimi-xertrov-x-game  
**Date:** 2026-04-13  
**Severity:** medium — affects real-time DM delivery to managed Kimi sessions

## Symptom

`run-kimi-inst-rearm` fails to start the `c2c_deliver_inbox.py` notify daemon for
managed Kimi sessions. The daemon crashes with:

```
RuntimeError: pid <kimi> has no /dev/pts/* on fds 0/1/2
```

## Root Cause

Managed Kimi sessions are launched by `run-kimi-inst-outer` via
`subprocess.Popen(command, start_new_session=True)`. The Kimi process's
**stdin is a pipe**, not a PTY slave:

```
ls -la /proc/<kimi-pid>/fd/
0 -> pipe:[...]
1 -> /dev/pts/0
2 -> pipe:[...]
```

`c2c_deliver_inbox.py --notify-only` resolves the target via
`c2c_poker.resolve_pid()`, which requires a `/dev/pts/*` on fds 0, 1, or 2.
Since Kimi's stdin is a pipe, resolution fails.

Even if we bypassed this check and injected into `/dev/pts/0` (Kimi's stdout),
the injection would not reach Kimi's stdin because Kimi reads from the pipe,
not the PTY.

## Impact

- Kimi managed harness sessions cannot be woken by PTY-injected delivery nudges.
- Inbound DMs to Kimi will only be seen when the agent explicitly calls
  `mcp__c2c__poll_inbox` (e.g. at harness startup or via periodic outer-loop
  prompts).
- This is different from Codex/OpenCode managed harnesses, where the target
  process has a PTY and `c2c_deliver_inbox.py --notify-only` works.

## Fix Status

- `c2c_deliver_inbox.py` now catches `resolve_target` errors gracefully
  (commit pending) instead of dumping an unhandled traceback.
- The **structural gap** remains: managed Kimi needs a non-PTY wake mechanism.
  Candidates:
  1. Bake `poll_inbox` into every Kimi harness prompt (outer-loop injection).
  2. Have `run-kimi-inst-outer` write a synthetic prompt to Kimi's stdin pipe
     when the inbox file is modified.
  3. Accept polling-only delivery for Kimi and document it as a known limitation.

## Related

- `c2c_kimi_wake_daemon.py` is designed for interactive TUI Kimi sessions
  (where the user types into a PTY), not for managed harness sessions.
- `.collab/dm-matrix.md` currently marks Kimi delivery as `~† poll` (tentative
  polling path), which is accurate.
