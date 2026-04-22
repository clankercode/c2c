# e2e Harness: OpenCode smoke test plan

**Date**: 2026-04-23
**Author**: Lyra-Quill
**Status**: completed (OpenCode), in_progress (Claude)

## Background

The terminal E2E framework (`tests/e2e/framework/`) provides a `Scenario` class
that orchestrates launching agents in tmux panes, waiting for them to register,
sending DMs, and asserting delivery. It has adapters for `codex` and `codex-headless`
but none for `opencode`.

## Goal

Add a minimal smoke test: launch two OpenCode instances, send a DM from one to the
other, verify the message appears in the recipient's inbox.

## Why OpenCode first

OpenCode's delivery path is the most deterministic:
- `c2c.ts` plugin uses `promptAsync` for inbox delivery (TypeScript, testable)
- No PTY injection needed for delivery — the plugin polls broker inbox and
  injects via `promptAsync`
- The `opencode` binary is consistently available on the test machine
- Ready detection is simple: inner.pid exists + process alive + broker registered

Claude Code requires PTY injection to wake idle TUI. Codex headless requires
`codex-turn-start-bridge` binary. Kimi requires Wire bridge.

## Adapter interface

Each adapter must implement:

```python
class Adapter(Protocol):
    client_name: str
    default_backend: str

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        """Return dict with keys: command, cwd, env, title"""

    def is_ready(self, scenario: Scenario, agent: StartedAgent) -> bool:
        """Return True when the agent is fully initialized and registered"""

    def probe_capabilities(self, scenario: Scenario | None) -> dict[str, bool]:
        """Return capability flags for capability-gated tests"""
```

## OpenCodeAdapter design

```python
class OpenCodeAdapter:
    client_name = "opencode"
    default_backend = "tmux"

    def build_launch(self, scenario, config):
        return {
            "command": ["c2c", "start", "opencode", "-n", config.name],
            "cwd": scenario.workdir,
            "env": dict(config.env),
            "title": config.name,
        }

    def is_ready(self, scenario, agent):
        # 1. tmux pane alive
        if not scenario.drivers[agent.backend].is_alive(agent.handle):
            return False
        # 2. inner.pid exists and process alive
        inner_pid_path = _instance_dir(agent.name) / "inner.pid"
        if not _has_live_pid(inner_pid_path):
            return False
        return True

    def probe_capabilities(self, scenario):
        return {"opencode_binary": shutil.which("opencode") is not None}
```

## Test design

```
test_opencode_smoke (env var: C2C_TEST_OPENCODE_E2E=1)

1. scenario.start_agent("opencode", name="oc-sender-<suffix>")
2. scenario.start_agent("opencode", name="oc-receiver-<suffix>")
3. scenario.wait_for_init(timeout=90s)
4. scenario.wait_for(lambda: _registered(receiver, scenario), timeout=60s)
5. scenario.assert_agent(receiver).registered_alive()
6. message = f"opencode-e2e-ping-{suffix}"
7. scenario.send_dm(sender, receiver, message)
8. scenario.wait_for(lambda: scenario.broker_inbox_contains(receiver, message), timeout=60s)
9. teardown via _cleanup_scenario_agents
```

## Capability gating

```python
pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_OPENCODE_E2E") != "1"
    or shutil.which("opencode") is None
    or shutil.which("tmux") is None,
    reason="set C2C_TEST_OPENCODE_E2E=1 and ensure opencode/tmux are on PATH"
)
```

## What each client needs (comparison)

| Client | Launch cmd | Delivery path | Input injection | Key challenge |
|--------|-----------|---------------|----------------|---------------|
| OpenCode | `c2c start opencode -n X` | promptAsync (TS) | promptAsync | none — TS plugin is deterministic |
| Claude Code | `c2c start claude -n X` | PTY inject | PTY inject | PTY inject requires ptrace/cap |
| Kimi | `c2c start kimi -n X` | Wire bridge | Wire prompt | Wire bridge binary |
| Codex | `c2c start codex -n X` | PTY inject | PTY inject | PTY inject |
| Codex-headless | `c2c start codex-headless -n X` | XML FIFO | XML FIFO | bridge binary |

## Next steps after OpenCode

1. **Claude Code**: needs `c2c_claude_wake_daemon` running for idle delivery,
   or PTY injection sentinel. Hardest due to PTY requirements.
2. **Kimi**: needs `c2c_kimi_wire_bridge` running. Medium — Wire protocol
   is JSON-RPC but requires daemon.
3. **Codex**: similar to Claude Code — PTY injection for delivery.

OpenCode is the simplest path to a passing multi-client E2E test.

## ClaudeAdapter design

```python
class ClaudeAdapter:
    client_name = "claude"
    default_backend = "tmux"

    def build_launch(self, scenario, config):
        return {
            "command": ["c2c", "start", "claude", "-n", config.name],
            "cwd": scenario.workdir,
            "env": dict(config.env),
            "title": config.name,
        }

    def is_ready(self, scenario, agent):
        if not scenario.drivers[agent.backend].is_alive(agent.handle):
            return False
        return _has_live_pid(_instance_dir(agent.name) / "inner.pid")

    def probe_capabilities(self, scenario):
        return {"claude_binary": shutil.which("claude") is not None}
```

## Claude smoke test design

```
test_claude_smoke_send_receive (env var: C2C_TEST_CLAUDE_E2E=1)

1. scenario.start_agent("claude", name="claude-sender-<suffix>")
2. scenario.start_agent("claude", name="claude-receiver-<suffix>")
3. scenario.wait_for_init(timeout=120s)  — Claude is slower to start
4. scenario.wait_for(lambda: _registered(receiver, scenario), timeout=60s)
5. scenario.assert_agent(receiver).registered_alive()
6. message = f"claude-e2e-ping-{suffix}"
7. scenario.send_dm(sender, receiver, message)
8. scenario.wait_for(lambda: scenario.broker_inbox_contains(receiver, message), timeout=90s)
9. teardown via _cleanup_scenario_agents
```

Delivery path for Claude Code:
- Active session (between tool calls): PostToolUse hook → broker inbox poll → injected as `<c2c>` tag
- Idle gap: PTY wake via `c2c_claude_wake_daemon` or PTY injection sentinel
- The smoke test sends DMs via broker controller (no PTY needed for send), but recipient
  needs to be awake to poll inbox. The PostToolUse hook handles delivery when the
  recipient is actively processing tool calls.