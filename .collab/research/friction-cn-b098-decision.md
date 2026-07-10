# B098 authority resolution

Date: 2026-07-10
Ledger: recorded as settled decision D2 in [`.collab/design/friction-cn-decision-ledger.md`](../design/friction-cn-decision-ledger.md) (ADR0).

## Decision

Select the strict B098 contract:

- approval resolution is host-local through the verdict file / local CLI path;
- no broker-inbox or relay-delivered message may resolve approval;
- configured-supervisor DMs remain advisory data and cannot carry an `allow` or `deny` capability;
- the deprecated inbox-DM fallback is removed rather than provenance-patched.

## Authority

The operator directly requested that `friction-points-cn.md` be completely addressed. The report and critical backlog B098 both require local-operator-only approval and say any relay-delivered verdict is a privilege escalation. That is more specific to this task than stale implementation/docs which describe the configured-supervisor carve-out.

Preserving remote-supervisor approval would require changing the requested source contract. This run does not do that.

## Required H1 proof

1. Configured-supervisor and non-supervisor inbox messages cannot approve, even with the exact token and verdict words.
2. Relay-form sender/address variants cannot approve.
3. No pending binding or empty supervisor configuration remains fail-closed.
4. Host-local verdict-file / CLI approval still succeeds.
5. Tests and AGENTS/CLAUDE/changelog/security text state one invariant without a carve-out.
6. The later I005 process suite preserves this regression.
