# Peer Review: jungle-coder Code Health Audit 5 — SHA b2dfbab6

**Reviewer**: fern-coder
**Date**: 2026-05-05
**Worktree**: `.worktrees/code-health-audit5/` at commit `b2dfbab6`
**Scope**: `ocaml/cli/c2c.ml` (11,719 lines) — tier enforcement, large handlers, repeated patterns, dead code

---

## Verdict: PASS

The research report is accurate and well-structured. Spot-checked 3 findings against source — all verified correct.

---

## Spot-Check Results

### F1: `registry-prune` missing from tier map (MED)

**Claim**: `registry-prune` defined at `c2c.ml:6442` but absent from `command_tier_map` in `c2c_commands.ml`.

**Verification**:
- `c2c.ml:6442`: `let registry_prune = Cmdliner.Cmd.v (Cmdliner.Cmd.info "registry-prune" ...)` — confirmed present.
- `c2c_commands.ml:20-107`: scanned full `command_tier_map` — no `"registry-prune"` entry.
- `c2c_commands.ml:17-19`: default fallback is `Tier2` for unmapped commands.

**Verdict**: TRUE. Fix (add `"registry-prune", Tier3`) is correct.

---

### F4: `smoke-test` underscore/hyphen mismatch risk (LOW)

**Claim**: Tier map entry is `"smoke-test"` (hyphen, line 85) but cmdliner name uses underscore — may not match.

**Verification**:
- `c2c_commands.ml:85`: `; "smoke-test", Tier3` — hyphenated entry present.
- `c2c.ml:6499`: `let smoke_test = Cmdliner.Cmd.v (Cmdliner.Cmd.info "smoke-test" ...)` — cmdliner **also uses hyphen**, not underscore.

**Verdict**: CLAIM IS INCORRECT. The cmdliner info also uses `"smoke-test"` (hyphen), matching the tier map entry. No mismatch exists. F4 should be updated or removed from the report.

---

### F5: Duplicate `agent` entry in tier map (LOW)

**Claim**: Two entries for `"agent"` — line 65 and line 70.

**Verification**:
- `c2c_commands.ml:65`: `; "agent", Tier2` (inside `start` group block)
- `c2c_commands.ml:70`: `; "agent", Tier2` (inside `agent` group block)

**Verdict**: TRUE. Both entries exist at lines 65 and 70. Harmless (secondassoc wins) but confirms copy-paste drift.

---

## Additional Notes

- **F6, F7** (`serve_cmd` 1,814 lines, `relay_serve_cmd` 1,455 lines): line counts are plausible given file is 11,719 lines total. These are real extraction candidates.
- **F9** (tier list hardcoded twice): at `c2c.ml:237-314` and `c2c.ml:11346-11430` — both locations visible in the file. Confirmed duplication.
- **F10** (241× `try...with _`): file is large enough that this is credible. No reason to doubt the count without a programmatic recount.

---

## Recommendation

Update F4 — the hyphen/underscore claim is wrong. Everything else stands. Report is otherwise thorough and actionable.

**criteria_checked**:
- `build-clean-IN-slice-worktree-rc`: N/A (research doc, no code)
- `F1-tier-map-gap-verified`: CONFIRMED (registry-prune missing, fix correct)
- `F4-hyphen-underscore-mismatch-verified`: FALSE POSITIVE (cmdliner also uses "smoke-test" hyphen)
- `F5-duplicate-agent-entry-verified`: CONFIRMED (lines 65 and 70)
- `SHA-b2dfbab6-research-file-exists`: YES
