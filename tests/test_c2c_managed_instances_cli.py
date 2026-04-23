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
        self.assertEqual(len(payload), 1)
        self.assertEqual(payload[0]["name"], "opencode-test")
        self.assertEqual(payload[0]["delivery_mode"], "plugin")

    def test_status_json_includes_managed_instances_with_delivery_mode(self):
        broker_root = self.home / ".git" / "c2c" / "mcp"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text("[]", encoding="utf-8")

        result = self._run("status", "--json")
        payload = json.loads(result.stdout)
        self.assertIn("managed_instances", payload)
        self.assertEqual(len(payload["managed_instances"]), 1)
        self.assertEqual(payload["managed_instances"][0]["name"], "opencode-test")
        self.assertEqual(payload["managed_instances"][0]["delivery_mode"], "plugin")
