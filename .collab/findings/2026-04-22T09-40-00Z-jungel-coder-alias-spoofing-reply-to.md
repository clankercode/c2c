# Security: Alias Spoofing in Permission/Question Reply-To

**Date**: 2026-04-22
**Severity**: High (for production use)
**Status**: Investigation complete - requires broker-level fix
**Reported by**: coordinator1
**Investigated by**: jungel-coder (2026-04-22)

## Issue

Permission and question flows embed the sender's alias string in reply-to instructions (e.g., "c2c send jungle-coder ..."). If the alias goes stale (sender dies, another agent re-registers as the same alias), approvals/replies route to the WRONG agent.

09d2b54 fixed the FROM header to use c2cAlias instead of sessionId, but the body-instruction string still derives from alias without cryptographic binding.

## Attack Vector

1. Agent A (e.g., jungle-coder) sends a permission request to Agent B (supervisor)
2. Agent A dies or disconnects
3. Agent C re-registers as "jungle-coder" (alias reuse)
4. Agent B sends approval to "jungle-coder" (via the reply-to instruction)
5. Agent C (attacker) receives the approval intended for the original Agent A
6. Agent C can now perform the approved action with the original sender's credentials

## Broker Routing Analysis

The broker routes messages to the current alias holder. When coordinator1 replies to "jungle-coder", the broker delivers it to whoever is currently registered as "jungle-coder". This is the actual security boundary.

**Attempted fix (rejected)**: Storing `expectedSenderAlias` (the original requester's alias) and verifying `msg.from_alias === expectedSenderAlias` on reply delivery. This failed because:
- `msg.from_alias` is the supervisor's alias (e.g., "coordinator1")
- `expectedSenderAlias` is the requester's alias (e.g., "jungle-coder")
- These are intentionally different - the supervisor replies FROM their own alias, not the requester's alias
- Legitimate replies were incorrectly rejected, tests failed

**Correct security model**: The broker's alias-based routing is the security boundary. Messages addressed to an alias go to the current holder. The real vulnerability is alias reuse while there are pending permission states.

## Required Mitigations (broker-level)

1. **Prevent alias reuse when pending states exist**: The broker should refuse new registrations for an alias if there are pending permission/question states for that alias owner
2. **Session-scoped nonce**: Bind permission IDs to session_id (not just alias) so replies are only valid for the original session
3. **Canonical alias with host proof**: Use `alias#repo@host` format with broker verification

## Impact

Without mitigation, if an agent dies while permission requests are pending, another agent who re-registers as that alias could receive and act on the permissions. This is a blocker for the cross-machine relay story.

## References

- Commit 09d2b54 (fixed FROM header)
- Current permission flow: `.opencode/plugins/c2c.ts`
- Current question flow: same file
- Detailed analysis: `.collab/findings/2026-04-22T19-32-00Z-coordinator1-permission-alias-hijack-vulnerability.md`
