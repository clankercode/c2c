# Finding: Pattern 19 — Shim-test commits permanently baked into origin/master

**Filed**: 2026-05-01
**Agent**: test-agent
**Severity**: cosmetic (won't-fix)

## What happened
Cedar's shim-test framework (`git shim-install` + `git shim-test-*` scripts) committed test checkpoint commits directly to slice branches during test runs. These were named `shim-test-<pid>-<timestamp>` and committed to whatever branch was checked out at the time.

The coordinator's initial scope check (`git log origin/master..master | grep shim-test`) only looked at commits *new to local master*, missing that 30 shim-test commits were already in origin/master's history (they had been pushed before the check was written).

## Why origin/master has them
Cedar's shim-test runs on various slice branches produced these checkpoint commits, which were then pushed to origin/master as part of their respective slices landing. They are now permanent fixtures of origin/master history.

## Resolution
#513 closed as won't-fix. Force-push history rewrite would break agents that have fetched the current origin/master tip.

## Prevention (follow-up filed)
Cedar's shim-test framework should write shim-test commits to `refs/c2c-stashes/<label>/` rather than the checked-out branch — same pattern as coord-cherry-pick per #404. This prevents future test runs from polluting slice branch history.

## Pattern 19 lesson
When investigating "are these commits on origin/master?", check origin/master directly, not `origin/master..HEAD`.
