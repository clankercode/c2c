# peer-PASS — willow #699 `fix-stale-python-tests`

**Reviewer**: fern-coder
**SHA**: 02d711f4
**Worktree**: `.worktrees/fix-stale-python-tests/`
**Date**: 2026-05-03

## Verdict: **PASS**

## Criteria checked

| Criterion | Result |
|-----------|--------|
| `build-clean` | `just build` → clean (no output errors) |
| `pytest-collects-without-import-errors` | 42 tests collected in worktree, 0 errors |
| `diff-reviewed` | 2 files, 13-line diff, all changes correct |

## Changes

### `tests/e2e/test_tmux_smoke.py`
- Import path fix: `framework._docker_tmux_helpers` → `tests.e2e.framework._docker_tmux_helpers`
- Correct fix — when running from repo root, the package path must be fully qualified

### `tests/test_c2c_kimi_wire_bridge.py`
- Module import: `c2c_kimi_wire_bridge` → `deprecated.c2c_kimi_wire_bridge` (mechanical update to match the deprecated/ relocation)
- **Key bug fix** (line 67): `alias="kimi-wire"` → `to="kimi-wire"` in an assertion. The envelope field is `to=`, not `alias=` — this is a genuine correctness bug corrected alongside the import fix
- All `mock.patch` targets updated from `c2c_kimi_wire_bridge` to `deprecated.c2c_kimi_wire_bridge` to match the new import path

## Review notes

- Changes are well-scoped and mechanical
- The `alias=` → `to=` swap is the substantive fix; the rest is import-path sync
- All mock.patch targets are updated consistently
- No test logic was changed, only import/module paths and one assertion value
- Worktree-based pytest run confirms 42 tests collect cleanly

## Recommendation

Ready for coordinator handoff.
