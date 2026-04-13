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
        self.assertEqual(
            status["alive_peers"],
            [
                {
                    "alias": "codex",
                    "alive": True,
                    "sent": 20,
                    "received": 20,
                    "goal_met": True,
                }
            ],
        )
        self.assertEqual(
            status["rooms"],
            [
                {
                    "room_id": "swarm-lounge",
                    "member_count": 2,
                    "alive_count": 1,
                }
            ],
        )

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


if __name__ == "__main__":
    unittest.main()
