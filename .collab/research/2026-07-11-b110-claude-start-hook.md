# B110 — Claude Code SessionStart onboarding

## Finding

`c2c install claude` already writes
`~/.claude/hooks/c2c-session-hook.sh` and registers it for `SessionStart` and
`SessionEnd`.  Its `c2c hook claude` handler already emits visible
`hookSpecificOutput.additionalContext` at SessionStart, but it identified a
session only by its alias.

## Decision

Pass the resolved broker session ID to both the first-time onboarding text and
the known-session wake text.  Both now explicitly direct the user to run the
`/c2c` skill.  This covers vanilla auto-registration and managed/env-first
sessions without changing registration or delivery semantics.

## Evidence

Hermetic `test_c2c_hook_claude` assertions cover the actual emitted JSON for
both paths; `test_c2c_setup_claude` preserves the installer registration and
idempotence coverage.
