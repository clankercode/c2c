import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_deliver_inbox


class C2CDeliverInboxLoopTests(unittest.TestCase):
    def test_loop_runs_until_max_iterations_and_sleeps_between_empty_polls(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir()

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_target",
                    return_value=(33333, "9", None),
                ),
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    side_effect=[
                        {
                            "ok": True,
                            "messages": [],
                            "delivered": 0,
                            "dry_run": False,
                        },
                        {
                            "ok": True,
                            "messages": [
                                {
                                    "from_alias": "storm-echo",
                                    "to_alias": "codex",
                                    "content": "wake",
                                }
                            ],
                            "delivered": 1,
                            "dry_run": False,
                        },
                    ],
                ) as deliver_once,
                mock.patch("c2c_deliver_inbox.time.sleep") as sleep,
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--broker-root",
                        str(broker_root),
                        "--loop",
                        "--max-iterations",
                        "2",
                        "--interval",
                        "0.25",
                        "--json",
                    ]
                )

            self.assertEqual(result, 0)
            self.assertEqual(deliver_once.call_count, 2)
            sleep.assert_called_once_with(0.25)

    def test_loop_writes_pidfile_before_first_iteration(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            pidfile = Path(temp_dir) / "deliver.pid"

            with (
                mock.patch(
                    "c2c_deliver_inbox.c2c_inject.resolve_target",
                    return_value=(33333, "9", None),
                ),
                mock.patch(
                    "c2c_deliver_inbox.deliver_once",
                    return_value={
                        "ok": True,
                        "messages": [],
                        "delivered": 0,
                        "dry_run": False,
                    },
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = c2c_deliver_inbox.main(
                    [
                        "--client",
                        "codex",
                        "--pid",
                        "12345",
                        "--session-id",
                        "codex-local",
                        "--broker-root",
                        str(broker_root),
                        "--loop",
                        "--max-iterations",
                        "1",
                        "--pidfile",
                        str(pidfile),
                    ]
                )

            self.assertEqual(result, 0)
            self.assertTrue(pidfile.exists())
            self.assertRegex(pidfile.read_text(encoding="utf-8"), r"^\d+\n$")


if __name__ == "__main__":
    unittest.main()
