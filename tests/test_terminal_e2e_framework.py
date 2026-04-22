from pathlib import Path
import json
import importlib.util
import sys

import pytest

_FRAMEWORK_DIR = Path(__file__).resolve().parent / "e2e" / "framework"

_artifacts_spec = importlib.util.spec_from_file_location(
    "tests.e2e.framework.artifacts",
    _FRAMEWORK_DIR / "artifacts.py",
)
assert _artifacts_spec is not None and _artifacts_spec.loader is not None
_artifacts_module = importlib.util.module_from_spec(_artifacts_spec)
sys.modules[_artifacts_spec.name] = _artifacts_module
_artifacts_spec.loader.exec_module(_artifacts_module)
ArtifactCollector = _artifacts_module.ArtifactCollector

_driver_spec = importlib.util.spec_from_file_location(
    "tests.e2e.framework.terminal_driver",
    _FRAMEWORK_DIR / "terminal_driver.py",
)
assert _driver_spec is not None and _driver_spec.loader is not None
_driver_module = importlib.util.module_from_spec(_driver_spec)
sys.modules[_driver_spec.name] = _driver_module
_driver_spec.loader.exec_module(_driver_module)
TerminalCapture = _driver_module.TerminalCapture
TerminalHandle = _driver_module.TerminalHandle


def test_artifact_collector_creates_run_dir_and_timeline(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    run_dir = collector.start_run()

    assert run_dir.parent == tmp_path / "test_demo"
    assert (run_dir / "timeline.jsonl").exists()


def test_artifact_collector_creates_distinct_run_dir_for_same_second_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(_artifacts_module.time, "strftime", lambda _fmt: "20260422-123456")

    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    first = collector.start_run()
    second = collector.start_run()

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
