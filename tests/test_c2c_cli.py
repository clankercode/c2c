import io
import json
import os
import runpy
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from threading import BrokenBarrierError
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_register
import c2c_registry
import c2c_deliver_inbox
import c2c_inject
import c2c_mcp
import c2c_poll_inbox
import c2c_poker
import c2c_prune
import c2c_send
import c2c_dead_letter
import c2c_cli
import c2c_verify
import c2c_whoami
import c2c_status
import claude_list_sessions
import claude_send_msg
from c2c_list import list_registered_sessions, list_sessions
from c2c_register import register_session
from c2c_registry import load_registry, save_registry


CLI_TIMEOUT_SECONDS = 5
AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


def run_cli(command, *args, env=None):
    return run_cli_in_root(REPO, command, *args, env=env)


def run_cli_in_root(root, command, *args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)

    return subprocess.run(
        [str(Path(root) / command), *args],
        cwd=root,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def copy_cli_checkout(source_root: Path, target_root: Path) -> None:
    target_root.mkdir(parents=True, exist_ok=True)
    source_git_path = source_root / ".git"
    target_git_path = target_root / ".git"
    if source_git_path.is_dir():
        # Exclude large subdirs that tests don't need:
        #   c2c/    — live broker data (tests use C2C_REGISTRY_PATH instead)
        #   objects/ — git object pack (only HEAD/config/refs needed for rev-parse)
        #   logs/    — reflog not needed
        # Copying the full .git (30+ MB objects + broker archives) exhausts /tmp
        # per-user disk quota on CI machines.
        shutil.copytree(
            source_git_path,
            target_git_path,
            ignore=shutil.ignore_patterns("c2c", "objects", "logs", "rr-cache"),
        )
    else:
        shutil.copy2(source_git_path, target_git_path)
    for relative_path in [
        "c2c",
        "c2c-broker-gc",
        "c2c-claude-wake",
        "c2c-configure-claude-code",
        "c2c-configure-codex",
        "c2c-configure-crush",
        "c2c-configure-kimi",
        "c2c-configure-opencode",
        "c2c-crush-wake",
        "c2c-deliver-inbox",
        "c2c-health",
        "c2c-init",
        "c2c-kimi-wake",
        "c2c-kimi-wire-bridge",
        "c2c-opencode-wake",
        "c2c-prune",
        "c2c-register",
        "c2c-restart-me",
        "c2c-room",
        "c2c-list",
        "c2c-send",
        "c2c-send-all",
        "c2c-setup",
        "c2c-install",
        "c2c-inject",
        "c2c-poker-sweep",
        "c2c-verify",
        "c2c-watch",
        "c2c-whoami",
        "restart-codex-self",
        "restart-crush-self",
        "restart-kimi-self",
        "restart-opencode-self",
        "run-crush-inst",
        "run-crush-inst-outer",
        "run-crush-inst-rearm",
        "run-kimi-inst",
        "run-kimi-inst-outer",
        "run-kimi-inst-rearm",
        "c2c_kimi_prefill.py",
        "c2c_broker_gc.py",
        "c2c_dead_letter.py",
        "c2c_register.py",
        "c2c_restart_me.py",
        "c2c_room.py",
        "c2c_configure_claude_code.py",
        "c2c_configure_codex.py",
        "c2c_configure_crush.py",
        "c2c_configure_kimi.py",
        "c2c_configure_opencode.py",
        "c2c_init.py",
        "c2c_list.py",
        "c2c_prune.py",
        "c2c_send.py",
        "c2c_send_all.py",
        "c2c_smoke_test.py",
        "c2c_setup.py",
        "c2c_install.py",
        "c2c_deliver_inbox.py",
        "c2c_inject.py",
        "c2c_poker.py",
        "c2c_poker_sweep.py",
        "c2c_poll_inbox.py",
        "c2c_pts_inject.py",
        "c2c_verify.py",
        "c2c_watch.py",
        "c2c_whoami.py",
        "c2c_health.py",
        "c2c_claude_wake_daemon.py",
        "c2c_kimi_wake_daemon.py",
        "c2c_kimi_wire_bridge.py",
        "c2c_opencode_wake_daemon.py",
        "c2c_crush_wake_daemon.py",
        "c2c_cli.py",
        "c2c_history.py",
        "c2c_status.py",
        "c2c_smoke_test.py",
        "c2c_sweep_dryrun.py",
        "c2c_mcp.py",
        "c2c_registry.py",
        "claude_send_msg.py",
        "claude_list_sessions.py",
    ]:
        shutil.copy2(source_root / relative_path, target_root / relative_path)


class C2CCLITests(unittest.TestCase):
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

    def test_register_returns_alias_and_json(self):
        result = self.invoke_cli(
            "c2c-register",
            "6e45bbe8-998c-4140-b77e-c6f117e6ca4b",
            "--json",
        )
        self.assertEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], "6e45bbe8-998c-4140-b77e-c6f117e6ca4b")
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")

    def test_register_is_idempotent_for_same_live_session(self):
        first = self.invoke_cli("c2c-register", "agent-one", "--json")
        second = self.invoke_cli("c2c-register", "agent-one", "--json")
        self.assertEqual(result_code(first), 0)
        self.assertEqual(result_code(second), 0)
        self.assertEqual(
            json.loads(first.stdout)["alias"], json.loads(second.stdout)["alias"]
        )

    def test_register_persists_yaml_registry_record(self):
        result = self.invoke_cli("c2c-register", AGENT_ONE_SESSION_ID, "--json")
        self.assertEqual(result_code(result), 0)
        self.assertTrue(self.registry_path.exists())
        registry_text = self.registry_path.read_text(encoding="utf-8")
        self.assertIn("registrations:", registry_text)
        self.assertIn(f"session_id: {AGENT_ONE_SESSION_ID}", registry_text)
        self.assertRegex(registry_text, r"alias: [a-z]+-[a-z]+")

    def test_list_only_shows_opted_in_sessions(self):
        registered = self.invoke_cli("c2c-register", "agent-one", env=self.env)
        self.assertEqual(result_code(registered), 0)
        listed = self.invoke_cli("c2c-list", "--json", env=self.env)
        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual([item["name"] for item in payload["sessions"]], ["agent-one"])

    def test_list_all_shows_live_sessions_even_when_unregistered(self):
        listed = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            payload["sessions"],
            [
                {
                    "alias": "",
                    "name": "agent-one",
                    "session_id": AGENT_ONE_SESSION_ID,
                },
                {
                    "alias": "",
                    "name": "agent-two",
                    "session_id": AGENT_TWO_SESSION_ID,
                },
            ],
        )

    def test_list_all_includes_alias_when_live_session_is_registered(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-one", "--json", env=self.env
        )

        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]

        listed = self.invoke_cli("c2c-list", "--all", "--json", env=self.env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            payload["sessions"],
            [
                {
                    "alias": alias,
                    "name": "agent-one",
                    "session_id": AGENT_ONE_SESSION_ID,
                },
                {
                    "alias": "",
                    "name": "agent-two",
                    "session_id": AGENT_TWO_SESSION_ID,
                },
            ],
        )

    def test_list_all_human_output_shows_live_sessions(self):
        listed = self.invoke_cli("c2c-list", "--all", env=self.env)

        self.assertEqual(result_code(listed), 0)
        self.assertEqual(
            listed.stdout.splitlines(),
            [
                f"\tagent-one\t{AGENT_ONE_SESSION_ID}",
                f"\tagent-two\t{AGENT_TWO_SESSION_ID}",
            ],
        )

    def test_list_prunes_dead_registrations(self):
        registered = self.invoke_cli("c2c-register", "agent-one", env=self.env)
        self.assertEqual(result_code(registered), 0)
        dead_env = dict(self.env)
        dead_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-live-and-dead.json"
        )
        listed = self.invoke_cli("c2c-list", "--json", env=dead_env)
        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(payload["sessions"], [])

    def test_list_returns_recently_registered_sessions_in_same_environment(self):
        register_checkout = Path(self.temp_dir.name) / "checkout-register"
        list_checkout = Path(self.temp_dir.name) / "checkout-list"
        copy_cli_checkout(REPO, register_checkout)
        copy_cli_checkout(REPO, list_checkout)

        # Use a shared temp registry so both checkouts see the same registrations.
        shared_registry = Path(self.temp_dir.name) / "shared-registry.yaml"
        shared_broker_root = Path(self.temp_dir.name) / "shared-broker"

        env = {
            "C2C_REGISTRY_PATH": str(shared_registry),
            "C2C_MCP_BROKER_ROOT": str(shared_broker_root),
            "C2C_ALIAS_WORDS_PATH": str(self.words_path),
            "C2C_SEND_MESSAGE_FIXTURE": "1",
            "C2C_SESSIONS_FIXTURE": str(REPO / "tests/fixtures/sessions-live.json"),
            "C2C_MCP_AUTO_REGISTER_ALIAS": "",
            "C2C_MCP_AUTO_JOIN_ROOMS": "",
        }

        first = run_cli_in_root(
            register_checkout, "c2c-register", "agent-one", "--json", env=env
        )
        second = run_cli_in_root(
            register_checkout, "c2c-register", "agent-two", "--json", env=env
        )

        self.assertEqual(result_code(first), 0)
        self.assertEqual(result_code(second), 0)

        listed = run_cli_in_root(list_checkout, "c2c-list", "--json", env=env)

        self.assertEqual(result_code(listed), 0)
        payload = json.loads(listed.stdout)
        self.assertEqual(
            sorted(item["session_id"] for item in payload["sessions"]),
            [AGENT_ONE_SESSION_ID, AGENT_TWO_SESSION_ID],
        )

    def test_install_writes_user_local_wrappers(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)

        result = self.invoke_cli("c2c-install", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(
            sorted(payload["installed_commands"]),
            [
                "c2c",
                "c2c-broker-gc",
                "c2c-claude-wake",
                "c2c-configure-claude-code",
                "c2c-configure-codex",
                "c2c-configure-crush",
                "c2c-configure-kimi",
                "c2c-configure-opencode",
                "c2c-crush-wake",
                "c2c-deliver-inbox",
                "c2c-health",
                "c2c-init",
                "c2c-inject",
                "c2c-install",
                "c2c-instances",
                "c2c-kimi-wake",
                "c2c-kimi-wire-bridge",
                "c2c-list",
                "c2c-opencode-wake",
                "c2c-poker-sweep",
                "c2c-poll-inbox",
                "c2c-prune",
                "c2c-register",
                "c2c-restart",
                "c2c-restart-me",
                "c2c-room",
                "c2c-send",
                "c2c-send-all",
                "c2c-setup",
                "c2c-start",
                "c2c-stop",
                "c2c-verify",
                "c2c-wake-peer",
                "c2c-watch",
                "c2c-whoami",
                "restart-codex-self",
                "restart-crush-self",
                "restart-kimi-self",
                "restart-opencode-self",
                "run-crush-inst",
                "run-crush-inst-outer",
                "run-crush-inst-rearm",
                "run-kimi-inst",
                "run-kimi-inst-outer",
                "run-kimi-inst-rearm",
            ],
        )
        self.assertTrue((install_dir / "c2c").exists())
        self.assertTrue((install_dir / "c2c-configure-claude-code").exists())
        self.assertTrue((install_dir / "c2c-configure-opencode").exists())
        self.assertTrue((install_dir / "c2c-deliver-inbox").exists())
        self.assertTrue((install_dir / "c2c-inject").exists())
        self.assertTrue((install_dir / "c2c-poker-sweep").exists())
        self.assertTrue((install_dir / "c2c-poll-inbox").exists())
        self.assertTrue((install_dir / "c2c-prune").exists())
        self.assertTrue((install_dir / "c2c-register").exists())
        self.assertTrue((install_dir / "c2c-room").exists())
        self.assertTrue((install_dir / "c2c-setup").exists())
        self.assertTrue((install_dir / "c2c-kimi-wire-bridge").exists())
        self.assertTrue((install_dir / "restart-opencode-self").exists())
        self.assertTrue((install_dir / "run-kimi-inst").exists())
        self.assertTrue((install_dir / "run-crush-inst").exists())
        self.assertTrue((install_dir / "c2c-watch").exists())
        self.assertTrue((install_dir / "c2c-whoami").exists())

    def test_install_wrapper_exec_points_to_git_common_root(self):
        """Wrapper exec path must resolve to the main repo root, not a worktree."""
        import subprocess as _subprocess

        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)

        result = self.invoke_cli("c2c-install", env=env)
        self.assertEqual(result_code(result), 0)

        wrapper_content = (install_dir / "c2c").read_text(encoding="utf-8")
        # Extract the exec path from: exec "/path/to/c2c" "$@"
        exec_line = next(
            l for l in wrapper_content.splitlines() if l.startswith("exec ")
        )
        exec_path = exec_line.split('"')[1]  # e.g. /home/xertrov/src/c2c-msg/c2c

        # The wrapper must point to the git-common-dir parent (main repo), not a worktree.
        git_common_dir = _subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"], text=True
        ).strip()
        expected_root = str(Path(git_common_dir).resolve().parent)
        self.assertTrue(
            exec_path.startswith(expected_root),
            f"exec path {exec_path!r} does not start with main repo root {expected_root!r}",
        )

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
        import c2c_sweep_dryrun

        broker_root = Path(self.temp_dir.name) / "broker"
        broker_root.mkdir()
        (broker_root / "registry.json").write_text("[]", encoding="utf-8")

        stdout = io.StringIO()
        with mock.patch("sys.stdout", stdout):
            result = c2c_sweep_dryrun.main(
                ["--root", str(broker_root), "--json"]
            )

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["root"], str(broker_root))

    def test_sweep_dryrun_reports_likely_stale_duplicate_pid_aliases(self):
        import c2c_sweep_dryrun

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
        import c2c_sweep_dryrun

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

    def test_register_updates_broker_registry_json(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        del env["C2C_REGISTRY_PATH"]

        result = self.invoke_cli("c2c-register", "agent-one", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        broker_data = json.loads(
            (broker_root / "registry.json").read_text(encoding="utf-8")
        )
        self.assertEqual(len(broker_data), 1)
        self.assertEqual(broker_data[0]["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(broker_data[0]["alias"], payload["alias"])
        self.assertIsInstance(broker_data[0].get("pid"), int)
        self.assertIsInstance(broker_data[0].get("pid_start_time"), int)

    def test_sync_broker_registry_writes_json_atomically(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        replaced = []
        original_replace = os.replace

        def tracking_replace(src, dst):
            replaced.append((src, dst))
            return original_replace(src, dst)

        with (
            mock.patch.dict(
                os.environ,
                {"C2C_REGISTRY_PATH": str(self.registry_path)},
                clear=False,
            ),
            mock.patch("c2c_mcp.os.replace", side_effect=tracking_replace),
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(len(replaced), 1)
        _, destination = replaced[0]
        self.assertEqual(Path(destination), broker_root / "registry.json")
        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [{"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}],
        )

    def test_sync_broker_registry_preserves_broker_only_registrations(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": "codex-local", "alias": "codex"},
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "old-alias"},
                ]
            ),
            encoding="utf-8",
        )
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                {"session_id": "codex-local", "alias": "codex"},
            ],
        )

    def test_sync_broker_registry_preserves_liveness_metadata_for_yaml_backed_peer(
        self,
    ):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-ember",
                        "pid": 4242,
                        "pid_start_time": 9999,
                    }
                ]
            ),
            encoding="utf-8",
        )
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {
                    "session_id": AGENT_ONE_SESSION_ID,
                    "alias": "storm-ember",
                    "pid": 4242,
                    "pid_start_time": 9999,
                }
            ],
        )

    def test_sync_broker_registry_preserves_broker_only_liveness_metadata(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": "codex-local",
                        "alias": "codex",
                        "pid": 123,
                        "pid_start_time": 456,
                    }
                ]
            ),
            encoding="utf-8",
        )
        save_registry({"registrations": []}, self.registry_path)

        with mock.patch.dict(
            os.environ,
            {"C2C_REGISTRY_PATH": str(self.registry_path)},
            clear=False,
        ):
            c2c_mcp.sync_broker_registry(broker_root)

        self.assertEqual(
            json.loads((broker_root / "registry.json").read_text(encoding="utf-8")),
            [
                {
                    "session_id": "codex-local",
                    "alias": "codex",
                    "pid": 123,
                    "pid_start_time": 456,
                }
            ],
        )

    def test_install_reports_path_guidance_when_bin_not_on_path(self):
        install_dir = Path(self.temp_dir.name) / "bin"
        env = dict(self.env)
        env["C2C_INSTALL_BIN_DIR"] = str(install_dir)
        env["PATH"] = "/usr/bin"

        result = self.invoke_cli("c2c-install", env=env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("not currently on PATH", result.stdout)

class C2CCLIUnitTests(unittest.TestCase):
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

def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
