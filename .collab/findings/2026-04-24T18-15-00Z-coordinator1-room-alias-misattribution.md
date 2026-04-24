# Room message alias misattribution: jungle-coder messages appear as coordinator1

**Reporter**: coordinator1 (Cairn-Vigil) + Max Kaye
**Date**: 2026-04-24T18:15 UTC
**Severity**: high — breaks trust/attribution in room history; impersonation vector

## Symptom

`mcp__c2c__room_history` for swarm-lounge shows messages sent by jungle-coder
with `from_alias: "coordinator1"`. Specifically:

- ts 1776967858: "coordinator1" → "@jungle-coder relay-connector.ml build broken..."
- ts 1776968056: "coordinator1" → "I apologize - I checkout'd HEAD..."
- ts 1776968102: "coordinator1" → follow-up apology

Max confirmed these were sent by jungle-coder, not coordinator1.

## How discovered

coordinator1 noticed unfamiliar messages attributed to itself in room_history
and flagged as potential impersonation. Max confirmed it's a bug, not a second
coordinator1 session.

## Root cause (suspected)

Unknown — needs investigation. Possible causes:
1. `send_room` call by jungle-coder passes wrong `from_alias` to broker
2. Broker persists room messages with incorrect sender (e.g. uses `to_alias`
   lookup instead of session-resolved `from_alias`)
3. jungle-coder's OpenCode session registered with coordinator1's session_id
   somehow, so broker resolves its alias as coordinator1
4. Room history write path uses a different alias resolution than direct DMs

## Impact

- Any agent or human reading room_history sees incorrect attribution
- Coordinator may take responsibility for actions it didn't take
- Could theoretically be exploited for impersonation if not fixed
- Makes coordination decisions based on room history unreliable

## Narrowed root cause

`c2c_start.ml:799` correctly sets `C2C_MCP_SESSION_ID=<name>` for the spawned
managed session — so jungle-coder's MCP env had the right value.

That means the bug is in the broker's `send_room` handler: it's not resolving
`from_alias` from the MCP connection's session identity (established at
`initialize` time), but from some other source — possibly a registry lookup by
the wrong key, or an env-var read that picks up the parent shell's
`C2C_MCP_SESSION_ID=coordinator1`.

Candidate location: `c2c_mcp.ml` — the `send_room` tool handler's
from-alias resolution path.

## Fix status

Open — root cause narrowed to send_room alias resolution in c2c_mcp.ml.

## Next steps

- Check broker's `send_room` handler: does it resolve from_alias from
  session_id (correct) or from the message payload (spoofable)?
- Compare jungle-coder's registered session_id vs coordinator1's
- Check if OpenCode's MCP session is registering with the wrong session_id
  (known footgun: child CLIs inherit CLAUDE_SESSION_ID)
