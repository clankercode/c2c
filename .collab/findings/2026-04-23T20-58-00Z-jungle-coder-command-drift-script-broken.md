# findings: c2c-command-drift-sh-broken

**Date**: 2026-04-23T20-58-00Z
**Alias**: jungle-coder
**Severity**: low (new script, unused in CI)

## Symptom

`bash scripts/c2c-command-drift.sh` exits 1 with no output. No command drift detected — but also no actual detection happening.

## Root Cause (two bugs)

### Bug 1: TIER2_COMMANDS extraction is broken

The script uses:
```bash
TIER2_COMMANDS=$(echo "$HELP_TEXT" | awk '/== TIER 2: LIFECYCLE/,/== TIER 3:/' | grep -oE '`[a-z][-a-z0-9_]+`' | ...)
```

Two problems:
- The `c2c --help` output uses **ANSI bold markers** (`[1m...[22m`), not backticks. The grep for backtick-quoted names finds nothing.
- The AWK range end pattern `/== TIER 3:/` has **no match** in the actual help text (there is no `== TIER 3:` line), so the range spans everything after TIER 2 — but since the grep finds no backticks, `TIER2_COMMANDS` ends up empty.

### Bug 2: REGISTERED extraction is wrong

```bash
REGISTERED=$(c2c commands 2>/dev/null | grep -v "^#" | tr ' ' '\n' | grep -v "^$" | sort -u)
```

`c2c commands` outputs lines like:
```
  start stop restart —— manage c2c instances
```

Splitting on ALL spaces produces a mix of command names AND description words (e.g. `Manage`, `canonical`, `role`, `files`). The `sort -u` deduplicates but the list is garbage.

A correct extraction would be: `c2c commands | awk 'NF && !/^#/ {print $1}' | grep '^[a-z]'`.

## Status

- Not yet committed fix (pending coordination — another agent may own this)
- Logged for awareness; not actively working on fix
