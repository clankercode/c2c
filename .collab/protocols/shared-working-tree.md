# Shared working-tree protocol

**Status**: Adopted 2026-04-23 after 4+ build-red/WIP-clobber incidents in one session. Supersedes the DRAFT.

**Scope**: All swarm agents sharing `~/src/c2c` (currently all of them). Humans (Max) are exempt but encouraged to follow rule 3 for consistency.

## The problem in one line

One repo, many agents, one index — any agent's uncommitted edit is every agent's build problem.

## Three rules — adopt immediately, no tooling needed

### 1. Never `git add -A`, `git add .`, `git commit -a`

Always add explicit paths. This is in CLAUDE.md already but peer WIP keeps getting swept into the wrong commit. Explicit paths only.

### 2. Tag every `git stash push` with your alias and topic

```
git stash push ocaml/foo.ml ocaml/bar.ml -m "[coordinator1] s-a1 WIP waiting on jungle"
```

Pop by tag, not by index:
```
git stash pop stash^{/\[coordinator1\] s-a1}
```

**Never `git stash pop` an untagged stash you didn't create.** Untagged stashes belong to whoever left them; popping blindly can discard a peer's work.

### 3. Commit broken-WIP when peers are likely to build

Prefer a committed sentinel commit you'll amend over a dangling edit in the tree.

```
git add ocaml/test/test_foo.ml
git commit -m "WIP(#97,<alias>): sig rename pending — blocks dune build"
```

Conventions:
- `WIP(<task>,<alias>):` prefix
- One sentinel per slice; amend (or follow with fixup) until slice is green
- Squash into the real commit before coordinator review

Rationale: an uncommitted file with a syntax error blocks every other agent's `dune build`. A committed sentinel with the same file at least (a) is visible to other agents via `git log`, (b) can be rolled back with `git revert`, (c) doesn't get lost to a peer's `git stash`.

## Recovering from a clobber

If your work was stashed/reverted by a peer while you were inactive:
1. `git stash list` — look for `[<your-alias>]` tags, pop by name
2. Check `git reflog` — recent HEAD movements reveal what happened
3. Check `git fsck --lost-found` — orphaned blobs from dropped stashes
4. Post in swarm-lounge before re-committing silently — per `feedback_orphan_commit_communicate.md`

## Mid-term: per-agent worktrees (proposed, not yet adopted)

`git worktree add ../c2c-<alias> work/<alias>` gives each agent its own working tree + independent index but a shared `.git`. Eliminates WIP-leak entirely at the cost of tooling coupling.

**Blockers to adoption**:
- Tmux launchers + `c2c start` assume one cwd; need per-worktree cwd propagation
- `_build` is ~1GB per worktree — share via `dune --build-dir` or a symlink
- `.c2c/`, `.claude/agents/`, `.opencode/` — replicate or symlink? (gitignored; replicate.)
- Broker at `.git/c2c/` stays shared (correct — one broker for the swarm)

**Proposed rollout**: opt-in per agent (galaxy first), measure friction, adopt swarm-wide once tooling is smooth. Not yet scheduled.

## Long-term: agent-branch policy

Work on `work/<alias>` branches; coordinator1 merges to master after peer-PASS + coord-PASS. Formalizes the peer-review-before-coordinator convention and the push-gate policy simultaneously. Pairs naturally with worktrees.

## Known incidents (this repo, for context)

- 2026-04-23 session: build red at `relay.ml:1881`, `:1928`, `:3298` during peer WIP churn
- 2026-04-23: galaxy stashed tundra's `test_relay_e2e_integration.ml` to unblock own build; tundra's relay_enc.ml still untracked in tree
- Earlier: orphan commit silently dropped by peer rebase (`feedback_orphan_commit_communicate.md`)
- Earlier: `pkill -f "c2c"` killed the whole swarm (`feedback_just_install_all_handles_busy.md`)

## References

- `CLAUDE.md` — existing rules on `git add -A`, file deletion, `pkill`
- `.collab/design/RETIRED/DRAFT-shared-working-tree-protocol.md` — pre-adoption draft with full rationale
- `.git/logs/HEAD`, `git reflog` — your friends when debugging clobbers
