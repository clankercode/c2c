#!/usr/bin/env python3
"""Integration tests for remote relay transport (GET /remote_inbox/<session_id>).

These tests spin up a real OCaml relay server with remote broker flags,
set up a fake broker dir in /tmp, and exercise the HTTP endpoint including:
- Path length: /remote_inbox/ is 14 chars (regression test for off-by-one)
- Auth gate: unauthenticated requests are rejected when token is set
- Dev mode: no-token means open access

Gated behind C2C_TEST_REMOTE_RELAY=1 so CI stays green by default.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

import pytest

C2C_BIN = shutil.which("c2c")

pytestmark = [
    pytest.mark.skipif(C2C_BIN is None, reason="c2c binary not on PATH"),
    pytest.mark.skipif(os.environ.get("C2C_TEST_REMOTE_RELAY") != "1",
                       reason="set C2C_TEST_REMOTE_RELAY=1 to enable"),
]


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class RelayClient:
    """Minimal synchronous HTTP client for the relay server."""

    def __init__(self, base_url: str, token: str | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        url = f"{self.base_url}{path}"
        data = json.dumps(body or {}).encode() if body is not None else b""
        req = urllib.request.Request(url, data=data or None, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return (resp.status, json.loads(resp.read()))
        except urllib.error.HTTPError as exc:
            try:
                return (exc.code, json.loads(exc.read()))
            finally:
                exc.close()

    def get(self, path: str) -> tuple[int, dict]:
        return self._request("GET", path)


def wait_for_relay(host: str, port: int, proc: subprocess.Popen, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"relay process exited: {proc.poll()}")
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.1)
    raise TimeoutError("relay server did not start")


class TestRemoteInboxAuth(unittest.TestCase):
    """Auth gate tests for GET /remote_inbox/<session_id>."""

    @classmethod
    def setUpClass(cls):
        cls.token = "test-secret-token"
        cls.port = find_free_port()
        cls.broker_root = Path(tempfile.mkdtemp(prefix="c2c-remote-relay-auth-"))
        cls.inbox_dir = cls.broker_root / "inbox"
        cls.inbox_dir.mkdir()
        cls.fake_session = "test-session-abc123"
        inbox_path = cls.inbox_dir / f"{cls.fake_session}.json"
        inbox_path.write_text(
            json.dumps([
                {
                    "message_id": "msg-001",
                    "from_alias": "sender-a",
                    "to_alias": "test-session-abc123",
                    "content": "hello from remote broker",
                    "ts": 1776880000.0,
                }
            ]),
            encoding="utf-8",
        )
        cls.relay_url = f"http://127.0.0.1:{cls.port}"
        cls.proc = subprocess.Popen(
            [
                C2C_BIN, "relay", "serve",
                "--listen", f"127.0.0.1:{cls.port}",
                "--token", cls.token,
                "--remote-broker-ssh-target", "localhost",
                "--remote-broker-root", str(cls.broker_root),
                "--remote-broker-id", "test-broker",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "C2C_MCP_SESSION_ID": ""},
        )
        wait_for_relay("127.0.0.1", cls.port, cls.proc)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        shutil.rmtree(cls.broker_root, ignore_errors=True)

    def test_health_no_auth_required(self):
        """GET /health is always accessible without auth."""
        client = RelayClient(self.relay_url)
        status, body = client.get("/health")
        self.assertEqual(status, 200, body)
        self.assertTrue(body.get("ok"))

    def test_remote_inbox_with_bearer_ok(self):
        """GET /remote_inbox/<session_id> with valid Bearer returns messages."""
        client = RelayClient(self.relay_url, token=self.token)
        status, body = client.get(f"/remote_inbox/{self.fake_session}")
        self.assertEqual(status, 200, body)
        self.assertIsInstance(body.get("messages"), list)
        self.assertEqual(len(body["messages"]), 1)
        self.assertEqual(body["messages"][0]["message_id"], "msg-001")

    def test_remote_inbox_without_auth_rejected(self):
        """GET /remote_inbox/<session_id> without auth returns 401."""
        client = RelayClient(self.relay_url)
        status, body = client.get(f"/remote_inbox/{self.fake_session}")
        self.assertEqual(status, 401, f"expected 401, got {status}: {body}")
        self.assertFalse(body.get("ok"))
        self.assertIn("error", body)

    def test_remote_inbox_with_wrong_bearer_rejected(self):
        """GET /remote_inbox/<session_id> with wrong Bearer returns 401."""
        client = RelayClient(self.relay_url, token="wrong-token")
        status, body = client.get(f"/remote_inbox/{self.fake_session}")
        self.assertEqual(status, 401, f"expected 401, got {status}: {body}")

    def test_remote_inbox_nonexistent_session(self):
        """GET /remote_inbox/<nonexistent> returns empty messages, not 401."""
        client = RelayClient(self.relay_url, token=self.token)
        status, body = client.get("/remote_inbox/nonexistent-session-xyz")
        self.assertEqual(status, 200, body)
        self.assertIsInstance(body.get("messages"), list)
        self.assertEqual(len(body["messages"]), 0)


class TestRemoteInboxPathLength(unittest.TestCase):
    """Regression test: /remote_inbox/ is 14 chars, not 13.

    Off-by-one bug: the route match used String.sub path 0 13 which truncated
    the prefix, so /remote_inbox/<id> always 404'd.
    """

    @classmethod
    def setUpClass(cls):
        cls.token = "path-len-test-token"
        cls.port = find_free_port()
        cls.broker_root = Path(tempfile.mkdtemp(prefix="c2c-remote-relay-pathlen-"))
        cls.inbox_dir = cls.broker_root / "inbox"
        cls.inbox_dir.mkdir()
        cls.relay_url = f"http://127.0.0.1:{cls.port}"
        cls.proc = subprocess.Popen(
            [
                C2C_BIN, "relay", "serve",
                "--listen", f"127.0.0.1:{cls.port}",
                "--token", cls.token,
                "--remote-broker-ssh-target", "localhost",
                "--remote-broker-root", str(cls.broker_root),
                "--remote-broker-id", "pathlen-test",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "C2C_MCP_SESSION_ID": ""},
        )
        wait_for_relay("127.0.0.1", cls.port, cls.proc)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        shutil.rmtree(cls.broker_root, ignore_errors=True)

    def test_path_prefix_is_14_chars(self):
        """The string '/remote_inbox/' must be exactly 14 characters."""
        prefix = "/remote_inbox/"
        self.assertEqual(len(prefix), 14, f"prefix should be 14 chars, got {len(prefix)}")

    def test_various_session_id_formats(self):
        """Path parsing works for various session ID formats."""
        client = RelayClient(self.relay_url, token=self.token)
        test_cases = [
            "simple-session",
            "my-session-123",
            "foo_bar",
            "a",
            "x" * 64,
        ]
        for session_id in test_cases:
            with self.subTest(session_id=session_id):
                status, body = client.get(f"/remote_inbox/{session_id}")
                self.assertEqual(status, 200, f"failed for {session_id}: {body}")
                self.assertIsInstance(body.get("messages"), list)


class TestRemoteInboxDevMode(unittest.TestCase):
    """Dev mode tests: when no token is set, auth is disabled."""

    @classmethod
    def setUpClass(cls):
        cls.port = find_free_port()
        cls.broker_root = Path(tempfile.mkdtemp(prefix="c2c-remote-relay-devmode-"))
        cls.inbox_dir = cls.broker_root / "inbox"
        cls.inbox_dir.mkdir()
        cls.fake_session = "dev-mode-session"
        inbox_path = cls.inbox_dir / f"{cls.fake_session}.json"
        inbox_path.write_text(
            json.dumps([
                {
                    "message_id": "dev-msg-001",
                    "from_alias": "dev-sender",
                    "to_alias": "dev-mode-session",
                    "content": "dev mode message",
                    "ts": 1776880001.0,
                }
            ]),
            encoding="utf-8",
        )
        cls.relay_url = f"http://127.0.0.1:{cls.port}"
        cls.proc = subprocess.Popen(
            [
                C2C_BIN, "relay", "serve",
                "--listen", f"127.0.0.1:{cls.port}",
                "--remote-broker-ssh-target", "localhost",
                "--remote-broker-root", str(cls.broker_root),
                "--remote-broker-id", "devmode-test",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "C2C_MCP_SESSION_ID": ""},
        )
        wait_for_relay("127.0.0.1", cls.port, cls.proc)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)
        shutil.rmtree(cls.broker_root, ignore_errors=True)

    def test_dev_mode_no_token_allows_unauthenticated_access(self):
        """When no token is configured, /remote_inbox/ is accessible without auth."""
        client = RelayClient(self.relay_url)
        status, body = client.get(f"/remote_inbox/{self.fake_session}")
        self.assertEqual(status, 200, f"dev mode should allow no-auth: {body}")
        self.assertEqual(len(body.get("messages", [])), 1)


if __name__ == "__main__":
    unittest.main()
