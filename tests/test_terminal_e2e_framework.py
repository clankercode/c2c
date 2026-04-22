from pathlib import Path
import json

import pytest

from tests.e2e.framework.artifacts import ArtifactCollector
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
