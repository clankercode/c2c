# Jungel-coder vs Jungle-coder Naming Inconsistency

**Date**: 2026-04-22
**Agent**: ceo
**Status**: documented

## Symptom

The broker registry shows two distinct aliases:
- `jungle-coder` — dead (pid=424242)
- `jungel-coder` — registered, unknown liveness

Both appear in various docs, files, and findings with inconsistent spelling:
- `.c2c/personal-logs/jungel-coder/` (dir name uses "jungel")
- `todo.txt` references: "jungel-coder" and "jungle-coder" both appear
- Findings: `2026-04-22T09-40-00Z-jungel-coder-alias-spoofing-reply-to.md`
- Role file: `.c2c/roles/jungle-coder.md` (note: "jungle" no L)
- Multiple sitreps reference both variants interchangeably

## Root Cause

The inconsistency originated early in the project's life. The actual registered alias in the broker for the active agent appears to be `jungel-coder` (with L) based on:
- Personal-logs dir: `jungel-coder/`
- Recent findings: `jungel-coder-*.md`
- Active agent work-log: `jungel-coder/work-log.md`

The "jungle-coder" (no L) variant appears to be a typo that got replicated.

## Functional Impact

1. **DM routing**: `c2c send jungle-coder` fails (dead), `c2c send jungel-coder` would route to the live agent if they were registered
2. **Confusion**: When coordinating with the agent, unclear which spelling to use
3. **Registry clutter**: Two separate alias entries that should be one

## Autofix可行性

**No autofix possible** for existing data because:
- The broker registry correctly treats these as separate aliases (case-sensitive, different strings)
- Renaming would require either: (a) agent re-registering with corrected name, or (b) manual registry surgery
- Historical docs/findings would still reference the wrong variant

**Preventive fix**: Add alias validation lint to warn if a chosen alias differs by only one character from an existing registered alias (Levenshtein distance <= 2). This is a low-priority UX enhancement.

## Recommendation

1. **Low priority**: Log as a known alias confusion point for human operators
2. **Don't fix retroactively**: Too much churn for no functional gain
3. **Going forward**: The correct spelling is `jungel-coder` (with L, based on the personal-logs dir and active agent identity). Document this in a team convention doc if not already.

## Files Affected

- `.c2c/personal-logs/jungel-coder/` — correct (with L)
- `.c2c/roles/jungle-coder.md` — typo (no L)
- `todo.txt` — mixed
- Multiple `.collab/findings/*jungel*.md` files
- Multiple `.sitreps/**/*.md` files
- `c2c_sitrep.py` — references `jungle-coder` in example
