# Claude E2E Test Blocked: Interactive Startup Prompts

**Date**: 2026-04-23
**Author**: Lyra-Quill
**Status**: blocked — not feasible without PTY injection or startup flag

## Symptom

`test_claude_smoke_send_receive` times out during `wait_for_init`. The tmux pane starts but the inner Claude process never fully initializes — `inner.pid` exists but the process is dead within seconds.

## Root Cause

`c2c start claude` launches an interactive Claude Code session that requires TWO TTY prompts before the MCP server starts:

1. **Workspace trust prompt**: "Is this a project you created or one you trust?"
2. **Development channels warning**: "I am using this for local development / Exit"

Even with `--auto` and pre-seeded role files, these prompts block startup because:
- `--auto` skips the role prompt but NOT the trust prompt
- The trust prompt reads the actual working directory and has no non-interactive bypass flag
- Claude Code has no `--trust-directory` or `--no-prompt` startup flag

The inner Claude process (PID from `inner.pid`) starts, immediately encounters the trust prompt on its stdin, and since the tmux pane has no attached stdin for interactive answering, it hangs and eventually exits.

## What Doesn't Work

1. **`claude -p`** — skips the trust dialog per docs, but is a one-shot print mode that exits immediately. No persistent session to register with broker.

2. **`skipDangerousModePermissionPrompt: true`** — skips the development channels warning only, not the workspace trust dialog.

3. **Pre-seeding role files** — only bypasses the role prompt (which `--auto` already skips). Does not affect the trust prompt.

4. **Project settings in `~/.claude/projects/`** — the trust prompt reads the actual cwd on disk; there's no `trustedDirectories` global setting. The pytest workdir is under `/tmp/pytest-of-xertrov/...` which is not a registered Claude project.

5. **`--dangerously-skip-permissions`** — bypasses permission checks during session, not the startup trust dialog.

## Feasibility Assessment

- **PTY injection for prompts**: Would work — feed "1\n1\n" to dismiss both prompts. Same approach used for Codex and Claude wake daemons. But this is non-trivial to implement correctly in the test harness.
- **Startup flag**: Claude Code has no `--trust-workspace` or equivalent flag. Would need an upstream Claude Code change.
- **`claude -p` with broker registration**: If `-p` mode could somehow register with the broker before exiting, it would work for a DM send/receive cycle. But `-p` mode doesn't run the full startup loop where broker registration happens.

## Impact

Claude adapter E2E smoke test cannot be implemented without either:
1. PTY injection harness to drive the two startup prompts
2. Claude Code adding a non-interactive startup mode

## Alternative Path

Kimi adapter may be cleaner to smoke-test — the OCaml wire daemon (`c2c_wire_bridge`) has no interactive TTY prompts. Galaxy-coder is actively working on the OCaml wire daemon. Once that's confirmed working, a Kimi smoke test would validate the same delivery path without the startup prompt complexity.

## References

- `tests/e2e/framework/client_adapters.py` — `ClaudeAdapter` (scaffolded, not working)
- `tests/test_c2c_claude_e2e.py` — smoke test (BLOCKED)
- `tests/test_c2c_opencode_e2e.py` — working OpenCode smoke test for comparison
- AGENTS.md § "Testing against live agents: use tmux + scripts/*"
