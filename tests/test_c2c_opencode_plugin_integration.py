"""Integration tests for the c2c OpenCode plugin via a Node.js harness.

Starts the real plugin (.opencode/plugins/c2c.ts) under a test harness
(.opencode/tests/integration-harness.ts) and verifies end-to-end wiring:
inbox file change → fs.watch → drain → promptAsync → mock HTTP server.

A small shim stands in for the `c2c` CLI so the plugin's
`drainInbox()` can read the inbox JSON from a test-controlled file
without requiring a real broker + registry.
"""
from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HARNESS_PATH = REPO / ".opencode" / "tests" / "integration-harness.ts"
PLUGIN_PATH = REPO / ".opencode" / "plugins" / "c2c.ts"

# Skip the entire module if node or the harness/plugin are missing.
NODE_BIN = os.environ.get("NODE_BIN", "node")


def _node_available() -> bool:
    try:
        subprocess.run(
            [NODE_BIN, "--version"],
            capture_output=True,
            check=True,
            timeout=5,
        )
        return True
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


pytestmark = pytest.mark.skipif(
    not HARNESS_PATH.exists() or not PLUGIN_PATH.exists() or not _node_available(),
    reason="node or harness/plugin missing",
)


MOCK_CLI_TEMPLATE = """#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

INBOX_PATH = os.environ["MOCK_C2C_INBOX_PATH"]
SPOOL_PATH = os.environ.get("MOCK_C2C_SPOOL_PATH", "/tmp/c2c-spool.json")
STATEFILE_PATH = os.environ.get("MOCK_C2C_STATEFILE_PATH", "/tmp/oc-plugin-state.json")

def _deep_merge(dst, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            _deep_merge(dst[key], value)
        else:
            dst[key] = value

def _read_inbox():
    try:
        with open(INBOX_PATH, "r") as f:
            content = f.read().strip() or "[]"
            return json.loads(content)
    except FileNotFoundError:
        return []

def _drain_inbox():
    messages = _read_inbox()
    # Atomically drain: rewrite as empty list.
    with open(INBOX_PATH, "w") as f:
        f.write("[]")
    return messages

def _read_statefile():
    try:
        with open(STATEFILE_PATH, "r") as f:
            content = f.read().strip()
            return json.loads(content) if content else None
    except FileNotFoundError:
        return None

def _write_statefile(payload):
    path = Path(STATEFILE_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload))

if len(sys.argv) >= 2 and sys.argv[1] == "poll-inbox":
    messages = _drain_inbox()
    session_id = os.environ.get("C2C_MCP_SESSION_ID", "")
    print(json.dumps({"session_id": session_id, "messages": messages}))
    sys.exit(0)

if len(sys.argv) >= 3 and sys.argv[1] == "oc-plugin" and sys.argv[2] == "drain-inbox-to-spool":
    # Parse --spool-path and --json flags.
    args = sys.argv[3:]
    spool_path = SPOOL_PATH
    json_mode = False
    i = 0
    while i < len(args):
        if args[i] == "--spool-path" and i + 1 < len(args):
            spool_path = args[i + 1]
            i += 2
        elif args[i] == "--json":
            json_mode = True
            i += 1
        else:
            i += 1

    messages = _drain_inbox()

    # Write messages to spool (simulate spool append).
    try:
        spool = json.loads(open(spool_path).read()) if os.path.exists(spool_path) else []
    except Exception:
        spool = []
    spool = spool + messages
    with open(spool_path, "w") as f:
        json.dump(spool, f)

    if json_mode:
        print(json.dumps({
            "ok": True,
            "session_id": os.environ.get("C2C_MCP_SESSION_ID", ""),
            "spool_path": spool_path,
            "count": len(messages),
            "messages": messages,
        }))
    else:
        print("staged %d OpenCode message(s) into %s" % (len(messages), spool_path))
    sys.exit(0)

if len(sys.argv) >= 3 and sys.argv[1] == "oc-plugin" and sys.argv[2] == "stream-write-statefile":
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("event") == "state.snapshot":
            _write_statefile(event)
            continue
        if event.get("event") == "state.patch":
            current = _read_statefile()
            if current is None:
                current = {"event": "state.snapshot", "ts": event.get("ts"), "state": {}}
            current["ts"] = event.get("ts", current.get("ts"))
            state = current.setdefault("state", {})
            _deep_merge(state, event.get("patch", {}))
            current["event"] = "state.snapshot"
            _write_statefile(current)
    sys.exit(0)

print("unknown mock c2c args: %s" % sys.argv[1:], file=sys.stderr)
sys.exit(1)
"""


