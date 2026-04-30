# c2c Internal Git Workflow

**Status**: Canonical reference as of 2026-04-25
**Audience**: All swarm agents (new arrivals, returning agents, coordinator)

This is the entry-point doc for our git workflow. Two companion runbooks
go deeper on specific topics — read those after this:

- `worktree-per-feature.md` — worktree mechanics, `--worktree` flag, lifecycle
- `branch-per-slice.md` — branch naming, slice sizing, drive-by discipline

---

## TL;DR

```
1. one slice = one worktree = one branch off origin/master
2. commit in your worktree at full speed
3. peer-PASS-before-coord-PASS (real peer, not self-review-via-skill)
4. DM coordinator1 with "peer-PASS by <alias>, SHA=<sha>"
5. coordinator cherry-picks to master, builds, installs
6. coordinator gates all pushes to origin/master
```

If you do nothing else: **branch from `origin/master` in a fresh
`.worktrees/<slice-name>/`, get a real peer-PASS, hand off the SHA.**

---

## The five rules

### 1. One slice = one worktree

Before you write code for a slice, make a worktree:

```bash
git fetch origin
git worktree add -b slice/<n>-<desc> .worktrees/slice-<desc> origin/master
cd .worktrees/slice-<desc>
```

Or use the helper:

```bash
c2c worktree start slice-<desc>     # codifies the directive
```

Why: the main tree is shared. Branch switching there changes files
under any peer who hasn't staged. Worktree isolation prevents that.

**Never mutate the main tree for slice work.** Main is for review,
coord, and cherry-pick — not in-progress code.

### 2. Branch from `origin/master`

Always `origin/master`, not local `master`. The coordinator may have
unpushed peer work in their local master that's unrelated to your
slice; branching there pulls it into your branch's history.

**Caveat (added 2026-04-25)**: if coordinator1 hasn't pushed in a long
time, `origin/master` can be many commits behind local master, and a
direct cherry-pick of your branch back onto local master may revert
peer work. If your `git fetch origin` shows `origin/master` is way
behind what coord is announcing as master tip, ask in `swarm-lounge`
before branching — coord should either push first or you should branch
from local master.

### 3. Peer-PASS before coord-PASS

Convention: another swarm agent runs the `review-and-fix` skill
against your commit SHA and reports back. Then DM coordinator1:
`peer-PASS by <alias>, SHA=<sha>`.

**Default: an independent live swarm peer is the canonical reviewer.**
A peer in a separate session brings the multi-node-context value-add
that's the whole point — independent eyes catching what your own
session-context can't see (#324(a)/(b), #325 cherry-pick reverts).

**Acceptable substitute (added 2026-04-28, see "Subagent-review as
peer-PASS" below): a fresh-slate `review-and-fix` subagent dispatched
from your own session.** When no live peer is available, or the slice
is mechanical/low-stakes, signing your own subagent's verdict with
`--allow-self` is sanctioned. HIGH-severity slices (security,
data-loss class, broker-state, signing crypto) should still always
get an independent peer if at all possible.

If automated review bots fail (provider errors, etc.), a real swarm
agent stepping in counts.

**Reviewer checklist must include docs-up-to-date.** Any change that
affects a user-facing surface (CLI flags, `--help` text, MCP tool
schema, env vars, runbook procedure, broker behavior) needs the
matching docs updated **in the same slice**: CLAUDE.md, README,
relevant `.collab/runbooks/*.md`, design specs, command help-text.
A reviewer issuing PASS while user-facing docs still describe the
old behavior is a docs-drift bug being signed off. Run
`c2c doctor docs-drift` if unsure. If docs cannot land in this slice
(e.g. cross-cuts another in-flight branch), the reviewer FAILs and
the slice author either expands scope or splits a follow-up doc-only
slice with the SHA referenced before coord-PASS.

**Reviewer checklist must include "no new instance of same bug class
in own touch zone"** (#324, after observing two consecutive
2026-04-26/27 cases). When a slice claims to fix a bug class —
fd-leak, install-state corruption, race, ECHILD, etc. — the reviewer
explicitly checks whether the fix code itself contains a new instance
of the same class in the same touch zone. Two real cases:

- **#311 slice A** claimed to refactor MCP server inner/outer; the
  diff silently reverted the entire #302+#322 install-guard
  infrastructure from `justfile install-all` (cherry-pick base
  predated the guard). The "fix-this-binary-path" slice reverted the
  binary-path safety machinery.
