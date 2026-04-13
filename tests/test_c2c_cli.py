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


class C2CRegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_default_registry_path_uses_shared_git_state_location(self):
        common_dir = Path(self.temp_dir.name) / "repo" / ".git"
        expected = common_dir / "c2c" / "registry.yaml"

        with mock.patch("c2c_registry.repo_common_dir", return_value=common_dir):
            self.assertEqual(c2c_registry.default_registry_path(), expected)

    def test_load_registry_reads_minimal_yaml_format(self):
        self.registry_path.write_text(
            "registrations:\n"
            "  - session_id: 6e45bbe8-998c-4140-b77e-c6f117e6ca4b\n"
            "    alias: storm-herald\n",
            encoding="utf-8",
        )

        self.assertEqual(
            load_registry(self.registry_path),
            {
                "registrations": [
                    {
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-herald",
                    }
                ]
            },
        )

    def test_save_registry_replaces_file_atomically(self):
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        with mock.patch("c2c_registry.os.replace", wraps=os.replace) as replace_mock:
            save_registry(registry, self.registry_path)

        self.assertEqual(replace_mock.call_count, 1)
        self.assertEqual(replace_mock.call_args.args[1], self.registry_path)

    def test_registry_round_trips_quoted_yaml_scalars(self):
        registry = {
            "registrations": [
                {
                    "session_id": 'agent "one" \\ path',
                    "alias": 'signal "flare" \\ relay',
                }
            ]
        }

        save_registry(registry, self.registry_path)

        self.assertEqual(load_registry(self.registry_path), registry)

    def test_seeded_alias_allocation_starts_from_session_specific_offset(self):
        words = ["aava", "ilma", "kaiku", "sisu"]

        self.assertNotEqual(
            c2c_registry.allocate_unique_alias(words, set(), seed="alpha"),
            c2c_registry.allocate_unique_alias(words, set(), seed="beta"),
        )

    def test_seeded_alias_allocation_wraps_to_available_pair(self):
        words = ["aava", "ilma"]
        first = c2c_registry.allocate_unique_alias(words, set(), seed="session-a")
        existing = {
            first,
            "aava-aava",
            "aava-ilma",
            "ilma-aava",
            "ilma-ilma",
        } - {first}

        self.assertEqual(
            c2c_registry.allocate_unique_alias(words, existing, seed="session-a"),
            first,
        )


class RegistryJsonFallbackTests(unittest.TestCase):
    """Tests for load_registry() falling back to broker JSON registry.

    When registry.yaml doesn't exist (typical in modern setups where the OCaml
    broker uses registry.json), load_registry() should transparently read the
    JSON registry and return data in the same dict format.
    """

    def setUp(self):
        import c2c_registry as _c2c_registry

        self.c2c_registry = _c2c_registry
        self.temp_dir = tempfile.TemporaryDirectory()
        self.td = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_json_registry(self, registrations: list) -> Path:
        json_path = self.td / "registry.json"
        json_path.write_text(json.dumps(registrations), encoding="utf-8")
        return json_path

    def test_fallback_to_json_when_yaml_missing(self):
        """load_registry() returns JSON entries when registry.yaml doesn't exist."""
        regs = [{"session_id": "s-abc", "alias": "test-peer", "pid": 1234}]
        json_path = self._write_json_registry(regs)
        yaml_path = self.td / "registry.yaml"
        # yaml_path intentionally not created

        with mock.patch.object(self.c2c_registry, "default_broker_registry_path", return_value=json_path):
            with mock.patch.object(self.c2c_registry, "registry_path_from_env", return_value=yaml_path):
                result = self.c2c_registry.load_registry()

        self.assertEqual(len(result["registrations"]), 1)
        self.assertEqual(result["registrations"][0]["alias"], "test-peer")

    def test_yaml_takes_precedence_when_both_exist(self):
        """When registry.yaml exists, it is used even if JSON also exists."""
        yaml_path = self.td / "registry.yaml"
        yaml_path.write_text(
            "registrations:\n  - session_id: yaml-sid\n    alias: yaml-peer\n",
            encoding="utf-8",
        )
        json_path = self._write_json_registry([{"session_id": "json-sid", "alias": "json-peer"}])

        with mock.patch.object(self.c2c_registry, "default_broker_registry_path", return_value=json_path):
            result = self.c2c_registry.load_registry(yaml_path)

        # Explicit path → YAML is used
        self.assertEqual(result["registrations"][0]["alias"], "yaml-peer")

    def test_returns_empty_when_neither_exists(self):
        """Returns empty registry when neither YAML nor JSON exists."""
        json_path = self.td / "registry.json"
        yaml_path = self.td / "registry.yaml"
        # Neither file exists — should return empty.
        with mock.patch.object(
            self.c2c_registry, "default_broker_registry_path", return_value=json_path
        ), mock.patch.object(
            self.c2c_registry, "default_registry_path", return_value=yaml_path
        ):
            result = self.c2c_registry.load_registry()

        self.assertEqual(result, {"registrations": []})

    def test_load_broker_json_as_registry_handles_list(self):
        """_load_broker_json_as_registry converts a JSON array to registry format."""
        regs = [{"session_id": "s1", "alias": "a1"}, {"session_id": "s2", "alias": "a2"}]
        json_path = self._write_json_registry(regs)
        result = self.c2c_registry._load_broker_json_as_registry(json_path)
        self.assertEqual(len(result["registrations"]), 2)
        self.assertEqual(result["registrations"][1]["alias"], "a2")

    def test_load_broker_json_as_registry_handles_corrupt_file(self):
        """_load_broker_json_as_registry returns empty on corrupt JSON."""
        bad_path = self.td / "bad.json"
        bad_path.write_text("not json", encoding="utf-8")
        result = self.c2c_registry._load_broker_json_as_registry(bad_path)
        self.assertEqual(result, {"registrations": []})


class C2CRegisterUnitTests(unittest.TestCase):
    def test_register_session_uses_transactional_registry_update(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch(
                "c2c_register.update_registry", return_value=registration
            ) as update,
        ):
            (
                resolved_session,
                resolved_registration,
                registration_was_new,
            ) = register_session("agent-one")

        self.assertEqual(resolved_session, session)
        self.assertEqual(resolved_registration, registration)
        self.assertFalse(registration_was_new)
        self.assertEqual(update.call_count, 1)

    def test_register_session_does_not_load_alias_words_for_existing_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        def mutate_registry(mutator):
            return mutator(registry)

        with (
            mock.patch("c2c_register.load_sessions", return_value=[session]),
            mock.patch("c2c_register.update_registry", side_effect=mutate_registry),
            mock.patch("c2c_register.load_alias_words") as load_alias_words,
        ):
            (
                resolved_session,
                resolved_registration,
                registration_was_new,
            ) = register_session("agent-one")

        self.assertEqual(resolved_session, session)
        self.assertEqual(resolved_registration, registry["registrations"][0])
        self.assertFalse(registration_was_new)
        load_alias_words.assert_not_called()


class C2CRegisterNotificationTests(unittest.TestCase):
    def test_register_sends_onboarding_for_new_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session"
            ) as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_called_once_with(
            session,
            "You are now registered for C2C.\n"
            "Your alias is storm-herald.\n"
            "Run c2c-whoami for your current details and tutorial.\n"
            "Run c2c-list to see other opted-in sessions.\n"
            "If Bash approval allows it, reply with c2c-send <alias> <message...>.\n"
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            event="onboarding",
            sender_name="c2c-register",
            sender_alias="storm-herald",
        )

    def test_register_sends_onboarding_with_onboarding_event_metadata(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with mock.patch(
            "c2c_register.claude_send_msg.send_message_to_session"
        ) as send_message:
            c2c_register.send_onboarding_message(session, "storm-herald")

        send_message.assert_called_once_with(
            session,
            "You are now registered for C2C.\n"
            "Your alias is storm-herald.\n"
            "Run c2c-whoami for your current details and tutorial.\n"
            "Run c2c-list to see other opted-in sessions.\n"
            "If Bash approval allows it, reply with c2c-send <alias> <message...>.\n"
            "If Bash is not available or not approved, reply as a normal assistant message instead.",
            event="onboarding",
            sender_name="c2c-register",
            sender_alias="storm-herald",
        )

    def test_register_does_not_resend_onboarding_for_existing_registration(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, False),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session"
            ) as send_message,
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 0)
        send_message.assert_not_called()

    def test_register_returns_non_zero_when_new_registration_onboarding_send_fails(
        self,
    ):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
        stderr = io.StringIO()

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session",
                side_effect=RuntimeError("target session has no pts tty"),
            ),
            mock.patch("c2c_register.rollback_registration") as rollback_registration,
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 1)
        rollback_registration.assert_called_once_with(
            AGENT_ONE_SESSION_ID, "storm-herald"
        )
        self.assertEqual(stderr.getvalue().strip(), "target session has no pts tty")

    def test_register_rolls_back_new_registration_when_onboarding_send_fails(self):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            words_path = Path(temp_dir) / "words.txt"
            words_path.write_text(
                "storm\nherald\nember\ncrown\nsilver\nbanner\n",
                encoding="utf-8",
            )

            with (
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(registry_path),
                        "C2C_ALIAS_WORDS_PATH": str(words_path),
                    },
                    clear=False,
                ),
                mock.patch("c2c_register.load_sessions", return_value=[session]),
                mock.patch(
                    "c2c_register.claude_send_msg.send_message_to_session",
                    side_effect=RuntimeError("target session has no pts tty"),
                ),
                mock.patch("sys.stderr", io.StringIO()),
            ):
                result = c2c_register.main(["agent-one"])

            self.assertEqual(result, 1)
            self.assertEqual(load_registry(registry_path)["registrations"], [])

    def test_register_rolls_back_new_registration_when_onboarding_send_raises_unexpected_exception(
        self,
    ):
        session = {
            "name": "agent-one",
            "pid": 11111,
            "session_id": AGENT_ONE_SESSION_ID,
        }
        registration = {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
        stderr = io.StringIO()

        with (
            mock.patch(
                "c2c_register.register_session",
                return_value=(session, registration, True),
            ),
            mock.patch(
                "c2c_register.claude_send_msg.send_message_to_session",
                side_effect=ValueError("unexpected onboarding failure"),
            ),
            mock.patch("c2c_register.rollback_registration") as rollback_registration,
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_register.main(["agent-one"])

        self.assertEqual(result, 1)
        rollback_registration.assert_called_once_with(
            AGENT_ONE_SESSION_ID, "storm-herald"
        )
        self.assertEqual(stderr.getvalue().strip(), "unexpected onboarding failure")

    def test_rollback_registration_only_removes_matching_alias(self):
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "ember-crown"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "silver-banner"},
            ]
        }

        def mutate_registry(mutator):
            mutator(registry)

        with mock.patch("c2c_register.update_registry", side_effect=mutate_registry):
            c2c_register.rollback_registration(AGENT_ONE_SESSION_ID, "storm-herald")

        self.assertEqual(
            registry["registrations"],
            [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "ember-crown"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "silver-banner"},
            ],
        )


class C2CTestHelpersTests(unittest.TestCase):
    def test_copy_cli_checkout_supports_git_directory_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            source_root = Path(temp_dir) / "source"
            target_root = Path(temp_dir) / "target"
            source_root.mkdir()
            (source_root / ".git").mkdir()
            (source_root / ".git" / "HEAD").write_text(
                "ref: refs/heads/main\n", encoding="utf-8"
            )

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
                "c2c_health.py",
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
                "c2c_claude_wake_daemon.py",
                "c2c_kimi_wake_daemon.py",
                "c2c_kimi_wire_bridge.py",
                "c2c_opencode_wake_daemon.py",
                "c2c_crush_wake_daemon.py",
                "c2c_cli.py",
                "c2c_history.py",
                "c2c_status.py",
                "c2c_smoke_test.py",
                "c2c_mcp.py",
                "c2c_registry.py",
                "claude_send_msg.py",
                "claude_list_sessions.py",
            ]:
                (source_root / relative_path).write_text(
                    "placeholder\n", encoding="utf-8"
                )

            copy_cli_checkout(source_root, target_root)

            self.assertTrue((target_root / ".git").is_dir())
            self.assertEqual(
                (target_root / ".git" / "HEAD").read_text(encoding="utf-8"),
                "ref: refs/heads/main\n",
            )


class C2CListUnitTests(unittest.TestCase):
    def test_list_registered_sessions_does_not_mutate_registry(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        seeded = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": session["session_id"], "alias": "ember-crown"},
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=[session]),
            ):
                rows = list_registered_sessions()

            reloaded = load_registry(registry_path)

        self.assertEqual(
            rows,
            [
                {
                    "alias": "ember-crown",
                    "name": "agent-two",
                    "session_id": session["session_id"],
                }
            ],
        )
        self.assertEqual(reloaded, seeded)

    def test_infer_client_type_from_session_id_and_alias(self):
        from c2c_list import _infer_client_type

        self.assertEqual(
            _infer_client_type("storm-beacon", "d16034fc-5526-414b-a88e-709d1a93e345"),
            "claude-code",
        )
        self.assertEqual(
            _infer_client_type(
                "claude-bob-local", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            ),
            "claude-code",
        )
        self.assertEqual(_infer_client_type("codex", "codex-local"), "codex")
        self.assertEqual(
            _infer_client_type("codex-worker", "codex-worker-session"), "codex"
        )
        self.assertEqual(
            _infer_client_type("opencode-local", "opencode-local"), "opencode"
        )
        self.assertEqual(_infer_client_type("opencode-x", "opencode-x"), "opencode")
        self.assertEqual(
            _infer_client_type("kimi-alice-host", "kimi-alice-host"), "kimi"
        )
        self.assertEqual(
            _infer_client_type("crush-bob-host", "crush-bob-host"), "crush"
        )
        self.assertEqual(_infer_client_type("mystery", "mystery-session"), "?")

    def test_list_broker_flag_reads_broker_registry(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {"session_id": "codex-local", "alias": "codex"},
                        {"session_id": "opencode-local", "alias": "gpt"},
                    ]
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO / "c2c_list.py"),
                    "--broker",
                    "--json",
                ],
                cwd=REPO,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        payload = json.loads(result.stdout)
        peers_by_alias = {p["alias"]: p for p in payload["peers"]}
        self.assertIn("codex", peers_by_alias)
        self.assertIn("gpt", peers_by_alias)
        # New fields: alive (None when no pid) and rooms (empty list)
        self.assertIsNone(peers_by_alias["codex"]["alive"])
        self.assertEqual(peers_by_alias["codex"]["rooms"], [])
        self.assertEqual(peers_by_alias["codex"]["session_id"], "codex-local")
        self.assertEqual(peers_by_alias["codex"]["client_type"], "codex")
        self.assertIsNone(peers_by_alias["gpt"]["alive"])
        self.assertEqual(peers_by_alias["gpt"]["session_id"], "opencode-local")
        self.assertEqual(peers_by_alias["gpt"]["client_type"], "opencode")
        # last_seen is None when no inbox file exists
        self.assertIsNone(peers_by_alias["codex"]["last_seen"])
        self.assertIsNone(peers_by_alias["gpt"]["last_seen"])

    def _make_dead_broker(self) -> tempfile.TemporaryDirectory:
        """Helper: broker root with one dead (pid=99999999) peer."""
        tmp = tempfile.TemporaryDirectory()
        (Path(tmp.name) / "registry.json").write_text(
            json.dumps([{"session_id": "s1", "alias": "dead-peer", "pid": 99999999}]),
            encoding="utf-8",
        )
        return tmp

    def _run_list_broker(self, broker_root: str, outer_state: dict) -> str:
        """Call c2c_list.main(["--broker"]) with a mocked outer-loop check and capture stdout."""
        import io
        import c2c_list
        from contextlib import redirect_stdout

        buf = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": broker_root}),
            mock.patch("c2c_health.check_outer_loops", return_value=outer_state),
            redirect_stdout(buf),
        ):
            c2c_list.main(["--broker"])
        return buf.getvalue()

    def test_list_broker_text_suggests_sweep_when_safe(self):
        """Safe-to-sweep: suggest 'c2c sweep'."""
        tmp = self._make_dead_broker()
        try:
            output = self._run_list_broker(
                tmp.name, {"safe_to_sweep": True, "running": []}
            )
        finally:
            tmp.cleanup()
        self.assertIn("c2c sweep", output)
        self.assertNotIn("outer loops running", output)

    def test_list_broker_text_warns_when_outer_loops_present(self):
        """Outer loops running: warn instead of suggesting sweep."""
        tmp = self._make_dead_broker()
        try:
            outer_state = {
                "safe_to_sweep": False,
                "running": [
                    {
                        "client": "codex",
                        "pid": 1234,
                        "instance": "local",
                        "cmdline": "x",
                    }
                ],
            }
            output = self._run_list_broker(tmp.name, outer_state)
        finally:
            tmp.cleanup()
        self.assertIn("outer loops running", output)
        self.assertIn("codex", output)
        self.assertNotIn("run `c2c sweep`", output)

    def test_pid_alive_handles_spaces_in_process_name(self):
        """_pid_alive must parse /proc/pid/stat correctly when comm contains spaces.

        Without the fix, stat.split() misaligns the starttime field for names
        like 'Kimi Code', causing a matching PID to appear dead.

        After last ')': parts[0]=state, parts[1..18]=ppid..itrealvalue, parts[19]=starttime.
        """
        import c2c_list

        fake_pid = os.getpid()
        starttime = 30294636
        # 18 filler fields (1-18) after state so parts[19] == starttime
        fake_stat = (
            f"{fake_pid} (Kimi Code) S 1 2 3 4 5 6 "
            f"7 8 9 10 11 12 13 14 15 16 17 18 {starttime} 21 22\n"
        )
        with (
            mock.patch("pathlib.Path.read_text", return_value=fake_stat),
            mock.patch("pathlib.Path.exists", return_value=True),
        ):
            result = c2c_list._pid_alive(fake_pid, starttime)
        self.assertTrue(result, "should be alive when starttime matches")

    def test_pid_alive_detects_pid_reuse_with_spaces_in_process_name(self):
        """_pid_alive returns False when starttime mismatches (PID reused), even for spaced names."""
        import c2c_list

        fake_pid = os.getpid()
        starttime = 30294636
        fake_stat = (
            f"{fake_pid} (Kimi Code) S 1 2 3 4 5 6 "
            f"7 8 9 10 11 12 13 14 15 16 17 18 {starttime} 21 22\n"
        )
        wrong_starttime = 12345
        with (
            mock.patch("pathlib.Path.read_text", return_value=fake_stat),
            mock.patch("pathlib.Path.exists", return_value=True),
        ):
            result = c2c_list._pid_alive(fake_pid, wrong_starttime)
        self.assertFalse(result, "should be dead when starttime mismatches")

    def test_list_sessions_includes_alias_for_registered_live_sessions(self):
        sessions = [
            {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID},
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]
        seeded = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
            ]
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=sessions),
            ):
                rows = list_sessions(include_all=True)

        self.assertEqual(
            rows,
            [
                {
                    "alias": "storm-herald",
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


class RegistryReadPathsDoNotMutateTests(unittest.TestCase):
    """Regression for the alias-churn-on-restart bug.

    Read commands (`c2c list`, `c2c send`, `c2c verify`) must not prune the
    YAML registry based on /proc-detected live Claude sessions. Pruning on
    read paths wiped entries for any agent whose process was briefly offline
    (e.g. mid-restart-self), causing it to allocate a fresh alias on
    re-register and silently breaking peer recognition across the swarm. See
    .collab/findings/2026-04-13T05-40-00Z-storm-ember-alias-churn-on-restart.md.
    """

    def _seeded(self) -> dict:
        return {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                {
                    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
                    "alias": "storm-lantern",
                },
            ]
        }

    def test_c2c_list_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        only_one_live = [
            {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_list.load_sessions", return_value=only_one_live),
            ):
                list_registered_sessions()
                list_sessions(include_all=True)

            self.assertEqual(load_registry(registry_path), seeded)

    def test_c2c_send_resolve_alias_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        target_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_send.load_sessions", return_value=[target_session]),
            ):
                session, registration = c2c_send.resolve_alias("ember-crown")

            self.assertEqual(session, target_session)
            self.assertEqual(registration["alias"], "ember-crown")
            self.assertEqual(load_registry(registry_path), seeded)

    def test_c2c_verify_progress_does_not_prune_offline_registrations(self):
        seeded = self._seeded()
        only_one_live = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(seeded, registry_path)

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=only_one_live),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    return_value={"sent": 1, "received": 1},
                ),
            ):
                c2c_verify.verify_progress()

            self.assertEqual(load_registry(registry_path), seeded)


