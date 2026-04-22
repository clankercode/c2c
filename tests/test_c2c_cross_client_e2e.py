"""Cross-client live E2E tests: OpenCode ↔ Kimi DM parity.

This is the first test proving cross-client messaging parity — a north-star
milestone. Tests both directions:
  1. OpenCode → Kimi  (OpenCode uses promptAsync delivery, Kimi uses PTY inject)
  2. Kimi → OpenCode (Kimi uses PTY inject, OpenCode uses promptAsync delivery)

Capability-gated: requires C2C_TEST_CROSS_CLIENT=1.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
OPENCODE_BIN = shutil.which("opencode")
KIMI_BIN = shutil.which("kimi")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CROSS_CLIENT") != "1"
    or not TMUX_BIN
    or not OPENCODE_BIN
    or not KIMI_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_CROSS_CLIENT=1 and ensure "
        "tmux/opencode/kimi/c2c are on PATH"
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


def _write_role_file(workdir: Path, alias: str) -> None:
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    (roles_dir / f"{alias}.md").write_text("test-agent\n", encoding="utf-8")


def _create_opencode_json(workdir: Path, broker_root: Path) -> None:
    """Create .opencode/opencode.json so c2c start opencode doesn't prompt.

    The OCaml c2c binary calls `c2c install opencode` (a Tier 3 command) when
    .opencode/opencode.json is missing. Since Tier 3 commands are hidden from
    agent sessions, the call silently fails and the interactive "Run it now?"
    prompt blocks startup. Pre-creating the file bypasses this.
    """
    mcp_bin = shutil.which("c2c-mcp-server")
    if not mcp_bin:
        mcp_bin = str(Path(__file__).resolve().parents[1] / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe")
    oc_dir = workdir / ".opencode"
    oc_dir.mkdir(parents=True, exist_ok=True)
    config = {
        "mcp": {
            "c2c": {
                "type": "stdio",
                "command": [mcp_bin],
                "env": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                },
            }
        }
    }
    (oc_dir / "opencode.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def test_cross_client_opencode_kimi(scenario: Scenario) -> None:
    """Launch OpenCode and Kimi, exchange DMs both directions, verify delivery.

    Direction 1: OpenCode → Kimi
      - OpenCode uses promptAsync delivery (TypeScript plugin)
      - Kimi receives via PTY injection from deliver daemon

    Direction 2: Kimi → OpenCode
      - Kimi uses PTY injection from deliver daemon
      - OpenCode receives via promptAsync (TypeScript plugin)

    Both directions must succeed to prove cross-client parity.
    """
    _init_git_repo(scenario.workdir)
    _create_opencode_json(scenario.workdir, scenario.broker_root())
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    opencode_alias = f"oc-{suffix}"
    kimi_alias = f"kimi-{suffix}"

    _write_role_file(scenario.workdir, kimi_alias)
    _write_role_file(scenario.workdir, opencode_alias)
    opencode_agent = scenario.start_agent("opencode", name=opencode_alias)
    kimi_agent = scenario.start_agent("kimi", name=kimi_alias, auto=True)

    scenario.wait_for_init(opencode_agent, kimi_agent, timeout=120.0)
    scenario.wait_for(
        lambda: _registered(opencode_agent, scenario) and _registered(kimi_agent, scenario),
        timeout=60.0,
    )

    scenario.assert_agent(opencode_agent).alive()
    scenario.assert_agent(kimi_agent).alive()
    scenario.assert_agent(opencode_agent).registered_alive()
    scenario.assert_agent(kimi_agent).registered_alive()

    msg_oc_to_kimi = f"oc-to-kimi-{suffix}"
    scenario.send_dm(opencode_agent, kimi_agent, msg_oc_to_kimi)
    scenario.wait_for(
        lambda: scenario.broker_inbox_contains(kimi_agent, msg_oc_to_kimi),
        timeout=90.0,
    )

    msg_kimi_to_oc = f"kimi-to-oc-{suffix}"
    scenario.send_dm(kimi_agent, opencode_agent, msg_kimi_to_oc)
    scenario.wait_for(
        lambda: scenario.broker_inbox_contains(opencode_agent, msg_kimi_to_oc),
        timeout=90.0,
    )
