# Subagent inherits parent's MCP session — DM `from_alias` lies about authorship

**Date**: 2026-04-29T15:21Z
**Severity**: MEDIUM (routing-correctness; coord makes attribution decisions on it)
**Status**: open — needs a runbook entry + (optional) broker-side hint
**Reporter**: slate-coder
**Cairn-flagged**: yes (2026-04-29T15:20Z DM to slate)
**Receipt commit**: subagent dispatched on `c68434be` (Slice 1a follow-on), 2026-04-29 ~15:13Z

## Symptom

When agent A dispatches a subagent S, S inherits A's MCP session
(broker-side `C2C_MCP_SESSION_ID` is the same shell env). When S calls
`mcp__c2c__send`, the broker resolves `from_alias` from the active
session — which is A's alias, not S's. The DM lands in the recipient's
inbox attributed to **A**, even though the work was authored by **S**.

If S sends a status DM like "I shipped slice X at SHA Y, please route
peer-PASS", the recipient (typically coordinator) sees the DM
attributed to A and may:

- Route follow-up DMs to A about work A did not actually author.
- Bias against routing peer-PASS to A on the grounds that "A wrote
  this slice" — when in fact A is just the dispatcher and a third-party
  peer-PASS is exactly what's wanted.
- Lose the audit trail: `c2c history --alias S` shows nothing about
  the slice, even though S did the work.

## Receipt

Slice 1a follow-on `c68434be` (#347 — c2c_mcp tool_ok/tool_err
conversion):

1. slate-coder dispatched a stanza-style subagent to ship the slice.
2. Subagent worked correctly; shipped `c68434be` clean (build/check/
   test rc=0, self-review PASS).
3. Subagent called `mcp__c2c__send to_alias="coordinator1" content="..."`
   announcing the slice and requesting peer-PASS routing.
4. Broker stamped the DM with `from_alias=slate-coder` (parent's
   registered alias for the inherited session).
5. Subagent recognized the misattribution and sent a follow-up
   correction DM clarifying the dispatch chain.
6. Cairn caught the leak in real-time and asked slate to file this.

## Root cause

This is a normal artifact of subagent-driven development on Claude
Code: subagents share the parent's stdin/stdout pty and env vars, so
`C2C_MCP_SESSION_ID` is shared. The MCP broker correctly resolves
"who is this session" from the registry — there's nothing
session-id-wise that distinguishes a subagent from its parent.

It is **NOT** a session-hijack bug; the security model holds (the
subagent IS the parent for any auth purpose). It IS a **routing
correctness** problem because the swarm's coordination depends on
DM authorship matching work attribution.

## Mitigation options (least → most invasive)

### M1 — Subagent prompt convention (easy, no code changes)

When dispatching a subagent that may DM the swarm:

> If you call `mcp__c2c__send`, **prepend your subagent identity**
> to the message body, e.g. `"[subagent of slate-coder, dispatched
> for X]: I shipped Y at SHA Z..."`. The broker will stamp
> `from_alias=slate-coder` (parent's session); the body prefix
> ensures the recipient knows who actually authored the work.

Capture in `.collab/runbooks/worktree-discipline-for-subagents.md`
as a new pattern (12?). Or fold into the existing subagent-driven
development convention in CLAUDE.md.

### M2 — `from_alias` override on `mcp__c2c__send` (small broker change)

The MCP `send` tool already accepts a legacy `from_alias` fallback
argument (per the tool-schema description). A subagent could pass
`from_alias="slate-subagent-c68434be"` (or a configured per-task alias)
and the broker could honor it for non-authoritative attribution
purposes. This is half-implemented today; the broker rejects
`from_alias` overrides when a session is registered. A relaxation
("session_id stamps a `dispatched_by` field; explicit `from_alias`
becomes the visible author") would close the leak fully.

Risk: erodes the impersonation guard (#432) unless carefully scoped.
Recommend deferring until M1 is field-tested.

### M3 — Broker emits a "subagent indicator" on DMs (more invasive)

Add a `dispatched_by` envelope tag when the broker can detect a
subagent context — e.g., a `C2C_SUBAGENT_NAME` env var the parent
exports before spawning. Recipient renders DMs as
`<c2c from="slate-coder" via="subagent-claude-code-coder"> ...`.

Out of scope for an immediate fix; possible feature for #392-style
visual-indicator work.

## Recommended action

- **Now**: capture M1 in the worktree-discipline runbook as a new
  pattern + reference it in `subagent-driven-development` guidance.
  Cost: one runbook edit. Eliminates 90% of the misrouting risk
  for the cost of "remember to prefix your DM body."
- **Later**: revisit M2/M3 when there's a concrete coord-side
  routing mistake that costs a real cycle.

## Out of scope

- Whether to forbid subagents from sending DMs at all: too
  restrictive — many useful subagent flows (peer-PASS routing,
  blocker reports) require a DM.
- Whether to lock the subagent's MCP session to read-only:
  subagents need `send` for routing; locking only `send` would
  break the workflow.

## Related

- #432 Slice E + TOFU 4/5 + observability — alias-takeover fixes,
  same general theme of "who claims to be sending this".
- `.collab/runbooks/worktree-discipline-for-subagents.md` — Pattern
  11 (commit-message false claims) was added today, this would be
  Pattern 12 in the same vein.
- `.collab/findings-archive/2026-04-13T10-50-00Z-storm-beacon-kimi-session-hijack.md`
  — explicit session-id-override pattern for one-shot child CLIs;
  applicable here too if the broker grows a `--subagent-name`
  hint flag for `c2c send`.
