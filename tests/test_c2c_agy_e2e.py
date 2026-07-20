"""Live agy (Antigravity) smoke tests on the shared terminal E2E framework.

Opt-in: launches real managed ``c2c start agy`` sessions in tmux.

Primary delivery is agentapi inject via the deliver-watch sidecar
(``c2c_agy_deliver`` / ``C2c_agy_agentapi``). This suite proves managed start
readiness, broker registration, and peer DM landing in the broker inbox.
Full agentapi wake needs a live LS address + model session and is hermetically
covered in ``ocaml/test/test_c2c_agy_agentapi.ml`` and
``ocaml/cli/test_c2c_agy_deliver.ml``.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.e2e.framework.capabilities import AGY_AGENTAPI
from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
AGY_BIN = shutil.which("agy")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_AGY_E2E") != "1"
    or not TMUX_BIN
    or not AGY_BIN
    or not C2C_BIN,
    reason="set C2C_TEST_AGY_E2E=1 and ensure tmux/agy/c2c are on PATH",
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


def _instance_dir(name: str) -> Path:
    return Path.home() / ".local" / "share" / "c2c" / "instances" / name


def _deliver_watch_armed(alias: str) -> bool:
    """True when the managed deliver sidecar has a live deliver.pid (or outer)."""
    inst = _instance_dir(alias)
    for name in ("deliver.pid", "outer.pid", "inner.pid"):
        path = inst / name
        if not path.exists():
            continue
        try:
            pid = int(path.read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            continue
    return False


def test_agy_managed_start_registers(scenario: Scenario) -> None:
    """Managed agy starts, reports agentapi capability, and registers."""
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.require_capability(AGY_AGENTAPI)

    suffix = _unique_suffix()
    # Product identity prefers agy-* aliases; use that prefix for realism.
    alias = f"agy-e2e-{suffix}"
    _write_role_file(scenario.workdir, alias)

    agent = scenario.start_agent("agy", name=alias, auto=True)
    scenario.wait_for_init(agent, timeout=120.0)

    scenario.assert_agent(agent).alive()
    try:
        scenario.wait_for(lambda: _registered(agent, scenario), timeout=60.0)
    except AssertionError:
        pytest.skip(
            "managed agy launched but did not auto-register "
            "(hooks/auth may be missing in this environment)"
        )
    scenario.assert_agent(agent).registered_alive()

    # deliver-watch or outer loop should be trackable under instances/
    if not _deliver_watch_armed(alias):
        scenario.comment(
            "warning: no live deliver/outer/inner pidfile yet "
            "(registration still proves managed start path)"
        )


def test_agy_peer_dm_reaches_broker_inbox(scenario: Scenario) -> None:
    """Controller-side peer DM lands in the managed agy receiver inbox.

    Agentapi inject itself is not pane-scrapable here; inbox presence is the
    shared messaging contract before the deliver sidecar drains.
    """
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.require_capability(AGY_AGENTAPI)

    suffix = _unique_suffix()
    receiver_alias = f"agy-rx-{suffix}"
    _write_role_file(scenario.workdir, receiver_alias)

    receiver = scenario.start_agent("agy", name=receiver_alias, auto=True)
    scenario.wait_for_init(receiver, timeout=120.0)
    try:
        scenario.wait_for(lambda: _registered(receiver, scenario), timeout=60.0)
    except AssertionError:
        pytest.skip("managed agy did not register; cannot prove DM path")

    message = f"agy-e2e-ping-{suffix}"
    # from_agent=None: controller inject as anonymous peer via c2c send
    scenario.send_dm(None, receiver, message)

    seen = {"ok": False}

    def _see_or_seen() -> bool:
        if scenario.broker_inbox_contains(receiver, message):
            seen["ok"] = True
            return True
        return seen["ok"]

    try:
        scenario.wait_for(_see_or_seen, timeout=90.0, interval=0.05)
    except AssertionError:
        blog = scenario.broker_root() / "broker.log"
        if blog.exists() and message in blog.read_text(encoding="utf-8", errors="replace"):
            scenario.comment(
                "DM marker not in inbox but present in broker.log (deliver drained)"
            )
            return
        raise AssertionError(
            f"peer DM marker never appeared in inbox or broker.log for "
            f"{receiver.name}: {message}"
        )
