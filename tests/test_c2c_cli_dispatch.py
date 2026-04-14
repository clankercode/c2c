import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_cli
import c2c_sweep_dryrun


CLI_TIMEOUT_SECONDS = 5


def run_cli(command, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        [str(REPO / command), *args],
        cwd=REPO,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def result_code(result):
    return result.returncode


class C2CCLIDispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.words_path = Path(self.temp_dir.name) / "words.txt"
        self.words_path.write_text(
            "storm\nherald\nember\ncrown\nsilver\nbanner\n",
            encoding="utf-8",
        )
        self.env = {
            "C2C_REGISTRY_PATH": str(self.registry_path),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }

    def tearDown(self):
        self.temp_dir.cleanup()

    def invoke_cli(self, command, *args, env=None):
        try:
            return run_cli(command, *args, env=env or self.env)
        except FileNotFoundError as error:
            self.fail(f"missing command: {command}\n{error}")

    def test_c2c_list_subcommand_matches_wrapper_json_output(self):
        wrapper = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)
        canonical = self.invoke_cli("c2c", "list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(wrapper), 0)
        self.assertEqual(result_code(canonical), 0)
        self.assertEqual(json.loads(canonical.stdout), json.loads(wrapper.stdout))

    def test_c2c_send_subcommand_matches_wrapper_dry_run_output(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-two", "--json", env=self.env
        )
        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]

        wrapper = self.invoke_cli(
            "c2c-send", alias, "hello", "peer", "--dry-run", "--json", env=self.env
        )
        canonical = self.invoke_cli(
            "c2c", "send", alias, "hello", "peer", "--dry-run", "--json", env=self.env
        )

        self.assertEqual(result_code(wrapper), 0)
        self.assertEqual(result_code(canonical), 0)
        self.assertEqual(json.loads(canonical.stdout), json.loads(wrapper.stdout))

    def test_c2c_mcp_subcommand_dispatches_to_mcp_wrapper(self):
        with mock.patch("c2c_cli.c2c_mcp.main", return_value=0) as mcp_main:
            result = c2c_cli.main(["mcp", "--help"])

        self.assertEqual(result, 0)
        mcp_main.assert_called_once_with(["--help"])

    def test_c2c_top_level_help_prints_usage(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch("sys.stdout", new=stdout), mock.patch("sys.stderr", new=stderr):
            result = c2c_cli.main(["--help"])

        self.assertEqual(result, 0)
        self.assertIn("usage: c2c <", stdout.getvalue())
        self.assertIn("setup", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")

    def test_c2c_inject_subcommand_dispatches_to_cross_client_injector(self):
        with mock.patch("c2c_cli.c2c_inject.main", return_value=0) as inject_main:
            result = c2c_cli.main(["inject", "--pid", "123", "hello"])

        self.assertEqual(result, 0)
        inject_main.assert_called_once_with(["--pid", "123", "hello"])

    def test_c2c_deliver_inbox_subcommand_dispatches_to_delivery_tool(self):
        with mock.patch(
            "c2c_cli.c2c_deliver_inbox.main", return_value=0
        ) as deliver_main:
            result = c2c_cli.main(
                ["deliver-inbox", "--pid", "123", "--session-id", "s"]
            )

        self.assertEqual(result, 0)
        deliver_main.assert_called_once_with(["--pid", "123", "--session-id", "s"])

    def test_c2c_sweep_dryrun_subcommand_dispatches_to_safe_preview(self):
        with mock.patch("c2c_cli.c2c_sweep_dryrun.main", return_value=0) as dryrun_main:
            result = c2c_cli.main(["sweep-dryrun", "--json"])

        self.assertEqual(result, 0)
        dryrun_main.assert_called_once_with(["--json"])

    def test_sweep_dryrun_main_accepts_argv_from_dispatcher(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        broker_root.mkdir()
        (broker_root / "registry.json").write_text("[]", encoding="utf-8")

        stdout = io.StringIO()
        with mock.patch("sys.stdout", stdout):
            result = c2c_sweep_dryrun.main(["--root", str(broker_root), "--json"])

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["root"], str(broker_root))

    def test_sweep_dryrun_reports_likely_stale_duplicate_pid_aliases(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        broker_root.mkdir()
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": "codex-local", "alias": "codex", "pid": os.getpid()},
                    {
                        "session_id": "opencode-c2c-msg",
                        "alias": "opencode-c2c-msg",
                        "pid": os.getpid(),
                    },
                ]
            ),
            encoding="utf-8",
        )
        archive_dir = broker_root / "archive"
        archive_dir.mkdir()
        (archive_dir / "codex-local.jsonl").write_text(
            json.dumps({"from_alias": "codex", "to_alias": "peer"}) + "\n",
            encoding="utf-8",
        )

        report = c2c_sweep_dryrun.analyze(broker_root)

        self.assertEqual(
            report["duplicate_pids"][0]["likely_stale_aliases"],
            ["opencode-c2c-msg"],
        )

    def test_sweep_dryrun_text_reports_likely_stale_duplicate_pid_aliases(self):
        report = {
            "root": "/tmp/broker",
            "totals": {
                "registrations": 2,
                "inbox_files": 0,
                "live": 2,
                "legacy_pidless": 0,
                "dead": 0,
                "orphan_inboxes": 0,
                "dropped_if_swept": 0,
                "nonempty_content_at_risk": 0,
            },
            "duplicate_pids": [
                {
                    "pid": 12345,
                    "aliases": ["codex", "opencode-c2c-msg"],
                    "likely_stale_aliases": ["opencode-c2c-msg"],
                }
            ],
            "duplicate_aliases": {},
            "dead_regs": [],
            "nonempty_content_at_risk": [],
        }

        stdout = io.StringIO()
        with mock.patch("sys.stdout", stdout):
            c2c_sweep_dryrun.print_report(report)

        self.assertIn("duplicate PIDs", stdout.getvalue())
        self.assertIn("likely stale: opencode-c2c-msg", stdout.getvalue())

    def test_c2c_poll_inbox_subcommand_dispatches_to_recovery_poller(self):
        with mock.patch("c2c_cli.c2c_poll_inbox.main", return_value=0) as poll_main:
            result = c2c_cli.main(["poll-inbox", "--json"])

        self.assertEqual(result, 0)
        poll_main.assert_called_once_with(["--json"])

    def test_c2c_send_all_subcommand_dispatches_to_broadcast_client(self):
        with mock.patch("c2c_cli.c2c_send_all.main", return_value=0) as send_all_main:
            result = c2c_cli.main(
                ["send-all", "--from-alias", "me", "hello swarm", "--json"]
            )

        self.assertEqual(result, 0)
        send_all_main.assert_called_once_with(
            ["--from-alias", "me", "hello swarm", "--json"]
        )

    def test_c2c_init_subcommand_dispatches_to_bootstrap(self):
        with mock.patch("c2c_cli.c2c_init.main", return_value=0) as init_main:
            result = c2c_cli.main(["init", "--json"])

        self.assertEqual(result, 0)
        init_main.assert_called_once_with(["--json"])

    def test_c2c_init_creates_broker_root_and_reports_peers(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "fresh-broker"
            self.assertFalse(broker_root.exists())
            env = os.environ.copy()
            env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
            result = subprocess.run(
                [sys.executable, str(REPO / "c2c_init.py"), "--json"],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["broker_root"], str(broker_root))
            self.assertEqual(payload["peer_count"], 0)
            self.assertEqual(payload["aliases"], [])
            self.assertTrue(broker_root.exists())

            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {"session_id": "alice-local", "alias": "alice"},
                        {"session_id": "bob-local", "alias": "bob"},
                    ]
                ),
                encoding="utf-8",
            )
            second = subprocess.run(
                [sys.executable, str(REPO / "c2c_init.py"), "--json"],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
            self.assertEqual(second.returncode, 0, msg=second.stderr)
            second_payload = json.loads(second.stdout)
            self.assertEqual(second_payload["peer_count"], 2)
            self.assertEqual(sorted(second_payload["aliases"]), ["alice", "bob"])

    def test_is_safe_auto_approve_command_accepts_allowlisted_c2c_subcommands(self):
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c send storm-ember hi"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c list --all --json"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c whoami --json"))
        self.assertTrue(c2c_cli.is_safe_auto_approve_command("c2c verify --json"))

    def test_is_safe_auto_approve_command_rejects_non_allowlisted_or_fake_prefixes(
        self,
    ):
        self.assertFalse(c2c_cli.is_safe_auto_approve_command("c2c register agent-one"))
        self.assertFalse(
            c2c_cli.is_safe_auto_approve_command(
                "c2c-but-i-just-named-it-that send storm-ember hi"
            )
        )
        self.assertFalse(
            c2c_cli.is_safe_auto_approve_command("python c2c send storm-ember hi")
        )

    def test_auto_approve_is_disabled_by_default(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            self.assertFalse(c2c_cli.auto_approve_enabled())


if __name__ == "__main__":
    unittest.main()
