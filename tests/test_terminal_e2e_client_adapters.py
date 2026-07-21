from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest import mock

import pytest

from tests.e2e.framework.capabilities import (
    AGY_AGENTAPI,
    CLAUDE_CHANNEL,
    CODEX_HEADLESS_THREAD_ID_FD,
    CODEX_MANAGED,
    CODEX_XML_FD,
    KIMI_WIRE,
    OPENCODE_PLUGIN,
    PI_C2C,
)
from tests.e2e.framework.scenario import AgentConfig, Scenario, StartedAgent
from tests.e2e.framework.terminal_driver import TerminalCapture, TerminalHandle


class _ReadyDriver:
    def __init__(self, *, alive: bool = True) -> None:
        self.alive = alive

    def start(self, spec: object) -> TerminalHandle:
        raise NotImplementedError

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        return None

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        return None

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        return TerminalCapture(text="", raw="")

    def is_alive(self, handle: TerminalHandle) -> bool:
        return self.alive

    def stop(self, handle: TerminalHandle) -> None:
        return None


class _CapabilityAdapter:
    client_name = "dummy"
    default_backend = "fake-pty"

    def __init__(self, capabilities: dict[str, bool]) -> None:
        self.capabilities = capabilities

    def build_launch(self, scenario: Scenario, config: AgentConfig) -> dict[str, object]:
        raise NotImplementedError

    def is_ready(self, scenario: Scenario, agent: StartedAgent) -> bool:
        return True

    def probe_capabilities(self, scenario: Scenario) -> dict[str, bool]:
        return dict(self.capabilities)


def _make_agent(*, client: str, name: str, backend: str = "tmux") -> StartedAgent:
    return StartedAgent(
        client=client,
        name=name,
        backend=backend,
        handle=TerminalHandle(backend=backend, target=f"{name}-target", process_pid=123),
        config=AgentConfig(client=client, name=name),
    )


def test_codex_adapter_detects_managed_capability(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: "/usr/bin/codex" if name == "codex" else None,
    )

    adapter = CodexAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities[CODEX_MANAGED] is True
    assert CODEX_XML_FD not in capabilities


def test_codex_headless_adapter_detects_thread_id_fd_capability(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import CodexHeadlessAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.subprocess.run",
        lambda *a, **k: mock.Mock(
            stdout="Usage: codex-turn-start-bridge --thread-id-fd <fd>\n",
            stderr="",
        ),
    )

    adapter = CodexHeadlessAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities[CODEX_HEADLESS_THREAD_ID_FD] is True


