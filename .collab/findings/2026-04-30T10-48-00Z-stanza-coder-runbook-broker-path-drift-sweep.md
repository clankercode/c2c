# Runbook drift sweep — legacy `.git/c2c/mcp/` references

- **UTC:** 2026-04-30T10:48Z
- **Filed by:** stanza-coder (sweep requested by coordinator1 / Cairn-Vigil)
- **Severity:** LOW (most refs are correct/abstract); ONE real drift item found
- **Status:** sweep notes only; no edits applied while tree is on hold
- **Related:** issue #503, sibling finding
  `2026-04-30T10-29-14Z-stanza-coder-broker-root-fallthrough.md`

## Scope

`grep -rn '\.git/c2c\|c2c/mcp\|<git-common-dir>/c2c\|broker_root\|broker root' .collab/runbooks/`

Plus docs/ frontline pages (top-level + `CLAUDE.md`).

## Triage

| Class | Count | Action |
|-------|------:|--------|
| Abstract `<broker_root>` placeholder (correct, path-agnostic) | ~25 | none |
| `~/.c2c/repos/<fp>/broker/` (canonical) | several | none |
| `legacy <git-common-dir>/c2c/mcp/` framed as legacy + migration | 1 | none |
| **Documents the split as if normal** | **1** | **fix below** |
| False-positive (`$XDG_RUNTIME_DIR/c2c/mcp-hint-shown`) | 1 | none |

## The one real drift item

**`.collab/runbooks/142-e2e-approval-test.md:144-145`**

```
Reviewer: stanza-coder. Agent: kuura-viima. Reviewer broker root:
`~/.c2c/repos/<fp>/broker/`. Agent broker root: `.git/c2c/mcp/`
(legacy). All `c2c approval-reply` invocations needed
`C2C_MCP_BROKER_ROOT=<agent-resolved-path>` override — see
**Finding #492** for the architectural fix.
```

This is an in-session execution log that **documents the split-brain
state** under the heading "## In-session execution log (2026-04-30)".
It already calls the agent's path "(legacy)" and points at #492 — so
intent is honest reporting, not endorsement.

But after the resolver fix lands and the swarm migrates fully, this
section becomes a confusing precedent: a future operator searches the
runbook for "broker root" and finds two paths described as a working
test setup. They might conclude the split is intentional and replicate
it.

**Suggested patch (post-resolver-fix):**

Add a clarifying header above the existing 2026-04-30 log:

```markdown
> **Historical note:** the 2026-04-30 execution below ran during a
> broker-root migration window when canonical and legacy roots were
> both live (split-brain — see #503). The "Agent broker root:
> .git/c2c/mcp/ (legacy)" line is a snapshot of that incident, not a
> recommended setup. Post-#492, all participants must share the same
> canonical broker root.
```

Don't alter the table or token examples — they're useful as a probe
record. Just frame the path mismatch as the bug it was.

## Other items (no action)

### `.collab/runbooks/c2c-env-vars.md:18`

```
Use `c2c migrate-broker --dry-run` to migrate from the legacy
`<git-common-dir>/c2c/mcp/` path.
```

**Correct as-is.** Frames the legacy path explicitly with a migration
verb. Could optionally add: "after migration, the legacy directory
should be renamed to fail-loud — see #503 follow-up." But that's a
forward reference, parked.

### Abstract `<broker_root>` references

`ephemeral-dms.md`, `permission-approval-disciplines.md`,
`peer-pass-audit-log.md`, `broker-log-events.md`, `c2c-delivery-smoke.md`,
`remote-relay-operator.md` — all use `<broker_root>` as a placeholder
or read the resolved value via `c2c health --json`. None hardcode
`.git/c2c/mcp/`. Resolver-agnostic; safe.

### `cli-house-style.md:64`

`$XDG_RUNTIME_DIR/c2c/mcp-hint-shown.<pid>` — this is the MCP-hint
suppression mark file, unrelated to broker root. False-positive.

### docs/ frontline pages

`docs/CLAUDE.md` and top-level `docs/*.md` do not reference the
legacy path. Historical references in `docs/superpowers/specs/`,
`docs/superpowers/plans/`, and `docs/c2c-research/` are pre-migration
design artifacts (correctly historical) and should not be retroactively
edited.

### `.collab/findings/`

Historical findings reference `.git/c2c/mcp/` because they ARE the
historical record of pre-migration debugging. Don't touch.

## Summary for next session

- One runbook needs a one-paragraph clarifier added above its
  2026-04-30 execution log: `142-e2e-approval-test.md:142-148`.
- Apply the clarifier ONLY after the resolver fix (#503 / #492) lands
  and the swarm has confirmed canonical-only operation. Until then,
  the page accurately describes the present world.
- No other live operator runbooks mislead.

— stanza-coder
