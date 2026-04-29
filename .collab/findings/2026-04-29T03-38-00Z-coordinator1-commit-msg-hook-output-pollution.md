---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-29T03:38:00Z
slice: git-hooks
related: scripts/git-hooks/pre-commit, cedar's `a58c25b8`
severity: LOW
status: OPEN
---

# git pre-commit hook output leaks into commit message body

## Symptom

Cedar's `a58c25b8` (#427 Pattern 7 doc) shipped with a commit message
containing literal hook stdout in the body:

```
docs(#427): add Pattern 7 — review-and-fix pre-flight must use fresh build

Adds the 'build in slice worktree' discipline as Pattern 7:
- Rule: always installed: /home/xertrov/src/c2c/.git/hooks/pre-commit → scripts/git-hooks/pre-commit
installed: /home/xertrov/src/c2c/.git/hooks/pre-push → scripts/git-hooks/pre-push before build verification
- Verification step: compare 0.8.0 aa1d04d8 2026-04-28T17:33:52Z SHA against worktree HEAD
- Skill template note pointing to review-and-fix SKILL.md pre-flight update

Co-authored-by: cedar-coder <cedar-coder@c2c.im>
```

The "Rule: always installed: ..." and the embedded `0.8.0 aa1d04d8 ...`
version stamp look like `scripts/git-hooks/install` echo output OR
`c2c doctor` snippet text that got captured into the agent's
intended commit body via shell substitution / heredoc gone wrong.

## Diagnosis

Likely path: cedar composed the commit message via a shell heredoc
that interpolated a command whose stdout was hook-installation
output. OR cedar piped `c2c doctor` output into a bash substitution
inside the commit message and only got the relay-line back. Hard to
tell without reflog of cedar's exact invocation.

The DIFF content is fine — only 46 lines added to the runbook, all
proper Pattern 7 doc.

## Severity

LOW — message is funky but the patch is correct. Doesn't block
anything; future archaeologists will be confused.

## Proposed action

1. Document this as a class for cedar (and others using
   shell-heredoc commit messages): pre-render the body to a file,
   read it back, never let `$(...)` substitutions run inside the
   heredoc.
2. Optional: cedar (or anyone) could `git commit --amend` to clean
   up — but per swarm convention we don't amend after-the-fact, so
   live with it.
3. A followup git-hooks pre-commit lint could refuse messages
   containing pathlike strings like `/home/xertrov/...` but that's
   probably overkill.

No action required — filing for next-agent visibility.
