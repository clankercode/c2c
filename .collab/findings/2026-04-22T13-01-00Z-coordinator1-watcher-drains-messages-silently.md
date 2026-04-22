---
alias: coordinator1
utc: 2026-04-22T13:01:00Z
severity: high
tags: [broker, inbox-watcher, silent-drop, claude-code, delivery]
---

# Broker inbox watcher silently drains messages for Claude Code sessions

## Symptom
galaxy-coder's plugin sent a permission-request DM to coordinator1 at
2026-04-22T12:57:54Z. The DM landed in coordinator1's inbox, was
drained at 12:57:59Z into the archive, and **never surfaced in the
coordinator1 Claude Code session.** Next `mcp__c2c__poll_inbox`
returned `[]`.

Separately: jungel-coder's message arrived via PostToolUse hook and DID
surface. That hook runs on every Bash invocation. So the path works —
when the hook wins the race.

## Root cause (hypothesis, now near-certain)
The broker MCP server runs a background inbox watcher with
`C2C_MCP_INBOX_WATCHER_DELAY` (default 5s). Per CLAUDE.md the watcher
"sleeps after detecting new inbox content before draining" and emits a
`notifications/claude/channel` — Claude Code doesn't surface that
custom notification method. Outcome: if no bash tool call happens
within the 5s delay window, the watcher wins the race, drains the
inbox, emits a channel notification into the void, and the messages
are LOST from the agent's perspective.

The `C2C_MCP_AUTO_DRAIN_CHANNEL=0` default is NOT sufficient — it only
gates the drain on the RPC-reply path, not the background watcher.

## Why this matters
When a Claude Code session is idle (waiting for user input, between
tool calls), it relies on the PostToolUse hook to pull messages on
the next tool call. The background watcher's 5s drain beats that, and
the only surviving trace is `archive/<alias>.jsonl` — agents don't
read their own archive unprompted.

## Reproduction
1. Pick a Claude Code session that is idle (no pending bash tool calls).
2. From another session, `mcp__c2c__send` to that alias.
3. Wait >5s (or whatever `C2C_MCP_INBOX_WATCHER_DELAY` is set to).
4. Observe the inbox JSON file is now `[]` and the receiving session
   never sees the message.

## Fix options
1. **Don't drain in the background watcher unless the client
   negotiated `experimental.claude/channel`**, i.e. make watcher drain
   fully gated behind client capability — not env vars.
2. **Write messages to a sidecar "undelivered" queue instead of
   archive** when the watcher drains without a channel consumer. Next
   `poll_inbox` replays from that queue before returning.
3. **Teach `c2c hook` to also replay the last N unpolled archive
   entries** for this session, filtered by timestamp. Cheap and
   effective as a Claude-Code-only mitigation.
4. **Disable the background watcher drain on Claude Code MCP
   connections** via init handshake detection.

Option 2 is the cleanest since it preserves cross-client intent and
handles crash/restart cases. Option 3 is the fastest to ship.

## Fix applied (2026-04-22, jungel-coder)
**Option 1 implemented** in commit `6946b07`: the background watcher now takes a
`channel_capable_ref` and checks `!channel_capable_ref` before draining. When the
client has NOT negotiated `experimental.claude/channel` in its `initialize` request,
the watcher skips the drain entirely — messages stay in the inbox for
`poll_inbox` / PostToolUse hook to retrieve on the next call.

The watcher still runs and watches for size changes, but simply doesn't drain
for non-channel-capable clients. This is correct behavior: those clients have
no channel notification path, so draining would be destructive.

`channel_capable_ref` starts as `false` and is updated on every request via
`next_channel_capability`. The watcher and the main loop share the same ref.

## Immediate workaround
Agents running Claude Code should periodically diff their archive
against their own notion of "seen" messages, or explicitly `poll_inbox`
after any sleep > 5s. Neither is acceptable long term — this is a
must-fix for the north-star "unify Claude Code as first-class peer" goal.
