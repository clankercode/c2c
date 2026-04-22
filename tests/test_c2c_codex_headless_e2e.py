"""Live Codex-headless smoke tests on the shared terminal E2E framework."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
BRIDGE_BIN = shutil.which("codex-turn-start-bridge")
CODEX_BIN = shutil.which("codex")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_CODEX_HEADLESS_E2E") != "1"
    or not TMUX_BIN
    or not BRIDGE_BIN
    or not CODEX_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_CODEX_HEADLESS_E2E=1 and ensure "
        "tmux/codex-turn-start-bridge/codex/c2c are on PATH"
    ),
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


def _instance_dir(alias: str) -> Path:
    return Path.home() / ".local" / "share" / "c2c" / "instances" / alias


def _load_instance_config(alias: str) -> dict[str, object] | None:
    path = _instance_dir(alias) / "config.json"
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def _persisted_thread_id(alias: str) -> str | None:
    cfg = _load_instance_config(alias)
    if not cfg:
        return None
    value = cfg.get("resume_session_id")
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def test_codex_headless_bridge_startup_smoke(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.xfail_unless(
        "codex_headless_thread_id_fd",
        reason="updated codex-turn-start-bridge with --thread-id-fd not present yet",
    )

    alias = f"codex-headless-{_unique_suffix()}"
    _write_role_file(scenario.workdir, alias)

    agent = scenario.start_agent("codex-headless", name=alias)
    scenario.wait_for_init(agent, timeout=90.0)
    scenario.wait_for(lambda: _registered(agent, scenario), timeout=60.0)

    scenario.assert_agent(agent).alive()
    scenario.assert_agent(agent).registered_alive()

    cmdline = scenario.managed_inner_cmdline(agent)
    assert "codex-turn-start-bridge" in cmdline
    assert "--stdin-format xml" in cmdline
    assert "--thread-id-fd" in cmdline


def test_codex_headless_xml_delivery_persists_thread_id(scenario: Scenario) -> None:
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.xfail_unless(
        "codex_headless_thread_id_fd",
        reason="updated codex-turn-start-bridge with --thread-id-fd not present yet",
    )

    suffix = _unique_suffix()
    alias = f"codex-headless-xml-{suffix}"
    sender_alias = f"codex-headless-sender-{suffix}"
    _write_role_file(scenario.workdir, alias)
    _write_role_file(scenario.workdir, sender_alias)

    agent = scenario.start_agent("codex-headless", name=alias)
    sender = scenario.start_agent("codex-headless", name=sender_alias)
    scenario.wait_for_init(agent, sender, timeout=90.0)
    scenario.wait_for(
        lambda: _registered(agent, scenario) and _registered(sender, scenario),
        timeout=60.0,
    )

    message = f"headless-xml-ping-{_unique_suffix()}"
    scenario.send_dm(sender, agent, message)
    scenario.wait_for(
        lambda: not scenario.broker_inbox_contains(agent, message)
        and _persisted_thread_id(alias) is not None,
        timeout=90.0,
    )

    thread_id = _persisted_thread_id(alias)
    assert thread_id is not None
    assert thread_id != alias
