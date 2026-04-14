import io
import json
import os
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
        self.assertEqual(peer["inbox_pending"], 0)
        rooms = status["rooms"]
        self.assertEqual(len(rooms), 1)
        room = rooms[0]
        self.assertEqual(room["room_id"], "swarm-lounge")
        self.assertEqual(room["member_count"], 2)
        self.assertEqual(room["alive_count"], 1)
        self.assertEqual(room["alive_members"], ["codex"])

    def test_swarm_status_filters_zero_activity_alive_peers_by_default(self):
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
                            "session_id": "ghost-local",
                            "alias": "opencode-ghost",
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

            with mock.patch("c2c_mcp.broker_registration_is_alive", return_value=True):
                status = c2c_status.swarm_status(broker_root)

        self.assertEqual([p["alias"] for p in status["alive_peers"]], ["codex"])
        self.assertEqual(status["filtered_peer_count"], 1)
        self.assertEqual(status["min_messages"], 1)
        self.assertEqual(status["goal_total"], 1)
        self.assertTrue(status["overall_goal_met"])

    def test_swarm_status_min_messages_zero_includes_zero_activity_alive_peers(self):
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
                            "session_id": "ghost-local",
                            "alias": "opencode-ghost",
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

            with mock.patch("c2c_mcp.broker_registration_is_alive", return_value=True):
                status = c2c_status.swarm_status(broker_root, min_messages=0)

        self.assertEqual(
            [p["alias"] for p in status["alive_peers"]],
            ["codex", "opencode-ghost"],
        )
        self.assertEqual(status["filtered_peer_count"], 0)
        self.assertEqual(status["min_messages"], 0)
        self.assertEqual(status["goal_total"], 2)
        self.assertFalse(status["overall_goal_met"])

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

    def test_main_passes_min_messages_to_status(self):
        payload = {
            "ts": "2026-04-13T20:25:00+00:00",
            "alive_peers": [],
            "dead_peer_count": 0,
            "total_peer_count": 0,
            "rooms": [],
            "goal_met_count": 0,
            "goal_total": 0,
            "overall_goal_met": False,
            "filtered_peer_count": 0,
            "min_messages": 0,
        }

        with mock.patch("c2c_status.swarm_status", return_value=payload) as status_mock:
            rc = c2c_status.main(["--json", "--min-messages", "0"])

        self.assertEqual(rc, 0)
        status_mock.assert_called_once_with(None, min_messages=0)

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


    def test_swarm_status_includes_inbox_pending(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "agent-local",
                            "alias": "agent-a",
                            "pid": 111,
                            "pid_start_time": 222,
                        },
                    ]
                ),
                encoding="utf-8",
            )
            (broker_root / "agent-local.inbox.json").write_text(
                json.dumps([{"from_alias": "x", "content": "hi"}] * 7),
                encoding="utf-8",
            )
            write_jsonl(
                broker_root / "archive" / "agent-local.jsonl",
                [{"from_alias": "agent-a", "content": f"msg {i}"} for i in range(20)],
            )

            with mock.patch("c2c_mcp.broker_registration_is_alive", return_value=True):
                status = c2c_status.swarm_status(broker_root)

        self.assertEqual(len(status["alive_peers"]), 1)
        peer = status["alive_peers"][0]
        self.assertEqual(peer["inbox_pending"], 7)


