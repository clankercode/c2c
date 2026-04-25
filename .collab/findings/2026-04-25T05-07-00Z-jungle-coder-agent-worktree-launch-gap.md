# Agent worktree launch gap

## Finding
Agents cannot `cd` themselves into their assigned worktree because `cwd` is fixed at session launch. When an agent is told "switch to your worktree at `.c2c/worktrees/jungle-coder`", they cannot do it from within their current session — `cd` doesn't change the persistent working directory.

## Impact
- Agents are assigned worktrees but remain "stuck" in the main tree
- The branch name in main tree becomes unreliable (test-agent, stanza, etc. switch in/out)
- Cannot self-recover from being in the wrong tree without external intervention

## Root Cause
OpenCode/Claude Code sessions have a fixed working directory at launch time. `cd` in a subprocess doesn't affect the parent shell's cwd.

## Fix (should be in #165)
`c2c start <agent>` should launch agents in the correct worktree directory, not just assign them one. The launch command needs to `cd` to the worktree before starting the CLI harness.

## Discovery
2026-04-25, jungle-coder told to switch to `.c2c/worktrees/jungle-coder` but `cd` within session doesn't work.
