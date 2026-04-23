from __future__ import annotations

import subprocess
from pathlib import Path
from unittest import mock

import pytest

from tests.e2e.framework.capabilities import (
    CLAUDE_CHANNEL,
    CODEX_HEADLESS_THREAD_ID_FD,
    CODEX_XML_FD,
    KIMI_WIRE,
    OPENCODE_PLUGIN,
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


def test_codex_adapter_detects_xml_fd_capability(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    monkeypatch.setattr(
        "tests.e2e.framework.client_adapters.subprocess.run",
        lambda *a, **k: mock.Mock(stdout="Usage: codex --xml-input-fd <fd>\n", stderr=""),
    )

    adapter = CodexAdapter(tmp_path)
    capabilities = adapter.probe_capabilities(None)

    assert capabilities[CODEX_XML_FD] is True


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
        model="minimax-coding-plan/MiniMax-M2.7-highspeed",
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
        "minimax-coding-plan/MiniMax-M2.7-highspeed",
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


def test_capability_probe_returns_false_on_timeout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.e2e.framework.client_adapters import CodexAdapter

    def fake_run(*args: object, **kwargs: object) -> mock.Mock:
        raise subprocess.TimeoutExpired(cmd=["codex", "--help"], timeout=1.0)

    monkeypatch.setattr("tests.e2e.framework.client_adapters.subprocess.run", fake_run)

    adapter = CodexAdapter(tmp_path)

    assert adapter.probe_capabilities(None) == {CODEX_XML_FD: False}


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
