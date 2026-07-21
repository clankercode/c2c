"""Regression coverage for the standalone ``c2c_send_all`` client.

Kept in its own file so it does not conflict with the long-running lock on
``tests/test_c2c_cli.py`` while the ``c2c inject`` slice is in flight.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def run_send_all(
    *,
    from_alias: str,
    message: str,
    broker_root: Path,
    exclude: list[str] | None = None,
    session_id: str = "c2c-send-all-test",
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session_id
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    env["C2C_MCP_AUTO_REGISTER_ALIAS"] = ""  # prevent live-session alias from leaking
    env["C2C_REGISTRY_PATH"] = str(broker_root / "isolated-yaml-registry.yaml")
    env["C2C_SESSIONS_FIXTURE"] = str(broker_root / "isolated-sessions.json")
    if extra_env:
        env.update(extra_env)
    args = [
        sys.executable,
        str(REPO / "c2c_send_all.py"),
        "--from-alias",
        from_alias,
        message,
        "--json",
        "--broker-root",
        str(broker_root),
    ]
    for alias in exclude or []:
        args.extend(["--exclude", alias])
    return subprocess.run(
        args, cwd=REPO, capture_output=True, text=True, env=env, timeout=30
    )


class C2CSendAllTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _write_registry(self, entries: list[dict]) -> None:
        (self.broker_root / "registry.json").write_text(
            json.dumps(entries), encoding="utf-8"
        )

    def _read_inbox(self, session_id: str) -> list[dict]:
        path = self.broker_root / f"{session_id}.inbox.json"
        if not path.exists():
            return []
        return json.loads(path.read_text(encoding="utf-8"))

    def test_fans_out_to_every_live_peer_and_skips_sender(self) -> None:
        self._write_registry(
            [
                {"session_id": "alice-local", "alias": "alice"},
                {"session_id": "bob-local", "alias": "bob"},
                {"session_id": "caller", "alias": "me"},
            ]
        )

        result = run_send_all(
            from_alias="me", message="hello swarm", broker_root=self.broker_root
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(sorted(payload["sent_to"]), ["alice", "bob"])
        self.assertEqual(payload["skipped"], [])
        self.assertEqual(
            self._read_inbox("alice-local"),
            [{"from_alias": "me", "to_alias": "alice", "content": "hello swarm"}],
        )
        self.assertEqual(
            self._read_inbox("bob-local"),
            [{"from_alias": "me", "to_alias": "bob", "content": "hello swarm"}],
        )
        self.assertEqual(self._read_inbox("caller"), [])

    def test_exclude_aliases_drops_named_peers(self) -> None:
        self._write_registry(
            [
                {"session_id": "alice-local", "alias": "alice"},
                {"session_id": "bob-local", "alias": "bob"},
                {"session_id": "caller", "alias": "me"},
            ]
        )

        result = run_send_all(
            from_alias="me",
            message="just to bob",
            broker_root=self.broker_root,
            exclude=["alice"],
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["sent_to"], ["bob"])
        self.assertEqual(self._read_inbox("alice-local"), [])
        self.assertEqual(
            self._read_inbox("bob-local"),
            [{"from_alias": "me", "to_alias": "bob", "content": "just to bob"}],
        )

    def test_missing_argument_exits_with_error(self) -> None:
        env = os.environ.copy()
        env["C2C_MCP_BROKER_ROOT"] = str(self.broker_root)
        result = subprocess.run(
            [sys.executable, str(REPO / "c2c_send_all.py"), "--json", "no-from-alias"],
            cwd=REPO,
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--from-alias", result.stderr)


if __name__ == "__main__":
    unittest.main()
