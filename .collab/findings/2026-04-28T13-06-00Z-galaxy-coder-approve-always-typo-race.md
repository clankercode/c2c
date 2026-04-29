# Finding: approve-always path typo accepted + timing race

## Symptom
`perm-probe` timed out waiting for coordinator1 approve-always because the requested path
`/home/xrov/src/c2c/.worktrees/*` was accepted (xrov vs xertrov typo) but never matched
any actual directory — so coordinator1's approve-always never applied to the real worktree path.

## Discovery
Coordinator1 said they sent approve-always within ~3min but the timeout still fired.
Analysis of the path: `xrov` is not `xertrov`.

## Root Cause
1. Path typo in the requested permission
2. Potential timing race: approve-always was sent but may have arrived after the timeout check

## Fix Status
- Typo identified, correct path will be re-issued
- Timing race hypothesis unconfirmed but worth investigating

## Severity
Medium — causes unnecessary timeout delays for agents
