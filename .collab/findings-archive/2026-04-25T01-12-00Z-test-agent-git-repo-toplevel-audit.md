# Audit: git_repo_toplevel vs git_common_dir_parent

## Date: 2026-04-25
## Finder: test-agent

## Summary
Post-#173 fix (stickers: `git_common_dir_parent`), coordinator noted `git_repo_toplevel` should
be `git_common_dir_parent` in other places too. Audited all 10 usages.

## Key Distinction
- `git_repo_toplevel` → returns the **worktree/clone root** (where you `cd`'d to)
- `git_common_dir_parent` → returns **parent of .git** (shared across all worktrees)
- In worktrees, `.git` is a FILE pointing to the actual gitdir — `git_repo_toplevel`
  returns the worktree path, NOT the main repo path

## Usages Analyzed

| Location | Function | Should be `git_common_dir_parent`? | Verdict |
|----------|----------|-----------------------------------|---------|
| c2c_stickers.ml:9 | `sticker_dir ()` | YES — stickers must live in shared storage | ✓ Already fixed |
| c2c_mcp.ml:4213 | `skills_dir ()` | YES — skills are per-worktree (worktree has own `.opencode/`) | ⚠️ See below |
| c2c_worktree.ml:26 | `worktrees_root ()` | YES — worktree list must be in main repo, not per-worktree | ❌ BUG |
| c2c_setup.ml:1247 | `do_install_git_hook` | NO — hook source is per-worktree (`.c2c/hooks/`), hook dest is common | ✓ Correct |
| c2c.ml:49,50,68 | local `git_repo_toplevel` wrapper | NO — these are for repo-root-relative paths within a single repo clone | ✓ Correct |
| c2c.ml:5013 | `check-rebase-base` | NO — checks if THIS clone/worktree is based on origin/master | ✓ Correct |
| c2c.ml:5035 | `doctor` command | NO — runs `scripts/c2c-doctor.sh` from the repo root | ✓ Correct |
| c2c.ml:8303 | (unknown usage) | TBD — need more context | Unclear |

## Bugs Found

### 1. c2c_worktree.ml:26 — `worktrees_root ()` BUG
```ocaml
let worktrees_root () =
  match Git_helpers.git_repo_toplevel () with
  | Some repo_root -> repo_root // ".c2c" // "worktrees"
  | None -> failwith "not in a git repository"
```
**Problem**: If called from a worktree, `git_repo_toplevel` returns the worktree root, not the main repo.
This means `c2c worktree add` would create `<worktree>/.c2c/worktrees/<alias>` instead of
`<main_repo>/.c2c/worktrees/<alias>`.

**Fix**: Change to `git_common_dir_parent`:
```ocaml
let worktrees_root () =
  match Git_helpers.git_common_dir_parent () with
  | Some parent -> parent // ".c2c" // "worktrees"
  | None -> failwith "not in a git repository"
```

### 2. c2c_mcp.ml:4213 — `skills_dir ()` UNCERTAIN
**Current**: `git_repo_toplevel ()` + fallback `Sys.getcwd ()`
**Coordinator said** this was "further upgraded to `git_common_dir_parent` post-merge" — but the
code I'm reading still shows `git_repo_toplevel`. Either:
- (a) The upgrade hasn't landed in this checkout yet, OR
- (b) `git_repo_toplevel` is actually correct for skills because skills are per-worktree

**Analysis**: Skills live at `<worktree>/.opencode/skills/`. Each worktree has its own `.opencode/`.
So `git_repo_toplevel` IS correct for `skills_dir` — skills are per-worktree, not shared.
The coordinator's comment may have been referring to `git_common_dir` (not `git_common_dir_parent`).

**Recommendation**: Confirm with coordinator whether `skills_dir ()` is correct as-is or needs changing.

## Severity
- c2c_worktree.ml BUG: **HIGH** — per-agent worktree isolation (#165) is broken if used from a worktree
- c2c_mcp.ml: **MEDIUM** — needs confirmation from coordinator

## Status
- Filed: 2026-04-25T01-12-00Z
- `c2c_worktree.ml` fix: NOT YET COMMITTED (needs new commit)
- `c2c_mcp.ml`: PENDING COORDINATOR CONFIRMATION
