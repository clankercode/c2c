# Cross-worktree storage bug — #173

**Timestamp**: 2026-04-25T09:45:00Z
**Severity**: High (functional — stickers landed per-worktree instead of shared)

## Symptom
When running `c2c sticker list` (or any sticker command) from a worktree other than the main worktree, it could not find `registry.json` because it was looking at `<worktree-root>/.c2c/stickers/registry.json` instead of `<main-worktree>/.c2c/stickers/registry.json`.

## Root Cause
`sticker_dir()` used `Git_helpers.git_repo_toplevel()` which returns the worktree-specific toplevel path. Each worktree has its own `.c2c/stickers/` but the stickers and registry should be shared across all worktrees via the git common dir.

## Discovery
Testing `c2c sticker list` in `c2c-stickers-work` worktree returned empty (no stickers) even though `registry.json` existed in that worktree's `.c2c/stickers/`. The real registry was in the main worktree.

## Fix
Added `git_common_dir_parent()` to `Git_helpers.ml`:
```ocaml
let git_common_dir_parent () =
  match git_common_dir () with
  | Some d -> Some (Filename.dirname d)
  | None -> None
```

Changed `sticker_dir()` in `c2c_stickers.ml` from:
```ocaml
match Git_helpers.git_repo_toplevel () with
| Some top -> top // ".c2c" // "stickers"
```
to:
```ocaml
match Git_helpers.git_common_dir_parent () with
| Some parent -> parent // ".c2c" // "stickers"
```

## Verification
- `git -C /home/xertrov/src/c2c-stickers-work rev-parse --git-common-dir` returns `/home/xertrov/src/c2c/.git`
- `git_common_dir_parent()` returns `/home/xertrov/src/c2c`
- `sticker_dir()` now returns `/home/xertrov/src/c2c/.c2c/stickers/`
- `c2c sticker list` works from main worktree, shows all 9 stickers
- Dogfood sticker (sent from jungle-coder to coordinator1) stored at correct shared path

## Related
This same pattern will affect `#168` cold-boot hook when it writes to `.c2c/`. galaxy-coder was notified.
