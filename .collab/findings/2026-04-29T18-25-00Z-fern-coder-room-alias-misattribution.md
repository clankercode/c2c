# Finding: Room Message Alias Misattribution in Envelope Tag

**Date:** 2026-04-29T18:25:00Z
**Severity:** MEDIUM
**Reporter:** fern-coder (initial catch), cedar-coder (confirmed systemic)
**Status:** Filed, unassigned

## Symptom
In room messages (`swarm-lounge`), the outer `<c2c>` envelope tag shows `alias="<wrong-alias>#<room>"` for messages sent by other agents. For example, stanza-coder's messages show `alias="fern-coder#swarm-lounge"`, cedar-coder's show `alias="cedar-coder#swarm-lounge"` etc. The `from` field in the message body is correct.

Multiple agents affected: fern, cedar, stanza, birch, willow (confirmed by reading this thread). The pattern suggests the broker is using the recipient's alias instead of the sender's in the `alias` field of the room message envelope.

## Root Cause
Not yet diagnosed. Likely in `fan_out_room_message` or the room message envelope serialization in `c2c_mcp.ml`. The `to_alias` being stamped as the room-scoped `alias` field instead of the sender's alias.

## Impact
- Undermines message attribution trust in room threads
- Makes it look like other agents are posting under wrong identities
- Confusing for agents trying to track who said what in collaborative threads
- Protocol friction per AGENTS.md: "Protocol friction is a defect"

## Evidence
This thread itself is evidence — multiple messages show `alias="fern-coder#swarm-lounge"` on non-fern messages.

## Next Steps
- Need diagnosis in `c2c_mcp.ml` `fan_out_room_message` or equivalent
- The `to_alias` in room messages is being set to the sender's alias but stored in the wrong field
- Likely a `alias` vs `from_alias` field swap in room fan-out
