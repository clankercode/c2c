import json
import os
import tempfile
import unittest
from pathlib import Path
import sys
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_room


class RoomInitTests(unittest.TestCase):
    def test_init_creates_room_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            result = c2c_room.init_room("lobby", broker)
            self.assertTrue(result["ok"])
            rdir = broker / "rooms" / "lobby"
            self.assertTrue(rdir.is_dir())
            self.assertTrue((rdir / "members.json").exists())
            self.assertTrue((rdir / "history.jsonl").exists())
            self.assertEqual(
                json.loads((rdir / "members.json").read_text()), []
            )

    def test_init_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.init_room("lobby", broker)
            c2c_room.init_room("lobby", broker)
            rdir = broker / "rooms" / "lobby"
            self.assertEqual(
                json.loads((rdir / "members.json").read_text()), []
            )


class RoomJoinLeaveTests(unittest.TestCase):
    def test_join_adds_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            result = c2c_room.join_room("lobby", "storm-beacon", "sid-1", broker)
            self.assertTrue(result["ok"])
            self.assertFalse(result["already_member"])
            members = c2c_room.load_json_list(
                broker / "rooms" / "lobby" / "members.json"
            )
            self.assertEqual(len(members), 1)
            self.assertEqual(members[0]["alias"], "storm-beacon")
            self.assertEqual(members[0]["session_id"], "sid-1")

    def test_join_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "storm-beacon", "sid-1", broker)
            result = c2c_room.join_room("lobby", "storm-beacon", "sid-1", broker)
            self.assertTrue(result["already_member"])
            members = c2c_room.load_json_list(
                broker / "rooms" / "lobby" / "members.json"
            )
            self.assertEqual(len(members), 1)

    def test_leave_removes_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "storm-beacon", "sid-1", broker)
            c2c_room.join_room("lobby", "storm-ember", "sid-2", broker)
            result = c2c_room.leave_room("lobby", "storm-beacon", broker)
            self.assertTrue(result["ok"])
            self.assertEqual(result["removed"], 1)
            members = c2c_room.load_json_list(
                broker / "rooms" / "lobby" / "members.json"
            )
            self.assertEqual(len(members), 1)
            self.assertEqual(members[0]["alias"], "storm-ember")

    def test_leave_nonexistent_room(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            result = c2c_room.leave_room("missing", "x", broker)
            self.assertFalse(result["ok"])


class RoomSendTests(unittest.TestCase):
    def test_send_appends_to_history_and_fans_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            # set up broker registry-like structure
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            c2c_room.join_room("lobby", "bob", "sid-b", broker)
            # create inbox files
            for sid in ("sid-a", "sid-b"):
                (broker / f"{sid}.inbox.json").write_text("[]")

            result = c2c_room.send_room("lobby", "alice", "hello room", broker)
            self.assertTrue(result["ok"])
            self.assertIn("bob", result["sent_to"])
            self.assertNotIn("alice", result["sent_to"])

            # check history
            history = c2c_room.room_history("lobby", broker_root=broker)
            self.assertEqual(len(history), 1)
            self.assertEqual(history[0]["from_alias"], "alice")
            self.assertEqual(history[0]["content"], "hello room")

            # check bob's inbox
            inbox = json.loads(
                (broker / "sid-b.inbox.json").read_text()
            )
            self.assertEqual(len(inbox), 1)
            self.assertEqual(inbox[0]["from_alias"], "alice")
            self.assertEqual(inbox[0]["to_alias"], "bob@lobby")

            # alice's inbox should be unchanged
            inbox_a = json.loads(
                (broker / "sid-a.inbox.json").read_text()
            )
            self.assertEqual(len(inbox_a), 0)

    def test_send_to_nonexistent_room(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            result = c2c_room.send_room("missing", "x", "msg", broker)
            self.assertFalse(result["ok"])


class RoomListTests(unittest.TestCase):
    def test_list_shows_rooms_with_member_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            c2c_room.join_room("lobby", "bob", "sid-b", broker)
            c2c_room.join_room("dev", "alice", "sid-a", broker)

            rooms = c2c_room.list_rooms(broker)
            self.assertEqual(len(rooms), 2)
            room_map = {r["room_id"]: r for r in rooms}
            self.assertEqual(room_map["lobby"]["member_count"], 2)
            self.assertEqual(room_map["dev"]["member_count"], 1)

    def test_list_includes_member_liveness_summary(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            c2c_room.join_room("lobby", "bob", "sid-b", broker)
            c2c_room.join_room("lobby", "carol", "sid-c", broker)
            (broker / "registry.json").write_text(
                json.dumps(
                    [
                        {"alias": "alice", "session_id": "sid-a", "pid": os.getpid()},
                        {"alias": "bob", "session_id": "sid-b", "pid": 999999999},
                        {"alias": "carol", "session_id": "sid-c"},
                    ]
                ),
                encoding="utf-8",
            )

            rooms = c2c_room.list_rooms(broker)

            lobby = rooms[0]
            self.assertEqual(lobby["alive_member_count"], 1)
            self.assertEqual(lobby["dead_member_count"], 1)
            self.assertEqual(lobby["unknown_member_count"], 1)
            detail = {m["alias"]: m for m in lobby["member_details"]}
            self.assertIs(detail["alice"]["alive"], True)
            self.assertIs(detail["bob"]["alive"], False)
            self.assertIsNone(detail["carol"]["alive"])

    def test_list_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            self.assertEqual(c2c_room.list_rooms(broker), [])


class RoomHistoryTests(unittest.TestCase):
    def test_history_returns_last_n_records(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")
            for i in range(10):
                c2c_room.send_room("lobby", "alice", f"msg-{i}", broker)

            history = c2c_room.room_history("lobby", limit=3, broker_root=broker)
            self.assertEqual(len(history), 3)
            self.assertEqual(history[0]["content"], "msg-7")
            self.assertEqual(history[2]["content"], "msg-9")

    def test_history_nonexistent_room(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                c2c_room.room_history("missing", broker_root=Path(tmp)), []
            )


class RoomFilePermissionTests(unittest.TestCase):
    def test_members_and_history_are_mode_0600(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")
            c2c_room.send_room("lobby", "alice", "hello", broker)

            rdir = broker / "rooms" / "lobby"
            members_mode = os.stat(rdir / "members.json").st_mode & 0o777
            history_mode = os.stat(rdir / "history.jsonl").st_mode & 0o777
            self.assertEqual(members_mode, 0o600)
            self.assertEqual(history_mode, 0o600)


class RoomIdentityResolutionTests(unittest.TestCase):
    def test_resolve_self_alias_uses_whoami_fallback_without_env_session(self):
        with mock.patch.dict(
            os.environ,
            {"C2C_MCP_SESSION_ID": "", "C2C_SESSION_ID": ""},
            clear=False,
        ), mock.patch(
            "c2c_whoami.resolve_identity",
            return_value=({"session_id": "sid-1"}, {"alias": "storm-ember"}),
        ):
            self.assertEqual(c2c_room.resolve_self_alias(), "storm-ember")

    def test_resolve_self_session_id_uses_whoami_fallback_without_env_session(self):
        with mock.patch.dict(
            os.environ,
            {"C2C_MCP_SESSION_ID": "", "C2C_SESSION_ID": ""},
            clear=False,
        ), mock.patch(
            "c2c_whoami.resolve_identity",
            return_value=({"session_id": "sid-1"}, {"alias": "storm-ember"}),
        ):
            self.assertEqual(c2c_room.resolve_self_session_id(), "sid-1")


if __name__ == "__main__":
    unittest.main()
