# Claude E2E Test Blocked: Interactive Startup Prompts

**Date**: 2026-04-23
**Author**: Lyra-Quill
**Status**: closed — upstream limitation (Anthropic)

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

2. **`skipDangerousModePermissionPrompt: true` in `~/.claude/settings.json`** — skips the development channels warning only, not the workspace trust dialog.

3. **Pre-seeding role files** — only bypasses the role prompt (which `--auto` already skips). Does not affect the trust prompt.

4. **Project settings in `~/.claude/projects/<slug>/.claude.settings.json`** — the trust prompt reads the actual cwd on disk, not project metadata. No `trustedDirectories` or `hasCompletedOnboarding` field bypasses it.

5. **`.claude/settings.json` in the workdir** — created `workdir/.claude/settings.json` with `skipDangerousModePermissionPrompt: true` and `permissions.defaultMode: bypassPermissions`; trust prompt still appeared.

6. **`--dangerously-skip-permissions`** — bypasses permission checks during session, not the startup trust dialog.

7. **`--bare`** — skips hooks, LSP, plugins, attribution, and auto-memory, but still shows the trust prompt.

## Feasibility Assessment

The ONLY viable path is PTY injection: feed "1\n1\n" to dismiss the trust prompt and development channels prompt. This is the same technique used by `c2c_claude_wake_daemon` for idle-gap waking. However, implementing this correctly in the E2E test harness is non-trivial and the effort is not justified when Kimi + OpenCode already provide E2E coverage.

## Resolution

**Closed as upstream limitation.** To fully unblock, Claude Code would need one of:
- `--trust-workspace` / `--no-trust-prompt` flag
- `trustedDirectories: ["/tmp/pytest-of-xrtrov"]` in project settings
- A way for `-p` mode to run the MCP broker registration loop before exiting

Filing to Anthropic as a feature request for non-interactive / CI-friendly startup mode.

## Current Coverage

With Kimi (0a7389b) and OpenCode (cddc1ad) E2E smoke tests passing, we have broker and delivery path coverage for two clients. Claude Code E2E testing would require PTY injection work that is not justified at this time.

## References

- `tests/e2e/framework/client_adapters.py` — `ClaudeAdapter` (scaffolded, not working)
- `tests/test_c2c_claude_e2e.py` — smoke test (BLOCKED)
- `tests/test_c2c_opencode_e2e.py` — working OpenCode smoke test for comparison
- AGENTS.md § "Testing against live agents: use tmux + scripts/*"