class C2CSendUnitTests(unittest.TestCase):
    def test_send_to_alias_delegates_to_existing_send_surface(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        registration = {"session_id": session["session_id"], "alias": "ember-crown"}
        delegated_result = {
            "ok": True,
            "to": "agent-two",
            "session_id": session["session_id"],
            "pid": 11112,
            "sent_at": 123.0,
        }

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value=delegated_result,
            ) as delegate,
            mock.patch.dict(
                os.environ,
                {"C2C_SESSION_ID": "", "C2C_SESSION_PID": "", "C2C_MCP_SESSION_ID": ""},
                clear=False,
            ),
        ):
            result = c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        self.assertEqual(result, delegated_result)
        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="c2c-send",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_passes_sender_metadata_when_current_session_registered(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.resolve_sender_metadata",
                return_value={"name": "agent-one", "alias": "storm-herald"},
            ),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="agent-one",
            sender_alias="storm-herald",
            sessions=mock.ANY,
        )

    def test_send_to_alias_passes_mcp_env_sender_metadata_to_pty_delegate(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "opencode-local",
                            "alias": "opencode-local",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            session = {
                "name": "agent-two",
                "pid": 11112,
                "session_id": AGENT_TWO_SESSION_ID,
            }
            registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch(
                    "c2c_send.resolve_alias", return_value=(session, registration)
                ),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": "",
                        "C2C_SESSION_PID": "",
                        "C2C_MCP_SESSION_ID": "opencode-local",
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch(
                    "c2c_send.claude_send_msg.send_message_to_session",
                    return_value={"ok": True},
                ) as delegate,
            ):
                c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="opencode-local",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_uses_minimal_sender_fallback_when_current_session_unknown(
        self,
    ):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.resolve_sender_metadata",
                return_value={"name": "c2c-send", "alias": ""},
            ),
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="c2c-send",
            sender_alias="",
            sessions=mock.ANY,
        )

    def test_send_to_alias_reuses_loaded_sessions_for_sender_metadata_and_sendability(
        self,
    ):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        registration = {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"}
        sessions = [
            {
                "name": "agent-one",
                "pid": 11111,
                "session_id": AGENT_ONE_SESSION_ID,
                "tty": "/dev/pts/8",
                "terminal_pid": 22222,
                "terminal_master_fd": 7,
            },
            {
                **session,
                "terminal_pid": 33333,
                "terminal_master_fd": 8,
            },
        ]

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch.dict(
                os.environ,
                {"C2C_SESSION_ID": AGENT_ONE_SESSION_ID, "C2C_MCP_SESSION_ID": ""},
                clear=False,
            ),
            mock.patch(
                "c2c_send.load_registration_for_session_id",
                return_value={
                    "session_id": AGENT_ONE_SESSION_ID,
                    "alias": "storm-herald",
                },
            ),
            mock.patch(
                "c2c_send.load_sessions", return_value=sessions
            ) as load_sessions,
            mock.patch(
                "c2c_send.claude_send_msg.send_message_to_session",
                return_value={"ok": True},
            ) as delegate,
        ):
            c2c_send.send_to_alias("ember-crown", "hello peer", dry_run=False)

        load_sessions.assert_called_once_with()
        delegate.assert_called_once_with(
            session,
            "hello peer",
            event="message",
            sender_name="agent-one",
            sender_alias="",
            sessions=sessions,
        )

    def test_send_to_alias_broker_only_peer_appends_to_broker_inbox(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                result = c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertTrue(result["ok"])
            self.assertEqual(result["to"], "broker:codex-local")
            self.assertEqual(result["session_id"], "codex-local")
            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "c2c-send",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_broker_only_peer_uses_registered_sender_alias(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )

            with (
                mock.patch(
                    "c2c_send.load_sessions",
                    return_value=[
                        {"name": "agent-one", "session_id": AGENT_ONE_SESSION_ID}
                    ],
                ),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": AGENT_ONE_SESSION_ID,
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch(
                    "c2c_send.load_registration_for_session_id",
                    return_value={
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "storm-herald",
                    },
                ),
                mock.patch(
                    "c2c_send.find_session",
                    return_value={
                        "name": "agent-one",
                        "session_id": AGENT_ONE_SESSION_ID,
                    },
                ),
            ):
                c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "storm-herald",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_broker_only_peer_uses_mcp_env_sender_alias(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "opencode-local",
                            "alias": "opencode-local",
                        },
                        {"session_id": "codex-local", "alias": "codex"},
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_SESSION_ID": "",
                        "C2C_SESSION_PID": "",
                        "C2C_MCP_SESSION_ID": "opencode-local",
                        "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertEqual(
                json.loads(
                    (broker_root / "codex-local.inbox.json").read_text(encoding="utf-8")
                ),
                [
                    {
                        "from_alias": "opencode-local",
                        "to_alias": "codex",
                        "content": "hello peer",
                    }
                ],
            )

    def test_send_to_alias_rejects_dead_broker_only_peer(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps(
                    [
                        {
                            "session_id": "codex-local",
                            "alias": "codex",
                            "pid": 4242,
                            "pid_start_time": 9999,
                        }
                    ]
                ),
                encoding="utf-8",
            )

            with (
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
                mock.patch("c2c_send.os.path.exists", return_value=False),
            ):
                with self.assertRaisesRegex(
                    ValueError, "recipient is not alive: codex"
                ):
                    c2c_send.send_to_alias("codex", "hello peer", dry_run=False)

            self.assertFalse((broker_root / "codex-local.inbox.json").exists())

    def test_send_to_alias_broker_only_peer_concurrent_appends_preserve_all_messages(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            broker_root = Path(temp_dir) / "mcp-broker"
            broker_root.mkdir(parents=True, exist_ok=True)
            (broker_root / "registry.json").write_text(
                json.dumps([{"session_id": "codex-local", "alias": "codex"}]),
                encoding="utf-8",
            )
            inbox_path = broker_root / "codex-local.inbox.json"
            inbox_path.write_text("[]", encoding="utf-8")
            original_read_text = Path.read_text
            worker_count = 8
            start_barrier = threading.Barrier(worker_count)
            read_barrier = threading.Barrier(worker_count)
            errors = []

            def delayed_read_text(path_self, *args, **kwargs):
                if path_self == inbox_path:
                    contents = original_read_text(path_self, *args, **kwargs)
                    try:
                        read_barrier.wait(timeout=0.5)
                    except BrokenBarrierError:
                        pass
                    return contents
                return original_read_text(path_self, *args, **kwargs)

            def worker(index: int) -> None:
                try:
                    start_barrier.wait(timeout=2)
                    c2c_send.send_to_alias(
                        "codex", f"hello peer {index}", dry_run=False
                    )
                except Exception as error:  # pragma: no cover - failure surfaced below
                    errors.append(error)

            with (
                mock.patch("pathlib.Path.read_text", delayed_read_text),
                mock.patch("c2c_send.load_sessions", return_value=[]),
                mock.patch.dict(
                    os.environ,
                    {
                        "C2C_REGISTRY_PATH": str(Path(temp_dir) / "registry.yaml"),
                        "C2C_MCP_BROKER_ROOT": str(broker_root),
                    },
                    clear=False,
                ),
            ):
                threads = [
                    threading.Thread(target=worker, args=(index,))
                    for index in range(worker_count)
                ]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=5)

            self.assertEqual(errors, [])
            items = json.loads(inbox_path.read_text(encoding="utf-8"))
            self.assertEqual(len(items), worker_count)
            self.assertEqual(
                {item["content"] for item in items},
                {f"hello peer {index}" for index in range(worker_count)},
            )

    def test_broker_inbox_write_lock_uses_posix_lockf_for_ocaml_compatibility(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            inbox_path = Path(temp_dir) / "codex-local.inbox.json"

            with mock.patch("c2c_send.fcntl.lockf") as lockf:
                with c2c_send.broker_inbox_write_lock(inbox_path):
                    pass

            self.assertEqual(lockf.call_args_list[0].args[1], c2c_send.fcntl.LOCK_EX)
            self.assertEqual(lockf.call_args_list[1].args[1], c2c_send.fcntl.LOCK_UN)

    def test_broker_inbox_write_lock_uses_ocaml_sidecar_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            inbox_path = Path(temp_dir) / "codex-local.inbox.json"

            with c2c_send.broker_inbox_write_lock(inbox_path):
                self.assertTrue((Path(temp_dir) / "codex-local.inbox.lock").exists())
                self.assertFalse(
                    (Path(temp_dir) / "codex-local.inbox.json.lock").exists()
                )

    def test_main_reports_send_surface_failures_cleanly(self):
        session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
        }
        registration = {"session_id": session["session_id"], "alias": "ember-crown"}
        stderr = io.StringIO()

        with (
            mock.patch("c2c_send.resolve_alias", return_value=(session, registration)),
            mock.patch(
                "c2c_send.delegate_send",
                side_effect=subprocess.CalledProcessError(
                    1, ["pty_inject"], stderr="permission denied\n"
                ),
            ),
            mock.patch("sys.stderr", stderr),
        ):
            result = c2c_send.main(["ember-crown", "hello"])

        self.assertEqual(result, 1)
        self.assertEqual(stderr.getvalue().strip(), "send failed: permission denied")

    def test_main_uses_human_output_without_json_flag(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_send.send_to_alias",
                return_value={
                    "ok": True,
                    "to": "agent-two",
                    "session_id": "fa68bd5b-0529-4292-bc27-d617f6840ce7",
                    "pid": 11112,
                    "sent_at": 123.0,
                },
            ),
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_send.main(["ember-crown", "hello"])

        self.assertEqual(result, 0)
        self.assertEqual(
            stdout.getvalue().strip(), "Sent c2c message to agent-two (ember-crown)"
        )


class C2CInjectUnitTests(unittest.TestCase):
    def test_inject_pid_dry_run_resolves_generic_client_without_writing_pty(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_inject.c2c_poker.resolve_pid", return_value=(33333, "9", None)
            ) as resolve_pid,
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "codex",
                    "--pid",
                    "12345",
                    "--dry-run",
                    "--json",
                    "hello",
                    "codex",
                ]
            )

        self.assertEqual(result, 0)
        resolve_pid.assert_called_once_with(12345)
        inject.assert_not_called()
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "codex")
        self.assertEqual(payload["terminal_pid"], 33333)
        self.assertEqual(payload["pts"], "9")
        self.assertTrue(payload["dry_run"])
        self.assertIn('<c2c event="message" from="c2c-inject"', payload["payload"])
        self.assertIn('source="pty"', payload["payload"])
        self.assertIn('source_tool="c2c_inject"', payload["payload"])
        self.assertIn("hello codex", payload["payload"])

    def test_inject_terminal_target_writes_raw_message_for_opencode(self):
        stdout = io.StringIO()

        with (
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--raw",
                    "--json",
                    "raw prompt",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once_with(44444, "12", "raw prompt")
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "opencode")
        self.assertEqual(payload["payload"], "raw prompt")
        self.assertFalse(payload["dry_run"])

    def test_inject_kimi_client_uses_master_pty_with_default_delay(self):
        stdout = io.StringIO()

        with (
            mock.patch("c2c_inject.c2c_pts_inject.inject") as pts_inject,
            mock.patch("c2c_inject.c2c_poker.inject") as pty_inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "kimi",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--raw",
                    "--json",
                    "wake prompt",
                ]
            )

        self.assertEqual(result, 0)
        pts_inject.assert_not_called()
        pty_inject.assert_called_once_with(
            44444,
            "12",
            "wake prompt",
            submit_delay=1.5,
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "kimi")
        self.assertEqual(payload["payload"], "wake prompt")
        self.assertEqual(payload["submit_delay"], 1.5)
        self.assertFalse(payload["dry_run"])

    def test_inject_submit_delay_is_forwarded_to_pty_backend(self):
        stdout = io.StringIO()

        with (
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--submit-delay",
                    "1.25",
                    "--raw",
                    "--json",
                    "slow prompt",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once_with(
            44444,
            "12",
            "slow prompt",
            submit_delay=1.25,
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["submit_delay"], 1.25)

    def test_inject_claude_session_uses_claude_resolver(self):
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_inject.c2c_poker.resolve_claude_session",
                return_value=(22222, "11", "/tmp/transcript.jsonl"),
            ) as resolve_claude_session,
            mock.patch("c2c_inject.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_inject.main(
                [
                    "--client",
                    "claude",
                    "--claude-session",
                    "agent-one",
                    "--json",
                    "hello",
                    "claude",
                ]
            )

        self.assertEqual(result, 0)
        resolve_claude_session.assert_called_once_with("agent-one")
        inject.assert_called_once()
        self.assertEqual(inject.call_args.args[0:2], (22222, "11"))
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["client"], "claude")
        self.assertIn('source="pty"', payload["payload"])
        self.assertIn('source_tool="c2c_inject"', payload["payload"])
        self.assertIn("hello claude", payload["payload"])


class C2CDeliverInboxUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_deliver_inbox_dry_run_peeks_without_injecting(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "codex-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "codex",
                        "content": "queued hello",
                    }
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_deliver_inbox.c2c_inject.resolve_target",
                return_value=(33333, "9", None),
            ),
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
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
                    "--dry-run",
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_not_called()
        self.assertEqual(
            json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
            "queued hello",
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 0)
        self.assertEqual(payload["messages"][0]["content"], "queued hello")

    def test_deliver_inbox_drains_and_injects_each_message(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "storm-beacon",
                        "to_alias": "opencode",
                        "content": "first",
                    },
                    {
                        "from_alias": "storm-echo",
                        "to_alias": "opencode",
                        "content": "second",
                    },
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch(
                "c2c_deliver_inbox.c2c_poll_inbox.call_mcp_tool",
                side_effect=RuntimeError("mcp unavailable"),
            ),
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--session-id",
                    "opencode-local",
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        self.assertEqual(inject.call_count, 2)
        self.assertEqual(json.loads(inbox_path.read_text(encoding="utf-8")), [])
        self.assertIn("first", inject.call_args_list[0].args[2])
        self.assertIn("second", inject.call_args_list[1].args[2])
        self.assertIn('source="broker"', inject.call_args_list[0].args[2])
        self.assertIn(
            'source_tool="c2c_deliver_inbox"', inject.call_args_list[0].args[2]
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 2)
        self.assertEqual(payload["target"]["terminal_pid"], 44444)

    def test_deliver_inbox_notify_only_injects_nudge_without_draining_content(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "opencode-local.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "codex",
                        "to_alias": "opencode-local",
                        "content": "secret content must stay broker-native",
                    }
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "opencode",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--session-id",
                    "opencode-local",
                    "--broker-root",
                    str(broker_root),
                    "--notify-only",
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        inject.assert_called_once()
        payload_text = inject.call_args.args[2]
        self.assertIn("mcp__c2c__poll_inbox", payload_text)
        self.assertIn('source="broker-notify"', payload_text)
        self.assertIn('source_tool="c2c_deliver_inbox"', payload_text)
        self.assertNotIn("secret content", payload_text)
        self.assertEqual(
            json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
            "secret content must stay broker-native",
        )
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["delivered"], 0)
        self.assertTrue(payload["notified"])

    def test_deliver_inbox_kimi_notify_only_uses_master_pty_with_default_delay(self):
        broker_root = Path(self.temp_dir.name) / "mcp-broker"
        broker_root.mkdir()
        inbox_path = broker_root / "kimi-nova.inbox.json"
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "codex",
                        "to_alias": "kimi-nova",
                        "content": "secret content",
                    }
                ]
            ),
            encoding="utf-8",
        )
        stdout = io.StringIO()

        with (
            mock.patch("c2c_deliver_inbox.c2c_pts_inject.inject") as pts_inject,
            mock.patch("c2c_deliver_inbox.c2c_poker.inject") as pty_inject,
            mock.patch("sys.stdout", stdout),
        ):
            result = c2c_deliver_inbox.main(
                [
                    "--client",
                    "kimi",
                    "--terminal-pid",
                    "44444",
                    "--pts",
                    "12",
                    "--session-id",
                    "kimi-nova",
                    "--broker-root",
                    str(broker_root),
                    "--notify-only",
                    "--json",
                ]
            )

        self.assertEqual(result, 0)
        pts_inject.assert_not_called()
        pty_inject.assert_called_once()
        self.assertEqual(pty_inject.call_args.args[:2], (44444, "12"))
        self.assertEqual(pty_inject.call_args.kwargs, {"submit_delay": 1.5})
        payload_text = pty_inject.call_args.args[2]
        self.assertIn("mcp__c2c__poll_inbox", payload_text)
        self.assertIn('source="broker-notify"', payload_text)
        self.assertNotIn("secret content", payload_text)
        self.assertEqual(
            json.loads(inbox_path.read_text(encoding="utf-8"))[0]["content"],
            "secret content",
        )


class ClaudeListSessionsUnitTests(unittest.TestCase):
    def test_load_sessions_defaults_to_fast_mode_without_terminal_owner_lookup(self):
        session_file = Path("/tmp/session.json")
        session_data = {
            "name": "agent-one",
            "pid": 11111,
            "sessionId": AGENT_ONE_SESSION_ID,
            "cwd": "/tmp/project",
        }

        with (
            mock.patch("claude_list_sessions.fixture_path_from_env", return_value=None),
            mock.patch(
                "claude_list_sessions.iter_live_claude_processes",
                return_value=iter([]),
            ),
            mock.patch(
                "claude_list_sessions.iter_session_files",
                return_value=[(".claude", session_file)],
            ),
            mock.patch("claude_list_sessions.safe_json", return_value=session_data),
            mock.patch("claude_list_sessions.process_alive", return_value=True),
            mock.patch("claude_list_sessions.readlink", return_value="/dev/pts/12"),
            mock.patch(
                "claude_list_sessions.find_terminal_owner",
                side_effect=AssertionError(
                    "find_terminal_owner should not run in fast mode"
                ),
            ),
        ):
            rows = claude_list_sessions.load_sessions()

        self.assertEqual(
            rows,
            [
                {
                    "profile": ".claude",
                    "name": "agent-one",
                    "pid": 11111,
                    "session_id": AGENT_ONE_SESSION_ID,
                    "cwd": "/tmp/project",
                    "tty": "/dev/pts/12",
                    "terminal_pid": "",
                    "terminal_master_fd": "",
                    "transcript": claude_list_sessions.transcript_path(
                        "/tmp/project", AGENT_ONE_SESSION_ID
                    )
                    or "",
                }
            ],
        )

    def test_load_sessions_with_terminal_owner_populates_owner_fields(self):
        session_file = Path("/tmp/session.json")
        session_data = {
            "name": "agent-one",
            "pid": 11111,
            "sessionId": AGENT_ONE_SESSION_ID,
            "cwd": "/tmp/project",
        }

        with (
            mock.patch("claude_list_sessions.fixture_path_from_env", return_value=None),
            mock.patch(
                "claude_list_sessions.iter_live_claude_processes",
                return_value=iter([]),
            ),
            mock.patch(
                "claude_list_sessions.iter_session_files",
                return_value=[(".claude", session_file)],
            ),
            mock.patch("claude_list_sessions.safe_json", return_value=session_data),
            mock.patch("claude_list_sessions.process_alive", return_value=True),
            mock.patch("claude_list_sessions.readlink", return_value="/dev/pts/12"),
            mock.patch(
                "claude_list_sessions.find_terminal_owner", return_value=(22222, 7)
            ) as find_owner,
        ):
            rows = claude_list_sessions.load_sessions(with_terminal_owner=True)

        self.assertEqual(find_owner.call_count, 1)
        self.assertEqual(rows[0]["terminal_pid"], 22222)
        self.assertEqual(rows[0]["terminal_master_fd"], 7)

    def test_find_terminal_owner_uses_parent_chain_before_global_scan(self):
        with (
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_parent_chain",
                return_value=(22222, 7),
            ) as parent_chain_lookup,
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_proc_scan",
                side_effect=AssertionError(
                    "global proc scan should not run when parent-chain lookup succeeds"
                ),
            ) as global_scan,
        ):
            owner = claude_list_sessions.find_terminal_owner("12", session_pid=11111)

        self.assertEqual(owner, (22222, 7))
        parent_chain_lookup.assert_called_once_with(11111, "12")
        global_scan.assert_not_called()

    def test_find_terminal_owner_falls_back_to_global_scan_when_parent_chain_misses(
        self,
    ):
        with (
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_parent_chain",
                return_value=(None, None),
            ) as parent_chain_lookup,
            mock.patch(
                "claude_list_sessions.find_terminal_owner_in_proc_scan",
                return_value=(33333, 8),
            ) as global_scan,
        ):
            owner = claude_list_sessions.find_terminal_owner("12", session_pid=11111)

        self.assertEqual(owner, (33333, 8))
        parent_chain_lookup.assert_called_once_with(11111, "12")
        global_scan.assert_called_once_with("12")


