import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_status


def write_jsonl(path: Path, entries: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(json.dumps(entry) + "\n" for entry in entries),
        encoding="utf-8",
    )


class C2CStatusTests(unittest.TestCase):
    def test_swarm_status_summarizes_alive_peers_and_rooms(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "codex-local",
                            "alias": "codex",
                            "pid": 111,
                            "pid_start_time": 222,
                        },
                        {
                            "session_id": "dead-local",
                            "alias": "dead-peer",
                            "pid": 333,
                            "pid_start_time": 444,
                        },
                    ]
                ),
                encoding="utf-8",
            )
            write_jsonl(
                broker_root / "archive" / "codex-local.jsonl",
                [{"from_alias": "codex", "content": f"msg {i}"} for i in range(20)],
            )
            write_jsonl(
                broker_root / "archive" / "dead-local.jsonl",
                [{"from_alias": "dead-peer", "content": "old"}],
            )
            room_dir = broker_root / "rooms" / "swarm-lounge"
            room_dir.mkdir(parents=True)
            (room_dir / "members.json").write_text(
                json.dumps(
                    [
                        {"session_id": "codex-local", "alias": "codex"},
                        {"session_id": "dead-local", "alias": "dead-peer"},
                    ]
                ),
                encoding="utf-8",
            )

            with mock.patch(
                "c2c_mcp.broker_registration_is_alive",
                side_effect=lambda reg: reg.get("alias") == "codex",
            ):
                status = c2c_status.swarm_status(broker_root)

        self.assertEqual(status["dead_peer_count"], 1)
        self.assertEqual(status["goal_met_count"], 1)
        self.assertTrue(status["overall_goal_met"])
        self.assertEqual(len(status["alive_peers"]), 1)
        peer = status["alive_peers"][0]
        self.assertEqual(peer["alias"], "codex")
        self.assertTrue(peer["alive"])
        self.assertEqual(peer["sent"], 20)
        self.assertEqual(peer["received"], 20)
        self.assertTrue(peer["goal_met"])
        self.assertIn("last_active_ts", peer)
        rooms = status["rooms"]
        self.assertEqual(len(rooms), 1)
        room = rooms[0]
        self.assertEqual(room["room_id"], "swarm-lounge")
        self.assertEqual(room["member_count"], 2)
        self.assertEqual(room["alive_count"], 1)
        self.assertEqual(room["alive_members"], ["codex"])

    def test_main_json_prints_status_payload(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [],
            "dead_peer_count": 0,
            "total_peer_count": 0,
            "rooms": [],
            "goal_met_count": 0,
            "goal_total": 0,
            "overall_goal_met": False,
        }
        stdout = io.StringIO()

        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            rc = c2c_status.main(["--json"])

        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(stdout.getvalue()), payload)

    def test_main_text_output_is_ascii_and_shows_goal_thresholds(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [
                {
                    "alias": "codex",
                    "alive": True,
                    "sent": 3,
                    "received": 4,
                    "goal_met": False,
                }
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 0,
            "goal_total": 1,
            "overall_goal_met": False,
        }
        stdout = io.StringIO()

        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            rc = c2c_status.main([])

        output = stdout.getvalue()
        self.assertEqual(rc, 0)
        output.encode("ascii")
        self.assertIn("sent>=20 AND recv>=20", output)
        # Blocker detail should appear for peers not at goal_met
        self.assertIn("Blocked by codex", output)
        self.assertIn("need", output)

    def test_goal_met_no_blocked_by_line(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [
                {"alias": "codex", "alive": True, "sent": 20, "received": 20, "goal_met": True}
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 1,
            "goal_total": 1,
            "overall_goal_met": True,
        }
        stdout = io.StringIO()
        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            c2c_status.main([])
        output = stdout.getvalue()
        self.assertIn("ALL 1 alive peers at goal_met  OK", output)
        self.assertNotIn("Blocked by", output)

    def test_blocked_by_shows_sends_and_recvs_needed(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [
                {"alias": "agent-x", "alive": True, "sent": 5, "received": 3, "goal_met": False}
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 0,
            "goal_total": 1,
            "overall_goal_met": False,
        }
        stdout = io.StringIO()
        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            c2c_status.main([])
        output = stdout.getvalue()
        self.assertIn("Blocked by agent-x", output)
        self.assertIn("need 15 more sends", output)
        self.assertIn("need 17 more recvs", output)

    def test_rooms_with_zero_members_hidden_from_text_output(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [],
            "dead_peer_count": 0,
            "total_peer_count": 0,
            "rooms": [
                {"room_id": "empty-room", "member_count": 0, "alive_count": 0, "alive_members": []},
                {"room_id": "active-room", "member_count": 2, "alive_count": 1, "alive_members": ["codex"]},
            ],
            "goal_met_count": 0,
            "goal_total": 0,
            "overall_goal_met": False,
        }
        stdout = io.StringIO()

        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            c2c_status.main([])

        output = stdout.getvalue()
        self.assertNotIn("empty-room", output)
        self.assertIn("active-room", output)

    def test_rooms_show_alive_member_names(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [],
            "dead_peer_count": 0,
            "total_peer_count": 0,
            "rooms": [
                {
                    "room_id": "swarm-lounge",
                    "member_count": 3,
                    "alive_count": 2,
                    "alive_members": ["codex", "kimi-nova"],
                },
            ],
            "goal_met_count": 0,
            "goal_total": 0,
            "overall_goal_met": False,
        }
        stdout = io.StringIO()

        with (
            mock.patch("c2c_status.swarm_status", return_value=payload),
            mock.patch("sys.stdout", stdout),
        ):
            c2c_status.main([])

        output = stdout.getvalue()
        self.assertIn("codex", output)
        self.assertIn("kimi-nova", output)
        self.assertIn("swarm-lounge", output)

    def test_load_room_summary_includes_alive_members(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            room_dir = broker_root / "rooms" / "swarm-lounge"
            room_dir.mkdir(parents=True)
            (room_dir / "members.json").write_text(
                json.dumps(
                    [
                        {"session_id": "s1", "alias": "alice"},
                        {"session_id": "s2", "alias": "bob"},
                        {"session_id": "s3", "alias": "charlie"},
                    ]
                ),
                encoding="utf-8",
            )
            registry = [
                {"alias": "alice", "pid": 1, "pid_start_time": 0},
                {"alias": "bob", "pid": 2, "pid_start_time": 0},
                {"alias": "charlie", "pid": 3, "pid_start_time": 0},
            ]
            with mock.patch(
                "c2c_mcp.broker_registration_is_alive",
                side_effect=lambda reg: reg["alias"] in ("alice", "bob"),
            ):
                summaries = c2c_status._load_room_summary(broker_root, registry)

        self.assertEqual(len(summaries), 1)
        room = summaries[0]
        self.assertEqual(room["alive_count"], 2)
        self.assertEqual(room["alive_members"], ["alice", "bob"])

    def test_load_room_summary_empty_room_has_empty_alive_members(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            room_dir = broker_root / "rooms" / "test-room"
            room_dir.mkdir(parents=True)
            (room_dir / "members.json").write_text(json.dumps([]), encoding="utf-8")
            with mock.patch("c2c_mcp.broker_registration_is_alive", return_value=False):
                summaries = c2c_status._load_room_summary(broker_root, [])

        self.assertEqual(len(summaries), 1)
        room = summaries[0]
        self.assertEqual(room["member_count"], 0)
        self.assertEqual(room["alive_count"], 0)
        self.assertEqual(room["alive_members"], [])


if __name__ == "__main__":
    unittest.main()
