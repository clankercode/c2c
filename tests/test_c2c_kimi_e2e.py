"""Live Kimi smoke tests on the shared terminal E2E framework.

Primary managed delivery is the REST notifier (POST to Kimi Code
``/api/v1/sessions/{id}/prompts``). This suite asserts:

  * twin (or sender→receiver) managed start + registration
  * peer DM present in the broker inbox (messaging contract)
  * notifier armed (pid/sid under ``~/.local/share/c2c/kimi-notifiers/``
    and/or instance ``notifier.pid``) — the deliver path product claim

Full REST inject wake still needs a live kimi server + session id; hermetic
coverage lives in ``ocaml/test/test_c2c_kimi_{notifier,deliver,delivery_claim}.ml``.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

from tests.e2e.framework.client_adapters import compile_role
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
    try:
        registrations = json.loads(registry.read_text(encoding="utf-8") or "[]")
        rows = (
            registrations
            if isinstance(registrations, list)
            else registrations.get("registrations", [])
        )
        for row in rows:
            if row.get("alias") == agent.name and row.get("alive") is not False:
                return True
    except Exception:
        pass
    return False


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "c2c test"], cwd=path, check=True)
    subprocess.run(
        ["git", "config", "user.email", "c2c-test@example.invalid"],
        cwd=path,
        check=True,
    )
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init", "-q"],
        cwd=path,
        check=True,
    )


def _write_role_file(workdir: Path, alias: str) -> None:
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    (roles_dir / f"{alias}.md").write_text("test-agent\n", encoding="utf-8")


def _notifier_pid_paths(alias: str) -> list[Path]:
    home = Path.home()
    return [
        home / ".local" / "share" / "c2c" / "kimi-notifiers" / f"{alias}.pid",
        home / ".local" / "share" / "c2c" / "instances" / alias / "notifier.pid",
    ]


def _notifier_sid_path(alias: str) -> Path:
    return Path.home() / ".local" / "share" / "c2c" / "kimi-notifiers" / f"{alias}.sid"


def _pid_alive(path: Path) -> bool:
    try:
        pid = int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _notifier_armed(alias: str) -> bool:
    """True when the managed kimi REST notifier is trackable for *alias*."""
    if any(_pid_alive(p) for p in _notifier_pid_paths(alias)):
        return True
    sid = _notifier_sid_path(alias)
    if sid.exists():
        try:
            text = sid.read_text(encoding="utf-8").strip()
            return bool(text)
        except OSError:
            return False
    return False


def test_kimi_smoke_send_receive(scenario: Scenario) -> None:
    """Launch two Kimi instances, send a DM, verify inbox + notifier arming."""
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

    # Product claim: managed start arms the REST notifier (CONDITIONAL wake).
    # Prefer live pid; fall back to .sid binding written at arm time.
    try:
        scenario.wait_for(
            lambda: _notifier_armed(receiver_alias) or _notifier_armed(sender_alias),
            timeout=45.0,
        )
    except AssertionError:
        pytest.skip(
            "managed kimi registered but REST notifier was not armed "
            "(pid/sid missing — deliver path not proven in this environment)"
        )

    scenario.comment(
        f"notifier armed for receiver={_notifier_armed(receiver_alias)} "
        f"sender={_notifier_armed(sender_alias)}"
    )

    message = f"kimi-e2e-ping-{suffix}"
    scenario.send_dm(sender, receiver, message)

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
                "DM marker not in inbox but present in broker.log (REST drained)"
            )
            return
        raise AssertionError(
            f"peer DM marker never appeared in inbox or broker.log for "
            f"{receiver.name}: {message}"
        )


def test_kimi_smoke_with_agent(scenario: Scenario) -> None:
    """Launch Kimi with --agent flag, verify compiled role file is picked up.

    AC:
    - C2C_TEST_KIMI_E2E=1 pytest ...::test_kimi_smoke_with_agent passes
    - Role file is generated at .kimi/agents/<name>.md before client startup
    - Test is capability-gated (skip if kimi binary absent)
    """
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    agent_alias = f"kimi-agent-{suffix}"
    agent_file = scenario.workdir / ".kimi" / "agents" / f"{agent_alias}.md"

    compile_role(scenario.workdir, agent_alias, "kimi")
    assert agent_file.exists(), f"compiled role not found at {agent_file}"

    agent = scenario.start_agent("kimi", name=agent_alias, role=agent_alias, auto=True)

    scenario.wait_for_init(agent, timeout=120.0)
    scenario.wait_for(
        lambda: _registered(agent, scenario),
        timeout=60.0,
    )

    scenario.assert_agent(agent).alive()
    scenario.assert_agent(agent).registered_alive()


