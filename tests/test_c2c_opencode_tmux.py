"""Optional tmux-visible integration test for the c2c OpenCode plugin.

Opens a real tmux session with three panes for live observability of the
harness. Gated behind `C2C_TEST_TMUX=1` since it requires tmux, mutates
the user's terminal, and is intended for operator debugging rather than
routine CI.
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HARNESS_PATH = REPO / ".opencode" / "tests" / "integration-harness.ts"

TMUX_BIN = shutil.which("tmux")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_TMUX") != "1" or not TMUX_BIN,
    reason="set C2C_TEST_TMUX=1 and install tmux to run this test",
)


MOCK_CLI_TEMPLATE = """#!/usr/bin/env python3
import json
import os
import sys

INBOX_PATH = os.environ["MOCK_C2C_INBOX_PATH"]

if len(sys.argv) >= 2 and sys.argv[1] == "poll-inbox":
    try:
        with open(INBOX_PATH, "r") as f:
            content = f.read().strip() or "[]"
            messages = json.loads(content)
    except FileNotFoundError:
        messages = []
    with open(INBOX_PATH, "w") as f:
        f.write("[]")
    session_id = os.environ.get("C2C_MCP_SESSION_ID", "")
    print(json.dumps({"session_id": session_id, "messages": messages}))
    sys.exit(0)

sys.exit(1)
"""


class _MockServer(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            payload = {"_raw": raw.decode("utf-8", errors="replace")}
        self.server.recorded_calls.append(payload)  # type: ignore[attr-defined]
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


def _tmux(*args: str) -> subprocess.CompletedProcess:
    assert TMUX_BIN is not None
    return subprocess.run(
        [TMUX_BIN, *args],
        capture_output=True,
        text=True,
        check=True,
    )


def test_visible_delivery_in_tmux(tmp_path: Path) -> None:
    assert TMUX_BIN is not None

    broker_root = tmp_path / "broker"
    broker_root.mkdir()
    session_id = "tmux-session"
    inbox_path = broker_root / f"{session_id}.inbox.json"
    inbox_path.write_text("[]")

    mock_cli = tmp_path / "mock-c2c"
    mock_cli.write_text(MOCK_CLI_TEMPLATE)
    mock_cli.chmod(
        mock_cli.stat().st_mode
        | stat.S_IXUSR
        | stat.S_IXGRP
        | stat.S_IXOTH
    )

    server, url = _start_mock_server()
    tmux_session = f"c2c-plugin-test-{os.getpid()}"
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    harness_log = log_dir / "harness.log"

    env_file = tmp_path / "harness.env"
    env_file.write_text(
        "\n".join(
            [
                f"export C2C_MCP_SESSION_ID={session_id}",
                f"export C2C_MCP_BROKER_ROOT={broker_root}",
                f"export C2C_TEST_MOCK_SERVER_URL={url}",
                f"export C2C_CLI_COMMAND={mock_cli}",
                f"export MOCK_C2C_INBOX_PATH={inbox_path}",
                "export C2C_TEST_TARGET_SESSION=harness-root",
                "export C2C_TEST_HARNESS_TIMEOUT=30",
                "",
            ]
        )
    )

    try:
        _tmux("new-session", "-d", "-s", tmux_session, "-x", "200", "-y", "50", "bash")
        _tmux(
            "send-keys",
            "-t",
            f"{tmux_session}:0.0",
            f"tail -F {inbox_path}",
            "Enter",
        )
        _tmux("split-window", "-h", "-t", f"{tmux_session}:0", "bash")
        _tmux(
            "send-keys",
            "-t",
            f"{tmux_session}:0.1",
            (
                f"source {env_file} && "
                f"node --experimental-strip-types {HARNESS_PATH} 2>&1 | tee {harness_log}"
            ),
            "Enter",
        )
        _tmux("split-window", "-v", "-t", f"{tmux_session}:0.1", "bash")

        # Wait for the harness to print READY.
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if harness_log.exists() and "READY" in harness_log.read_text():
                break
            time.sleep(0.2)
        else:
            raise AssertionError(
                f"Harness never reported READY. Log: {harness_log.read_text() if harness_log.exists() else '(missing)'}"
            )

        # Poke the inbox and wait for the mock server to record a call.
        inbox_path.write_text(
            json.dumps(
                [
                    {
                        "from_alias": "tmux-peer",
                        "to_alias": "harness-root",
                        "content": "visible delivery",
                    }
                ]
            )
        )
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if server.recorded_calls:  # type: ignore[attr-defined]
                break
            time.sleep(0.1)

        assert server.recorded_calls, (  # type: ignore[attr-defined]
            "Mock server did not receive prompt_async call"
        )
        call = server.recorded_calls[0]  # type: ignore[attr-defined]
        text = call["body"]["parts"][0]["text"]
        assert "visible delivery" in text
    finally:
        try:
            _tmux("kill-session", "-t", tmux_session)
        except subprocess.CalledProcessError:
            pass
        server.shutdown()
