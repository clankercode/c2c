# OpenCode/Kimi E2E Tests Broken: OCaml `c2c install` Missing Subcommand

**Date**: 2026-04-23
**Author**: Lyra-Quill
**Status**: blocked — pre-existing issue in current OCaml build

## Symptom

OpenCode E2E (`test_c2c_opencode_e2e.py`), Kimi E2E (`test_c2c_kimi_e2e.py`), and cross-client (`test_c2c_cross_client_e2e.py`) all fail:
- OpenCode: `c2c start opencode` prompts for `Run it now? [Y/n]` waiting for interactive input
- Kimi: `c2c start kimi` blocks at "What is this agent's role?" prompt

## Root Cause

The OCaml `c2c` binary was recently rebuilt (at 05:28 today). The new build changed behavior:

1. **`c2c start opencode`** now requires `.opencode/opencode.json` to exist before starting
2. When the file is missing, it prompts: `Run it now? [Y/n]` waiting for interactive input
3. The OCaml source (`c2c_start.ml` line 1389) references `c2c install opencode` to create this file
4. **But `c2c install` doesn't exist as a subcommand** in the OCaml binary — `c2c --help` shows no `install` command

The OCaml `c2c` binary is missing the `install` subcommand that the code references.

For Kimi: the role prompt blocks even with `--auto` flag (role file must be pre-seeded in workdir before `c2c start` runs).

## Timeline

- 05:18 — Kimi E2E test passed (1.81s)
- 05:28 — OCaml binary was rebuilt (from `just install-all` or similar)
- After 05:28 — All OpenCode/Kimi E2E tests start failing

## Impact

No one can run `c2c start opencode` without first manually creating `.opencode/opencode.json` in the workdir.

## Resolution

This is NOT a test framework bug — it's a broken OCaml build. The fix requires either:
1. Implementing the `install` subcommand in the OCaml binary
2. Reverting to an older OCaml binary that had `c2c install`
3. Running `c2c install opencode` via the Python CLI (deprecated but still exists)

## Test Files Affected

- `tests/test_c2c_opencode_e2e.py` — blocked
- `tests/test_c2c_kimi_e2e.py` — blocked
- `tests/test_c2c_cross_client_e2e.py` — blocked (written, not committed)

## References

- `ocaml/cli/c2c.ml` — `c2c_start.ml` line 1389 references `c2c install opencode`
- `ocaml/c2c_start.ml` — handles opencode.json check and install prompt
