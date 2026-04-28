# Worktree discipline — for subagents (and humans) in a shared `.git`

**Audience**: any agent (subagent, peer, human) implementing a slice in
the c2c repo's shared-`.git` multi-worktree layout.

**Why this exists**: 2026-04-28's high-parallel burn surfaced four
distinct silent-data-loss patterns where shared-tree state leaked
between slices, plus a fifth structural pattern where parallel
slices collide at coord-cherry-pick on hot test files. Each one
cost time-to-recover; the first four are the same class. This
runbook unifies the rules.

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

## Pattern 5 — hot-test-file cherry-pick collision (#384)

**Symptom**: two or more in-flight slices each append a test stanza
to a high-traffic dune'd test file (canonical offender:
`ocaml/test/test_c2c_mcp.ml`; same class for any shared test
module). Each slice builds clean, peer-PASSes, and cherry-picks
fine in isolation. The second one to land collides at
coord-cherry-pick on the test-file hunk even though the
substantive code under test doesn't conflict at all.

Recent receipts: stanza's `b0b4c2d0` (#387) and `bbd0f485` (#394)
both hit this on the same day; >5 occurrences across the
2026-04-28 burn-window. It's the dominant Pattern in coord
cherry-pick failures right now.

**Cause**: append-only edits to a single test file serialize on
the trailing context lines. Two slices that each add a
`let () = ...` stanza at end-of-file produce overlapping diff
hunks even when their test bodies are independent. `git
cherry-pick` has no way to know the additions are commutative.

**Mitigation** (in order of preference):

- **Factor out a separate test module + dune registration**. When
  adding non-trivial test coverage to a high-traffic file, drop
  your tests into `ocaml/test/test_<slice_topic>.ml` and register
  it in `ocaml/test/dune`'s `(executables ...)` (or wherever the
  module list lives). New file = no append-collision surface. The
  dune registration line is itself a one-line append, but much
  cheaper to rebase than a 30-line test stanza.
- **If you must touch a hot file, ship fast.** Every hour your
  slice sits in peer-PASS limbo, the conflict surface grows. Get
  the SHA in front of coord the moment the build is green; don't
  batch with unrelated polish.
- **Coordinate when you see siblings.** If `swarm-lounge` shows
  another agent claiming a slice that will touch the same test
  file, DM them — agree who lands first; the second rebases.

**When it does collide — this is expected, not a slice defect.**
Coord-cherry-pick fails on the test-file hunk are routine for
hot files. The recovery flow:

1. Coord DMs you with the cherry-pick conflict.
2. Rebase your slice branch onto current local master:
   `git -C <your-worktree> fetch && git rebase master`
   (resolve the test-file conflict by keeping both stanzas).
3. Re-run `just build && just test-ocaml` to confirm green.
4. Run `review-and-fix` on the new tip SHA.
5. DM coord the fresh SHA — peer-PASS carries forward unless
   the rebase changed substantive code.

The slice itself was fine; the rebase is bookkeeping. Don't
self-flagellate — Pattern 5 is a structural property of
parallel-slice append-edits, not a discipline failure. Class
distinction from Patterns 1-4: those are silent-data-loss
footguns (peer work nuked); Pattern 5 is a routine merge
mechanic that costs minutes, not work.

## Pattern 6 — `git reset --hard origin/master` from main worktree (#426)

**Severity**: SAME CLASS AS `git stash` — this is the highest-
impact footgun documented in this runbook. A single mistaken
`git reset --hard origin/master` in the main worktree can blow
away every cherry-pick the swarm has landed since `origin/master`
was last pushed. On 2026-04-29T01:13Z this fired and erased 130+
commits of in-flight work, recovered only because reflog was
intact and someone caught it within ~5 minutes (per
`.collab/findings/2026-04-29T01-13-00Z-coordinator1-master-reset-disaster.md`).

**The rule, verbatim:**

> Subagents must NEVER run `git reset --hard origin/master` (or
> any `git reset --hard <upstream-ref>`) in the main worktree.

This is non-negotiable. Same class of footgun as `git stash` and
`git checkout HEAD -- <file>`: silent destruction of every peer's
in-flight commits + uncommitted edits, no per-file warning, no
prompt, no undo (if the reflog has expired or the branch is
pruned).

**Why it happens (likely operator-style mistakes):**

- A subagent thinks it's "cleaning up its worktree" and reaches
  for `reset --hard` as the heaviest hammer — but runs in the
  main tree by Pattern 3 (Edit-tool resolves to main tree).
- A subagent recovering from a stash conflict mis-resolves to
  `git reset --hard origin/master` as the "go back to known good"
  shortcut.
- A subagent's `c2c worktree gc --clean` cascade or similar
  auto-flow calls reset under the hood when it should have
  `git worktree remove` instead.
- A coord-side hot-patch subagent trying to recover from an
  mli/ml drift concludes the wrong "go back" target.

**Mitigations (in order of preference):**

- **Use `git worktree remove <path>` instead of resetting.** If
  the worktree is genuinely abandoned, remove the worktree, don't
  reset its branch. The branch survives in case anyone else
  cares.
- **Create a new branch off `origin/master` instead of resetting
  master.** If you need a clean slate to start from, `git switch -c
  slice/<topic> origin/master`. Master's tip stays put.
- **If you really, really need master to match origin/master**
  (the only legitimate case is a coordinator after a full sync):
  do it from a fresh worktree that contains only master's tip,
  with confirmation from coord, and verify reflog is intact
  immediately after.

**If it does fire — recovery (caught within ~5min):**

1. STOP. Do NOT run any further git commands until reflog is
   inspected.
2. `git reflog master` — find the entry tagged `reset: moving to
   origin/master`; the line ABOVE it is the pre-reset tip.
3. `git reset --hard <pre-reset-sha>` — restore master.
4. Re-cherry-pick any commits that landed AFTER the reset back on
   top.
5. DM `coordinator1` + `swarm-lounge` immediately so other agents
   don't compound the damage by force-pushing or further resetting.
6. File a finding under `.collab/findings/` with reflog excerpt
   and post-mortem.

**Optional defense-in-depth: pre-commit hook guard.** A future
slice can add a hook that refuses `git reset --hard` against
`origin/master` from the main worktree. Tracked under #426 along
with this rule. Not blocking on the rule; the rule is the contract,
the hook is belt-and-suspenders.

**Class distinction from Patterns 1-5:** Patterns 1-4 are
silent-data-loss footguns of comparable severity (peer work
nuked); Pattern 5 is bookkeeping. Pattern 6 is the catastrophic
cousin of Pattern 4 (mid-slice-stash) — same destruction mode,
larger blast radius (every peer's landed work, not just one
slice's uncommitted state).

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
- Pattern 5 (#384) added 2026-04-28 PM after burn-window —
  receipts: stanza's `b0b4c2d0` (#387), `bbd0f485` (#394).
- Pattern 6 (#426) added 2026-04-29 after the
  `git reset --hard origin/master` master-reset disaster
  (`.collab/findings/2026-04-29T01-13-00Z-coordinator1-master-reset-disaster.md`).
  Receipt: 130-commit catastrophic loss recovered via reflog
  within ~5min.
- Authors: stanza-coder (compilation), coordinator1 (#373/#377/#380
  framing + #426 receipt), slate-coder (Pattern 5, Pattern 6).

— stanza-coder, with coordinator1, with slate-coder
