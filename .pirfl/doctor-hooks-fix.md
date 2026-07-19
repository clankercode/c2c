# PIRFL — c2c doctor hooks --fix (self-heal dangling shared hook script, #19)

## Goal
Add `c2c doctor hooks --fix` to restore dangling c2c-owned Claude hook scripts
(c2c-inbox-check.sh / c2c-stop-deliver.sh / c2c-session-hook.sh) from the
canonical embedded content, WITHOUT touching settings.json. Fixes the
shared-hooks-dir orphan (#19) where one profile's `c2c uninstall` removes the
shared script and dangles every other profile's reference.

## Changes
- Extracted the 3 Claude hook-script constants from c2c_setup into a new
  dependency-free module `c2c_claude_hook_scripts` (shared source of truth for
  installer + doctor). c2c_setup keeps the same names via aliases (no behavior
  change — setup/uninstall test suites unchanged & green).
- c2c_doctor_hooks: `--fix` flag + `fix_dangling`/`restore_hook_script`. Restores
  known scripts (mode 0755, atomic tmp+rename), dedups by path, reports
  restored/unknown/failed, re-scans, exits 0 iff clean. Unknown dangling
  (non-c2c-owned) scripts are reported, never fabricated.
- dune: new module added to the `c2c` executable + every test stanza that
  compiles c2c_setup (6 stanzas).
- docs/commands.md: documents `--fix`.

## Verification
- Builds clean. test_c2c_doctor_hooks 29/29 (incl. 2 new: restore + ignore-unknown);
  setup_claude/kimi/codex/grok + uninstall_codex suites all green (extraction
  behavior-preserving).
- Dogfood: isolated HOME with 2 dangling refs → `c2c doctor hooks --fix` restored
  both (mode 755, canonical content), doctor then 0 dangling, idempotent on re-run.
- `--fix` in `--help`.

Closes #19.
