---
name: review-and-fix
description: "Use when a task needs a disciplined review/fix loop: first run a thorough review against acceptance criteria, then fix any issues found, then rereview until it passes or exits on deep/spec-blocked problems. Best for validating work before handing off, merging, or marking a slice done. Ported from ~/.claude/skills/review-and-fix."
metadata:
  short-description: Disciplined review/fix loop before hand-off
---

# Review And Fix

Use this skill to coordinate a strict review/remediation loop for completed
work, especially delegated or background-agent output that should not be
trusted blindly. Pair with c2c's commit-before/commit-after discipline: the
loop is only meaningful as a git-visible sequence.

## When to use

- After finishing a meaningful work unit, before returning or handing off.
- Before marking a slice/todo item done when the change lands in shared
  code paths (broker, plugins, renderers, CLI surface).
- When reviewing delegated or background-agent output.

## Prerequisite: commit first

The reviewer needs a stable SHA to target. Commit your work before invoking
this skill. If the review returns `FAIL`, fix in a NEW commit (do not
`--amend`) and re-invoke.

## Workflow

### Step 1: Review

Dispatch a review pass on the described work. In Codex, this means either
spawning a sub-session with the CLI (`codex exec ...`) or running the
review inline with a clean, focused prompt. If subagent dispatch is
unavailable in your harness, run the review inline with a tight scope.

Your review prompt should be detailed, professional, and direct. If you
know of relevant files, include them in the prompt.

Instruct the reviewer to:
- Evaluate the implementation against the work description, acceptance
  criteria, and surrounding code.
- Identify bugs in the implementation.
- Ensure the code is neat, well integrated, and consistent with existing
  practices.
- Ensure there is no excessive duplication or obvious refactor
  opportunity required for cleanliness.
- Ensure the implementation is intuitively complete: hooked up properly,
  with no obvious missing pieces.
- Return `PASS` or `FAIL`. `FAIL` if any single meaningful issue remains.
- Do not delegate further.

### Step 2: Address issues

If the review returns `FAIL`, dispatch a fixing pass (or do it inline in
solo mode). Instruct the fixer to satisfy both:
- the review findings
- the original work description and acceptance criteria

Do not delegate further from the fixing pass.

### Step 3: Repeat

If any issues were fixed, commit the fix (new commit — never `--amend`)
and return to Step 1 for a rereview against the new SHA.

Continue until:
- the work passes, or
- the problem is deeply blocked, contradictory, or requires user-level
  design decisions.

## Guidance

- Prefer focused review findings over vague unease.
- Preserve scope discipline; do not turn a review into a redesign unless
  the spec itself is broken.
- The final fix must be committed before marking the work done — the
  review-and-fix loop is only meaningful as a git-visible sequence.
- In Codex solo mode (no subagent dispatch), run review and fix inline
  with clear scope boundaries; the discipline is the same.
