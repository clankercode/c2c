# test-agent prune-older-than stale-binary finding

## Date: 2026-04-24T10:53:00Z

## Symptom
`c2c instances --prune-older-than 7` returned "unknown option" despite source code containing the flag.

## Root Cause
Binary at `~/.local/bin/c2c` was stale — built Apr 24 20:49 but source commit 101f609 ("prune stale stopped instances") was already in HEAD at `3a732aa`.

## Resolution
Ran `just install-all` to rebuild and install. Flag now works correctly.

## Lesson
When a flag exists in source but "unknown option" appears at runtime: binary is stale, not source broken. Always rebuild before investigating further.
