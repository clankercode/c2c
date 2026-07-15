import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
C2C_BUILD_BIN = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"


@unittest.skipUnless(C2C_BUILD_BIN.exists(), f"built c2c binary not found at {C2C_BUILD_BIN}")
class ManagedInstancesCLITests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.home = Path(self.temp_dir)
        now = datetime.now(timezone.utc)
        first_active_at = (now - timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
        last_active_at = now.isoformat().replace("+00:00", "Z")
        self.instance_dir = self.home / ".local" / "share" / "c2c" / "instances" / "opencode-test"
        self.instance_dir.mkdir(parents=True, exist_ok=True)
        (self.instance_dir / "config.json").write_text(
            json.dumps(
                {
                    "name": "opencode-test",
                    "client": "opencode",
                    "session_id": "opencode-test",
                    "resume_session_id": "",
                    "alias": "opencode-test",
                    "extra_args": [],
                    "created_at": 1713910800.0,
                    "broker_root": "/tmp/broker",
                    "auto_join_rooms": "swarm-lounge",
                }
            ),
            encoding="utf-8",
        )
        (self.instance_dir / "outer.pid").write_text("999999\n", encoding="utf-8")
        (self.instance_dir / "oc-plugin-state.json").write_text(
            json.dumps(
                {
                    "event": "state.snapshot",
                    "ts": last_active_at,
                    "state": {
                        "c2c_session_id": "opencode-test",
                        "state_last_updated_at": last_active_at,
                        "activity_sources": {
                            "plugin": {
                                "source_type": "plugin",
                                "first_active_at": first_active_at,
                                "last_active_at": last_active_at,
                                "heartbeat_interval_ms": 10000,
                            }
                        },
                    },
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _run(self, *args: str) -> subprocess.CompletedProcess:
        C2C_BUILD_BIN.chmod(0o755)
        env = {
            **os.environ,
            "HOME": str(self.home),
            "C2C_MCP_BROKER_ROOT": str(self.home / ".git" / "c2c" / "mcp"),
        }
        return subprocess.run(
            [str(C2C_BUILD_BIN), *args],
            check=True,
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
        )

    def test_instances_json_includes_delivery_mode(self):
        result = self._run("instances", "--json")
        payload = json.loads(result.stdout)
        self.assertEqual(payload["alive"], 0)
        self.assertEqual(payload["total"], 1)
        self.assertTrue(payload["filtered"])
        self.assertEqual(payload["instances"], [])

        result = self._run("instances", "--all", "--json")
        payload = json.loads(result.stdout)
        self.assertEqual(len(payload["instances"]), 1)
        self.assertEqual(payload["instances"][0]["name"], "opencode-test")
        self.assertEqual(payload["instances"][0]["delivery_mode"], "plugin")

    def test_status_json_includes_managed_instances_with_delivery_mode(self):
        (self.instance_dir / "outer.pid").write_text(
            f"{os.getpid()}\n", encoding="utf-8"
        )
        broker_root = self.home / ".git" / "c2c" / "mcp"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text("[]", encoding="utf-8")

        result = self._run("status", "--json")
        payload = json.loads(result.stdout)
        self.assertIn("managed_instances", payload)
        self.assertEqual(len(payload["managed_instances"]), 1)
        self.assertEqual(payload["managed_instances"][0]["name"], "opencode-test")
        self.assertEqual(payload["managed_instances"][0]["delivery_mode"], "plugin")

    def test_dev_instances_reports_active_agy_identity_and_deliver_watch(self):
        agy_dir = (
            self.home / ".local" / "share" / "c2c" / "instances" / "agy-window-a"
        )
        agy_dir.mkdir(parents=True, exist_ok=True)
        (agy_dir / "config.json").write_text(
            json.dumps(
                {
                    "name": "agy-window-a",
                    "client": "agy",
                    "session_id": "agy-window-a",
                    "created_at": 1713910800.0,
                }
            ),
            encoding="utf-8",
        )
        (agy_dir / "outer.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        (agy_dir / "deliver.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        agy_metadata_dir = self.home / ".c2c" / "instances" / "agy-window-a"
        agy_metadata_dir.mkdir(parents=True, exist_ok=True)
        (agy_metadata_dir / "agy-env.json").write_text(
            json.dumps(
                {
                    "ls_address": "http://127.0.0.1:43123",
                    "conversation_id": "conversation-7f3a",
                }
            ),
            encoding="utf-8",
        )

        result = self._run("dev", "instances", "--json")
        payload = json.loads(result.stdout)
        agy = next(item for item in payload["instances"] if item["client"] == "agy")
        self.assertEqual(
            agy["agy"],
            {
                "session_id": "agy-window-a",
                "ls_address": "http://127.0.0.1:43123",
                "conversation_id": "conversation-7f3a",
                "deliver_watch": {"status": "running", "pid": os.getpid()},
            },
        )
        human = self._run("dev", "instances").stdout
        self.assertIn("session=agy-window-a", human)
        self.assertIn("conversation=conversation-7f3a", human)
        self.assertIn("ls=http://127.0.0.1:43123", human)
        self.assertIn(f"deliver-watch=running(pid={os.getpid()})", human)

    def test_dev_instances_rejects_malformed_agy_ls_addresses_without_leaking(self):
        agy_dir = (
            self.home / ".local" / "share" / "c2c" / "instances" / "agy-window-malformed"
        )
        agy_dir.mkdir(parents=True, exist_ok=True)
        (agy_dir / "config.json").write_text(
            json.dumps({"name": "agy-window-malformed", "client": "agy"}),
            encoding="utf-8",
        )
        (agy_dir / "outer.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
        metadata_dir = self.home / ".c2c" / "instances" / "agy-window-malformed"
        metadata_dir.mkdir(parents=True, exist_ok=True)

        malformed = [
            "http://operator:credential-secret@127.0.0.1:43123",
            "http://127.0.0.1:43123\\backslash-secret",
            "http://127.0.0.1:43123/authority-secret",
            "http://127.0.0.1:43123\x01control-secret",
            "not-an-authority-secret",
        ]
        for address in malformed:
            with self.subTest(address=address):
                (metadata_dir / "agy-env.json").write_text(
                    json.dumps({"ls_address": address, "conversation_id": "conversation-safe"}),
                    encoding="utf-8",
                )
                result = self._run("dev", "instances", "--json")
                payload = json.loads(result.stdout)
                agy = next(
                    item for item in payload["instances"]
                    if item["name"] == "agy-window-malformed"
                )
                self.assertIsNone(agy["agy"]["ls_address"])
                self.assertNotIn("secret", result.stdout)

                human = self._run("dev", "instances").stdout
                self.assertNotIn("secret", human)

    def test_dev_instances_ignores_non_positive_agy_deliver_pidfiles(self):
        agy_dir = (
            self.home / ".local" / "share" / "c2c" / "instances" / "agy-window-pid"
        )
        agy_dir.mkdir(parents=True, exist_ok=True)
        (agy_dir / "config.json").write_text(
            json.dumps({"name": "agy-window-pid", "client": "agy"}),
            encoding="utf-8",
        )
        (agy_dir / "outer.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")

        for pid, expected in ((0, {"status": "not-found", "pid": None}),
                              (-1, {"status": "not-found", "pid": None}),
                              (999999, {"status": "stopped", "pid": 999999})):
            with self.subTest(pid=pid):
                (agy_dir / "deliver.pid").write_text(f"{pid}\n", encoding="utf-8")
                result = self._run("dev", "instances", "--json")
                payload = json.loads(result.stdout)
                agy = next(
                    item for item in payload["instances"] if item["name"] == "agy-window-pid"
                )
                self.assertEqual(agy["agy"]["deliver_watch"], expected)

    def test_dev_instances_reports_missing_agy_metadata_without_proc_lookup(self):
        agy_dir = (
            self.home / ".local" / "share" / "c2c" / "instances" / "agy-window-b"
        )
        agy_dir.mkdir(parents=True, exist_ok=True)
        (agy_dir / "config.json").write_text(
            json.dumps({"name": "agy-window-b", "client": "agy"}),
            encoding="utf-8",
        )
        (agy_dir / "outer.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")

        result = self._run("dev", "instances", "--json")
        payload = json.loads(result.stdout)
        agy = next(item for item in payload["instances"] if item["client"] == "agy")
        self.assertEqual(agy["agy"]["session_id"], "agy-window-b")
        self.assertIsNone(agy["agy"]["ls_address"])
        self.assertIsNone(agy["agy"]["conversation_id"])
        self.assertEqual(
            agy["agy"]["deliver_watch"], {"status": "not-found", "pid": None}
        )
