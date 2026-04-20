import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_dead_letter
import c2c_mcp


class WakePeerTests(unittest.TestCase):
    """Tests for c2c_wake_peer.wake_peer()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def test_unknown_alias_returns_error(self):
        import c2c_wake_peer

        rc = c2c_wake_peer.wake_peer("no-such-agent", broker_root=self.broker_root)
        self.assertEqual(rc, 1)

    def test_dead_pid_returns_error(self):
        import c2c_wake_peer

        self._write_registry(
            [
                {
                    "alias": "dead-agent",
                    "session_id": "sid-dead",
                    "pid": 99999999,
                    "pid_start_time": 1,
                },
            ]
        )
        rc = c2c_wake_peer.wake_peer("dead-agent", broker_root=self.broker_root)
        self.assertEqual(rc, 1)

    def test_dry_run_does_not_call_subprocess(self):
        import c2c_wake_peer

        self._write_registry(
            [
                {
                    "alias": "live-agent",
                    "session_id": "sid-live",
                    "pid": os.getpid(),
                    "pid_start_time": c2c_mcp.read_pid_start_time(os.getpid()),
                },
            ]
        )
        # dry-run should succeed without side effects
        rc = c2c_wake_peer.wake_peer(
            "live-agent", broker_root=self.broker_root, dry_run=True
        )
        self.assertEqual(rc, 0)

    def test_json_output_for_unknown_alias(self):
        import c2c_wake_peer
        import io

        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = c2c_wake_peer.wake_peer(
                "missing", broker_root=self.broker_root, json_out=True
            )
        self.assertEqual(rc, 1)
        out = json.loads(buf.getvalue())
        self.assertFalse(out["ok"])
        self.assertIn("not found", out["error"])

    def test_json_output_redacts_embedded_deliver_messages(self):
        import c2c_wake_peer
        import io

        self._write_registry(
            [
                {
                    "alias": "live-agent",
                    "session_id": "sid-live",
                    "pid": os.getpid(),
                    "pid_start_time": c2c_mcp.read_pid_start_time(os.getpid()),
                },
            ]
        )
        deliver_stdout = json.dumps(
            {
                "ok": True,
                "messages": [
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "live-agent",
                        "content": "SECRET_WAKE_BODY",
                    }
                ],
                "delivered": 0,
                "notified": True,
            }
        )

        buf = io.StringIO()
        with (
            mock.patch(
                "c2c_wake_peer.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout=deliver_stdout, stderr=""),
            ),
            mock.patch("sys.stdout", buf),
        ):
            rc = c2c_wake_peer.wake_peer(
                "live-agent", broker_root=self.broker_root, json_out=True
            )

        self.assertEqual(rc, 0)
        raw_output = buf.getvalue()
        self.assertNotIn("SECRET_WAKE_BODY", raw_output)
        out = json.loads(raw_output)
        self.assertEqual(out["deliver_result"]["message_count"], 1)
        self.assertEqual(out["deliver_result"]["messages"], [])
        self.assertTrue(out["deliver_result"]["messages_redacted"])


class RefreshPeerTests(unittest.TestCase):
    """Tests for c2c_refresh_peer.refresh_peer()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        self.registry_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _read_registry(self):
        return json.loads(self.registry_path.read_text(encoding="utf-8"))

    def test_refresh_peer_unknown_alias_raises(self):
        """refresh_peer exits with error for unknown alias."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "other-agent", "pid": 99999}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("missing-alias", None, self.broker_root)

    def test_refresh_peer_accepts_session_id_when_alias_drifted(self):
        """refresh_peer can recover a row when alias drifted from session_id."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        self._write_registry(
            [
                {
                    "session_id": "kimi-nova",
                    "alias": "kimi-nova-2",
                    "pid": 99999,
                }
            ]
        )

        result = c2c_refresh_peer.refresh_peer(
            "kimi-nova", new_pid, self.broker_root, session_id="kimi-nova"
        )

        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["alias"], "kimi-nova-2")
        self.assertEqual(result["matched_by"], "session_id")
        regs = self._read_registry()
        self.assertEqual(regs[0]["alias"], "kimi-nova-2")
        self.assertEqual(regs[0]["session_id"], "kimi-nova")
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_alive_registration_returns_no_change(self):
        """When current registration is already alive, no-arg refresh says so."""
        import c2c_refresh_peer

        live_pid = os.getpid()
        self._write_registry([{"session_id": "s1", "alias": "me", "pid": live_pid}])
        result = c2c_refresh_peer.refresh_peer("me", None, self.broker_root)
        self.assertEqual(result["status"], "already_alive")
        self.assertEqual(result["pid"], live_pid)

    def test_refresh_peer_dead_pid_no_arg_raises(self):
        """When registration has dead PID and no new PID given, raises."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "stale-agent", "pid": 11111}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("stale-agent", None, self.broker_root)

    def test_refresh_peer_updates_pid(self):
        """refresh_peer with explicit live PID updates the registry row."""
        import c2c_refresh_peer

        old_pid = 11111  # dead
        new_pid = os.getpid()  # definitely alive
        self._write_registry(
            [{"session_id": "s1", "alias": "opencode-local", "pid": old_pid}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "opencode-local", new_pid, self.broker_root
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["old_pid"], old_pid)
        self.assertEqual(result["new_pid"], new_pid)

        regs = self._read_registry()
        self.assertEqual(len(regs), 1)
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_refuses_dead_new_pid(self):
        """refresh_peer refuses to update to a PID that is not in /proc."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "opencode-local", "pid": 11111}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("opencode-local", 11111, self.broker_root)

    def test_refresh_peer_dry_run_does_not_write(self):
        """--dry-run reports intended change but does not modify registry."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        original = [{"session_id": "s1", "alias": "opencode-local", "pid": 99999}]
        self._write_registry(original)
        result = c2c_refresh_peer.refresh_peer(
            "opencode-local", new_pid, self.broker_root, dry_run=True
        )
        self.assertEqual(result["status"], "dry_run")
        # Registry must be unchanged
        regs = self._read_registry()
        self.assertEqual(regs[0]["pid"], 99999)

    def test_cli_refresh_peer_subcommand_wired(self):
        """c2c refresh-peer is reachable via the main CLI dispatcher."""
        result = subprocess.run(
            [sys.executable, str(REPO / "c2c_cli.py"), "refresh-peer", "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("alias", result.stdout)

    def test_refresh_peer_updates_session_id(self):
        """refresh_peer with session_id corrects a stale session_id in the registry."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        old_session_id = "opencode-c2c-msg"
        new_session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        self._write_registry(
            [{"session_id": old_session_id, "alias": "storm-beacon", "pid": 99999}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon", new_pid, self.broker_root, session_id=new_session_id
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result.get("old_session_id"), old_session_id)
        self.assertEqual(result.get("new_session_id"), new_session_id)

        regs = self._read_registry()
        self.assertEqual(regs[0]["session_id"], new_session_id)
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_session_id_unchanged_not_reported(self):
        """When session_id matches, no old/new_session_id keys appear in result."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        self._write_registry(
            [{"session_id": session_id, "alias": "storm-beacon", "pid": 99999}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon", new_pid, self.broker_root, session_id=session_id
        )
        self.assertEqual(result["status"], "updated")
        self.assertNotIn("old_session_id", result)
        self.assertNotIn("new_session_id", result)

    def test_refresh_peer_dry_run_reports_session_id_change(self):
        """dry_run with session_id reports the intended change without writing."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        old_session_id = "opencode-c2c-msg"
        new_session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        original = [
            {"session_id": old_session_id, "alias": "storm-beacon", "pid": 99999}
        ]
        self._write_registry(original)
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon",
            new_pid,
            self.broker_root,
            session_id=new_session_id,
            dry_run=True,
        )
        self.assertEqual(result["status"], "dry_run")
        self.assertEqual(result.get("old_session_id"), old_session_id)
        self.assertEqual(result.get("new_session_id"), new_session_id)
        # Registry must be unchanged
        regs = self._read_registry()
        self.assertEqual(regs[0]["session_id"], old_session_id)
        self.assertEqual(regs[0]["pid"], 99999)


