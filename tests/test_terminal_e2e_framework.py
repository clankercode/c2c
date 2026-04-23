import json
import os
import shutil
import shlex
import sys
import time
from pathlib import Path
from unittest import mock

import pytest

from tests import conftest as conftest_module
from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.scenario import Scenario
from tests.e2e.framework.terminal_driver import TerminalCapture, TerminalHandle, TerminalStartSpec
from tests.e2e.framework.tmux_driver import TmuxDriver

FAKE_TERMINAL_CHILD = (
    Path(__file__).resolve().parent / "e2e" / "fixtures" / "fake_terminal_child.py"
)


def test_artifact_collector_creates_run_dir_and_timeline(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    run_dir = collector.start_run()

    assert run_dir.parent == tmp_path / "test_demo"
    assert (run_dir / "timeline.jsonl").exists()


def test_artifact_collector_creates_distinct_run_dir_for_same_second_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework import artifacts as artifacts_module

    monkeypatch.setattr(artifacts_module.time, "strftime", lambda _fmt: "20260422-123456")

    first_collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    second_collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    first = first_collector.start_run()
    second = second_collector.start_run()

    assert first != second
    assert first.exists()
    assert second.exists()
    assert first.parent == second.parent == tmp_path / "test_demo"


def test_artifact_collector_writes_actual_on_golden_mismatch(tmp_path: Path) -> None:
    golden = tmp_path / "golden.txt"
    golden.write_text("expected screen\n", encoding="utf-8")

    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    with pytest.raises(AssertionError):
        collector.compare_golden("screen", "actual screen\n", golden)

    assert (collector.run_dir / "screen.actual.txt").exists()


def test_artifact_collector_requires_start_run_before_writing(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")

    with pytest.raises(RuntimeError, match="start_run\\(\\) must be called first"):
        collector.write_text("screen.txt", "body")


def test_artifact_collector_event_field_wins_over_payload_event(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    collector.append_event("ready", {"event": "payload", "extra": 1})

    line = (collector.run_dir / "timeline.jsonl").read_text(encoding="utf-8").strip()
    payload = json.loads(line)
    assert payload["event"] == "ready"
    assert payload["extra"] == 1
    assert set(payload) == {"event", "extra"}


def test_artifact_collector_retries_when_mkdir_collides(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework import artifacts as artifacts_module

    monkeypatch.setattr(artifacts_module.time, "strftime", lambda _fmt: "20260422-123456")

    original_mkdir = artifacts_module.Path.mkdir
    seen_first_target = {"value": False}

    def fake_mkdir(self: Path, *args: object, **kwargs: object) -> None:
        if self.name == "20260422-123456" and not seen_first_target["value"]:
            seen_first_target["value"] = True
            raise FileExistsError
        return original_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(artifacts_module.Path, "mkdir", fake_mkdir)

    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    run_dir = collector.start_run()

    assert run_dir.name == "20260422-123456-1"
    assert run_dir.exists()


def test_artifact_collector_serializes_path_payload_values(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    collector.append_event("paths", {"artifact": tmp_path / "screen.txt"})

    line = (collector.run_dir / "timeline.jsonl").read_text(encoding="utf-8").strip()
    payload = json.loads(line)
    assert payload["event"] == "paths"
    assert payload["artifact"] == str(tmp_path / "screen.txt")


def test_artifact_collector_rejects_traversal_test_name(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="../escape")

    with pytest.raises(ValueError, match="unsafe path fragment"):
        collector.start_run()


def test_artifact_collector_rejects_slash_and_absolute_artifact_names(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    with pytest.raises(ValueError, match="unsafe path fragment"):
        collector.write_text("nested/screen.txt", "body")

    with pytest.raises(ValueError, match="unsafe path fragment"):
        collector.write_text(str(Path("/abs.txt")), "body")


def test_terminal_types_keep_backend_and_target_explicit() -> None:
    handle = TerminalHandle(
        backend="fake-pty",
        target="pty-1",
        process_pid=12345,
    )
    capture = TerminalCapture(
        text="READY\n",
        raw="READY\r\n",
    )

    assert handle.backend == "fake-pty"
    assert handle.target == "pty-1"
    handle.metadata["role"] = "driver"
    assert handle.metadata["role"] == "driver"
    assert capture.text == "READY\n"


def test_artifact_collector_requires_start_run_before_appending(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")

    with pytest.raises(RuntimeError, match="start_run\\(\\) must be called first"):
        collector.append_event("ready", {})


def test_framework_package_exports_smoke() -> None:
    from tests.e2e.framework import ArtifactCollector as ExportedCollector
    from tests.e2e.framework import TerminalCapture as ExportedCapture
    from tests.e2e.framework import TerminalHandle as ExportedHandle
    from tests.e2e.framework import TerminalDriver as ExportedDriver

    assert ExportedCollector is ArtifactCollector
    assert ExportedHandle.__name__ == "TerminalHandle"
    assert ExportedCapture.__name__ == "TerminalCapture"
    assert ExportedDriver.__name__ == "TerminalDriver"


class DummyDriver:
    def __init__(self) -> None:
        self.started: list[object] = []
        self.stopped: list[TerminalHandle] = []

    def start(self, spec: object) -> TerminalHandle:
        self.started.append(spec)
        return TerminalHandle(backend="dummy", target="dummy-1", process_pid=111)

    def send_text(self, handle: TerminalHandle, text: str) -> None:
        return None

    def send_key(self, handle: TerminalHandle, key: str) -> None:
        return None

    def capture(self, handle: TerminalHandle) -> TerminalCapture:
        return TerminalCapture(text="READY\n", raw="READY\r\n")

    def is_alive(self, handle: TerminalHandle) -> bool:
        return True

    def stop(self, handle: TerminalHandle) -> None:
        self.stopped.append(handle)
        return None


class FailingStopDriver(DummyDriver):
    def stop(self, handle: TerminalHandle) -> None:
        self.stopped.append(handle)
        raise RuntimeError(f"cannot stop {handle.target}")


class DummyAdapter:
    client_name = "dummy"
    default_backend = "dummy"

    def build_launch(self, scenario: Scenario, config: object) -> dict[str, object]:
        return {
            "command": ["python3", "-c", "print('ready')"],
            "cwd": scenario.workdir,
            "env": {},
            "title": getattr(config, "name"),
        }

    def is_ready(self, scenario: Scenario, agent: object) -> bool:
        return True

    def probe_capabilities(self, scenario: Scenario) -> dict[str, bool]:
        return {"dummy_ready": True}


class LaunchSpecAdapter(DummyAdapter):
    def build_launch(self, scenario: Scenario, config: object) -> dict[str, object]:
        return {
            "command": ["python3", "-c", "print('custom ready')"],
            "cwd": scenario.workdir / "client-cwd",
            "env": {"SCENARIO_TEST": "1"},
            "title": f"session-{getattr(config, 'name')}",
        }


def test_scenario_comment_writes_timeline(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    scenario.comment("hello world")

    timeline = (scenario.artifacts.run_dir / "timeline.jsonl").read_text(encoding="utf-8")
    assert "hello world" in timeline


def test_scenario_start_agent_tracks_started_agent(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    agent = scenario.start_agent("dummy", name="dummy-a")

    assert agent.client == "dummy"
    assert agent.name == "dummy-a"
    assert agent.handle.target == "dummy-1"


def test_scenario_start_agent_rejects_duplicate_agent_names(tmp_path: Path) -> None:
    driver = DummyDriver()
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": driver},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    original = scenario.start_agent("dummy", name="dummy-a")

    with pytest.raises(ValueError, match="duplicate agent name: dummy-a"):
        scenario.start_agent("dummy", name="dummy-a")

    assert scenario.agents["dummy-a"] is original
    assert len(driver.started) == 1


def test_scenario_start_agent_passes_terminal_start_spec_to_driver(tmp_path: Path) -> None:
    driver = DummyDriver()
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": driver},
        adapters={"dummy": LaunchSpecAdapter()},
    )
    scenario.artifacts.start_run()
    scenario.start_agent("dummy", name="dummy-a")

    assert len(driver.started) == 1
    spec = driver.started[0]
    assert isinstance(spec, TerminalStartSpec)
    assert spec.command == ["python3", "-c", "print('custom ready')"]
    assert spec.cwd == scenario.workdir / "client-cwd"
    assert spec.env == {"SCENARIO_TEST": "1"}
    assert spec.title == "session-dummy-a"
    assert spec.cols == 220
    assert spec.rows == 60


def test_scenario_capture_returns_text_and_writes_artifact(tmp_path: Path) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    agent = scenario.start_agent("dummy", name="dummy-a")

    captured = scenario.capture(agent)

    assert captured == "READY\n"
    artifact_path = scenario.artifacts.run_dir / "dummy-a.capture.txt"
    assert artifact_path.read_text(encoding="utf-8") == "READY\n"


def test_scenario_send_dm_invokes_c2c_send_with_from_agent_and_records_timeline(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    sender = scenario.start_agent("dummy", name="dummy-a")
    recipient = scenario.start_agent("dummy", name="dummy-b")
    calls: list[tuple[list[str], Path]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> mock.Mock:
        calls.append((cmd, kwargs["cwd"]))
        stdout = ".git\n" if cmd[:3] == ["git", "rev-parse", "--git-common-dir"] else ""
        return mock.Mock(stdout=stdout, stderr="", returncode=0)

    monkeypatch.setattr("tests.e2e.framework.scenario.subprocess.run", fake_run)

    scenario.send_dm(sender, recipient, "hello there")

    assert calls == [
        (["git", "rev-parse", "--git-common-dir"], scenario.workdir),
        (["c2c", "send", "--from", "dummy-a", "dummy-b", "hello there"], scenario.workdir),
    ]
    timeline = (scenario.artifacts.run_dir / "timeline.jsonl").read_text(encoding="utf-8")
    assert '"event": "dm.sent"' in timeline
    assert '"from_agent": "dummy-a"' in timeline
    assert '"to_agent": "dummy-b"' in timeline
    assert '"text": "hello there"' in timeline


def test_scenario_send_dm_preserves_controller_side_send_when_from_agent_is_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    recipient = scenario.start_agent("dummy", name="dummy-b")
    calls: list[tuple[list[str], Path]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> mock.Mock:
        calls.append((cmd, kwargs["cwd"]))
        stdout = ".git\n" if cmd[:3] == ["git", "rev-parse", "--git-common-dir"] else ""
        return mock.Mock(stdout=stdout, stderr="", returncode=0)

    monkeypatch.setattr("tests.e2e.framework.scenario.subprocess.run", fake_run)

    scenario.send_dm(None, recipient, "controller message")

    assert calls == [
        (["git", "rev-parse", "--git-common-dir"], scenario.workdir),
        (["c2c", "send", "dummy-b", "controller message"], scenario.workdir),
    ]
    timeline = (scenario.artifacts.run_dir / "timeline.jsonl").read_text(encoding="utf-8")
    assert '"event": "dm.sent"' in timeline
    assert '"from_agent": null' in timeline
    assert '"to_agent": "dummy-b"' in timeline
    assert '"text": "controller message"' in timeline


def test_scenario_broker_root_resolves_git_common_dir_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "worktree",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    calls: list[list[str]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> mock.Mock:
        calls.append(cmd)
        return mock.Mock(stdout="../.git-common\n", returncode=0)

    monkeypatch.setattr("tests.e2e.framework.scenario.subprocess.run", fake_run)

    first = scenario.broker_root()
    second = scenario.broker_root()

    expected = (scenario.workdir / "../.git-common" / "c2c" / "mcp").resolve()
    assert first == expected
    assert second == expected
    assert calls == [["git", "rev-parse", "--git-common-dir"]]


def test_scenario_broker_inbox_contains_matches_nested_json_text(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    agent = scenario.start_agent("dummy", name="dummy-b")
    broker_root = tmp_path / "broker"
    broker_root.mkdir(parents=True)
    (broker_root / "dummy-b.inbox.json").write_text(
        json.dumps([{"message": {"text": "hello there"}}]),
        encoding="utf-8",
    )
    monkeypatch.setattr(scenario, "broker_root", lambda: broker_root)

    assert scenario.broker_inbox_contains(agent, "hello there") is True
    assert scenario.broker_inbox_contains(agent, "not present") is False


def test_scenario_assert_agent_checks_liveness_and_registration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    driver = DummyDriver()
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": driver},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    agent = scenario.start_agent("dummy", name="dummy-a")
    broker_root = tmp_path / "broker"
    broker_root.mkdir(parents=True)
    (broker_root / "registry.json").write_text(
        json.dumps(
            [
                {"alias": "dummy-a", "alive": True},
                {"alias": "dummy-b", "alive": False},
            ]
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(scenario, "broker_root", lambda: broker_root)

    scenario.assert_agent(agent).alive()
    scenario.assert_agent(agent).registered_alive()

    monkeypatch.setattr(driver, "is_alive", lambda _handle: False)
    with pytest.raises(AssertionError, match="dummy-a is not alive"):
        scenario.assert_agent(agent).alive()

    monkeypatch.setattr(driver, "is_alive", lambda _handle: True)
    (broker_root / "registry.json").write_text(
        json.dumps([{"alias": "dummy-a", "alive": False}]),
        encoding="utf-8",
    )
    with pytest.raises(AssertionError, match="dummy-a is not registered alive in broker registry"):
        scenario.assert_agent(agent).registered_alive()


def test_scenario_require_binary_raises_for_missing_binary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"dummy": DummyDriver()},
        adapters={"dummy": DummyAdapter()},
    )

    monkeypatch.setattr(shutil, "which", lambda _name: None)

    with pytest.raises(AssertionError, match="required binary missing: missing-binary"):
        scenario.require_binary("missing-binary")


def test_cleanup_scenario_agents_continues_after_stop_failure(tmp_path: Path) -> None:
    failing_driver = FailingStopDriver()
    healthy_driver = DummyDriver()
    scenario = Scenario(
        test_name="test_demo",
        workdir=tmp_path / "work",
        artifacts=ArtifactCollector(tmp_path / "artifacts", "test_demo"),
        drivers={"failing": failing_driver, "healthy": healthy_driver},
        adapters={"dummy": DummyAdapter()},
    )
    scenario.artifacts.start_run()
    failing_agent = scenario.start_agent("dummy", name="dummy-a", backend="failing")
    healthy_agent = scenario.start_agent("dummy", name="dummy-b", backend="healthy")

    with pytest.raises(AssertionError, match="scenario cleanup failed: dummy-a: cannot stop dummy-1"):
        conftest_module._cleanup_scenario_agents(scenario)

    assert failing_driver.stopped == [failing_agent.handle]
    assert healthy_driver.stopped == [healthy_agent.handle]


def test_scenario_fixture_provides_workdir_and_artifacts(scenario) -> None:
    assert scenario.workdir.exists()
    assert scenario.artifacts.run_dir is not None
    assert scenario.artifacts.run_dir.exists()


def test_tmux_driver_start_uses_new_session_and_returns_pane_handle(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[tuple[list[str], dict[str, object]]] = []
    completed = mock.Mock(stdout="%42\n")

    def fake_run(cmd: list[str], **kwargs: object) -> mock.Mock:
        calls.append((cmd, kwargs))
        return completed

    monkeypatch.setattr("tests.e2e.framework.tmux_driver.subprocess.run", fake_run)

    driver = TmuxDriver(repo_root=tmp_path)
    handle = driver.start(
        TerminalStartSpec(
            command=["bash", "-lc", "echo hi"],
            cwd=tmp_path,
            env={"C2C_TEST_ENV": "alpha", "C2C_OTHER": "beta"},
            title="demo",
            cols=111,
            rows=37,
        )
    )

    assert handle.backend == "tmux"
    assert handle.target == "%42"
    cmd, kwargs = calls[0]
    assert cmd[:6] == ["tmux", "new-session", "-d", "-P", "-F", "#{pane_id}"]
    assert ["-x", "111"] == cmd[6:8]
    assert ["-y", "37"] == cmd[8:10]
    assert ["-e", "C2C_TEST_ENV=alpha", "-e", "C2C_OTHER=beta"] == cmd[10:14]
    assert cmd[14:16] == ["bash", "-lc"]
    assert cmd[16] == f"cd {shlex.quote(str(tmp_path))} && bash -lc 'echo hi'"
    assert "env" not in kwargs or kwargs["env"].get("C2C_TEST_ENV") != "alpha"


def test_tmux_driver_enter_uses_repo_helper(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[list[str]] = []

    def fake_run(cmd: list[str], **kwargs: object) -> mock.Mock:
        calls.append(cmd)
        return mock.Mock(stdout="")

    monkeypatch.setattr("tests.e2e.framework.tmux_driver.subprocess.run", fake_run)

    driver = TmuxDriver(repo_root=tmp_path)
    handle = TerminalHandle(backend="tmux", target="%99", process_pid=999)
    driver.send_key(handle, "Enter")

    assert calls[0][0] == str(tmp_path / "scripts" / "c2c-tmux-enter.sh")
    assert calls[0][1] == "%99"


def test_fake_pty_driver_round_trips_input(tmp_path: Path) -> None:
    from tests.e2e.framework.fake_pty_driver import FakePtyDriver

    driver = FakePtyDriver()
    handle = driver.start(
        TerminalStartSpec(
            command=[sys.executable, str(FAKE_TERMINAL_CHILD)],
            cwd=tmp_path,
            env={},
            title="fake-child",
        )
    )

    try:
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            capture = driver.capture(handle)
            if "READY" in capture.text:
                break
            time.sleep(0.05)
        else:
            raise AssertionError(driver.capture(handle).text)

        driver.send_text(handle, "hello")
        driver.send_key(handle, "Enter")

        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            capture = driver.capture(handle)
            if "ECHO: hello" in capture.text:
                break
            time.sleep(0.05)
        else:
            raise AssertionError(driver.capture(handle).text)

        assert driver.is_alive(handle) is True

        driver.send_text(handle, "/quit")
        driver.send_key(handle, "Enter")

        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            capture = driver.capture(handle)
            if "BYE" in capture.text:
                break
            time.sleep(0.05)
        else:
            raise AssertionError(driver.capture(handle).text)
    finally:
        driver.stop(handle)

    assert driver.is_alive(handle) is False


def test_fake_pty_driver_closes_openpty_fds_when_launch_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    from tests.e2e.framework import fake_pty_driver as fake_pty_driver_module
    from tests.e2e.framework.fake_pty_driver import FakePtyDriver

    closed: list[int] = []

    monkeypatch.setattr(fake_pty_driver_module.pty, "openpty", lambda: (11, 12))
    monkeypatch.setattr(fake_pty_driver_module.os, "set_blocking", lambda _fd, _flag: None)
    monkeypatch.setattr(fake_pty_driver_module.os, "close", lambda fd: closed.append(fd))
    monkeypatch.setattr(fake_pty_driver_module.fcntl, "ioctl", lambda *args: None)

    def fake_popen(*args: object, **kwargs: object) -> object:
        raise OSError("boom")

    monkeypatch.setattr(fake_pty_driver_module.subprocess, "Popen", fake_popen)

    driver = FakePtyDriver()

    with pytest.raises(OSError, match="boom"):
        driver.start(
            TerminalStartSpec(
                command=["/missing"],
                cwd=Path.cwd(),
                env={},
                title="broken",
            )
        )

    assert closed == [11, 12]


def test_fake_pty_driver_closes_openpty_fds_when_winsize_setup_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from tests.e2e.framework import fake_pty_driver as fake_pty_driver_module
    from tests.e2e.framework.fake_pty_driver import FakePtyDriver

    closed: list[int] = []

    monkeypatch.setattr(fake_pty_driver_module.pty, "openpty", lambda: (31, 32))
    monkeypatch.setattr(fake_pty_driver_module.os, "set_blocking", lambda _fd, _flag: None)
    monkeypatch.setattr(fake_pty_driver_module.os, "close", lambda fd: closed.append(fd))

    def fake_set_winsize(self: FakePtyDriver, slave_fd: int, *, rows: int, cols: int) -> None:
        raise OSError("winsize boom")

    monkeypatch.setattr(FakePtyDriver, "_set_winsize", fake_set_winsize)

    driver = FakePtyDriver()

    with pytest.raises(OSError, match="winsize boom"):
        driver.start(
            TerminalStartSpec(
                command=["/fake"],
                cwd=Path.cwd(),
                env={},
                title="broken-winsize",
            )
        )

    assert closed == [31, 32]


def test_fake_pty_driver_start_sets_winsize_from_terminal_spec(
    monkeypatch: pytest.MonkeyPatch
) -> None:
    from tests.e2e.framework import fake_pty_driver as fake_pty_driver_module
    from tests.e2e.framework.fake_pty_driver import FakePtyDriver

    ioctl_calls: list[tuple[int, int, bytes]] = []
    closed: list[int] = []

    class FakeProc:
        pid = 321

        def poll(self) -> int:
            return 0

    monkeypatch.setattr(fake_pty_driver_module.pty, "openpty", lambda: (21, 22))
    monkeypatch.setattr(fake_pty_driver_module.os, "set_blocking", lambda _fd, _flag: None)
    monkeypatch.setattr(fake_pty_driver_module.os, "close", lambda fd: closed.append(fd))
    monkeypatch.setattr(fake_pty_driver_module.subprocess, "Popen", lambda *args, **kwargs: FakeProc())

    def fake_ioctl(fd: int, op: int, arg: bytes) -> None:
        ioctl_calls.append((fd, op, arg))

    monkeypatch.setattr(fake_pty_driver_module.fcntl, "ioctl", fake_ioctl, raising=False)

    driver = FakePtyDriver()
    handle = driver.start(
        TerminalStartSpec(
            command=["/fake"],
            cwd=Path.cwd(),
            env={},
            title="sized-child",
            cols=111,
            rows=37,
        )
    )

    try:
        assert ioctl_calls == [
            (
                22,
                fake_pty_driver_module.termios.TIOCSWINSZ,
                fake_pty_driver_module.struct.pack("HHHH", 37, 111, 0, 0),
            )
        ]
        assert handle.process_pid == 321
    finally:
        driver.stop(handle)
    assert closed == [22, 21]


@pytest.mark.skipif(
    os.environ.get("C2C_TEST_TMUX") != "1" or shutil.which("tmux") is None,
    reason="set C2C_TEST_TMUX=1 and install tmux to run live tmux backend parity smoke",
)
def test_tmux_driver_can_run_same_fake_child(scenario) -> None:
    driver = scenario.drivers["tmux"]
    handle = driver.start(
        TerminalStartSpec(
            command=[sys.executable, str(FAKE_TERMINAL_CHILD)],
            cwd=scenario.workdir,
            env={},
            title="tmux-fake-child",
        )
    )

    try:
        scenario.wait_for(lambda: "READY" in driver.capture(handle).text, timeout=5.0)
        driver.send_text(handle, "hello")
        driver.send_key(handle, "Enter")
        scenario.wait_for(lambda: "ECHO: hello" in driver.capture(handle).text, timeout=5.0)
    finally:
        if driver.is_alive(handle):
            driver.send_text(handle, "/quit")
            driver.send_key(handle, "Enter")
        driver.stop(handle)
