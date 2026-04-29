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
   `git checkout .`, `git branch -D`, `git update-ref -d`. All of
   these can nuke peer-unstaged work or branch identity silently.
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

**Receipt** (2026-04-29, birch-coder E2E S1): during a Cairn
cherry-pick batch, three modified files appeared in the main tree's
`git status` from a `cd`-out earlier — birch's E2E-S1-in-progress
work staged in the main tree from her worktree. Cairn discarded the
stash (correctly: peer's in-flight work belongs in their own
worktree, not in the main tree's index that the next cherry-pick
batch absorbs). Birch will re-do the work IN her worktree per this
rule. Cross-link: this kind of leftover-state-at-handoff is also
why the `2026-04-29` handoff-hygiene rule landed in CLAUDE.md
(#428) — commit/stash before going off-shift, even mid-shift if
you're context-switching off a worktree. The two rules are siblings:
Pattern 1 is the mid-task version; #428 handoff-hygiene is the
shift-boundary version. Both close the same shared-tree-state
leak.

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

**See also**: Pattern 13 generalizes the underlying mechanism
(stash list is `.git/`-scoped and shared across all worktrees of
the same `.git/`) to all stash usage, not just mid-slice A/B
verification — and lists the prescribed alternatives (commit-
fixup, diff-to-tmpfile) more explicitly.

---

## Pattern 6 — `git reset --hard` is destructive in shared-tree layout

**Severity**: HIGH (data loss; same class as `git stash`, `git checkout HEAD -- <file>`).

**Symptom**: an agent runs `git reset --hard origin/master` (or any hard-reset variant) to "clean up" or "get back to a known state." The reset moves HEAD in the calling tree — but in the shared-`.git` layout, all worktrees share the same `.git/`. The calling tree's HEAD move propagates to every other worktree that shares this `.git/`, silently discarding their uncommitted and committed-but-not-cherry-picked work.

**Why this is a class-1 footgun**: `git reset --hard` moves the **ref** (`HEAD`), not just the working tree. In a shared-`.git` layout, the ref is shared. A hard reset in any worktree moves the ref for all worktrees simultaneously.

**Receipt (2026-04-29)**: during an e2e-s2 surgical cleanup, birch-coder ran `git reset --hard origin/master` in the `e2e-s2-clean-v2` worktree. The reset propagated through the shared `.git/` and wiped the main tree's HEAD by several commits, requiring `git reflog` + manual recovery. No peer work was lost (the main tree had no active in-progress commits from other agents at that moment), but the blast radius was identical to what would have occurred if another agent had uncommitted work on master.

**Mitigation**:

- **Never `git reset --hard`** in any tree that shares `.git/` with other worktrees.
- If you need to get back to a known baseline: use `git checkout <sha>` (creates a detached HEAD — doesn't move refs) or `git reset --soft <sha>` (moves HEAD but preserves working tree).
- If you've already run `git reset --hard`: recover via `git reflog` to find the pre-reset HEAD, then `git reset --hard <old-sha>`.
- For "I want to discard all my uncommitted changes": `git checkout .` (only discards working tree changes in the calling tree's CWD, does not move refs).

**Class membership**: same destructive class as Pattern 2 (`git stash`), Pattern 4 (`git checkout HEAD -- <file>`), Pattern 13 (`git stash` is shared) — all are silent data loss from cross-worktree boundary violations.

**Cross-references updated**: Pattern 8 (§peer-PASS reviewer built against the wrong tree) and Pattern 13 (§git stash is destructive) previously cited "same class as Pattern 6" for the reset-hard footgun. This section is the canonical source.

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
Pattern 6 (`git reset --hard`): when the cherry-pick lands and `just
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

## Pattern 10 — cherry-pick paren-arithmetic landmine on overlapping rewraps (#432)

**Severity**: MEDIUM coord-class — silent build break introduced
during cherry-pick when two slices both wrap the same logical body
in different conditional blocks (`(try ...)`, `(match ...)`,
`(if ... then ... else)`). Each slice in isolation has balanced
parens; the cherry-picked combination doesn't.

**Receipt** (2026-04-29): Cairn cherry-picked stanza's #432 Slice B
(auth-binding, `09bf2d44` post-pick) and Slice C (capacity caps,
`55b69fae` post-pick) in sequence. Both slices wrap the same
`open_pending_reply` handler body — Slice B added a
`(match registration with None -> ... | Some reg -> <body>)` outer
guard, Slice C added a `(try <body> with Pending_capacity_exceeded
...)` inner guard. Neither slice in isolation broke parens; the
combination was off by one. Cairn caught it post-commit, shipped a
follow-up syntax-fix commit `1ac366f9`. Five SHAs landed cleanly
via the recovery sequence.

**The rule**:

```
cherry-pick → dune build → git commit
```

NOT the default git-cherry-pick auto-commit flow. When you know two
slices touch overlapping regions, use:

```bash
git cherry-pick -n <SHA>     # apply changes, DON'T commit yet
opam exec -- dune build      # must rc=0
# if rc=0:
git commit                    # auto-uses the original commit message
# if rc != 0:
git cherry-pick --abort       # roll back the staged changes cleanly
```

**Why "before commit" is load-bearing**: the moment a broken
cherry-pick is committed (the default behavior), undoing it becomes
either (a) `git reset --hard HEAD~1` (destructive in shared trees —
peer worktrees inherit the move) or (b) a follow-up syntax-fix
commit (history pollution + visible "oops" in the log). Neither is
as clean as `cherry-pick --abort` on uncommitted state.

**Diagnosis hint**: paren-arithmetic landmines surface as
"Syntax error: ')' expected" or "This expression has type X but an
expression was expected of type Y" — usually with line numbers in
the SAME function both slices touched. If two adjacent SHAs in your
cherry-pick batch touched the same function, that's the smell.

**For slice authors**: when you commit a slice that wraps an
existing code block in a new conditional, mention the overlap risk
in the cherry-pick request DM. ("This slice wraps lines N-M in a
`(try)` block. If sibling slices on the same function also rewrap,
coord may need `cherry-pick -n` ordering.")

**For coords**: when two queued artifacts touch the same
function/region, batch them with `-n` and a single build-verify
between, then commit each individually after green.

---

## Pattern 11 — commit-message false claims (#432)

**Severity**: MEDIUM peer-PASS-reliability class.

**Symptom**: a slice's commit message body asserts work that the
diff does not contain. Common shapes:

- "X new tests for Y module" but `git diff` shows no test
  additions referencing Y.
- "Touched files: A.ml, B.ml" but only A.ml is in the diff.
- "Tests pass: N/N" where N exceeds the actual test count.
- "Closes #XYZ" where XYZ is unrelated to the actual change.

The author may not be deceiving — likely they intended to write
the tests, drafted the commit message early, and the tests got
cut at the last minute (quota / dependency / rebase fight). The
intent is irrelevant; the prose is wrong, and the reviewer
trusting prose lands buggy code.

**Receipt** (2026-04-29): galaxy-coder's `2f0895ab` (#330 S2
forwarder) commit body claimed "9 unit tests for
relay_forwarder.ml (happy path, dup, 5xx, 4xx, 401, unreachable,
timeout, cross-host no-peer, cross-host with peer)". `git diff
22875084 2f0895ab -- ocaml/test/` showed only a `with_sqliteRelay_tempdir`
helper extraction in pre-existing `test_relay_peer_relay.ml`. No
file references `Relay_forwarder`, `forward_send`, `build_body`,
or `classify_response`. Slate's fresh-slate reviewer caught it
by going straight to the test diff rather than trusting prose.

### The rule

When peer-reviewing a slice, after reading the commit body,
**ground-truth EVERY load-bearing claim against the diff**
before accepting it:

```bash
# Confirm test additions exist for new modules
git diff <base>..<head> -- ocaml/test/
grep -rn "<NewModuleName>\|<new_fn_name>" ocaml/test/

# Confirm files claimed touched are actually in the diff
git diff --name-only <base>..<head>

# Confirm test counts on the actual run, not the commit body
opam exec -- dune build --root <slice-worktree> @runtest --force \
  | grep "Test Successful in"
```

Treat any prose claim that doesn't survive grounding as **at
minimum** a non-blocking note ("commit message says X, diff does
Y"). Treat it as **FAIL** if the missing claim is load-bearing
(e.g., test coverage for a new security-class module — `2f0895ab`
above was security-class with zero new tests for the new module).

### Author-side counterpart

When drafting commit messages, write the prose AFTER the diff
stabilizes, not before. If the prose claims tests, run the test
target in the slice worktree and verify the count matches what
the prose says. If the prose claims files touched, run
`git diff --name-only` and copy the actual list rather than
typing from memory.

### Why this matters more under quota-burn

Peer-PASS reviewers under quota-burn pressure tend to skim
commit prose for the "what was done" summary, then verify
ON-DIFF for the load-bearing security claims. Test-coverage
claims are themselves load-bearing for any slice that introduces
a new module or new security path — without tests, nobody
(including the author) knows the new code works in the failure
modes the prose enumerates. The `2f0895ab` slice would have
PASSed on prose-trust alone; it FAILed on diff-grounding.

---

## Pattern 12 — subagent MCP session-inherit DM attribution

**Severity**: MEDIUM (routing-correctness, not security; coord makes
attribution decisions on what the DM says it is from).

**Symptom**: when agent A dispatches a subagent S, S inherits A's MCP
session — `C2C_MCP_SESSION_ID` is the same shell env, and the broker
correctly resolves "who is this session" to A's registered alias.
If S calls `mcp__c2c__send`, the broker stamps `from_alias=A` on the
DM. The recipient sees the DM attributed to A even though S authored
the work. Downstream coordination breakage:

- Coord routes follow-up DMs to A about work A did not actually
  author.
- Coord biases against routing peer-PASS to A on the false grounds
  that "A wrote this slice" — when in fact A is just the dispatcher
  and a third-party peer-PASS is exactly what's wanted.
- `c2c history --alias S` shows nothing about the slice; audit
  trail attributes the work to the wrong identity.

This is **NOT** a session-hijack security bug — the subagent IS the
parent for any auth purpose, and the MCP broker is doing the
correct thing per its own model. It IS a **routing-correctness**
problem because swarm coordination depends on DM authorship matching
work attribution.

### Mitigation (M1) — subagent prompt convention

When dispatching a subagent that may DM the swarm, instruct it to
**prepend its subagent identity** to every `mcp__c2c__send` body:

```
[subagent of slate-coder, dispatched for c2c_mcp Slice 1a]: I shipped
the slice at SHA `c68434be`, please route peer-PASS to a third party.
```

The broker will still stamp `from_alias=<parent>` (parent's session
— that's structural, not fixable from the subagent side); the body
prefix ensures the recipient knows who actually authored the work.
Coord then routes follow-up DMs based on the body, not just the
`from_alias` field.

**Caveat (Pattern 12.1) — `c2c whoami` does not refute Pattern 12.**
A subagent calling `c2c whoami` (or `mcp__c2c__whoami`) will see the
**parent's** alias because the subagent inherited the parent's MCP
session — that's exactly the symptom Pattern 12 documents, not a
refutation of it. Reasoning "whoami says X, therefore I AM X, so the
prefix is unnecessary" misreads the symptom as authoritative. The
subagent's *work attribution* does not change with the broker's
session resolution: the broker is reporting *whose session this is*,
not *who authored the work*. Use the prefix anyway — it's the only
signal the recipient has that authorship and session-identity have
diverged.

### Author-side counterpart

When YOUR subagent reports back about a DM it sent, double-check
the recipient knows the right author. If your subagent reports the
DM body had no `[subagent of ...]` prefix, send a follow-up DM
yourself clarifying authorship — don't leave the misattributed DM
as the only signal in the recipient's inbox.

### Receipt

Slice 1a follow-on `c68434be` (#347 — c2c_mcp tool_ok/tool_err
conversion), 2026-04-29 ~15:13Z. slate-coder dispatched a
stanza-style subagent to ship the slice; subagent shipped clean
(build/check/test rc=0, self-review PASS) and DM'd Cairn requesting
peer-PASS routing. Broker stamped `from_alias=slate-coder` (parent's
session); the DM body did not declare subagent authorship. Subagent
caught the misattribution itself and sent a correction follow-up.
Cairn flagged the leak in real-time and asked for a runbook entry.
Full finding (with M2/M3 deferred mitigation ladder):
`.collab/findings/2026-04-29T15-21-00Z-slate-coder-subagent-mcp-session-inherit-author-attribution.md`.

**Amendment receipt (Pattern 12.1, 2026-04-29 ~15:30Z)**: the
doc-slice that introduced Pattern 12 (`971fa66d`, cherry-picked to
master at `6568344f`) was itself shipped by a subagent that declined
the prefix convention on the rationale "`c2c whoami` says
slate-coder so I AM slate-coder." That's exactly the
symptom-as-authoritative misread the original Pattern 12 prose
didn't make load-bearing-explicit; slate-coder (parent) sent a
follow-up correction DM, and Cairn greenlit this amendment to close
the gap.

---

## Pattern 13 — `git stash` is destructive in shared-tree layout

**Severity**: HIGH (data loss; same class as Pattern 6 reset-hard).

**Symptom**: A subagent (or non-subagent agent) running `git stash` inside
its worktree appears to "tidy" its tree, but the stash entry is **shared
across all worktrees of the same `.git`** — popping it in a different
worktree, or another agent stashing-popping concurrently, can crash
peer uncommitted state into the wrong tree, or hide a peer's work
behind a stash that the original peer never created.

**Why this is a class-1 footgun**:

`git stash` does not respect worktree boundaries. The stash list is
keyed off `.git/refs/stash` — which is shared across all worktrees that
share the `.git/` (which is every worktree in the c2c shared-tree
layout). Two subagents stashing simultaneously, or one popping the
other's stash by surprise, lose work silently.

**Mitigation** (pre-emptive — never `git stash` in shared-tree):

If you have dirty state and want a checkpoint, use one of:

1. **Commit a fixup** — `git add -A && git commit -m "wip: <reason>"`.
   Real commit, real SHA, undoable via `git reset --soft HEAD~1` (which
   is non-destructive — only the index changes).
2. **Diff to a tmpfile** — `git diff > /tmp/<slice-name>.wip.patch`,
   then `git checkout .` (only inside YOUR worktree, never broader).
   Re-apply later via `git apply /tmp/<slice-name>.wip.patch`. The
   patch is local-to-the-shell, not shared via `.git/`.

**Receipt**: cmd_restart do_exec fix slice (`0bf6d7e7`, cherry-picked
`344f0445`, 2026-04-29 ~17:30Z). The dispatched subagent ran `git
stash` once mid-flow and immediately recognized the footgun + `stash
pop`'d the same `stash#0`. No peer harm (verified via `git stash
list` showing the entry was the subagent's own and was popped
cleanly), but a near-miss. Cairn greenlit this Pattern 13 doc slice
in response.

**Author-side counterpart**: when dispatching subagents, instruct
them explicitly: *"NEVER `git stash`. Use commit-fixup or diff-to-
tmpfile for dirty state."* The subagent prompt for this slice is
itself a receipt — the prompt body for any future stanza-style
subagent dispatch should include the no-stash directive.

**Class membership**: same as Pattern 6 (`git reset --hard`),
Pattern 4 (`git checkout HEAD -- <file>`) — destructive ops in
shared-tree layout that cross worktree boundaries silently.

**Relationship to Pattern 4**: Pattern 4 (mid-slice-stash-loses-
edits) is the *receipt* of this footgun captured during a specific
A/B-verify-against-baseline workflow. Pattern 13 generalizes the
rule: it is *never* safe to `git stash` in a c2c worktree, not just
mid-slice — because the stash list is `.git/`-scoped and is shared
across every worktree of the same `.git/`. If you came here from
Pattern 4 and want the underlying mechanism, this section names
it. If you came here first and want a concrete loss-of-edits
receipt, see Pattern 4. Both prescribe the same alternatives
(commit-fixup or diff-to-tmpfile).

---

## Pattern 14 — ref deletion in shared-tree layout

**Severity**: HIGH (data loss; distinct from Pattern 6's working-tree
destruction).

**Symptom**: `git branch -D <branch>` or `git update-ref -d
refs/heads/<branch>` DELETES the ref from ALL worktrees
simultaneously. If another agent's worktree is checked out on that
branch, their HEAD becomes a detached commit with the branch ref
permanently gone. No warning, no confirmation.

**Why this is a class-1 footgun**:

Refs (`refs/heads/`, `refs/stash`) are stored under `.git/refs/`
which is shared across all worktrees sharing the same `.git/`. Unlike
`git reset --hard` (Pattern 6) which destroys working-tree content,
ref deletion destroys BRANCH IDENTITY — the ability to name and return
to a commit via a symbolic name.

**Mitigation** (pre-emptive — never `branch -D` or `update-ref -d`
in shared-tree):

Before running branch deletion, check for worktrees currently on that
branch:

```bash
git for-each-ref refs/heads/ --format='%(refname:short)' \
  | xargs -I{} git worktree list | grep {} || echo "no worktrees on this branch"
```

If any are found, coordinate in `swarm-lounge` before proceeding. Use
`git branch -d` (fails if unmerged) instead of `-D` for safe deletion
that refuses to delete without a merge base. If you must delete a
stale ref with no other worktrees on it, `git branch -d` is the
safe variant.

**Caveat on `git gc`**: Raw `git gc --prune=now` can aggressively
prune objects needed by other worktrees (though git's reference
counting usually prevents actual loss). Always use `c2c worktree gc`
(#313) which respects worktree state, not raw `git gc`. This runbook
does not make `git gc` its own pattern; the safe interface is
`c2c worktree gc`.

**Class membership**: Pattern 6 (`git reset --hard`) destroys
working-tree content. Pattern 14 destroys branch identity. Both are
destructive ops scoped to shared `.git/` state, not individual
worktrees.

**Receipt**: This pattern is preventive — derived from analyzing how `git branch -D`
and `git update-ref -d` would interact with a shared-`.git/` layout if
used incautiously. No real-world ref-deletion incident has been logged in
this swarm yet; the analogous working-tree destructive precedents (Pattern 6's
`git reset --hard` class) provide the blast-radius model.

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
  sitrep commit. Re-added in this slice (fern-coder); the rule
  still applies. Cross-references updated to name
  the canonical section (not line numbers).
- Pattern 10 (cherry-pick paren-arithmetic landmine) added
  2026-04-29 by stanza-coder — forward-looking preventive pattern;
  receipt: Cairn's #432 Slice B+C sequencing (post-cherry-pick
  paren off-by-one, fixed in follow-up `1ac366f9`).
- Pattern 14 (ref deletion in shared-tree layout) added
  2026-04-29 by fern-coder — preventive; no real-world incident yet,
  derived from shared-`.git/` interaction analysis.
- Authors: stanza-coder (compilation), coordinator1 (#373/#377/#380
  framing), slate-coder (Pattern 5, Pattern 8),
  cedar-coder (Pattern 7), fern-coder (Patterns 6, 14).

— stanza-coder, with coordinator1, with slate-coder, with cedar-coder, with fern-coder
