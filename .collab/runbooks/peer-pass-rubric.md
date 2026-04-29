# Peer-PASS Review Rubric

> **Audience**: Any c2c swarm agent doing a peer-PASS review.
> **When**: Run through this checklist before sending a PASS verdict.
> **Rule**: A self-review via `review-and-fix` skill is NOT a peer-PASS.
>         Another live swarm agent must sign off on code. (CLAUDE.md Rule 3)

A PASS means: "I reviewed this SHA, built it in the slice's own worktree,
and it is shippable." A FAIL means: "This has an issue that must be
fixed before it lands."

The four failure patterns below are the ones that have repeatedly survived
self-PASS and bitten the swarm. Each one has a detection trick and a fix
shape.

---

## 1. Forward-Reference / Lexical Scoping

**Symptom**: A function, type, or value is referenced before it is declared
inside a module, and the code still compiles because OCaml evaluates
definitions in order — but the reference resolves to whatever was in scope
*before* the intended definition.

**How to detect**: Look for a reference that depends on a later definition
in the same file. `just build` in the slice worktree will often succeed
(because the reference resolves to something — possibly stale — from a
previously compiled artifact). `git diff HEAD~1` on the file often makes
the ordering mistake obvious.

**Typical false-PASS**: Reviewer sees `just build` succeed in the worktree
and passes. The code works by accident because a prior build artifact from
an earlier state of the same file happens to satisfy the reference.

**Fix shape**: Move the referenced definition above its first use site in
the source file. In OCaml, declarations must precede uses within a single
module.

**Example from #488 round 1**: `log_broker_event` was called inside
`enqueue_message` but defined later in the same module. The call resolved
to a stale artifact; a clean rebuild would have changed the behaviour.

**Cross-ref**: `.collab/runbooks/worktree-discipline-for-subagents.md`
Pattern 8 — always build in the slice worktree, not the main tree.

---

## 2. Broker-Log Event Catalog Gap

**Symptom**: A new `Broker.log_event` call is added to the codebase but the
event name does not appear in the canonical catalog at
`.collab/runbooks/broker-log-events.md`. `just check` runs the
`check-broker-log-catalog.sh` script and **hard-FAILs** on undocumented
event names. If the review only ran `just build` (narrow target), the gap
is invisible.

**How to detect**: Run `just check` (not `just build`) in the slice
worktree. The catalog check is what catches this. If the slice touched
any `Broker.log_event` or `Yojson` emitter, verify the event name is in
the catalog.

**Typical false-PASS**: Reviewer ran `just build` (compile-only), not
`just check` (full build + catalog audit). The event compiles fine but is
undocumented, so `just check` on future commits will hard-FAIL.

**Fix shape**: Add the new event name to the catalog in the same commit
that introduces the `log_event` call. Removed events must be deleted from
the catalog too — both directions hard-FAIL `just check`.

**Cross-ref**: `.collab/runbooks/broker-log-events.md` — the canonical
catalog; `just check` validates against it.

---

## 3. Cross-Runbook Factual Drift

**Symptom**: A runbook references a path, command, or constant that is
correctly documented in one runbook but incorrectly stated in another. The
reviewer reads the local doc, finds it consistent, and PASSes — but the
value is wrong in practice because a sibling runbook has the correct value.

**How to detect**: For path references, verify the path exists before
PASSing. For command references, confirm the command is the canonical form.
When a runbook links to another (`./sibling.md`), check the sibling's
version of the same fact — not just the local text. If two runbooks
mention the same file or command and disagree, that is a FAIL.

**Typical false-PASS**: Reviewer reads the local file and finds it
internally consistent, missing that it contradicts a linked runbook. The
drift is only caught in production when an operator follows the documented
path and it doesn't work.

**Fix shape**: Align the value across both runbooks; decide which is the
authority and update the other. Update both in the same commit.

**Example from #473**: `kimi-as-peer-quickref.md` line 133 said
"kimi.log in the notifier log dir". The notifier log is at
`~/.local/share/c2c/kimi-notifiers/<alias>.log`; the kimi TUI session
log is at `~/.kimi/logs/kimi.log`. The linked runbook
`kimi-notification-store-delivery.md` had the correct path; the quickref
had the wrong one. An operator following the quickref would have looked
in the wrong directory.

**Cross-ref**:
- `.collab/runbooks/kimi-notification-store-delivery.md`
- `.collab/runbooks/documentation-hygiene.md` — verbatim-not-paraphrase
  rule for operational recipes.

---

## 4. Subagent-PASS-Does-Not-Count Rule

**Symptom**: The PASS verdict was produced by a subagent of the slice
author, or by the author's own `review-and-fix` skill invocation, not by an
independent peer. The chain of custody is broken.

**How to detect**: Check who ran the review. The PASS artifact must name
an agent that is neither the slice author nor a subagent of the slice
author. If the author reviewed their own code via a skill invocation, that
is a self-PASS and does NOT count. If a dispatched subagent produced the
verdict, the verdict is stamped with the parent's alias (because subagent
MCP sends come from the parent's session), so it is also invalid.

**Typical false-PASS**: The slice author dispatches a subagent, the
subagent "reviews" the work, and the author files the subagent's verdict
as a peer-PASS. Or the author runs `review-and-fix` themselves and treats
that as the required review. Both are self-PASS variants.

**Fix shape**: A real peer-PASS must come from a different agent in the
swarm who is not in a parent-child relationship with the author for this
slice. For doc-only slices, coord may approve self-PASS via
`review-and-fix` with the understanding that a live peer-PASS will follow
in a separate step.

**Rule text** (CLAUDE.md Rule 3):
> "Real peer-PASS before coord-PASS — another swarm agent runs
> `review-and-fix` on your SHA, and the reviewer's 'build clean' verdict
> MUST come from a build run inside the slice's own worktree with the rc
> captured in the artifact's `criteria_checked` list... self-review-via-skill
> is NOT a peer-PASS, and a subagent of yours doesn't count either."

**Cross-ref**:
- `.collab/runbooks/worktree-discipline-for-subagents.md` Pattern 12
  (subagent DMs lie about authorship)
- `.collab/runbooks/git-workflow.md` — peer-PASS gate before coord cherry-pick

---

## Review Checklist

Before sending a PASS verdict, run through each item:

```
[ ] I built (or ran `just check`) in the slice worktree, not the main tree
[ ] `just check` passed (not just `just build`) if any log_event was touched
[ ] Any new broker event name is in .collab/runbooks/broker-log-events.md
[ ] All path/command references match their sibling runbooks, not just this one
[ ] My verdict comes from a live peer, not my own skill run or subagent
[ ] If doc-only: coord approved self-PASS, or a live peer is queued for the real PASS
[ ] The criteria I checked are listed in the PASS artifact (criteria_checked)
```

If any item is a "no": FAIL, with a specific finding.

---

## Related

- `.collab/runbooks/git-workflow.md` — peer-PASS gate workflow
- `.collab/runbooks/worktree-discipline-for-subagents.md` — worktree mechanics
  and subagent pattern warnings (Patterns 8, 12, 13)
- `.collab/runbooks/broker-log-events.md` — event name catalog
- `.collab/runbooks/documentation-hygiene.md` — verbatim-not-paraphrase rule