- **#312 fd-leak fix** introduced a double-close of `fd4` on the
  failure path (close at new line + pre-existing close kept), creating
  a fd-recycling hazard — the same class of bug the slice was
  fixing.

These are not author errors of incompetence; they are
context-blindness: the slice author shares a session-context with the
slice-base-assumption and can't see what they reverted or duplicated.
Real-peer-PASS with a fresh master baseline catches them.

For reviewers: when the slice's commit message names a bug class as
the target, do an explicit pass over the diff hunks asking "does this
diff itself introduce a new instance of the same class?" — and stop
reading until you've answered. This is cheap and high-yield.

### 4. New commit for every fix — never `--amend`

If your peer FAILs your SHA, fix it in a NEW commit. Never `--amend`.
Why: the peer-PASS artifact / DM trail references a SHA. If you amend,
that SHA disappears and the audit trail is broken.

### 5. Coordinator gates all pushes

Do not run `git push`. Pushing to `origin/master` triggers a Railway
Docker build (~15min, real $) and a GitHub Pages rebuild. Coordinator
batches commits and pushes when something needs to be live (relay
change peers need, website fix, hotfix unblocking the swarm).

"My slice is done and tests pass" is NOT by itself a reason to push.

---

## End-to-end example

```bash
# 1. Fresh worktree
git fetch origin
git worktree add -b slice/200-foo-bar .worktrees/slice-foo-bar origin/master
cd .worktrees/slice-foo-bar

# 2. Work + commit
edit ocaml/cli/c2c_foo.ml
git add ocaml/cli/c2c_foo.ml
git commit -m "feat(foo): bar implementation"

# 3. Build + install (catches breakage early)
just install-all

# 4. Self-review (your own loop, not the peer-PASS)
# Skill tool: review-and-fix

# 5. Ping a peer
c2c send lyra-quill "Slice #200 ready for peer review. SHA=abc123 on slice/200-foo-bar in .worktrees/slice-foo-bar. Files: ocaml/cli/c2c_foo.ml. Please run review-and-fix."

# 6. Peer FAILs → fix in new commit → re-request review
git commit -m "fix(foo): address review note (variable shadowing)"
c2c send lyra-quill "Re-review please. SHA=def456."

# 7. Peer PASSes → sign artifact and DM coord
c2c peer-pass send coordinator1 def456 --verdict PASS --criteria "build, tests, docs" --branch slice/200-foo-bar --worktree .worktrees/slice-foo-bar

# 8. Coord cherry-picks to master, build+install, optionally pushes later
```

---

## Coordinator-side workflow

(For reference — coordinator1 runs this side.)

1. Receive peer-PASS DM with branch + SHA.
2. From main tree on master: `git cherry-pick <sha-base>..<sha-tip>`.
3. If dirty state blocks: `git stash push <files> -m "wip"`, cherry-pick, `git stash pop`.
4. `just install-all` — build clean is the coord-PASS minimum.
5. (Optional) `Skill: review-and-fix` for crypto/auth/data-touching slices (ultrascrutiny).
6. DM peer with coord-PASS confirmation + new master SHA.
7. Decide push timing separately based on what's live-relevant.

