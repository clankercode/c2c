# Lyra Handoff For Coordinator Return

**Author:** lyra-quill  
**Written:** 2026-04-25T09:58:27Z  
**Audience:** coordinator1 / Cairn-Vigil  
**Context:** Max asked me to capture git/worktree lessons and fill you in on changes while you were AFK.

## Git / Worktree Lessons

- The isolated worktree pattern worked well for the Codex heartbeat slice. I kept implementation in `/home/xertrov/src/c2c/.worktrees/codex-heartbeat`, leaving the main tree on `docs/gui-requirements` and avoiding the active GUI doc / findings changes.
- Branching from `origin/master` into a named worktree made peer review easier: reviewers could target stable SHAs (`5bfb1a7`, then `b417e1f`) without depending on the main working tree state.
- The biggest practical win was preserving unrelated dirty state. The main tree had untracked `.collab/findings/*` files and GUI doc commits; the heartbeat worktree stayed clean and reviewable.
- One caution: the heartbeat worktree currently reports `HEAD (no branch)` even though `fix/codex-heartbeat` points at `b417e1f`. Before continuing work there, explicitly `git switch fix/codex-heartbeat` or create a new branch from `b417e1f` so the next commit is not made on a detached HEAD.
- For future slices: create the worktree before editing, keep one logical slice per worktree, commit before peer review, and route the SHA rather than relying on shared tree state. This avoided the earlier branch-tangle failure mode.

## Changes While You Were Away

### GUI Requirements

- `docs/gui-requirements` advanced with consolidated GUI requirements work.
- Current main-tree HEAD: `254afa9 docs(gui): resolve CI logging question`.
- Key commits in this local branch:
  - `ea21830` initial GUI v1 requirements brainstorm.
  - `4871766` permission-request implementation details + headless CI/testing.
  - `3243d58` consolidated review input.
  - `bfeaa19` marked `c2c gui --batch` as v1-required.
  - `254afa9` resolved the CI logging question.
- Consensus from galaxy, jungle, test-agent, and me: `c2c gui --batch` should be v1 scope as a no-display JSON snapshot / smoke path, not a full operator dashboard.
- Remaining GUI blockers called out in the doc: restart Direction B / managed-session lifecycle, relay auth, `c2c init` non-interactive onboarding, MCP JSON-RPC surface audit, and clean app exit without stranded managed sessions.

### Class E / Shell Substitution Warning

- Class E had review churn while you were away.
- Stanza found the earlier coord-as-peer pass missed plain backticks and then later found a squash lost tests.
- test-agent eventually peer-PASSed `fb18db4` on `fix/class-e-shell-subst-warn-lyra`; it fixes the escaped-backslash handling and covers the requested five cases.
- There is also `1263977` on that branch for Python fallback removal per galaxy's status message.
- This still needs final coordinator review/merge state confirmation.

### Codex Heartbeat

- Max reported Codex agents lacked automatic heartbeats; I filed `.collab/findings/2026-04-25T08-19-24Z-lyra-quill-problems-log.md`.
- Implemented first slice in `.worktrees/codex-heartbeat`.
- Final SHA: `b417e1f fix(codex): restrict heartbeat to normal codex`.
- Behavior at `b417e1f`:
  - Normal `codex` managed sessions get a broker-inbox heartbeat every 240s.
  - The heartbeat uses `Broker.enqueue_message`, so delivery follows the same inbox transport as ordinary c2c messages.
  - `codex-headless` is excluded by default after reviewer feedback because the headless XML path can create/persist a first thread.
  - Heartbeat starts only when the Codex deliver daemon started (`deliver_pid` present).
- Peer review status:
  - Rawls caught the codex-headless issue on `5bfb1a7`.
  - Pauli PASSed `b417e1f`.
  - jungle PASSed `b417e1f`.
  - galaxy PASSed `b417e1f`.
  - test-agent PASSed `b417e1f`.
- Verification:
  - Focused tests `ocaml/test/test_c2c_start.exe -- test launch_args 11-14` passed.
  - Earlier focused build passed before the final gating commit.
  - One later Dune watchdog run hung with no output; treated as infra, not code-specific.
  - Full `test_c2c_start` had a known unrelated reset-thread failure on the base.

### New Max Request: General Managed Heartbeats

Max expanded the heartbeat requirement after the Codex-only slice:

- Enable heartbeats for all coding CLIs, not just Codex.
- Provide a default heartbeat message configurable in config.
- Support per-agent override from role files.
- Support multiple per-agent heartbeats at different frequencies.
- Examples:
  - coordinator hourly sitrep heartbeat.
  - coordinator 20-minute idle-team check heartbeat.
  - optional command execution attached to a heartbeat, e.g. API usage quota sent to coordinator every 15 minutes.

I announced the design thread in `swarm-lounge` and began inspecting `C2c_role` and `C2c_start` structures. No generalized-heartbeat implementation has been committed yet. Recommended next move is to create a new branch from `b417e1f` (or coordinator-approved base), write a short design, then implement with tests.

## Open Routing

- If you want the Codex-only heartbeat landed independently, review/merge `b417e1f` first.
- If you prefer to supersede it with generalized configurable heartbeats, use `b417e1f` as the proven transport/gating base and continue on a new branch.
- GUI requirements doc is ready for your coord review on `docs/gui-requirements`.
- Class E final status likely needs your review/merge decision unless it already landed while I was offline.
