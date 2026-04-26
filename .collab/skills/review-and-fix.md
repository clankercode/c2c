---
name: review-and-fix
description: "Use when validating a c2c slice before peer-PASS handoff to coordinator. Runs a thorough review against acceptance criteria, fixes issues, and rereviews until PASS — geared for the c2c worktree-per-slice + signed peer-PASS workflow."
---

# Review And Fix (c2c project-local)

Disciplined review/fix loop tuned for c2c's swarm workflow. The output of a
PASS run is normally **input to a peer-PASS** — i.e. another swarm agent then
runs this skill against your SHA before coordinator1 cherry-picks. Self-run of
this skill is NOT a peer-PASS by itself.

See also: `.collab/runbooks/git-workflow.md`,
`~/.claude/skills/review-and-fix/SKILL.md` (global generic version).

## Pre-flight

Before invoking the skill:

- The work is committed. Reviewer needs a stable SHA — never `--amend` after
  a peer-PASS DM goes out.
- The work lives in `.worktrees/<slice-name>/`, branched from
  `origin/master` (NOT local master, which may contain unmerged peer work).
  See `.collab/runbooks/worktree-per-feature.md`.
- `just install-all` has succeeded against the worktree (reviewer can `c2c`
  the new binary if needed).

## Workflow

### Step 1: Review

Launch a subagent (Agent tool) to review the work. Prompt should be detailed,
professional, and direct, and include relevant files + the SHA.

Instruct the reviewer to:

- Evaluate against the work description / acceptance criteria / surrounding
  code.
- Identify bugs in the implementation.
- Ensure the code is neat, well integrated, consistent with existing
  practices.
- Ensure no excessive duplication or obvious refactor opportunity.
- Ensure the implementation is intuitively complete: hooked up properly,
  no obvious missing pieces, no half-finished branches.
- **Ensure user-facing docs are up to date with the change.** If the slice
  changes any documented surface — CLI flags / `--help` text, MCP tool
  schemas, env vars, runbook procedures, design specs (`.collab/design/`),
  README, CLAUDE.md, project landing pages (`docs/`), `c2c relay`
  landing-page HTML in `ocaml/relay.ml` — the matching docs MUST be updated
  in the same slice. Suggested check: `c2c doctor docs-drift` against the
  worktree. PASS while docs still describe old behavior = a docs-drift bug
  being signed off. FAIL if user-facing docs are stale; the slice author
  either expands scope or splits a follow-up doc-only slice referenced by
  SHA before coord-PASS.
- Ensure tests cover the change (RED-first preferred; existing tests still
  pass; new tests are deterministic and don't add live-network dependence).
- Return `PASS` or `FAIL`. `FAIL` if any single meaningful issue remains.
- Do not delegate further to other subagents.

### Step 2: Address issues

If the review returns `FAIL`, launch a fixing subagent (or fix inline).

Instruct the fixer to satisfy both:
- the review findings
- the original work description and acceptance criteria

Fixer constraints:
- **New commit for every fix.** Never `--amend` — the peer-PASS DM
  references the SHA; amending breaks the audit trail.
- Do not delegate further to other subagents.
- Re-run `just install-all` after the fix lands so the binary is current.

### Step 3: Repeat

After a fix, return to Step 1 and rereview.

Continue until:
- the work passes, or
- the problem is deeply blocked, contradictory, or requires user-level
  design decisions (escalate via DM to coordinator1 in that case).

### Step 4: Emit signed peer-PASS artifact (after PASS)

After a PASS verdict — and only if you are reviewing **someone else's** work
(self-review-via-skill is NOT a peer-PASS) — emit a signed peer-PASS
artifact so the review is verifiable on cherry-pick:

```bash
c2c peer-pass sign <SHA> \
  --verdict PASS \
  --criteria "<criterion1>, <criterion2>, ..." \
  --skill-version <version> \
  --commit-range <from>..<to> \
  [--all-targets] \
  [--notes "<free text>"] \
  [--json]
```

Required:
- `SHA` — git SHA of the reviewed commit
- `--verdict PASS` (or `FAIL`)
- `--criteria` — comma-separated criteria checked

Optional:
- `--skill-version` — version of the review skill used
- `--commit-range` — e.g. `abc123..def456`
- `--all-targets` — mark all binaries (c2c, c2c_mcp_server, c2c_inbox_hook)
  as built and verified
- `--notes` — free-text notes
- `--json` — machine-readable output

Verify the artifact stored:

```bash
c2c peer-pass verify .c2c/peer-passes/<SHA>-<your-alias>.json
c2c peer-pass list
```

On FAIL: do NOT emit an artifact — return FAIL verdict directly to the
slice author so they can fix in a new commit.

### Step 5: DM coordinator1

Once the artifact is signed, DM coordinator1:

```
peer-PASS by <your-alias>, SHA=<sha>, branch=<branch>, in .worktrees/<slice-name>
```

Coordinator cherry-picks to master, runs `just install-all`, then decides
push timing.

## Guidance

- Prefer focused review findings over vague unease.
- Preserve scope discipline; do not turn a review into a redesign unless
  the spec itself is broken.
- Subagent-verified is NOT a peer-PASS. Your own session — not your own
  subagents — running this skill on someone else's commit is a peer-PASS.
- If the slice author also wants their own pre-handoff confidence check,
  they can run this skill on their own commit. That is "self-review-via-
  skill" and is NOT a peer-PASS, but does help catch issues early.

## Common failure modes

- **Stale binary**: reviewer trusts local `c2c` behavior but `just
  install-all` was skipped after the last fix. Re-run before testing.
- **Branched from local master with uncommitted-to-origin commits**:
  cherry-pick later may revert peer work. Re-base off `origin/master` and
  rerun the loop.
- **Docs-drift at PASS**: user-facing docs still describe the old surface.
  FAIL — see Step 1 docs check. Use `c2c doctor docs-drift` to diagnose.
- **Peer-PASS for own work**: artifact signed by the same alias as the
  commit author. The broker's self-PASS-detector will refuse this; the
  pre-push hook also gates on it. Get a real peer.
