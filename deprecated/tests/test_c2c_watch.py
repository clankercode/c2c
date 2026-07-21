import io
import json
import unittest
from unittest import mock

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_cli
import c2c_install
import c2c_watch


class FakeStdout:
    def __init__(self, lines):
        self._lines = iter(lines)

    def __iter__(self):
        return self

    def __next__(self):
        return next(self._lines)


class C2CWatchTests(unittest.TestCase):
    def test_watch_forwards_each_stdout_line_with_label(self):
        proc = mock.Mock()
        proc.stdout = FakeStdout(["first\n", "second\n"])
        proc.wait.return_value = 0

        with (
            mock.patch("c2c_watch.subprocess.Popen", return_value=proc),
            mock.patch("c2c_watch.c2c_send.send_to_alias") as send_to_alias,
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            result = c2c_watch.main(
                ["--to", "codex", "--label", "build", "--", "make", "test"]
            )

        self.assertEqual(result, 0)
        self.assertEqual(
            [call.args for call in send_to_alias.call_args_list],
            [
                ("codex", "[build] first", False),
                ("codex", "[build] second", False),
            ],
        )

    def test_watch_returns_command_exit_code(self):
        proc = mock.Mock()
        proc.stdout = FakeStdout(["bad\n"])
        proc.wait.return_value = 7

        with (
            mock.patch("c2c_watch.subprocess.Popen", return_value=proc),
            mock.patch("c2c_watch.c2c_send.send_to_alias"),
            mock.patch("sys.stdout", new_callable=io.StringIO),
        ):
            result = c2c_watch.main(["--to", "codex", "--", "false"])

        self.assertEqual(result, 7)

    def test_watch_json_reports_forwarded_count(self):
        proc = mock.Mock()
        proc.stdout = FakeStdout(["line\n"])
        proc.wait.return_value = 0

        with (
            mock.patch("c2c_watch.subprocess.Popen", return_value=proc),
            mock.patch("c2c_watch.c2c_send.send_to_alias"),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            result = c2c_watch.main(["--to", "codex", "--json", "--", "echo", "line"])

        self.assertEqual(result, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["forwarded"], 1)
        self.assertEqual(payload["returncode"], 0)

    def test_cli_dispatches_watch(self):
        with mock.patch("c2c_cli.c2c_watch.main", return_value=0) as main:
            result = c2c_cli.main(["watch", "--to", "codex", "--", "echo", "hi"])

        self.assertEqual(result, 0)
        main.assert_called_once_with(["--to", "codex", "--", "echo", "hi"])

    def test_install_includes_watch_wrapper(self):
        self.assertIn("c2c-watch", c2c_install.COMMANDS)


if __name__ == "__main__":
    unittest.main()
