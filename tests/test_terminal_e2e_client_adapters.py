from __future__ import annotations

from pathlib import Path
from unittest import mock

import pytest

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


def test_codex_adapter_detects_xml_fd_capability(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.subprocess.run",
        lambda *a, **k: mock.Mock(stdout="Usage: codex --xml-input-fd <fd>\n", stderr=""),
    )

    adapter = CodexAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities["codex_xml_fd"] is True


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

    assert capabilities["codex_headless_thread_id_fd"] is True


def test_codex_adapter_builds_managed_launch_command(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    adapter = CodexAdapter(tmp_path)
    config = AgentConfig(
        client="codex",
        name="codex-a",
        auto=True,
        extra_args=["--approval-policy", "never"],
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "codex", "-n", "codex-a"]
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
        extra_args=["--approval-policy", "never"],
        env={"C2C_TEST_ENV": "1"},
    )
    scenario = mock.Mock(workdir=tmp_path / "work")

    launch = adapter.build_launch(scenario, config)

    assert launch["command"][:5] == ["c2c", "start", "codex-headless", "-n", "headless-a"]
    assert launch["command"][-3:] == ["--", "--approval-policy", "never"]
    assert launch["env"] == {"C2C_TEST_ENV": "1"}


def test_codex_adapter_ready_when_driver_alive_and_instance_dir_exists(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    adapter = CodexAdapter(tmp_path)
    agent = _make_agent(client="codex", name="codex-a")
    scenario = mock.Mock(drivers={"tmux": _ReadyDriver(alive=True)})
    instance_dir = tmp_path / ".local" / "share" / "c2c" / "instances" / agent.name
    instance_dir.mkdir(parents=True)

    with mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path):
        assert adapter.is_ready(scenario, agent) is True


def test_codex_headless_adapter_ready_requires_config_json(tmp_path: Path) -> None:
    from tests.e2e.framework.client_adapters import CodexHeadlessAdapter

    adapter = CodexHeadlessAdapter(tmp_path)
    agent = _make_agent(client="codex-headless", name="headless-a")
    scenario = mock.Mock(drivers={"tmux": _ReadyDriver(alive=True)})
    instance_dir = tmp_path / ".local" / "share" / "c2c" / "instances" / agent.name
    instance_dir.mkdir(parents=True)

    with mock.patch("tests.e2e.framework.client_adapters.Path.home", return_value=tmp_path):
        assert adapter.is_ready(scenario, agent) is False
        (instance_dir / "config.json").write_text("{}", encoding="utf-8")
        assert adapter.is_ready(scenario, agent) is True


def test_scenario_refresh_capabilities_merges_adapter_results(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={
            "dummy-a": _CapabilityAdapter({"codex_xml_fd": True}),
            "dummy-b": _CapabilityAdapter({"codex_headless_thread_id_fd": False}),
        },
    )

    capabilities = scenario.refresh_capabilities()

    assert capabilities == {
        "codex_xml_fd": True,
        "codex_headless_thread_id_fd": False,
    }


def test_scenario_require_capability_raises_for_missing_capability(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={"dummy": _CapabilityAdapter({"codex_xml_fd": False})},
    )

    scenario.refresh_capabilities()

    with pytest.raises(AssertionError, match="required capability missing: codex_xml_fd"):
        scenario.require_capability("codex_xml_fd")


def test_scenario_xfail_unless_marks_missing_capability(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=mock.Mock(),
        drivers={"fake-pty": _ReadyDriver()},
        adapters={"dummy": _CapabilityAdapter({"codex_xml_fd": False})},
    )

    scenario.refresh_capabilities()

    with pytest.raises(pytest.xfail.Exception):
        scenario.xfail_unless("codex_xml_fd", reason="missing binary support")
