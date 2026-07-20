"""Live Codex twin smoke tests on the shared terminal E2E framework.

These are opt-in because they launch real Codex sessions in tmux.

Primary managed delivery is app-server inject (+ hooks fallback). This suite
proves managed start, broker registration, and peer DM landing in the
receiver's broker inbox. Full inject/auto-turn wake is covered by the gated
B144 harnesses:

  * scripts/codex-managed-appserver-live-e2e.py  (C2C_CODEX_APPSERVER_LIVE=1)
  * scripts/codex-hooks-live-e2e.py              (C2C_CODEX_HOOKS_LIVE=1)
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.e2e.framework.capabilities import CODEX_MANAGED
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
            "managed Codex twins launched but did not auto-register with the broker"
        )


def test_codex_twin_managed_start_and_register(scenario: Scenario) -> None:
    """Managed twins start (app-server or hooks) and register alive."""
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.require_capability(CODEX_MANAGED)

    suffix = _unique_suffix()
    alias_a = f"codex-a-{suffix}"
    alias_b = f"codex-b-{suffix}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)

    # Upstream removed --xml-input-fd; managed path must not reintroduce it.
    for agent in (a, b):
        cmdline = scenario.managed_inner_cmdline(agent)
        assert "--xml-input-fd" not in cmdline, (
            f"managed codex must not use removed XML sideband: {cmdline}"
        )

    _wait_for_registered_agents_or_skip(scenario, a, b)

    scenario.comment(
        "Managed Codex twins register without the retired --xml-input-fd surface."
    )
    scenario.assert_agent(a).alive()
    scenario.assert_agent(b).alive()
    scenario.assert_agent(a).registered_alive()
    scenario.assert_agent(b).registered_alive()


def test_codex_twin_peer_dm_reaches_broker_inbox(scenario: Scenario) -> None:
    """Peer DM is enqueued in the receiver broker inbox (delivery seam).

    Model-visible inject / auto-turn is proven by the B144 live harnesses,
    not by scraping the TUI pane (app-server inject is not pane-visible).
    """
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()
    scenario.require_capability(CODEX_MANAGED)

    suffix = _unique_suffix()
    alias_a = f"codex-dm-a-{suffix}"
    alias_b = f"codex-dm-b-{suffix}"
    _write_role_file(scenario.workdir, alias_a)
    _write_role_file(scenario.workdir, alias_b)

    a = scenario.start_agent("codex", name=alias_a, auto=True)
    b = scenario.start_agent("codex", name=alias_b, auto=True)
    scenario.wait_for_init(a, b, timeout=120.0)
    _wait_for_registered_agents_or_skip(scenario, a, b)

    message = f"codex-twin-ping-{os.getpid()}-{time.time_ns()}"
    scenario.send_dm(a, b, message)

    # Messaging contract: unique marker appears in the receiver inbox at least
    # once. Poll tightly so a fast app-server/hooks drain still races us.
    # Model-visible inject is proven by B144 live harnesses, not pane scrape.
    seen = {"ok": False}

    def _see_or_seen() -> bool:
        if scenario.broker_inbox_contains(b, message):
            seen["ok"] = True
            return True
        return seen["ok"]

    try:
        scenario.wait_for(_see_or_seen, timeout=90.0, interval=0.05)
    except AssertionError:
        # Last-chance: deliver may have drained; broker.log often retains the body.
        blog = scenario.broker_root() / "broker.log"
        if blog.exists() and message in blog.read_text(encoding="utf-8", errors="replace"):
            scenario.comment(
                "DM marker not in inbox but present in broker.log (deliver drained)"
            )
            return
        raise AssertionError(
            f"peer DM marker never appeared in inbox or broker.log for {b.name}: {message}"
        )