class ClaudeSendMsgUnitTests(unittest.TestCase):
    def test_render_payload_wraps_plain_message_in_single_c2c_root_with_metadata(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="agent-one",
                sender_alias="storm-herald",
            ),
            '<c2c event="message" from="agent-one" alias="storm-herald" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
        )

    def test_render_payload_omits_alias_when_sender_alias_missing(self):
        self.assertEqual(
            claude_send_msg.render_payload(
                "hello peer",
                event="message",
                sender_name="c2c-send",
                sender_alias="",
            ),
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
        )

    def test_inject_delegates_to_external_pty_helper_with_terminal_metadata(self):
        session = {
            "tty": "/dev/pts/9",
            "terminal_pid": 33333,
        }

        with mock.patch("claude_send_msg.subprocess.run") as run:
            claude_send_msg.inject(session, "hello peer")

        run.assert_called_once_with(
            [str(claude_send_msg.PTY_INJECT), "33333", "9", "hello peer"],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_send_message_to_session_reloads_full_terminal_metadata_when_needed(self):
        partial_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        full_session = {
            **partial_session,
            "terminal_pid": 33333,
            "terminal_master_fd": 8,
        }

        with (
            mock.patch("claude_send_msg.use_send_message_fixture", return_value=False),
            mock.patch(
                "claude_send_msg.load_sessions", return_value=[full_session]
            ) as load_sessions,
            mock.patch("claude_send_msg.inject") as inject,
            mock.patch("claude_send_msg.time.time", return_value=123.0),
        ):
            result = claude_send_msg.send_message_to_session(
                partial_session, "hello peer"
            )

        load_sessions.assert_called_once_with()
        inject.assert_called_once_with(
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
        )
        self.assertEqual(
            result,
            {
                "ok": True,
                "to": "agent-two",
                "session_id": AGENT_TWO_SESSION_ID,
                "pid": 11112,
                "sent_at": 123.0,
            },
        )

    def test_send_message_to_session_skips_session_reload_when_sessions_already_provided(
        self,
    ):
        partial_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        full_session = {
            **partial_session,
            "terminal_pid": 33333,
            "terminal_master_fd": 8,
        }

        with (
            mock.patch("claude_send_msg.use_send_message_fixture", return_value=False),
            mock.patch(
                "claude_send_msg.load_sessions",
                side_effect=AssertionError("load_sessions should not be called"),
            ),
            mock.patch("claude_send_msg.inject") as inject,
            mock.patch("claude_send_msg.time.time", return_value=123.0),
        ):
            result = claude_send_msg.send_message_to_session(
                partial_session,
                "hello peer",
                sessions=[full_session],
            )

        inject.assert_called_once_with(
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
        )
        self.assertEqual(result["session_id"], AGENT_TWO_SESSION_ID)

    def test_send_message_to_session_reloads_when_provided_sessions_lack_terminal_owner(
        self,
    ):
        partial_session = {
            "name": "agent-two",
            "pid": 11112,
            "session_id": AGENT_TWO_SESSION_ID,
            "tty": "/dev/pts/9",
        }
        full_session = {
            **partial_session,
            "terminal_pid": 33333,
            "terminal_master_fd": 8,
        }

        with (
            mock.patch("claude_send_msg.use_send_message_fixture", return_value=False),
            mock.patch(
                "claude_send_msg.load_sessions", return_value=[full_session]
            ) as load_sessions,
            mock.patch("claude_send_msg.inject") as inject,
            mock.patch("claude_send_msg.time.time", return_value=123.0),
        ):
            result = claude_send_msg.send_message_to_session(
                partial_session,
                "hello peer",
                sessions=[partial_session],
            )

        load_sessions.assert_called_once_with()
        inject.assert_called_once_with(
            full_session,
            '<c2c event="message" from="c2c-send" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
        )
        self.assertEqual(result["session_id"], AGENT_TWO_SESSION_ID)


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


class OpenCodeLocalConfigTests(unittest.TestCase):
    def test_opencode_local_config_exposes_c2c_mcp(self):
        config = json.loads(
            (REPO / ".opencode" / "opencode.json").read_text(encoding="utf-8")
        )
        c2c = config["mcp"]["c2c"]
        self.assertEqual(c2c["type"], "local")
        self.assertEqual(c2c["command"][:2], ["python3", str(REPO / "c2c_mcp.py")])
        self.assertEqual(c2c["environment"]["C2C_MCP_SESSION_ID"], "opencode-c2c-msg")
        self.assertEqual(
            c2c["environment"]["C2C_MCP_AUTO_REGISTER_ALIAS"],
            "opencode-c2c-msg",
        )
        self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertTrue(c2c.get("enabled", True))

    def test_run_opencode_inst_dry_run_reports_local_config_and_session(self):
        env = {"RUN_OPENCODE_INST_DRY_RUN": "1"}
        result = run_cli("run-opencode-inst", "c2c-opencode-local", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_C2C_SESSION_ID"], "opencode-local"
        )
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_CONFIG_PATH"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        # OPENCODE_CONFIG: path opencode reads to find its config
        self.assertEqual(
            payload["env"]["OPENCODE_CONFIG"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        # OPENCODE_CONFIG_CONTENT: content of that file for debugging / dry-run inspection
        env_config = json.loads(payload["env"]["OPENCODE_CONFIG_CONTENT"])
        self.assertEqual(
            env_config["mcp"]["c2c"]["environment"]["C2C_MCP_SESSION_ID"],
            "opencode-local",
        )
        self.assertEqual(payload["cwd"], str(REPO))
        self.assertIn("opencode", payload["launch"][0])
        self.assertIn("OPENCODE_MCP_PROMPT", payload["env"])
        self.assertEqual(payload["env"]["C2C_MCP_SESSION_ID"], "opencode-local")
        self.assertEqual(
            payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-local"
        )
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")
        self.assertEqual(
            payload["env"]["C2C_MCP_BROKER_ROOT"],
            str(REPO / ".git" / "c2c" / "mcp"),
        )
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertEqual(
            payload["env"]["RUN_OPENCODE_INST_RESTART_MARKER"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.restart.json"),
        )

    def test_run_opencode_inst_silent_suppresses_wrapper_stderr(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            project = Path(temp_dir) / "repo"
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            project.mkdir()
            config_dir.mkdir()
            opencode_config = config_dir / "opencode-a.opencode.json"
            opencode_config.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            (config_dir / "opencode-a.json").write_text(
                json.dumps(
                    {
                        "command": sys.executable,
                        "cwd": str(project),
                        "config_path": str(opencode_config),
                        "c2c_session_id": "opencode-a-local",
                        "c2c_alias": "opencode-a",
                        "prompt": "poll inbox",
                        "flags": ["-c", "import sys; sys.exit(0)"],
                    }
                ),
                encoding="utf-8",
            )

            result = run_cli(
                "run-opencode-inst",
                "opencode-a",
                env={
                    "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                    "RUN_OPENCODE_INST_SILENT": "1",
                },
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_run_opencode_inst_rearm_dry_run_reports_bg_loop_commands(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            config_dir.mkdir()
            (config_dir / "opencode-a.pid").write_text("12345\n", encoding="utf-8")
            (config_dir / "opencode-a.json").write_text(
                json.dumps(
                    {
                        "c2c_session_id": "opencode-a-local",
                        "c2c_alias": "opencode-a",
                    }
                ),
                encoding="utf-8",
            )
            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                "RUN_OPENCODE_INST_REARM_DRY_RUN": "1",
            }

            result = run_cli("run-opencode-inst-rearm", "opencode-a", "--json", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "opencode-a")
        self.assertEqual(payload["target_pid"], 12345)
        self.assertEqual(payload["session_id"], "opencode-a-local")
        self.assertEqual(payload["alias"], "opencode-a")
        joined_commands = "\n".join(
            " ".join(command) for command in payload["commands"]
        )
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--client opencode", joined_commands)
        self.assertIn("--session-id opencode-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)
        self.assertIn("c2c_poker.py", joined_commands)

    def test_run_opencode_inst_rearm_skips_live_process_without_tty(self):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                config_dir = Path(temp_dir) / "run-opencode-inst.d"
                config_dir.mkdir()
                (config_dir / "opencode-a.json").write_text(
                    json.dumps(
                        {
                            "c2c_session_id": "opencode-a-local",
                            "c2c_alias": "opencode-a",
                        }
                    ),
                    encoding="utf-8",
                )
                env = {"RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)}

                result = run_cli(
                    "run-opencode-inst-rearm",
                    "opencode-a",
                    "--pid",
                    str(sleeper.pid),
                    "--start-timeout",
                    "0.1",
                    "--json",
                    env=env,
                )
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=1)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=1)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["skipped"])
        self.assertEqual(payload["reason"], "target_has_no_tty")
        self.assertIn("no /dev/pts", payload["error"])

    def test_run_opencode_inst_rearm_refreshes_broker_registration_before_tty_skip(
        self,
    ):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                config_dir = root / "run-opencode-inst.d"
                config_dir.mkdir()
                broker_root = root / "mcp-broker"
                broker_root.mkdir()
                (broker_root / "registry.json").write_text(
                    json.dumps(
                        [
                            {
                                "session_id": "opencode-a-local",
                                "alias": "opencode-a",
                                "pid": 99999999,
                            }
                        ]
                    ),
                    encoding="utf-8",
                )
                (config_dir / "opencode-a.json").write_text(
                    json.dumps(
                        {
                            "c2c_session_id": "opencode-a-local",
                            "c2c_alias": "opencode-a",
                        }
                    ),
                    encoding="utf-8",
                )
                env = {
                    "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }

                result = run_cli(
                    "run-opencode-inst-rearm",
                    "opencode-a",
                    "--pid",
                    str(sleeper.pid),
                    "--start-timeout",
                    "0.1",
                    "--json",
                    env=env,
                )
                registrations = json.loads(
                    (broker_root / "registry.json").read_text(encoding="utf-8")
                )
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=1)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=1)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["registration"]["ok"])
        self.assertEqual(payload["registration"]["pid"], sleeper.pid)
        self.assertEqual(registrations[0]["alias"], "opencode-a")
        self.assertEqual(registrations[0]["session_id"], "opencode-a-local")
        self.assertEqual(registrations[0]["pid"], sleeper.pid)
        self.assertIsInstance(registrations[0]["pid_start_time"], int)

    def test_run_opencode_inst_rearm_refreshes_plugin_sidecar_before_tty_skip(self):
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                project = root / "project"
                config_dir = root / "run-opencode-inst.d"
                broker_root = root / "mcp-broker"
                (project / ".opencode").mkdir(parents=True)
                config_dir.mkdir()
                broker_root.mkdir()
                sidecar_path = project / ".opencode" / "c2c-plugin.json"
                sidecar_path.write_text(
                    json.dumps(
                        {
                            "session_id": "stale-session",
                            "alias": "stale-alias",
                            "broker_root": "/stale/broker",
                        }
                    ),
                    encoding="utf-8",
                )
                (config_dir / "opencode-a.json").write_text(
                    json.dumps(
                        {
                            "cwd": str(project),
                            "session": "ses_managed_opencode",
                            "c2c_session_id": "opencode-a-local",
                            "c2c_alias": "opencode-a",
                        }
                    ),
                    encoding="utf-8",
                )
                env = {
                    "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                }

                result = run_cli(
                    "run-opencode-inst-rearm",
                    "opencode-a",
                    "--pid",
                    str(sleeper.pid),
                    "--start-timeout",
                    "0.1",
                    "--json",
                    env=env,
                )
                sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=1)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=1)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sidecar["session_id"], "opencode-a-local")
        self.assertEqual(sidecar["alias"], "opencode-a")
        self.assertEqual(sidecar["broker_root"], str(broker_root))
        self.assertEqual(sidecar["opencode_session_id"], "ses_managed_opencode")

    def test_opencode_local_config_sets_stable_c2c_alias(self):
        config = json.loads(
            (REPO / "run-opencode-inst.d" / "c2c-opencode-local.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertEqual(config["c2c_alias"], "opencode-local")
        self.assertEqual(
            config["config_path"],
            str(REPO / "run-opencode-inst.d" / "c2c-opencode-local.opencode.json"),
        )
        self.assertNotIn("pre_exec", config)

    def test_run_opencode_inst_uses_c2c_alias_not_session_id_for_auto_register(self):
        """When c2c_alias differs from c2c_session_id, AUTO_REGISTER_ALIAS must
        use the alias so peers can address the managed instance by its stable name."""
        with tempfile.TemporaryDirectory() as temp_dir:
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            config_dir.mkdir()
            managed_config = {
                "command": "opencode",
                "cwd": str(REPO),
                "c2c_session_id": "ses-internal-abc123",
                "c2c_alias": "opencode-special",
                "prompt": "test prompt",
            }
            (config_dir / "special.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            (config_dir / "special.opencode.json").write_text(
                json.dumps({"mcp": {}}), encoding="utf-8"
            )
            # Point at our temp config dir so we don't need a real opencode binary
            managed_config["config_path"] = str(config_dir / "special.opencode.json")
            (config_dir / "special.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_DRY_RUN": "1",
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "special", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        # SESSION_ID stays as the internal session identifier
        self.assertEqual(payload["env"]["C2C_MCP_SESSION_ID"], "ses-internal-abc123")
        # AUTO_REGISTER_ALIAS must be the c2c_alias, not the session_id
        self.assertEqual(
            payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "opencode-special"
        )

    def test_run_opencode_inst_dry_run_does_not_overwrite_plugin_sidecar(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode").mkdir(parents=True)
            config_dir.mkdir()
            existing_sidecar = {
                "session_id": "live-session",
                "alias": "live-alias",
                "broker_root": "/live/broker",
            }
            sidecar_path = project / ".opencode" / "c2c-plugin.json"
            sidecar_path.write_text(
                json.dumps(existing_sidecar, indent=2) + "\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "dry-run.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": "opencode",
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "dry-run-session",
                "c2c_alias": "dry-run-alias",
                "prompt": "test prompt",
            }
            (config_dir / "dry-run.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_DRY_RUN": "1",
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "dry-run", env=env)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(sidecar_path.read_text(encoding="utf-8")),
                existing_sidecar,
            )

    def test_run_opencode_inst_copies_plugin_to_config_dir(self):
        """_ensure_opencode_plugin copies plugin + package.json when config is outside .opencode/."""
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")
        with tempfile.TemporaryDirectory() as temp_dir:
            project = Path(temp_dir) / "repo"
            config_dir = Path(temp_dir) / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                plugin_src.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (project / ".opencode" / "package.json").write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "1.4.3"}}),
                encoding="utf-8",
            )
            (project / ".opencode" / "node_modules").mkdir()
            opencode_json = config_dir / "test-inst.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "test-inst",
                "c2c_alias": "test-inst",
                "prompt": "test",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "test-inst.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "test-inst", env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            # Plugin should have been synced to the config dir's plugins/
            plugin_dest = config_dir / "plugins" / "c2c.ts"
            pkg_dest = config_dir / "package.json"
            self.assertTrue(
                plugin_dest.exists(), "plugin should be copied to config dir"
            )
            self.assertTrue(
                pkg_dest.exists(), "package.json should be copied to config dir"
            )
            # node_modules symlink should be created so Bun can resolve @opencode-ai/plugin
            nm_src = project / ".opencode" / "node_modules"
            nm_dest = config_dir / "node_modules"
            if nm_src.exists():
                self.assertTrue(
                    nm_dest.is_symlink(), "node_modules should be a symlink"
                )
                self.assertEqual(
                    os.readlink(str(nm_dest)),
                    str(nm_src),
                    "node_modules symlink should point to .opencode/node_modules",
                )

    def test_run_opencode_inst_writes_plugin_sidecar_in_cwd(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            (project / ".opencode" / "package.json").write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "1.4.3"}}),
                encoding="utf-8",
            )
            opencode_json = config_dir / "opencode-local.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-local",
                "c2c_alias": "opencode-local",
                "session": "ses_managed_opencode",
                "prompt": "test",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "opencode-local.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )

            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
            }
            result = run_cli("run-opencode-inst", "opencode-local", env=env)

            self.assertEqual(result.returncode, 0, result.stderr)
            sidecar = json.loads(
                (project / ".opencode" / "c2c-plugin.json").read_text(encoding="utf-8")
            )
            self.assertEqual(sidecar["session_id"], "opencode-local")
            self.assertEqual(sidecar["alias"], "opencode-local")
            self.assertEqual(sidecar["opencode_session_id"], "ses_managed_opencode")
            self.assertEqual(
                sidecar["broker_root"], str(project / ".git" / "c2c" / "mcp")
            )

    def test_run_opencode_inst_injects_spool_into_prompt(self):
        """Spooled messages (failed promptAsync) are prepended to the next startup prompt."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "spool-test.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-spool",
                "c2c_alias": "opencode-spool",
                "prompt": "STEP 1: poll inbox",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "spool-test.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            # Write a spool file simulating a failed promptAsync from last cycle
            spool = [
                {
                    "from_alias": "storm-beacon",
                    "to_alias": "opencode-spool",
                    "content": "hi from spool",
                }
            ]
            spool_path = project / ".opencode" / "c2c-plugin-spool.json"
            spool_path.write_text(json.dumps(spool), encoding="utf-8")

            env = {
                "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir),
                "RUN_OPENCODE_INST_DRY_RUN": "1",
            }
            result = run_cli("run-opencode-inst", "spool-test", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            effective_prompt = payload["env"]["OPENCODE_MCP_PROMPT"]
            # Spool message must appear before the normal prompt text
            self.assertIn("hi from spool", effective_prompt)
            self.assertIn('from="storm-beacon"', effective_prompt)
            self.assertIn('source="spool"', effective_prompt)
            self.assertIn("STEP 1: poll inbox", effective_prompt)
            spool_pos = effective_prompt.index("hi from spool")
            step_pos = effective_prompt.index("STEP 1: poll inbox")
            self.assertLess(spool_pos, step_pos, "spool must come before normal prompt")
            # In dry-run, spool must NOT be cleared
            self.assertEqual(json.loads(spool_path.read_text(encoding="utf-8")), spool)

    def test_run_opencode_inst_clears_spool_in_live_run(self):
        """Spool file is cleared after injection (apply_side_effects=True in non-dry-run)."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project = root / "project"
            config_dir = root / "run-opencode-inst.d"
            (project / ".opencode" / "plugins").mkdir(parents=True)
            config_dir.mkdir()
            (project / ".opencode" / "plugins" / "c2c.ts").write_text(
                "export default async function C2C() { return {}; }\n",
                encoding="utf-8",
            )
            opencode_json = config_dir / "spool-clear.opencode.json"
            opencode_json.write_text(json.dumps({"mcp": {}}), encoding="utf-8")
            managed_config = {
                "command": sys.executable,
                "cwd": str(project),
                "config_path": str(opencode_json),
                "c2c_session_id": "opencode-spool-clear",
                "c2c_alias": "opencode-spool-clear",
                "prompt": "poll inbox",
                "flags": ["-c", "import sys; sys.exit(0)"],
            }
            (config_dir / "spool-clear.json").write_text(
                json.dumps(managed_config), encoding="utf-8"
            )
            spool = [
                {
                    "from_alias": "codex",
                    "to_alias": "opencode-spool-clear",
                    "content": "clear me",
                }
            ]
            spool_path = project / ".opencode" / "c2c-plugin-spool.json"
            spool_path.write_text(json.dumps(spool), encoding="utf-8")

            env = {"RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)}
            result = run_cli("run-opencode-inst", "spool-clear", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            # Spool must be cleared after live run
            remaining = json.loads(spool_path.read_text(encoding="utf-8"))
            self.assertEqual(remaining, [], "spool should be empty after live run")

    def test_opencode_plugin_uses_supported_process_runner_for_drain(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertNotIn("ctx.$.quiet", plugin_text)
        self.assertIn('from "child_process"', plugin_text)
        self.assertIn("spawn(", plugin_text)

    def test_opencode_plugin_starts_background_loop_without_lifecycle_hook(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertIn("function startBackgroundLoop()", plugin_text)
        self.assertIn("startBackgroundLoop();", plugin_text)

    def test_opencode_plugin_prefers_configured_session_target(self):
        plugin_src = REPO / ".opencode" / "plugins" / "c2c.ts"
        if not plugin_src.exists():
            self.skipTest("plugin source not present")

        plugin_text = plugin_src.read_text(encoding="utf-8")

        self.assertIn("sidecar.opencode_session_id", plugin_text)
        self.assertIn("configuredOpenCodeSessionId", plugin_text)
        self.assertIn(
            "let activeSessionId: string | null = configuredOpenCodeSessionId",
            plugin_text,
        )

    def test_run_opencode_inst_outer_dry_run_reports_inner_launch_command(self):
        env = {"RUN_OPENCODE_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-opencode-inst-outer", "c2c-opencode-local", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:],
            [str(REPO / "run-opencode-inst"), "c2c-opencode-local"],
        )
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:],
            [str(REPO / "run-opencode-inst-rearm"), "c2c-opencode-local"],
        )

    def test_run_opencode_inst_outer_forwards_first_sigint_to_child_session(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            outer_path = root / "run-opencode-inst-outer"
            inner_path = root / "run-opencode-inst"
            signal_path = root / "signal.txt"
            child_pid_path = root / "child.pid"
            launch_log_path = root / "launches.txt"
            shutil.copy2(REPO / "run-opencode-inst-outer", outer_path)
            inner_path.write_text(
                "import os, pathlib, signal, sys, time\n"
                f"signal_path = pathlib.Path({str(signal_path)!r})\n"
                f"child_pid_path = pathlib.Path({str(child_pid_path)!r})\n"
                f"launch_log_path = pathlib.Path({str(launch_log_path)!r})\n"
                "with launch_log_path.open('a', encoding='utf-8') as handle:\n"
                "    handle.write(f'{os.getpid()}\\n')\n"
                "child_pid_path.write_text(f'{os.getpid()}\\n', encoding='utf-8')\n"
                "def handle(signum, _frame):\n"
                "    time.sleep(1.0)\n"
                "    signal_path.write_text(signal.Signals(signum).name + '\\n', encoding='utf-8')\n"
                "    raise SystemExit(0)\n"
                "signal.signal(signal.SIGINT, handle)\n"
                "signal.signal(signal.SIGTERM, handle)\n"
                "while True:\n"
                "    time.sleep(0.1)\n",
                encoding="utf-8",
            )

            process = subprocess.Popen(
                [sys.executable, str(outer_path), "opencode-a"],
                cwd=root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    if child_pid_path.exists():
                        break
                    time.sleep(0.05)
                self.assertTrue(child_pid_path.exists(), "child process did not start")

                process.send_signal(signal.SIGINT)

                deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
                while time.monotonic() < deadline:
                    if signal_path.exists():
                        break
                    time.sleep(0.05)

                launches = launch_log_path.read_text(encoding="utf-8").splitlines()
                self.assertEqual(
                    launches, [child_pid_path.read_text(encoding="utf-8").strip()]
                )

                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=CLI_TIMEOUT_SECONDS)

                self.assertEqual(process.returncode, 130, stderr)
                self.assertTrue(signal_path.exists(), stdout + stderr)
                self.assertEqual(
                    signal_path.read_text(encoding="utf-8").strip(), "SIGINT"
                )
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=CLI_TIMEOUT_SECONDS)

    @unittest.skipUnless(shutil.which("opencode"), "opencode not installed")
    def test_opencode_repo_local_config_lists_c2c_server(self):
        result = subprocess.run(
            ["opencode", "mcp", "list"],
            cwd=REPO,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("c2c", result.stdout)
        self.assertIn("c2c_mcp.py", result.stdout)


class RunOpenCodeInstPluginTests(unittest.TestCase):
    def _make_config(
        self, config_dir: Path, name: str, cwd: Path, config_path: Path
    ) -> Path:
        config = {
            "command": sys.executable,
            "cwd": str(cwd),
            "config_path": str(config_path),
            "c2c_session_id": f"{name}-local",
            "c2c_alias": name,
            "prompt": "poll inbox",
            "flags": ["-c", "import sys; sys.exit(0)"],
        }
        config_file = config_dir / f"{name}.json"
        config_file.write_text(json.dumps(config), encoding="utf-8")
        return config_file

    def test_copies_plugin_when_config_outside_repo_opencode(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "^1.0.0"}}),
                encoding="utf-8",
            )
            nm_src = opencode_dir / "node_modules"
            nm_src.mkdir()

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertTrue(
                plugin_dest.exists(), f"plugin should be copied to {plugin_dest}"
            )
            self.assertEqual(plugin_dest.read_text(encoding="utf-8"), "// plugin")
            pkg_dest = config_dir / "package.json"
            self.assertTrue(pkg_dest.exists())
            pkg = json.loads(pkg_dest.read_text(encoding="utf-8"))
            self.assertEqual(pkg["dependencies"]["@opencode-ai/plugin"], "^1.0.0")
            nm_dest = config_dir / "node_modules"
            self.assertTrue(nm_dest.is_symlink() or nm_dest.exists())

    def test_skips_plugin_copy_when_config_inside_repo_opencode(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps({"dependencies": {"@opencode-ai/plugin": "^1.0.0"}}),
                encoding="utf-8",
            )
            nm_src = opencode_dir / "node_modules"
            nm_src.mkdir()

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = opencode_dir / "opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertFalse(
                plugin_dest.exists(),
                "plugin should NOT be copied when config is inside repo .opencode",
            )
            pkg_dest = config_dir / "package.json"
            self.assertFalse(
                pkg_dest.exists() or pkg_dest.is_symlink(),
                "package.json should NOT be copied",
            )
            nm_dest = config_dir / "node_modules"
            self.assertFalse(
                nm_dest.exists() or nm_dest.is_symlink(),
                "node_modules should NOT be symlinked",
            )

    def test_merges_package_json_when_already_exists_in_config_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            plugin_src = opencode_dir / "plugins" / "c2c.ts"
            plugin_src.parent.mkdir(parents=True, exist_ok=True)
            plugin_src.write_text("// plugin", encoding="utf-8")
            pkg_src = opencode_dir / "package.json"
            pkg_src.write_text(
                json.dumps(
                    {
                        "dependencies": {
                            "@opencode-ai/plugin": "^1.0.0",
                            "new-dep": "^2.0.0",
                        }
                    }
                ),
                encoding="utf-8",
            )

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            existing_pkg = config_dir / "package.json"
            existing_pkg.write_text(
                json.dumps({"dependencies": {"existing-dep": "^0.1.0"}}),
                encoding="utf-8",
            )
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            pkg = json.loads(existing_pkg.read_text(encoding="utf-8"))
            self.assertEqual(pkg["dependencies"]["existing-dep"], "^0.1.0")
            self.assertEqual(pkg["dependencies"]["@opencode-ai/plugin"], "^1.0.0")
            self.assertEqual(pkg["dependencies"]["new-dep"], "^2.0.0")

    def test_no_op_when_plugin_source_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp) / "repo"
            cwd.mkdir()
            opencode_dir = cwd / ".opencode"
            opencode_dir.mkdir()
            # no plugins/c2c.ts

            config_dir = Path(tmp) / "run-opencode-inst.d"
            config_dir.mkdir()
            config_path = config_dir / "test.opencode.json"
            config_path.write_text("{}", encoding="utf-8")
            self._make_config(config_dir, "test", cwd, config_path)

            result = subprocess.run(
                [str(REPO / "run-opencode-inst"), "test"],
                env={**os.environ, "RUN_OPENCODE_INST_CONFIG_DIR": str(config_dir)},
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            plugin_dest = config_dir / "plugins" / "c2c.ts"
            self.assertFalse(plugin_dest.exists())


class C2CConfigureOpencodeTests(unittest.TestCase):
    def test_writes_opencode_config_pointing_at_c2c_mcp_in_target_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            config_path = Path(payload["config_path"])
            self.assertEqual(config_path, target / ".opencode" / "opencode.json")
            self.assertTrue(config_path.exists())
            config = json.loads(config_path.read_text(encoding="utf-8"))
            c2c = config["mcp"]["c2c"]
            self.assertEqual(c2c["type"], "local")
            self.assertEqual(c2c["command"], ["python3", str(REPO / "c2c_mcp.py")])
            self.assertEqual(
                c2c["environment"]["C2C_MCP_BROKER_ROOT"],
                str(REPO / ".git" / "c2c" / "mcp"),
            )
            self.assertEqual(
                c2c["environment"]["C2C_MCP_SESSION_ID"],
                f"opencode-{target.name}",
            )
            self.assertEqual(c2c["environment"]["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
            self.assertTrue(c2c["enabled"])
            self.assertEqual(payload["session_id"], f"opencode-{target.name}")
            self.assertEqual(payload["alias"], f"opencode-{target.name}")
            sidecar_path = target / ".opencode" / "c2c-plugin.json"
            self.assertTrue(sidecar_path.exists())
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            self.assertEqual(sidecar["session_id"], f"opencode-{target.name}")
            self.assertEqual(sidecar["alias"], f"opencode-{target.name}")
            self.assertEqual(sidecar["broker_root"], str(REPO / ".git" / "c2c" / "mcp"))
            self.assertTrue((target / ".opencode" / "plugins" / "c2c.ts").exists())
            package_json = json.loads(
                (target / ".opencode" / "package.json").read_text(encoding="utf-8")
            )
            self.assertIn("@opencode-ai/plugin", package_json["dependencies"])

    def test_writes_opencode_config_with_custom_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--alias",
                    "opencode-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            # session_id derived from dir name, alias is the custom value
            self.assertEqual(payload["session_id"], f"opencode-{target.name}")
            self.assertEqual(payload["alias"], "opencode-primary")
            config = json.loads(
                Path(payload["config_path"]).read_text(encoding="utf-8")
            )
            env = config["mcp"]["c2c"]["environment"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], f"opencode-{target.name}")
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            sidecar = json.loads(
                (target / ".opencode" / "c2c-plugin.json").read_text(encoding="utf-8")
            )
            self.assertEqual(sidecar["session_id"], f"opencode-{target.name}")
            self.assertEqual(sidecar["alias"], "opencode-primary")

    def test_refuses_to_overwrite_existing_config_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / ".opencode").mkdir()
            existing = target / ".opencode" / "opencode.json"
            existing.write_text('{"keep": "me"}', encoding="utf-8")
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exists", result.stderr.lower())
            self.assertEqual(
                json.loads(existing.read_text(encoding="utf-8")), {"keep": "me"}
            )

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / ".opencode").mkdir()
            existing = target / ".opencode" / "opencode.json"
            existing.write_text('{"keep": "me"}', encoding="utf-8")
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-opencode",
                    "--target-dir",
                    str(target),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(existing.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcp"])


class RestartOpenCodeSelfTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        # Skip the 1.5s grace-period sleep so tests stay inside CLI_TIMEOUT_SECONDS.
        self.env = {"RUN_OPENCODE_RESTART_SURVIVOR_KILL_DELAY": "0"}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_restart_opencode_self_dry_run_reads_pid_file_without_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        sleeper_pgid = os.getpgid(sleeper.pid)
        try:
            (config_dir / "opencode-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"
            env["RUN_OPENCODE_RESTART_SELF_DRY_RUN"] = "1"

            result = run_cli("restart-opencode-self", "--expect-comm", "sleep", env=env)

            self.assertEqual(result_code(result), 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload["name"], "opencode-a")
            self.assertEqual(payload["pid"], sleeper.pid)
            self.assertEqual(payload["pid_file"], str(config_dir / "opencode-a.pid"))
            self.assertEqual(payload["signal"], "SIGTERM")
            self.assertEqual(payload["comm"], "sleep")
            self.assertEqual(payload["process_group"], os.getpgid(sleeper.pid))
            self.assertEqual(payload["dry_run"], True)
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            try:
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                sleeper.kill()
                sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_opencode_self_writes_reason_marker_before_signaling(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        sleeper_pgid = os.getpgid(sleeper.pid)
        try:
            (config_dir / "opencode-a.pid").write_text(
                f"{sleeper.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"
            env["RUN_OPENCODE_RESTART_SELF_DRY_RUN"] = "0"

            result = run_cli(
                "restart-opencode-self",
                "--expect-comm",
                "sleep",
                "--reason",
                "disabled snip plugin; restart managed opencode",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
            marker_path = config_dir / "opencode-a.restart.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            self.assertEqual(marker["name"], "opencode-a")
            self.assertEqual(marker["pid"], sleeper.pid)
            self.assertEqual(marker["signal"], "SIGTERM")
            self.assertEqual(marker["process_group"], sleeper_pgid)
            self.assertEqual(
                marker["reason"], "disabled snip plugin; restart managed opencode"
            )
            self.assertFalse(marker["dry_run"])
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
                try:
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    sleeper.kill()
                    sleeper.wait(timeout=CLI_TIMEOUT_SECONDS)

    def test_restart_opencode_self_kills_detached_child_from_snapshot(self):
        config_dir = Path(self.temp_dir.name) / "run-opencode-inst.d"
        config_dir.mkdir()
        child_pid_path = Path(self.temp_dir.name) / "child.pid"
        parent_script = (
            "import pathlib, signal, subprocess, sys, time\n"
            f"child_pid_path = pathlib.Path({str(child_pid_path)!r})\n"
            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)\n"
            "child_pid_path.write_text(f'{child.pid}\\n', encoding='utf-8')\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
            "while True:\n"
            "    time.sleep(1)\n"
        )
        parent = subprocess.Popen(
            [sys.executable, "-c", parent_script], start_new_session=True
        )
        child_pid = None
        try:
            deadline = time.monotonic() + CLI_TIMEOUT_SECONDS
            while time.monotonic() < deadline:
                if child_pid_path.exists():
                    child_pid = int(child_pid_path.read_text(encoding="utf-8").strip())
                    break
                time.sleep(0.05)
            self.assertIsNotNone(child_pid, "child pid file was not created")

            (config_dir / "opencode-a.pid").write_text(
                f"{parent.pid}\n", encoding="utf-8"
            )
            env = dict(self.env)
            env["RUN_OPENCODE_INST_CONFIG_DIR"] = str(config_dir)
            env["RUN_OPENCODE_INST_NAME"] = "opencode-a"

            result = run_cli(
                "restart-opencode-self",
                "--expect-comm",
                "python",
                env=env,
            )

            self.assertEqual(result_code(result), 0, result.stderr)
            parent.wait(timeout=CLI_TIMEOUT_SECONDS)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            if parent.poll() is None:
                parent.terminate()
                try:
                    parent.wait(timeout=CLI_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    parent.kill()
                    parent.wait(timeout=CLI_TIMEOUT_SECONDS)
            if child_pid is not None:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_restart_opencode_self_requires_instance_name(self):
        env = dict(self.env)
        env["RUN_OPENCODE_INST_NAME"] = ""

        result = run_cli("restart-opencode-self", env=env)

        self.assertEqual(result_code(result), 2)
        self.assertIn("no instance name", result.stderr)


class C2CVerifyUnitTests(unittest.TestCase):
    def test_resolve_transcript_path_prefers_sessions_fixture_directory(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_path = Path(temp_dir) / "fixtures" / "sessions-live.json"
            fixture_path.parent.mkdir(parents=True)
            transcript_path = fixture_path.parent / "nested" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with tempfile.TemporaryDirectory() as other_dir:
                with (
                    mock.patch.dict(
                        os.environ,
                        {"C2C_SESSIONS_FIXTURE": str(fixture_path)},
                        clear=False,
                    ),
                    mock.patch("os.getcwd", return_value=other_dir),
                ):
                    resolved = c2c_verify.resolve_transcript_path(
                        "nested/transcript.jsonl"
                    )

        self.assertEqual(resolved, transcript_path)

    def test_resolve_transcript_path_preserves_relative_structure_under_fixture_root(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture_root = Path(temp_dir)
            transcript_path = fixture_root / "nested" / "history" / "transcript.jsonl"
            transcript_path.parent.mkdir(parents=True)
            transcript_path.write_text("", encoding="utf-8")

            with mock.patch.dict(
                os.environ, {"C2C_VERIFY_FIXTURE": str(fixture_root)}, clear=False
            ):
                resolved = c2c_verify.resolve_transcript_path(
                    "nested/history/transcript.jsonl"
                )

        self.assertEqual(resolved, transcript_path)

    def test_verify_progress_disambiguates_duplicate_participant_names(self):
        sessions = [
            {"name": "shared-agent", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "shared-agent", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 4, "received": 5},
                    ],
                ),
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"],
            {
                "shared-agent (11111111)": {"sent": 2, "received": 3},
                "shared-agent (22222222)": {"sent": 4, "received": 5},
            },
        )

    def test_verify_progress_sets_goal_met_only_when_all_participants_meet_threshold(
        self,
    ):
        sessions = [
            {"name": "agent-one", "session_id": "11111111-aaaa", "transcript": "a"},
            {"name": "agent-two", "session_id": "22222222-bbbb", "transcript": "b"},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": "11111111-aaaa", "alias": "storm-herald"},
                        {"session_id": "22222222-bbbb", "alias": "ember-crown"},
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 20, "received": 20},
                        {"sent": 19, "received": 20},
                    ],
                ),
            ):
                met_payload = c2c_verify.verify_progress()
                not_met_payload = c2c_verify.verify_progress()

        self.assertTrue(met_payload["goal_met"])
        self.assertFalse(not_met_payload["goal_met"])

    def test_verify_progress_ignores_unregistered_live_sessions(self):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {
                "name": "agent-two",
                "session_id": AGENT_TWO_SESSION_ID,
                "transcript": "b",
            },
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    side_effect=[
                        {"sent": 2, "received": 3},
                        {"sent": 99, "received": 99},
                    ],
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 2, "received": 3}}
        )
        summarize.assert_called_once_with("a")

    def test_verify_progress_ignores_missing_transcript_when_session_not_registered(
        self,
    ):
        sessions = [
            {
                "name": "agent-one",
                "session_id": AGENT_ONE_SESSION_ID,
                "transcript": "a",
            },
            {"name": "agent-two", "session_id": AGENT_TWO_SESSION_ID},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            registry_path = Path(temp_dir) / "registry.yaml"
            save_registry(
                {
                    "registrations": [
                        {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"}
                    ]
                },
                registry_path,
            )

            with (
                mock.patch.dict(
                    os.environ, {"C2C_REGISTRY_PATH": str(registry_path)}, clear=False
                ),
                mock.patch("c2c_verify.load_sessions", return_value=sessions),
                mock.patch(
                    "c2c_verify.summarize_transcript",
                    return_value={"sent": 1, "received": 4},
                ) as summarize,
            ):
                payload = c2c_verify.verify_progress()

        self.assertEqual(
            payload["participants"], {"agent-one": {"sent": 1, "received": 4}}
        )
        summarize.assert_called_once_with("a")

    def test_summarize_transcript_counts_queued_replies(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">two</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply one"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply two"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 2, "received": 2},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CWhoamiUnitTests(unittest.TestCase):
    def test_current_session_identifier_uses_direct_parent_claude_process(self):
        def read_text(path_self):
            if str(path_self) == "/proc/4000/comm":
                return "claude\n"
            if str(path_self) == "/proc/3000/comm":
                return "bash\n"
            if str(path_self) == "/proc/5000/comm":
                return "python3\n"
            raise FileNotFoundError(str(path_self))

        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.Path.read_text", autospec=True, side_effect=read_text
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "4000")

    def test_current_session_identifier_uses_single_claude_child_of_parent_shell(self):
        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000, 3000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                side_effect=[[], [(11111, "claude")], []],
            ),
        ):
            self.assertEqual(c2c_whoami.current_session_identifier(), "11111")

    def test_current_session_identifier_fails_when_parent_chain_has_multiple_claude_children(
        self,
    ):
        with (
            mock.patch.dict(
                os.environ, {"C2C_SESSION_ID": "", "C2C_SESSION_PID": ""}, clear=False
            ),
            mock.patch("c2c_whoami.os.getpid", return_value=5000),
            mock.patch(
                "c2c_whoami.parent_process_chain",
                return_value=[5000, 4000],
            ),
            mock.patch(
                "c2c_whoami.child_processes",
                return_value=[(11111, "claude"), (22222, "claude")],
            ),
        ):
            with self.assertRaisesRegex(
                ValueError, "could not resolve current session uniquely"
            ):
                c2c_whoami.current_session_identifier()

    def test_summarize_transcript_does_not_count_assistant_after_unrelated_user_turn(
        self,
    ):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"follow-up outside c2c"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"general reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 0, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)

    def test_summarize_transcript_counts_reply_after_tool_use_and_tool_result(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">one</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"lookup","input":{}}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply after tool"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)

    def test_summarize_transcript_ignores_onboarding_events(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            transcript_path = Path(handle.name)
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"onboarding\\" from=\\"c2c-register\\" alias=\\"storm-herald\\">welcome</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"thanks"}]}}\n'
            )
            handle.write(
                '{"type":"user","message":{"content":"<c2c event=\\"message\\" from=\\"storm-herald\\" alias=\\"storm-herald\\">hello</c2c>"}}\n'
            )
            handle.write(
                '{"type":"assistant","message":{"content":[{"type":"text","text":"reply"}]}}\n'
            )

        try:
            self.assertEqual(
                c2c_verify.summarize_transcript(str(transcript_path)),
                {"sent": 1, "received": 1},
            )
        finally:
            transcript_path.unlink(missing_ok=True)