class DeadLetterReplayTests(unittest.TestCase):
    """Tests for c2c_dead_letter replay behavior."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        dl_path.write_text(
            "\n".join(json.dumps(record) for record in records) + "\n",
            encoding="utf-8",
        )
        return dl_path

    def test_replay_dry_run_uses_explicit_root_for_broker_resolution(self):
        self._write_registry([{"alias": "target", "session_id": "target-session"}])
        dl_path = self._write_dead_letter(
            [
                {
                    "deleted_at": time.time(),
                    "from_session_id": "orphan-session",
                    "message": {
                        "from_alias": "sender",
                        "to_alias": "target",
                        "content": "recover me",
                    },
                },
            ]
        )
        original_content = dl_path.read_text(encoding="utf-8")

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": ""}, clear=False):
            with (
                mock.patch("sys.stdout", new=stdout),
                mock.patch("sys.stderr", new=stderr),
            ):
                result = c2c_dead_letter.main(
                    [
                        "--root",
                        str(self.broker_root),
                        "--replay",
                        "--to",
                        "target",
                        "--dry-run",
                    ]
                )

        self.assertEqual(result, 0, stderr.getvalue())
        self.assertIn("[DRY] 1. -> target: broker:target-session", stdout.getvalue())
        self.assertIn("replay result: 1/1 sent, 0 failed", stdout.getvalue())
        self.assertEqual(dl_path.read_text(encoding="utf-8"), original_content)

    def test_replay_does_not_replace_loaded_c2c_send_module(self):
        loaded_module = sys.modules["c2c_send"]

        stdout = io.StringIO()
        with mock.patch("sys.stdout", new=stdout):
            result = c2c_dead_letter.replay_records(
                [], dry_run=True, broker_root=self.broker_root
            )

        self.assertIs(sys.modules["c2c_send"], loaded_module)
        self.assertEqual(result["sent"], 0)
        self.assertEqual(result["failed"], [])


class PurgeOldDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc.purge_old_dead_letter()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        lines = [json.dumps(r) for r in records]
        dl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return dl_path

    def test_no_file_returns_empty_ok(self):
        """Returns ok with zero counts when dead-letter.jsonl does not exist."""
        import c2c_broker_gc

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["after_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purges_expired_entries(self):
        """Entries older than TTL are removed; recent entries are kept."""
        import c2c_broker_gc

        now = time.time()
        old_ts = now - 200
        new_ts = now - 10
        records = [
            {
                "deleted_at": old_ts,
                "from_session_id": "s1",
                "message": {"content": "old"},
            },
            {
                "deleted_at": new_ts,
                "from_session_id": "s2",
                "message": {"content": "new"},
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=100)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["after_count"], 1)
        self.assertEqual(result["purged_count"], 1)

        remaining = [
            json.loads(l) for l in dl_path.read_text().splitlines() if l.strip()
        ]
        self.assertEqual(len(remaining), 1)
        self.assertEqual(remaining[0]["from_session_id"], "s2")

    def test_dry_run_does_not_modify_file(self):
        """dry_run=True reports would-purge count but does not touch the file."""
        import c2c_broker_gc

        now = time.time()
        records = [
            {"deleted_at": now - 200, "from_session_id": "s1", "message": {}},
        ]
        dl_path = self._write_dead_letter(records)
        original_content = dl_path.read_text()

        result = c2c_broker_gc.purge_old_dead_letter(
            self.broker_root, ttl_seconds=100, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(dl_path.read_text(), original_content)

    def test_keeps_all_when_nothing_expired(self):
        """No entries are purged when all are within TTL."""
        import c2c_broker_gc

        now = time.time()
        records = [
            {"deleted_at": now - 10, "from_session_id": "s1", "message": {}},
            {"deleted_at": now - 20, "from_session_id": "s2", "message": {}},
        ]
        self._write_dead_letter(records)

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["after_count"], 2)
        self.assertEqual(result["purged_count"], 0)

    def test_malformed_lines_kept(self):
        """Lines that cannot be parsed as JSON are kept (safe default)."""
        import c2c_broker_gc

        dl_path = self.broker_root / "dead-letter.jsonl"
        dl_path.write_text(
            'not-valid-json\n{"deleted_at": 1, "from_session_id": "s"}\n',
            encoding="utf-8",
        )

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=60)
        self.assertTrue(result["ok"])
        # The valid record (ts=1) is very old and should be purged; the malformed line stays
        remaining = [l for l in dl_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(remaining), 1)
        self.assertIn("not-valid-json", remaining[0])


class PurgeOrphanDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc.purge_orphan_dead_letter()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        lines = [json.dumps(r) for r in records]
        dl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return dl_path

    def test_no_file_returns_empty_ok(self):
        """Returns ok with zero counts when dead-letter.jsonl does not exist."""
        import c2c_broker_gc

        result = c2c_broker_gc.purge_orphan_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purges_entry_when_alias_unregistered(self):
        """Entry is purged when to_alias is not in registry and older than TTL."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "live-alice",
                    "to_alias": "gone-bob",
                    "content": "hi",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 0)
        remaining = [l for l in dl_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(remaining), 0)

    def test_keeps_entry_when_alias_registered(self):
        """Entry is kept when to_alias IS in the registry (will redeliver on re-register)."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "live-alice",
                    "content": "hi",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_strips_room_suffix_for_matching(self):
        """Room fan-out messages (to_alias='alice@room') match if base alias 'alice' is registered."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            # alice@swarm-lounge → base alias live-alice IS registered → keep
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "live-alice#swarm-lounge",
                    "content": "room msg",
                },
            },
            # gone-bob@swarm-lounge → base alias gone-bob NOT registered → purge
            {
                "deleted_at": now - 7200,
                "from_session_id": "s3",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "gone-bob#swarm-lounge",
                    "content": "room msg",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 1)
        remaining = [
            json.loads(l) for l in dl_path.read_text().splitlines() if l.strip()
        ]
        self.assertEqual(remaining[0]["message"]["to_alias"], "live-alice#swarm-lounge")

    def test_keeps_entry_within_ttl(self):
        """Recent entries are kept even if the alias is not registered."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry([])
        records = [
            {
                "deleted_at": now - 30,
                "from_session_id": "s1",
                "message": {
                    "from_alias": "x",
                    "to_alias": "gone-bob",
                    "content": "recent",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_dry_run_does_not_modify_file(self):
        """dry_run=True reports would-purge count without touching the file."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry([])
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s1",
                "message": {
                    "from_alias": "x",
                    "to_alias": "gone-alias",
                    "content": "old",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)
        original = dl_path.read_text()

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(dl_path.read_text(), original)


