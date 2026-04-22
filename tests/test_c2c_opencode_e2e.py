"""Live OpenCode smoke tests on the shared terminal E2E framework."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.e2e.framework.client_adapters import compile_role
from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
OPENCODE_BIN = shutil.which("opencode")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_OPENCODE_E2E") != "1"
    or not TMUX_BIN
    or not OPENCODE_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_OPENCODE_E2E=1 and ensure "
        "tmux/opencode/c2c are on PATH"
    ),
)

_unique_suffix_counter = 0


def _unique_suffix() -> str:
    global _unique_suffix_counter
    _unique_suffix_counter += 1
    return f"{os.getpid()}-{_unique_suffix_counter}"


def _registered(agent: object, scenario: Scenario) -> bool:
    registry = scenario.broker_root() / "registry.json"
    if not registry.exists():
        return False
    try:
        registrations = json.loads(registry.read_text(encoding="utf-8") or "[]")
        rows = registrations if isinstance(registrations, list) else registrations.get("registrations", [])
        for row in rows:
            if row.get("alias") == agent.name and row.get("alive") is not False:
                return True
    except Exception:
        pass
    return False


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "c2c test"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "c2c-test@example.invalid"], cwd=path, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path, check=True)


def _create_opencode_json(workdir: Path, broker_root: Path) -> None:
    """Create .opencode/opencode.json so c2c start opencode doesn't prompt.

    Uses the same JSON structure that 'c2c install opencode' writes, so OpenCode's
    c2c plugin accepts it. The 'c2c start opencode' flow calls 'c2c install
    opencode' (Tier 2, non-interactive) which would create this file, but only
    when the server binary is reachable from CWD (needs _build/ or OPAM_SWITCH_PREFIX).
    Pre-creating with the correct format bypasses the install call and avoids a
    broken-server-path config that OpenCode would reject.
    """
    mcp_bin = shutil.which("c2c-mcp-server")
    if not mcp_bin:
        mcp_bin = "/home/xertrov/.local/bin/c2c-mcp-server"
    oc_dir = workdir / ".opencode"
    oc_dir.mkdir(parents=True, exist_ok=True)
    c2c_bin = shutil.which("c2c") or "/home/xertrov/.local/bin/c2c"
    config = {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {
            "c2c": {
                "type": "local",
                "command": ["opam", "exec", "--", mcp_bin],
                "environment": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                    "C2C_CLI_COMMAND": c2c_bin,
                },
                "enabled": True,
            }
        },
    }
    (oc_dir / "opencode.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def _write_role_file(workdir: Path, alias: str) -> None:
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    (roles_dir / f"{alias}.md").write_text("test-agent\n", encoding="utf-8")


def test_opencode_smoke_send_receive(scenario: Scenario) -> None:
    """Launch two OpenCode instances, send a DM from one to the other, verify receipt."""
    _init_git_repo(scenario.workdir)
    _create_opencode_json(scenario.workdir, scenario.broker_root())
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    sender_alias = f"oc-sender-{suffix}"
    receiver_alias = f"oc-receiver-{suffix}"

    _write_role_file(scenario.workdir, sender_alias)
    _write_role_file(scenario.workdir, receiver_alias)
    sender = scenario.start_agent("opencode", name=sender_alias)
    receiver = scenario.start_agent("opencode", name=receiver_alias)

    scenario.wait_for_init(sender, receiver, timeout=90.0)
    scenario.wait_for(
        lambda: _registered(sender, scenario) and _registered(receiver, scenario),
        timeout=60.0,
    )

    scenario.assert_agent(sender).alive()
    scenario.assert_agent(receiver).alive()
    scenario.assert_agent(receiver).registered_alive()

    message = f"opencode-e2e-ping-{suffix}"
    scenario.send_dm(sender, receiver, message)

    scenario.wait_for(
        lambda: scenario.broker_inbox_contains(receiver, message),
        timeout=90.0,
    )


def test_opencode_smoke_with_agent(scenario: Scenario) -> None:
    """Launch OpenCode with --agent flag, verify compiled role file is picked up.

    AC:
    - C2C_TEST_OPENCODE_E2E=1 pytest ...::test_opencode_smoke_with_agent passes
    - Role file is generated at .opencode/agents/<name>.md before client startup
    - Test is capability-gated (skip if opencode binary absent)
    """
    _init_git_repo(scenario.workdir)
    _create_opencode_json(scenario.workdir, scenario.broker_root())
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    agent_alias = f"oc-agent-{suffix}"
    agent_file = scenario.workdir / ".opencode" / "agents" / f"{agent_alias}.md"

    compile_role(scenario.workdir, agent_alias, "opencode")
    assert agent_file.exists(), f"compiled role not found at {agent_file}"

    agent = scenario.start_agent("opencode", name=agent_alias, role=agent_alias)

    scenario.wait_for_init(agent, timeout=90.0)

    scenario.wait_for(
        lambda: _registered(agent, scenario),
        timeout=60.0,
    )

    scenario.assert_agent(agent).alive()
    scenario.assert_agent(agent).registered_alive()