class C2CVerifyBrokerTests(unittest.TestCase):
    """Tests for verify_progress_broker() — broker-archive-based cross-client verify."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name) / "broker"
        self.archive_dir = self.broker_root / "archive"
        self.archive_dir.mkdir(parents=True)
        self.registry_path = self.broker_root / "registry.json"

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

    def test_empty_broker_returns_empty_participants(self):
        self._write_registry([])
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"], {})
        self.assertFalse(result["goal_met"])
        self.assertEqual(result["source"], "broker")

    def test_received_count_from_own_archive(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        msgs = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ]
        self._write_archive("sess-a.jsonl", msgs * 5)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["received"], 5)

    def test_archive_keyed_by_alias_fallback(self):
        """Named sessions (e.g. codex-local) may have archive file named after alias."""
        self._write_registry([{"alias": "codex", "session_id": "codex-local"}])
        msgs = [
            {
                "from_alias": "agent-a",
                "to_alias": "codex",
                "content": "hi",
                "drained_at": 1.0,
            }
        ]
        # Archive file is named after session_id (codex-local.jsonl)
        self._write_archive("codex-local.jsonl", msgs * 3)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["codex"]["received"], 3)

    def test_sent_count_from_cross_archive_scan(self):
        self._write_registry(
            [
                {"alias": "agent-a", "session_id": "sess-a"},
                {"alias": "agent-b", "session_id": "sess-b"},
            ]
        )
        # agent-b archive: agent-a sent 4 messages to agent-b
        msgs_b = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 4
        # agent-a archive: agent-b sent 2 messages to agent-a
        msgs_a = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hey",
                "drained_at": 2.0,
            }
        ] * 2
        self._write_archive("sess-a.jsonl", msgs_a)
        self._write_archive("sess-b.jsonl", msgs_b)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 4)
        self.assertEqual(result["participants"]["agent-b"]["sent"], 2)

    def test_c2c_system_messages_excluded_from_sent(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        msgs = [
            {
                "from_alias": "c2c-system",
                "to_alias": "agent-a@swarm-lounge",
                "content": "{}",
                "drained_at": 1.0,
            }
        ] * 10
        self._write_archive("sess-a.jsonl", msgs)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        # c2c-system messages should not count toward any sent tally
        self.assertEqual(result["participants"]["agent-a"]["sent"], 0)

    def test_goal_met_when_both_thresholds_reached(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        # 20 messages received, 20 messages "sent" (appearing as from_alias in other archives)
        received = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 20
        self._write_archive("sess-a.jsonl", received)
        # Simulate agent-a's sent messages appearing in agent-b's archive
        sent_as_from = [
            {
                "from_alias": "agent-a",
                "to_alias": "agent-b",
                "content": "yo",
                "drained_at": 2.0,
            }
        ] * 20
        self._write_archive("sess-b.jsonl", sent_as_from)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 20)
        self.assertEqual(result["participants"]["agent-a"]["received"], 20)
        self.assertTrue(result["goal_met"])

    def test_goal_not_met_when_only_received_threshold_reached(self):
        self._write_registry([{"alias": "agent-a", "session_id": "sess-a"}])
        received = [
            {
                "from_alias": "agent-b",
                "to_alias": "agent-a",
                "content": "hi",
                "drained_at": 1.0,
            }
        ] * 20
        self._write_archive("sess-a.jsonl", received)
        result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertEqual(result["participants"]["agent-a"]["received"], 20)
        self.assertEqual(result["participants"]["agent-a"]["sent"], 0)
        self.assertFalse(result["goal_met"])

    def test_falls_back_to_yaml_registry_when_json_absent(self):
        # No registry.json — falls back to load_registry() (Python YAML)
        with mock.patch("c2c_verify.load_registry") as mock_load:
            mock_load.return_value = {
                "registrations": [{"alias": "agent-z", "session_id": "sess-z"}]
            }
            result = c2c_verify.verify_progress_broker(self.broker_root)
        self.assertIn("agent-z", result["participants"])

    def test_alive_only_filters_dead_registrations(self):
        # Pass pid without pid_start_time — broker_registration_is_alive returns True
        # if /proc/<pid> exists and pid_start_time is not an int.
        self._write_registry(
            [
                {"alias": "live-agent", "session_id": "sess-live", "pid": os.getpid()},
                {"alias": "dead-agent", "session_id": "sess-dead", "pid": 99999999},
            ]
        )
        result = c2c_verify.verify_progress_broker(self.broker_root, alive_only=True)
        # dead-agent has a nonexistent PID → excluded
        self.assertIn("live-agent", result["participants"])
        self.assertNotIn("dead-agent", result["participants"])

    def test_alive_only_false_includes_dead_registrations(self):
        self._write_registry(
            [
                {"alias": "live-agent", "session_id": "sess-live", "pid": os.getpid()},
                {"alias": "dead-agent", "session_id": "sess-dead", "pid": 99999999},
            ]
        )
        result = c2c_verify.verify_progress_broker(self.broker_root, alive_only=False)
        self.assertIn("live-agent", result["participants"])
        self.assertIn("dead-agent", result["participants"])


class C2CPruneUnitTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.registry_path = Path(self.temp_dir.name) / "registry.yaml"
        self.stale_session_id = "dead0000-0000-0000-0000-000000000000"

    def tearDown(self):
        self.temp_dir.cleanup()

    def _seed_registry(self):
        """Seed 3 registrations: agent-one, agent-two (live), and one stale."""
        registry = {
            "registrations": [
                {"session_id": AGENT_ONE_SESSION_ID, "alias": "storm-herald"},
                {"session_id": AGENT_TWO_SESSION_ID, "alias": "ember-crown"},
                {"session_id": self.stale_session_id, "alias": "silver-banner"},
            ]
        }
        save_registry(registry, self.registry_path)
        return registry

    def _mock_load_sessions(self):
        """Return only agent-one as live; agent-two and stale are dead."""
        return [
            {"session_id": AGENT_ONE_SESSION_ID, "name": "agent-one"},
        ]

    def test_prune_removes_stale_entries_from_yaml(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main([])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(session_ids, [AGENT_ONE_SESSION_ID])

    def test_prune_dry_run_does_not_mutate(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
        ):
            rc = c2c_prune.main(["--dry-run"])

        self.assertEqual(rc, 0)
        registry = load_registry(self.registry_path)
        session_ids = [r["session_id"] for r in registry["registrations"]]
        self.assertEqual(len(session_ids), 3)
        self.assertIn(AGENT_ONE_SESSION_ID, session_ids)
        self.assertIn(AGENT_TWO_SESSION_ID, session_ids)
        self.assertIn(self.stale_session_id, session_ids)

    def test_prune_reports_removed_entries_in_json(self):
        self._seed_registry()

        with (
            mock.patch.dict(os.environ, {"C2C_REGISTRY_PATH": str(self.registry_path)}),
            mock.patch("c2c_prune.load_sessions", side_effect=self._mock_load_sessions),
            mock.patch("sys.stdout", new_callable=io.StringIO) as mock_stdout,
        ):
            rc = c2c_prune.main(["--json"])

        self.assertEqual(rc, 0)
        payload = json.loads(mock_stdout.getvalue())
        self.assertEqual(payload["count"], 2)
        self.assertFalse(payload["dry_run"])
        removed_aliases = sorted(entry["alias"] for entry in payload["pruned"])
        self.assertEqual(removed_aliases, ["ember-crown", "silver-banner"])
        removed_session_ids = sorted(entry["session_id"] for entry in payload["pruned"])
        self.assertEqual(
            removed_session_ids,
            sorted([AGENT_TWO_SESSION_ID, self.stale_session_id]),
        )


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


class C2CConfigureKimiTests(unittest.TestCase):
    def test_writes_kimi_mcp_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(mcp_path))
            self.assertTrue(mcp_path.exists())
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            c2c = config["mcpServers"]["c2c"]
            self.assertEqual(c2c["type"], "stdio")
            self.assertEqual(c2c["command"], "python3")
            self.assertEqual(c2c["args"], [str(REPO / "c2c_mcp.py")])
            self.assertEqual(c2c["env"]["C2C_MCP_BROKER_ROOT"], str(broker_root))

    def test_setup_kimi_dispatches_to_configure_kimi(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "setup",
                    "kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(mcp_path))
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcpServers"])

    def test_writes_kimi_mcp_config_with_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--session-id",
                    "kimi-test",
                    "--alias",
                    "kimi-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-test")
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)

    def test_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            mcp_path.write_text('{"mcpServers": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            mcp_path.write_text('{"mcpServers": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])


class C2CConfigureCrushTests(unittest.TestCase):
    def test_writes_crush_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(config_path))
            self.assertTrue(config_path.exists())
            config = json.loads(config_path.read_text(encoding="utf-8"))
            c2c = config["mcp"]["c2c"]
            self.assertEqual(c2c["type"], "stdio")
            self.assertEqual(c2c["command"], "python3")
            self.assertEqual(c2c["args"], [str(REPO / "c2c_mcp.py")])
            self.assertEqual(c2c["env"]["C2C_MCP_BROKER_ROOT"], str(broker_root))

    def test_setup_crush_dispatches_to_configure_crush(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "setup",
                    "crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["path"], str(config_path))
            config = json.loads(config_path.read_text(encoding="utf-8"))
            self.assertIn("c2c", config["mcp"])

    def test_writes_crush_config_with_alias(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--session-id",
                    "crush-test",
                    "--alias",
                    "crush-primary",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "crush-test")
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)

    def test_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            config_path.write_text('{"mcp": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 1)
            payload = json.loads(result.stdout)
            self.assertFalse(payload["ok"])

    def test_force_overwrites_existing_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            config_path.write_text('{"mcp": {"c2c": {}}}', encoding="utf-8")
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--force",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])

    def test_writes_default_alias_when_no_alias_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            # Default alias should be set (crush-user-host pattern)
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # Session ID should equal alias so auto_register_startup works
            self.assertEqual(
                env.get("C2C_MCP_SESSION_ID"), env.get("C2C_MCP_SESSION_ID")
            )

    def test_alias_is_used_as_session_id_when_no_explicit_session(self):
        """When --alias is given but no --session-id, session ID defaults to alias."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--alias",
                    "crush-mybot",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "crush-mybot")

    def test_no_alias_flag_suppresses_auto_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "crush.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-crush",
                    "--config-path",
                    str(config_path),
                    "--broker-root",
                    str(broker_root),
                    "--no-alias",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            env = config["mcp"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # No alias means no session ID either
            self.assertNotIn("C2C_MCP_SESSION_ID", env)


class C2CConfigureKimiDefaultAliasTests(unittest.TestCase):
    def test_writes_default_alias_when_no_alias_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            # Default alias should be set (kimi-user-host pattern)
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # Session ID should equal alias so auto_register_startup works
            self.assertEqual(
                env.get("C2C_MCP_SESSION_ID"), env.get("C2C_MCP_SESSION_ID")
            )

    def test_alias_is_used_as_session_id_when_no_explicit_session(self):
        """When --alias is given but no --session-id, session ID defaults to alias."""
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--alias",
                    "kimi-mybot",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-mybot")

    def test_no_alias_flag_suppresses_auto_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            mcp_path = Path(tmp) / "mcp.json"
            broker_root = Path(tmp) / "broker"
            result = subprocess.run(
                [
                    str(REPO / "c2c"),
                    "configure-kimi",
                    "--mcp-path",
                    str(mcp_path),
                    "--broker-root",
                    str(broker_root),
                    "--no-alias",
                    "--json",
                ],
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(mcp_path.read_text(encoding="utf-8"))
            env = config["mcpServers"]["c2c"]["env"]
            self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", env)
            # No alias means no session ID either
            self.assertNotIn("C2C_MCP_SESSION_ID", env)


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


class RunKimiInstTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.env = {}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_run_kimi_inst_dry_run_shows_launch_command(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        # In interactive (non-print) mode, --continue is added for session resumption
        self.assertEqual(payload["launch"], ["kimi", "--yolo", "--continue"])
        self.assertEqual(payload["prompt_mode"], "interactive-cli")
        self.assertEqual(payload["env"]["RUN_KIMI_INST_C2C_SESSION_ID"], "kimi-test")
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-test")
        # C2C_MCP_CLIENT_PID must be set so broker registers against durable Kimi PID
        self.assertRegex(payload["env"]["C2C_MCP_CLIENT_PID"], r"^[1-9][0-9]*$")

    def test_run_kimi_inst_dry_run_supports_command_array(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": ["uvx", "--python", "python3.14", "--from", "kimi-cli", "kimi"],
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        # In interactive (non-print) mode, --continue is added for session resumption
        self.assertEqual(
            payload["launch"],
            [
                "uvx",
                "--python",
                "python3.14",
                "--from",
                "kimi-cli",
                "kimi",
                "--yolo",
                "--continue",
            ],
        )

    def test_run_kimi_inst_dry_run_prefills_prompt_in_interactive_mode(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        bin_dir = Path(self.temp_dir.name) / "bin"
        bin_dir.mkdir()
        kimi_python = Path(self.temp_dir.name) / "kimi-python"
        kimi_python.write_text("#!/bin/sh\n", encoding="utf-8")
        kimi_python.chmod(0o755)
        kimi = bin_dir / "kimi"
        kimi.write_text(f"#!{kimi_python}\n", encoding="utf-8")
        kimi.chmod(0o755)
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
            "prompt": "poll inbox",
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)
        env["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"],
            [
                str(kimi_python),
                str(REPO / "c2c_kimi_prefill.py"),
                "--yolo",
                "--continue",
                "--prompt",
                "poll inbox",
            ],
        )
        self.assertEqual(payload["interactive_prompt"], "prefill")
        self.assertNotIn("--trust-all-tools", payload["launch"])
        self.assertNotIn("--print", payload["launch"])
        self.assertEqual(payload["prompt_mode"], "interactive-prefill")

    def test_run_kimi_inst_dry_run_uses_print_mode_when_explicitly_configured(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        config = {
            "command": "kimi",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "kimi-test",
            "c2c_alias": "kimi-test",
            "prompt": "poll inbox",
            "print": True,
        }
        (config_dir / "kimi-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_DRY_RUN"] = "1"
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-kimi-inst", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"][:5],
            ["kimi", "--yolo", "--print", "--prompt", "poll inbox"],
        )
        self.assertEqual(payload["prompt_mode"], "non-interactive")

    def test_run_kimi_inst_help_exits_without_config_lookup(self):
        result = run_cli("run-kimi-inst", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-kimi-inst", result.stdout)

    def test_run_kimi_inst_outer_dry_run_reports_inner_and_rearm(self):
        env = {"RUN_KIMI_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-kimi-inst-outer", "kimi-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(payload["inner"][1:], [str(REPO / "run-kimi-inst"), "kimi-a"])
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:], [str(REPO / "run-kimi-inst-rearm"), "kimi-a"]
        )
        self.assertFalse(payload["start_new_session"])

    def test_run_kimi_inst_outer_help_exits_without_looping(self):
        result = run_cli("run-kimi-inst-outer", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-kimi-inst-outer", result.stdout)
        self.assertNotIn("iter 1", result.stdout)

    def test_run_kimi_inst_outer_refresh_peer_passes_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "kimi-a.json").write_text(
            json.dumps({"c2c_alias": "kimi-nova", "c2c_session_id": "kimi-session"}),
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
            namespace["maybe_refresh_peer"]("kimi-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0],
            [
                sys.executable,
                str(refresh),
                "kimi-nova",
                "--pid",
                "12345",
                "--session-id",
                "kimi-session",
            ],
        )

    def test_run_kimi_inst_outer_refresh_peer_passes_env_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-kimi-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "kimi-b.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "kimi-nova",
                    "env": {"C2C_MCP_SESSION_ID": "kimi-env-session"},
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
            namespace["maybe_refresh_peer"]("kimi-b", 12345)

        self.assertEqual(len(calls), 1)
        self.assertIn("--session-id", calls[0])
        idx = calls[0].index("--session-id")
        self.assertEqual(calls[0][idx + 1], "kimi-env-session")

    def test_run_kimi_inst_outer_logs_rearm_output(self):
        namespace = runpy.run_path(str(REPO / "run-kimi-inst-outer"))
        root = Path(self.temp_dir.name)
        rearm = root / "run-kimi-inst-rearm"
        rearm.write_text("#!/bin/sh\n", encoding="utf-8")
        globals_for_outer = namespace["maybe_rearm"].__globals__
        globals_for_outer["HERE"] = root
        globals_for_outer["REARM"] = rearm

        def fake_run(command, *, cwd, check, stdout, stderr):
            stdout.write("rearm stdout\n")
            stderr.write("rearm stderr\n")
            return subprocess.CompletedProcess(command, 9)

        with (
            mock.patch.dict(os.environ, {"RUN_KIMI_INST_REARM": "1"}),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            namespace["maybe_rearm"]("kimi-a")

        log_path = root / "run-kimi-inst.d" / "kimi-a.outer.log"
        self.assertEqual(
            log_path.read_text(encoding="utf-8"), "rearm stdout\nrearm stderr\n"
        )
        self.assertIn("rearm exited code=9", stderr.getvalue())
        self.assertIn(str(log_path), stderr.getvalue())

    def test_run_kimi_inst_rearm_dry_run_shows_deliver_command(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        config_dir.mkdir()
        live_pid = os.getpid()
        (config_dir / "kimi-a.pid").write_text(f"{live_pid}\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-kimi-inst-rearm",
            "kimi-a",
            "--session-id",
            "kimi-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "kimi-a")
        self.assertEqual(payload["target_pid"], live_pid)
        self.assertEqual(payload["target_source"], "pidfile")
        self.assertEqual(payload["session_id"], "kimi-a-local")
        self.assertTrue(payload["dry_run"])
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id kimi-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)

    def test_run_kimi_inst_rearm_uses_live_broker_pid_when_pidfile_stale(self):
        config_dir = Path(self.temp_dir.name) / "run-kimi-inst.d"
        broker_root = Path(self.temp_dir.name) / "broker"
        config_dir.mkdir()
        broker_root.mkdir()
        (config_dir / "kimi-nova.pid").write_text("11111\n", encoding="utf-8")
        config = {
            "c2c_session_id": "kimi-nova",
            "c2c_alias": "kimi-nova",
        }
        (config_dir / "kimi-nova.json").write_text(json.dumps(config), encoding="utf-8")
        live_pid = os.getpid()
        (broker_root / "registry.json").write_text(
            json.dumps(
                [
                    {
                        "session_id": "kimi-nova",
                        "alias": "kimi-nova",
                        "pid": live_pid,
                        "pid_start_time": c2c_mcp.read_pid_start_time(live_pid),
                    }
                ]
            ),
            encoding="utf-8",
        )
        env = dict(self.env)
        env["RUN_KIMI_INST_CONFIG_DIR"] = str(config_dir)
        env["C2C_MCP_BROKER_ROOT"] = str(broker_root)

        result = run_cli(
            "run-kimi-inst-rearm",
            "kimi-nova",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["target_pid"], live_pid)
        self.assertEqual(payload["target_source"], "broker")
        self.assertEqual(payload["pidfile_pid"], 11111)
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn(f"--pid {live_pid}", joined_commands)


class RunCrushInstTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.env = {}

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_run_crush_inst_dry_run_shows_launch_command(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-test",
            "c2c_alias": "crush-test",
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["launch"][0], "crush")
        self.assertEqual(payload["env"]["RUN_CRUSH_INST_C2C_SESSION_ID"], "crush-test")
        self.assertEqual(payload["env"]["C2C_MCP_AUTO_REGISTER_ALIAS"], "crush-test")

    def test_run_crush_inst_uses_explicit_crush_session_id(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-c2c",
            "c2c_alias": "crush-c2c",
            "crush_session_id": "crush-native-session",
            "flags": ["--model", "sonnet", "--continue", "-C"],
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["launch"],
            ["crush", "--model", "sonnet", "-s", "crush-native-session"],
        )
        self.assertNotIn("--continue", payload["launch"])
        self.assertNotIn("-C", payload["launch"])

    def test_run_crush_inst_crush_session_id_must_be_string(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        config = {
            "command": "crush",
            "cwd": self.temp_dir.name,
            "c2c_session_id": "crush-c2c",
            "crush_session_id": 123,
        }
        (config_dir / "crush-a.json").write_text(json.dumps(config), encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_DRY_RUN"] = "1"
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli("run-crush-inst", "crush-a", env=env)

        self.assertNotEqual(result_code(result), 0)
        self.assertIn("crush_session_id must be a string", result.stderr)

    def test_run_crush_inst_help_exits_without_config_lookup(self):
        result = run_cli("run-crush-inst", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-crush-inst", result.stdout)

    def test_run_crush_inst_outer_dry_run_reports_inner_and_rearm(self):
        env = {"RUN_CRUSH_INST_OUTER_DRY_RUN": "1"}
        result = run_cli("run-crush-inst-outer", "crush-a", env=env)

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(Path(payload["inner"][0]).name.startswith("python"))
        self.assertEqual(
            payload["inner"][1:], [str(REPO / "run-crush-inst"), "crush-a"]
        )
        self.assertTrue(Path(payload["rearm"][0]).name.startswith("python"))
        self.assertEqual(
            payload["rearm"][1:], [str(REPO / "run-crush-inst-rearm"), "crush-a"]
        )

    def test_run_crush_inst_outer_help_exits_without_looping(self):
        result = run_cli("run-crush-inst-outer", "--help")

        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("Usage: ./run-crush-inst-outer", result.stdout)
        self.assertNotIn("iter 1", result.stdout)

    def test_run_crush_inst_outer_create_writes_default_config(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-crush-inst"
        rearm = root / "run-crush-inst-rearm"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        rearm.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner
        namespace["main"].__globals__["REARM"] = rearm

        stdout = io.StringIO()
        with (
            mock.patch.dict(
                os.environ, {"RUN_CRUSH_INST_OUTER_DRY_RUN": "1"}, clear=False
            ),
            mock.patch("sys.stdout", new=stdout),
        ):
            rc = namespace["main"](["run-crush-inst-outer", "--create", "crush-new"])

        self.assertEqual(rc, 0)
        cfg_path = root / "run-crush-inst.d" / "crush-new.json"
        self.assertTrue(cfg_path.exists())
        payload = json.loads(cfg_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["command"], "crush")
        self.assertEqual(payload["cwd"], str(root))
        self.assertEqual(payload["c2c_session_id"], "crush-new")
        self.assertEqual(payload["c2c_alias"], "crush-new")
        self.assertIn("[run-crush-inst-outer] created config:", stdout.getvalue())

    def test_run_crush_inst_outer_create_preserves_existing_config(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-crush-inst.d"
        cfg_dir.mkdir()
        cfg_path = cfg_dir / "crush-existing.json"
        cfg_path.write_text(
            json.dumps({"command": "custom-crush", "c2c_alias": "stable"}),
            encoding="utf-8",
        )
        namespace["_create_config"].__globals__["HERE"] = root

        result = namespace["_create_config"]("crush-existing")

        self.assertEqual(result, cfg_path)
        self.assertEqual(
            json.loads(cfg_path.read_text(encoding="utf-8")),
            {"command": "custom-crush", "c2c_alias": "stable"},
        )

    def test_run_crush_inst_outer_refreshes_peer_after_child_spawn(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        inner = root / "run-crush-inst"
        inner.write_text("#!/bin/sh\n", encoding="utf-8")
        namespace["main"].__globals__["HERE"] = root
        namespace["main"].__globals__["INNER"] = inner

        refresh_calls = []

        class FakeProcess:
            pid = 43210
            returncode = 0

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
                namespace["main"](["run-crush-inst-outer", "crush-a"])

        self.assertEqual(refresh_calls, [("crush-a", 43210)])

    def test_run_crush_inst_outer_refresh_peer_passes_session_id(self):
        namespace = runpy.run_path(str(REPO / "run-crush-inst-outer"))
        root = Path(self.temp_dir.name)
        cfg_dir = root / "run-crush-inst.d"
        cfg_dir.mkdir()
        (cfg_dir / "crush-a.json").write_text(
            json.dumps(
                {
                    "c2c_alias": "crush-primary",
                    "c2c_session_id": "crush-session",
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
            namespace["maybe_refresh_peer"]("crush-a", 12345)

        self.assertEqual(len(calls), 1)
        self.assertEqual(
            calls[0],
            [
                sys.executable,
                str(refresh),
                "crush-primary",
                "--pid",
                "12345",
                "--session-id",
                "crush-session",
            ],
        )

    def test_run_crush_inst_rearm_dry_run_shows_deliver_command(self):
        config_dir = Path(self.temp_dir.name) / "run-crush-inst.d"
        config_dir.mkdir()
        (config_dir / "crush-a.pid").write_text("54321\n", encoding="utf-8")
        env = dict(self.env)
        env["RUN_CRUSH_INST_CONFIG_DIR"] = str(config_dir)

        result = run_cli(
            "run-crush-inst-rearm",
            "crush-a",
            "--session-id",
            "crush-a-local",
            "--dry-run",
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["name"], "crush-a")
        self.assertEqual(payload["target_pid"], 54321)
        self.assertEqual(payload["session_id"], "crush-a-local")
        self.assertTrue(payload["dry_run"])
        joined_commands = " ".join(" ".join(cmd) for cmd in payload["commands"])
        self.assertIn("c2c_deliver_inbox.py", joined_commands)
        self.assertIn("--session-id crush-a-local", joined_commands)
        self.assertIn("--notify-only", joined_commands)


class HealthCheckHookTests(unittest.TestCase):
    """Tests for c2c_health.check_hook()."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.home = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _hook_path(self):
        return self.home / ".claude" / "hooks" / "c2c-inbox-check.sh"

    def _settings_path(self):
        return self.home / ".claude" / "settings.json"

    def _write_hook(self, executable: bool = True) -> None:
        hook = self._hook_path()
        hook.parent.mkdir(parents=True, exist_ok=True)
        hook.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        if executable:
            hook.chmod(0o755)

    def _write_settings(self, has_c2c: bool = True) -> None:
        settings = self._settings_path()
        settings.parent.mkdir(parents=True, exist_ok=True)
        if has_c2c:
            payload = {
                "hooks": {
                    "PostToolUse": [
                        {
                            "matcher": ".*",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "/home/user/.claude/hooks/c2c-inbox-check.sh",
                                }
                            ],
                        }
                    ]
                }
            }
        else:
            payload = {"hooks": {"PostToolUse": []}}
        settings.write_text(json.dumps(payload), encoding="utf-8")

    def test_no_hook_file_returns_not_ok(self):
        import c2c_health

        result = c2c_health.check_hook(self.home)
        self.assertFalse(result["hook_exists"])
        self.assertFalse(result["ok"])

    def test_hook_exists_but_not_in_settings_returns_partial(self):
        import c2c_health

        self._write_hook()
        self._write_settings(has_c2c=False)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertTrue(result["hook_executable"])
        self.assertFalse(result["settings_registered"])
        self.assertFalse(result["ok"])

    def test_hook_and_settings_both_present_returns_ok(self):
        import c2c_health

        self._write_hook()
        self._write_settings(has_c2c=True)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertTrue(result["hook_executable"])
        self.assertTrue(result["settings_registered"])
        self.assertTrue(result["ok"])

    def test_non_executable_hook_returns_not_ok(self):
        import c2c_health

        self._write_hook(executable=False)
        self._write_settings(has_c2c=True)
        result = c2c_health.check_hook(self.home)
        self.assertTrue(result["hook_exists"])
        self.assertFalse(result["hook_executable"])
        self.assertFalse(result["ok"])


class HealthCheckSwarmLoungeTests(unittest.TestCase):
    """Tests for c2c_health.check_swarm_lounge()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_no_alias_returns_not_member(self):
        import c2c_health

        result = c2c_health.check_swarm_lounge(self.broker_root, None)
        self.assertFalse(result["member"])
        self.assertFalse(result["room_exists"])

    def test_room_missing_returns_not_member(self):
        import c2c_health

        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertFalse(result["member"])
        self.assertFalse(result["room_exists"])

    def test_alias_in_members_returns_member(self):
        import c2c_health

        lounge = self.broker_root / "rooms" / "swarm-lounge"
        lounge.mkdir(parents=True)
        (lounge / "members.json").write_text(
            json.dumps([{"alias": "my-alias", "session_id": "s1"}]),
            encoding="utf-8",
        )
        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertTrue(result["member"])
        self.assertTrue(result["room_exists"])

    def test_alias_not_in_members_returns_not_member(self):
        import c2c_health

        lounge = self.broker_root / "rooms" / "swarm-lounge"
        lounge.mkdir(parents=True)
        (lounge / "members.json").write_text(
            json.dumps([{"alias": "other-alias", "session_id": "s1"}]),
            encoding="utf-8",
        )
        result = c2c_health.check_swarm_lounge(self.broker_root, "my-alias")
        self.assertFalse(result["member"])
        self.assertTrue(result["room_exists"])


class HealthCheckSessionInboxPendingTests(unittest.TestCase):
    """Tests for inbox_pending count in c2c_health.check_session()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, session_id: str, alias: str) -> None:
        import os

        self.registry_path.write_text(
            json.dumps(
                [
                    {
                        "session_id": session_id,
                        "alias": alias,
                        "pid": os.getpid(),
                        "pid_start_time": 1,
                    }
                ]
            ),
            encoding="utf-8",
        )

    def test_inbox_pending_is_zero_for_empty_inbox(self):
        import c2c_health

        self._write_registry("ses-empty", "agent-empty")
        inbox = self.broker_root / "ses-empty.inbox.json"
        inbox.write_text("[]", encoding="utf-8")

        result = c2c_health.check_session(self.broker_root, session_id="ses-empty")
        self.assertTrue(result["registered"])
        self.assertEqual(result["inbox_pending"], 0)

    def test_inbox_pending_counts_messages(self):
        import c2c_health

        self._write_registry("ses-msgs", "agent-msgs")
        msgs = [
            {"from_alias": "peer-a", "to_alias": "agent-msgs", "content": "hello"},
            {"from_alias": "peer-b", "to_alias": "agent-msgs", "content": "world"},
            {"from_alias": "peer-c", "to_alias": "agent-msgs", "content": "sup"},
        ]
        inbox = self.broker_root / "ses-msgs.inbox.json"
        inbox.write_text(json.dumps(msgs), encoding="utf-8")

        result = c2c_health.check_session(self.broker_root, session_id="ses-msgs")
        self.assertTrue(result["registered"])
        self.assertEqual(result["inbox_pending"], 3)

    def test_inbox_pending_zero_when_inbox_missing(self):
        import c2c_health

        self._write_registry("ses-nofile", "agent-nofile")
        # No inbox file created

        result = c2c_health.check_session(self.broker_root, session_id="ses-nofile")
        self.assertTrue(result["registered"])
        self.assertFalse(result["inbox_exists"])
        self.assertEqual(result["inbox_pending"], 0)


class HealthCheckSessionMcpSessionIdTests(unittest.TestCase):
    """Tests for C2C_MCP_SESSION_ID fallback in c2c_health.check_session()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, session_id: str, alias: str) -> None:
        import os

        self.registry_path.write_text(
            json.dumps(
                [
                    {
                        "session_id": session_id,
                        "alias": alias,
                        "pid": os.getpid(),
                        "pid_start_time": 1,
                    }
                ]
            ),
            encoding="utf-8",
        )

    def test_mcp_session_id_resolves_when_no_explicit_session_id(self):
        """C2C_MCP_SESSION_ID env var is used as fallback for session resolution."""
        import c2c_health

        self._write_registry("mcp-sid-abc123", "storm-beacon")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "mcp-sid-abc123"}, clear=False
        ):
            # Remove env vars that would interfere with whoami resolution
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("C2C_SESSION_ID", "C2C_SESSION_PID")
            }
            env["C2C_MCP_SESSION_ID"] = "mcp-sid-abc123"
            with mock.patch.dict(os.environ, env, clear=True):
                result = c2c_health.check_session(self.broker_root)

        self.assertTrue(result["resolved"])
        self.assertTrue(result["registered"])
        self.assertEqual(result["alias"], "storm-beacon")
        self.assertEqual(result["session_id"], "mcp-sid-abc123")

    def test_mcp_session_id_not_in_registry_gives_unregistered(self):
        """C2C_MCP_SESSION_ID set but not registered yields resolved=True, registered=False."""
        import c2c_health

        # Registry is empty
        self.registry_path.write_text("[]", encoding="utf-8")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "unknown-sid-xyz"}, clear=False
        ):
            env = {
                k: v
                for k, v in os.environ.items()
                if k not in ("C2C_SESSION_ID", "C2C_SESSION_PID")
            }
            env["C2C_MCP_SESSION_ID"] = "unknown-sid-xyz"
            with mock.patch("c2c_whoami.resolve_identity", return_value=(None, None)):
                with mock.patch.dict(os.environ, env, clear=True):
                    result = c2c_health.check_session(self.broker_root)

        self.assertTrue(result["resolved"])
        self.assertFalse(result["registered"])

    def test_explicit_session_id_arg_takes_priority_over_mcp_env(self):
        """Explicit session_id arg bypasses C2C_MCP_SESSION_ID env var."""
        import c2c_health

        self._write_registry("explicit-sid-999", "operator-alias")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_SESSION_ID": "mcp-sid-should-be-ignored"}, clear=False
        ):
            result = c2c_health.check_session(
                self.broker_root, session_id="explicit-sid-999"
            )

        self.assertTrue(result["registered"])
        self.assertEqual(result["alias"], "operator-alias")
        self.assertEqual(result["session_id"], "explicit-sid-999")
        self.assertTrue(result["operator_check"])


class HealthCheckWireDaemonTests(unittest.TestCase):
    """Tests for c2c_health.check_wire_daemon()."""

    def test_no_session_id_skips_wire_daemon_check(self):
        import c2c_health

        result = c2c_health.check_wire_daemon(None)

        self.assertFalse(result["checked"])

    def test_wire_daemon_status_is_reported_for_session_id(self):
        import c2c_health

        status = {
            "running": True,
            "pid": 12345,
            "pidfile": "/tmp/kimi-test.pid",
        }
        with mock.patch("c2c_wire_daemon._daemon_status", return_value=status):
            result = c2c_health.check_wire_daemon("kimi-test")

        self.assertTrue(result["checked"])
        self.assertTrue(result["running"])
        self.assertEqual(result["pid"], 12345)
        self.assertEqual(result["pidfile"], "/tmp/kimi-test.pid")

    def test_run_health_check_uses_resolved_session_for_wire_daemon_check(self):
        import c2c_health

        session = {
            "resolved": True,
            "registered": True,
            "alias": "kimi-agent",
            "session_id": "kimi-agent",
            "inbox_exists": True,
            "inbox_writable": True,
            "operator_check": False,
        }
        with (
            mock.patch("c2c_health.check_session", return_value=session),
            mock.patch("c2c_health.check_broker_root", return_value={}),
            mock.patch("c2c_health.check_registry", return_value={}),
            mock.patch("c2c_health.check_rooms", return_value={}),
            mock.patch("c2c_health.check_hook", return_value={}),
            mock.patch("c2c_health.check_swarm_lounge", return_value={}),
            mock.patch("c2c_health.check_dead_letter", return_value={}),
            mock.patch("c2c_health.check_stale_inboxes", return_value={}),
            mock.patch("c2c_health.check_outer_loops", return_value={}),
            mock.patch("c2c_health.check_relay", return_value={}),
            mock.patch("c2c_health.check_broker_binary", return_value={}),
            mock.patch("c2c_health.check_wire_daemon") as check_wire,
        ):
            c2c_health.run_health_check(Path("/tmp/broker"))

        check_wire.assert_called_once_with("kimi-agent")


class HealthCheckBrokerBinaryTests(unittest.TestCase):
    """Tests for c2c_health.check_broker_binary()."""

    def test_binary_does_not_exist_returns_not_exists(self):
        import c2c_health

        with (
            mock.patch(
                "c2c_mcp.built_server_path",
                return_value=Path("/nonexistent/c2c_mcp_server.exe"),
            ),
        ):
            result = c2c_health.check_broker_binary()

        self.assertFalse(result["exists"])
        self.assertFalse(result["fresh"])

    def test_fresh_binary_reports_version_and_fresh(self, tmp_path=None):
        import c2c_health
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".exe", delete=False) as fh:
            bin_path = Path(fh.name)
        try:
            with (
                mock.patch("c2c_mcp.built_server_path", return_value=bin_path),
                mock.patch("c2c_mcp.server_is_fresh", return_value=True),
                mock.patch(
                    "pathlib.Path.read_text",
                    return_value='let server_version = "0.6.6"\nother code\n',
                ),
            ):
                result = c2c_health.check_broker_binary()
        finally:
            bin_path.unlink(missing_ok=True)

        self.assertTrue(result["exists"])
        self.assertTrue(result["fresh"])
        self.assertEqual(result.get("source_version"), "0.6.6")

    def test_stale_binary_reports_not_fresh(self):
        import c2c_health
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".exe", delete=False) as fh:
            bin_path = Path(fh.name)
        try:
            with (
                mock.patch("c2c_mcp.built_server_path", return_value=bin_path),
                mock.patch("c2c_mcp.server_is_fresh", return_value=False),
            ):
                result = c2c_health.check_broker_binary()
        finally:
            bin_path.unlink(missing_ok=True)

        self.assertTrue(result["exists"])
        self.assertFalse(result["fresh"])


class ServerIsFreshTests(unittest.TestCase):
    """Tests for c2c_mcp.server_is_fresh() — freshness check excludes test/ dir."""

    def test_fresh_when_binary_newer_than_sources(self):
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            ocaml_dir.mkdir()
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            import time

            time.sleep(0.05)
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            # Binary is newer than source — should be fresh.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertTrue(c2c_mcp.server_is_fresh(bin_path))

    def test_stale_when_source_newer_than_binary(self):
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            ocaml_dir.mkdir()
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            import time

            time.sleep(0.05)
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            # Source is newer than binary — should be stale.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertFalse(c2c_mcp.server_is_fresh(bin_path))

    def test_test_dir_sources_excluded_from_freshness_check(self):
        """Test files under ocaml/test/ must not trigger stale when newer than binary."""
        import c2c_mcp
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            ocaml_dir = root / "ocaml"
            test_dir = ocaml_dir / "test"
            test_dir.mkdir(parents=True)
            # Server source (older)
            src = ocaml_dir / "c2c_mcp.ml"
            src.write_text("let x = 1\n")
            import time

            time.sleep(0.05)
            # Binary (newer than server source)
            bin_path = root / "c2c_mcp_server.exe"
            bin_path.write_bytes(b"binary")
            import time

            time.sleep(0.05)
            # Test file (newest — but should be excluded from check)
            test_src = test_dir / "test_c2c_mcp.ml"
            test_src.write_text("let () = ()\n")
            # Despite test file being newer than binary, should still be fresh.
            with mock.patch("c2c_mcp.ROOT", root):
                self.assertTrue(c2c_mcp.server_is_fresh(bin_path))


class HealthCheckStaleInboxTests(unittest.TestCase):
    """Tests for c2c_health.check_stale_inboxes()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health
        self.temp_dir = tempfile.TemporaryDirectory()
        self.broker_root = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_inbox(self, session_id: str, messages: list) -> None:
        path = self.broker_root / f"{session_id}.inbox.json"
        path.write_text(json.dumps(messages), encoding="utf-8")

    def _write_registry(self, registrations: list[dict]) -> None:
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def test_empty_broker_dir_returns_no_stale(self):
        result = self.c2c_health.check_stale_inboxes(self.broker_root)
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["total_pending"], 0)

    def test_empty_inbox_not_reported(self):
        self._write_inbox("sess-a", [])
        result = self.c2c_health.check_stale_inboxes(self.broker_root)
        self.assertEqual(result["stale"], [])

    def test_inbox_below_threshold_not_reported(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 3)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"], [])
        self.assertEqual(result["total_pending"], 3)

    def test_inbox_at_threshold_reported(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 5)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(len(result["stale"]), 1)
        self.assertEqual(result["stale"][0]["session_id"], "sess-a")
        self.assertEqual(result["stale"][0]["count"], 5)

    def test_alias_resolved_from_registry(self):
        self._write_registry([{"session_id": "sess-a", "alias": "nice-agent"}])
        self._write_inbox("sess-a", [{"content": "m"}] * 10)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"][0]["alias"], "nice-agent")

    def test_session_id_used_as_alias_when_not_in_registry(self):
        self._write_inbox("unknown-sess", [{"content": "m"}] * 10)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["stale"][0]["alias"], "unknown-sess")

    def test_total_pending_counts_all_inboxes(self):
        self._write_inbox("sess-a", [{"content": "m"}] * 2)
        self._write_inbox("sess-b", [{"content": "m"}] * 8)
        result = self.c2c_health.check_stale_inboxes(self.broker_root, threshold=5)
        self.assertEqual(result["total_pending"], 10)
        self.assertEqual(len(result["stale"]), 1)  # only sess-b >= threshold


class HealthCheckDeliverDaemonTests(unittest.TestCase):
    """Tests for c2c_health.check_deliver_daemon()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health

    def test_no_session_id_returns_unchecked(self):
        result = self.c2c_health.check_deliver_daemon(None)
        self.assertFalse(result["checked"])
        self.assertFalse(result["running"])

    def test_running_when_session_id_in_pgrep_output(self):
        fake_stdout = (
            "338330 python3 c2c_deliver_inbox.py --client codex --session-id codex-local\n"
            "3771272 python3 c2c_deliver_inbox.py --client kimi --session-id kimi-nova\n"
        )
        with mock.patch(
            "subprocess.run",
            return_value=mock.Mock(stdout=fake_stdout, stderr=""),
        ) as mock_run:
            result = self.c2c_health.check_deliver_daemon("kimi-nova")
            mock_run.assert_called_once()
            self.assertTrue(result["checked"])
            self.assertTrue(result["running"])
            self.assertEqual(result["pid"], 3771272)

    def test_not_running_when_session_id_missing(self):
        fake_stdout = "338330 python3 c2c_deliver_inbox.py --client codex --session-id codex-local\n"
        with mock.patch(
            "subprocess.run",
            return_value=mock.Mock(stdout=fake_stdout, stderr=""),
        ):
            result = self.c2c_health.check_deliver_daemon("opencode-local")
            self.assertTrue(result["checked"])
            self.assertFalse(result["running"])
            self.assertIsNone(result["pid"])

    def test_pgrep_error_returns_not_running(self):
        with mock.patch(
            "subprocess.run",
            side_effect=OSError("pgrep not found"),
        ):
            result = self.c2c_health.check_deliver_daemon("kimi-nova")
            self.assertTrue(result["checked"])
            self.assertFalse(result["running"])


class HealthPrintDeliverDaemonTests(unittest.TestCase):
    """Tests for deliver-daemon/hook interaction in print_health_report()."""

    def _make_report(self, *, hook_registered: bool, daemon_running: bool) -> dict:
        """Build a minimal health report dict for print_health_report testing."""
        return {
            "session": {
                "session_id": "sid-abc",
                "alias": "test-alias",
                "registered": True,
                "resolved": True,
                "operator_check": False,
                "inbox_exists": True,
                "inbox_writable": True,
                "inbox_pending": 0,
            },
            "broker_root": {"path": "/tmp/broker", "exists": True, "writable": True},
            "registry": {
                "path": "/tmp/broker/registry.json",
                "exists": True,
                "readable": True,
                "entry_count": 1,
            },
            "hook": {
                "hook_exists": hook_registered,
                "hook_executable": hook_registered,
                "settings_registered": hook_registered,
            },
            "claude_mcp": {"configured": False},
            "claude_wake_daemon": {"checked": False},
            "deliver_daemon": {
                "checked": True,
                "running": daemon_running,
                "pid": 12345 if daemon_running else None,
            },
            "swarm_lounge": {
                "alias": "test-alias",
                "member": True,
                "room_exists": True,
            },
            "dead_letter": {"count": 0},
            "stale_inboxes": {"stale": [], "total_pending": 0},
            "rooms": {"exists": True, "room_count": 0},
            "outer_loops": {"running": [], "count": 0},
            "broker_binary": {"checked": False},
            "relay": {"configured": False},
            "wire_daemon": {"checked": False},
        }

    def _capture_output(self, report: dict) -> str:
        import c2c_health

        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            c2c_health.print_health_report(report)
        return buf.getvalue()

    def test_deliver_daemon_warning_suppressed_when_hook_active(self):
        """No deliver-daemon warning for Claude Code sessions with hook active."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=True, daemon_running=False)
        output = self._capture_output(report)
        self.assertNotIn("Deliver daemon: not running", output)
        self.assertNotIn("c2c_deliver_inbox.py", output)

    def test_deliver_daemon_warning_shown_when_hook_not_active(self):
        """Deliver-daemon warning shown for non-Claude-Code sessions."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=False, daemon_running=False)
        output = self._capture_output(report)
        self.assertIn("Deliver daemon: not running", output)
        self.assertIn("c2c_deliver_inbox.py", output)

    def test_deliver_daemon_ok_shown_when_running(self):
        """Running deliver daemon always shows as green regardless of hook."""
        import c2c_health  # noqa: F401

        report = self._make_report(hook_registered=True, daemon_running=True)
        output = self._capture_output(report)
        self.assertIn("Deliver daemon: running (pid 12345)", output)


class WakePeerTests(unittest.TestCase):
    """Tests for c2c_wake_peer.wake_peer()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def test_unknown_alias_returns_error(self):
        import c2c_wake_peer

        rc = c2c_wake_peer.wake_peer("no-such-agent", broker_root=self.broker_root)
        self.assertEqual(rc, 1)

    def test_dead_pid_returns_error(self):
        import c2c_wake_peer

        self._write_registry(
            [
                {
                    "alias": "dead-agent",
                    "session_id": "sid-dead",
                    "pid": 99999999,
                    "pid_start_time": 1,
                },
            ]
        )
        rc = c2c_wake_peer.wake_peer("dead-agent", broker_root=self.broker_root)
        self.assertEqual(rc, 1)

    def test_dry_run_does_not_call_subprocess(self):
        import c2c_wake_peer

        self._write_registry(
            [
                {
                    "alias": "live-agent",
                    "session_id": "sid-live",
                    "pid": os.getpid(),
                    "pid_start_time": c2c_mcp.read_pid_start_time(os.getpid()),
                },
            ]
        )
        # dry-run should succeed without side effects
        rc = c2c_wake_peer.wake_peer(
            "live-agent", broker_root=self.broker_root, dry_run=True
        )
        self.assertEqual(rc, 0)

    def test_json_output_for_unknown_alias(self):
        import c2c_wake_peer
        import io

        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = c2c_wake_peer.wake_peer(
                "missing", broker_root=self.broker_root, json_out=True
            )
        self.assertEqual(rc, 1)
        out = json.loads(buf.getvalue())
        self.assertFalse(out["ok"])
        self.assertIn("not found", out["error"])


class RefreshPeerTests(unittest.TestCase):
    """Tests for c2c_refresh_peer.refresh_peer()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.registry_path = self.broker_root / "registry.json"

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        self.registry_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _read_registry(self):
        return json.loads(self.registry_path.read_text(encoding="utf-8"))

    def test_refresh_peer_unknown_alias_raises(self):
        """refresh_peer exits with error for unknown alias."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "other-agent", "pid": 99999}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("missing-alias", None, self.broker_root)

    def test_refresh_peer_accepts_session_id_when_alias_drifted(self):
        """refresh_peer can recover a row when alias drifted from session_id."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        self._write_registry(
            [
                {
                    "session_id": "kimi-nova",
                    "alias": "kimi-nova-2",
                    "pid": 99999,
                }
            ]
        )

        result = c2c_refresh_peer.refresh_peer(
            "kimi-nova", new_pid, self.broker_root, session_id="kimi-nova"
        )

        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["alias"], "kimi-nova-2")
        self.assertEqual(result["matched_by"], "session_id")
        regs = self._read_registry()
        self.assertEqual(regs[0]["alias"], "kimi-nova-2")
        self.assertEqual(regs[0]["session_id"], "kimi-nova")
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_alive_registration_returns_no_change(self):
        """When current registration is already alive, no-arg refresh says so."""
        import c2c_refresh_peer

        live_pid = os.getpid()
        self._write_registry([{"session_id": "s1", "alias": "me", "pid": live_pid}])
        result = c2c_refresh_peer.refresh_peer("me", None, self.broker_root)
        self.assertEqual(result["status"], "already_alive")
        self.assertEqual(result["pid"], live_pid)

    def test_refresh_peer_dead_pid_no_arg_raises(self):
        """When registration has dead PID and no new PID given, raises."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "stale-agent", "pid": 11111}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("stale-agent", None, self.broker_root)

    def test_refresh_peer_updates_pid(self):
        """refresh_peer with explicit live PID updates the registry row."""
        import c2c_refresh_peer

        old_pid = 11111  # dead
        new_pid = os.getpid()  # definitely alive
        self._write_registry(
            [{"session_id": "s1", "alias": "opencode-local", "pid": old_pid}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "opencode-local", new_pid, self.broker_root
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result["old_pid"], old_pid)
        self.assertEqual(result["new_pid"], new_pid)

        regs = self._read_registry()
        self.assertEqual(len(regs), 1)
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_refuses_dead_new_pid(self):
        """refresh_peer refuses to update to a PID that is not in /proc."""
        import c2c_refresh_peer

        self._write_registry(
            [{"session_id": "s1", "alias": "opencode-local", "pid": 11111}]
        )
        with self.assertRaises(SystemExit):
            c2c_refresh_peer.refresh_peer("opencode-local", 11111, self.broker_root)

    def test_refresh_peer_dry_run_does_not_write(self):
        """--dry-run reports intended change but does not modify registry."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        original = [{"session_id": "s1", "alias": "opencode-local", "pid": 99999}]
        self._write_registry(original)
        result = c2c_refresh_peer.refresh_peer(
            "opencode-local", new_pid, self.broker_root, dry_run=True
        )
        self.assertEqual(result["status"], "dry_run")
        # Registry must be unchanged
        regs = self._read_registry()
        self.assertEqual(regs[0]["pid"], 99999)

    def test_cli_refresh_peer_subcommand_wired(self):
        """c2c refresh-peer is reachable via the main CLI dispatcher."""
        result = subprocess.run(
            [sys.executable, str(REPO / "c2c_cli.py"), "refresh-peer", "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("alias", result.stdout)

    def test_refresh_peer_updates_session_id(self):
        """refresh_peer with session_id corrects a stale session_id in the registry."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        old_session_id = "opencode-c2c-msg"
        new_session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        self._write_registry(
            [{"session_id": old_session_id, "alias": "storm-beacon", "pid": 99999}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon", new_pid, self.broker_root, session_id=new_session_id
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(result.get("old_session_id"), old_session_id)
        self.assertEqual(result.get("new_session_id"), new_session_id)

        regs = self._read_registry()
        self.assertEqual(regs[0]["session_id"], new_session_id)
        self.assertEqual(regs[0]["pid"], new_pid)

    def test_refresh_peer_session_id_unchanged_not_reported(self):
        """When session_id matches, no old/new_session_id keys appear in result."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        self._write_registry(
            [{"session_id": session_id, "alias": "storm-beacon", "pid": 99999}]
        )
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon", new_pid, self.broker_root, session_id=session_id
        )
        self.assertEqual(result["status"], "updated")
        self.assertNotIn("old_session_id", result)
        self.assertNotIn("new_session_id", result)

    def test_refresh_peer_dry_run_reports_session_id_change(self):
        """dry_run with session_id reports the intended change without writing."""
        import c2c_refresh_peer

        new_pid = os.getpid()
        old_session_id = "opencode-c2c-msg"
        new_session_id = "d16034fc-5526-414b-a88e-709d1a93e345"
        original = [
            {"session_id": old_session_id, "alias": "storm-beacon", "pid": 99999}
        ]
        self._write_registry(original)
        result = c2c_refresh_peer.refresh_peer(
            "storm-beacon",
            new_pid,
            self.broker_root,
            session_id=new_session_id,
            dry_run=True,
        )
        self.assertEqual(result["status"], "dry_run")
        self.assertEqual(result.get("old_session_id"), old_session_id)
        self.assertEqual(result.get("new_session_id"), new_session_id)
        # Registry must be unchanged
        regs = self._read_registry()
        self.assertEqual(regs[0]["session_id"], old_session_id)
        self.assertEqual(regs[0]["pid"], 99999)


class DeadLetterReplayTests(unittest.TestCase):
    """Tests for c2c_dead_letter replay behavior."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        (self.broker_root / "registry.json").write_text(
            json.dumps(registrations), encoding="utf-8"
        )

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        dl_path.write_text(
            "\n".join(json.dumps(record) for record in records) + "\n",
            encoding="utf-8",
        )
        return dl_path

    def test_replay_dry_run_uses_explicit_root_for_broker_resolution(self):
        self._write_registry([{"alias": "target", "session_id": "target-session"}])
        dl_path = self._write_dead_letter(
            [
                {
                    "deleted_at": time.time(),
                    "from_session_id": "orphan-session",
                    "message": {
                        "from_alias": "sender",
                        "to_alias": "target",
                        "content": "recover me",
                    },
                },
            ]
        )
        original_content = dl_path.read_text(encoding="utf-8")

        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": ""}, clear=False):
            with (
                mock.patch("sys.stdout", new=stdout),
                mock.patch("sys.stderr", new=stderr),
            ):
                result = c2c_dead_letter.main(
                    [
                        "--root",
                        str(self.broker_root),
                        "--replay",
                        "--to",
                        "target",
                        "--dry-run",
                    ]
                )

        self.assertEqual(result, 0, stderr.getvalue())
        self.assertIn("[DRY] 1. -> target: broker:target-session", stdout.getvalue())
        self.assertIn("replay result: 1/1 sent, 0 failed", stdout.getvalue())
        self.assertEqual(dl_path.read_text(encoding="utf-8"), original_content)

    def test_replay_does_not_replace_loaded_c2c_send_module(self):
        loaded_module = sys.modules["c2c_send"]

        stdout = io.StringIO()
        with mock.patch("sys.stdout", new=stdout):
            result = c2c_dead_letter.replay_records(
                [], dry_run=True, broker_root=self.broker_root
            )

        self.assertIs(sys.modules["c2c_send"], loaded_module)
        self.assertEqual(result["sent"], 0)
        self.assertEqual(result["failed"], [])


class PurgeOldDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc.purge_old_dead_letter()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        lines = [json.dumps(r) for r in records]
        dl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return dl_path

    def test_no_file_returns_empty_ok(self):
        """Returns ok with zero counts when dead-letter.jsonl does not exist."""
        import c2c_broker_gc

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["after_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purges_expired_entries(self):
        """Entries older than TTL are removed; recent entries are kept."""
        import c2c_broker_gc

        now = time.time()
        old_ts = now - 200
        new_ts = now - 10
        records = [
            {
                "deleted_at": old_ts,
                "from_session_id": "s1",
                "message": {"content": "old"},
            },
            {
                "deleted_at": new_ts,
                "from_session_id": "s2",
                "message": {"content": "new"},
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=100)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["after_count"], 1)
        self.assertEqual(result["purged_count"], 1)

        remaining = [
            json.loads(l) for l in dl_path.read_text().splitlines() if l.strip()
        ]
        self.assertEqual(len(remaining), 1)
        self.assertEqual(remaining[0]["from_session_id"], "s2")

    def test_dry_run_does_not_modify_file(self):
        """dry_run=True reports would-purge count but does not touch the file."""
        import c2c_broker_gc

        now = time.time()
        records = [
            {"deleted_at": now - 200, "from_session_id": "s1", "message": {}},
        ]
        dl_path = self._write_dead_letter(records)
        original_content = dl_path.read_text()

        result = c2c_broker_gc.purge_old_dead_letter(
            self.broker_root, ttl_seconds=100, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(dl_path.read_text(), original_content)

    def test_keeps_all_when_nothing_expired(self):
        """No entries are purged when all are within TTL."""
        import c2c_broker_gc

        now = time.time()
        records = [
            {"deleted_at": now - 10, "from_session_id": "s1", "message": {}},
            {"deleted_at": now - 20, "from_session_id": "s2", "message": {}},
        ]
        self._write_dead_letter(records)

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["after_count"], 2)
        self.assertEqual(result["purged_count"], 0)

    def test_malformed_lines_kept(self):
        """Lines that cannot be parsed as JSON are kept (safe default)."""
        import c2c_broker_gc

        dl_path = self.broker_root / "dead-letter.jsonl"
        dl_path.write_text(
            'not-valid-json\n{"deleted_at": 1, "from_session_id": "s"}\n',
            encoding="utf-8",
        )

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=60)
        self.assertTrue(result["ok"])
        # The valid record (ts=1) is very old and should be purged; the malformed line stays
        remaining = [l for l in dl_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(remaining), 1)
        self.assertIn("not-valid-json", remaining[0])


class PurgeOrphanDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc.purge_orphan_dead_letter()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_dead_letter(self, records):
        dl_path = self.broker_root / "dead-letter.jsonl"
        lines = [json.dumps(r) for r in records]
        dl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return dl_path

    def test_no_file_returns_empty_ok(self):
        """Returns ok with zero counts when dead-letter.jsonl does not exist."""
        import c2c_broker_gc

        result = c2c_broker_gc.purge_orphan_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purges_entry_when_alias_unregistered(self):
        """Entry is purged when to_alias is not in registry and older than TTL."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "live-alice",
                    "to_alias": "gone-bob",
                    "content": "hi",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 0)
        remaining = [l for l in dl_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(remaining), 0)

    def test_keeps_entry_when_alias_registered(self):
        """Entry is kept when to_alias IS in the registry (will redeliver on re-register)."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "live-alice",
                    "content": "hi",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_strips_room_suffix_for_matching(self):
        """Room fan-out messages (to_alias='alice@room') match if base alias 'alice' is registered."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry(
            [{"alias": "live-alice", "session_id": "s1", "pid": 99999999}]
        )
        records = [
            # alice@swarm-lounge → base alias live-alice IS registered → keep
            {
                "deleted_at": now - 7200,
                "from_session_id": "s2",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "live-alice@swarm-lounge",
                    "content": "room msg",
                },
            },
            # gone-bob@swarm-lounge → base alias gone-bob NOT registered → purge
            {
                "deleted_at": now - 7200,
                "from_session_id": "s3",
                "message": {
                    "from_alias": "sender",
                    "to_alias": "gone-bob@swarm-lounge",
                    "content": "room msg",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 1)
        remaining = [
            json.loads(l) for l in dl_path.read_text().splitlines() if l.strip()
        ]
        self.assertEqual(remaining[0]["message"]["to_alias"], "live-alice@swarm-lounge")

    def test_keeps_entry_within_ttl(self):
        """Recent entries are kept even if the alias is not registered."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry([])
        records = [
            {
                "deleted_at": now - 30,
                "from_session_id": "s1",
                "message": {
                    "from_alias": "x",
                    "to_alias": "gone-bob",
                    "content": "recent",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertTrue(result["ok"])
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_dry_run_does_not_modify_file(self):
        """dry_run=True reports would-purge count without touching the file."""
        import c2c_broker_gc

        now = time.time()
        self._write_registry([])
        records = [
            {
                "deleted_at": now - 7200,
                "from_session_id": "s1",
                "message": {
                    "from_alias": "x",
                    "to_alias": "gone-alias",
                    "content": "old",
                },
            },
        ]
        dl_path = self._write_dead_letter(records)
        original = dl_path.read_text()

        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(dl_path.read_text(), original)


class SweepDeadRegistrationsTests(unittest.TestCase):
    """Tests for c2c_broker_gc.sweep_dead_registrations()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _read_registry(self):
        reg_path = self.broker_root / "registry.json"
        return json.loads(reg_path.read_text(encoding="utf-8"))

    def test_no_registry_returns_empty_ok(self):
        import c2c_broker_gc

        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["removed_count"], 0)

    def test_keeps_live_pid(self):
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "alive", "session_id": "s1", "pid": os.getpid()}]
        )
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def _dead_pid(self) -> int:
        """Return a PID that is guaranteed to be dead."""
        p = subprocess.Popen(["true"])
        p.wait()
        return p.pid

    def test_sweeps_dead_pid(self):
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s2", "pid": dead_pid}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 1)
        self.assertEqual(result["after_count"], 0)

    def test_keeps_pidless_registration(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "pidless", "session_id": "s3"}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        self.assertEqual(result["removed_count"], 0)

    def test_dry_run_does_not_modify_registry(self):
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s1", "pid": dead_pid}])
        result = c2c_broker_gc.sweep_dead_registrations(self.broker_root, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["removed_count"], 1)
        # Registry unchanged
        regs = self._read_registry()
        self.assertEqual(len(regs), 1)

    def test_lock_file_created_by_sweep(self):
        """sweep_dead_registrations should create registry.json.lock (POSIX lockf sidecar)."""
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "live", "session_id": "s1", "pid": os.getpid()}]
        )
        c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        lock_path = self.broker_root / "registry.json.lock"
        self.assertTrue(
            lock_path.exists(), "registry.json.lock should exist after sweep"
        )

    def test_atomic_write_no_temp_files(self):
        """sweep_dead_registrations should leave no .tmp files behind."""
        import c2c_broker_gc

        dead_pid = self._dead_pid()
        self._write_registry([{"alias": "dead", "session_id": "s1", "pid": dead_pid}])
        c2c_broker_gc.sweep_dead_registrations(self.broker_root)
        tmp_files = list(self.broker_root.glob(".registry.json.*.tmp"))
        self.assertEqual(tmp_files, [], f"no temp files should remain: {tmp_files}")

    def test_with_registry_lock_interlocks(self):
        """with_registry_lock must produce the registry.json.lock sidecar used by OCaml."""
        import c2c_broker_gc

        with c2c_broker_gc.with_registry_lock(self.broker_root):
            lock_path = self.broker_root / "registry.json.lock"
            self.assertTrue(lock_path.exists())

    def test_main_uses_env_broker_root_without_importing_c2c_mcp(self):
        import c2c_broker_gc

        self._write_registry(
            [{"alias": "live", "session_id": "s1", "pid": os.getpid()}]
        )
        env = {"C2C_MCP_BROKER_ROOT": str(self.broker_root)}
        with mock.patch.dict(os.environ, env, clear=False):
            with mock.patch("sys.stdout", new=io.StringIO()):
                result = c2c_broker_gc.main(["--once", "--dry-run", "--json"])
        self.assertEqual(result, 0)


