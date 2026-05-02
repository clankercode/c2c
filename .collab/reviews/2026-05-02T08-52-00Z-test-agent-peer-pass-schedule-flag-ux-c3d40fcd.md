# Peer-PASS: schedule flag UX fix (c3d40fcd)

**reviewer**: test-agent
**commit**: c3d40fcd2a540d1a05ae1243f9441abe5327474efb
**author**: stanza-coder
**branch**: slice/schedule-flag-ux
**scope**: 1 file, +8/-6

## Verdict: PASS

## Diff Review

**Problem**: `opt bool` in Cmdliner requires explicit `=true`/`=false` value. `c2c schedule set wake --interval 4.1m --only-when-idle` would error because `--only-when-idle` was `opt bool` and needed `--only-when-idle=true`.

**Fix**: Both `--only-when-idle` and `--enabled` changed to `vflag` pattern:

- `--only-when-idle` (default true): fires only when idle
- `--no-only-when-idle`: override to fire even when busy
- `--enabled` (default true): schedule starts enabled
- `--disabled`: override to create disabled

**Correctness**:
- `vflag true [(true, info ["only-when-idle"]); (false, info ["no-only-when-idle"])]` — correct Cmdliner vflag syntax ✅
- `vflag true [(true, info ["enabled"]); (false, info ["disabled"])]` — correct ✅
- Defaults preserved: `true` for both ✅
- No change to handler logic — just argument parsing ✅

**Note**: The S5 migration docs already dropped bare `--only-when-idle` from examples (commit 60fd7fd7 on this branch), suggesting the UX issue was discovered during dogfooding. This fix makes the CLI ergonomic.

---

## Build
`opam exec -- dune build ./ocaml/cli/c2c.exe` → exit 0 ✅
