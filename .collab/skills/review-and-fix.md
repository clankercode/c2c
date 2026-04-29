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

### Build the slice IN ITS OWN WORKTREE — not yours, not master (#427)

**Mandatory.** When reviewing SHA `<X>` on `slice/<topic>`, the reviewer's
build verdict MUST come from a build run against THAT slice's worktree, not
from the reviewer's main tree or any other dirty checkout. Master being
green on its own is not evidence the slice builds — the slice may introduce
references that don't exist on master, or signature mismatches that only
surface after the cherry-pick.

Procedure:

1. `cd .worktrees/<slice>/` (or use `dune build --root <worktree-path>`).
2. `rm -rf _build` IF the worktree's `_build/` may have been populated by
   the slice author with an interactive cycle — Dune caches build artifacts,
   and a stale `_build/` can mask a real compile error. (For a fresh
   worktree just created via `git worktree add`, the cache is empty already
   and `rm -rf _build` is a no-op.)
3. `just build` from the slice worktree (or `opam exec -- dune build --root
   <slice-path>`). Capture the exit code.
4. Report the build verdict in the peer-PASS artifact's `criteria_checked`
   list with a verbatim entry like `build-clean-IN-slice-worktree-rc=0` so
   the reader can confirm the build was actually performed against the
   slice, not an adjacent tree.

**Background**: 2026-04-29T02:28Z `812cce1e` (#379 S1) was peer-PASSed by
three independent reviewers all reporting "build clean" against code that
fails to compile after cherry-pick (missing `stripped_to_alias` in scope,
constructor-signature mismatch on `~self_host`). The reviewers' builds
returned `rc=0` because they were running against master without the
slice applied, OR against a stale `_build/` cache. The rubric below now
requires: in-worktree build, fresh `_build/` (or proven not stale), and
explicit `rc=N` capture in the artifact.

Full receipt:
`.collab/findings/2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`.

Pattern 8 in `.collab/runbooks/worktree-discipline-for-subagents.md`
covers this rule from the discipline-runbook angle (cedar's
Pattern 7 is the complementary clean-cache rule — both must hold
for the reviewer's build verdict to be trustworthy).

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

After a PASS verdict, emit a signed peer-PASS artifact and DM the
coordinator in one command. The default and preferred path is **another
swarm agent** running this skill on someone else's SHA — that's the
canonical peer-PASS. A **fresh-slate subagent** verdict on your own SHA
is a sanctioned substitute when no live peer is available or the slice
is mechanical / low-stakes (see "Subagent-review as peer-PASS" in
`git-workflow.md` and the Step 4 note below on `--allow-self`):

```bash
c2c peer-pass send coordinator1 <SHA> \
  --verdict PASS \
  --criteria "<criterion1>, <criterion2>, ..." \
  --skill-version <version> \
  --commit-range <from>..<to> \
  --branch <branch> \
  --worktree .worktrees/<slice-name> \
  --build-rc 0 \
  [--all-targets] \
  [--notes "<free text>"] \
  [--json]
```

If you need an artifact without sending a DM, use:

```bash
c2c peer-pass sign <SHA> \
  --verdict PASS \
  --criteria "<criterion1>, <criterion2>, ..." \
  --skill-version <version> \
  --commit-range <from>..<to> \
  --build-rc 0 \
  [--all-targets] \
  [--notes "<free text>"] \
  [--json]
```

Required:
- `SHA` — git SHA of the reviewed commit
- `--verdict PASS` (or `FAIL`)
- `--criteria` — comma-separated criteria checked. **Per #427, the list MUST
  include a verbatim build-rc entry like `build-clean-IN-slice-worktree-rc=0`
  so the reader can confirm the reviewer actually built the slice in its own
  worktree.** Pair this with the `--build-rc N` structured field below
  (#427b) for v2 artifacts.

Optional:
- `--skill-version` — version of the review skill used
- `--commit-range` — e.g. `abc123..def456`
- `--branch` / `--worktree` — included in the notification by `peer-pass send`
- `--build-rc N` — **#427b structured capture of the slice-worktree build
  exit code.** `0` is the only value that should accompany a `--verdict
  PASS` per Pattern 8. Bumps the artifact schema from v1 to v2; the field
  is in scope of the Ed25519 signature so tampering invalidates
  verification. Reviewers should also retain the textual
  `build-clean-IN-slice-worktree-rc=0` entry in `--criteria` for
  backward-readable evidence. **Per #427c, PASS without `--build-rc` is
  rejected (exit 124) unless `--no-build-rc` is also passed.**
- `--no-build-rc` — **#427c opt-out for legitimate doc-only / runbook /
  config-only slices** where no compilable target exists. Mutually
  exclusive with `--build-rc`. Recorded in the artifact's `notes`
  field as `no-build-rc:doc-only` for audit. Use sparingly: most
  slices DO have a build, even when the change feels small (e.g. a
  CLI flag wired into existing OCaml).
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

**Signing your own SHA after a fresh-slate subagent review.** If you ran
this skill on your own commit and the Step 1 subagent returned PASS,
`c2c peer-pass sign` will refuse by default (reviewer alias matches commit
author). This is sanctioned per `git-workflow.md` "Subagent-review as
peer-PASS" when no live swarm peer is available or the slice is mechanical
/ low-stakes. Re-run with `--allow-self --via-subagent <id-or-desc>` to
record the subagent path in the artifact's notes for audit:

```bash
c2c peer-pass sign <SHA> --verdict PASS \
  --criteria "build, tests, docs" --skill-version 1.0.0 \
  --allow-self --via-subagent "review-and-fix-task-<n>" \
  --notes "fresh-slate subagent review; no live peer available"
```

HIGH-severity slices (security, data-loss class, broker state, signing
crypto, install-guard paths) should still get a live peer if at all
possible — DM `swarm-lounge` first before falling back to subagent-only.

### Step 5: DM coordinator1

`c2c peer-pass send coordinator1 ...` handles the coordinator DM and signs the
artifact. Only send a manual `c2c send coordinator1 "peer-PASS by ..."` if you
used `peer-pass sign` directly or need custom wording.

Coordinator cherry-picks to master, runs `just install-all`, then decides
push timing.

## Guidance

- Prefer focused review findings over vague unease.
- Preserve scope discipline; do not turn a review into a redesign unless
  the spec itself is broken.
- An independent live peer is the canonical peer-PASS reviewer.
- A fresh-slate subagent (Step 1's Agent dispatch starting with no
  conversational history) is a sanctioned substitute when no live peer is
  available or the slice is mechanical / low-stakes — sign with
  `--allow-self --via-subagent <id>` so the path is auditable. See
  `git-workflow.md` "Subagent-review as peer-PASS".
- A bare same-session self-review (you reading your own diff with the slice
  conversation already loaded) is NOT a peer-PASS. The subagent-review
  path's value is the fresh-slate independence the Agent tool gives you.

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
