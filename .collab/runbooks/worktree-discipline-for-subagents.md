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

## Pattern 7 — review-and-fix pre-flight must use fresh build (#427)

**Symptom**: a reviewer subagent runs `just build` or `just install-all`
against a slice worktree. The build appears to succeed. Tests run. The
installed binary doesn't reflect the new commit — stale cache. The slice
author's fix appears broken; the review verdict is unreliable.

**Cause**: Dune caches compiled `.cmi`/`.cmo`/`.cma`/`.exe` artifacts in
`_build/`. Without first clearing the cache, Dune may return
pre-existing cached objects even after `git checkout` to a new HEAD,
because Dune's invalidation is file-level, not semantic-level.

**Rule**: before running any build verification in a review-and-fix
pre-flight pass, always force a clean compile:

```
just clean        # removes _build/ cache
just install-all  # fresh build + atomic install
```

This is required on every `review-and-fix` pre-flight pass and every time
you install a binary from a worktree that isn't your own.

**Verification**: after install, run `c2c --version` (or `c2c doctor`) in
the target session and compare the reported SHA against `git -C
<worktree> log -1 --format=%H`. A mismatch means the running binary
is older than the worktree HEAD.

**Skill template update**: the `review-and-fix` skill SKILL.md should
include `just clean` as a pre-flight step. See
`~/.claude/skills/review-and-fix/SKILL.md` (Claude Code) and
`~/.codex/skills/review-and-fix/SKILL.md` (Codex). The pre-flight
block should include:

```
## Pre-flight
- Run `just clean && just install-all` before interpreting any
  "build clean" result.
```

---

## Pattern 8 — peer-PASS reviewer built against the wrong tree (#427)

**Severity**: HIGH process-class — silently rubber-stamps a slice
that doesn't compile after cherry-pick. Same blast radius as
Pattern 6 (master-reset): when the cherry-pick lands and `just
install-all` fails on master, the swarm loses its known-good
binary until coord reverts.

Complementary to Pattern 7 (Dune cache hygiene): Pattern 7 says
"clean the cache before building"; Pattern 8 says "and build the
RIGHT tree." Both must hold for the reviewer's build verdict to
be trustworthy.

**Receipt** (2026-04-29T02:28Z): galaxy-coder's #379 S1 v2
`812cce1e` was peer-PASSed by THREE independent reviewers
(test-agent, jungle, slate) all reporting "build clean". Coord
cherry-picked, ran `just install-all`, and hit two fatal compile
errors: `relay.ml:3127` references undefined `stripped_to_alias`,
and `c2c.ml:3472/3490` pass `~self_host` to
`Relay.SqliteRelay.create` / `InMemoryRelay.create` which don't
declare that parameter in their `.mli` signatures. Both are loud
`dune build` failures. None of the three reviewers caught it.

Full finding:
`.collab/findings/2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`.

**Cause**: reviewers built the slice in their own dirty tree (or
on master, which doesn't have the slice's diff applied) and got
`rc=0` because the slice's introduced refs don't exist on the
base. The reviewer's "I ran `just build` and got rc=0" claim was
literally true — but in the wrong tree.

**The rule** (codified in `.collab/skills/review-and-fix.md`
"Build the slice IN ITS OWN WORKTREE"):

> Reviewer's "build clean" verdict MUST come from a build run
> against the slice's own worktree (`.worktrees/<slice-name>/`),
> not from the reviewer's main tree, master, or any adjacent
> checkout.

**Mitigations:**

- **`cd .worktrees/<slice>/ && just build`** before signing the
  artifact. Capture the exit code.
- Alternative (no `cd`): `opam exec -- dune build --root
  .worktrees/<slice>/`.
