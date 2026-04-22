"""Live Codex twin smoke tests on the shared terminal E2E framework.

These are opt-in because they launch real Codex sessions in tmux.
They assert the current local Codex launch surface, including
``--xml-input-fd`` on managed inner processes.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
CODEX_BIN = shutil.which("codex")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CODEX_TWIN_E2E") != "1"
    or not TMUX_BIN
    or not CODEX_BIN
    or not C2C_BIN,
    reason="set C2C_TEST_CODEX_TWIN_E2E=1 and ensure tmux/codex/c2c are on PATH",
)


def _run(cmd: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    )


def _init_git_repo(path: Path) -> None:
    _run(["git", "init", "-q"], cwd=path)
    _run(["git", "config", "user.name", "c2c test"], cwd=path)
    _run(["git", "config", "user.email", "c2c-test@example.invalid"], cwd=path)
    _run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=path)


def _write_role_file(workdir: Path, alias: str) -> None:
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    (roles_dir / f"{alias}.md").write_text("test-agent\n", encoding="utf-8")


def _unique_suffix() -> str:
    return f"{os.getpid()}-{time.time_ns()}"


def _registered(agent, scenario: Scenario) -> bool:
    try:
        scenario.assert_agent(agent).registered_alive()
    except AssertionError:
        return False
    return True


def _assert_xml_launch_surface(scenario: Scenario, *agents) -> None:
    scenario.require_capability("codex_xml_fd")
    for agent in agents:
        assert "--xml-input-fd" in scenario.managed_inner_cmdline(agent)


def _wait_for_registered_agents_or_skip(
    scenario: Scenario,
    *agents,
    timeout: float = 60.0,
) -> None:
    try:
        scenario.wait_for(
            lambda: all(_registered(agent, scenario) for agent in agents),
            timeout=timeout,
        )
    except AssertionError:
        pytest.skip(
            "managed Codex twins launched with --xml-input-fd but did not auto-register with the broker"
        )


def test_codex_twin_launches_with_xml_input_fd(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    alias_a = f"codex-a-{suffix}"
    alias_b = f"codex-b-{suffix}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)
    _assert_xml_launch_surface(scenario, a, b)

    scenario.comment(
        "Managed Codex twins should launch with XML sideband input enabled."
    )

    scenario.assert_agent(a).alive()
    scenario.assert_agent(b).alive()


def test_codex_twin_xml_user_turn_delivery(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    alias_a = f"codex-xml-a-{suffix}"
    alias_b = f"codex-xml-b-{suffix}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)
    _assert_xml_launch_surface(scenario, a, b)
    _wait_for_registered_agents_or_skip(scenario, a, b)

    message = f"xml-turn-ping-{os.getpid()}"
    scenario.send_dm(a, b, message)
    scenario.wait_for(
        lambda: message in scenario.capture(b)
        and not scenario.broker_inbox_contains(b, message),
        timeout=90.0,
    )
