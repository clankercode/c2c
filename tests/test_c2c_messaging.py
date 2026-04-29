import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from threading import BrokenBarrierError
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_deliver_inbox
import c2c_inject
import c2c_send
import claude_list_sessions
import claude_send_msg


AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"
AGENT_TWO_SESSION_ID = "fa68bd5b-0529-4292-bc27-d617f6840ce7"


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
                "c2c_deliver_inbox.c2c_inject.resolve_session_info",
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
            '<c2c event="message" from="agent-one" to="storm-herald" source="pty" source_tool="claude_send_msg" action_after="continue">\nhello peer\n</c2c>',
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

    def test_inject_delegates_to_pure_python_pty_backend_with_terminal_metadata(self):
        session = {
            "tty": "/dev/pts/9",
            "terminal_pid": 33333,
        }

        with mock.patch("claude_send_msg.c2c_pty_inject.inject") as inject:
            claude_send_msg.inject(session, "hello peer")

        inject.assert_called_once_with(33333, "9", "hello peer")

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


if __name__ == "__main__":
    unittest.main()
