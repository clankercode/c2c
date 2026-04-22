from __future__ import annotations

import json
import time
from pathlib import Path


class ArtifactCollector:
    def __init__(self, root: Path, test_name: str) -> None:
        self.root = root
        self.test_name = test_name
        self.run_dir: Path | None = None

    def start_run(self) -> Path:
        run_id = time.strftime("%Y%m%d-%H%M%S")
        self.run_dir = self.root / self.test_name / run_id
        self.run_dir.mkdir(parents=True, exist_ok=True)
        (self.run_dir / "timeline.jsonl").write_text("", encoding="utf-8")
        return self.run_dir

    def append_event(self, event: str, payload: dict[str, object]) -> None:
        assert self.run_dir is not None
        path = self.run_dir / "timeline.jsonl"
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"event": event, **payload}) + "\n")

    def write_text(self, name: str, text: str) -> Path:
        assert self.run_dir is not None
        path = self.run_dir / name
        path.write_text(text, encoding="utf-8")
        return path

    def compare_golden(self, stem: str, actual: str, golden_path: Path) -> None:
        expected = golden_path.read_text(encoding="utf-8")
        if actual != expected:
            self.write_text(f"{stem}.actual.txt", actual)
            raise AssertionError(f"{stem} did not match golden snapshot {golden_path}")
