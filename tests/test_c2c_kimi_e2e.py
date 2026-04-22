"""Live Kimi smoke tests on the shared terminal E2E framework."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
KIMI_BIN = shutil.which("kimi")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_KIMI_E2E") != "1"
    or not TMUX_BIN
    or not KIMI_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_KIMI_E2E=1 and ensure "
        "tmux/kimi/c2c are on PATH"
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
    import json

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


def test_kimi_smoke_send_receive(scenario: Scenario) -> None:
    """Launch two Kimi instances, send a DM from one to the other, verify receipt."""
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    sender_alias = f"kimi-sender-{suffix}"
    receiver_alias = f"kimi-receiver-{suffix}"

    _write_role_file(scenario.workdir, sender_alias)
    _write_role_file(scenario.workdir, receiver_alias)

    sender = scenario.start_agent("kimi", name=sender_alias, auto=True)
    receiver = scenario.start_agent("kimi", name=receiver_alias, auto=True)

    scenario.wait_for_init(sender, receiver, timeout=120.0)
    scenario.wait_for(
        lambda: _registered(sender, scenario) and _registered(receiver, scenario),
        timeout=60.0,
    )

    scenario.assert_agent(sender).alive()
    scenario.assert_agent(receiver).alive()
    scenario.assert_agent(receiver).registered_alive()

    message = f"kimi-e2e-ping-{suffix}"
    scenario.send_dm(sender, receiver, message)

    scenario.wait_for(
        lambda: scenario.broker_inbox_contains(receiver, message),
        timeout=90.0,
    )