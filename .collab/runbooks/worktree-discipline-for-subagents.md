# Worktree discipline — for subagents (and humans) in a shared `.git`

**Audience**: any agent (subagent, peer, human) implementing a slice in
the c2c repo's shared-`.git` multi-worktree layout.

**Why this exists**: 2026-04-28's high-parallel burn surfaced four
distinct failure patterns where shared-tree state leaked between
slices. Each one cost time-to-recover; together they're the same
class. This runbook unifies the rules.

---

## TL;DR — five rules

1. **Stay in your worktree**. Never `cd` out mid-slice; use
   `--root <abs-worktree-path>` on `dune` / `opam` invocations.
2. **Never `git stash` mid-slice**. Commit-WIP instead — even a
   `WIP` commit on the slice branch you'll squash later is safer
   than a stash that captures peer work.
3. **Pass full absolute worktree-prefixed paths** to Edit/Read/Write
   (`/home/xertrov/src/c2c/.claude/worktrees/<wt>/...`). Don't trust
   path-resolution heuristics — Edit can resolve to the main tree.
4. **No destructive git ops**: `git stash`, `git checkout HEAD --
   <file>`, `git restore`, `git reset --hard`, `git clean -f`,
   `git checkout .`. All of these can nuke peer-unstaged work
   silently.
5. **If a build breaks or a test fails unexpectedly**: the first
   question is "who else is touching this file?" — not
   "let me reset the tree." Send a DM. Coordinate.

---

## Pattern 1 — `cd`-out-of-worktree (#373)

**Symptom**: subagent runs `cd /home/xertrov/src/c2c && opam exec --
dune build` thinking the build will be scoped to its slice. Build
proceeds against the main tree's working state, which has unrelated
edits from peers, breaking in confusing ways. Or the subagent's own
edits get accidentally captured into the main tree's `git status`.

**Cause**: `git stash` and similar are scoped to the `.git`
directory, not the worktree CWD. Many shell tools default to the
main-tree CWD when invoked from a subprocess.

**Mitigation**: never `cd` out. If you need a different working dir,
spawn a sub-shell that scopes back. For dune: pass
`--root <abs-worktree-path>` explicitly:

```
opam exec -- dune build --root /home/xertrov/src/c2c/.claude/worktrees/<wt>
```

For git in the worktree: use `git -C <abs-worktree-path>` instead of
`cd ... && git ...`. This makes the explicit-worktree intent
visible at the command level, not just shell state.

---

## Pattern 2 — concurrent-stage (#377)

**Symptom**: subagent A runs `git stash` to A/B-test something. The
stash captures unrelated `.collab/findings/*.md` changes from
subagent B that happened to be unstaged in the shared tree. Pop
later "succeeds" but B's work is silently merged in/lost depending
on timing.

**Cause**: `.git/` is shared across all worktrees. `git stash`
reads from the index + working tree of whatever directory you
invoke it from, but the stash itself is global per-`.git`.

**Mitigation**: **never `git stash` mid-slice**. If you need to
A/B-test something:

- Commit your WIP (even a `WIP: testing X` commit on your slice
  branch). You can rewrite history later.
- Or use a separate fresh worktree for the test.
- Never use `git stash`. Period.

Variant: **never `git checkout HEAD -- <file>`** to "revert" a
local edit. It will silently discard a peer's unstaged edit to
the same file and the file is NOT recoverable from reflog.

---

## Pattern 3 — Edit-tool-resolves-to-main-tree (#380)

**Symptom**: subagent in `/home/xertrov/src/c2c/.claude/worktrees/<wt>/`
calls Edit on `ocaml/c2c_mcp.ml` (or even an absolute path like
`/home/xertrov/src/c2c/ocaml/c2c_mcp.ml` without the worktree
prefix). The Edit tool resolves to the **main worktree's** copy
instead of the slice worktree's, briefly polluting main with
slice changes.

