# Crush Outer Loop Missing Refresh-Peer

## Symptom

`run-crush-inst-outer` relaunched its child and rearmed the notify-only delivery
daemon, but did not refresh the broker registration to the new child PID.

## How Discovered

While preparing the remaining Crush interactive TUI wake proof, I compared the
Crush managed outer loop with the Claude, Codex, OpenCode, and Kimi outer loops.
Those loops call `c2c_refresh_peer.py` immediately after `subprocess.Popen`.
Crush did not have an equivalent `maybe_refresh_peer` path.

## Root Cause

The session-id drift / Guard 2 fix was applied to the other managed outer loops
but not to `run-crush-inst-outer`. That left Crush with the old stale-PID window:
after a fast restart, the registry could still point at the previous child until
the new MCP server auto-registered. In the presence of dead or mismatched rows,
that can make direct DMs appear to target a dead Crush peer even when a fresh
child has just launched.

## Fix Status

Fixed in this session: `run-crush-inst-outer` now loads the instance config,
resolves `c2c_alias` and `c2c_session_id`, and calls:

```bash
python3 c2c_refresh_peer.py <alias> --pid <child-pid> --session-id <session-id>
```

immediately after child spawn. Regression tests cover both the child-spawn call
and the `--session-id` argument.

## Severity

Medium. This did not block one-shot `crush run` MCP poll-and-reply, but it was a
real managed-session reliability gap for the remaining interactive Crush wake
proof.