class _MockServer(BaseHTTPRequestHandler):
    # Silence BaseHTTPRequestHandler's default request logging.
    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            payload = {"_raw": raw.decode("utf-8", errors="replace")}
        self.server.recorded_calls.append({"path": self.path, "payload": payload})  # type: ignore[attr-defined]
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")


def _start_mock_server() -> tuple[HTTPServer, str]:
    server = HTTPServer(("127.0.0.1", 0), _MockServer)
    server.recorded_calls = []  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    sockname = server.server_address
    host, port = sockname[0], sockname[1]
    return server, f"http://{host}:{port}"


def _write_mock_cli(tmp_path: Path) -> Path:
    path = tmp_path / "mock-c2c"
    path.write_text(MOCK_CLI_TEMPLATE)
    path.chmod(
        path.stat().st_mode
        | stat.S_IXUSR
        | stat.S_IXGRP
        | stat.S_IXOTH
    )
    return path


def _wait_for_line(proc: subprocess.Popen, needle: str, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    assert proc.stdout is not None
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError(f"Harness exited before '{needle}' (rc={proc.returncode})")
            continue
        if needle in line:
            return line
    raise TimeoutError(f"Harness did not emit '{needle}' within {timeout}s")


def _start_harness(
    *,
    tmp_path: Path,
    env_overrides: dict[str, str],
) -> subprocess.Popen:
    env = {
        **os.environ,
        "C2C_MCP_INBOX_WATCHER_DELAY": "0",
        # Skip cold-boot delay so integration tests complete within their timeout
        "C2C_PLUGIN_COLD_BOOT_DELAY_MS": "0",
        **env_overrides,
    }
    return subprocess.Popen(
        [NODE_BIN, "--experimental-strip-types", str(HARNESS_PATH)],
        cwd=str(tmp_path),
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )


def _stop_harness(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        try:
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2)


class TestOpenCodePluginDelivery:
    def test_plugin_delivers_message_from_inbox(self, tmp_path: Path) -> None:
        broker_root = tmp_path / "broker"
        broker_root.mkdir()
        session_id = "harness-session"
        inbox_path = broker_root / f"{session_id}.inbox.json"
        inbox_path.write_text("[]")

        # The plugin writes its spool to process.cwd() / ".opencode" / "c2c-plugin-spool.json".
        # Create .opencode so the plugin can write the spool file there.
        opencode_dir = tmp_path / ".opencode"
        opencode_dir.mkdir()

        mock_cli = _write_mock_cli(tmp_path)
        server, url = _start_mock_server()
        try:
            proc = _start_harness(
                tmp_path=tmp_path,
                env_overrides={
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_TEST_MOCK_SERVER_URL": url,
                    "C2C_CLI_COMMAND": str(mock_cli),
                    "MOCK_C2C_INBOX_PATH": str(inbox_path),
                    "C2C_TEST_TARGET_SESSION": "harness-root",
                    "C2C_TEST_HARNESS_TIMEOUT": "15",
                },
            )
            try:
                _wait_for_line(proc, "READY", timeout=10.0)

                # Write a message to the inbox — fs.watch should detect it.
                inbox_path.write_text(
                    json.dumps(
                        [
                            {
                                "from_alias": "alice",
                                "to_alias": "harness-root",
                                "content": "hello plugin",
                            }
                        ]
                    )
                )

                # Wait for either the DELIVERED stdout line OR a recorded
                # mock server call (whichever comes first).
                deadline = time.monotonic() + 10.0
                while time.monotonic() < deadline:
                    if server.recorded_calls:  # type: ignore[attr-defined]
                        break
                    time.sleep(0.1)
                assert server.recorded_calls, (  # type: ignore[attr-defined]
                    "Mock server did not receive prompt_async call"
                )
                call = server.recorded_calls[0]  # type: ignore[attr-defined]
                assert call["path"] == "/session/prompt_async"
                text = call["payload"]["body"]["parts"][0]["text"]
                assert '<c2c event="message"' in text
                assert 'from="alice"' in text
                assert "hello plugin" in text
            finally:
                _stop_harness(proc)
        finally:
            server.shutdown()

    def test_plugin_handles_missing_session_id_gracefully(self, tmp_path: Path) -> None:
        mock_cli = _write_mock_cli(tmp_path)
        server, url = _start_mock_server()
        try:
            proc = _start_harness(
                tmp_path=tmp_path,
                env_overrides={
                    "C2C_MCP_SESSION_ID": "",
                    "C2C_MCP_BROKER_ROOT": "",
                    "C2C_TEST_MOCK_SERVER_URL": url,
                    "C2C_CLI_COMMAND": str(mock_cli),
                    "MOCK_C2C_INBOX_PATH": str(tmp_path / "unused-inbox.json"),
                    "C2C_TEST_HARNESS_TIMEOUT": "5",
                },
            )
            try:
                _wait_for_line(proc, "READY", timeout=10.0)
                # Give it a beat; no delivery should happen.
                time.sleep(0.5)
                assert server.recorded_calls == []  # type: ignore[attr-defined]
            finally:
                _stop_harness(proc)
        finally:
            server.shutdown()

    def test_plugin_heartbeat_keeps_statefile_fresh(self, tmp_path: Path) -> None:
        broker_root = tmp_path / "broker"
        broker_root.mkdir()
        session_id = "heartbeat-session"
        inbox_path = broker_root / f"{session_id}.inbox.json"
        inbox_path.write_text("[]")
        statefile_path = tmp_path / ".local" / "share" / "c2c" / "instances" / "heartbeat-test" / "oc-plugin-state.json"

        mock_cli = _write_mock_cli(tmp_path)
        server, url = _start_mock_server()
        try:
            proc = _start_harness(
                tmp_path=tmp_path,
                env_overrides={
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_TEST_MOCK_SERVER_URL": url,
                    "C2C_CLI_COMMAND": str(mock_cli),
                    "MOCK_C2C_INBOX_PATH": str(inbox_path),
                    "MOCK_C2C_STATEFILE_PATH": str(statefile_path),
                    "C2C_PLUGIN_HEARTBEAT_INTERVAL_MS": "200",
                    "C2C_TEST_TARGET_SESSION": "heartbeat-root",
                    "C2C_TEST_HARNESS_TIMEOUT": "10",
                },
            )
            try:
                _wait_for_line(proc, "READY", timeout=10.0)

                deadline = time.monotonic() + 5.0
                first_snapshot = None
                while time.monotonic() < deadline:
                    if statefile_path.exists():
                        first_snapshot = json.loads(statefile_path.read_text())
                        break
                    time.sleep(0.05)
                assert first_snapshot is not None, "plugin did not write initial state snapshot"
                assert first_snapshot["event"] == "state.snapshot"
                assert first_snapshot["state"]["c2c_session_id"] == session_id
                first_active = first_snapshot["state"]["activity_sources"]["plugin"]["last_active_at"]

                deadline = time.monotonic() + 5.0
                second_active = first_active
                while time.monotonic() < deadline:
                    snapshot = json.loads(statefile_path.read_text())
                    second_active = snapshot["state"]["activity_sources"]["plugin"]["last_active_at"]
                    if second_active != first_active:
                        break
                    time.sleep(0.05)

                assert second_active != first_active, "plugin heartbeat did not refresh last_active_at"
            finally:
                _stop_harness(proc)
        finally:
            server.shutdown()
