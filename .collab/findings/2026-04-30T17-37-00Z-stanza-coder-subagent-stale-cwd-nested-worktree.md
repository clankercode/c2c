# Subagent stale-CWD creates nested worktrees

**UTC:** 2026-04-30T17:37:00Z
**Author:** stanza-coder
**Severity:** MEDIUM (recurrent — bit twice in one session, recovery requires `git worktree remove` + re-add but commits/branches survive)

## Symptom

Twice in the same session, a subagent dispatched with `git worktree
add .worktrees/<slice-name> ...` (relative path) created the worktree
**nested** under a sibling slice's worktree:

```
/home/xertrov/src/c2c/.worktrees/450-s0-helper-hoist/.worktrees/450-s05-post-broker-hoist/   # S0.5 — first hit
/home/xertrov/src/c2c/.worktrees/450-s05-post-broker-hoist/.worktrees/450-s1-memory-handlers/  # S1 — second hit
```

Branches (`slice/...`) and commits land correctly; only the
filesystem path is wrong. `git worktree list` reflects the actual
nested path; downstream `git worktree add` from a CWD inside
the nested tree compounds the problem.

## Discovery

Both times, caught by post-rebase / post-extract `git worktree list
| grep <slice-prefix>` showing the nested path. First time: I
chained `git worktree add` from main repo CWD and it worked — the
problem appeared on a *subsequent* slice. Second time: same.

## Root cause

**My parent shell's CWD gets pushed into the most recently used
worktree.** When I run `cd /home/xertrov/src/c2c/.worktrees/<slice>/
&& <stuff>` in a Bash tool call, my CWD updates inside the
persistent shell. Subsequent `git worktree add .worktrees/<new-slice>
...` calls — whether by me or a subagent — resolve the relative
`.worktrees/<new-slice>` path *relative to the current shell CWD*,
which is now inside the previous slice's worktree.

The `cd` directive in CLAUDE.md ("never use cd unless the User
explicitly requests it") is exactly designed to prevent this drift.
I violated it implicitly — the inline `cd <path> && <build>` form
chains a directory change into the persistent shell state.

Subagents inherit the parent's CWD. So if my parent shell drifted
into S0.5's worktree, a subagent told to "create a worktree at
.worktrees/450-s1-memory-handlers" creates it nested under S0.5,
not at the top level.

## Fix

**Two-tier mitigation.**

### Operator (me)
- **Always use absolute paths in Bash tool calls.** `cd /abs/path
  && <cmd>` is fine for the duration of one tool call but doesn't
  protect subsequent calls — the persistent shell's CWD now points
  at /abs/path. Prefer:
  ```sh
  cd /home/xertrov/src/c2c && <git worktree add ...>
  ```
  with the **main repo path** as a hard anchor before any worktree
  manipulation.
- **Verify before delegating.** Before dispatching a subagent that
  will run `git worktree add`, run `pwd && cat .git 2>/dev/null |
  head -1` from a Bash tool call. If `.git` shows `gitdir: ...
  /worktrees/...`, the parent shell is inside a worktree and any
  relative-path subagent worktree-add will nest. Anchor first.

### Subagent prompt
- **Pass absolute paths only.** Never tell a subagent to "cd to
  .worktrees/<slice>" — pass `/home/xertrov/src/c2c/.worktrees/<slice>/`
  in full, and require the subagent to verify with `pwd` before
  running `dune --root .` or any git-state command.
- **Forbid `git worktree add` from subagents.** Worktree creation
  is a coordination primitive; if a subagent thinks it needs a new
  worktree, that's a slice-design problem (it should be working in
  one already-created by the parent).

## Recovery (already proven this session twice)

When a nested worktree is detected:
1. `cd /home/xertrov/src/c2c` (absolute, from main repo).
2. Verify: `cat .git 2>/dev/null` should be silent (`.git` is a
   directory in the main repo, not a file with `gitdir:`).
3. `git worktree remove /<absolute-nested-path>` — `git` handles
   the metadata cleanup.
4. `git worktree add .worktrees/<slice-name> slice/<branch-name>`
   — re-adds at the correct top-level path. Branch + commits
   survive; only the checkout path moves.
5. `rmdir /home/xertrov/src/c2c/.worktrees/<parent-slice>/.worktrees`
   to clean the empty stub directory.
6. Verify: `git worktree list | grep <slice-prefix>` shows
   top-level paths only.

Build artifacts (`_build/`) inside the nested checkout are lost
on remove — re-running `dune build --root .` in the new location
rebuilds. ~30s cost.

## Counter-cases

- **Genuinely nested designs.** If a slice intentionally nests
  worktrees (none currently — but possible for a future "slice-
  inside-a-slice" pattern), the subagent prompt must say so
  explicitly and pass the full nested path. Default discipline
  is "all worktrees at top-level `.worktrees/`."

## Severity

MEDIUM. Recovery is safe and ~1min, but:
- It bit twice in a single session, so the trigger is clearly not
  rare.
- Subagent reports build/test rc=0 from the nested path, which is
  *correct for the work done* but masks the topology problem —
  parent has to actively check `git worktree list` to catch it.
- Future slices off the nested branch compound the nesting.

## Recommendation

Add as **Pattern 19** to
`.collab/runbooks/worktree-discipline-for-subagents.md`. Cairn
flagged this as Pattern-worthy at 2026-05-01T17:34Z when caught
on S1: *"subagent stale CWD is persistently a thing — worth a
Pattern entry if it bites again."*

## Cross-refs

- `.collab/runbooks/worktree-discipline-for-subagents.md` — host
  for Pattern 19.
- `CLAUDE.md` — "Subagents must NOT `cd` out of their assigned
  worktree (#373)" covers the inverse direction (subagent leaves
  its tree); this finding covers the parent leaking CWD *into* a
  subagent.
- Related: Pattern 12 (subagent DMs lie about authorship) — same
  inheritance class (subagents inherit parent's MCP session AND
  CWD). Pattern 19 is the CWD-inheritance footgun; Pattern 12 is
  the alias-inheritance footgun.
