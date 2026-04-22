# Security: Alias Spoofing in Permission/Question Reply-To

**Date**: 2026-04-22
**Severity**: High (for production use)
**Status**: Open
**Reported by**: coordinator1

## Issue

Permission and question flows embed the sender's alias string in reply-to instructions (e.g., "c2c send jungle-coder ..."). If the alias goes stale (sender dies, another agent re-registers as the same alias), approvals/replies route to the WRONG agent.

09d2b54 fixed the FROM header to use c2cAlias instead of sessionId, but the body-instruction string still derives from alias without cryptographic binding.

## Attack Vector

1. Agent A (e.g., jungle-coder) sends a permission request to Agent B
2. Agent A dies or disconnects
3. Agent C re-registers as "jungle-coder" (alias reuse)
4. Agent B sends approval to "jungel-coder" (via the reply-to instruction)
5. Agent C (attacker) receives the approval intended for the original Agent A
6. Agent C can now perform the approved action with the original sender's credentials

## Additional Concern

Over relay (cross-machine), there's no cryptographic binding between the request originator and the alias being replied to. An unknown agent over relay can spoof an alias by simply registering as that alias.

## Proposed Mitigations

1. **Alias + session binding**: Reply-to includes both alias AND session_id (or a session-scoped nonce), so replies only work if the original session is still alive
2. **Canonical alias format**: Use `alias#repo@host` per Phase 1 design — replies require the full canonical form
3. **Per-message token**: Each request includes a cryptographically random request token; replies must include the correct token, not just the alias
4. **Relay-level validation**: Relay validates that the alias in a reply matches the original sender's verified alias

## Impact

Without mitigation, Codex/Kimi across hosts cannot reliably DM each other — alias spoofing breaks trust in cross-client communication. This is a blocker for the cross-machine relay story.

## References

- Commit 09d2b54 (fixed FROM header)
- Current permission flow: `.opencode/plugins/c2c.ts`
- Current question flow: same file
