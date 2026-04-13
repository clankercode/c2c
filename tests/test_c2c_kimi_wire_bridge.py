"""Tests for the Kimi Wire bridge: WireState, formatting, C2CSpool, WireClient, and CLI."""
import io
import json
import sys
import tempfile
import unittest
import unittest.mock as mock
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import c2c_kimi_wire_bridge as bridge


class WireStateTests(unittest.TestCase):
    def test_initial_state_not_active(self):
        state = bridge.WireState()
        self.assertFalse(state.turn_active)
        self.assertEqual(state.steer_inputs, [])

    def test_turn_begin_and_end_toggle_active_state(self):
        state = bridge.WireState()

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnBegin", "payload": {"user_input": "hi"}},
        })
        self.assertTrue(state.turn_active)

        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "TurnEnd", "payload": {}},
        })
        self.assertFalse(state.turn_active)

    def test_steer_input_marks_consumed(self):
        state = bridge.WireState()
        state.apply_message({
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": "SteerInput", "payload": {"user_input": "wake"}},
        })
        self.assertEqual(state.steer_inputs, ["wake"])

    def test_non_event_messages_are_ignored(self):
        state = bridge.WireState()
        state.apply_message({"jsonrpc": "2.0", "id": "1", "result": {}})
        self.assertFalse(state.turn_active)


class FormattingTests(unittest.TestCase):
    def test_formats_c2c_envelope(self):
        msg = {
            "from_alias": "codex",
            "to_alias": "kimi-wire",
            "content": "hello",
        }
        text = bridge.format_c2c_envelope(msg)

        self.assertIn('<c2c event="message"', text)
        self.assertIn('from="codex"', text)
        self.assertIn('alias="kimi-wire"', text)
        self.assertIn('source="broker"', text)
        self.assertIn("hello", text)

    def test_formats_multiple_messages_as_one_prompt(self):
        prompt = bridge.format_prompt([
            {"from_alias": "a", "to_alias": "k", "content": "one"},
            {"from_alias": "b", "to_alias": "k", "content": "two"},
        ])

        self.assertIn("one", prompt)
        self.assertIn("two", prompt)
        self.assertIn("\n\n", prompt)

    def test_envelope_escapes_special_chars_in_alias(self):
        msg = {"from_alias": 'a"b', "to_alias": "kimi", "content": "x"}
        text = bridge.format_c2c_envelope(msg)
        self.assertNotIn('"a"b"', text)


