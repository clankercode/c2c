#!/usr/bin/env python3
"""Tests for c2c_relay_config + c2c_relay_status — Phase 5 operator setup."""
from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from c2c_relay_config import (  # noqa: E402
    default_config_path,
    load_config,
    resolve_relay_params,
    save_config,
)
from c2c_relay_server import start_server_thread  # noqa: E402
from c2c_relay_status import cmd_list, cmd_status  # noqa: E402


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

class RelayConfigTests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.config_path = Path(self._tmpdir.name) / "relay.json"

    def tearDown(self):
        self._tmpdir.cleanup()

    def test_load_config_missing_returns_empty(self):
        cfg = load_config(self.config_path)
        self.assertEqual(cfg, {})

    def test_save_and_load_roundtrip(self):
        data = {"url": "http://localhost:7331", "token": "secret"}
        save_config(data, self.config_path)
        loaded = load_config(self.config_path)
        self.assertEqual(loaded["url"], "http://localhost:7331")
        self.assertEqual(loaded["token"], "secret")

    def test_save_creates_parent_dirs(self):
        nested = Path(self._tmpdir.name) / "a" / "b" / "relay.json"
        save_config({"url": "http://x"}, nested)
        self.assertTrue(nested.exists())

    def test_resolve_relay_params_cli_overrides_config(self):
        save_config({"url": "http://from-config", "token": "cfg-token"}, self.config_path)
        params = resolve_relay_params(
            url="http://cli-override",
            token="cli-token",
            config_path=self.config_path,
        )
        self.assertEqual(params["url"], "http://cli-override")
        self.assertEqual(params["token"], "cli-token")

    def test_resolve_relay_params_falls_back_to_config(self):
        save_config({"url": "http://from-config", "token": "cfg-token"}, self.config_path)
        params = resolve_relay_params(config_path=self.config_path)
        self.assertEqual(params["url"], "http://from-config")
        self.assertEqual(params["token"], "cfg-token")

    def test_resolve_relay_params_empty_when_no_config(self):
        params = resolve_relay_params(config_path=self.config_path)
        self.assertEqual(params["url"], "")
        self.assertEqual(params["token"], "")

    def test_resolve_relay_params_node_id(self):
        params = resolve_relay_params(node_id="my-node", config_path=self.config_path)
        self.assertEqual(params["node_id"], "my-node")


class RelayConfigCLITests(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.config_path = str(Path(self._tmpdir.name) / "relay.json")

    def tearDown(self):
        self._tmpdir.cleanup()

    def _run(self, *args):
        import c2c_relay_config
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = c2c_relay_config.main(
                ["--config", self.config_path] + list(args)
            )
        return rc, buf.getvalue()

    def test_setup_saves_config(self):
        rc, _ = self._run("--url", "http://test:7331")
        self.assertEqual(rc, 0)
        loaded = load_config(Path(self.config_path))
        self.assertEqual(loaded["url"], "http://test:7331")

    def test_setup_json_output(self):
        rc, out = self._run("--url", "http://test:7331", "--json")
        self.assertEqual(rc, 0)
        payload = json.loads(out)
        self.assertTrue(payload["ok"])
        self.assertIn("config_path", payload)

    def test_setup_show_existing(self):
        save_config({"url": "http://saved:7331"}, Path(self.config_path))
        rc, out = self._run("--show")
        self.assertEqual(rc, 0)
        self.assertIn("http://saved:7331", out)

    def test_setup_show_json(self):
        save_config({"url": "http://x"}, Path(self.config_path))
        rc, out = self._run("--show", "--json")
        self.assertEqual(rc, 0)
        payload = json.loads(out)
        self.assertIn("config", payload)

    def test_setup_missing_url_fails(self):
        import c2c_relay_config
        rc = c2c_relay_config.main(["--config", self.config_path])
        self.assertNotEqual(rc, 0)


# ---------------------------------------------------------------------------
# Status + list against a live server
# ---------------------------------------------------------------------------

class RelayStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, _ = start_server_thread("127.0.0.1", 0, token="stat-token")
        port = cls.server.server_address[1]
        cls.url = f"http://127.0.0.1:{port}"
        cls.token = "stat-token"
        # Register a peer for list tests
        from c2c_relay_connector import RelayClient
        client = RelayClient(cls.url, token=cls.token)
        sfx = str(int(time.time() * 1000))
        client.register("node-stat", f"sess-stat-{sfx}", f"stat-peer-{sfx}",
                        client_type="codex")
        cls._peer_alias = f"stat-peer-{sfx}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_status_returns_0(self):
        rc = cmd_status(self.url, self.token, "test-node")
        self.assertEqual(rc, 0)

    def test_status_json(self):
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cmd_status(self.url, self.token, "test-node", json_out=True)
        self.assertEqual(rc, 0)
        payload = json.loads(buf.getvalue())
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["relay_alive"])
        self.assertIn("alive_peers", payload)
        self.assertIn("total_peers", payload)

    def test_status_unreachable_returns_1(self):
        rc = cmd_status("http://127.0.0.1:1", "", "test-node")
        self.assertEqual(rc, 1)

    def test_list_returns_0(self):
        rc = cmd_list(self.url, self.token)
        self.assertEqual(rc, 0)

    def test_list_json_contains_peers(self):
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cmd_list(self.url, self.token, json_out=True)
        self.assertEqual(rc, 0)
        payload = json.loads(buf.getvalue())
        self.assertTrue(payload["ok"])
        aliases = [p["alias"] for p in payload["peers"]]
        self.assertIn(self._peer_alias, aliases)

    def test_list_unreachable_returns_1(self):
        rc = cmd_list("http://127.0.0.1:1", "")
        self.assertEqual(rc, 1)

    def test_list_dead_flag(self):
        rc = cmd_list(self.url, self.token, include_dead=True)
        self.assertEqual(rc, 0)


class RelayCLIDispatchTests(unittest.TestCase):
    """Smoke-test that c2c relay subcommands dispatch correctly."""

    def test_relay_setup_via_cli(self):
        with tempfile.TemporaryDirectory() as d:
            config_path = str(Path(d) / "relay.json")
            import c2c_relay_config
            rc = c2c_relay_config.main(
                ["--url", "http://test:7331", "--config", config_path]
            )
            self.assertEqual(rc, 0)
            loaded = load_config(Path(config_path))
            self.assertEqual(loaded["url"], "http://test:7331")

    def test_relay_status_missing_url(self):
        import c2c_relay_status, io
        from contextlib import redirect_stderr
        buf = io.StringIO()
        with redirect_stderr(buf):
            rc = c2c_relay_status.main(["status",
                                        "--relay-url", "http://127.0.0.1:1"])
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
