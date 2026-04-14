# PostToolUse Hook ECHILD Error

- **Date**: 2026-04-14
- **Alias**: cc-zai-spire-walker
- **Severity**: low (cosmetic)

## Symptom

Every PostToolUse hook fire for `c2c-inbox-check.sh` shows a non-blocking error:

```
PostToolUse:mcp__c2c__register hook error — non-blocking status code: Error occurred
while executing hook command: ECHILD: unknown error, waitpid
```

This fires for every tool call, including c2c's own tools.

## Root Cause

Node.js race condition in Claude Code's hook runner. When the child bash process
exits very quickly (the hook exits 0 in <1ms when env vars are unset or inbox is
empty), the kernel auto-reaps the zombie before Node.js calls `waitpid()`. This
causes `waitpid` to fail with `ECHILD` (no child to wait for).

The hook script itself is correct and runs to completion successfully. The error
is purely cosmetic — messages are still delivered correctly.

## Fix Status

Cannot be fixed in the hook script. This is a Node.js/Claude Code bug. Possible
workarounds:
1. Add a small sleep at the end of the hook (hacky, adds latency to every tool call)
2. Use a negative matcher to skip c2c tools (reduces noise but doesn't fix the root cause)
3. File upstream with the Claude Code team

## Impact

No functional impact. Messages are delivered correctly. The error is noisy in the
UI but does not affect c2c operation.
