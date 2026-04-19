"""Integration tests for c2c MCP server channel delivery.

These tests launch the actual OCaml MCP server binary, communicate via
stdin/stdout JSON-RPC, and verify channel notification behavior end-to-end.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
MCP_SERVER_EXE = REPO / "_build" / "default" / "ocaml" / "server" / "c2c_mcp_server.exe"

# Skip entire module if binary not built
pytestmark = pytest.mark.skipif(
    not MCP_SERVER_EXE.exists(),
    reason=f"MCP server binary not built: {MCP_SERVER_EXE}",
)


def send_jsonrpc(proc: subprocess.Popen, obj: dict) -> None:
    """Send a JSON-RPC message to the server via stdin."""
    line = json.dumps(obj) + "\n"
    proc.stdin.write(line)
    proc.stdin.flush()


def read_jsonrpc(proc: subprocess.Popen, timeout: float = 5.0) -> dict:
    """Read a JSON-RPC message from stdout, with timeout."""
    import select

    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    if not ready:
        raise TimeoutError("No response from MCP server within timeout")
    line = proc.stdout.readline()
    if not line:
        raise EOFError("MCP server closed stdout")
    return json.loads(line)


def read_all_jsonrpc(proc: subprocess.Popen, timeout: float = 3.0) -> list[dict]:
    """Read all available JSON-RPC messages until timeout."""
    import select

    messages = []
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            break
        line = proc.stdout.readline()
        if not line:
            break
        messages.append(json.loads(line))
    return messages


def start_server(
    broker_root: str,
    session_id: str,
    *,
    channel_delivery: bool = True,
    auto_drain: bool = False,
    auto_register_alias: str = "",
    auto_join_rooms: str = "",
    watcher_delay: str = "0",
) -> subprocess.Popen:
    """Start the MCP server as a subprocess.

    watcher_delay defaults to "0" (not the 30s production default) so
    existing tests observe near-immediate channel delivery. Delay-
    specific tests (TestWatcherDrainDelay) pass an explicit non-zero
    value.
    """
    env = {
        **os.environ,
        "C2C_MCP_BROKER_ROOT": broker_root,
        "C2C_MCP_SESSION_ID": session_id,
        "C2C_MCP_CHANNEL_DELIVERY": "1" if channel_delivery else "0",
        "C2C_MCP_AUTO_DRAIN_CHANNEL": "1" if auto_drain else "0",
        "C2C_MCP_AUTO_REGISTER_ALIAS": auto_register_alias,
        "C2C_MCP_AUTO_JOIN_ROOMS": auto_join_rooms,
        "C2C_MCP_INBOX_WATCHER_DELAY": watcher_delay,
    }
    proc = subprocess.Popen(
        [str(MCP_SERVER_EXE)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )
    return proc


@pytest.fixture
def broker_dir(tmp_path: Path) -> Path:
    """Create a temporary broker root directory."""
    d = tmp_path / "broker"
    d.mkdir()
    return d


def initialize_server(proc: subprocess.Popen, *, with_channel: bool = False) -> dict:
    """Send initialize and return the response."""
    params: dict = {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "test-harness", "version": "0.0.1"},
    }
    if with_channel:
        params["capabilities"] = {
            "experimental": {"claude/channel": {}}
        }
    send_jsonrpc(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": params,
    })
    return read_jsonrpc(proc)


class TestInitializeChannelCapability:
    """Verify the server declares channel capability in initialize response."""

    def test_server_declares_channel_capability(self, broker_dir: Path) -> None:
        proc = start_server(str(broker_dir), "test-session-1")
        try:
            resp = initialize_server(proc)
            caps = resp["result"]["capabilities"]
            assert "experimental" in caps
            assert caps["experimental"]["claude/channel"] == {}
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_server_declares_capability_regardless_of_client(
        self, broker_dir: Path
    ) -> None:
        """Server declares its capability even if client doesn't."""
        proc = start_server(str(broker_dir), "test-session-2")
        try:
            resp = initialize_server(proc, with_channel=False)
            caps = resp["result"]["capabilities"]
            assert caps["experimental"]["claude/channel"] == {}
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_initialize_returns_server_info(self, broker_dir: Path) -> None:
        proc = start_server(str(broker_dir), "test-session-3")
        try:
            resp = initialize_server(proc)
            server_info = resp["result"]["serverInfo"]
            assert server_info["name"] == "c2c"
            assert "version" in server_info
            assert "features" in server_info
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_initialize_returns_protocol_version(self, broker_dir: Path) -> None:
        proc = start_server(str(broker_dir), "test-session-4")
        try:
            resp = initialize_server(proc)
            assert resp["result"]["protocolVersion"] == "2024-11-05"
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class TestSendAndPollRoundTrip:
    """Verify message send + poll_inbox round-trip via MCP tools."""

    def _register(self, proc, session_id: str, alias: str) -> dict:
        send_jsonrpc(proc, {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "register",
                "arguments": {"session_id": session_id, "alias": alias},
            },
        })
        return read_jsonrpc(proc)

    def _send(self, proc, to_alias: str, content: str) -> dict:
        send_jsonrpc(proc, {
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": {
                "name": "send",
                "arguments": {"to_alias": to_alias, "content": content},
            },
        })
        return read_jsonrpc(proc)

    def _poll_inbox(self, proc) -> dict:
        send_jsonrpc(proc, {
            "jsonrpc": "2.0",
            "id": 30,
            "method": "tools/call",
            "params": {"name": "poll_inbox", "arguments": {}},
        })
        return read_jsonrpc(proc)

    def test_send_and_poll_round_trip(self, broker_dir: Path) -> None:
        """Two sessions on same broker: send from A, poll from B.
        Starts servers sequentially to avoid registry write races,
        then uses MCP register tool to ensure both are registered."""
        # Start server A first, let it auto-register
        proc_a = start_server(
            str(broker_dir), "session-a",
            channel_delivery=False, auto_register_alias="alice",
        )
        # Small delay to let A finish auto-register before B starts
        time.sleep(0.2)
        proc_b = start_server(
            str(broker_dir), "session-b",
            channel_delivery=False, auto_register_alias="bob",
        )
        time.sleep(0.2)
        try:
            # Initialize both
            initialize_server(proc_a)
            initialize_server(proc_b)

            # Explicitly register via MCP to ensure both are in the
            # registry (auto-register may race on shared broker root)
            reg_a = self._register(proc_a, "session-a", "alice")
            reg_b = self._register(proc_b, "session-b", "bob")

            # Send from A to B
            send_resp = self._send(proc_a, "bob", "hello from alice")
            assert "result" in send_resp
            text = send_resp["result"]["content"][0]["text"]
            result = json.loads(text)
            assert result.get("queued") is True, f"Send failed: {text}"

            # Poll from B
            poll_resp = self._poll_inbox(proc_b)
            assert "result" in poll_resp
            poll_text = poll_resp["result"]["content"][0]["text"]
            messages = json.loads(poll_text)
            assert len(messages) == 1
            assert "hello from alice" in messages[0]["content"]
            assert messages[0]["from_alias"] == "alice"
        finally:
            proc_a.terminate()
            proc_b.terminate()
            proc_a.wait(timeout=5)
            proc_b.wait(timeout=5)

    def test_poll_empty_inbox_returns_empty_array(self, broker_dir: Path) -> None:
        proc = start_server(
            str(broker_dir), "session-empty",
            channel_delivery=False, auto_register_alias="lonely",
        )
        try:
            initialize_server(proc)
            self._register(proc, "session-empty", "lonely")
            poll_resp = self._poll_inbox(proc)
            text = poll_resp["result"]["content"][0]["text"]
            messages = json.loads(text)
            assert messages == []
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class TestChannelNotificationDelivery:
    """Verify background inbox watcher emits channel notifications."""

    def test_watcher_emits_notification_on_new_message(
        self, broker_dir: Path
    ) -> None:
        """When a message is written to the inbox file externally,
        the background watcher should detect it and emit a
        notifications/claude/channel notification on stdout."""
        session_id = "session-watcher"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
            auto_register_alias="watcher-test",
        )
        try:
            initialize_server(proc)

            # Write a message directly to the inbox file (simulating
            # another process sending a message)
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "external-sender",
                "to_alias": "watcher-test",
                "content": "channel test message",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Wait for the watcher to pick it up (polls every 1s)
            # Read all messages for up to 3 seconds
            notifications = read_all_jsonrpc(proc, timeout=3.0)

            # Filter for channel notifications
            channel_notifs = [
                n for n in notifications
                if n.get("method") == "notifications/claude/channel"
            ]
            assert len(channel_notifs) >= 1, (
                f"Expected at least 1 channel notification, got {len(channel_notifs)}. "
                f"All messages: {notifications}"
            )

            notif = channel_notifs[0]
            assert notif["jsonrpc"] == "2.0"
            assert "id" not in notif  # notifications have no id
            assert notif["params"]["content"] == "channel test message"
            assert notif["params"]["meta"]["from_alias"] == "external-sender"
            assert notif["params"]["meta"]["to_alias"] == "watcher-test"
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_watcher_handles_missing_inbox_at_startup(
        self, broker_dir: Path
    ) -> None:
        """Watcher should not die when inbox file doesn't exist at startup.
        It should start delivering once messages arrive later."""
        session_id = "session-lazy"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
        )
        try:
            initialize_server(proc)

            # Inbox file doesn't exist yet - watcher should survive
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            assert not inbox_path.exists()

            # Wait a bit to let the watcher tick a few times
            time.sleep(2.5)

            # Now write a message - watcher should pick it up
            msg = {
                "from_alias": "late-sender",
                "to_alias": "lazy-agent",
                "content": "arrived after startup",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Read notifications
            notifications = read_all_jsonrpc(proc, timeout=3.0)
            channel_notifs = [
                n for n in notifications
                if n.get("method") == "notifications/claude/channel"
            ]
            assert len(channel_notifs) >= 1, (
                f"Expected watcher to survive and deliver, got: {notifications}"
            )
            assert channel_notifs[0]["params"]["content"] == "arrived after startup"
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_watcher_delivers_multiple_batches(
        self, broker_dir: Path
    ) -> None:
        """Watcher should deliver a second batch even if it's smaller than
        the first (regression test for the pre-drain-size bug)."""
        session_id = "session-multi"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
        )
        try:
            initialize_server(proc)
            inbox_path = broker_dir / f"{session_id}.inbox.json"

            # First batch: large message
            msg1 = {
                "from_alias": "sender",
                "to_alias": "multi",
                "content": "A" * 500,  # large message
            }
            inbox_path.write_text(json.dumps([msg1]))

            # Wait for watcher to drain first batch
            batch1 = read_all_jsonrpc(proc, timeout=3.0)
            channel1 = [
                n for n in batch1
                if n.get("method") == "notifications/claude/channel"
            ]
            assert len(channel1) >= 1, f"First batch not delivered: {batch1}"

            # Second batch: smaller message (this was the bug — old code
            # used pre-drain file size, so smaller messages were invisible)
            msg2 = {
                "from_alias": "sender",
                "to_alias": "multi",
                "content": "small",
            }
            inbox_path.write_text(json.dumps([msg2]))

            # Wait for watcher to deliver second batch
            batch2 = read_all_jsonrpc(proc, timeout=3.0)
            channel2 = [
                n for n in batch2
                if n.get("method") == "notifications/claude/channel"
            ]
            assert len(channel2) >= 1, (
                f"Second (smaller) batch not delivered — regression! "
                f"Got: {batch2}"
            )
            assert channel2[0]["params"]["content"] == "small"
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_auto_drain_after_rpc_when_client_capable(
        self, broker_dir: Path
    ) -> None:
        """When client declares channel support and auto-drain is on,
        the server should drain inbox and emit notifications after
        each RPC response."""
        session_id = "session-autodrain"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=False,  # disable watcher
            auto_drain=True,
            auto_register_alias="drainer",
        )
        try:
            # Initialize WITH channel capability
            resp = initialize_server(proc, with_channel=True)
            assert resp["result"]["capabilities"]["experimental"]["claude/channel"] == {}

            # Write a message to inbox
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "peer",
                "to_alias": "drainer",
                "content": "auto-drain test",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Send any RPC to trigger auto-drain
            send_jsonrpc(proc, {
                "jsonrpc": "2.0",
                "id": 99,
                "method": "tools/list",
                "params": {},
            })

            # Read the tools/list response AND any notifications
            messages = read_all_jsonrpc(proc, timeout=3.0)

            # Should have the tools/list response
            responses = [m for m in messages if "id" in m]
            assert len(responses) >= 1

            # Should have a channel notification from auto-drain
            channel_notifs = [
                m for m in messages
                if m.get("method") == "notifications/claude/channel"
            ]
            assert len(channel_notifs) >= 1, (
                f"Expected auto-drain notification, got: {messages}"
            )
            assert channel_notifs[0]["params"]["content"] == "auto-drain test"
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_no_auto_drain_when_client_not_capable(
        self, broker_dir: Path
    ) -> None:
        """When client does NOT declare channel support, auto-drain should
        NOT emit notifications even if C2C_MCP_AUTO_DRAIN_CHANNEL=1."""
        session_id = "session-nocap"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=False,  # disable watcher too
            auto_drain=True,
            auto_register_alias="nocap",
        )
        try:
            # Initialize WITHOUT channel capability
            initialize_server(proc, with_channel=False)

            # Write a message to inbox
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "peer",
                "to_alias": "nocap",
                "content": "should not drain",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Send RPC to trigger potential auto-drain
            send_jsonrpc(proc, {
                "jsonrpc": "2.0",
                "id": 99,
                "method": "tools/list",
                "params": {},
            })

            # Read responses
            messages = read_all_jsonrpc(proc, timeout=2.0)

            # Should NOT have channel notifications
            channel_notifs = [
                m for m in messages
                if m.get("method") == "notifications/claude/channel"
            ]
            assert len(channel_notifs) == 0, (
                f"Auto-drain should NOT fire without client capability, "
                f"but got: {channel_notifs}"
            )

            # Message should still be in inbox (not drained)
            inbox_content = json.loads(inbox_path.read_text())
            assert len(inbox_content) == 1
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class TestWatcherDrainDelay:
    """Verify C2C_MCP_INBOX_WATCHER_DELAY delays the watcher's drain."""

    def test_watcher_respects_drain_delay(self, broker_dir: Path) -> None:
        """With a non-zero delay, no notification should arrive before the
        delay elapses; after the delay, the message should be delivered."""
        session_id = "session-delay"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
            watcher_delay="1.2",
        )
        try:
            initialize_server(proc)

            # Write a message immediately
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "sender",
                "to_alias": "delayed",
                "content": "delayed delivery",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Watcher ticks every ~1s, then sleeps delay=1.2s before
            # draining. So at t < ~1s nothing should be emitted yet.
            early = read_all_jsonrpc(proc, timeout=0.6)
            early_notifs = [
                n for n in early
                if n.get("method") == "notifications/claude/channel"
            ]
            assert early_notifs == [], (
                f"Expected no notifications before delay elapsed, "
                f"got: {early_notifs}"
            )

            # Wait longer for the watcher to fire after the delay elapses.
            # Total bound: 1s tick + 1.2s delay + slack = <=4s
            late = read_all_jsonrpc(proc, timeout=4.0)
            late_notifs = [
                n for n in late
                if n.get("method") == "notifications/claude/channel"
            ]
            assert len(late_notifs) >= 1, (
                f"Expected notification after delay elapsed, got: {late}"
            )
            assert late_notifs[0]["params"]["content"] == "delayed delivery"
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_watcher_skips_emit_when_hook_drains_first(
        self, broker_dir: Path
    ) -> None:
        """If something (hook) drains the inbox during the delay window,
        the watcher should drain, see an empty list, and emit nothing."""
        session_id = "session-hook-wins"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
            watcher_delay="1.5",
        )
        try:
            initialize_server(proc)

            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "sender",
                "to_alias": "raced",
                "content": "hook got here first",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Simulate hook draining the inbox before the watcher wakes.
            # Give the watcher ~0.3s to notice the size increase, then drain.
            time.sleep(0.5)
            inbox_path.write_text("[]")

            # Watcher's delay is 1.5s, so watcher finishes after ~1s + 1.5s
            # = 2.5s. Wait longer, then assert no notification was emitted.
            notifs = read_all_jsonrpc(proc, timeout=3.5)
            channel_notifs = [
                n for n in notifs
                if n.get("method") == "notifications/claude/channel"
            ]
            assert channel_notifs == [], (
                f"Expected no channel notification when hook drained "
                f"inbox first, got: {channel_notifs}"
            )
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class TestE2ESessionLifecycle:
    """End-to-end test simulating a full Claude Code MCP session lifecycle.

    This is the closest we can get to a real e2e test without launching
    Claude Code itself (which requires an API key, is non-deterministic,
    and expensive). It exercises the full protocol contract:

    1. initialize (server declares channel capability)
    2. register (agent claims an alias)
    3. External peer writes to inbox (simulating another agent's send)
    4. Background watcher detects and emits channel notification
    5. Agent calls poll_inbox (messages already drained by watcher)
    6. Verify archive contains the delivered messages

    A true Claude Code e2e test would additionally verify that the
    notifications render in the chat UI, but that requires the
    --dangerously-load-development-channels flag and an interactive
    Claude Code session.
    """

    def test_full_session_lifecycle(self, broker_dir: Path) -> None:
        session_id = "session-e2e"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=True,
            auto_drain=False,
            auto_register_alias="e2e-agent",
            auto_join_rooms="test-room",
        )
        try:
            # Step 1: Initialize
            resp = initialize_server(proc)
            assert resp["result"]["capabilities"]["experimental"]["claude/channel"] == {}
            assert resp["result"]["serverInfo"]["name"] == "c2c"

            # Step 2: Verify registration via whoami
            send_jsonrpc(proc, {
                "jsonrpc": "2.0", "id": 2,
                "method": "tools/call",
                "params": {"name": "whoami", "arguments": {}},
            })
            whoami = read_jsonrpc(proc)
            whoami_text = whoami["result"]["content"][0]["text"]
            assert "e2e-agent" in whoami_text

            # Step 3: External peer writes to inbox
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            messages_to_deliver = [
                {
                    "from_alias": "peer-alpha",
                    "to_alias": "e2e-agent",
                    "content": "first message",
                },
                {
                    "from_alias": "peer-beta",
                    "to_alias": "e2e-agent",
                    "content": "second message",
                },
            ]
            inbox_path.write_text(json.dumps(messages_to_deliver))

            # Step 4: Background watcher detects and emits notifications.
            # Read in multiple rounds to handle Lwt IO buffering timing.
            channel_notifs = []
            deadline = time.monotonic() + 5.0
            while len(channel_notifs) < 2 and time.monotonic() < deadline:
                remaining = deadline - time.monotonic()
                batch = read_all_jsonrpc(proc, timeout=min(remaining, 2.0))
                channel_notifs.extend(
                    n for n in batch
                    if n.get("method") == "notifications/claude/channel"
                )

            assert len(channel_notifs) == 2, (
                f"Expected 2 channel notifications, got {len(channel_notifs)}: "
                f"{channel_notifs}"
            )
            contents = {n["params"]["content"] for n in channel_notifs}
            assert "first message" in contents
            assert "second message" in contents

            # Verify no "id" field in notifications (JSON-RPC 2.0 compliance)
            for n in channel_notifs:
                assert "id" not in n

            # Step 5: poll_inbox should return empty (watcher already drained)
            send_jsonrpc(proc, {
                "jsonrpc": "2.0", "id": 5,
                "method": "tools/call",
                "params": {"name": "poll_inbox", "arguments": {}},
            })
            poll_resp = read_jsonrpc(proc)
            poll_text = poll_resp["result"]["content"][0]["text"]
            poll_messages = json.loads(poll_text)
            assert poll_messages == [], (
                f"Inbox should be empty after watcher drain, got: {poll_messages}"
            )

            # Step 6: Verify archive exists and has the messages
            archive_dir = broker_dir / "archive"
            if archive_dir.exists():
                archive_path = archive_dir / f"{session_id}.jsonl"
                if archive_path.exists():
                    lines = archive_path.read_text().strip().splitlines()
                    archived = [json.loads(l) for l in lines]
                    assert len(archived) == 2
                    assert archived[0]["from_alias"] == "peer-alpha"
                    assert archived[1]["from_alias"] == "peer-beta"

            # Step 7: Verify room membership (auto-joined test-room)
            send_jsonrpc(proc, {
                "jsonrpc": "2.0", "id": 7,
                "method": "tools/call",
                "params": {"name": "my_rooms", "arguments": {}},
            })
            rooms_resp = read_jsonrpc(proc)
            rooms_text = rooms_resp["result"]["content"][0]["text"]
            assert "test-room" in rooms_text
        finally:
            proc.terminate()
            proc.wait(timeout=5)


class TestChannelDeliveryDisabled:
    """Verify that channel_delivery=false disables the watcher."""

    def test_no_notifications_when_delivery_disabled(
        self, broker_dir: Path
    ) -> None:
        session_id = "session-disabled"
        proc = start_server(
            str(broker_dir), session_id,
            channel_delivery=False,
            auto_drain=False,
        )
        try:
            initialize_server(proc)

            # Write a message
            inbox_path = broker_dir / f"{session_id}.inbox.json"
            msg = {
                "from_alias": "peer",
                "to_alias": "disabled",
                "content": "should not notify",
            }
            inbox_path.write_text(json.dumps([msg]))

            # Wait and check - no notifications should arrive
            messages = read_all_jsonrpc(proc, timeout=3.0)
            channel_notifs = [
                m for m in messages
                if m.get("method") == "notifications/claude/channel"
            ]
            assert len(channel_notifs) == 0, (
                f"Should not emit notifications when delivery disabled: {channel_notifs}"
            )
        finally:
            proc.terminate()
            proc.wait(timeout=5)