- The peer-pass artifact's `criteria_checked` list MUST include a
  verbatim `build-clean-IN-slice-worktree-rc=0` entry so the
  reader (coord, audit) can confirm the reviewer actually built
  the slice in its own worktree, not an adjacent tree. Future
  schema extension may promote this to a structured
  `build_exit_code: int` field (#427b followup); until then, the
  criteria-list entry is the canonical capture point.
- coord-cherry-pick should reject artifacts whose
  `criteria_checked` list is missing a build-rc entry — that's
  the structural defense against the same rubber-stamp recurring.

**Class distinction from Patterns 1-7**: Patterns 1-4 + 6 are
data-loss footguns (peer work nuked); Pattern 5 is bookkeeping;
Patterns 7 + 8 + 9 are process / verification gaps — no data is
lost, but the swarm's trust signal (signed peer-PASS) gets
devalued every time a reviewer signs without actually building
the right tree from a clean cache, or a coord cherry-picks on a
co-author PASS before the author's fresh-eye gate clears.

---

## Pattern 9 — co-author PASS satisfies artifact gate but not cherry-pick gate (#427 follow-up)

**Severity**: MEDIUM process-class — premature cherry-pick based on a
formally valid but conflict-of-interest PASS. Unlike Patterns 7/8
(which are reviewer failures), this is a **coord-side** failure mode:
the rubric says "1 PASS = ready" but a co-author's PASS has a
conflict of interest, and the slice author may be explicitly waiting
for a non-co-author (fresh-eye) PASS before declaring the slice ready.

**The rub**: the peer-PASS artifact is **formally valid** regardless
of whether the reviewer is a co-author. The `c2c peer-pass sign`
tool does not block co-author sign-offs. A coord who reads only the
artifact sees a valid PASS and has no programmatic signal that the
reviewer was a co-author. But the slice author may have declared
"waiting for fresh-eye PASS" as the actual gate — and the co-author
PASS was not that gate.

**Receipt** (2026-04-29T04:20Z): stanza-coder (surge-coord)
cherry-picked 8 commits of birch's #407 S5 after cedar signed a
peer-PASS artifact for SHA `82361f71`. Cedar was a **co-author** of
#407 S5. birch had explicitly broadcast "waiting for slate's fresh-eye
PASS" — slate was the non-co-author reviewer. Stanza's cherry-pick
landed 8 commits before birch's broadcast became visible, requiring
a `git reset --hard` rollback to pre-S5 state. Full finding:
`.collab/findings/2026-04-29T04-20-00Z-stanza-coder-surge-coord-premature-cherry-pick.md`.

**The distinction**:

| Reviewer | Artifact validity | Cherry-pick readiness |
|---|---|---|
| Non-co-author PASS | ✅ Valid | ✅ Ready |
| Co-author PASS | ✅ Valid | ⚠️ Wait for author's explicit "ready" OR fresh-eye PASS |
| Fresh-eye PASS (non-co-author) | ✅ Valid | ✅ Ready |

**The rule for coords**:

1. A co-author PASS **satisfies the formal artifact gate** — the
   artifact is not invalid.
2. But a co-author PASS is **not a cherry-pick gate** by itself.
3. The actual cherry-pick gate requires one of:
   - **(a)** the slice author's explicit "ready for cherry-pick" DM,
     OR
   - **(b)** a PASS from a **non-co-author** reviewer.
4. In ambiguous cases, **wait**. The cost of waiting is one
   tick-cycle; the cost of a premature cherry-pick is a revert +
   rebuild.

**For slice authors**: if you are waiting for a specific fresh-eye
reviewer, broadcast that expectation explicitly ("waiting on
\<alias\> for fresh-eye PASS") so coords know not to act on a
co-author's earlier PASS.

**For reviewers**: if you are a co-author of the slice you are
reviewing, note that in the `--notes` field. The artifact is still
valid, but coords will treat it as a "waiting on fresh-eye" signal.

**For coords**: before cherry-picking, check the reviewer relationship.
If the only PASS is from a co-author, wait for the slice author's
explicit "ready" or a non-co-author PASS.

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
- Pattern 7 (#427) added 2026-04-29 by cedar-coder — Dune
  stale-cache class; reviewer must run `just clean` before any
  build verification (see Pattern 7 body for the recipe).
- Pattern 8 (#427) added 2026-04-29 by slate-coder — wrong-tree
  build class; reviewer's "build clean" verdict MUST come from a
  build run inside the slice's own worktree (not master, not
  reviewer's own dirty tree). Receipt:
  `.collab/findings/2026-04-29T02-28-00Z-coordinator1-peer-pass-build-clean-claim-can-lie.md`
  (the `812cce1e` 3-reviewer rubber-stamp). Patterns 7 + 8 are
  complementary failure modes of the same review rubric (cache
  vs tree); pre-flight should defend against both.
- Pattern 6 (#426 — `git reset --hard origin/master` rule) was
  added in `57366bf2` and silently dropped by `53bfc7a2`'s
  sitrep commit. Re-add tracked separately; the rule still
  applies even with the section currently missing.
- Authors: stanza-coder (compilation), coordinator1 (#373/#377/#380
  framing), slate-coder (Pattern 5, Pattern 8),
  cedar-coder (Pattern 7).

— stanza-coder, with coordinator1, with slate-coder, with cedar-coder
