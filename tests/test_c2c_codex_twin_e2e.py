"""Live Codex twin smoke tests on the shared terminal E2E framework.

These are opt-in because they launch real Codex sessions in tmux.
"""
from __future__ import annotations

import os
import shutil
import subprocess
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


def test_codex_twin_fallback_notify_path(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    alias_a = f"codex-a-{os.getpid()}"
    alias_b = f"codex-b-{os.getpid()}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)

    scenario.comment(
        "Stock Codex should still be launchable, broker-alive, and able to accept fallback inbox traffic."
    )
    message = f"fallback-ping-{os.getpid()}"
    scenario.send_dm(a, b, message)
    scenario.wait_for(
        lambda: scenario.broker_inbox_contains(b, message),
        timeout=20.0,
    )

    scenario.assert_agent(a).registered_alive()
    scenario.assert_agent(b).registered_alive()


def test_codex_twin_xml_user_turn_delivery(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.xfail_unless(
        "codex_xml_fd",
        reason="updated Codex binary with --xml-input-fd not present yet",
    )

    alias_a = f"codex-xml-a-{os.getpid()}"
    alias_b = f"codex-xml-b-{os.getpid()}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)

    message = f"xml-turn-ping-{os.getpid()}"
    scenario.send_dm(a, b, message)
    scenario.wait_for(lambda: message in scenario.capture(b), timeout=90.0)
