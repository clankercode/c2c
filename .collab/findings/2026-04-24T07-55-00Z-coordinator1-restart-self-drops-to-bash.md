# Finding: `./restart-self` drops coordinator back to bash instead of re-launching Claude Code

- **Agent**: coordinator1 (Cairn-Vigil)
- **Timestamp**: 2026-04-24T07:55Z
- **Severity**: medium (blocks coordinator restart-in-place after binary upgrades; workaround = relaunch in new tmux pane)
- **Component**: `./restart-self` script + Claude Code harness

## Symptom

After `just install-all` landed new c2c + mcp-server binaries for #135 (channel-push force-cap fix), coordinator1 attempted `./restart-self` to pick up the fix on the live coordinator session. Instead of re-launching Claude Code with a fresh MCP server (and the new `C2C_MCP_FORCE_CAPABILITIES=claude_channel` env var), the session dropped to a bash prompt. The Claude Code TUI did not come back up.

Max confirmed: "restart-self didn't work by the way, you dropped back to bash".

## Impact

- Coordinator-class sessions cannot safely pick up binary changes without a full relaunch via `c2c start claude -n coordinator1` in a new tmux pane — the drop-to-bash means the original session is lost and the operator has to restart it manually.
- This defeats the CLAUDE.md workflow of "commit → install → restart-self → verify" for the single most important class of session in the swarm.
- For #135 specifically, this meant coordinator1's MCP env still lacked `C2C_MCP_FORCE_CAPABILITIES`, so channel-push couldn't be validated on the coordinator without a relaunch.

## Root cause (hypothesis)

`restart-self` likely `exec`s a re-launch command, but the harness claude was originally started under (probably a direct `claude` invocation, not `c2c start claude`) doesn't re-enter cleanly. The parent process exits, the TUI tears down, and whatever shell spawned the session sees the child exit and returns to the prompt. CLAUDE.md already warns: "restart-self hasn't been proven across every harness — verify it works in your context before relying on it".

Confirmed NOT a harness that restart-self works in: whatever coordinator1 was started from (2026-04-24 session).

## Workaround

For coordinator-class sessions: relaunch in a new tmux pane via `c2c start claude -n coordinator1` and let the old session's state (monitors, context) die naturally. Restore state from the `restart_state_*.md` memory file.

Never rely on restart-self for the coordinator session when the swarm is mid-work — the drop-to-bash is a hard failure mode.

## Proposed fix (not yet implemented)

1. `restart-self` should detect which harness launched the session and use the matching re-entry pattern. If the harness can't be detected, refuse with a clear error ("restart-self cannot safely restart this session; relaunch manually via `c2c start claude`") instead of exec'ing a command that drops to bash.
2. The `c2c start <client>` path should tag managed sessions with an env var (e.g. `C2C_LAUNCH_MODE=managed`) that restart-self checks for. Only attempt in-place restart when it's set.
3. Long-term: restart-self should be the primary mechanism for binary-upgrade pickup, but the current "unknown harness support" caveat makes it unsafe as the default. Either narrow its scope to managed sessions, or replace with a clearer "relaunch in pane X" tooling.
