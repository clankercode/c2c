# DRAFT — Shared working-tree protocol for the swarm

**Status**: DRAFT — prompted by Max 2026-04-23 after repeated build-red cycles caused by peer WIP leaking between agents. Needs consolidation with the team.

## Problem

All agents (coordinator1 / galaxy-coder / jungle-coder / Lyra-Quill / ceo) share one git working tree at `~/src/c2c`. Each agent runs in its own tmux pane but edits/commits/stashes the SAME index. Consequences:

- Agent A mid-edit has uncommitted changes to `relay.ml`.
- Agent B runs `dune build`. Build is red from A's WIP, even though B didn't write it.
- Agent A stashes with `git stash`; B notices build is green, resumes work, commits — but now A's stash is in limbo and A's later pop may conflict with B's new commits.
- Agent B inspects `git status` to diagnose and sees A's WIP; misreads it as their own.
- Cross-contamination when a `git add -A` or `git commit -a` happens anywhere.

Observed symptoms this session:
- Build red at `relay.ml:1881` (jungle S5a) blocked my Phase A fix for ~10 min
- Build red at `relay.ml:1928` same cycle
- Build red at `relay.ml:3298` during cc-mm launch testing — blocked the fix we were validating
- Galaxy's `git stash` operation made working-tree state ambiguous to jungle + me
- `git add -A` has swallowed peer WIP into the wrong agent's commit multiple times historically

## Immediate convention (applies now, no tooling change)

**Three rules**:

1. **Never `git add -A`, `git add .`, or `git commit -a`.** Always add explicit paths. In CLAUDE.md already, but hitting anyway — worth reiterating.
2. **`git stash push` MUST tag with alias and topic**:
   ```
   git stash push -m "[alias] slice-s-a1 WIP"
   git stash pop stash^{/\[alias\] slice-s-a1}
   ```
   Never `git stash pop` an untagged stash you didn't create.
3. **Commit early, commit often, commit broken** — prefer a committed WIP commit you'll amend than a dangling edit in the tree. Name them `wip(<alias>): ...` so they're recognizable, squash before review.

## Mid-term: per-agent worktrees

`git worktree add ../c2c-galaxy master` creates a sibling directory with its own working tree + independent index but same `.git`. Each agent operates in its own worktree:

- `~/src/c2c` — shared base, coordinator1 or whoever shepherds merges
- `~/src/c2c-galaxy` — galaxy-coder's worktree
- `~/src/c2c-jungle` — jungle-coder's worktree
- etc.

Each agent commits on their own branch (`work/galaxy`, `work/jungle`); periodically rebase or merge into master from the shared worktree. This is the GitHub-PR model without the round-trip.

**Blockers**:
- tmux panes + managed-session launchers assume a single workdir. Each pane would need its own cwd.
- `.c2c/`, `.claude/agents/`, `.opencode/` — compiled artifacts, session state — all live under the worktree. Do we replicate or symlink? (Compiled are gitignored; replicate on compile.)
- Broker state at `.git/c2c/` is shared because `.git` is shared. That's actually what we want (one broker for all agents).
- Resource use: each worktree is ~1.2GB with _build. Maybe switch to `dune clean`-aware workflow or share `_build` via `dune --build-dir`.

**Proposed path**: scripts/c2c-worktree-up.sh <alias> creates `~/src/c2c-<alias>`, checks out a per-agent branch, configures tmux to cd there. Incremental — start with one agent (e.g. galaxy-coder) opting in, see if it helps.

## Long-term: agent branch policy

Each agent's primary work lives on `work/<alias>`. Master only gets merges via coordinator1 (me) after review. This formalizes the peer-review-before-coordinator convention and the push-gate policy simultaneously.

## Open questions

1. Does anyone rely on `git stash` being global to the repo? (Swarm coordination tricks?)
2. Can we move `_build` to `/tmp/c2c-build-<alias>` to avoid per-worktree rebuild storms?
3. Broker root resolution when multiple worktrees exist — does `git rev-parse --git-common-dir` still work correctly?
4. Tmux pane cwd at session start — propagate via `C2C_MCP_CWD` or equivalent?

## Next step

Discuss with peers in swarm-lounge. Adopt the three immediate rules now; evaluate worktrees over the next session or two before committing to that migration.

## References

- Repeated build-red incidents 2026-04-23 session (this afternoon)
- `feedback_just_install_all_handles_busy.md` — prior art: pkill on c2c wildcards killed the swarm (shared state)
- `feedback_orphan_commit_communicate.md` — prior art: a commit I landed got silently dropped by someone's rebase
- CLAUDE.md existing rules about `git add -A` / shared-file deletion
