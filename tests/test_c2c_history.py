"""Tests for c2c_history.py — session message archive reader."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

# Allow import from repo root
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import c2c_history


def _write_archive(broker_root: Path, session_id: str, entries: list[dict]) -> None:
    archive_dir = broker_root / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    path = archive_dir / f"{session_id}.jsonl"
    path.write_text(
        "".join(json.dumps(e) + "\n" for e in entries),
        encoding="utf-8",
    )


class C2CHistoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_read_archive_returns_entries(self) -> None:
        entries = [
            {"drained_at": 1.0, "from_alias": "alice", "to_alias": "bob", "content": "hello"},
            {"drained_at": 2.0, "from_alias": "charlie", "to_alias": "bob", "content": "world"},
        ]
        _write_archive(self.broker_root, "bob-session", entries)
        result = c2c_history.read_archive(self.broker_root, "bob-session", limit=50)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["from_alias"], "alice")
        self.assertEqual(result[1]["from_alias"], "charlie")

    def test_read_archive_missing_returns_empty(self) -> None:
        result = c2c_history.read_archive(self.broker_root, "nonexistent-session", limit=50)
        self.assertEqual(result, [])

    def test_read_archive_limit_returns_newest(self) -> None:
        entries = [
            {"drained_at": float(i), "from_alias": "x", "to_alias": "y", "content": str(i)}
            for i in range(10)
        ]
        _write_archive(self.broker_root, "test-session", entries)
        result = c2c_history.read_archive(self.broker_root, "test-session", limit=3)
        self.assertEqual(len(result), 3)
        # Should be the last 3 entries
        self.assertEqual(result[0]["content"], "7")
        self.assertEqual(result[2]["content"], "9")

    def test_read_archive_limit_zero_returns_all(self) -> None:
        entries = [
            {"drained_at": float(i), "from_alias": "x", "to_alias": "y", "content": str(i)}
            for i in range(5)
        ]
        _write_archive(self.broker_root, "test-session", entries)
        result = c2c_history.read_archive(self.broker_root, "test-session", limit=0)
        self.assertEqual(len(result), 5)

    def test_list_archive_sessions(self) -> None:
        _write_archive(self.broker_root, "alice-session", [])
        _write_archive(self.broker_root, "bob-session", [])
        sessions = c2c_history.list_archive_sessions(self.broker_root)
        self.assertIn("alice-session", sessions)
        self.assertIn("bob-session", sessions)
        self.assertEqual(len(sessions), 2)

    def test_list_archive_sessions_empty_dir(self) -> None:
        sessions = c2c_history.list_archive_sessions(self.broker_root)
        self.assertEqual(sessions, [])

    def test_main_json_output(self) -> None:
        entries = [
            {"drained_at": 1.0, "from_alias": "alice", "to_alias": "bob", "content": "hi"},
        ]
        _write_archive(self.broker_root, "bob-session", entries)
        old_stdout = sys.stdout
        from io import StringIO
        sys.stdout = StringIO()
        rc = c2c_history.main([
            "--session-id", "bob-session",
            "--broker-root", str(self.broker_root),
            "--json",
        ])
        output = sys.stdout.getvalue()
        sys.stdout = old_stdout
        self.assertEqual(rc, 0)
        data = json.loads(output)
        self.assertEqual(data["session_id"], "bob-session")
        self.assertEqual(data["count"], 1)
        self.assertEqual(data["messages"][0]["from_alias"], "alice")

    def test_main_list_sessions_json(self) -> None:
        _write_archive(self.broker_root, "my-session", [])
        from io import StringIO
        old_stdout = sys.stdout
        sys.stdout = StringIO()
        rc = c2c_history.main([
            "--broker-root", str(self.broker_root),
            "--list-sessions",
            "--json",
        ])
        output = sys.stdout.getvalue()
        sys.stdout = old_stdout
        self.assertEqual(rc, 0)
        data = json.loads(output)
        self.assertIn("my-session", data["sessions"])

    def test_main_no_session_id_returns_error(self) -> None:
        env_backup = {k: os.environ.pop(k, None)
                      for k in ("C2C_MCP_SESSION_ID", "RUN_CLAUDE_INST_C2C_SESSION_ID",
                                "RUN_CODEX_INST_C2C_SESSION_ID")}
        try:
            rc = c2c_history.main(["--broker-root", str(self.broker_root)])
            self.assertEqual(rc, 1)
        finally:
            for k, v in env_backup.items():
                if v is not None:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
