"""Tests for c2c_relay_gc — relay GC daemon.

Uses a live relay server on an ephemeral port.
"""
from __future__ import annotations

import json
import sys
import time
import unittest
from io import StringIO

sys.path.insert(0, ".")

from c2c_relay_contract import InMemoryRelay
from c2c_relay_server import start_server_thread
import c2c_relay_gc as gc_cli


def _make_server() -> tuple:
    token = "test-gc-token"
    server, _thread = start_server_thread(port=0, token=token)
    _, port = server.server_address
    url = f"http://127.0.0.1:{port}"
    return server, url, token


class TestRelayGcOnce(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()

    def tearDown(self):
        self.server.shutdown()

    def _run(self, extra_argv: list[str] | None = None) -> tuple[int, str]:
        argv = ["--relay-url", self.url, "--token", self.token, "--once"]
        argv += (extra_argv or [])
        buf = StringIO()
        old = sys.stdout
        sys.stdout = buf
        try:
            rc = gc_cli.main(argv)
        finally:
            sys.stdout = old
        return rc, buf.getvalue()

    def test_gc_once_returns_0(self):
        rc, _ = self._run()
        self.assertEqual(rc, 0)

    def test_gc_once_json(self):
        rc, out = self._run(["--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertTrue(data["ok"])
        # GC result should have these keys (matching InMemoryRelay.gc() shape)
        self.assertIn("expired_leases", data)
        self.assertIn("pruned_inboxes", data)

    def test_gc_removes_expired_session(self):
        relay = self.server.relay
        # Register with very short TTL
        relay.register("n1", "s1", "zombie", ttl=0.001)
        # Fast-forward: manually tick expiry by sleeping just a bit
        time.sleep(0.05)

        rc, out = self._run(["--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertGreaterEqual(len(data["expired_leases"]), 1)
        self.assertIn("zombie", data["expired_leases"])

    def test_gc_leaves_live_sessions(self):
        relay = self.server.relay
        relay.register("n1", "s1", "live-agent", ttl=300)

        rc, out = self._run(["--json"])
        self.assertEqual(rc, 0)
        data = json.loads(out)
        # live session should NOT be in expired_leases
        self.assertNotIn("live-agent", data["expired_leases"])

        # Confirm still listed
        peers = relay.list_peers(include_dead=False)
        aliases = [p["alias"] for p in peers]
        self.assertIn("live-agent", aliases)

    def test_gc_bad_url_returns_1(self):
        argv = ["--relay-url", "http://127.0.0.1:1", "--token", "x", "--once"]
        rc = gc_cli.main(argv)
        self.assertEqual(rc, 1)


class TestRelayGcVerbose(unittest.TestCase):
    def setUp(self):
        self.server, self.url, self.token = _make_server()

    def tearDown(self):
        self.server.shutdown()

    def test_gc_verbose_logs_to_stderr(self):
        argv = ["--relay-url", self.url, "--token", self.token, "--once", "--verbose"]
        buf = StringIO()
        old = sys.stderr
        sys.stderr = buf
        try:
            rc = gc_cli.main(argv)
        finally:
            sys.stderr = old
        self.assertEqual(rc, 0)
        self.assertIn("relay gc", buf.getvalue())


class TestRelayGcNoConfig(unittest.TestCase):
    def test_no_url_returns_1(self):
        # No relay config saved, no --relay-url → should return 1
        import os
        env_backup = {k: os.environ.pop(k, None)
                      for k in ("C2C_RELAY_URL", "C2C_RELAY_TOKEN")}
        try:
            rc = gc_cli.main(["--once"])
        finally:
            for k, v in env_backup.items():
                if v is not None:
                    os.environ[k] = v
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
