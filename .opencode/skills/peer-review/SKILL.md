---
name: peer-review
description: "Use when asked to peer-review a commit, branch, or PR. Covers what to look for, how to give feedback, and the PASS/FAIL signal."
---

# Peer Review

Peer review is mandatory before coordinator review. It catches trivial build breaks and obvious misses early.

## Before You Start

1. Verify the SHA you are reviewing is committed (not just staged).
2. Read the original task description / acceptance criteria.
3. Understand the scope — do not let a review balloon into a refactor.

## What to Check

### Correctness
- Does the implementation satisfy the acceptance criteria?
- Are there bugs, edge cases, or race conditions?
- Are error paths handled properly?

### Integration
- Is the code hooked up correctly to existing code?
- Are there obvious missing pieces?
- Does it follow existing patterns and conventions?

### Code Quality
- Is the code clean and readable?
- Is there excessive duplication?
- Are there obvious refactor opportunities that would cost < 10 lines?

### Tests
- Are there tests for new functionality?
- Do tests actually test what they claim?
- Are edge cases covered?

### Scope
- Does the change match the original brief?
- Were there any feature creep or YAGNI violations?

## Giving Feedback

Be specific and actionable. Format:

```
## Finding: <short title>

<description of the issue>

<suggested fix or approach>
```

Avoid vague feedback like "this looks wrong." Be precise about what is wrong and why.

## PASS / FAIL Signal

- **PASS**: No meaningful issues remain. Ready for coordinator review.
- **FAIL**: One or more meaningful issues found. Fix and re-review.

"Meaningful" = would cause a bug, build break, or user-visible regression. Style nits and preferences are not FAIL reasons — note them separately.

## Process

1. Run `review-and-fix` skill on the commit.
2. If PASS: DM coordinator1 with "peer-PASS by <your-alias>, SHA=<abc1234>"
3. If FAIL: DM the author with specific findings and request fixes.
4. After fixes, re-review until PASS.

## Notes

- Do not use peer review to redesign the system.
- Keep scope discipline — review what was asked, not what you wish had been asked.
- When in doubt, PASS and let coordinator catch broader issues.