class SweepDeadRegistrationsTests(unittest.TestCase):
    """Tests for c2c_broker_gc.sweep_dead_registrations()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _read_registry(self):
        reg_path = self.broker_root / "registry.json"
        return json.loads(reg_path.read_text(encoding="utf-8"))

    def test_no_registry_returns_empty_ok(self):
        import c2c_broker_gc

        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["removed_count"], 0)

    def test_keeps_live_pid(self):
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "alive", "session_id": "s1", "pid": os.getpid()}]
        )
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def _dead_pid(self) -> int:
        """Return a PID that is guaranteed to be dead."""
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def test_sweeps_dead_pid(self):
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s2", "pid": dead_pid}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 1)
        self.assertEqual(result["after_count"], 0)

    def test_keeps_pidless_registration(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "pidless", "session_id": "s3"}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 0)

    def test_dry_run_does_not_modify_registry(self):
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s1", "pid": dead_pid}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["removed_count"], 1)
        # Registry unchanged
        regs = self._read_registry()
        self.assertEqual(len(regs), 1)

    def test_lock_file_created_by_sweep(self):
        """sweep_dead_registrations should create registry.json.lock (POSIX lockf sidecar)."""
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "live", "session_id": "s1", "pid": os.getpid()}]
        )
        c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        lock_path = self.broker_root / "registry.json.lock"
        self.assertTrue(
            lock_path.exists(), "registry.json.lock should exist after sweep"
        )

    def test_atomic_write_no_temp_files(self):
        """sweep_dead_registrations should leave no .tmp files behind."""
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s1", "pid": dead_pid}])
        c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        tmp_files = list(self.broker_root.glob(".registry.json.*.tmp"))
        self.assertEqual(tmp_files, [], f"no temp files should remain: {tmp_files}")

    def test_with_registry_lock_interlocks(self):
        """with_registry_lock must produce the registry.json.lock sidecar used by OCaml."""
        import c2c_broker_gc

        with c2c_broker_gc.with_registry_lock(self.broker_root):
            lock_path = self.broker_root / "registry.json.lock"
            self.assertTrue(lock_path.exists())

    def test_main_uses_env_broker_root_without_importing_c2c_mcp(self):
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "live", "session_id": "s1", "pid": os.getpid()}]
        )
        env = {"C2C_MCP_BROKER_ROOT": str(self.broker_root)}
        with mock.patch.dict(os.environ, env, clear=False):
            with mock.patch("sys.stdout", new=io.StringIO()):
                result = c2c_broker_gc.main(["--once", "--dry-run", "--json"])
        self.assertEqual(result, 0)

class BrokerGcDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc dead-letter purge functions."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_dead_letter(self, lines):
        dl_path = self.broker_root / "dead-letter.jsonl"
        content = "\n".join(lines)
        if content and not content.endswith("\n"):
            content += "\n"
        dl_path.write_text(content, encoding="utf-8")

    def _read_dead_letter(self):
        dl_path = self.broker_root / "dead-letter.jsonl"
        if not dl_path.exists():
            return []
        return [
            line
            for line in dl_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def test_purge_old_no_file_returns_empty(self):
        import c2c_broker_gc

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purge_old_keeps_fresh_entries(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps({"deleted_at": now - 100, "message": {"to_alias": "alice"}}),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_purge_old_removes_stale_entries(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 0)

    def test_purge_old_malformed_line_kept(self):
        import c2c_broker_gc

        self._write_dead_letter(
            [
                "not-json",
                json.dumps(
                    {
                        "deleted_at": time.time() - 10000,
                        "message": {"to_alias": "alice"},
                    }
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["purged_count"], 1)
        lines = self._read_dead_letter()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0], "not-json")

    def test_purge_old_dry_run_no_modify(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 1)

    def test_purge_orphan_no_file_returns_empty(self):
        import c2c_broker_gc

        result = c2c_broker_gc.purge_orphan_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)

    def test_purge_orphan_keeps_registered_alias(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(len(self._read_dead_letter()), 1)

    def test_purge_orphan_removes_unregistered_alias(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps({"deleted_at": now - 10000, "message": {"to_alias": "bob"}}),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 0)

    def test_purge_orphan_strips_room_suffix(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {
                        "deleted_at": now - 10000,
                        "message": {"to_alias": "bob#swarm-lounge"},
                    }
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 1)

    def test_purge_orphan_dry_run_no_modify(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "orphan"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 1)


class PruneDeadMembersTests(unittest.TestCase):
    """Tests for c2c_room.prune_dead_members()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.rooms_root = self.broker_root / "rooms"
        self.rooms_root.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, aliases: list[str]) -> None:
        regs = [{"session_id": f"s-{a}", "alias": a} for a in aliases]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )

    def _write_members(self, room_id: str, members: list[str]) -> None:
        rdir = self.rooms_root / room_id
        rdir.mkdir(parents=True, exist_ok=True)
        (rdir / "members.json").write_text(
            json.dumps([{"alias": a, "session_id": f"s-{a}"} for a in members]),
            encoding="utf-8",
        )

    def _read_members(self, room_id: str) -> list[str]:
        p = self.rooms_root / room_id / "members.json"
        return [m["alias"] for m in json.loads(p.read_text(encoding="utf-8"))]

    def test_room_not_found_returns_error(self):
        import c2c_room

        result = c2c_room.prune_dead_members(
            "nonexistent", broker_root=self.broker_root
        )
        self.assertFalse(result["ok"])

    def test_removes_unregistered_members(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice", "gone"])

        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["removed"], ["gone"])
        self.assertEqual(result["after_count"], 1)
        self.assertEqual(self._read_members("test-room"), ["alice"])

    def test_keeps_all_when_all_registered(self):
        import c2c_room

        self._write_registry(["alice", "bob"])
        self._write_members("test-room", ["alice", "bob"])

        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertEqual(result["removed"], [])
        self.assertEqual(result["after_count"], 2)

    def test_dry_run_does_not_modify(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice", "gone"])

        result = c2c_room.prune_dead_members(
            "test-room", broker_root=self.broker_root, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["removed"], ["gone"])
        # Members file unchanged
        self.assertEqual(self._read_members("test-room"), ["alice", "gone"])

    def test_empty_registry_removes_all(self):
        import c2c_room

        self._write_registry([])
        self._write_members("test-room", ["smoke1", "smoke2"])
        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertEqual(result["after_count"], 0)
        self.assertEqual(len(result["removed"]), 2)
        self.assertEqual(self._read_members("test-room"), [])

    def test_lock_file_created(self):
        """prune_dead_members should create members.lock (POSIX lockf sidecar)."""
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice"])
        c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        lock_path = self.rooms_root / "test-room" / "members.lock"
        self.assertTrue(lock_path.exists(), "members.lock should be created by prune")

    def test_prune_all_rooms_prunes_every_room(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("room-a", ["alice", "ghost-a"])
        self._write_members("room-b", ["alice", "ghost-b"])

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["rooms_processed"], 2)
        self.assertEqual(result["total_removed"], 2)
        self.assertEqual(self._read_members("room-a"), ["alice"])
        self.assertEqual(self._read_members("room-b"), ["alice"])

    def test_prune_all_rooms_dry_run_does_not_modify(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("room-a", ["alice", "ghost"])

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["total_removed"], 1)
        # Members file must be unchanged
        self.assertEqual(self._read_members("room-a"), ["alice", "ghost"])

    def test_prune_all_rooms_empty_rooms_dir(self):
        import c2c_room

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["rooms_processed"], 0)
        self.assertEqual(result["total_removed"], 0)