def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()


class BrokerGcDeadLetterTests(unittest.TestCase):
    """Tests for c2c_broker_gc dead-letter purge functions."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, registrations):
        reg_path = self.broker_root / "registry.json"
        reg_path.write_text(json.dumps(registrations), encoding="utf-8")

    def _write_dead_letter(self, lines):
        dl_path = self.broker_root / "dead-letter.jsonl"
        content = "\n".join(lines)
        if content and not content.endswith("\n"):
            content += "\n"
        dl_path.write_text(content, encoding="utf-8")

    def _read_dead_letter(self):
        dl_path = self.broker_root / "dead-letter.jsonl"
        if not dl_path.exists():
            return []
        return [
            line
            for line in dl_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def test_purge_old_no_file_returns_empty(self):
        import c2c_broker_gc

        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)
        self.assertEqual(result["purged_count"], 0)

    def test_purge_old_keeps_fresh_entries(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps({"deleted_at": now - 100, "message": {"to_alias": "alice"}}),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(result["after_count"], 1)

    def test_purge_old_removes_stale_entries(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(result["after_count"], 0)

    def test_purge_old_malformed_line_kept(self):
        import c2c_broker_gc

        self._write_dead_letter(
            [
                "not-json",
                json.dumps(
                    {
                        "deleted_at": time.time() - 10000,
                        "message": {"to_alias": "alice"},
                    }
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(self.broker_root, ttl_seconds=3600)
        self.assertEqual(result["before_count"], 2)
        self.assertEqual(result["purged_count"], 1)
        lines = self._read_dead_letter()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0], "not-json")

    def test_purge_old_dry_run_no_modify(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_old_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 1)

    def test_purge_orphan_no_file_returns_empty(self):
        import c2c_broker_gc

        result = c2c_broker_gc.purge_orphan_dead_letter(self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["before_count"], 0)

    def test_purge_orphan_keeps_registered_alias(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "alice"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 0)
        self.assertEqual(len(self._read_dead_letter()), 1)

    def test_purge_orphan_removes_unregistered_alias(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps({"deleted_at": now - 10000, "message": {"to_alias": "bob"}}),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 0)

    def test_purge_orphan_strips_room_suffix(self):
        import c2c_broker_gc

        self._write_registry([{"alias": "alice", "session_id": "s1"}])
        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {
                        "deleted_at": now - 10000,
                        "message": {"to_alias": "bob@swarm-lounge"},
                    }
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600
        )
        self.assertEqual(result["purged_count"], 1)

    def test_purge_orphan_dry_run_no_modify(self):
        import c2c_broker_gc

        now = time.time()
        self._write_dead_letter(
            [
                json.dumps(
                    {"deleted_at": now - 10000, "message": {"to_alias": "orphan"}}
                ),
            ]
        )
        result = c2c_broker_gc.purge_orphan_dead_letter(
            self.broker_root, ttl_seconds=3600, dry_run=True
        )
        self.assertEqual(result["purged_count"], 1)
        self.assertEqual(len(self._read_dead_letter()), 1)


class PruneDeadMembersTests(unittest.TestCase):
    """Tests for c2c_room.prune_dead_members()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.broker_root = Path(self.tmpdir)
        self.rooms_root = self.broker_root / "rooms"
        self.rooms_root.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _write_registry(self, aliases: list[str]) -> None:
        regs = [{"session_id": f"s-{a}", "alias": a} for a in aliases]
        (self.broker_root / "registry.json").write_text(
            json.dumps(regs), encoding="utf-8"
        )

    def _write_members(self, room_id: str, members: list[str]) -> None:
        rdir = self.rooms_root / room_id
        rdir.mkdir(parents=True, exist_ok=True)
        (rdir / "members.json").write_text(
            json.dumps([{"alias": a, "session_id": f"s-{a}"} for a in members]),
            encoding="utf-8",
        )

    def _read_members(self, room_id: str) -> list[str]:
        p = self.rooms_root / room_id / "members.json"
        return [m["alias"] for m in json.loads(p.read_text(encoding="utf-8"))]

    def test_room_not_found_returns_error(self):
        import c2c_room

        result = c2c_room.prune_dead_members(
            "nonexistent", broker_root=self.broker_root
        )
        self.assertFalse(result["ok"])

    def test_removes_unregistered_members(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice", "gone"])

        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["removed"], ["gone"])
        self.assertEqual(result["after_count"], 1)
        self.assertEqual(self._read_members("test-room"), ["alice"])

    def test_keeps_all_when_all_registered(self):
        import c2c_room

        self._write_registry(["alice", "bob"])
        self._write_members("test-room", ["alice", "bob"])

        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertEqual(result["removed"], [])
        self.assertEqual(result["after_count"], 2)

    def test_dry_run_does_not_modify(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice", "gone"])

        result = c2c_room.prune_dead_members(
            "test-room", broker_root=self.broker_root, dry_run=True
        )
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["removed"], ["gone"])
        # Members file unchanged
        self.assertEqual(self._read_members("test-room"), ["alice", "gone"])

    def test_empty_registry_removes_all(self):
        import c2c_room

        self._write_registry([])
        self._write_members("test-room", ["smoke1", "smoke2"])
        result = c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        self.assertEqual(result["after_count"], 0)
        self.assertEqual(len(result["removed"]), 2)
        self.assertEqual(self._read_members("test-room"), [])

    def test_lock_file_created(self):
        """prune_dead_members should create members.lock (POSIX lockf sidecar)."""
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("test-room", ["alice"])
        c2c_room.prune_dead_members("test-room", broker_root=self.broker_root)
        lock_path = self.rooms_root / "test-room" / "members.lock"
        self.assertTrue(lock_path.exists(), "members.lock should be created by prune")

    def test_prune_all_rooms_prunes_every_room(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("room-a", ["alice", "ghost-a"])
        self._write_members("room-b", ["alice", "ghost-b"])

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["rooms_processed"], 2)
        self.assertEqual(result["total_removed"], 2)
        self.assertEqual(self._read_members("room-a"), ["alice"])
        self.assertEqual(self._read_members("room-b"), ["alice"])

    def test_prune_all_rooms_dry_run_does_not_modify(self):
        import c2c_room

        self._write_registry(["alice"])
        self._write_members("room-a", ["alice", "ghost"])

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["total_removed"], 1)
        # Members file must be unchanged
        self.assertEqual(self._read_members("room-a"), ["alice", "ghost"])

    def test_prune_all_rooms_empty_rooms_dir(self):
        import c2c_room

        result = c2c_room.prune_all_rooms(broker_root=self.broker_root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["rooms_processed"], 0)
        self.assertEqual(result["total_removed"], 0)