class C2CStatusLegacyTests(unittest.TestCase):
    """Tests for c2c_status swarm_status() and print_status_report()."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name) / "broker"
        self.broker_root.mkdir(parents=True)
        self.registry_path = self.broker_root / "registry.json"
        self.archive_dir = self.broker_root / "archive"
        self.archive_dir.mkdir()
        self.rooms_dir = self.broker_root / "rooms"
        self.rooms_dir.mkdir()

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_registry(self, registrations: list[dict]) -> None:
        self.registry_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_archive(self, filename: str, messages: list[dict]) -> None:
        path = self.archive_dir / filename
        path.write_text(
            "\n".join(json.dumps(m) for m in messages) + "\n",
            encoding="utf-8",
        )

    def _write_room_members(self, room_id: str, members: list[dict]) -> None:
        room_dir = self.rooms_dir / room_id
        room_dir.mkdir(exist_ok=True)
        (room_dir / "members.json").write_text(json.dumps(members), encoding="utf-8")

    def test_empty_broker_returns_zero_counts(self):
        self._write_registry([])
        data = c2c_status.swarm_status(self.broker_root, min_messages=0)
        self.assertEqual(data["alive_peers"], [])
        self.assertEqual(data["dead_peer_count"], 0)
        self.assertEqual(data["total_peer_count"], 0)
        self.assertFalse(data["overall_goal_met"])

    def test_alive_peer_counted_correctly(self):
        self._write_registry(
            [
                {"alias": "storm-beacon", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        data = c2c_status.swarm_status(self.broker_root, min_messages=0)
        self.assertEqual(len(data["alive_peers"]), 1)
        self.assertEqual(data["alive_peers"][0]["alias"], "storm-beacon")
        self.assertEqual(data["dead_peer_count"], 0)

    def test_dead_peer_not_in_alive_list(self):
        self._write_registry(
            [
                {"alias": "ghost-agent", "session_id": "sess-g", "pid": 99999999},
            ]
        )
        data = c2c_status.swarm_status(self.broker_root)
        self.assertEqual(data["alive_peers"], [])
        self.assertEqual(data["dead_peer_count"], 1)

    def test_sent_and_received_counts_populated(self):
        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        received = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 3
        self._write_archive("sess-a.jsonl", received)
        sent = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "yo",
                "drained_at": 2.0,
            }
        ] * 2
        self._write_archive("sess-b.jsonl", sent)
        data = c2c_status.swarm_status(self.broker_root)
        peer = data["alive_peers"][0]
        self.assertEqual(peer["received"], 3)
        self.assertEqual(peer["sent"], 2)

    def test_goal_met_flag_set_when_thresholds_reached(self):
        from c2c_verify import GOAL_COUNT

        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        received = [
            {
                "from_alias": "x",
                "to_alias": "agent-a",
                "content": "m",
                "drained_at": 1.0,
            }
        ] * GOAL_COUNT
        sent = [
            {
                "from_alias": "agent-a",
                "to_alias": "x",
                "content": "m",
                "drained_at": 2.0,
            }
        ] * GOAL_COUNT
        self._write_archive("sess-a.jsonl", received)
        self._write_archive("sess-x.jsonl", sent)
        data = c2c_status.swarm_status(self.broker_root)
        self.assertTrue(data["alive_peers"][0]["goal_met"])
        self.assertTrue(data["overall_goal_met"])

    def test_overall_goal_not_met_when_one_peer_short(self):
        from c2c_verify import GOAL_COUNT

        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
                {"alias": "agent-b", "session_id": "sess-b", "pid": os.getpid()},
            ]
        )
        received_a = [
            {
                "from_alias": "x",
                "to_alias": "agent-a",
                "content": "m",
                "drained_at": 1.0,
            }
        ] * GOAL_COUNT
        sent_a = [
            {
                "from_alias": "agent-a",
                "to_alias": "x",
                "content": "m",
                "drained_at": 2.0,
            }
        ] * GOAL_COUNT
        self._write_archive("sess-a.jsonl", received_a)
        self._write_archive("extra.jsonl", sent_a)
        self._write_archive(
            "sess-b.jsonl",
            [
                {
                    "from_alias": "agent-a",
                    "to_alias": "agent-b",
                    "content": "still short",
                    "drained_at": 3.0,
                }
            ],
        )
        data = c2c_status.swarm_status(self.broker_root)
        self.assertFalse(data["overall_goal_met"])

    def test_rooms_summary_populated(self):
        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        self._write_room_members(
            "swarm-lounge",
            [
                {
                    "alias": "agent-a",
                    "session_id": "sess-a",
                    "joined_at": "2026-01-01T00:00:00Z",
                },
                {
                    "alias": "ghost",
                    "session_id": "sess-g",
                    "joined_at": "2026-01-01T00:00:00Z",
                },
            ],
        )
        data = c2c_status.swarm_status(self.broker_root)
        self.assertEqual(len(data["rooms"]), 1)
        room = data["rooms"][0]
        self.assertEqual(room["room_id"], "swarm-lounge")
        self.assertEqual(room["member_count"], 2)
        self.assertEqual(room["alive_count"], 1)

    def test_rooms_empty_when_no_rooms_dir(self):
        self.rooms_dir.rmdir()
        self._write_registry([])
        data = c2c_status.swarm_status(self.broker_root)
        self.assertEqual(data["rooms"], [])

    def test_print_status_report_no_crash(self):
        """print_status_report should not raise on well-formed data."""
        data = {
            "ts": "2026-01-01T00:00:00+00:00",
            "alive_peers": [
                {
                    "alias": "agent-a",
                    "alive": True,
                    "sent": 5,
                    "received": 3,
                    "goal_met": False,
                }
            ],
            "dead_peer_count": 1,
            "total_peer_count": 2,
            "rooms": [{"room_id": "swarm-lounge", "member_count": 2, "alive_count": 1}],
            "goal_met_count": 0,
            "goal_total": 1,
            "overall_goal_met": False,
        }
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_status.print_status_report(data)
        output = buf.getvalue()
        self.assertIn("agent-a", output)
        self.assertIn("swarm-lounge", output)

    def test_print_status_report_shows_inbox_pending(self):
        data = {
            "ts": "2026-01-01T00:00:00+00:00",
            "alive_peers": [
                {
                    "alias": "agent-a",
                    "alive": True,
                    "sent": 5,
                    "received": 3,
                    "goal_met": False,
                    "inbox_pending": 12,
                }
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 0,
            "goal_total": 1,
            "overall_goal_met": False,
        }
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_status.print_status_report(data)
        output = buf.getvalue()
        self.assertIn("pending=12", output)

    def test_print_status_report_hides_zero_inbox_pending(self):
        data = {
            "ts": "2026-01-01T00:00:00+00:00",
            "alive_peers": [
                {
                    "alias": "agent-a",
                    "alive": True,
                    "sent": 20,
                    "received": 20,
                    "goal_met": True,
                    "inbox_pending": 0,
                }
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 1,
            "goal_total": 1,
            "overall_goal_met": True,
        }
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_status.print_status_report(data)
        output = buf.getvalue()
        self.assertNotIn("pending", output)

    def test_print_status_report_goal_met_shown(self):
        data = {
            "ts": "2026-01-01T00:00:00+00:00",
            "alive_peers": [
                {
                    "alias": "agent-a",
                    "alive": True,
                    "sent": 20,
                    "received": 20,
                    "goal_met": True,
                }
            ],
            "dead_peer_count": 0,
            "total_peer_count": 1,
            "rooms": [],
            "goal_met_count": 1,
            "goal_total": 1,
            "overall_goal_met": True,
        }
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_status.print_status_report(data)
        output = buf.getvalue()
        self.assertIn("[goal_met]", output)
        self.assertIn("ALL", output)

    def test_last_active_ts_from_recv(self):
        import time as _time

        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        now_ts = _time.time()
        msgs = [
            {
                "from_alias": "x",
                "to_alias": "agent-a",
                "drained_at": now_ts - 30,
                "content": "hi",
            }
        ]
        self._write_archive("sess-a.jsonl", msgs)
        data = c2c_status.swarm_status(self.broker_root)
        peer = data["alive_peers"][0]
        self.assertAlmostEqual(peer["last_active_ts"], now_ts - 30, delta=1.0)

    def test_last_active_ts_from_sent_when_newer(self):
        """last_active_ts should use max(recv_ts, sent_ts) — sent may be more recent."""
        import time as _time

        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        now_ts = _time.time()
        # agent-a received a message 300s ago
        recv_msgs = [
            {
                "from_alias": "x",
                "to_alias": "agent-a",
                "drained_at": now_ts - 300,
                "content": "hi",
            }
        ]
        self._write_archive("sess-a.jsonl", recv_msgs)
        # agent-a sent a message 10s ago (appears in agent-b's archive)
        sent_msgs = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "drained_at": now_ts - 10,
                "content": "yo",
            }
        ]
        self._write_archive("sess-b.jsonl", sent_msgs)
        data = c2c_status.swarm_status(self.broker_root)
        peer = data["alive_peers"][0]
        self.assertAlmostEqual(peer["last_active_ts"], now_ts - 10, delta=1.0)

    def test_last_active_ts_none_when_no_archive(self):
        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        data = c2c_status.swarm_status(self.broker_root, min_messages=0)
        self.assertIsNone(data["alive_peers"][0]["last_active_ts"])

    def test_fmt_age_seconds(self):
        now = 1000.0
        self.assertEqual(c2c_status._fmt_age(955.0, now), "45s ago")

    def test_fmt_age_minutes(self):
        now = 1000.0
        self.assertEqual(c2c_status._fmt_age(400.0, now), "10m ago")

    def test_fmt_age_hours(self):
        now = 10000.0
        self.assertEqual(c2c_status._fmt_age(3400.0, now), "1h ago")

    def test_fmt_age_none_returns_never(self):
        self.assertEqual(c2c_status._fmt_age(None, 1000.0), "never")

    def test_status_output_shows_last_age(self):
        import time as _time

        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a", "pid": os.getpid()},
            ]
        )
        now_ts = _time.time()
        msgs = [
            {
                "from_alias": "x",
                "to_alias": "agent-a",
                "drained_at": now_ts - 90,
                "content": "hi",
            }
        ]
        self._write_archive("sess-a.jsonl", msgs)
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_status.main(["--broker-root", str(self.broker_root)])
        self.assertIn("last=", buf.getvalue())

    def test_cli_json_output(self):
        self._write_registry([])
        rc = c2c_status.main(["--json", "--broker-root", str(self.broker_root)])
        self.assertEqual(rc, 0)

    def test_cli_text_output(self):
        self._write_registry([])
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = c2c_status.main(["--broker-root", str(self.broker_root)])
        self.assertEqual(rc, 0)
        self.assertIn("Swarm Status", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