def test_codex_adapter_builds_managed_launch_command(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    adapter = CodexAdapter(tmp_path)
    config = AgentConfig(
        client="codex",
        name="codex-a",
        auto=True,
        model="gpt-5.4",
        extra_args=["--approval-policy", "never"],
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "codex", "-n", "codex-a"]
    assert "--model" in launch["command"]
    assert "gpt-5.4" in launch["command"]
    assert "--auto" in launch["command"]
    assert "--" in launch["command"]
    assert launch["cwd"] == scenario.workdir
    assert launch["title"] == "codex-a"


def test_codex_headless_adapter_builds_managed_launch_command(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexHeadlessAdapter

    adapter = CodexHeadlessAdapter(tmp_path)
    config = AgentConfig(
        client="codex-headless",
        name="headless-a",
        auto=True,
        model="gpt-5.4",
        extra_args=["--approval-policy", "never"],
        env={"C2C_TEST_ENV": "1"},
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "codex-headless", "-n", "headless-a"]
    assert "--model" in launch["command"]
    assert "gpt-5.4" in launch["command"]
    assert launch["command"][-3:] == ["--", "--approval-policy", "never"]
    assert launch["env"] == {"C2C_TEST_ENV": "1"}


def test_opencode_adapter_builds_managed_launch_command_with_model(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import OpenCodeAdapter

    adapter = OpenCodeAdapter(tmp_path)
    config = AgentConfig(
        client="opencode",
        name="oc-a",
        role="worker",
        model="zai-coding-plan/glm-5-turbo",
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"] == [
        "c2c",
        "start",
        "opencode",
        "-n",
        "oc-a",
        "--agent",
        "worker",
        "--model",
        "zai-coding-plan/glm-5-turbo",
    ]


def test_codex_adapter_ready_requires_live_inner_pid(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    adapter = CodexAdapter(tmp_path)
    agent = _make_agent(client="codex", name="codex-a")
    scenario = mock.Mock(drivers={"tmux": _ReadyDriver(alive=True)})
    instance_dir = tmp_path / ".local" / "share" / "c2c" / "instances" / agent.name
    instance_dir.mkdir(parents=True)
    inner_pid = instance_dir / "inner.pid"

    with (
        mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path),
        mock.patch("tests.e2e.framework.client_adapters.os.kill", side_effect=ProcessLookupError),
    ):
        assert adapter.is_ready(scenario, agent) is False
        inner_pid.write_text("4242\n", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False

    with (
        mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path),
        mock.patch("tests.e2e.framework.client_adapters.os.kill", return_value=None),
    ):
        assert adapter.is_ready(scenario, agent) is True


def test_codex_headless_adapter_ready_requires_sidecars_and_startup_grace(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexHeadlessAdapter

    adapter = CodexHeadlessAdapter(tmp_path)
    agent = _make_agent(client="codex-headless", name="headless-a")
    scenario = mock.Mock(drivers={"tmux": _ReadyDriver(alive=True)})
    instance_dir = tmp_path / ".local" / "share" / "c2c" / "instances" / agent.name
    instance_dir.mkdir(parents=True)
    inner_pid = instance_dir / "inner.pid"
    deliver_pid = instance_dir / "deliver.pid"
    meta_path = instance_dir / "meta.json"

    with (
        mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path),
        mock.patch("tests.e2e.framework.client_adapters.os.kill", return_value=None),
        mock.patch("tests.e2e.framework.client_adapters.time.time", return_value=100.0),
    ):
        assert adapter.is_ready(scenario, agent) is False
        (instance_dir / "config.json").write_text("{}", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        inner_pid.write_text("9898\n", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        deliver_pid.write_text("9899\n", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        (instance_dir / "thread-id-handoff.jsonl").write_text("", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        (instance_dir / "xml-input.fifo").write_text("", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        meta_path.write_text('{"start_ts": 99.5}', encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False
        meta_path.write_text('{"start_ts": 98.0}', encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is True


def test_capability_probe_returns_false_when_codex_missing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: None,
    )

    adapter = CodexAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {CODEX_MANAGED: False}


def test_headless_capability_probe_returns_false_on_subprocess_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import CodexHeadlessAdapter

    def fake_run(*args: object, **kwargs: object) -> mock.Mock:
        raise OSError("wedged binary")

    monkeypatch.setattr("tests.e2e.framework.client_adapters.subprocess.run", fake_run)

    adapter = CodexHeadlessAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {CODEX_HEADLESS_THREAD_ID_FD: False}


def test_claude_adapter_uses_shared_channel_capability_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import ClaudeAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: "/usr/bin/claude" if name == "claude" else None,
    )

    adapter = ClaudeAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {CLAUDE_CHANNEL: True}


def test_opencode_adapter_reports_plugin_capability_from_repo_plugin_path(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import OpenCodeAdapter

    plugin_path = tmp_path / ".opencode" / "plugins"
    plugin_path.mkdir(parents=True)
    (plugin_path / "c2c.ts").write_text("// plugin\n", encoding="utf-8")

    adapter = OpenCodeAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {OPENCODE_PLUGIN: True}


def test_kimi_adapter_uses_shared_wire_capability_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import KimiAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: "/usr/bin/kimi" if name == "kimi" else None,
    )

    adapter = KimiAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {KIMI_WIRE: True}


def test_agy_adapter_builds_managed_launch_command(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import AgyAdapter

    adapter = AgyAdapter(tmp_path)
    config = AgentConfig(
        client="agy",
        name="agy-a",
        auto=True,
        model="gemini-3-flash",
        extra_args=["--mode", "accept-edits"],
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "agy", "-n", "agy-a"]
    assert "--model" in launch["command"]
    assert "gemini-3-flash" in launch["command"]
    assert "--auto" in launch["command"]
    assert launch["command"][-3:] == ["--", "--mode", "accept-edits"]
    assert launch["cwd"] == scenario.workdir
    assert launch["title"] == "agy-a"


def test_agy_adapter_uses_agentapi_capability_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import AgyAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: "/usr/bin/agy" if name == "agy" else None,
    )

    adapter = AgyAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {AGY_AGENTAPI: True}


def test_agy_adapter_ready_requires_live_inner_pid(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import AgyAdapter

    adapter = AgyAdapter(tmp_path)
    agent = _make_agent(client="agy", name="agy-a")
    scenario = mock.Mock(drivers={"tmux": _ReadyDriver(alive=True)})
    instance_dir = tmp_path / ".local" / "share" / "c2c" / "instances" / agent.name
    instance_dir.mkdir(parents=True)
    inner_pid = instance_dir / "inner.pid"

    with (
        mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path),
        mock.patch("tests.e2e.framework.client_adapters.os.kill", side_effect=ProcessLookupError),
    ):
        assert adapter.is_ready(scenario, agent) is False
        inner_pid.write_text("4242\n", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is False

    with (
        mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path),
        mock.patch("tests.e2e.framework.client_adapters.os.kill", return_value=None),
    ):
        assert adapter.is_ready(scenario, agent) is True


def test_kimi_e2e_notifier_paths_match_shipped_layout() -> None:
    """Structural: kimi e2e notifier helpers target real C2c_kimi_notifier paths."""
    # Import helpers from the live module without running gated live tests.
    from tests import test_c2c_kimi_e2e as kimi_e2e

    alias = "structural-only-alias"
    paths = kimi_e2e._notifier_pid_paths(alias)
    assert any("kimi-notifiers" in str(p) for p in paths)
    assert any("notifier.pid" in str(p) for p in paths)
    assert str(kimi_e2e._notifier_sid_path(alias)).endswith(f"{alias}.sid")
    assert kimi_e2e._notifier_armed(alias) is False


def test_agy_registered_in_scenario_fixture_adapters() -> None:
    """conftest scenario fixture must register AgyAdapter (criterion 3)."""
    import inspect

    import tests.conftest as conf

    src = inspect.getsource(conf.scenario)
    assert '"agy"' in src or "'agy'" in src
    assert "AgyAdapter" in inspect.getsource(conf)


def test_client_e2e_gates_documented_for_preflight() -> None:
    """Cheap always-on preflight: live modules reference opt-in gate env names."""
    from pathlib import Path

    root = Path(__file__).resolve().parents[1]
    twin = (root / "tests" / "test_c2c_codex_twin_e2e.py").read_text(encoding="utf-8")
    kimi = (root / "tests" / "test_c2c_kimi_e2e.py").read_text(encoding="utf-8")
    agy = (root / "tests" / "test_c2c_agy_e2e.py").read_text(encoding="utf-8")
    live_ml = (root / "ocaml" / "test" / "test_c2c_codex_live_e2e.ml").read_text(
        encoding="utf-8"
    )
    assert "C2C_TEST_CODEX_TWIN_E2E" in twin
    assert "C2C_TEST_KIMI_E2E" in kimi
    assert "C2C_TEST_AGY_E2E" in agy
    assert "C2C_CODEX_APPSERVER_LIVE" in live_ml
    assert "C2C_CODEX_HOOKS_LIVE" in live_ml
    # Adapter modules import cleanly and name the three clients.
    from tests.e2e.framework.client_adapters import AgyAdapter, CodexAdapter, KimiAdapter

    assert AgyAdapter.client_name == "agy"
    assert CodexAdapter.client_name == "codex"
    assert KimiAdapter.client_name == "kimi"


def test_pi_adapter_builds_launch_command_with_model_and_hermetic_env(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import PiAdapter

    adapter = PiAdapter(tmp_path)
    config = AgentConfig(
        client="pi",
        name="pi-a",
        model="xiaomi-token-plan-sgp/mimo-v2.5-pro",
    )
    broker_root = tmp_path / "broker"
    scenario = mock.Mock(workdir=tmp_path / "work", broker_root=lambda: broker_root)

    launch = adapter.build_launch(scenario, config)

    assert launch["command"] == ["pi", "--model", "xiaomi-token-plan-sgp/mimo-v2.5-pro"]
    assert launch["cwd"] == scenario.workdir
    assert launch["title"] == "pi-a"
    env = launch["env"]
    assert env["C2C_PI_ALIAS"] == "pi-a"
    assert env["C2C_MCP_BROKER_ROOT"] == str(broker_root)
    assert env["C2C_PI_CROSS_REPO"] == "0"
    assert env["C2C_PI_RELAY"] == "0"


def test_pi_adapter_launch_command_omits_model_when_unset(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import PiAdapter

    adapter = PiAdapter(tmp_path)
    config = AgentConfig(client="pi", name="pi-a")
    scenario = mock.Mock(workdir=tmp_path / "work", broker_root=lambda: tmp_path / "broker")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"] == ["pi"]


def test_pi_adapter_caller_env_overrides_hermetic_defaults(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import PiAdapter

    adapter = PiAdapter(tmp_path)
    config = AgentConfig(
        client="pi",
        name="pi-a",
        env={"C2C_PI_RELAY": "1", "C2C_MCP_BROKER_ROOT": "/custom/broker"},
    )
    scenario = mock.Mock(workdir=tmp_path / "work", broker_root=lambda: tmp_path / "broker")

    env = adapter.build_launch(scenario, config)["env"]

    assert env["C2C_PI_RELAY"] == "1"
    assert env["C2C_MCP_BROKER_ROOT"] == "/custom/broker"


def test_pi_adapter_reports_capability_from_pi_binary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework.client_adapters import PiAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.shutil.which",
        lambda name: "/usr/bin/pi" if name == "pi" else None,
    )

    adapter = PiAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {PI_C2C: True}


def test_pi_adapter_ready_requires_broker_registration(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import PiAdapter

    adapter = PiAdapter(tmp_path)
    agent = _make_agent(client="pi", name="pi-a")
    broker_root = tmp_path / "broker"
    broker_root.mkdir(parents=True)
    scenario = mock.Mock(
        drivers={"tmux": _ReadyDriver(alive=True)},
        broker_root=lambda: broker_root,
    )

    # No registry yet -> not ready.
    assert adapter.is_ready(scenario, agent) is False

    registry = broker_root / "registry.json"
    registry.write_text(json.dumps([{"alias": "pi-a", "alive": False}]), encoding="utf-8")
    assert adapter.is_ready(scenario, agent) is False

    registry.write_text(json.dumps([{"alias": "pi-a", "alive": True}]), encoding="utf-8")
    assert adapter.is_ready(scenario, agent) is True

    # Dead driver short-circuits even when registered.
    scenario.drivers["tmux"] = _ReadyDriver(alive=False)
    assert adapter.is_ready(scenario, agent) is False


def test_scenario_refresh_capabilities_merges_adapter_results(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={
            "dummy-a": _CapabilityAdapter({CODEX_XML_FD: True}),
            "dummy-b": _CapabilityAdapter({CODEX_HEADLESS_THREAD_ID_FD: False}),
        },
    )

    capabilities = scenario.refresh_capabilities()

    assert capabilities == {
        CODEX_XML_FD: True,
        CODEX_HEADLESS_THREAD_ID_FD: False,
    }


def test_scenario_require_capability_raises_for_missing_capability(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={"dummy": _CapabilityAdapter({CODEX_XML_FD: False})},
    )

    scenario.refresh_capabilities()

    with pytest.raises(AssertionError, match=f"required capability missing: {CODEX_XML_FD}"):
        scenario.require_capability(CODEX_XML_FD)


def test_scenario_probe_capabilities_populates_require_and_xfail_contract(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={
            "codex": _CapabilityAdapter({CODEX_XML_FD: True}),
            "headless": _CapabilityAdapter({CODEX_HEADLESS_THREAD_ID_FD: False}),
        },
    )

    caps = scenario.probe_capabilities("codex")

    assert caps == {CODEX_XML_FD: True}
    scenario.require_capability(CODEX_XML_FD)

    scenario.probe_capabilities("headless")
    with pytest.raises(pytest.xfail.Exception):
        scenario.xfail_unless(CODEX_HEADLESS_THREAD_ID_FD, reason="missing binary support")


def test_scenario_xfail_unless_marks_missing_capability(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={"dummy": _CapabilityAdapter({CODEX_XML_FD: False})},
    )

    scenario.refresh_capabilities()

    with pytest.raises(pytest.xfail.Exception):
        scenario.xfail_unless(CODEX_XML_FD, reason="missing binary support")
