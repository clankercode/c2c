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
        if self.run_dir is not None:
            raise RuntimeError("start_run() may only be called once per collector")
        self._require_safe_fragment(self.test_name, "test_name")
        run_id = time.strftime("%Y%m%d-%H%M%S")
        base_dir = self.root / self.test_name
        suffix = 1
        base_dir.mkdir(parents=True, exist_ok=True)
        while True:
            run_dir = base_dir / run_id if suffix == 1 else base_dir / f"{run_id}-{suffix - 1}"
            try:
                run_dir.mkdir(parents=True, exist_ok=False)
            except FileExistsError:
                suffix += 1
                continue
            self.run_dir = run_dir
            (self.run_dir / "timeline.jsonl").write_text("", encoding="utf-8")
            return self.run_dir

    def append_event(self, event: str, payload: dict[str, object]) -> None:
        path = self._require_run_dir() / "timeline.jsonl"
        with path.open("a", encoding="utf-8") as fh:
            entry = {"event": event, **{k: v for k, v in payload.items() if k != "event"}}
            fh.write(json.dumps(entry, default=self._json_default) + "\n")

    def write_text(self, name: str, text: str) -> Path:
        self._require_safe_fragment(name, "artifact name")
        path = self._require_run_dir() / name
        path.write_text(text, encoding="utf-8")
        return path

    def compare_golden(self, stem: str, actual: str, golden_path: Path) -> None:
        self._require_safe_fragment(stem, "artifact stem")
        expected = golden_path.read_text(encoding="utf-8")
        if actual != expected:
            self.write_text(f"{stem}.actual.txt", actual)
            raise AssertionError(f"{stem} did not match golden snapshot {golden_path}")

    def _require_run_dir(self) -> Path:
        if self.run_dir is None:
            raise RuntimeError("start_run() must be called first")
        return self.run_dir

    @staticmethod
    def _json_default(value: object) -> object:
        if isinstance(value, Path):
            return str(value)
        raise TypeError(f"Object of type {value.__class__.__name__} is not JSON serializable")

    @staticmethod
    def _require_safe_fragment(fragment: str, label: str) -> None:
        path = Path(fragment)
        if (
            path.is_absolute()
            or len(path.parts) != 1
            or fragment in {"", ".", ".."}
            or any(part in {"", ".", ".."} for part in path.parts)
        ):
            raise ValueError(f"unsafe path fragment for {label}: {fragment!r}")
