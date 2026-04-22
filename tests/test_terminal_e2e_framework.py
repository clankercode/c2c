from pathlib import Path

import pytest

from e2e.framework.artifacts import ArtifactCollector
from e2e.framework.terminal_driver import TerminalCapture, TerminalHandle


def test_artifact_collector_creates_run_dir_and_timeline(tmp_path: Path) -> None:
    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    run_dir = collector.start_run()

    assert run_dir.parent == tmp_path / "test_demo"
    assert (run_dir / "timeline.jsonl").exists()


def test_artifact_collector_writes_actual_on_golden_mismatch(tmp_path: Path) -> None:
    golden = tmp_path / "golden.txt"
    golden.write_text("expected screen\n", encoding="utf-8")

    collector = ArtifactCollector(root=tmp_path, test_name="test_demo")
    collector.start_run()

    with pytest.raises(AssertionError):
        collector.compare_golden("screen", "actual screen\n", golden)

    assert (collector.run_dir / "screen.actual.txt").exists()


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
    assert capture.text == "READY\n"
