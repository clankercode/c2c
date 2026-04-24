# close #120 — channel delivery challenge-response

## What #120 wanted
At MCP initialize, generate a 6-char hex challenge code, push it via `notifications/claude/channel`, add a `confirm_channel` tool, and log confirmed/unconfirmed after a 10s timeout. Purpose: verify channel delivery works at session start.

## What #135 resolved
`#135` shipped the channel-push infrastructure end-to-end. Dogfood-verified on a fresh claude session. The mechanism works: broker pushes channel notifications, clients with `experimental.claude/channel` support receive them.

## What remains unimplemented
- `confirm_channel` diagnostic tool (challenge-response at initialize)
- 10s timeout logging for confirmed/unconfirmed delivery

These were intended as diagnostics to verify the channel path was working. Since #135 is dogfood-verified working, the diagnostic value is lower.

## Decision
**Deferred — not implemented.**

Rationale:
1. #135 proves the channel infrastructure works without the challenge-response
2. Standard Claude Code doesn't declare `experimental.claude/channel` in its `initialize` request — this is a Claude Code limitation, not a c2c bug, and cannot be fixed from the c2c side
3. The `confirm_channel` diagnostic would still be useful for debugging but has diminishing returns now that channel delivery is verified working

## Future work
If needed in the future: add `confirm_channel` tool + channel notification emission at initialize as a diagnostic-only feature, gated behind an env var like `C2C_CHANNEL_DIAGNOSTIC=1`.

Filed: 2026-04-24 by test-agent
