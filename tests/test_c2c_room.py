import io
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

    def test_join_updates_alias_when_session_rejoins(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "old-alias", "sid-1", broker)
            result = c2c_room.join_room("lobby", "new-alias", "sid-1", broker)
            self.assertFalse(result["already_member"])
            members = c2c_room.load_json_list(
                broker / "rooms" / "lobby" / "members.json"
            )
            self.assertEqual(len(members), 1)
            self.assertEqual(members[0]["alias"], "new-alias")
            self.assertEqual(members[0]["session_id"], "sid-1")

    def test_join_updates_session_id_when_alias_rejoins(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "storm-beacon", "old-sid", broker)
            result = c2c_room.join_room("lobby", "storm-beacon", "new-sid", broker)
            self.assertFalse(result["already_member"])
            members = c2c_room.load_json_list(
                broker / "rooms" / "lobby" / "members.json"
            )
            self.assertEqual(len(members), 1)
            self.assertEqual(members[0]["alias"], "storm-beacon")
            self.assertEqual(members[0]["session_id"], "new-sid")

    def test_join_broadcasts_system_message_to_all_members(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")

            c2c_room.join_room("lobby", "bob", "sid-b", broker)

            inbox_a = json.loads((broker / "sid-a.inbox.json").read_text())
            inbox_b = json.loads((broker / "sid-b.inbox.json").read_text())
            self.assertEqual(len(inbox_a), 1)
            self.assertEqual(len(inbox_b), 1)
            self.assertEqual(inbox_a[0]["from_alias"], "c2c-system")
            self.assertEqual(inbox_b[0]["from_alias"], "c2c-system")
            self.assertEqual(inbox_a[0]["to_alias"], "alice@lobby")
            self.assertEqual(inbox_b[0]["to_alias"], "bob@lobby")
            self.assertEqual(inbox_a[0]["content"], "bob joined room lobby")
            self.assertEqual(inbox_b[0]["content"], "bob joined room lobby")

            history = c2c_room.room_history("lobby", broker_root=broker)
            self.assertEqual(len(history), 2)
            self.assertEqual(history[-1]["from_alias"], "c2c-system")
            self.assertEqual(history[-1]["content"], "bob joined room lobby")

    def test_idempotent_join_does_not_rebroadcast(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")

            c2c_room.join_room("lobby", "alice", "sid-a", broker)

            inbox = json.loads((broker / "sid-a.inbox.json").read_text())
            self.assertEqual(inbox, [])
            history = c2c_room.room_history("lobby", broker_root=broker)
            self.assertEqual(len(history), 1)

    def test_idempotent_join_for_non_tail_member_does_not_rebroadcast(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            c2c_room.join_room("lobby", "bob", "sid-b", broker)
            (broker / "sid-a.inbox.json").write_text("[]")
            (broker / "sid-b.inbox.json").write_text("[]")
            history_before = c2c_room.room_history("lobby", broker_root=broker)

            result = c2c_room.join_room("lobby", "alice", "sid-a", broker)

            self.assertTrue(result["already_member"])
            inbox_a = json.loads((broker / "sid-a.inbox.json").read_text())
            inbox_b = json.loads((broker / "sid-b.inbox.json").read_text())
            self.assertEqual(inbox_a, [])
            self.assertEqual(inbox_b, [])
            history_after = c2c_room.room_history("lobby", broker_root=broker)
            self.assertEqual(len(history_after), len(history_before))

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
            self.assertEqual(history[-1]["from_alias"], "alice")
            self.assertEqual(history[-1]["content"], "hello room")

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


class RoomHistoryFormatTests(unittest.TestCase):
    def test_format_empty_history(self):
        text = c2c_room.format_room_history_text("lobby", [])
        self.assertEqual(text, "No messages in lobby yet.")

    def test_format_normal_message(self):
        entries = [{"ts": 1776134059.0, "from_alias": "alice", "content": "hello"}]
        text = c2c_room.format_room_history_text("lobby", entries)
        self.assertIn("[2026-04-14 12:34:19] alice: hello", text)

    def test_format_system_message(self):
        entries = [{"ts": 1776134059.0, "from_alias": "c2c-system", "content": "bob joined room lobby"}]
        text = c2c_room.format_room_history_text("lobby", entries)
        self.assertIn("-- bob joined room lobby", text)

    def test_format_multiline_content(self):
        entries = [{"ts": 1776134059.0, "from_alias": "alice", "content": "line one\nline two"}]
        text = c2c_room.format_room_history_text("lobby", entries)
        self.assertIn("line one\nline two", text)

    def test_cli_history_text_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")
            c2c_room.send_room("lobby", "alice", "hello text", broker)
            stdout = io.StringIO()
            with mock.patch.dict(
                os.environ, {"C2C_MCP_BROKER_ROOT": str(broker)}
            ), mock.patch("sys.stdout", new=stdout):
                rc = c2c_room.main(["history", "lobby", "--limit", "10"])
            self.assertEqual(rc, 0)
            output = stdout.getvalue()
            self.assertIn("alice: hello text", output)
            self.assertNotIn('"from_alias"', output)

    def test_cli_history_json_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("lobby", "alice", "sid-a", broker)
            (broker / "sid-a.inbox.json").write_text("[]")
            c2c_room.send_room("lobby", "alice", "hello json", broker)
            stdout = io.StringIO()
            with mock.patch.dict(
                os.environ, {"C2C_MCP_BROKER_ROOT": str(broker)}
            ), mock.patch("sys.stdout", new=stdout):
                rc = c2c_room.main(["history", "lobby", "--limit", "10", "--json"])
            self.assertEqual(rc, 0)
            output = stdout.getvalue()
            self.assertIn('"from_alias": "alice"', output)
            self.assertIn('"content": "hello json"', output)


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


class RoomInviteTests(unittest.TestCase):
    def test_invite_adds_to_invite_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            result = c2c_room.send_room_invite("club", "alice", "bob", broker)
            self.assertTrue(result["ok"])
            self.assertEqual(result["invitee_alias"], "bob")
            meta = c2c_room.load_room_meta(broker / "rooms" / "club")
            self.assertEqual(meta["invited_members"], ["bob"])

    def test_invite_only_member_can_invite(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            result = c2c_room.send_room_invite("club", "bob", "carol", broker)
            self.assertFalse(result["ok"])
            self.assertIn("only room members can invite", result["error"])

    def test_join_invite_only_rejects_uninvited(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            c2c_room.set_room_visibility("club", "alice", "invite_only", broker)
            result = c2c_room.join_room("club", "bob", "sid-b", broker)
            self.assertFalse(result["ok"])
            self.assertIn("invite-only", result["error"])

    def test_join_invite_only_accepts_invited(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            c2c_room.set_room_visibility("club", "alice", "invite_only", broker)
            c2c_room.send_room_invite("club", "alice", "bob", broker)
            result = c2c_room.join_room("club", "bob", "sid-b", broker)
            self.assertTrue(result["ok"])
            members = c2c_room.load_json_list(broker / "rooms" / "club" / "members.json")
            self.assertEqual(len(members), 2)

    def test_existing_member_can_rejoin_invite_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            c2c_room.set_room_visibility("club", "alice", "invite_only", broker)
            result = c2c_room.join_room("club", "alice", "sid-a", broker)
            self.assertTrue(result["ok"])
            self.assertTrue(result["already_member"])

    def test_visibility_only_member_can_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            result = c2c_room.set_room_visibility("club", "bob", "invite_only", broker)
            self.assertFalse(result["ok"])
            self.assertIn("only room members can change visibility", result["error"])

    def test_list_rooms_includes_visibility_and_invited(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            c2c_room.send_room_invite("club", "alice", "bob", broker)
            c2c_room.set_room_visibility("club", "alice", "invite_only", broker)
            rooms = c2c_room.list_rooms(broker)
            self.assertEqual(len(rooms), 1)
            self.assertEqual(rooms[0]["visibility"], "invite_only")
            self.assertEqual(rooms[0]["invited_members"], ["bob"])

    def test_init_room_accepts_visibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            result = c2c_room.init_room("club", broker, visibility="invite_only")
            self.assertTrue(result["ok"])
            self.assertEqual(result["visibility"], "invite_only")
            meta = c2c_room.load_room_meta(broker / "rooms" / "club")
            self.assertEqual(meta["visibility"], "invite_only")


class RoomCliTests(unittest.TestCase):
    def test_cli_invite_subcommand(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.init_room("club", broker)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            with mock.patch("c2c_room.default_broker_root", return_value=broker):
                rc = c2c_room.main(["invite", "club", "bob", "--alias", "alice"])
            self.assertEqual(rc, 0)
            meta = c2c_room.load_room_meta(broker / "rooms" / "club")
            self.assertEqual(meta["invited_members"], ["bob"])

    def test_cli_visibility_subcommand(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            c2c_room.init_room("club", broker)
            c2c_room.join_room("club", "alice", "sid-a", broker)
            with mock.patch("c2c_room.default_broker_root", return_value=broker):
                rc = c2c_room.main(["visibility", "club", "invite_only", "--alias", "alice"])
            self.assertEqual(rc, 0)
            meta = c2c_room.load_room_meta(broker / "rooms" / "club")
            self.assertEqual(meta["visibility"], "invite_only")

    def test_cli_init_with_visibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker = Path(tmp)
            with mock.patch("c2c_room.default_broker_root", return_value=broker):
                rc = c2c_room.main(["init", "club", "--visibility", "invite_only"])
            self.assertEqual(rc, 0)
            meta = c2c_room.load_room_meta(broker / "rooms" / "club")
            self.assertEqual(meta["visibility"], "invite_only")


if __name__ == "__main__":
    unittest.main()