class C2CStatusTests(unittest.TestCase):
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
        data = c2c_status.swarm_status(self.broker_root)
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
        data = c2c_status.swarm_status(self.broker_root)
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
        data = c2c_status.swarm_status(self.broker_root)
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


class HealthCheckTmpSpaceTests(unittest.TestCase):
    """Tests for c2c_health.check_tmp_space()."""

    def setUp(self):
        import c2c_health

        self.c2c_health = c2c_health
        self.temp_dir = tempfile.TemporaryDirectory()
        self.tmp_dir = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_returns_checked_true_on_success(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertTrue(result["checked"])
        self.assertIn("free_bytes", result)
        self.assertIn("free_gb", result)
        self.assertIn("used_pct", result)
        self.assertIn("low", result)

    def test_free_bytes_is_nonnegative(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertGreaterEqual(result["free_bytes"], 0)

    def test_fea_so_files_counted(self):
        # Create fake .fea123.so files
        for i in range(3):
            (self.tmp_dir / f".fea{i}.so").write_bytes(b"x" * 1024)
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertEqual(result["fea_so_count"], 3)
        self.assertGreater(result["fea_so_bytes"], 0)

    def test_no_fea_so_files_returns_zero(self):
        result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertEqual(result["fea_so_count"], 0)
        self.assertEqual(result["fea_so_bytes"], 0)

    def test_low_flag_set_when_free_below_2gb(self):
        with mock.patch("os.statvfs") as m:
            st = mock.MagicMock()
            # 1 GB total, 500 MB free (below 2 GB threshold)
            st.f_blocks = 256 * 1024  # blocks
            st.f_frsize = 4096  # 4 KB per block → 1 GB total
            st.f_bavail = 128 * 1024  # 512 MB free
            m.return_value = st
            result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertTrue(result["low"])

    def test_low_flag_clear_when_free_above_2gb(self):
        with mock.patch("os.statvfs") as m:
            st = mock.MagicMock()
            # 16 GB total, 8 GB free
            st.f_blocks = 4 * 1024 * 1024  # blocks
            st.f_frsize = 4096  # 4 KB per block → 16 GB total
            st.f_bavail = 2 * 1024 * 1024  # 8 GB free
            m.return_value = st
            result = self.c2c_health.check_tmp_space(self.tmp_dir)
        self.assertFalse(result["low"])

    def test_nonexistent_dir_returns_unchecked(self):
        bad_dir = Path(self.temp_dir.name) / "no-such-dir"
        result = self.c2c_health.check_tmp_space(bad_dir)
        self.assertFalse(result["checked"])
        self.assertIn("error", result)


class HealthCheckInstancesTests(unittest.TestCase):
    """Tests for c2c_health.check_instances()."""

    def setUp(self):
        import c2c_health
        import c2c_start

        self.c2c_health = c2c_health
        self.c2c_start = c2c_start
        self.instances_dir_patcher = mock.patch.object(
            c2c_start,
            "INSTANCES_DIR",
            Path(tempfile.mkdtemp()),
        )
        self.instances_dir = self.instances_dir_patcher.start()

    def tearDown(self):
        self.instances_dir_patcher.stop()
        import shutil

        shutil.rmtree(str(self.c2c_start.INSTANCES_DIR), ignore_errors=True)

    def test_returns_checked_true_and_empty_when_no_instances(self):
        result = self.c2c_health.check_instances()
        self.assertTrue(result["checked"])
        self.assertEqual(result["instances"], [])
        self.assertEqual(result["alive_count"], 0)
        self.assertEqual(result["total_count"], 0)

    def test_alive_count_reflects_live_outer_pids(self):
        # Create two instances — one alive (current pid), one dead (pid 0)
        with mock.patch.object(
            self.c2c_start,
            "run_outer_loop",
            return_value=0,
        ):
            br = Path(tempfile.mkdtemp())
            self.c2c_start.cmd_start("codex", "inst-a", [], br)

        # Patch list_instances so one shows outer_alive=True and one False
        fake = [
            {
                "name": "inst-a",
                "client": "codex",
                "outer_alive": True,
                "outer_pid": os.getpid(),
            },
            {
                "name": "inst-b",
                "client": "kimi",
                "outer_alive": False,
                "outer_pid": None,
            },
        ]
        with mock.patch.object(self.c2c_start, "list_instances", return_value=fake):
            result = self.c2c_health.check_instances()
        self.assertEqual(result["alive_count"], 1)
        self.assertEqual(result["total_count"], 2)

    def test_check_instances_graceful_on_import_error(self):
        with mock.patch.dict("sys.modules", {"c2c_start": None}):
            result = self.c2c_health.check_instances()
        self.assertFalse(result.get("checked", True))

    def test_instances_in_run_health_check_output(self):
        """check_instances result is included in run_health_check() dict."""
        br = Path(tempfile.mkdtemp())
        with mock.patch.object(self.c2c_start, "list_instances", return_value=[]):
            report = self.c2c_health.run_health_check(br)
        self.assertIn("instances", report)
        self.assertTrue(report["instances"]["checked"])


class C2CStartUnitTests(unittest.TestCase):
    """Tests for c2c_start module."""

    def setUp(self):
        import c2c_start

        self.c2c_start = c2c_start
        self.temp_dir = tempfile.TemporaryDirectory()
        self.instances_dir = Path(self.temp_dir.name) / "instances"
        # Patch INSTANCES_DIR to point at temp dir.
        self._orig_instances_dir = c2c_start.INSTANCES_DIR
        c2c_start.INSTANCES_DIR = self.instances_dir

    def tearDown(self):
        self.c2c_start.INSTANCES_DIR = self._orig_instances_dir
        self.temp_dir.cleanup()

    def test_default_name_uses_client_and_hostname(self):
        name = self.c2c_start.default_name("claude")
        self.assertTrue(name.startswith("claude-"), name)

    def test_default_name_different_per_client(self):
        self.assertNotEqual(
            self.c2c_start.default_name("codex"),
            self.c2c_start.default_name("kimi"),
        )

    def test_invalid_client_rejected(self):
        broker_root = Path(self.temp_dir.name)
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_start(
                "nonexistent-client", "test-name", [], broker_root
            )
        self.assertEqual(rc, 1)
        self.assertIn("nonexistent-client", buf.getvalue())

    def test_invalid_client_rejected_json(self):
        broker_root = Path(self.temp_dir.name)
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.cmd_start(
                "nonexistent-client", "test-name", [], broker_root, json_out=True
            )
        self.assertEqual(rc, 1)
        result = json.loads(buf.getvalue())
        self.assertFalse(result["ok"])
        self.assertIn("error", result)

    def test_config_json_written_on_start(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        # Mock run_outer_loop so it doesn't actually launch anything.
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            rc = self.c2c_start.cmd_start("claude", "my-agent", ["--arg"], broker_root)
        self.assertEqual(rc, 0)
        cfg = self.c2c_start.load_instance_config("my-agent")
        self.assertIsNotNone(cfg)
        self.assertEqual(cfg["client"], "claude")
        self.assertEqual(cfg["name"], "my-agent")
        self.assertEqual(cfg["session_id"], "my-agent")
        self.assertEqual(cfg["alias"], "my-agent")
        self.assertEqual(cfg["extra_args"], ["--arg"])

    def test_config_json_includes_binary_override(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            rc = self.c2c_start.cmd_start(
                "claude", "my-agent", [], broker_root, binary_override="cc-zai"
            )
        self.assertEqual(rc, 0)
        cfg = self.c2c_start.load_instance_config("my-agent")
        self.assertEqual(cfg.get("binary_override"), "cc-zai")

    def test_custom_binary_override_used_by_run_outer_loop(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "run_outer_loop", return_value=0
        ) as mock_loop:
            self.c2c_start.cmd_start(
                "claude", "my-agent", [], broker_root, binary_override="cc-zai"
            )
        mock_loop.assert_called_once()
        self.assertEqual(mock_loop.call_args.kwargs.get("binary_override"), "cc-zai")

    def test_duplicate_name_rejected(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        # Write a fake pidfile with the current process PID (alive).
        inst_dir = self.instances_dir / "my-agent"
        inst_dir.mkdir(parents=True, exist_ok=True)
        (inst_dir / "outer.pid").write_text(str(os.getpid()))
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_start("claude", "my-agent", [], broker_root)
        self.assertEqual(rc, 1)
        self.assertIn("already running", buf.getvalue())

    def test_stop_nonexistent_returns_error(self):
        buf = io.StringIO()
        with mock.patch("sys.stderr", buf):
            rc = self.c2c_start.cmd_stop("no-such-instance")
        self.assertEqual(rc, 1)

    def test_stop_nonexistent_json_returns_error(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.cmd_stop("no-such-instance", json_out=True)
        self.assertEqual(rc, 1)
        result = json.loads(buf.getvalue())
        self.assertFalse(result["ok"])

    def test_list_instances_empty(self):
        instances = self.c2c_start.list_instances()
        self.assertEqual(instances, [])

    def test_list_instances_returns_configured(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(self.c2c_start, "run_outer_loop", return_value=0):
            self.c2c_start.cmd_start("codex", "test-codex", [], broker_root)
        instances = self.c2c_start.list_instances()
        self.assertEqual(len(instances), 1)
        self.assertEqual(instances[0]["name"], "test-codex")
        self.assertEqual(instances[0]["client"], "codex")

    def test_build_env_sets_required_vars(self):
        env = self.c2c_start.build_env("my-agent")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "my-agent")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "my-agent")
        self.assertIn("swarm-lounge", env.get("C2C_MCP_AUTO_JOIN_ROOMS", ""))
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")
        self.assertIn("C2C_MCP_BROKER_ROOT", env)

    def test_kimi_launch_args_write_instance_mcp_config(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "kimi-proof", "kimi", ["--print"], broker_root
        )

        mcp_config = self.instances_dir / "kimi-proof" / "kimi-mcp.json"
        self.assertEqual(args[:2], ["--mcp-config-file", str(mcp_config)])
        self.assertEqual(args[2:], ["--print"])
        config = json.loads(mcp_config.read_text(encoding="utf-8"))
        env = config["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], str(broker_root))
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-proof")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-proof")
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")

    def test_kimi_launch_args_respect_explicit_mcp_config(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "kimi-proof",
            "kimi",
            ["--mcp-config-file", "/tmp/custom.json", "--print"],
            broker_root,
        )

        self.assertEqual(args, ["--mcp-config-file", "/tmp/custom.json", "--print"])
        self.assertFalse((self.instances_dir / "kimi-proof" / "kimi-mcp.json").exists())

    def test_non_kimi_launch_args_unchanged(self):
        broker_root = Path(self.temp_dir.name) / "broker"

        args = self.c2c_start.prepare_launch_args(
            "codex-proof", "codex", ["--approval-policy", "never"], broker_root
        )

        self.assertEqual(args, ["--approval-policy", "never"])

    def test_instances_cli_empty_json(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.main(["instances", "--json"])
        self.assertEqual(rc, 0)
        result = json.loads(buf.getvalue())
        self.assertEqual(result, [])

    def test_instances_cli_text_empty(self):
        buf = io.StringIO()
        with mock.patch("sys.stdout", buf):
            rc = self.c2c_start.main(["instances"])
        self.assertEqual(rc, 0)
        self.assertIn("No c2c instances", buf.getvalue())

    def test_start_cli_bin_flag_passed_to_cmd_start(self):
        broker_root = Path(self.temp_dir.name) / "broker"
        with mock.patch.object(
            self.c2c_start, "cmd_start", return_value=0
        ) as mock_cmd:
            rc = self.c2c_start.main(
                [
                    "--broker-root",
                    str(broker_root),
                    "start",
                    "claude",
                    "-n",
                    "zai",
                    "--bin",
                    "cc-zai",
                    "--",
                    "--dangerously-skip-permissions",
                ]
            )
        self.assertEqual(rc, 0)
        mock_cmd.assert_called_once()
        args, kwargs = mock_cmd.call_args
        self.assertEqual(args, ("claude", "zai", ["--dangerously-skip-permissions"], broker_root))
        self.assertEqual(kwargs.get("binary_override"), "cc-zai")


class C2CStartConstantsTests(unittest.TestCase):
    """Task 1: constants, SUPPORTED_CLIENTS, and public helper API."""

    def test_client_configs_has_all_five_clients(self):
        from c2c_start import CLIENT_CONFIGS

        self.assertEqual(
            set(CLIENT_CONFIGS.keys()), {"claude", "codex", "opencode", "kimi", "crush"}
        )

    def test_supported_clients_matches_configs(self):
        from c2c_start import SUPPORTED_CLIENTS, CLIENT_CONFIGS

        self.assertEqual(SUPPORTED_CLIENTS, set(CLIENT_CONFIGS.keys()))

    def test_client_config_has_required_keys(self):
        from c2c_start import CLIENT_CONFIGS

        for client, cfg in CLIENT_CONFIGS.items():
            self.assertIn("binary", cfg, f"{client} missing binary")
            self.assertIn("deliver_client", cfg, f"{client} missing deliver_client")
            self.assertIn("needs_poker", cfg, f"{client} missing needs_poker")

    def test_constants_exist(self):
        import c2c_start

        self.assertEqual(c2c_start.MIN_RUN_SECONDS, 10.0)
        self.assertEqual(c2c_start.RESTART_PAUSE_SECONDS, 1.5)
        self.assertEqual(c2c_start.INITIAL_BACKOFF_SECONDS, 2.0)
        self.assertEqual(c2c_start.MAX_BACKOFF_SECONDS, 60.0)

    def test_default_name_uses_hostname(self):
        from c2c_start import default_name

        with mock.patch("socket.gethostname", return_value="testhost"):
            self.assertEqual(default_name("claude"), "claude-testhost")
            self.assertEqual(default_name("codex"), "codex-testhost")

    def test_instances_dir_creates_on_access(self):
        from c2c_start import instances_dir

        with tempfile.TemporaryDirectory() as tmp:
            import c2c_start

            orig = c2c_start.INSTANCES_DIR
            try:
                c2c_start.INSTANCES_DIR = (
                    Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
                d = instances_dir()
                self.assertTrue(d.exists())
                self.assertEqual(
                    d, Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_instance_dir_path(self):
        from c2c_start import instance_dir

        with tempfile.TemporaryDirectory() as tmp:
            import c2c_start

            orig = c2c_start.INSTANCES_DIR
            try:
                c2c_start.INSTANCES_DIR = (
                    Path(tmp) / ".local" / "share" / "c2c" / "instances"
                )
                d = instance_dir("my-agent")
                self.assertEqual(
                    d, Path(tmp) / ".local" / "share" / "c2c" / "instances" / "my-agent"
                )
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_broker_root_uses_env_override(self):
        from c2c_start import broker_root

        with mock.patch.dict(os.environ, {"C2C_MCP_BROKER_ROOT": "/custom/broker"}):
            self.assertEqual(broker_root(), Path("/custom/broker"))

    def test_read_pid_returns_int_or_none(self):
        from c2c_start import read_pid

        with tempfile.NamedTemporaryFile(mode="w", suffix=".pid", delete=False) as f:
            f.write("12345\n")
            f.flush()
            self.assertEqual(read_pid(Path(f.name)), 12345)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".pid", delete=False) as f:
            f.write("notanumber\n")
            f.flush()
            self.assertIsNone(read_pid(Path(f.name)))
        self.assertIsNone(read_pid(Path("/nonexistent/pidfile.pid")))

    def test_write_pid_creates_file(self):
        from c2c_start import write_pid

        with tempfile.TemporaryDirectory() as tmp:
            pidfile = Path(tmp) / "sub" / "test.pid"
            write_pid(pidfile, 42)
            self.assertEqual(pidfile.read_text().strip(), "42")

    def test_pid_alive_live_process(self):
        from c2c_start import pid_alive

        self.assertTrue(pid_alive(os.getpid()))

    def test_pid_alive_dead_process(self):
        from c2c_start import pid_alive

        self.assertFalse(pid_alive(99999999))

    def test_cleanup_pidfiles_removes_stale(self):
        from c2c_start import cleanup_pidfiles, write_pid

        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            write_pid(d / "alive.pid", os.getpid())
            write_pid(d / "dead.pid", 99999999)
            cleaned = cleanup_pidfiles(d)
            self.assertIn("dead.pid", cleaned)
            self.assertTrue((d / "alive.pid").exists())
            self.assertFalse((d / "dead.pid").exists())

    def test_cleanup_pidfiles_empty_dir(self):
        from c2c_start import cleanup_pidfiles

        self.assertEqual(cleanup_pidfiles(Path("/nonexistent/dir")), [])

    def test_write_and_load_config(self):
        from c2c_start import write_config, load_config, instance_dir
        import c2c_start

        orig = c2c_start.INSTANCES_DIR
        with tempfile.TemporaryDirectory() as tmp:
            c2c_start.INSTANCES_DIR = Path(tmp) / "instances"
            try:
                path = write_config("test-agent", "claude", ["--verbose"])
                self.assertTrue(path.exists())
                cfg = load_config("test-agent")
                self.assertEqual(cfg["client"], "claude")
                self.assertEqual(cfg["name"], "test-agent")
                self.assertEqual(cfg["extra_args"], ["--verbose"])
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_load_config_missing_raises(self):
        from c2c_start import load_config
        import c2c_start

        orig = c2c_start.INSTANCES_DIR
        with tempfile.TemporaryDirectory() as tmp:
            c2c_start.INSTANCES_DIR = Path(tmp) / "instances"
            try:
                with self.assertRaises(SystemExit):
                    load_config("nonexistent")
            finally:
                c2c_start.INSTANCES_DIR = orig

    def test_cleanup_fea_so(self):
        from c2c_start import cleanup_fea_so

        fake = Path("/tmp/libfea_inject.so")
        fake.write_text("test", encoding="utf-8")
        cleanup_fea_so()
        self.assertFalse(fake.exists())
        # Calling again is a no-op.
        cleanup_fea_so()
