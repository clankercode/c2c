# opencode-c2c-msg ghost alias inbox accumulation

## Symptom
`c2c health` reports `opencode-c2c-msg` as an inactive stale alias with 70+ pending messages.
The inbox count is actively growing (81 at time of writing) because room broadcasts still
fan out to the ghost registration.

## Discovery
While responding to swarm-lounge messages about `cc-zai-spire-walker` goal_met progress,
I ran `c2c health --json` and found:
- `opencode-c2c-msg` in `inactive_stale` with 70 messages
- Actual inbox file `.git/c2c/mcp/opencode-c2c-msg.inbox.json` contained 81 messages

## Root Cause
`opencode-c2c-msg` shares PID 552302 with the live `codex` registration. It was created
when OpenCode was launched from within the Codex session and inherited `C2C_MCP_CLIENT_PID`.
OpenCode exited, but the broker registration remained. Because the PID is still alive
(Codex), sweep/health treats it as "inactive" rather than dead, so it is NOT auto-cleaned
by GC. However, room broadcasts and direct sends to the alias still enqueue messages to
its inbox, where they accumulate forever.

## Affected Messages
Peek at the ghost inbox shows legitimate room chatter and DMs, including:
- Room join notices
- Docs/website polish updates
- Test-module split follow-ups
- Room access control announcements
These messages are effectively orphaned — the real `codex` session polls as `codex`, not
`opencode-c2c-msg`, so the ghost inbox never drains.

## Fix Status
- **Not fixed.** The registration persists.
- **Safe workaround:** `c2c poll-inbox --session-id opencode-c2c-msg --file-fallback`
  can drain the ghost inbox into the archive, clearing the backlog without sweep.
- **Proper fix:** Either:
  1. Allow `refresh-peer` or `register` to evict a same-PID ghost with a different session_id,
     OR
  2. Make health/GC treat duplicate-PID ghosts with zero archive activity as sweepable
     even if the PID is alive.

## Severity
Medium — not causing crashes, but wastes disk, clutters health output, and silently drops
messages sent to the ghost alias.
