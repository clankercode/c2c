import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_mcp


AGENT_ONE_SESSION_ID = "6e45bbe8-998c-4140-b77e-c6f117e6ca4b"


class C2CMcpAutoRegisterTests(unittest.TestCase):
    def test_auto_register_disabled_by_default(self):
        with mock.patch.dict(os.environ, {"C2C_MCP_AUTO_REGISTER_ALIAS": ""}, clear=False):
            self.assertIsNone(c2c_mcp.auto_register_alias_from_env())

    def test_auto_register_alias_from_env_trims_and_rejects_blank(self):
        with mock.patch.dict(
            os.environ,
            {"C2C_MCP_AUTO_REGISTER_ALIAS": "  opencode-local  "},
            clear=False,
        ):
            self.assertEqual(c2c_mcp.auto_register_alias_from_env(), "opencode-local")

        with mock.patch.dict(
            os.environ, {"C2C_MCP_AUTO_REGISTER_ALIAS": "   "}, clear=False
        ):
            self.assertIsNone(c2c_mcp.auto_register_alias_from_env())

    def test_maybe_auto_register_startup_registers_current_session_and_client_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "mcp-broker"
            env = {
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": AGENT_ONE_SESSION_ID,
                "C2C_MCP_CLIENT_PID": "424242",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
            }

            with (
                mock.patch.dict(os.environ, env, clear=False),
                mock.patch("c2c_mcp.read_pid_start_time", return_value=777),
            ):
                c2c_mcp.maybe_auto_register_startup(env)

            registrations = c2c_mcp.load_broker_registrations(
                broker_root / "registry.json"
            )
            self.assertEqual(
                registrations,
                [
                    {
                        "session_id": AGENT_ONE_SESSION_ID,
                        "alias": "opencode-local",
                        "pid": 424242,
                        "pid_start_time": 777,
                    }
                ],
            )

    def test_maybe_auto_register_startup_falls_back_to_parent_pid_when_client_pid_missing(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "mcp-broker"
            env = {
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": AGENT_ONE_SESSION_ID,
                "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
            }

            with (
                mock.patch.dict(os.environ, env, clear=False),
                mock.patch("c2c_mcp.os.getppid", return_value=515151),
                mock.patch("c2c_mcp.read_pid_start_time", return_value=888),
            ):
                c2c_mcp.maybe_auto_register_startup(env)

            registrations = c2c_mcp.load_broker_registrations(
                broker_root / "registry.json"
            )
            self.assertEqual(registrations[0]["pid"], 515151)
            self.assertEqual(registrations[0]["pid_start_time"], 888)

    def test_maybe_auto_register_startup_skips_when_alias_or_session_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "mcp-broker"
            env = {
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": AGENT_ONE_SESSION_ID,
            }

            c2c_mcp.maybe_auto_register_startup(env)
            self.assertEqual(
                c2c_mcp.load_broker_registrations(broker_root / "registry.json"), []
            )

            env["C2C_MCP_AUTO_REGISTER_ALIAS"] = "opencode-local"
            env["C2C_MCP_SESSION_ID"] = ""
            c2c_mcp.maybe_auto_register_startup(env)
            self.assertEqual(
                c2c_mcp.load_broker_registrations(broker_root / "registry.json"), []
            )

    def test_maybe_auto_register_startup_keeps_live_same_alias_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "mcp-broker"
            broker_root.mkdir(parents=True)
            (broker_root / "registry.json").write_text(
                '[{"session_id":"opencode-local","alias":"opencode-local",'
                '"pid":111,"pid_start_time":222}]',
                encoding="utf-8",
            )
            env = {
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": "opencode-local",
                "C2C_MCP_CLIENT_PID": "333",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
            }

            def fake_start_time(pid: int) -> int | None:
                return {111: 222, 333: 444}.get(pid)

            with (
                mock.patch.dict(os.environ, env, clear=False),
                mock.patch("c2c_mcp.os.path.exists", return_value=True),
                mock.patch("c2c_mcp.read_pid_start_time", side_effect=fake_start_time),
                mock.patch(
                    "c2c_mcp.proc_cmdline",
                    side_effect=lambda pid: {
                        111: "/home/xertrov/.bun/bin/opencode -s ses_abc",
                        333: "/home/xertrov/.bun/bin/opencode run --session ses_abc prompt",
                    }.get(pid, ""),
                ),
            ):
                c2c_mcp.maybe_auto_register_startup(env)

            registrations = c2c_mcp.load_broker_registrations(
                broker_root / "registry.json"
            )
            self.assertEqual(
                registrations,
                [
                    {
                        "session_id": "opencode-local",
                        "alias": "opencode-local",
                        "pid": 111,
                        "pid_start_time": 222,
                    }
                ],
            )

    def test_maybe_auto_register_startup_replaces_live_run_with_tui_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "mcp-broker"
            broker_root.mkdir(parents=True)
            (broker_root / "registry.json").write_text(
                '[{"session_id":"opencode-local","alias":"opencode-local",'
                '"pid":111,"pid_start_time":222}]',
                encoding="utf-8",
            )
            env = {
                "C2C_MCP_BROKER_ROOT": str(broker_root),
                "C2C_MCP_SESSION_ID": "opencode-local",
                "C2C_MCP_CLIENT_PID": "333",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "opencode-local",
            }

            def fake_start_time(pid: int) -> int | None:
                return {111: 222, 333: 444}.get(pid)

            with (
                mock.patch.dict(os.environ, env, clear=False),
                mock.patch("c2c_mcp.os.path.exists", return_value=True),
                mock.patch("c2c_mcp.read_pid_start_time", side_effect=fake_start_time),
                mock.patch(
                    "c2c_mcp.proc_cmdline",
                    side_effect=lambda pid: {
                        111: "/home/xertrov/.bun/bin/opencode run --session ses_abc prompt",
                        333: "/home/xertrov/.bun/bin/opencode -s ses_abc",
                    }.get(pid, ""),
                ),
            ):
                c2c_mcp.maybe_auto_register_startup(env)

            registrations = c2c_mcp.load_broker_registrations(
                broker_root / "registry.json"
            )
            self.assertEqual(registrations[0]["pid"], 333)
            self.assertEqual(registrations[0]["pid_start_time"], 444)


if __name__ == "__main__":
    unittest.main()
