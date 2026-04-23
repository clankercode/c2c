---
name: review-and-fix
description: "Use when a task needs a disciplined review/fix loop: first run a thorough review against acceptance criteria, then fix any issues found, then rereview until it passes or exits on deep/spec-blocked problems. Best for validating delegated work before merge or landing."
---

# Review And Fix

Use this skill to coordinate a strict review/remediation loop for completed work,
especially delegated or background-agent output that should not be trusted
blindly.

## Workflow

### Step 1: Review

Launch a subagent (using the Agent tool) to review the work described to you.
Your prompt for the subagent should be detailed, professional, and direct.
If you know of relevant files, include them in the prompt.

Instruct the reviewer to:
- Evaluate the implementation against the work description, acceptance criteria, and surrounding code.
- Identify bugs in the implementation.
- Ensure the code is neat, well integrated, and consistent with existing practices.
- Ensure there is no excessive duplication or obvious refactor opportunity required for cleanliness.
- Ensure the implementation is intuitively complete: hooked up properly, with no obvious missing pieces.
- Return `PASS` or `FAIL`. `FAIL` if any single meaningful issue remains.
- Do not delegate further to other subagents.

### Step 2: Address Issues

If the review returns `FAIL`, launch a subagent (using the Agent tool) to address the issues.

Instruct the fixing subagent to satisfy both:
- the review findings
- the original work description and acceptance criteria

Also instruct the fixing subagent:
- Do not delegate further to other subagents.

### Step 3: Repeat

If any issues were fixed, return to Step 1 and rereview.

Continue until:
- the work passes, or
- the problem is deeply blocked, contradictory, or requires user-level design decisions

## Guidance

- Prefer focused review findings over vague unease.
- Preserve scope discipline; do not turn a review into a redesign unless the spec itself is broken.
- Use this skill when delegated work needs a rigorous acceptance loop before merge or landing.
