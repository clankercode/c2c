"""Integration tests for `c2c monitor --json`.

These tests require inotifywait (inotify-tools package) and the built c2c
binary. They are skipped if inotifywait is not found.

Each test:
1. Creates a temporary broker root directory.
2. Starts `c2c monitor --json --all` as a subprocess.
3. Triggers file-system events (registry writes, room member writes).
4. Reads the JSON events from the monitor's stdout.
5. Asserts the expected event_type fields are present.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

C2C_BIN = shutil.which("c2c") or str(REPO / "_build/default/ocaml/cli/c2c.exe")
INOTIFYWAIT = shutil.which("inotifywait")

MONITOR_STARTUP_SECONDS = 3.0   # allow extra time under load (inotifywait setup)
EVENT_TIMEOUT_SECONDS = 8.0


def _read_events(proc, stop_event, events_out, timeout=EVENT_TIMEOUT_SECONDS):
    """Read newline-delimited JSON from proc.stdout into events_out until stop_event or EOF."""
    deadline = time.monotonic() + timeout
    while not stop_event.is_set() and time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            events_out.append(json.loads(line))
        except json.JSONDecodeError:
            pass


def _write_registry(broker_root: Path, registrations: list) -> None:
    payload = json.dumps({"registrations": registrations})
    tmp = broker_root / "registry.json.tmp"
    tmp.write_text(payload, encoding="utf-8")
    tmp.rename(broker_root / "registry.json")


def _write_members(broker_root: Path, room_id: str, members: list) -> None:
    room_dir = broker_root / "rooms" / room_id
    room_dir.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(members)
    tmp = room_dir / "members.json.tmp"
    tmp.write_text(payload, encoding="utf-8")
    tmp.rename(room_dir / "members.json")


@unittest.skipUnless(INOTIFYWAIT, "inotifywait not installed")
@unittest.skipUnless(os.path.exists(C2C_BIN), "c2c binary not found")
class MonitorJsonTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.tmpdir.name) / "mcp"
        self.broker_root.mkdir(parents=True)
        # Seed empty registry so the monitor can start cleanly.
        _write_registry(self.broker_root, [])

    def tearDown(self):
        self.tmpdir.cleanup()

    def _start_monitor(self, extra_args=None):
        args = [
            C2C_BIN, "monitor",
            "--broker-root", str(self.broker_root),
            "--json", "--all",
            "--drains", "--sweeps",
        ]
        if extra_args:
            args += extra_args
        env = os.environ.copy()
        env["C2C_MCP_BROKER_ROOT"] = str(self.broker_root)
        proc = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
        )
        # Allow inotifywait to arm before triggering events.
        time.sleep(MONITOR_STARTUP_SECONDS)
        return proc

    def _collect_events(self, proc, n=1, timeout=EVENT_TIMEOUT_SECONDS):
        """Collect at least n events from proc.stdout within timeout seconds."""
        events = []
        stop = threading.Event()
        t = threading.Thread(target=_read_events, args=(proc, stop, events, timeout))
        t.daemon = True
        t.start()
        t.join(timeout + 1)
        stop.set()
        proc.kill()
        proc.wait(timeout=5)
        return events

    def test_peer_alive_on_registry_write(self):
        proc = self._start_monitor()
        _write_registry(self.broker_root, [
            {"alias": "alice", "session_id": "sid-alice", "pid": 12345}
        ])
        events = self._collect_events(proc, n=1)
        alive = [e for e in events if e.get("event_type") == "peer.alive"]
        self.assertTrue(alive, f"expected peer.alive, got: {events}")
        self.assertEqual(alive[0]["alias"], "alice")
        self.assertIn("monitor_ts", alive[0])

    def test_peer_dead_on_registry_shrink(self):
        # Seed registry with alice, start monitor, then remove her.
        _write_registry(self.broker_root, [
            {"alias": "alice", "session_id": "sid-alice", "pid": 12345}
        ])
        proc = self._start_monitor()
        _write_registry(self.broker_root, [])
        events = self._collect_events(proc, n=1)
        dead = [e for e in events if e.get("event_type") == "peer.dead"]
        self.assertTrue(dead, f"expected peer.dead, got: {events}")
        self.assertEqual(dead[0]["alias"], "alice")

    def test_room_join_on_members_write(self):
        proc = self._start_monitor()
        _write_members(self.broker_root, "lobby", [
            {"alias": "bob", "session_id": "sid-bob", "joined_at": 1.0}
        ])
        events = self._collect_events(proc, n=1)
        joins = [e for e in events if e.get("event_type") == "room.join"]
        self.assertTrue(joins, f"expected room.join, got: {events}")
        self.assertEqual(joins[0]["alias"], "bob")
        self.assertEqual(joins[0]["room_id"], "lobby")
        self.assertIn("monitor_ts", joins[0])

    def test_room_leave_on_members_shrink(self):
        # Seed with carol in lobby, then remove her.
        _write_members(self.broker_root, "lobby", [
            {"alias": "carol", "session_id": "sid-carol", "joined_at": 1.0}
        ])
        proc = self._start_monitor()
        _write_members(self.broker_root, "lobby", [])
        events = self._collect_events(proc, n=1)
        leaves = [e for e in events if e.get("event_type") == "room.leave"]
        self.assertTrue(leaves, f"expected room.leave, got: {events}")
        self.assertEqual(leaves[0]["alias"], "carol")
        self.assertEqual(leaves[0]["room_id"], "lobby")

    def test_multiple_room_joins(self):
        proc = self._start_monitor()
        _write_members(self.broker_root, "swarm-lounge", [
            {"alias": "agent1", "session_id": "sid-1", "joined_at": 1.0},
            {"alias": "agent2", "session_id": "sid-2", "joined_at": 2.0},
        ])
        events = self._collect_events(proc, n=2, timeout=EVENT_TIMEOUT_SECONDS)
        joins = [e for e in events if e.get("event_type") == "room.join"]
        aliases = {j["alias"] for j in joins}
        self.assertIn("agent1", aliases)
        self.assertIn("agent2", aliases)

    def test_room_join_in_new_room_on_disk(self):
        """room.join fires even for a room that didn't exist when monitor started."""
        proc = self._start_monitor()
        _write_members(self.broker_root, "new-room", [
            {"alias": "latejoiner", "session_id": "sid-lj", "joined_at": 1.0}
        ])
        events = self._collect_events(proc, n=1)
        joins = [e for e in events if e.get("event_type") == "room.join"]
        self.assertTrue(joins, f"expected room.join for new-room, got: {events}")
        self.assertEqual(joins[0]["room_id"], "new-room")
        self.assertEqual(joins[0]["alias"], "latejoiner")

    def test_event_type_field_present_on_all_events(self):
        proc = self._start_monitor()
        _write_registry(self.broker_root, [
            {"alias": "dana", "session_id": "sid-dana", "pid": 999}
        ])
        _write_members(self.broker_root, "lobby", [
            {"alias": "dana", "session_id": "sid-dana", "joined_at": 1.0}
        ])
        events = self._collect_events(proc, n=2, timeout=EVENT_TIMEOUT_SECONDS)
        for e in events:
            self.assertIn("event_type", e, f"event missing event_type: {e}")
            self.assertIn("monitor_ts", e, f"event missing monitor_ts: {e}")

    def test_message_event_on_inbox_write(self):
        """Writing a message to an inbox.json must emit a message event in --json mode."""
        proc = self._start_monitor()
        inbox_path = self.broker_root / "sender1.inbox.json"
        msg = {
            "from_alias": "sender1",
            "to_alias": "receiver1",
            "content": "hello from monitor test",
            "deferrable": False,
        }
        tmp = self.broker_root / "sender1.inbox.json.tmp"
        tmp.write_text(json.dumps([msg]), encoding="utf-8")
        tmp.rename(inbox_path)
        events = self._collect_events(proc, n=1)
        msgs = [e for e in events if e.get("event_type") == "message"]
        self.assertTrue(msgs, f"expected message event, got: {events}")
        self.assertEqual(msgs[0]["from_alias"], "sender1")
        self.assertEqual(msgs[0]["content"], "hello from monitor test")
        self.assertIn("monitor_ts", msgs[0])

    def test_drain_event_on_inbox_clear(self):
        """Replacing inbox with [] must emit a drain event for the session alias."""
        inbox_path = self.broker_root / "agent1.inbox.json"
        inbox_path.write_text(json.dumps([
            {"from_alias": "x", "to_alias": "agent1", "content": "hi", "deferrable": False}
        ]))
        proc = self._start_monitor()
        tmp = self.broker_root / "agent1.inbox.json.tmp"
        tmp.write_text("[]", encoding="utf-8")
        tmp.rename(inbox_path)
        events = self._collect_events(proc, n=1)
        drains = [e for e in events if e.get("event_type") == "drain"]
        self.assertTrue(drains, f"expected drain event, got: {events}")
        self.assertEqual(drains[0]["alias"], "agent1")
        self.assertIn("monitor_ts", drains[0])


if __name__ == "__main__":
    unittest.main()
