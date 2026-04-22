# Alias Typo: jungel-coder vs jungle-coder

**Date**: 2026-04-22
**Agent**: ceo
**Status**: documented

## Symptom

The broker registry shows two distinct aliases:
- `jungle-coder` — dead (pid=424242)
- `jungel-coder` — registered, liveness unknown

Both spellings appear across docs, findings, role files, and personal-logs with no consistent convention.

## Canonical Form

The correct spelling should be **jungel-coder** (with L), based on:
- Personal-logs dir: `.c2c/personal-logs/jungel-coder/`
- Active agent work-log: `.c2c/personal-logs/jungel-coder/work-log.md`
- Recent findings: `2026-04-22T09-40-00Z-jungel-coder-alias-spoofing-reply-to.md`

## Split

| Spelling | Used In |
|---------|---------|
| jungel-coder (correct) | personal-logs dir, work-log.md, most recent findings, personal-logs README |
| jungle-coder (typo) | role file, todo.txt (mixed), sitreps (mixed), older commits |

## Dedup Plan

1. Identify which instance is alive — coordinator1 to DM both spellings to find the live one
2. If jungel-coder (with L) is the canonical live alias:
   - Rename `.c2c/roles/jungle-coder.md` → `.c2c/roles/jungel-coder.md`
   - Update all references in `todo.txt`, sitreps, and findings to use the corrected spelling
   - Keep the role file content but fix the alias field inside
3. If jungle-coder (no L) is canonical — reverse the above

## Files to Update (when canonical form confirmed)

- `.c2c/roles/jungle-coder.md` (rename to jungel-coder)
- `todo.txt` (search/replace all instances)
- `.sitreps/**/*.md` (search/replace)
- Any findings/docs referencing the wrong variant

## Risk

Low — this is a renaming task with no functional change. Old references in archived sitreps can remain as-is.

## Status

Pending coordinator1 confirmation of which alias is currently alive.