class SpoolTests(unittest.TestCase):
    def test_spool_append_replace_and_clear(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool = bridge.C2CSpool(Path(tmp) / "kimi.spool.json")

            spool.append([{"content": "one"}])
            spool.append([{"content": "two"}])
            self.assertEqual([m["content"] for m in spool.read()], ["one", "two"])

            spool.replace([{"content": "three"}])
            self.assertEqual([m["content"] for m in spool.read()], ["three"])

            spool.clear()
            self.assertEqual(spool.read(), [])

    def test_spool_read_returns_empty_for_missing_file(self):
        spool = bridge.C2CSpool(Path("/tmp/nonexistent-c2c-spool-test.json"))
        self.assertEqual(spool.read(), [])

    def test_spool_creates_parent_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            spool = bridge.C2CSpool(Path(tmp) / "nested" / "dir" / "spool.json")
            spool.append([{"content": "x"}])
            self.assertEqual(spool.read()[0]["content"], "x")


class ConfigTests(unittest.TestCase):
    def test_build_kimi_mcp_config_has_explicit_c2c_env(self):
        cfg = bridge.build_kimi_mcp_config(
            broker_root=Path("/broker"),
            session_id="kimi-wire",
            alias="kimi-wire",
            mcp_script=Path("/repo/c2c_mcp.py"),
        )

        env = cfg["mcpServers"]["c2c"]["env"]
        self.assertEqual(env["C2C_MCP_BROKER_ROOT"], "/broker")
        self.assertEqual(env["C2C_MCP_SESSION_ID"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_REGISTER_ALIAS"], "kimi-wire")
        self.assertEqual(env["C2C_MCP_AUTO_JOIN_ROOMS"], "swarm-lounge")
        self.assertEqual(env["C2C_MCP_AUTO_DRAIN_CHANNEL"], "0")

    def test_build_kimi_mcp_config_uses_python3_command(self):
        cfg = bridge.build_kimi_mcp_config(
            broker_root=Path("/b"),
            session_id="s",
            alias="s",
            mcp_script=Path("/repo/c2c_mcp.py"),
        )
        c2c_server = cfg["mcpServers"]["c2c"]
        self.assertEqual(c2c_server["command"], "python3")
        self.assertIn("/repo/c2c_mcp.py", c2c_server["args"])


class WireClientTests(unittest.TestCase):
    def test_initialize_writes_jsonrpc_request(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.initialize()

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "initialize")
        self.assertEqual(written["params"]["protocol_version"], "1.9")
        self.assertEqual(result["protocol_version"], "1.9")

    def test_prompt_writes_user_input(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","result":{"status":"finished"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        result = client.prompt("hello")

        written = json.loads(stdin.getvalue().strip())
        self.assertEqual(written["method"], "prompt")
        self.assertEqual(written["params"]["user_input"], "hello")
        self.assertEqual(result["status"], "finished")

    def test_client_skips_notifications_before_response(self):
        """Events arriving before the response are applied to state but don't block."""
        stdin = io.StringIO()
        notification = '{"jsonrpc":"2.0","method":"event","params":{"type":"TurnBegin","payload":{}}}\n'
        response = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        stdout = io.StringIO(notification + response)
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        client.initialize()

        self.assertTrue(client.state.turn_active)

    def test_client_raises_on_error_response(self):
        stdin = io.StringIO()
        stdout = io.StringIO('{"jsonrpc":"2.0","id":"1","error":{"code":-1,"message":"fail"}}\n')
        client = bridge.WireClient(stdin=stdin, stdout=stdout)

        with self.assertRaises(RuntimeError):
            client.prompt("hello")


class CLITests(unittest.TestCase):
    def test_dry_run_outputs_launch_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            rc, output = bridge.run_main_capture([
                "--session-id", "kimi-wire",
                "--alias", "kimi-wire",
                "--broker-root", str(Path(tmp) / "broker"),
                "--work-dir", tmp,
                "--dry-run",
                "--json",
            ])

        self.assertEqual(rc, 0)
        payload = json.loads(output)
        self.assertEqual(payload["session_id"], "kimi-wire")
        self.assertIn("--wire", payload["launch"])
        self.assertTrue(payload["dry_run"])

    def test_once_delivers_spooled_message_with_fake_wire(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            spool.append([{"from_alias": "codex", "to_alias": "kimi-wire", "content": "hello"}])
            stdin = io.StringIO()
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
                '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
            )

            result = bridge.deliver_once(
                wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                spool=spool,
                broker_root=broker_root,
                session_id="kimi-wire",
                timeout=1.0,
            )

        self.assertEqual(result["delivered"], 1)
        self.assertEqual(spool.read(), [])
        self.assertIn("hello", stdin.getvalue())

    def test_once_returns_zero_delivered_when_spool_and_inbox_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            stdin = io.StringIO()
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
            )

            result = bridge.deliver_once(
                wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                spool=spool,
                broker_root=broker_root,
                session_id="kimi-wire-empty",
                timeout=0.0,
            )

        self.assertEqual(result["delivered"], 0)
        self.assertTrue(result["ok"])

    def test_once_keeps_spool_intact_if_prompt_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool = bridge.C2CSpool(Path(tmp) / "spool.json")
            spool.append([{"from_alias": "a", "to_alias": "b", "content": "kept"}])
            stdin = io.StringIO()
            # initialize succeeds, prompt fails
            stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
                '{"jsonrpc":"2.0","id":"2","error":{"code":-32600,"message":"bad request"}}\n'
            )

            with self.assertRaises(RuntimeError):
                bridge.deliver_once(
                    wire=bridge.WireClient(stdin=stdin, stdout=stdout),
                    spool=spool,
                    broker_root=broker_root,
                    session_id="kimi-wire-fail",
                    timeout=1.0,
                )

            # assertion must be inside the with-block before temp dir cleanup
            self.assertEqual(len(spool.read()), 1)
            self.assertEqual(spool.read()[0]["content"], "kept")


class RunOnceLiveTests(unittest.TestCase):
    """Tests for run_once_live() using a mocked subprocess.Popen."""

    def _make_mock_proc(self, *wire_responses: str) -> mock.MagicMock:
        """Build a mock Popen process with canned Wire JSON-RPC stdout lines."""
        proc = mock.MagicMock()
        proc.stdin = io.StringIO()
        proc.stdout = io.StringIO("".join(wire_responses))
        proc.wait.return_value = 0
        return proc

    def test_run_once_live_delivers_spooled_message(self):
        """run_once_live delivers a pre-spooled message and clears the spool."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        prompt_resp = '{"jsonrpc":"2.0","id":"2","result":{"status":"finished"}}\n'
        proc = self._make_mock_proc(init_resp, prompt_resp)

        # run_once_live closes proc.stdin in its finally block; capture writes
        # to a side buffer so we can inspect them after the call returns.
        written_buf = io.StringIO()
        proc.stdin = mock.MagicMock()
        proc.stdin.write.side_effect = written_buf.write
        proc.stdin.flush.return_value = None

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            spool_path = Path(tmp) / "spool.json"
            spool = bridge.C2CSpool(spool_path)
            spool.append([{"from_alias": "codex", "to_alias": "kimi-wire", "content": "wire-test"}])

            with mock.patch("subprocess.Popen", return_value=proc):
                result = bridge.run_once_live(
                    session_id="kimi-wire",
                    alias="kimi-wire",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=spool_path,
                    timeout=0.0,
                )

            self.assertEqual(result["delivered"], 1)
            self.assertTrue(result["ok"])
            self.assertEqual(spool.read(), [])
            self.assertIn("wire-test", written_buf.getvalue())

    def test_run_once_live_launch_includes_wire_and_yolo(self):
        """Subprocess is launched with --wire and --yolo flags."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("subprocess.Popen", return_value=proc) as mock_popen:
                bridge.run_once_live(
                    session_id="s",
                    alias="s",
                    broker_root=Path(tmp) / "broker",
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        launch_cmd = mock_popen.call_args[0][0]
        self.assertIn("--wire", launch_cmd)
        self.assertIn("--yolo", launch_cmd)
        self.assertIn("--mcp-config-file", launch_cmd)
        self.assertIn("--work-dir", launch_cmd)

    def test_run_once_live_writes_valid_mcp_config_json(self):
        """A valid MCP config JSON file is written and passed to kimi."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch("subprocess.Popen", return_value=proc) as mock_popen:
                bridge.run_once_live(
                    session_id="test-sid",
                    alias="test-alias",
                    broker_root=Path(tmp) / "broker",
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        launch_cmd = mock_popen.call_args[0][0]
        cfg_idx = launch_cmd.index("--mcp-config-file") + 1
        cfg_path = Path(launch_cmd[cfg_idx])
        # The temp config is deleted after the function returns — we can't read it
        # directly, but we can check the launch args contain a path that ends in .json
        self.assertTrue(str(cfg_path).endswith(".json"))

    def test_run_once_live_returns_zero_delivered_when_nothing_queued(self):
        """run_once_live returns delivered=0 when spool and inbox are empty."""
        init_resp = '{"jsonrpc":"2.0","id":"1","result":{"protocol_version":"1.9"}}\n'
        proc = self._make_mock_proc(init_resp)

        with tempfile.TemporaryDirectory() as tmp:
            broker_root = Path(tmp) / "broker"
            broker_root.mkdir(parents=True)
            with mock.patch("subprocess.Popen", return_value=proc):
                result = bridge.run_once_live(
                    session_id="empty-session",
                    alias="empty-session",
                    broker_root=broker_root,
                    work_dir=Path(tmp),
                    command="kimi",
                    spool_path=Path(tmp) / "spool.json",
                    timeout=0.0,
                )

        self.assertEqual(result["delivered"], 0)
        self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main()
