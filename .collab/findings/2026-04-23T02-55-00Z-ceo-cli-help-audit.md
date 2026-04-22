# CLI Help-Text & Docstring Audit

**Date:** 2026-04-23
**Author:** CEO
**Severity:** BLOCKER (wrong command names), STALE (outdated references), NIT (polish)

**Status:** ✅ AUDIT COMPLETE — all items resolved (2026-04-23)

---

## BLOCKER — Wrong command names in `c2c --help`

### B1: `roles-compile` doesn't exist ✅ FIXED

**Location:** `c2c --help` lists `roles-compile` as a standalone command

**Reality:** The command is `c2c roles compile` — a subcommand of the `c2c roles` group.

**Impact:** An agent reading `c2c --help` and typing `c2c roles-compile` gets:
```
unknown command roles-compile. Must be one of agent, cc-plugin, ...
```

**Fix:** Updated the help text in `ocaml/cli/c2c.ml` to show `c2c roles compile` instead of `roles-compile`. Committed `420f423`.

---

### B2: `config-generation-client` doesn't exist ✅ FIXED

**Location:** `c2c --help` lists `config-generation-client` as a standalone command

**Reality:** The command is `c2c config generation-client` — a subcommand of the `c2c config` group.

**Impact:** An agent reading `c2c --help` and typing `c2c config-generation-client` gets:
```
unknown command config-generation-client. Must be one of agent, cc-plugin, ...
```

**Fix:** Updated the help text in `ocaml/cli/c2c.ml` to show `c2c config generation-client` instead of `config-generation-client`. Committed `420f423`.

---

## STALE — Outdated references

### S1: `cc-plugin` description mentions "PostToolUse hook" only ✅ FIXED

The `c2c cc-plugin` description says it's "(called by the PostToolUse hook and any Claude Code statefile emitters)". Updated to also explicitly mention PreCompact/PostCompact hooks. Committed `4a78b3d`.

### S2: `oc-plugin` description says `.opencode/plugins/c2c.ts` ✅ FIXED

The `c2c oc-plugin` description referenced `.opencode/plugins/c2c.ts` explicitly. Changed to generic "the OpenCode c2c plugin". Committed `4a78b3d`.

---

## NIT — Polish

### N1: `c2c doctor` help is minimal ✅ WON'T FIX

`c2c doctor --help` shows only generic options (--help, --version) with no command-specific flags documented. `doctor` genuinely has no flags — it just runs `scripts/c2c-doctor.sh`. No action needed.

### N2: `c2c cc-plugin` subcommand `write-statefile` has a typo-ish description ✅ FIXED

"Read a JSON state snapshot from stdin and write it atomically" — fixed to "Write a JSON state snapshot received on stdin atomically". Committed `57dda75`.

### N3: `c2c agent` help doesn't show `compile` as a subcommand ✅ RESOLVED

The `c2c agent` group doesn't include `compile` — it's under `c2c roles compile`. This is correct architecture (`agent` = role file CRUD, `roles compile` = compilation). B1/B2 fix removes the confusion that prompted this nit. No code change needed.

---

## CI Bonus: Drift Detection Script

```bash
#!/bin/bash
# Diff registered commands vs help text
HELP_COMMANDS=$(c2c --help 2>&1 | grep -E "^[a-z]" | grep -v "Tier" | tr ' ' '\n' | grep -v "^$")
REGISTERED=$(c2c commands 2>/dev/null | grep -v "Tier" | tr ' ' '\n' | grep -v "^$")
echo "In help but not registered:"
diff <(echo "$HELP_COMMANDS" | sort) <(echo "$REGISTERED" | sort) || true
```

---

## Summary

| # | Severity | Status | Commit |
|---|----------|--------|--------|
| B1 | BLOCKER | ✅ FIXED | `420f423` |
| B2 | BLOCKER | ✅ FIXED | `420f423` |
| S1 | STALE | ✅ FIXED | `4a78b3d` |
| S2 | STALE | ✅ FIXED | `4a78b3d` |
| N1 | NIT | ✅ WON'T FIX | — |
| N2 | NIT | ✅ FIXED | `57dda75` |
| N3 | NIT | ✅ RESOLVED | — |

**Audit complete.** All BLOCKERs and actionable items resolved. Commits: `420f423`, `4a78b3d`, `57dda75`.
