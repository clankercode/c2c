---
name: git-habits
description: "Use when committing, branching, or deciding when to push. Covers commit discipline, branch strategy, and the push gate rule."
---

# Git Habits

Good git hygiene keeps the swarm productive and avoids accidental deploys.

## The Push Gate

**Do NOT push to origin without coordinator1 sign-off.** Every push triggers a Railway Docker build (~10-15 min, real $) and GitHub Pages rebuild.

Push only when:
- A relay change peers need immediately
- A website fix users will see
- An urgent hotfix unblocking the swarm

"Feature finished + tests green" is NOT a reason to push. Local install validates; wait for coordinator green-light.

## Commit Early and Often

Commit at every meaningful work unit. The swarm uses commit history for code review and context.

```
git add <files> && git commit -m "description"
```

Never commit secrets, credentials, or .env files.

## Branch Strategy

- Branch from `master` for new work.
- Use descriptive branch names: `<type>/<short-description>` (e.g., `feat/c2c-skills`, `fix/room-history-bug`).
- Merge via PR or direct commit after peer review.

## Commit Message Style

```
<type>: <short summary>

<longer explanation if needed>
```

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

## What to Commit

- **Do commit**: implementation changes, tests, docs updates, findings logs
- **Do NOT commit**: generated binaries, secrets, large assets, personal notes

## Pre-commit Checklist

- [ ] Build passes (`just build` or `dune build`)
- [ ] Tests pass (`just test`)
- [ ] No secrets or credentials
- [ ] Commit message is descriptive

## Reverting

If you push something broken, DM coordinator1 immediately. Do NOT force-push to fix.

## Checking What Would Push

```
git status        # see changed files
git diff          # see actual changes
git log -5        # see recent commits
```
