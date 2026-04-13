"""End-to-end onboarding smoke test for the c2c OCaml MCP server.

This test answers "can a brand-new agent complete the minimum
c2c round-trip?" without any mocks, patches, or internal state
peeking. It spawns the real `_build/default/ocaml/server/c2c_mcp_server.exe`
binary twice (as two independent peer sessions), drives it via
stdio JSON-RPC exactly the way Claude Code / Codex / OpenCode do,
and asserts that a send → poll_inbox round-trip works in both
directions through a shared broker dir.

Closes gap #6 in
`.collab/findings/2026-04-13T06-42-00Z-storm-beacon-quality-gaps.md`.
If this test ever fails, onboarding is broken — we cannot tell a
new user "try c2c, here's how" without first fixing whatever this
test caught.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SERVER = REPO / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"


def _rpc(proc: subprocess.Popen, request: dict, timeout: float = 5.0) -> dict:
    """Send a JSON-RPC request and return the matching response.

    Skips server-initiated notifications (no `id` field) and any
    response whose id does not match ours — that way we are robust
    against future server-side chatter without per-test filters.
    """
    assert proc.stdin is not None
    assert proc.stdout is not None
    proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(
                f"server closed stdout while waiting for id={request.get('id')}"
            )
        payload = json.loads(line)
        if payload.get("id") == request.get("id"):
            return payload
        # notification or unrelated response — keep reading
    raise TimeoutError(f"no response for id={request.get('id')} within {timeout}s")


def _spawn_server(broker_root: Path, session_id: str) -> subprocess.Popen:
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session_id
    return subprocess.Popen(
        [str(SERVER)],
        cwd=REPO,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def _initialize(proc: subprocess.Popen, req_id: int) -> dict:
    return _rpc(
        proc,
        {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "onboarding-smoke", "version": "0"},
            },
        },
    )


def _tool_call(
    proc: subprocess.Popen, req_id: int, name: str, arguments: dict
) -> dict:
    return _rpc(
        proc,
        {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
    )


def _tool_text(response: dict) -> str:
    return response["result"]["content"][0]["text"]


class OnboardingSmokeTest(unittest.TestCase):
    """Real two-peer round-trip under 60 seconds, no mocks."""

    def setUp(self) -> None:
        if not SERVER.exists():
            self.skipTest(
                f"server binary missing at {SERVER}; "
                "run `dune build ./ocaml/server/c2c_mcp_server.exe` first"
            )
        self._tmp = tempfile.TemporaryDirectory()
        self.broker_root = Path(self._tmp.name) / "broker"
        self.broker_root.mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _shutdown(self, *procs: subprocess.Popen) -> None:
        for p in procs:
            try:
                if p.stdin is not None:
                    p.stdin.close()
                p.wait(timeout=5)
            except Exception:
                p.kill()
                p.wait()

    def test_two_peer_send_and_reply_roundtrip(self) -> None:
        start = time.monotonic()
        alice = _spawn_server(self.broker_root, "alice-session")
        bob = _spawn_server(self.broker_root, "bob-session")
        try:
            init_a = _initialize(alice, 1)
            init_b = _initialize(bob, 1)
            self.assertEqual(init_a["result"]["serverInfo"]["name"], "c2c")
            self.assertEqual(init_b["result"]["serverInfo"]["name"], "c2c")

            _tool_call(alice, 2, "register", {"alias": "alice"})
            _tool_call(bob, 2, "register", {"alias": "bob"})

            whoami_a = _tool_call(alice, 3, "whoami", {})
            whoami_text = _tool_text(whoami_a)
            self.assertIn("alice", whoami_text)

            send_resp = _tool_call(
                alice,
                4,
                "send",
                {
                    "from_alias": "alice",
                    "to_alias": "bob",
                    "content": "hello bob",
                },
            )
            self.assertFalse(
                send_resp["result"].get("isError", False),
                f"send reported error: {send_resp!r}",
            )
            receipt = json.loads(_tool_text(send_resp))
            self.assertTrue(receipt.get("queued"), "receipt.queued should be true")
            self.assertEqual(receipt.get("to_alias"), "bob", "receipt.to_alias should be bob")
            self.assertGreater(receipt.get("ts", 0), 0, "receipt.ts should be a positive epoch")

            poll_resp = _tool_call(bob, 5, "poll_inbox", {})
            messages = json.loads(_tool_text(poll_resp))
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0]["from_alias"], "alice")
            self.assertEqual(messages[0]["to_alias"], "bob")
            self.assertEqual(messages[0]["content"], "hello bob")

            _tool_call(
                bob,
                6,
                "send",
                {
                    "from_alias": "bob",
                    "to_alias": "alice",
                    "content": "hi alice",
                },
            )

            poll_back = _tool_call(alice, 7, "poll_inbox", {})
            replies = json.loads(_tool_text(poll_back))
            self.assertEqual(len(replies), 1)
            self.assertEqual(replies[0]["from_alias"], "bob")
            self.assertEqual(replies[0]["content"], "hi alice")
        finally:
            self._shutdown(alice, bob)

        elapsed = time.monotonic() - start
        self.assertLess(
            elapsed,
            60.0,
            f"onboarding round-trip took {elapsed:.1f}s, exceeding 60s budget",
        )

    def test_two_peer_room_send_and_receive(self) -> None:
        """Exercise the N:N room surface in the same smoke test.

        A newly-joined agent should be able to send_room and have
        every other member's `poll_inbox` surface the fan-out.
        """
        alice = _spawn_server(self.broker_root, "alice-room-session")
        bob = _spawn_server(self.broker_root, "bob-room-session")
        try:
            _initialize(alice, 1)
            _initialize(bob, 1)
            _tool_call(alice, 2, "register", {"alias": "alice-room"})
            _tool_call(bob, 2, "register", {"alias": "bob-room"})
            _tool_call(
                alice, 3, "join_room", {"room_id": "smoke", "alias": "alice-room"}
            )
            _tool_call(
                bob, 3, "join_room", {"room_id": "smoke", "alias": "bob-room"}
            )
            send_resp = _tool_call(
                alice,
                4,
                "send_room",
                {
                    "from_alias": "alice-room",
                    "room_id": "smoke",
                    "content": "room hello",
                },
            )
            parsed = json.loads(_tool_text(send_resp))
            self.assertIn("bob-room", parsed["delivered_to"])
            poll_resp = _tool_call(bob, 5, "poll_inbox", {})
            messages = json.loads(_tool_text(poll_resp))
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0]["from_alias"], "alice-room")
            self.assertEqual(messages[0]["content"], "room hello")
            self.assertEqual(messages[0]["to_alias"], "bob-room@smoke")
        finally:
            self._shutdown(alice, bob)


if __name__ == "__main__":
    unittest.main()