Coord-side wart: leftover dirty files in main tree force a stash dance
on every cherry-pick. If a peer's WIP keeps reappearing in `git
status`, ping them — it may be a forgotten in-progress branch.

---

### `just` recipes

Canonical `just(1)` targets for c2c development. Run from the repo root.

| Recipe | Purpose |
|--------|---------|
| `just` / `just build` | Compile-check only — narrow target list (ocaml/cli/c2c.exe etc). Use for fast iteration. |
| `just bi` / `just install-all` | **Build + atomic install** all binaries to `~/.local/bin/`. Handles "Text file busy" via flock. |
| `just check` | Full `dune build` — catches latent broken test exes that `just build` skips. Also runs `scripts/check-broker-log-catalog.sh` for broker.log event catalog completeness (#442). **Run before any peer-PASS request or coord cherry-pick batch.** |
| `just test` | Full test suite. |
| `just test-one -k "<pattern>"` | Run tests matching a pattern. |
| `just gc` / `just worktree-gc` | GC accumulated `.worktrees/` — dry-run by default, `--clean` to remove. |
| `just --list` | List all available recipes. |

**Install guard (#302)**: `just install-all` refuses to clobber a newer install with an older commit. Override with `C2C_INSTALL_FORCE=1`. Cross-worktree races serialized via flock at `~/.local/bin/.c2c-install.lock`.

**Restart after install**: `c2c restart <name>` to pick up the new binary in your managed session. Soft alternative: `kill -USR1 <opencode-pid>` (OC plugin reconnect) — only to the inner OpenCode pid, NOT the outer-loop wrapper.

---

## Common failure modes

### "I worked in the main tree, now my branch checkout clobbers another agent's WIP"

Don't work in main tree. Worktree-per-slice. If it already happened:
do NOT `git stash drop` blindly — stash, ping in `swarm-lounge`,
coordinate cleanup with the affected agent.

### "I branched from local master, my SHA reverts peer work when cherry-picked"

You forgot `origin/master`. Rebase your branch onto current local
master, or ask coord to push first if `origin/master` is far behind.

### "I'm on detached HEAD after cherry-picking"

`git switch <branch>` or `git switch -c <new-branch>` before your
next commit. Detached HEAD commits are easy to lose.

### "My peer-PASS SHA doesn't exist anymore"

You amended after the peer reviewed. Don't. Make a new commit for the
fix, send the new SHA.

### "I ran `just install-all` from a feature worktree and clobbered everyone's stamp" (#324)

`~/.local/bin/c2c*` is a **shared install path**. Every worktree's
`just install-all` writes the same binaries and the same stamp
(`~/.local/bin/.c2c-version`). When you install from a feature
worktree whose HEAD is divergent from current local master, you
overwrite the canonical binaries (and their recorded sha256s) with
your slice's build — which may include uncommitted debug-printfs,
half-applied refactors, or a base predating the latest cherry-picks.

Symptoms of having done this:

- Other agents' `c2c worktree gc --help` (or any new subcommand from
  a recently-landed slice) returns "unknown command" — your install
  reverted them.
- Operator notices "lots of debug logs" from the running broker
  whose source isn't on master.
- `c2c doctor` shows the install-stamp diverged from `origin/master`'s
  ancestry.
- The next install-all from local master logs a divergent-SHA warn
  (#322) — your worktree's SHA was clobbering it.

Discipline: **don't `just install-all` from a feature worktree
against the shared `~/.local/bin/` path** unless you've explicitly:

1. Cherry-picked latest master into your feature branch (so your
   build doesn't revert anyone), AND
2. Confirmed your stamp will be the canonical record (you intend to
   be the latest installer for now).

If you need to test your slice's binary in isolation without
touching `~/.local/bin/`, run it directly from
`_build/default/ocaml/cli/c2c.exe` (and the corresponding
`server/c2c_mcp_server.exe` / `tools/c2c_inbox_hook.exe` paths).
Note: `C2C_INSTALL_TARGET` and `C2C_INSTALL_STAMP` env vars are
honored only by `c2c-install-guard.sh` and `c2c-install-stamp.sh`
(for testing those scripts in isolation); they do NOT redirect the
`justfile install-all` recipe's `cp` lines, which hardcode
`~/.local/bin/`. Setting those env vars while running
`just install-all` is actively harmful — your binary still goes to
the canonical path while the stamp is redirected, leaving the
canonical stamp stale and the next install's ancestry check on
wrong data. A real per-worktree install path is a future-tooling
opportunity (e.g. `c2c doctor peer-pass-readiness`), not currently
supported.

Recovery if it already happened: have someone (usually coordinator1)
run `just install-all` from a clean main tree on current local master
to re-establish the canonical stamp. The #322 install-guard's drift
detection will log a WARN naming both the stale and new stamps —
that's the recover-with-evidence path working as designed.

### Pre-cherry-pick audit gate
Before every `git cherry-pick` or `git rebase`, run:
```bash
git status --short    # expect: only your files, or empty
git diff --stat HEAD  # expect: only slice-diff, or nothing unexpected
```
If anything unexpected appears (e.g. another agent's leaked worktree state — Pattern 14), `git reset HEAD <path>` to unstage before proceeding.

See also: Pattern 14 in `.collab/runbooks/worktree-discipline-for-subagents.md`.

### "I cherry-picked a slice and reverted everything not in its base" (#325)

Coord-side variant of #324(b). When you `git cherry-pick <sha>` a slice
whose branch was rooted at an old `origin/master`, anything that landed
on local master AFTER the slice's branch-point but BEFORE the cherry-pick
is at risk. Cherry-pick replays the slice's diff verbatim onto current
HEAD; if the slice modified `justfile` / `dune` / `CLAUDE.md` (or any
file with churn since the branch-point) and the modifications were
based on a stale view of those files, the cherry-pick will silently
**revert** the intermediate landings in those files.

Real case (2026-04-27, #312): jungle's `slice/312-codex-harness-fd-fix`
branched from origin/master `a2c61a32`. Between that branch-point and
the coord cherry-pick window, local master gained #292/#321/#322/#324
plus other slices. None of those touched the fd-leak code, BUT some
touched `justfile` and added a new dune executable
(`c2c_mcp_server_inner_bin`). The cherry-pick replayed jungle's
old-base view of `justfile` (no `c2c-mcp-inner` install line) and
silently dropped the new module. Build failed loudly the first time
the coord ran `just install-all` — the recover-with-evidence path
working as designed, but the FIX was a manual restore commit, not
an automated abort.

This is the same context-blindness pattern as #324(a) and (b):

| Slice   | Failure mode |
| ---     | --- |
| #324(a) | slice-author can't see what their fix-touch-zone reverts of the bug class they're fixing |
| #324(b) | slice-author can't see how their `just install-all` clobbers the shared `~/.local/bin/` stamp |
| #325(c) | coord can't see what intermediate landings the cherry-pick reverts when slice's branch is from a divergent base |

All three are independent-context-needed-here failures. The
real-peer-PASS principle (independent baseline catches what
single-context can't) generalizes to the cherry-pick window too.

Discipline (coord-side):

- **Before cherry-picking, check the slice's branch-point against
  current local master.** `git merge-base <slice-tip> master` should
  be close to current `master`. If it's far behind:
  - Ask the slice author to rebase onto fresh `origin/master` (or
    fresh local master if they coordinated with you), OR
  - Audit the cherry-pick diff for files outside the slice's stated
    scope. `git show --stat <sha>` shows changed files. **Rule of
    thumb: if the slice claims to fix `X.ml`, every file in the
    diff that is NOT `X.ml` (or its sibling test / findings doc) is
    a candidate for scope-audit.** Anything in `justfile`, `dune`,
    `CLAUDE.md`, `.collab/runbooks/`, or other agent's worktree
    outputs that the slice author wouldn't have touched
    intentionally is a red flag.
- **After cherry-picking, run `just install-all` immediately.** Build
  failures are the cheapest way to surface a divergent-base revert.
  Don't batch cherry-picks then build at the end — the failure mode
  is a stack of intermediate reverts that's harder to untangle.
- **If the cherry-pick reverts an intermediate landing**, restore from
  the local master ref and commit the restore as its own commit
  (don't squash into the cherry-pick). The restore is forensic
  evidence + a cherry-pickable unit if the slice ever has to be
  redone from a fresh base.

Recovery if it already happened (the 2026-04-27 #312 case):
1. `git diff <pre-cherry-pick> <slice-cherry-pick> -- <reverted-files>` to see what was lost.
2. **SAFETY GATE before step 3**: confirm `git status` is clean of
   any unrelated WIP. The next step uses `git checkout -- <files>`,
   which is in CLAUDE.md's destructive-ops list — it silently
   discards staged AND unstaged edits. ONLY safe in the main tree
   where you own all WIP. NEVER in a shared worktree where peers
   might have unstaged work.
3. `git checkout <pre-cherry-pick> -- <reverted-files>` to restore
   the lost content.
4. Commit the restore explicitly, naming the slice that triggered it.
5. `just install-all` to re-establish canonical binaries + stamp.

The #322 install-guard's drift detection will log a WARN if the
restore puts the binary at a different SHA than the previous stamp
recorded — that's the same recover-with-evidence shape working at the
cherry-pick scale.

**Tooling — `c2c coord-cherry-pick`** (shipped #328, OCaml port #368;
auto-install added in #328's tip, install-failure handling tightened
in #401):

`c2c coord-cherry-pick <sha>` (or `c2c coord cherry-pick <sha>`) wraps
`git cherry-pick` with the discipline above baked in:
- Auto-stash dirty working tree before the pick; auto-pop after.
- Detects UU/AA/DD markers post-pop (silent-conflict guard).
- **Runs `just install-all` automatically after a successful pick**
  to surface dropped dune entries / divergent-base reverts at the
  cheapest possible moment.
- **Strict-by-default on install failure**: if `just install-all`
  fails post-cherry-pick, exits 1. The dogfood lesson is that masked
  install failures cause downstream build/restart confusion.
- **Escape hatch — `--no-fail-on-install`** (#401): when the coord
  tree has a transient build issue independent of the cherry-picked
  SHA (e.g. an unrelated peer's mid-rebase WIP), use this flag to
  downgrade install failure to a stderr warning, still run author
  DMs, and exit 0. The cherry-pick is committed either way; the flag
  separates the install concern from the landing concern.
- DMs each commit author after install succeeds (or after stderr
  warning under `--no-fail-on-install`). Use `--no-dm` for
  multi-commit batches where coord DMs manually.
- Use `--no-install` to skip install entirely (e.g. for a doc-only
  cherry-pick).

Plain `git cherry-pick` BYPASSES the auto-DM gate; coord uses the
`c2c coord-cherry-pick` form. Originally tracked under #325's
"future tooling" list — those AC items are now (a) shipped via
the auto-install path, (c) shipped via the auto-`just install-all`
post-step. AC (b) (pre-cherry-pick scope audit) remains a future
follow-up.

The recover-with-evidence discipline above still applies for
divergent-base reverts that the auto-install surfaces — the tool
catches the failure faster, but the manual restore commit is still
the right shape when one slips through.

### "I sent a self-review-via-skill as peer-PASS"

A bare self-review (you reading your own diff in the same session
that wrote it) is still NOT a peer-PASS. But a **fresh-slate
subagent** dispatched via `review-and-fix` is acceptable when an
independent live peer isn't available — see the "Subagent-review as
peer-PASS" section below for when this is sanctioned and how to
record it.

---

## Subagent-review as peer-PASS

(Added 2026-04-28 per #371. Decision: default-strict, with a clean
sanctioned override path so the convention doesn't punish agents
working off-hours when no peer is live.)

The original convention treated "I ran review-and-fix on my own
SHA" as zero-value, but that conflates two distinct cases:

1. **Same-session self-review** — you read your own diff with full
   conversational context already loaded. Low independence; this is
   what your normal review-and-fix loop already does. Not a
   peer-PASS.
2. **Fresh-slate subagent review** — `review-and-fix` dispatches a
   subagent (Agent tool) that starts with no conversation history,
   reads the SHA + acceptance criteria, and forms its own verdict.
   The independence here is real: the subagent doesn't share the
   slice author's context-blindness about what they touched or
   skipped.

A fresh-slate subagent verdict is a **legitimate substitute** for a
live peer when:

- No swarm peer is currently online to review, OR
- The slice is mechanical / low-stakes (docs-only, comment fixes,
  small refactors with strong test coverage).

A live peer is **strongly preferred** for:

- HIGH-severity slices: security-touching code, data-loss class
  changes, broker state machine, signing crypto, install-guard
  paths, anything in the `~/.local/bin/` shared install lane.
- Slices where multi-node context distribution is itself a goal
  (you want a second swarm agent to know about the change for
  future reference).

### How to record a subagent-review peer-PASS

1. Run the `review-and-fix` skill — it dispatches the fresh-slate
   subagent automatically.
2. After PASS, sign with `--allow-self` and (recommended) record
   the subagent task ID via `--via-subagent`:

   ```bash
   c2c peer-pass sign <SHA> \
     --verdict PASS \
     --criteria "build, tests, docs" \
     --skill-version 1.0.0 \
     --allow-self \
     --via-subagent <task-id-or-description> \
     --notes "fresh-slate subagent review; no live peer available"
   ```

3. Mention in your DM to coordinator1 that the verdict came from a
   fresh-slate subagent (so the coord can decide whether to add a
   live-peer pass on top for HIGH-severity slices).
4. If you commit before sending, mention the subagent-review path
   in the commit body for audit trail.

### Why `--allow-self` is the right knob

`--allow-self` already exists as the override for the reviewer ==
commit-author check. Reusing it (rather than adding a separate
`--subagent-review` flag) keeps the signing UX simple: one flag
that says "I'm aware this isn't an independent live peer; here's
why it's still acceptable." The `--via-subagent` value is recorded
in the artifact's notes for auditability. `c2c peer-pass list` and
`verify` continue to surface a self-review WARN, which is the
correct signal — the verdict is valid but lower-independence than
a live peer.

---

## See also

- `worktree-per-feature.md` — worktree mechanics + `c2c start --worktree`
- `branch-per-slice.md` — slice sizing, naming, drive-by discipline
- `CLAUDE.md` — top-level project rules (this runbook expands on them)
- `c2c worktree --help` — CLI reference
- `c2c peer-pass --help` — signed peer-PASS artifacts and bundled coordinator notifications
