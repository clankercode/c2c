# Roles/docs accuracy review findings (#756)

## Finding 1: Deprecated `c2c_sitrep.py` in coordinator roles

**Files**: `.c2c/roles/coordinator1.md:42`, `.c2c/roles/builtins/Cairn-Vigil.md:49`

**Problem**: Both coordinator roles reference `python3 c2c_sitrep.py` as the sitrep scaffolding tool. The sitrep script pattern is deprecated in favor of native scheduling and file creation.

**Text**: `Scaffold with \`python3 c2c_sitrep.py\``

**Severity**: MEDIUM — coordinator productivity, not user-facing.

**Fix**: Update to reference the sitrep protocol at `.sitreps/PROTOCOL.md` and use `c2c schedule set` native scheduling instead of the Python script.

---

## Finding 2: Deprecated `c2c_deliver_inbox.py` in coder roles

**Files**: `.c2c/roles/slate-coder.md:72`, `.c2c/roles/stanza-coder.md:26`

**Problem**: Both coders reference "fixing a `c2c_deliver_inbox.py` regression" as an example task. The Python deliver inbox script is deprecated — the OCaml `c2c-deliver-inbox` binary is the canonical implementation.

**Text**: `fixing a \`c2c_deliver_inbox.py\` regression, or adding a \`scripts/\` utility`

**Severity**: MEDIUM — misleading for new coders; implies the Python script is still canonical.

**Fix**: Change to reference OCaml inbox delivery: "fixing a regression in `c2c-deliver-inbox` or the inbox hook" or similar.

---

## Finding 3: Cross-role inconsistency — `restart-self` deprecation

**Files**: `.c2c/roles/birch-coder.md:82-83`, `.c2c/roles/cedar-coder.md:82-83`, `.c2c/roles/willow-coder.md:90-91`

**Problem**: Three coder roles correctly note that `restart-self` is deprecated and `c2c restart <name>` is preferred. However, `.c2c/roles/slate-coder.md:164` still recommends `./restart-self` as the canonical way to pick up a new broker binary.

**Text (slate-coder.md)**: `\`./restart-self\` — pick up a new broker binary in your own session after install.`

**Severity**: MEDIUM — inconsistent across roles; `c2c restart <name>` is the established canonical form.

**Fix**: In slate-coder.md, change `./restart-self` to `\`c2c restart <name>\``.

---

## Finding 4: Cross-role inconsistency — "First 5 turns" orientation uses different tool types

**Files**: `.c2c/roles/slate-coder.md:26-43` vs `.c2c/roles/birch-coder.md:24-34`, `.c2c/roles/cedar-coder.md:24-34`, `.c2c/roles/willow-coder.md:24-34`

**Problem**: slate-coder uses CLI commands (`c2c whoami`, `c2c list`) for the First 5 Turns orientation. birch/cedar/willow coders use MCP tool names (`mcp__c2c__whoami`, `mcp__c2c__list`).

Both work — the CLI and MCP surfaces expose equivalent functionality — but the inconsistency is confusing for agents rotating across roles or reading multiple role files for context.

**Severity**: LOW — both patterns are valid; no broken functionality.

**Fix**: Decide on a canonical pattern (CLI is simpler for orientation) and standardize all coder role files.

---

## Finding 5: AGENTS.md Group Goal doesn't mention Kimi or Gemini

**File**: `AGENTS.md:41`

**Problem**: Group Goal "Reach" section says "Codex, Claude Code, and OpenCode as first-class peers" — omitting Kimi (fully implemented, #406) and Gemini (fully implemented, this session's E2E work). The north star should enumerate all four clients.

**Severity**: MEDIUM — north star is the authoritative reference; omitting working clients understates reach.

**Fix**: Update to "Codex, Claude Code, OpenCode, Kimi, and Gemini as first-class peers."

---

## Finding 6: AGENTS.md Group Goal delivery surfaces description partially outdated

**File**: `AGENTS.md:32-40`

**Problem**: The delivery surfaces section describes "MCP: auto-delivery... polling-based via `poll_inbox`" as if that's the only mode. Native scheduling (`c2c schedule set`) and the deliver-watch mechanism are not mentioned, even though they're load-bearing parts of the current system (S1-S5 of native scheduling shipped, deliver-watch for codex/opencode/kimi).

**Severity**: MEDIUM — north star understates current capabilities.

**Fix**: Update the delivery surfaces paragraph to mention native scheduling and deliver-watch alongside the MCP polling path.

---

## Summary table

| # | File | Line | Issue | Severity |
|---|------|-------|-------|----------|
| 1 | coordinator1.md | 42 | `c2c_sitrep.py` deprecated | MEDIUM |
| 2 | Cairn-Vigil.md | 49 | `c2c_sitrep.py` deprecated | MEDIUM |
| 3 | slate-coder.md | 72 | `c2c_deliver_inbox.py` deprecated | MEDIUM |
| 4 | stanza-coder.md | 26 | `c2c_deliver_inbox.py` deprecated | MEDIUM |
| 5 | slate-coder.md | 164 | `restart-self` vs `c2c restart` inconsistency | MEDIUM |
| 6 | birch/cedar/willow-coder.md | various | First 5 turns tool-type inconsistency | LOW |
| 7 | AGENTS.md | 41 | Group Goal omits Kimi + Gemini | MEDIUM |
| 8 | AGENTS.md | 32-40 | Delivery surfaces incomplete (no native scheduling) | MEDIUM |

**Total: 8 issues across 7 files.**
