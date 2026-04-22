from pathlib import Path
import json
import shutil

import pytest

from tests import conftest as conftest_module
from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.scenario import Scenario
from tests.e2e.framework.terminal_driver import TerminalCapture, TerminalHandle


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

    with pytest.warns(RuntimeWarning, match="best-effort cleanup"):
        conftest_module._cleanup_scenario_agents(scenario)

    assert failing_driver.stopped == [failing_agent.handle]
    assert healthy_driver.stopped == [healthy_agent.handle]


def test_scenario_fixture_provides_workdir_and_artifacts(scenario) -> None:
    assert scenario.workdir.exists()
    assert scenario.artifacts.run_dir is not None
    assert scenario.artifacts.run_dir.exists()