**Cause**: Edit doesn't always honor the calling subagent's CWD;
ambiguous relative or main-tree-prefixed paths get resolved
literally.

**Mitigation**: always pass the FULL slice-worktree-prefixed
absolute path:

```
/home/xertrov/src/c2c/.claude/worktrees/<wt>/ocaml/c2c_mcp.ml
```

Same for Read, Write, NotebookEdit. Never bare relative paths,
never `/home/xertrov/src/c2c/...` without the `.claude/worktrees/<wt>/`
prefix.

If you do pollute the main tree, recover via `git -C
/home/xertrov/src/c2c checkout -- <file>` — but this is itself
destructive (Pattern 2 caveat). Better: file the finding, ask the
swarm if anyone was holding unstaged work on that file, and only
revert with peer ack.

---

## Pattern 4 — mid-slice-stash-loses-edits (this slice)

**Symptom**: subagent runs `git stash && opam exec -- dune build &&
git stash pop` to verify a pre-existing test failure is theirs.
The stash pop reports `Dropped` but the subagent's edits to
`Git_helpers.ml` and `c2c_peer_pass.ml` are silently absent.
`git fsck --lost-found` recovers them via dangling commit objects.

**Cause**: same as Pattern 2 — stash captured an unrelated
`.collab/findings/*.md` change touched by a peer (the only edit
the global stash saw at that moment), then "popped" successfully
into the unrelated change while the subagent's edits remained
missing.

**Mitigation**: **never stash mid-slice** (rule 2). To A/B
verify against a baseline:

- Commit-WIP, run baseline test (a fresh worktree on
  `origin/master` is the cleanest baseline), restore your
  worktree, continue.
- Or git stash IN A SEPARATE FRESH WORKTREE — but this is overkill
  for the typical case.

Recovery if you've already lost edits: `git fsck --lost-found`
exposes dangling blobs/commits. Manual reapply.

---

## Why these rules are load-bearing

The c2c swarm runs many parallel subagents during quota-burn
windows (10+ at peak). Each subagent thinks it has a clean
private workspace; in reality, `.git/`, `.collab/findings/`, and
parts of the working state are shared. The patterns above are
the load-bearing failure modes that surfaced when concurrency
exceeded ~3-4 active workers.

The rules aren't "best practices for solo dev" — they're "the
specific moves that DON'T blow up other agents' uncommitted
work in this layout."

## When in doubt — coordinate

If you hit:
- A merge conflict you didn't expect
- A test failure that wasn't there 10 seconds ago
- A file that contains code you didn't write
- A dependency that mysteriously appeared/disappeared

The first move is **always** to ask:

> Is anyone else touching this file right now?

DM coordinator1, post in `swarm-lounge`, or check `git log
--all --since="5 minutes ago"`. Coordinate the fix. Never
reach for `git stash` / `git reset` / `git checkout --` as a
shortcut — those will create the next agent's footgun finding.

---

## Cross-references

- `.collab/findings/` (multiple) — the four pattern receipts:
  `2026-04-24T02-10-00Z-coordinator1-destructive-checkout-protocol-violation.md`
  (Pattern 1/2 origin), plus 2026-04-28 footgun notes from
  the burn-window.
- Root `CLAUDE.md` "Shared working tree rules" — the five
  destructive ops to never use.
- `.collab/runbooks/git-workflow.md` — overall slice / commit
  / push discipline (5 rules from #324).
- `.collab/runbooks/worktree-per-feature.md` — worktree
  mechanics + `--worktree` flag + `c2c worktree gc` integration.
- `.collab/runbooks/branch-per-slice.md` — slice sizing and
  drive-by discipline.

## Notes

- Filed unifying #373 (cd-out) + #377 (concurrent-stage) +
  #380 (Edit-resolve) + new pattern (mid-slice-stash) per
  Cairn's request 2026-04-28 ~16:30 AEST.
- Authors: stanza-coder (compilation), coordinator1 (#373/#377/#380
  framing).

— stanza-coder, with coordinator1
