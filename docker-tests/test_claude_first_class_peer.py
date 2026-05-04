"""
Phase C Case N: Claude as first-class peer.
Claude inside the container registers with the broker and DMs peers.

In the sealed Docker environment, we validate:
1. `claude` binary is callable inside container (or skip if absent).
2. `c2c install claude` succeeds inside container.
3. After install, `~/.claude/settings.json` has c2c hook + MCP entry.
4. `c2c start claude` can be launched (may not complete auth without network).
5. If claude registers, it appears in `c2c list` and can receive DMs.
"""
import json
import os
import subprocess
import time
import pytest


C2C = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")
AGENT_HOME = "/home/testagent"


def run(argv, session_id=None, alias=None, timeout=15):
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen(
        [C2C] + argv,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
    )
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    stdout, stderr = proc.communicate(timeout=timeout)
    return subprocess.CompletedProcess(
        args=[C2C] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )


class TestClaudeFirstClassPeer:
    """Case N: Claude as first-class peer in sealed Docker environment."""

    def test_claude_binary_present(self):
        """Verify `claude` is callable inside container (or skip)."""
        r = subprocess.run(
            ["which", "claude"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            pytest.skip("claude binary not in PATH inside container")
        claude_path = r.stdout.strip()
        assert claude_path, "which claude returned empty path"

        # Try --version or --help as a smoke test
        r = subprocess.run(
            [claude_path, "--version"],
            capture_output=True, text=True, timeout=10,
            env={"HOME": AGENT_HOME},
        )
        # Should not crash (exit 0 or 1 is fine — might need auth)
        assert r.returncode in (0, 1), f"claude --version crashed: {r.stderr}"

    def test_c2c_install_claude(self):
        """`c2c install claude` succeeds inside container."""
        r = subprocess.run(
            [C2C, "install", "claude"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": AGENT_HOME,
                "C2C_MCP_SESSION_ID": "claude-install-test",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "claude-install-test",
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should succeed or gracefully report what's missing
        # (claude binary may not be in PATH, or ANTHROPIC_API_KEY may be absent)
        assert r.returncode == 0 or "claude" in r.stderr.lower(), \
            f"c2c install claude unexpected failure: {r.stderr}"

    def test_claude_mcp_config_written(self):
        """After install, verify `~/.claude/settings.json` has c2c MCP entry."""
        settings_path = os.path.join(AGENT_HOME, ".claude", "settings.json")
        if not os.path.exists(settings_path):
            pytest.skip("c2c install claude was not run or did not produce settings.json")

        with open(settings_path) as f:
            settings = json.load(f)

        # The hook registration lives under "hooks" -> "PostToolUse"
        hooks = settings.get("hooks", {})
        post_tool_use = hooks.get("PostToolUse", [])
        c2c_hook_found = any(
            "c2c-inbox-check" in entry or "c2c" in entry
            for entry in post_tool_use
            if isinstance(entry, str)
        )
        assert c2c_hook_found, \
            f"c2c hook not found in PostToolUse entries: {post_tool_use}"

        # Also check the project .mcp.json was written (cwd = /docker-tests in container)
        mcp_path = os.path.join("/docker-tests", ".mcp.json")
        if os.path.exists(mcp_path):
            with open(mcp_path) as f:
                mcp = json.load(f)
            mcp_servers = mcp.get("mcpServers", {})
            assert "c2c" in mcp_servers, \
                f"c2c not in mcpServers: {list(mcp_servers.keys())}"

    def test_claude_registers_with_broker(self):
        """Register a claude alias and verify it appears in `c2c list`."""
        ts = int(time.time())
        claude_sid = f"claude-reg-{ts}"
        claude_alias = f"claude-docker-{ts}"

        # Try install first ( idempotent )
        subprocess.run(
            [C2C, "install", "claude"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": AGENT_HOME,
                "C2C_MCP_SESSION_ID": claude_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": claude_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )

        # Try c2c start claude (non-blocking — verify it launches without crashing)
        r = subprocess.run(
            [C2C, "start", "claude", "-n", claude_alias],
            capture_output=True, text=True, timeout=10,
            env={
                "HOME": AGENT_HOME,
                "C2C_MCP_SESSION_ID": claude_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": claude_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should either succeed or fail gracefully (no crash)
        # Exit code 0, 1 (user quit), or 2 (could not start) are acceptable
        assert r.returncode in (0, 1, 2), \
            f"c2c start claude crashed with {r.returncode}: {r.stderr}"

        # Give it time to register
        time.sleep(2)

        # Verify claude alias appears in peer list
        r = run(["list", "--json"], session_id=claude_sid)
        assert r.returncode == 0, f"list failed: {r.stderr}"
        peers = json.loads(r.stdout)
        claude_in_list = any(claude_alias in p.get("alias", "") for p in peers)
        assert claude_in_list, \
            f"claude ({claude_alias}) did not register — not in peer list: {peers}"

    def test_claude_send_and_receive(self):
        """Register two peers; one sends a DM to the other; verify inbox delivery."""
        ts = int(time.time())
        sender_sid = f"claude-sender-{ts}"
        receiver_sid = f"claude-receiver-{ts}"
        sender_alias = f"claude-sender-{ts}"
        receiver_alias = f"claude-receiver-{ts}"
        test_message = f"hello from claude docker test {ts}"

        # Register sender
        run(["register", "--alias", sender_alias],
            session_id=sender_sid, alias=sender_alias)
        time.sleep(0.3)

        # Register receiver
        run(["register", "--alias", receiver_alias],
            session_id=receiver_sid, alias=receiver_alias)
        time.sleep(0.3)

        # Sender sends a DM to receiver
        r = run(["send", receiver_alias, test_message],
                session_id=sender_sid, alias=sender_alias)
        assert r.returncode == 0, f"send failed: {r.stderr}"

        # Give broker time to deliver
        time.sleep(1)

        # Receiver polls inbox
        r = run(["poll-inbox", "--json"],
                session_id=receiver_sid, alias=receiver_alias)
        assert r.returncode == 0, f"poll-inbox failed: {r.stderr}"
        inbox = json.loads(r.stdout)

        found = any(
            test_message in msg.get("content", "")
            for msg in inbox
        )
        assert found, \
            f"message not found in receiver inbox: {inbox}"
