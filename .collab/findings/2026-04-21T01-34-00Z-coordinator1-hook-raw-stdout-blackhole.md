---
author: coordinator1
ts: 2026-04-21T01:34:00Z
severity: critical
fix: 97ca916
---

# PostToolUse hook raw-stdout silently black-holed every c2c DM

## Symptom

Every Claude Code agent in the swarm was dependent on `Monitor` tasks to
learn about incoming DMs. The PostToolUse hook (`~/.claude/hooks/c2c-inbox-check.sh`
→ `c2c hook`) *was* running on every non-MCP tool call, *was* draining the
inbox, *was* printing `<c2c event="message">` envelopes to stdout — but
those envelopes never appeared in the assistant's transcript.

## Discovery

Max reminded me: "don't forget that you still need to fix the automatic
delivery (tool call post hook, etc). right now you're still dependent
on the monitors." Spawned claude-code-guide to confirm hook stdout
semantics.

## Root cause

Claude Code's PostToolUse hook only surfaces text to the assistant when
stdout is a single JSON blob of shape:

```json
{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "…"}}
```

Raw stdout (what `c2c hook` emitted: one `<c2c event="message">…</c2c>`
line per drained message) goes to the hook debug log only. The assistant
never sees it. Hook was effectively a no-op for message delivery; Monitors
were the only reason DMs ever reached any agent's transcript.

Worst property: silent. No error, no log visible to the agent, exit 0
every time. Inbox got drained (so messages were "lost" from the broker
too), but the assistant never saw them — they ended up in the archive
jsonl and nowhere else in-conversation.

## Fix

`97ca916` — `c2c hook` now JSON-wraps when messages are present. Empty
inbox still emits nothing (no change). Verified end-to-end in
coordinator1's own session: sent self a DM, ran a Bash call, the
envelope arrived as PostToolUse additionalContext.

## Why this mattered

This is the single biggest reason the swarm felt "half-awake" — every
agent needed an armed `Monitor` to see DMs at all, and between Monitor
ticks DMs were invisible even though the hook was technically "working."
Now DMs flow through the hook on every non-MCP tool call (matcher
`^(?!mcp__).*`), Monitors become belt-and-braces instead of primary.

## Rollout

Each agent needs `just bi && ./restart-self` (or equivalent rebuild +
re-exec) because the hook script invokes `c2c` by PATH and runs in a
child shell — but the fix is in the binary, so the next hook firing
after the rebuild will already use it. No settings change required;
hook script itself is unchanged.
