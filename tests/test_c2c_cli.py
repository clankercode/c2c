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

    def test_c2c_mcp_defaults_broker_root_to_shared_git_c2c_dir(self):
        expected = REPO / ".git" / "c2c" / "mcp"
        with mock.patch.dict(os.environ, {}, clear=False):
            self.assertEqual(c2c_mcp.default_broker_root(), expected)

    def test_c2c_mcp_infers_session_id_when_env_not_set(self):
        with (
            mock.patch.dict(os.environ, {}, clear=False),
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions",
                return_value=[
                    {
                        "name": "agent-one",
                        "pid": 11111,
                        "session_id": AGENT_ONE_SESSION_ID,
                    }
                ],
            ),
            mock.patch(
                "c2c_mcp.find_session",
                return_value={
                    "name": "agent-one",
                    "pid": 11111,
                    "session_id": AGENT_ONE_SESSION_ID,
                },
            ),
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

    def test_c2c_mcp_default_session_id_retries_briefly_for_fresh_session_file(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions", side_effect=[[], [session]]
            ) as load_mock,
            mock.patch("c2c_mcp.find_session", side_effect=[None, session]),
            mock.patch("c2c_mcp.time.monotonic", side_effect=[100.0, 100.01]),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

        self.assertEqual(load_mock.call_count, 2)
        sleep_mock.assert_called_once_with(
            c2c_mcp.SESSION_DISCOVERY_POLL_INTERVAL_SECONDS
        )

    def test_c2c_mcp_default_session_id_waits_long_enough_for_real_startup(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch(
                "c2c_mcp.load_sessions",
                side_effect=[[], [], [], [], [], [session]],
            ) as load_mock,
            mock.patch(
                "c2c_mcp.find_session",
                side_effect=[None, None, None, None, None, session],
            ),
            mock.patch(
                "c2c_mcp.time.monotonic",
                side_effect=[100.0, 100.05, 100.10, 100.15, 100.20, 100.25],
            ),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            self.assertEqual(c2c_mcp.default_session_id(), AGENT_ONE_SESSION_ID)

        self.assertEqual(load_mock.call_count, 6)
        self.assertEqual(sleep_mock.call_count, 5)

    def test_c2c_mcp_default_session_id_stops_after_bounded_wait(self):
        with (
            mock.patch("c2c_mcp.current_session_identifier", return_value="11111"),
            mock.patch("c2c_mcp.load_sessions", side_effect=[[], []]) as load_mock,
            mock.patch("c2c_mcp.find_session", side_effect=[None, None]),
            mock.patch("c2c_mcp.time.monotonic", side_effect=[100.0, 100.5, 110.1]),
            mock.patch("c2c_mcp.time.sleep") as sleep_mock,
        ):
            with self.assertRaisesRegex(ValueError, "session not found: 11111"):
                c2c_mcp.default_session_id()

        self.assertEqual(load_mock.call_count, 2)
        sleep_mock.assert_called_once_with(
            c2c_mcp.SESSION_DISCOVERY_POLL_INTERVAL_SECONDS
        )

    def test_c2c_mcp_main_warns_and_skips_session_env_when_current_session_unresolvable(
        self,
    ):
        stderr = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"C2C_MCP_SESSION_ID": ""}, clear=False),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch(
                "c2c_mcp.default_session_id",
                side_effect=ValueError(
                    "could not resolve current session uniquely; use a session ID or PID"
                ),
            ),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", stderr),
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], str(REPO / ".git" / "c2c" / "mcp"))
        # The key may be absent OR empty — either means session ID was not resolved.
        self.assertFalse(
            env.get("C2C_MCP_SESSION_ID"),
            "session ID should be unset when discovery fails",
        )
        warning = stderr.getvalue()
        self.assertIn("c2c_mcp: WARNING session discovery failed", warning)
        self.assertIn("tool calls will need an explicit session_id", warning)

    def test_c2c_mcp_main_exports_parent_client_pid_for_server_register(self):
        with (
            mock.patch.dict(
                os.environ,
                {"C2C_MCP_SESSION_ID": "", "C2C_MCP_CLIENT_PID": ""},
                clear=False,
            ),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.os.getppid", return_value=424242),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_SESSION_ID"], AGENT_ONE_SESSION_ID)
        self.assertEqual(env["C2C_MCP_CLIENT_PID"], "424242")

    def test_c2c_mcp_main_replaces_dead_client_pid_env_for_server_register(self):
        with (
            mock.patch.dict(
                os.environ,
                {"C2C_MCP_SESSION_ID": "", "C2C_MCP_CLIENT_PID": "11111"},
                clear=False,
            ),
            mock.patch(
                "c2c_mcp.default_broker_root",
                return_value=REPO / ".git" / "c2c" / "mcp",
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.os.path.exists", return_value=False),
            mock.patch("c2c_mcp.os.getppid", return_value=424242),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        env = run_mock.call_args_list[1].kwargs["env"]
        self.assertEqual(env["C2C_MCP_SESSION_ID"], AGENT_ONE_SESSION_ID)
        self.assertEqual(env["C2C_MCP_CLIENT_PID"], "424242")

    def test_c2c_mcp_auto_register_ignores_dead_client_pid_env(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        live_parent_pid = os.getpid()
        env = {
            "C2C_MCP_BROKER_ROOT": str(broker_root),
            "C2C_MCP_SESSION_ID": "kimi-nova",
            "C2C_MCP_AUTO_REGISTER_ALIAS": "kimi-nova",
            "C2C_MCP_CLIENT_PID": "11111",
        }

        with (
            mock.patch("c2c_mcp._session_pid_from_proc", return_value=None),
            mock.patch("c2c_mcp.os.getppid", return_value=live_parent_pid),
        ):
            c2c_mcp.maybe_auto_register_startup(env)

        registrations = c2c_mcp.load_broker_registrations(broker_root / "registry.json")
        self.assertEqual(len(registrations), 1)
        self.assertEqual(registrations[0]["alias"], "kimi-nova")
        self.assertEqual(registrations[0]["pid"], live_parent_pid)
        self.assertEqual(
            registrations[0]["pid_start_time"],
            c2c_mcp.read_pid_start_time(live_parent_pid),
        )

    def test_c2c_mcp_stdio_initialize_smoke(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_ONE_SESSION_ID
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            }
        )
        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(body + "\n")
            process.stdin.flush()

            payload = process.stdout.readline()
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertIn('"protocolVersion":"2024-11-05"', payload)

    def test_c2c_mcp_main_seeds_broker_registry_and_session_env(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    # Clear any real session ID so default_session_id() is invoked.
                    "C2C_MCP_SESSION_ID": "",
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry") as sync_registry,
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.return_value.returncode = 0

            result = c2c_mcp.main([])

        self.assertEqual(result, 0)
        sync_registry.assert_called_once_with(broker_root)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].kwargs["env"]["C2C_MCP_SESSION_ID"],
            AGENT_ONE_SESSION_ID,
        )
        self.assertEqual(
            run_mock.call_args_list[1].kwargs["env"]["C2C_MCP_BROKER_ROOT"],
            str(broker_root),
        )

    def test_c2c_mcp_main_builds_server_before_launch(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch(
                "c2c_mcp.built_server_path",
                return_value=REPO
                / "_build"
                / "default"
                / "ocaml"
                / "server"
                / "c2c_mcp_server.exe",
            ),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.side_effect = [
                mock.Mock(returncode=0),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[0].args[0],
            [
                "opam",
                "exec",
                "--switch=/home/xertrov/src/call-coding-clis/ocaml",
                "--",
                "dune",
                "build",
                "--root",
                str(REPO),
                "./ocaml/server/c2c_mcp_server.exe",
            ],
        )

    def test_c2c_mcp_main_launches_built_server_directly(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = (
            REPO / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"
        )

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
        ):
            run_mock.side_effect = [
                mock.Mock(returncode=0),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        launch_call = run_mock.call_args_list[1]
        self.assertEqual(launch_call.args[0], [str(built_server), "--help"])
        self.assertEqual(launch_call.kwargs["cwd"], REPO)
        self.assertNotIn("bash", launch_call.args[0])

    def test_c2c_mcp_main_falls_back_to_existing_binary_when_build_fails(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = Path(self.temp_dir.name) / "c2c_mcp_server.exe"
        built_server.write_text("#!/bin/sh\n", encoding="utf-8")

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            run_mock.side_effect = [
                subprocess.CalledProcessError(2, ["dune", "build"]),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].args[0], [str(built_server), "--help"]
        )
        self.assertIn("build failed but existing binary found", stderr.getvalue())
        self.assertIn(str(built_server), stderr.getvalue())

    def test_c2c_mcp_main_falls_back_to_existing_binary_when_build_times_out(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        built_server = Path(self.temp_dir.name) / "c2c_mcp_server.exe"
        built_server.write_text("#!/bin/sh\n", encoding="utf-8")

        with (
            mock.patch.dict(
                os.environ,
                {
                    "C2C_REGISTRY_PATH": str(self.registry_path),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                },
                clear=False,
            ),
            mock.patch("c2c_mcp.sync_broker_registry"),
            mock.patch("c2c_mcp.default_session_id", return_value=AGENT_ONE_SESSION_ID),
            mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            mock.patch("c2c_mcp.built_server_path", return_value=built_server),
            mock.patch("c2c_mcp.BUILD_SERVER_TIMEOUT_SECONDS", 0.01),
            mock.patch("c2c_mcp.subprocess.run") as run_mock,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            run_mock.side_effect = [
                subprocess.TimeoutExpired(["dune", "build"], 0.01),
                mock.Mock(returncode=0),
            ]

            result = c2c_mcp.main(["--help"])

        self.assertEqual(result, 0)
        self.assertEqual(run_mock.call_count, 2)
        self.assertEqual(
            run_mock.call_args_list[1].args[0], [str(built_server), "--help"]
        )
        self.assertEqual(run_mock.call_args_list[0].kwargs["timeout"], 0.01)
        self.assertIn("build timed out but existing binary found", stderr.getvalue())

    def test_c2c_mcp_emits_channel_notification_for_session_inbox(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_TWO_SESSION_ID
        env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "1"

        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            ),
            encoding="utf-8",
        )
        (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-ember",
                        "to_alias": "storm-storm",
                        "content": "debate opener",
                    }
                ]
            ),
            encoding="utf-8",
        )

        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"experimental": {"claude/channel": {}}},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            }
        )
        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(body + "\n")
            process.stdin.flush()

            init_payload = process.stdout.readline()
            notif_payload = process.stdout.readline()
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        init_json = json.loads(init_payload)
        notif_json = json.loads(notif_payload)

        self.assertEqual(init_json["result"]["protocolVersion"], "2024-11-05")
        self.assertIn("instructions", init_json["result"])
        self.assertEqual(notif_json["jsonrpc"], "2.0")
        self.assertEqual(notif_json["method"], "notifications/claude/channel")
        self.assertEqual(notif_json["params"]["content"], "debate opener")
        self.assertEqual(notif_json["params"]["meta"]["from_alias"], "storm-ember")
        self.assertEqual(notif_json["params"]["meta"]["to_alias"], "storm-storm")

    def test_c2c_mcp_auto_drain_can_be_disabled_for_polling_clients(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_MCP_SESSION_ID"] = AGENT_TWO_SESSION_ID
        env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"

        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            ),
            encoding="utf-8",
        )
        (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-ember",
                        "to_alias": "storm-storm",
                        "content": "poll me",
                    }
                ]
            ),
            encoding="utf-8",
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            init_payload = json.loads(process.stdout.readline())

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "poll_inbox", "arguments": {}},
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            poll_payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(init_payload["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(poll_payload["id"], 2)
        self.assertEqual(poll_payload["result"]["isError"], False)
        messages = json.loads(poll_payload["result"]["content"][0]["text"])
        self.assertEqual(
            messages,
            [
                {
                    "from_alias": "storm-ember",
                    "to_alias": "storm-storm",
                    "content": "poll me",
                }
            ],
        )

    def test_c2c_mcp_whoami_uses_current_session_registration(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_SESSION_ID"] = AGENT_ONE_SESSION_ID
        env["C2C_MCP_SESSION_ID"] = AGENT_ONE_SESSION_ID
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"}
                ]
            },
            self.registry_path,
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            process.stdout.readline()

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {"name": "whoami", "arguments": {}},
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(payload["result"]["isError"], False)
        self.assertEqual(payload["result"]["content"][0]["text"], "storm-ember")

    def test_c2c_mcp_send_resolves_aliases_from_cli_registry(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
        env["C2C_SESSION_ID"] = AGENT_ONE_SESSION_ID
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = "storm-ember"
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-ember"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "storm-storm"},
                ]
            },
            self.registry_path,
        )

        process = subprocess.Popen(
            [str(REPO / "c2c"), "mcp"],
            cwd=REPO,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert process.stdin is not None
            assert process.stdout is not None
            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-11-25",
                            "capabilities": {},
                            "clientInfo": {"name": "test", "version": "0"},
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            process.stdout.readline()

            process.stdin.write(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "tools/call",
                        "params": {
                            "name": "send",
                            "arguments": {
                                "from_alias": "storm-ember",
                                "to_alias": "storm-storm",
                                "content": "hello from mcp",
                            },
                        },
                    }
                )
                + "\n"
            )
            process.stdin.flush()
            payload = json.loads(process.stdout.readline())
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
            process.terminate()
            process.wait(timeout=CLI_TIMEOUT_SECONDS)

        self.assertEqual(payload["result"]["isError"], False)
        receipt = json.loads(payload["result"]["content"][0]["text"])
        self.assertTrue(receipt["queued"])
        self.assertIn("ts", receipt)
        self.assertEqual(
            json.loads(
                (broker_root / f"{AGENT_TWO_SESSION_ID}.inbox.json").read_text(
                    encoding="utf-8"
                )
            ),
            [
                {
                    "from_alias": "storm-ember",
                    "to_alias": "storm-storm",
                    "content": "hello from mcp",
                }
            ],
        )

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

    def test_run_codex_inst_dry_run_builds_resume_command_with_unique_c2c_id(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-a.json").write_text(
            json.dumps(
                {
                    "command": "codex",
                    "mode": "resume",
                    "resume": "019d8483-ad93-72f1-85ba-e14f0f7e743d",
                    "flags": [
                        "--ask-for-approval",
                        "never",
                        "--sandbox",
                        "danger-full-access",
                    ],
                    "cwd": str(REPO),
                    "prompt": "Poll c2c and continue.",
                    "title": "codex-a",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "codex-a", "--search", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["cwd"], str(REPO))
        self.assertEqual(payload["pid_file"], str(config_dir / "codex-a.pid"))
        self.assertEqual(payload["env"]["RUN_CODEX_INST_NAME"], "codex-a")
        self.assertEqual(
            payload["env"]["RUN_CODEX_INST_C2C_SESSION_ID"], "codex-codex-a"
        )
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        # Remove the dynamic PID override before checking the rest of launch
        launch = payload["launch"]
        pid_override = f'mcp_servers.c2c.env.C2C_MCP_CLIENT_PID="{payload["env"]["C2C_MCP_CLIENT_PID"]}"'
        if pid_override in launch:
            idx = launch.index(pid_override)
            launch = (
                launch[: idx - 1] + launch[idx + 1 :]
            )  # remove the preceding "-c" too
        self.assertEqual(
            launch,
            [
                "codex",
                "--ask-for-approval",
                "never",
                "--sandbox",
                "danger-full-access",
                "--search",
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_SESSION_ID="codex-codex-a"',
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_AUTO_DRAIN_CHANNEL="0"',
                "resume",
                "019d8483-ad93-72f1-85ba-e14f0f7e743d",
                "Poll c2c and continue.",
            ],
        )

    def test_c2c_poker_default_message_orients_idle_agent_to_continue(self):
        message = c2c_poker.DEFAULT_MESSAGE

        self.assertIn("Poll your C2C inbox", message)
        self.assertIn("tmp_status.txt", message)
        self.assertIn("tmp_collab_lock.md", message)
        self.assertIn("Empty inbox is not a stop signal", message)
        self.assertIn("highest-leverage unblocked", message)
        self.assertNotIn("ignore", message.lower())

    def test_c2c_poll_inbox_file_fallback_drains_without_host_mcp_tool(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "codex",
                        "content": "recover without mcp",
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "codex-local",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], "codex-local")
        self.assertEqual(payload["source"], "file")
        self.assertEqual(
            payload["messages"],
            [
                {
                    "from_alias": "storm-echo",
                    "to_alias": "codex",
                    "content": "recover without mcp",
                }
            ],
        )
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_c2c_poll_inbox_defaults_session_from_run_codex_env(self):
        with mock.patch.dict(
            os.environ, {"RUN_CODEX_INST_C2C_SESSION_ID": "codex-from-env"}
        ):
            self.assertEqual(c2c_poll_inbox.resolve_session_id(None), "codex-from-env")

    def test_c2c_poll_inbox_falls_back_to_file_when_direct_mcp_fails(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "codex",
                        "content": "mcp failed but file worked",
                    }
                ]
            ),
            encoding="utf-8",
        )

        with mock.patch(
            "c2c_poll_inbox.call_mcp_tool",
            side_effect=RuntimeError("mcp startup failed"),
        ):
            source, messages = c2c_poll_inbox.poll_inbox(
                broker_root=broker_root,
                session_id="codex-local",
                timeout=0.1,
                force_file=False,
                allow_file_fallback=True,
            )

        self.assertEqual(source, "file")
        self.assertEqual(messages[0]["content"], "mcp failed but file worked")
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_c2c_poll_inbox_times_out_mcp_startup_and_falls_back_to_file(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "codex",
                        "content": "stuck mcp build but file worked",
                    }
                ]
            ),
            encoding="utf-8",
        )

        class StuckProcess:
            pid = 12345

            def communicate(self, _input, timeout=None):
                raise subprocess.TimeoutExpired(["c2c_mcp.py"], timeout)

            def wait(self, timeout=None):
                return 0

        with (
            mock.patch("c2c_poll_inbox.subprocess.Popen", return_value=StuckProcess()),
            mock.patch("c2c_poll_inbox.os.killpg") as killpg,
        ):
            source, messages = c2c_poll_inbox.poll_inbox(
                broker_root=broker_root,
                session_id="codex-local",
                timeout=0.1,
                force_file=False,
                allow_file_fallback=True,
            )

        self.assertEqual(source, "file")
        self.assertEqual(messages[0]["content"], "stuck mcp build but file worked")
        killpg.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])

    def test_file_fallback_peek_reads_without_draining(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "codex",
                "to_alias": "opencode-local",
                "content": "peek test",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = c2c_poll_inbox.file_fallback_peek(broker_root, "opencode-local")

        self.assertEqual(result, msgs)
        # Inbox must still contain the messages (non-destructive)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_file_fallback_peek_returns_empty_when_no_inbox(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-empty"
        broker_root.mkdir()
        result = c2c_poll_inbox.file_fallback_peek(broker_root, "ghost-session")
        self.assertEqual(result, [])
        # Should NOT create the file (unlike poll which creates it)
        self.assertFalse((broker_root / "ghost-session.inbox.json").exists())

    def test_c2c_poll_inbox_peek_flag_is_nondestructive(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-flag"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "storm-beacon",
                "to_alias": "opencode-local",
                "content": "hello",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "opencode-local",
            "--broker-root",
            str(broker_root),
            "--peek",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["source"], "file-peek")
        self.assertEqual(payload["messages"], msgs)
        # Messages must remain in inbox
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_c2c_peek_inbox_subcommand_is_nondestructive(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker-peek-sub"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        msgs = [
            {
                "from_alias": "codex",
                "to_alias": "opencode-local",
                "content": "subcommand test",
            }
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c",
            "peek-inbox",
            "--session-id",
            "opencode-local",
            "--broker-root",
            str(broker_root),
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["source"], "file-peek")
        self.assertEqual(payload["messages"], msgs)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), msgs)

    def test_print_result_count_line_in_text_mode(self):
        """Text-mode output prefixes messages with a count/summary line."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-text"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-count.inbox.json"
        msgs = [
            {"from_alias": "peer-a", "to_alias": "ses-count", "content": "hello"},
            {"from_alias": "peer-b", "to_alias": "ses-count", "content": "world"},
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-count",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        lines = result.stdout.splitlines()
        # First line must be the progress indicator
        self.assertIn("[c2c-poll-inbox]", lines[0])
        self.assertIn("2 messages", lines[0])
        self.assertIn("ses-count", lines[0])
        # Remaining lines are the message envelopes
        self.assertTrue(any('<c2c event="message"' in ln for ln in lines[1:]))

    def test_print_result_singular_message_count_line(self):
        """Single-message drain uses 'message' (not 'messages')."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-singular"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-one.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [{"from_alias": "peer", "to_alias": "ses-one", "content": "hi"}]
            ),
            encoding="utf-8",
        )

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-one",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        first_line = result.stdout.splitlines()[0]
        self.assertIn("1 message", first_line)
        self.assertNotIn("1 messages", first_line)

    def test_print_result_count_field_in_json_mode(self):
        """JSON output includes a top-level 'count' field matching len(messages)."""
        broker_root = Path(self.temp_dir.name) / "mcp-count-json"
        broker_root.mkdir()
        inbox_path = broker_root / "ses-json.inbox.json"
        msgs = [
            {"from_alias": "a", "to_alias": "ses-json", "content": "one"},
            {"from_alias": "b", "to_alias": "ses-json", "content": "two"},
            {"from_alias": "c", "to_alias": "ses-json", "content": "three"},
        ]
        inbox_path.write_text(json.dumps(msgs), encoding="utf-8")

        result = run_cli(
            "c2c-poll-inbox",
            "--session-id",
            "ses-json",
            "--broker-root",
            str(broker_root),
            "--file-fallback",
            "--json",
            env=self.env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn("count", payload)
        self.assertEqual(payload["count"], 3)
        self.assertEqual(len(payload["messages"]), payload["count"])

    def test_run_codex_inst_allows_explicit_c2c_id_for_multiple_codex_sessions(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "reviewer.json").write_text(
            json.dumps(
                {
                    "mode": "exec-resume",
                    "resume": "test-codex-for-injection",
                    "c2c_session_id": "codex-reviewer-1",
                    "cwd": str(REPO),
                    "prompt": "Poll c2c once.",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "reviewer", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["env"]["RUN_CODEX_INST_C2C_SESSION_ID"], "codex-reviewer-1"
        )
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        # Remove the dynamic PID override before checking the rest of launch
        launch = payload["launch"]
        pid_override = f'mcp_servers.c2c.env.C2C_MCP_CLIENT_PID="{payload["env"]["C2C_MCP_CLIENT_PID"]}"'
        if pid_override in launch:
            idx = launch.index(pid_override)
            launch = (
                launch[: idx - 1] + launch[idx + 1 :]
            )  # remove the preceding "-c" too
        self.assertEqual(
            launch,
            [
                "codex",
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_SESSION_ID="codex-reviewer-1"',
                "-c",
                'mcp_servers.c2c.env.C2C_MCP_AUTO_DRAIN_CHANNEL="0"',
                "exec",
                "resume",
                "test-codex-for-injection",
                "Poll c2c once.",
            ],
        )

    def test_run_codex_inst_passes_alias_hint_to_mcp_auto_register(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-main.json").write_text(
            json.dumps(
                {
                    "mode": "resume",
                    "resume": "test-codex-for-restart",
                    "c2c_session_id": "codex-local",
                    "c2c_alias": "codex",
                    "cwd": str(REPO),
                    "prompt": "Poll c2c once.",
                }
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
        env["RUN_CODEX_INST_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst", "codex-main", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertIn(
            'mcp_servers.c2c.env.C2C_MCP_AUTO_REGISTER_ALIAS="codex"',
            payload["launch"],
        )
        self.assertEqual(payload["env"]["RUN_CODEX_INST_ALIAS_HINT"], "codex")

    def test_run_codex_inst_outer_dry_run_reports_inner_launch_command(self):
        env = dict(self.env)
        env["RUN_CODEX_INST_OUTER_DRY_RUN"] = "1"

        result = run_cli("run-codex-inst-outer", "codex-a", "--search", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:], [str(REPO / "run-codex-inst"), "codex-a", "--search"]
        )

    def test_run_claude_inst_outer_refreshes_peer_after_child_spawn(self):
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-claude-inst"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner

        refresh_calls = []

        class FakeProcess:
            pid = 43210

            def wait(self):
                return 0

        namespace["main"].__globals__["maybe_refresh_peer"] = lambda name, pid: (
            refresh_calls.append((name, pid))
        )

        with (
            mock.patch("subprocess.Popen", return_value=FakeProcess()),
            mock.patch(
                "subprocess.run", return_value=subprocess.CompletedProcess([], 0)
            ),
            mock.patch("time.sleep", side_effect=KeyboardInterrupt),
        ):
            with self.assertRaises(KeyboardInterrupt):
                namespace["main"](["run-claude-inst-outer", "claude-a"])

        self.assertEqual(refresh_calls, [("claude-a", 43210)])

    def test_run_claude_inst_outer_refresh_peer_uses_config_alias(self):
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        # Config with top-level c2c_session_id; refresh-peer gets --session-id.
        (cfg_dir / "claude-a.json").write_text(
            json.dumps({"c2c_alias": "storm-beacon", "c2c_session_id": "sid-abc"}),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(
                {
                    "command": command,
                    "cwd": cwd,
                    "capture_output": capture_output,
                    "text": text,
                    "timeout": timeout,
                }
            )
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0]["command"],
            [
                sys.executable,
                str(refresh),
                "storm-beacon",
                "--pid",
                "12345",
                "--session-id",
                "sid-abc",
            ],
        )
        self.assertEqual(calls[0]["cwd"], root)
        self.assertTrue(calls[0]["capture_output"])
        self.assertTrue(calls[0]["text"])
        self.assertEqual(calls[0]["timeout"], 5.0)

    def test_run_claude_inst_outer_refresh_peer_passes_env_session_id(self):
        """Claude instances store session_id in env.C2C_MCP_SESSION_ID; outer loop passes it."""
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        # Claude format: session_id is in env dict, not top-level
        (cfg_dir / "claude-b.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "storm-beacon",
                    "env": {
                        "C2C_MCP_SESSION_ID": "d16034fc-5526-414b-a88e-709d1a93e345"
                    },
                }
            ),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-b", 12345)

        self.assertEqual(len(calls), 1)
        self.assertIn("--session-id", calls[0])
        idx = calls[0].index("--session-id")
        self.assertEqual(calls[0][idx + 1], "d16034fc-5526-414b-a88e-709d1a93e345")

    def test_run_claude_inst_outer_refresh_peer_no_session_id_in_config(self):
        """When config has no session_id, --session-id is not passed."""
        namespace = runpy.run_path(str(REPO / "run-claude-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-claude-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "claude-c.json").write_text(
            json.dumps({"c2c_alias": "storm-beacon"}),
            encoding="utf-8",
        )
        refresh = root / "c2c_refresh_peer.py"
        refresh.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        namespace["maybe_refresh_peer"].__globals__["HERE"] = root

        calls = []

        def fake_run(command, *, cwd, capture_output, text, timeout):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, stdout="{}", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            namespace["maybe_refresh_peer"]("claude-c", 12345)

        self.assertEqual(len(calls), 1)
        self.assertNotIn("--session-id", calls[0])

    def test_run_codex_inst_rearm_dry_run_reports_bg_loop_commands(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        (config_dir / "codex-a.pid").write_text("12345\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-codex-inst-rearm",
            "codex-a",
            "--session-id",
            "codex-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "codex-a")
        self.assertEqual(payload["target_pid"], 12345)
        self.assertEqual(payload["session_id"], "codex-a-local")
        self.assertTrue(payload["dry_run"])
        self.assertEqual(
            payload["pidfiles"],
            {
                "poker": str(config_dir / "codex-a.poker.pid"),
                "deliver": str(config_dir / "codex-a.deliver.pid"),
            },
        )
        joined_commands = "\n".join(
            " ".join(command) for command in payload["commands"]
        )
        self.assertIn("c2c_poker.py", joined_commands)
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id codex-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)
        self.assertIn("--daemon-timeout 30", joined_commands)

    def test_codex_b4_config_rearms_bg_loops_before_resume(self):
        config = json.loads(
            (REPO / "run-codex-inst.d" / "c2c-codex-b4.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertEqual(
            config["pre_exec"],
            [str(REPO / "run-codex-inst-rearm"), "c2c-codex-b4"],
        )

    def test_restart_codex_self_dry_run_reads_pid_file_without_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            (config_dir / "codex-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_CODEX_INST_NAME"] = "codex-a"
            env["RUN_CODEX_RESTART_SELF_DRY_RUN"] = "1"

            result = run_cli("restart-codex-self", "--expect-comm", "sleep", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["name"], "codex-a")
            self.assertEqual(payload["pid"], sleeper.pid)
            self.assertEqual(payload["pid_file"], str(config_dir / "codex-a.pid"))
            self.assertEqual(payload["signal"], "SIGTERM")
            self.assertEqual(payload["comm"], "sleep")
            self.assertEqual(payload["dry_run"], True)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_codex_self_writes_reason_marker_before_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-codex-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"])
        try:
            (config_dir / "codex-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_CODEX_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_CODEX_INST_NAME"] = "codex-a"
            env["RUN_CODEX_RESTART_SELF_DRY_RUN"] = "0"

            result = run_cli(
                "restart-codex-self",
                "--expect-comm",
                "sleep",
                "--reason",
                "rebuilt c2c mcp after startup failure",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            marker_path = config_dir / "codex-a.restart.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            self.assertEqual(marker["name"], "codex-a")
            self.assertEqual(marker["pid"], sleeper.pid)
            self.assertEqual(marker["signal"], "SIGTERM")
            self.assertEqual(marker["reason"], "rebuilt c2c mcp after startup failure")
            self.assertFalse(marker["dry_run"])
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
                try:
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    sleeper.kill()
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_codex_self_requires_instance_name(self):
        env = dict(self.env)
        env["RUN_CODEX_INST_NAME"] = ""

        result = run_cli("restart-codex-self", env=env)

        self.assertEqual(result_code(result), 2)
        self.assertIn("no instance name", result.stderr)

    def test_whoami_json_reports_alias_and_registration_status(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", "--json", env=self.env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "agent-one")
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["registered"], True)
        self.assertRegex(payload["alias"], r"^[a-z]+-[a-z]+$")
        self.assertIn("tutorial", payload)

    def test_whoami_fails_clearly_for_unregistered_session(self):
        result = self.invoke_cli("c2c-whoami", "agent-one", env=self.env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("session is not registered", result.stderr)

    def test_whoami_without_selector_uses_current_session(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)
        env = dict(self.env)
        env["C2C_SESSION_PID"] = "11111"

        result = self.invoke_cli("c2c-whoami", "--json", env=env)

        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["name"], "agent-one")

    def test_whoami_without_selector_uses_parent_shell_claude_child_when_env_missing(
        self,
    ):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                ]
            },
            self.registry_path,
        )

        with (
            mock.patch.dict(os.environ, self.env, clear=False),
            mock.patch("c2c_whoami.current_session_identifier", return_value="11111"),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            result = c2c_whoami.main(["--json"])

        self.assertEqual(result, 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["session_id"], AGENT_ONE_SESSION_ID)
        self.assertEqual(payload["name"], "agent-one")

    def test_whoami_without_selector_fails_when_not_uniquely_resolvable(self):
        stderr = io.StringIO()

        with (
            mock.patch.dict(os.environ, self.env, clear=False),
            mock.patch(
                "c2c_whoami.current_session_identifier",
                side_effect=ValueError(
                    "could not resolve current session uniquely; use a session ID or PID"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_whoami.main([])

        self.assertEqual(result, 1)
        self.assertIn("could not resolve current session uniquely", stderr.getvalue())
        self.assertIn("session ID or PID", stderr.getvalue())

    def test_whoami_human_output_includes_tutorial(self):
        self.invoke_cli("c2c-register", "agent-one", env=self.env)

        result = self.invoke_cli("c2c-whoami", "agent-one", env=self.env)

        self.assertEqual(result_code(result), 0)
        self.assertIn("Alias:", result.stdout)
        self.assertIn("Session: agent-one", result.stdout)
        self.assertIn(f"Session ID: {AGENT_ONE_SESSION_ID}", result.stdout)
        self.assertIn("Registered: yes", result.stdout)
        self.assertIn("What is C2C?", result.stdout)
        self.assertIn("c2c-send <alias> <message...>", result.stdout)
        self.assertIn("If Bash approval allows it, reply with c2c-send", result.stdout)
        self.assertIn(
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            result.stdout,
        )

    def test_register_rejects_ambiguous_session_name(self):
        ambiguous_env = dict(self.env)
        ambiguous_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-ambiguous-name.json"
        )

        result = self.invoke_cli("c2c-register", "shared-agent", env=ambiguous_env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("ambiguous session name", result.stderr)
        self.assertIn("session ID or PID", result.stderr)

    def test_register_fails_fast_for_invalid_sessions_fixture(self):
        invalid_env = dict(self.env)
        invalid_env["C2C_SESSIONS_FIXTURE"] = str(
            REPO / "tests/fixtures/sessions-invalid.json"
        )

        result = self.invoke_cli("c2c-register", "agent-one", env=invalid_env)

        self.assertEqual(result_code(result), 1)
        self.assertIn("invalid sessions fixture", result.stderr)

    def test_send_resolves_alias_to_live_session(self):
        registered = self.invoke_cli(
            "c2c-register", "agent-two", "--json", env=self.env
        )
        self.assertEqual(result_code(registered), 0)
        alias = json.loads(registered.stdout)["alias"]
        sent = self.invoke_cli(
            "c2c-send",
            alias,
            "hello",
            "peer",
            "--dry-run",
            "--json",
        )
        self.assertEqual(result_code(sent), 0)
        payload = json.loads(sent.stdout)
        self.assertEqual(payload["resolved_alias"], alias)
        self.assertEqual(
            payload["to_session_id"], "fa68bd5b-0529-4292-bc27-d617f6840ce7"
        )

    def test_send_fails_clearly_for_unknown_alias(self):
        result = self.invoke_cli("c2c-send", "unknown-alias", "hello")

        self.assertEqual(result_code(result), 1)
        self.assertIn("unknown alias", result.stderr)
        self.assertIn("unknown-alias", result.stderr)

    def test_send_dry_run_resolves_broker_only_alias(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir(parents=True, exist_ok=True)
        (broker_root / "registry.json").write_text(
            json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)

        result = self.invoke_cli(
            "c2c-send", "codex", "hello", "peer", "--dry-run", "--json", env=env
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["resolved_alias"], "codex")
        self.assertEqual(payload["to"], "broker:codex-local")
        self.assertEqual(payload["to_session_id"], "codex-local")

    def test_verify_supports_fixture_based_json_output(self):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                ]
            },
            self.registry_path,
        )
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")
        result = self.invoke_cli("c2c-verify", "--json", env=verify_env)
        self.assertEqual(result_code(result), 0)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload,
            {
                "goal_met": False,
                "participants": {
                    "agent-one": {"received": 1, "sent": 1},
                    "agent-two": {"received": 1, "sent": 1},
                },
            },
        )

    def test_verify_human_output_reports_progress_per_participant(self):
        save_registry(
            {
                "registrations": [
                    {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                    {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                ]
            },
            self.registry_path,
        )
        verify_env = dict(self.env)
        verify_env["C2C_VERIFY_FIXTURE"] = str(REPO / "tests/fixtures")

        result = self.invoke_cli("c2c-verify", env=verify_env)

        self.assertEqual(result_code(result), 0)
        self.assertEqual(
            result.stdout.strip().splitlines(),
            [
                "agent-one: sent=1 received=1 status=in_progress",
                "agent-two: sent=1 received=1 status=in_progress",
                "goal_met: no",
            ],
        )

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

class BuildRegistrationRecordTests(unittest.TestCase):
    def test_includes_pid_fields_when_passed(self):
        record = c2c_registry.build_registration_record(
            "sess-1", "storm-herald", pid=42, pid_start_time=99999
        )
        self.assertEqual(record["session_id"], "sess-1")
        self.assertEqual(record["alias"], "storm-herald")
        self.assertEqual(record["pid"], 42)
        self.assertEqual(record["pid_start_time"], 99999)

    def test_omits_pid_fields_when_not_passed(self):
        record = c2c_registry.build_registration_record("sess-1", "storm-herald")
        self.assertEqual(record, {"session_id": "sess-1", "alias": "storm-herald"})
        self.assertNotIn("pid", record)
        self.assertNotIn("pid_start_time", record)


class MergeBrokerRegistrationTests(unittest.TestCase):
    def test_carries_pid_fields_through_from_source(self):
        source = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        merged = c2c_mcp.merge_broker_registration(None, source)
        self.assertEqual(merged["pid"], 42)
        self.assertEqual(merged["pid_start_time"], 99999)

    def test_preserves_existing_pid_fields_when_source_has_none(self):
        existing = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        source = {"session_id": "sess-1", "alias": "storm-herald"}
        merged = c2c_mcp.merge_broker_registration(existing, source)
        self.assertEqual(merged["pid"], 42)
        self.assertEqual(merged["pid_start_time"], 99999)

    def test_source_pid_overwrites_existing(self):
        """YAML pid (refreshed on each register) takes precedence over stale broker pid."""
        existing = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 42,
            "pid_start_time": 99999,
        }
        source = {
            "session_id": "sess-1",
            "alias": "storm-herald",
            "pid": 100,
            "pid_start_time": 55555,
        }
        merged = c2c_mcp.merge_broker_registration(existing, source)
        self.assertEqual(merged["pid"], 100)
        self.assertEqual(merged["pid_start_time"], 55555)

    def test_pidless_new_entry_has_no_pid_fields(self):
        """New entry from pidless YAML should not fabricate pid fields."""
        source = {"session_id": "sess-1", "alias": "storm-herald"}
        merged = c2c_mcp.merge_broker_registration(None, source)
        self.assertNotIn("pid", merged)
        self.assertNotIn("pid_start_time", merged)


class SyncBrokerRegistryPidTests(unittest.TestCase):
    """Integration: sync_broker_registry preserves pid fields correctly."""

    def test_yaml_entry_with_pid_syncs_pid_to_broker(self):
        """YAML entries with pid populate the broker entry's pid fields."""
        with tempfile.TemporaryDirectory() as tmpdir:
            broker_root = Path(tmpdir) / "broker"
            broker_root.mkdir()
            yaml_path = Path(tmpdir) / "registry.yaml"
            yaml_path.write_text(
                "registrations:\n"
                "  - session_id: live-session\n"
                "    alias: storm-live\n"
                "    pid: 42\n"
                "    pid_start_time: 99999\n",
                encoding="utf-8",
            )
            with mock.patch("c2c_mcp.registry_path_from_env", return_value=yaml_path):
                c2c_mcp.sync_broker_registry(broker_root)

            data = json.loads(
                (broker_root / "registry.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["pid"], 42)
            self.assertEqual(data[0]["pid_start_time"], 99999)

    def test_broker_pid_preserved_when_yaml_has_no_pid(self):
        """When broker already has a pid-bearing entry, sync preserves it."""
        with tempfile.TemporaryDirectory() as tmpdir:
            broker_root = Path(tmpdir) / "broker"
            broker_root.mkdir()
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "live-session",
                            "alias": "storm-live",
                            "pid": 12345,
                            "pid_start_time": 99999,
                        }
                    ]
                ),
                encoding="utf-8",
            )
            yaml_path = Path(tmpdir) / "registry.yaml"
            yaml_path.write_text(
                "registrations:\n  - session_id: live-session\n    alias: storm-live\n",
                encoding="utf-8",
            )
            with mock.patch("c2c_mcp.registry_path_from_env", return_value=yaml_path):
                c2c_mcp.sync_broker_registry(broker_root)

            data = json.loads(
                (broker_root / "registry.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(data), 1)
            self.assertEqual(data[0]["pid"], 12345)
            self.assertEqual(data[0]["pid_start_time"], 99999)

class RestartMeUnitTests(unittest.TestCase):
    """Unit tests for c2c_restart_me helper functions."""

    def test_build_restart_argv_claude_code_with_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code",
            "abc-123",
            ["/usr/bin/claude", "--dangerously-skip-permissions"],
        )
        self.assertEqual(result[0], "/usr/bin/claude")
        self.assertIn("--resume", result)
        idx = result.index("--resume")
        self.assertEqual(result[idx + 1], "abc-123")
        self.assertIn("--dangerously-skip-permissions", result)

    def test_build_restart_argv_claude_code_no_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code", None, ["/usr/bin/claude"]
        )
        self.assertEqual(result, ["/usr/bin/claude"])
        self.assertNotIn("--resume", result)

    def test_build_restart_argv_claude_code_skips_prior_resume(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "claude-code",
            "new-uuid",
            ["/usr/bin/claude", "--resume", "old-uuid"],
        )
        self.assertIn("--resume", result)
        idx = result.index("--resume")
        self.assertEqual(result[idx + 1], "new-uuid")
        # old-uuid should not appear
        self.assertNotIn("old-uuid", result)

    def test_build_restart_argv_codex(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "codex", None, ["/usr/local/bin/codex", "--some-flag"]
        )
        self.assertEqual(result, ["/usr/local/bin/codex"])

    def test_build_restart_argv_opencode(self):
        import c2c_restart_me

        result = c2c_restart_me.build_restart_argv(
            "opencode", None, ["/usr/local/bin/opencode"]
        )
        self.assertEqual(result, ["/usr/local/bin/opencode"])

    def test_uuid_from_cmdline_extracts_resume_arg(self):
        import c2c_restart_me

        cmdline = ["claude", "--resume", "abc-def-123-456-7890"]
        result = c2c_restart_me._uuid_from_cmdline(cmdline)
        self.assertEqual(result, "abc-def-123-456-7890")

    def test_uuid_from_cmdline_returns_none_without_resume(self):
        import c2c_restart_me

        result = c2c_restart_me._uuid_from_cmdline(["claude", "--some-flag"])
        self.assertIsNone(result)

    def test_uuid_from_cmdline_returns_none_for_non_uuid(self):
        import c2c_restart_me

        result = c2c_restart_me._uuid_from_cmdline(["claude", "--resume", "notauuid"])
        self.assertIsNone(result)

    def test_uuid_from_claude_dir_returns_newest_jsonl_stem(self):
        import c2c_restart_me

        with tempfile.TemporaryDirectory() as tmp:
            slug = "home-user-src-repo"
            proj_dir = Path(tmp) / ".claude" / "projects" / slug
            proj_dir.mkdir(parents=True)
            old_file = proj_dir / "old-uuid-1111.jsonl"
            new_file = proj_dir / "new-uuid-2222.jsonl"
            old_file.write_text("[]", encoding="utf-8")
            import time as _time

            _time.sleep(0.01)
            new_file.write_text("[]", encoding="utf-8")

            # Point the function at our temp dir by monkeypatching Path.home()
            with mock.patch("c2c_restart_me.Path.home", return_value=Path(tmp)):
                # Need a fake /proc/<pid>/cwd symlink pointing at our dir
                # Instead call _uuid_from_claude_dir directly with a real pid
                # by patching os.readlink
                cwd = f"/home/user/src/repo"
                with mock.patch("os.readlink", return_value=cwd):
                    result = c2c_restart_me._uuid_from_claude_dir(12345)

            self.assertEqual(result, "new-uuid-2222")

    def test_print_unmanaged_instructions_includes_resume(self):
        import c2c_restart_me
        import io
        from unittest.mock import patch

        with patch("sys.stdout", new_callable=io.StringIO) as mock_out:
            c2c_restart_me.print_unmanaged_instructions("claude-code")
            output = mock_out.getvalue()

        self.assertIn("claude --resume", output)
        self.assertIn("/exit", output)

def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