class SweepDryrunTests(unittest.TestCase):
    """Unit tests for c2c_sweep_dryrun pure functions."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir) / "broker"
        self.broker_root.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    # --- load_registry ---

    def test_load_registry_empty_list(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        self.assertEqual(c2c_sweep_dryrun.load_registry(self.broker_root), [])

    def test_load_registry_missing_file(self):
        import c2c_sweep_dryrun

        self.assertEqual(c2c_sweep_dryrun.load_registry(self.broker_root), [])

    def test_load_registry_valid_entries(self):
        import c2c_sweep_dryrun

        regs = [{"session_id": "s1", "alias": "a1", "pid": 1234}]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )
        result = c2c_sweep_dryrun.load_registry(self.broker_root)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["alias"], "a1")

    def test_load_registry_invalid_json_exits(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("not json", encoding="utf-8")
        with self.assertRaises(SystemExit):
            c2c_sweep_dryrun.load_registry(self.broker_root)

    def test_load_registry_non_list_exits(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text(
            '{"not": "a list"}', encoding="utf-8"
        )
        with self.assertRaises(SystemExit):
            c2c_sweep_dryrun.load_registry(self.broker_root)

    # --- pid_is_alive ---

    def test_pid_is_alive_none_pid(self):
        import c2c_sweep_dryrun

        self.assertTrue(c2c_sweep_dryrun.pid_is_alive(None, None))

    def test_pid_is_alive_current_process(self):
        import c2c_sweep_dryrun

        self.assertTrue(c2c_sweep_dryrun.pid_is_alive(os.getpid(), None))

    def test_pid_is_alive_dead_pid(self):
        import c2c_sweep_dryrun

        self.assertFalse(c2c_sweep_dryrun.pid_is_alive(999999999, None))

    def test_pid_is_alive_mismatched_start_time(self):
        import c2c_sweep_dryrun

        # Use a start_time of 0 which won't match any real process
        self.assertFalse(c2c_sweep_dryrun.pid_is_alive(os.getpid(), 0))

    def test_pid_is_alive_matching_start_time(self):
        import c2c_sweep_dryrun

        # Read the actual starttime from /proc to verify match
        stat_path = Path(f"/proc/{os.getpid()}/stat")
        raw = stat_path.read_text()
        tail = raw[raw.rindex(")") + 2 :]
        fields = tail.split()
        real_start_time = int(fields[19])
        self.assertTrue(
            c2c_sweep_dryrun.pid_is_alive(os.getpid(), real_start_time)
        )

    # --- collect_inboxes ---

    def test_collect_inboxes_empty(self):
        import c2c_sweep_dryrun

        self.assertEqual(c2c_sweep_dryrun.collect_inboxes(self.broker_root), {})

    def test_collect_inboxes_finds_inbox_files(self):
        import c2c_sweep_dryrun

        (self.broker_root / "s1.inbox.json").write_text("[]", encoding="utf-8")
        (self.broker_root / "s2.inbox.json").write_text('[{"a":1}]', encoding="utf-8")
        # Non-inbox file should be ignored
        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")

        result = c2c_sweep_dryrun.collect_inboxes(self.broker_root)
        self.assertIn("s1", result)
        self.assertIn("s2", result)
        self.assertNotIn("registry", result)

    def test_collect_inboxes_missing_dir(self):
        import c2c_sweep_dryrun

        self.assertEqual(
            c2c_sweep_dryrun.collect_inboxes(Path("/nonexistent/path")), {}
        )

    # --- inbox_message_count ---

    def test_inbox_message_count_valid(self):
        import c2c_sweep_dryrun

        p = self.broker_root / "test.inbox.json"
        p.write_text('[{"a":1}, {"b":2}]', encoding="utf-8")
        self.assertEqual(c2c_sweep_dryrun.inbox_message_count(p), 2)

    def test_inbox_message_count_empty(self):
        import c2c_sweep_dryrun

        p = self.broker_root / "test.inbox.json"
        p.write_text("[]", encoding="utf-8")
        self.assertEqual(c2c_sweep_dryrun.inbox_message_count(p), 0)

    def test_inbox_message_count_missing_file(self):
        import c2c_sweep_dryrun

        p = self.broker_root / "nonexistent.inbox.json"
        self.assertIsNone(c2c_sweep_dryrun.inbox_message_count(p))

    def test_inbox_message_count_invalid_json(self):
        import c2c_sweep_dryrun

        p = self.broker_root / "test.inbox.json"
        p.write_text("not json", encoding="utf-8")
        self.assertIsNone(c2c_sweep_dryrun.inbox_message_count(p))

    def test_inbox_message_count_non_list(self):
        import c2c_sweep_dryrun

        p = self.broker_root / "test.inbox.json"
        p.write_text('{"not": "a list"}', encoding="utf-8")
        self.assertIsNone(c2c_sweep_dryrun.inbox_message_count(p))

    # --- archive_activity_counts ---

    def test_archive_activity_counts_empty(self):
        import c2c_sweep_dryrun

        self.assertEqual(c2c_sweep_dryrun.archive_activity_counts(self.broker_root), {})

    def test_archive_activity_counts_counts_from_and_to(self):
        import c2c_sweep_dryrun

        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir()
        entry = {"from_alias": "alice", "to_alias": "bob", "content": "hi"}
        (archive_dir / "s1.jsonl").write_text(
            json.dumps(entry) + "\n" + json.dumps(entry) + "\n",
            encoding="utf-8",
        )
        counts = c2c_sweep_dryrun.archive_activity_counts(self.broker_root)
        # s1 gets 2 (file lines), alice gets 2 (from_alias), bob gets 2 (to_alias)
        self.assertEqual(counts["s1"], 2)
        self.assertEqual(counts["alice"], 2)
        self.assertEqual(counts["bob"], 2)

    def test_archive_activity_counts_skips_blank_lines(self):
        import c2c_sweep_dryrun

        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir()
        (archive_dir / "s1.jsonl").write_text(
            json.dumps({"from_alias": "a"}) + "\n\n\n",
            encoding="utf-8",
        )
        counts = c2c_sweep_dryrun.archive_activity_counts(self.broker_root)
        self.assertEqual(counts["s1"], 1)
        self.assertEqual(counts["a"], 1)

    def test_archive_activity_counts_skips_bad_json(self):
        import c2c_sweep_dryrun

        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir()
        (archive_dir / "s1.jsonl").write_text(
            "bad json\n" + json.dumps({"from_alias": "a"}) + "\n",
            encoding="utf-8",
        )
        counts = c2c_sweep_dryrun.archive_activity_counts(self.broker_root)
        # bad json line still counts as a file line for s1
        self.assertEqual(counts["s1"], 2)
        self.assertEqual(counts["a"], 1)

    # --- registration_activity ---

    def test_registration_activity_no_activity(self):
        import c2c_sweep_dryrun

        reg = {"session_id": "s1", "alias": "a1"}
        self.assertEqual(c2c_sweep_dryrun.registration_activity(reg, {}), 0)

    def test_registration_activity_matches_session_id(self):
        import c2c_sweep_dryrun

        reg = {"session_id": "s1", "alias": "a1"}
        self.assertEqual(
            c2c_sweep_dryrun.registration_activity(reg, {"s1": 5}), 5
        )

    def test_registration_activity_matches_alias(self):
        import c2c_sweep_dryrun

        reg = {"session_id": "s1", "alias": "a1"}
        self.assertEqual(
            c2c_sweep_dryrun.registration_activity(reg, {"a1": 3}), 3
        )

    def test_registration_activity_sums_both(self):
        import c2c_sweep_dryrun

        reg = {"session_id": "s1", "alias": "a1"}
        self.assertEqual(
            c2c_sweep_dryrun.registration_activity(reg, {"s1": 2, "a1": 3}), 5
        )

    # --- analyze ---

    def test_analyze_empty_registry(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(report["totals"]["registrations"], 0)
        self.assertEqual(report["totals"]["live"], 0)
        self.assertEqual(report["totals"]["dead"], 0)

    def test_analyze_detects_dead_registration(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text(
            json.dumps(
                [{"session_id": "dead-sess", "alias": "dead-alias", "pid": 999999999}]
            ),
            encoding="utf-8",
        )
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(report["totals"]["dead"], 1)
        self.assertEqual(report["dead_regs"][0]["alias"], "dead-alias")

    def test_analyze_detects_live_registration(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": "live-sess",
                        "alias": "live-alias",
                        "pid": os.getpid(),
                    }
                ]
            ),
            encoding="utf-8",
        )
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(report["totals"]["live"], 1)

    def test_analyze_detects_orphan_inbox(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        (self.broker_root / "orphan.inbox.json").write_text(
            '[{"msg": 1}]', encoding="utf-8"
        )
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(report["totals"]["orphan_inboxes"], 1)
        self.assertEqual(report["orphan_inboxes"][0]["session_id"], "orphan")

    def test_analyze_duplicate_pids_with_activity(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": "active", "alias": "active", "pid": os.getpid()},
                    {"session_id": "ghost", "alias": "ghost", "pid": os.getpid()},
                ]
            ),
            encoding="utf-8",
        )
        archive_dir = self.broker_root / "archive"
        archive_dir.mkdir()
        (archive_dir / "active.jsonl").write_text(
            json.dumps({"from_alias": "active"}) + "\n", encoding="utf-8"
        )
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(len(report["duplicate_pids"]), 1)
        self.assertEqual(report["duplicate_pids"][0]["likely_stale_aliases"], ["ghost"])

    def test_analyze_nonempty_content_at_risk(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text(
            json.dumps(
                [{"session_id": "dead-sess", "alias": "dead", "pid": 999999999}]
            ),
            encoding="utf-8",
        )
        (self.broker_root / "dead-sess.inbox.json").write_text(
            '[{"msg": 1}, {"msg": 2}]', encoding="utf-8"
        )
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        self.assertEqual(report["totals"]["nonempty_content_at_risk"], 1)
        self.assertEqual(len(report["nonempty_content_at_risk"]), 1)

    # --- print_report ---

    def test_print_report_runs_without_error(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        report = c2c_sweep_dryrun.analyze(self.broker_root)
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_sweep_dryrun.print_report(report)
        output = buf.getvalue()
        self.assertIn("broker root:", output)
        self.assertIn("registrations", output)

    # --- main ---

    def test_main_json_output(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            result = c2c_sweep_dryrun.main(["--root", str(self.broker_root), "--json"])
        self.assertEqual(result, 0)
        parsed = json.loads(buf.getvalue())
        self.assertIn("totals", parsed)

    def test_main_text_output(self):
        import c2c_sweep_dryrun

        (self.broker_root / "registry.json").write_text("[]", encoding="utf-8")
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            result = c2c_sweep_dryrun.main(["--root", str(self.broker_root)])
        self.assertEqual(result, 0)
        output = buf.getvalue()
        self.assertIn("broker root:", output)


if __name__ == "__main__":
    unittest.main()
