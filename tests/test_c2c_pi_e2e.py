"""Live pi smoke tests on the shared terminal E2E framework, via pi-c2c.

pi is not a ``c2c start``-managed client; the pi-c2c extension (assumed
installed) makes a pi session a c2c peer. These tests launch real pi
sessions in tmux, pin them to a scenario-local broker, and verify
registration + broker-routed DM delivery.

Gated on ``C2C_TEST_PI_E2E=1`` plus tmux/pi/c2c on PATH so the default
suite never tries to spin up a live model.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.e2e.framework.models import e2e_model
from tests.e2e.framework.scenario import Scenario


TMUX_BIN = shutil.which("tmux")
PI_BIN = shutil.which("pi")
C2C_BIN = shutil.which("c2c")
# Overridable per run: C2C_E2E_PI_MODEL > C2C_E2E_MODEL > default
# (zai-coding-plan/glm-5-turbo).
PI_TEST_MODEL = e2e_model("pi")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_PI_E2E") != "1"
    or not TMUX_BIN
    or not PI_BIN
    or not C2C_BIN,
    reason=(
        "set C2C_TEST_PI_E2E=1 and ensure tmux/pi/c2c are on PATH "
        "(pi-c2c must be installed)"
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


def test_pi_smoke_registers(scenario: Scenario) -> None:
    """Launch a single pi session; verify pi-c2c registers it in the broker.

    AC:
    - C2C_TEST_PI_E2E=1 pytest ...::test_pi_smoke_registers passes
    - pi session registers an alive entry in the scenario broker registry
    - Capability-gated (skip if pi binary absent)
    """
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    alias = f"pi-agent-{suffix}"

    agent = scenario.start_agent("pi", name=alias, model=PI_TEST_MODEL)

    scenario.wait_for_init(agent, timeout=120.0)
    scenario.wait_for(lambda: _registered(agent, scenario), timeout=90.0)

    scenario.assert_agent(agent).alive()
    scenario.assert_agent(agent).registered_alive()


def test_pi_smoke_send_receive(scenario: Scenario) -> None:
    """Launch two pi sessions, send a DM from one to the other, verify receipt."""
    _init_git_repo(scenario.workdir)
    scenario.refresh_capabilities()

    suffix = _unique_suffix()
    sender_alias = f"pi-sender-{suffix}"
    receiver_alias = f"pi-receiver-{suffix}"

    sender = scenario.start_agent("pi", name=sender_alias, model=PI_TEST_MODEL)
    receiver = scenario.start_agent("pi", name=receiver_alias, model=PI_TEST_MODEL)

    scenario.wait_for_init(sender, receiver, timeout=120.0)
    scenario.wait_for(
        lambda: _registered(sender, scenario) and _registered(receiver, scenario),
        timeout=90.0,
    )

    scenario.assert_agent(sender).alive()
    scenario.assert_agent(receiver).alive()
    scenario.assert_agent(receiver).registered_alive()

    message = f"pi-e2e-ping-{suffix}"
    scenario.send_dm(sender, receiver, message)

    # pi-c2c delivers inbound DMs into the session and DRAINS the broker inbox
    # file (inotify watcher + poll), so broker_inbox_contains races the drain
    # and is unusable here. Assert real delivery instead: the receiver pi
    # renders the message body in its transcript pane.
    scenario.wait_for(
        lambda: message in scenario.capture(receiver),
        timeout=90.0,
    )


def test_pi_smoke_model_override_reaches_launch_command(scenario: Scenario) -> None:
    """The configured model lands on the inner pi --model flag.

    Doesn't need a live model — asserts the adapter wires --model through to
    the command the tmux pane runs. Kept here (not the unit file) so it shares
    the pi env gate and stays near the live tests it guards.
    """
    from tests.e2e.framework.client_adapters import PiAdapter
    from tests.e2e.framework.scenario import AgentConfig

    _init_git_repo(scenario.workdir)
    adapter = PiAdapter(scenario.workdir)
    config = AgentConfig(client="pi", name="pi-model-probe", model=PI_TEST_MODEL)

    launch = adapter.build_launch(scenario, config)

    assert launch["command"] == ["pi", "--model", PI_TEST_MODEL]
