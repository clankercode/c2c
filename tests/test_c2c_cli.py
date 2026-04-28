import io
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
NATIVE_C2C = REPO / "_build" / "default" / "ocaml" / "cli" / "c2c.exe"
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_mcp
import c2c_configure_codex
from c2c_registry import save_registry


CLI_TIMEOUT_SECONDS = 5
AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


def run_cli(command, *args, env=None):
    return run_cli_in_root(REPO, command, *args, env=env)


def run_native_cli(*args, env=None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(NATIVE_C2C), *args],
        cwd=REPO,
        env=merged_env,
        capture_output=True,
        text=True,
        timeout=CLI_TIMEOUT_SECONDS,
    )


def load_repo_c2c_module():
    loader = importlib.machinery.SourceFileLoader("repo_c2c_entry", str(REPO / "c2c"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


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
        "c2c_pty_inject.py",
        "c2c_setcap.py",
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

    def native_home_env(self, home_name: str):
        home_dir = Path(self.temp_dir.name) / home_name
        instances_dir = home_dir / ".local" / "share" / "c2c" / "instances"
        instances_dir.mkdir(parents=True, exist_ok=True)
        env = dict(self.env)
        env["HOME"] = str(home_dir)
        return env, instances_dir

    @staticmethod
    def write_instance_dir(
        instances_dir: Path,
        name: str,
        *,
        client: str = "codex",
        created_at: float,
        outer_pid: int | None = None,
    ) -> Path:
        inst_dir = instances_dir / name
        inst_dir.mkdir(parents=True, exist_ok=True)
        config = {
            "name": name,
            "client": client,
            "session_id": name,
            "resume_session_id": name,
            "alias": name,
            "extra_args": [],
            "created_at": created_at,
            "broker_root": str(instances_dir.parent.parent.parent / "broker"),
            "auto_join_rooms": "swarm-lounge",
        }
        (inst_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")
        if outer_pid is not None:
            (inst_dir / "outer.pid").write_text(f"{outer_pid}\n", encoding="utf-8")
        return inst_dir

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

    def test_configure_codex_block_omits_session_and_auto_register_env(self):
        block = c2c_configure_codex.build_toml_block(
            Path("/tmp/broker-root"),
            "codex-test-alias",
        )

        self.assertIn('C2C_MCP_BROKER_ROOT = "/tmp/broker-root"', block)
        self.assertIn('C2C_MCP_AUTO_JOIN_ROOMS = "swarm-lounge"', block)
        self.assertNotIn("C2C_MCP_SESSION_ID", block)
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", block)
        self.assertIn('[mcp_servers.c2c.tools.register]', block)
        self.assertIn('approval_mode = "auto"', block)

    def test_configure_codex_cli_output_does_not_claim_restart_auto_register(self):
        home_dir = Path(self.temp_dir.name) / "home"
        broker_root = Path(self.temp_dir.name) / "broker"
        home_dir.mkdir(parents=True, exist_ok=True)
        broker_root.mkdir(parents=True, exist_ok=True)

        env = dict(self.env)
        env["HOME"] = str(home_dir)

        result = subprocess.run(
            [
                sys.executable,
                str(REPO / "c2c_configure_codex.py"),
                "--alias",
                "codex-test-alias",
                "--broker-root",
                str(broker_root),
            ],
            cwd=REPO,
            env=env,
            capture_output=True,
            text=True,
            timeout=CLI_TIMEOUT_SECONDS,
        )

        self.assertEqual(result_code(result), 0)
        self.assertIn("wrote [mcp_servers.c2c]", result.stdout)
        self.assertIn(f"broker_root: {broker_root}", result.stdout)
        self.assertIn("alias:       codex-test-alias", result.stdout)
        self.assertNotIn("auto-registers on every restart", result.stdout)
        config_text = (home_dir / ".codex" / "config.toml").read_text(
            encoding="utf-8"
        )
        self.assertIn(f'C2C_MCP_BROKER_ROOT = "{broker_root}"', config_text)
        self.assertIn('C2C_MCP_AUTO_JOIN_ROOMS = "swarm-lounge"', config_text)
        self.assertNotIn("C2C_MCP_SESSION_ID", config_text)
        self.assertNotIn("C2C_MCP_AUTO_REGISTER_ALIAS", config_text)

    def test_install_codex_headless_aliases_to_codex_setup(self):
        home_dir = Path(self.temp_dir.name) / "home"
        broker_root = Path(self.temp_dir.name) / "broker"
        home_dir.mkdir(parents=True, exist_ok=True)
        broker_root.mkdir(parents=True, exist_ok=True)

        env = dict(self.env)
        env["HOME"] = str(home_dir)

        result = self.invoke_cli(
            "c2c",
            "install",
            "codex-headless",
            "--broker-root",
            str(broker_root),
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["client"], "codex")

    def test_native_install_codex_writes_client_type_env(self):
        home_dir = Path(self.temp_dir.name) / "home"
        broker_root = Path(self.temp_dir.name) / "broker"
        home_dir.mkdir(parents=True, exist_ok=True)
        broker_root.mkdir(parents=True, exist_ok=True)

        env = dict(self.env)
        env["HOME"] = str(home_dir)

        self.assertTrue(NATIVE_C2C.exists(), NATIVE_C2C)
        result = run_native_cli(
            "install",
            "codex",
            "--broker-root",
            str(broker_root),
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        config_text = (home_dir / ".codex" / "config.toml").read_text(
            encoding="utf-8"
        )
        self.assertIn('C2C_MCP_CLIENT_TYPE = "codex"', config_text)

    def test_native_install_codex_prefers_installed_mcp_server_command(self):
        home_dir = Path(self.temp_dir.name) / "home-codex-installed-mcp"
        broker_root = Path(self.temp_dir.name) / "broker-codex-installed-mcp"
        fake_bin = Path(self.temp_dir.name) / "bin"
        home_dir.mkdir(parents=True, exist_ok=True)
        broker_root.mkdir(parents=True, exist_ok=True)
        fake_bin.mkdir(parents=True, exist_ok=True)
        mcp_server = fake_bin / "c2c-mcp-server"
        mcp_server.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        mcp_server.chmod(0o755)

        env = dict(self.env)
        env["HOME"] = str(home_dir)
        env["PATH"] = f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"

        self.assertTrue(NATIVE_C2C.exists(), NATIVE_C2C)
        result = run_native_cli(
            "install",
            "codex",
            "--broker-root",
            str(broker_root),
            "--json",
            env=env,
        )

        self.assertEqual(result_code(result), 0, result.stderr)
        config_text = (home_dir / ".codex" / "config.toml").read_text(
            encoding="utf-8"
        )
        self.assertIn('command = "c2c-mcp-server"', config_text)
        self.assertIn("args = []", config_text)
        self.assertNotIn('command = "opam"', config_text)
        self.assertNotIn("_build/default/ocaml/server/c2c_mcp_server.exe", config_text)

    def test_native_install_other_clients_keep_nonempty_mcp_server_path(self):
        home_dir = Path(self.temp_dir.name) / "home-other-installed-mcp"
        broker_root = Path(self.temp_dir.name) / "broker-other-installed-mcp"
        fake_bin = Path(self.temp_dir.name) / "bin-other-installed-mcp"
        opencode_target = Path(self.temp_dir.name) / "opencode-target"
        home_dir.mkdir(parents=True, exist_ok=True)
        broker_root.mkdir(parents=True, exist_ok=True)
        fake_bin.mkdir(parents=True, exist_ok=True)
        opencode_target.mkdir(parents=True, exist_ok=True)
        mcp_server = fake_bin / "c2c-mcp-server"
        mcp_server.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        mcp_server.chmod(0o755)

        env = dict(self.env)
        env["HOME"] = str(home_dir)
        env["PATH"] = f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"

        for client, extra_args in [
            ("kimi", []),
            ("opencode", ["--target-dir", str(opencode_target), "--force"]),
            ("crush", []),
        ]:
            result = run_native_cli(
                "install",
                client,
                "--broker-root",
                str(broker_root),
                "--json",
                *extra_args,
                env=env,
            )
            self.assertEqual(result_code(result), 0, result.stderr)

        kimi = json.loads((home_dir / ".kimi" / "mcp.json").read_text(encoding="utf-8"))
        kimi_args = kimi["mcpServers"]["c2c"]["args"]
        self.assertEqual(kimi_args, ["exec", "--", str(mcp_server)])

        opencode = json.loads((opencode_target / ".opencode" / "opencode.json").read_text(encoding="utf-8"))
        opencode_command = opencode["mcp"]["c2c"]["command"]
        self.assertEqual(opencode_command, ["opam", "exec", "--", str(mcp_server)])

        crush = json.loads((home_dir / ".config" / "crush" / "crush.json").read_text(encoding="utf-8"))
        crush_args = crush["mcpServers"]["c2c"]["args"]
        self.assertEqual(crush_args, ["exec", "--", str(mcp_server)])

    def test_start_help_mentions_codex_headless(self):
        self.assertTrue(NATIVE_C2C.exists(), NATIVE_C2C)
        result = run_native_cli("start", "--help", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("codex-headless", result.stdout)

    def test_start_help_describes_codex_session_id_as_exact_target(self):
        self.assertTrue(NATIVE_C2C.exists(), NATIVE_C2C)
        result = run_native_cli("start", "--help", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Explicit", result.stdout)
        self.assertIn("thread/session target for codex and codex-headless", result.stdout)

    def test_commands_by_safety_describes_reset_thread_for_headless_too(self):
        self.assertTrue(NATIVE_C2C.exists(), NATIVE_C2C)
        result = run_native_cli("commands", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reset-thread", result.stdout)
        self.assertIn(
            "Restart a managed codex or codex-headless instance onto a specific thread",
            result.stdout,
        )

    def test_instances_cli_lists_stopped_and_running_instances(self):
        env, instances_dir = self.native_home_env("home-list")
        now = time.time()
        self.write_instance_dir(
            instances_dir,
            "stale-stopped",
            created_at=now - 10 * 86400.0,
        )
        self.write_instance_dir(
            instances_dir,
            "fresh-stopped",
            created_at=now - 1 * 86400.0,
        )
        self.write_instance_dir(
            instances_dir,
            "live-running",
            created_at=now - 2 * 86400.0,
            outer_pid=os.getpid(),
        )

        result = run_native_cli("instances", "--json", env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        names = [item["name"] for item in payload]
        self.assertEqual(sorted(names), ["fresh-stopped", "live-running", "stale-stopped"])
        statuses = {item["name"]: item["status"] for item in payload}
        self.assertEqual(statuses["stale-stopped"], "stopped")
        self.assertEqual(statuses["fresh-stopped"], "stopped")
        self.assertEqual(statuses["live-running"], "running")

    def test_instances_cli_prune_older_than_removes_stale_stopped_instances(self):
        env, instances_dir = self.native_home_env("home-prune")
        now = time.time()
        stale_dir = self.write_instance_dir(
            instances_dir,
            "stale-stopped",
            created_at=now - 10 * 86400.0,
        )
        fresh_dir = self.write_instance_dir(
            instances_dir,
            "fresh-stopped",
            created_at=now - 1 * 86400.0,
        )
        live_dir = self.write_instance_dir(
            instances_dir,
            "live-running",
            created_at=now - 2 * 86400.0,
            outer_pid=os.getpid(),
        )

        result = run_native_cli(
            "instances",
            "--prune-older-than",
            "7",
            "--json",
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        names = sorted(item["name"] for item in payload)
        self.assertEqual(names, ["fresh-stopped", "live-running"])
        self.assertFalse(stale_dir.exists())
        self.assertTrue(fresh_dir.exists())
        self.assertTrue(live_dir.exists())

    def test_repo_c2c_install_errors_cleanly_without_native_cli(self):
        c2c_entry = load_repo_c2c_module()
        stderr = io.StringIO()

        with (
            mock.patch.object(c2c_entry, "find_native_c2c", return_value=None),
            mock.patch.object(c2c_entry.sys, "argv", ["c2c", "install", "codex-headless"]),
            mock.patch("sys.stderr", stderr),
            mock.patch.object(c2c_entry.subprocess, "run") as run_mock,
        ):
            rc = c2c_entry.main()

        self.assertEqual(rc, 1)
        self.assertIn("native c2c CLI not found", stderr.getvalue())
        run_mock.assert_not_called()

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

    def test_resolve_broker_root_env_override(self):
        """C2C_MCP_BROKER_ROOT env var takes absolute precedence over repo fingerprint."""
        home_dir = Path(self.temp_dir.name) / "home-env-override"
        custom_broker = Path(self.temp_dir.name) / "my-custom-broker"
        home_dir.mkdir(parents=True, exist_ok=True)
        custom_broker.mkdir(parents=True, exist_ok=True)

        env = dict(self.env)
        env["HOME"] = str(home_dir)
        env["C2C_MCP_BROKER_ROOT"] = str(custom_broker)

        result = run_native_cli(
            "install", "codex",
            "--json",
            env=env,
        )
        self.assertEqual(result_code(result), 0, result.stderr)
        config_text = (home_dir / ".codex" / "config.toml").read_text(encoding="utf-8")
        self.assertIn(f'C2C_MCP_BROKER_ROOT = "{custom_broker}"', config_text)

    def test_migrate_broker_dry_run_does_not_write(self):
        """--dry-run prints planned copies but creates no files."""
        legacy = Path(self.temp_dir.name) / "legacy-broker"
        legacy.mkdir(parents=True, exist_ok=True)
        (legacy / "registry.json").write_text('{"registrations":[]}', encoding="utf-8")
        sub_dir = legacy / "archive"
        sub_dir.mkdir(parents=True, exist_ok=True)
        (sub_dir / "test-agent.jsonl").write_text(
            '{"ts":1,"from":"a","to":"b","content":"hello"}\n', encoding="utf-8"
        )

        new_root = Path(self.temp_dir.name) / "new-broker"
        env = dict(self.env)
        env["HOME"] = str(Path(self.temp_dir.name) / "home-migrate")

        result = run_native_cli(
            "migrate-broker",
            "--from", str(legacy),
            "--to", str(new_root),
            "--dry-run",
            env=env,
        )
        self.assertEqual(result_code(result), 0, result.stderr)
        self.assertIn("DRY RUN", result.stdout)
        self.assertIn("registry.json", result.stdout)
        self.assertIn("test-agent.jsonl", result.stdout)
        # dry-run should NOT create any files (only mkdir_p may run inside copy_dir
        # but files themselves should not be written)
        self.assertFalse((new_root / "registry.json").exists())
        self.assertFalse((new_root / "archive" / "test-agent.jsonl").exists())

    def test_migrate_broker_live_copies_nested_dirs(self):
        """Live migrate correctly copies nested directory structures."""
        legacy = Path(self.temp_dir.name) / "legacy-broker"
        legacy.mkdir(parents=True, exist_ok=True)
        # Simulate memory/ subdir with nested alias entries
        mem_dir = legacy / "memory" / "test-alias"
        mem_dir.mkdir(parents=True, exist_ok=True)
        (mem_dir / "entry.md").write_text("# test entry\ncontent", encoding="utf-8")
        # archive/session.jsonl
        arch_dir = legacy / "archive"
        arch_dir.mkdir(parents=True, exist_ok=True)
        (arch_dir / "test-session.jsonl").write_text(
            '{"ts":1,"from":"a","to":"b","content":"hello"}\n', encoding="utf-8"
        )
        # inbox.json.d/
        inbox_dir = legacy / "inbox.json.d"
        inbox_dir.mkdir(parents=True, exist_ok=True)
        (inbox_dir / "inbox.json").write_text('[]', encoding="utf-8")

        new_root = Path(self.temp_dir.name) / "new-broker"
        env = dict(self.env)
        env["HOME"] = str(Path(self.temp_dir.name) / "home-migrate-live")

        result = run_native_cli(
            "migrate-broker",
            "--from", str(legacy),
            "--to", str(new_root),
            "--json",
            env=env,
        )
        self.assertEqual(result_code(result), 0, result.stderr)

        # Verify all nested content made it
        self.assertTrue((new_root / "memory" / "test-alias" / "entry.md").exists())
        content = (new_root / "memory" / "test-alias" / "entry.md").read_text(encoding="utf-8")
        self.assertEqual(content, "# test entry\ncontent")

        self.assertTrue((new_root / "archive" / "test-session.jsonl").exists())
        self.assertTrue((new_root / "inbox.json.d" / "inbox.json").exists())


def result_code(result):
    return result.returncode


if __name__ == "__main__":
    unittest.main()
