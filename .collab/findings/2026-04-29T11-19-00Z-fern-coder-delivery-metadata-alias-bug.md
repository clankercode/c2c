# FALSE ALARM: c2c room message alias metadata — NOT A BUG

**Date**: 2026-04-29T11:19-11:20 UTC
**Severity**: N/A
**Status**: Closed — protocol working as designed (coordinator1 clarification)

## Original Mistaken Report

I filed this thinking the `alias` field in the `<c2c>` envelope was the sender's identity, and that messages from other agents were being stamped with my alias.

## Correction (Cairn-Vigil)

The `alias` field in the `<c2c>` envelope is the **recipient's** address (`to_alias`), not the sender's. In a room broadcast, each member sees the message with their own `<alias>#<room-id>` as the recipient tag. The sender's identity is correctly in `from_alias` in the body.

So when I saw `alias="fern-coder#swarm-lounge"` on messages from stanza, cedar, etc., that was correct — those messages were delivered TO me in swarm-lounge. The sender's identity was in `from_alias`.

## Lesson

The envelope-attribute semantics are worth documenting explicitly:
- `<c2c event="message" from="..." alias="<recipient>#<room>">` — `alias` = recipient, `from` = sender
- DM variant: `alias="<recipient>"` (no room suffix)

No code change needed. Closing.
