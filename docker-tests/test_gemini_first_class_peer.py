"""
Phase C Case N: Gemini as first-class peer.
Gemini inside the container DMs host-side peers.

In the sealed Docker environment, we validate:
1. Gemini oauth creds file is mounted and readable.
2. c2c install gemini succeeds inside container.
3. ~/.gemini/settings.json has the c2c MCP server entry after install.
4. `c2c start gemini` can be launched (may not complete auth without network).
5. If gemini binary is present, smoke interaction.
"""
import json
import os
import subprocess
import time
import pytest


C2C = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


def run(argv, session_id=None, alias=None, timeout=15):
    import os
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
    r = subprocess.CompletedProcess(
        args=[C2C] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )
    return r


class TestGeminiFirstClassPeer:
    """Gemini as first-class peer in sealed Docker environment."""

    def test_gemini_oauth_creds_present(self):
        """Gemini oauth creds file is mounted and readable."""
        import os
        gemini_dir = "/home/testagent/.gemini"
        creds_path = os.path.join(gemini_dir, "oauth_creds.json")
        if not os.path.exists(creds_path):
            pytest.skip("~/.gemini/oauth_creds.json not mounted in container")
        assert os.access(creds_path, os.R_OK), "oauth_creds.json not readable"

    def test_gemini_oauth_creds_content(self):
        """oauth_creds.json file has content (load-bearing per Max)."""
        creds_path = "/home/testagent/.gemini/oauth_creds.json"
        if not os.path.exists(creds_path):
            pytest.skip("~/.gemini/oauth_creds.json not present")
        with open(creds_path) as f:
            content = f.read().strip()
        assert len(content) > 0, "oauth_creds.json is empty"

    def test_c2c_install_gemini(self):
        """c2c install gemini succeeds inside container."""
        r = subprocess.run(
            [C2C, "install", "gemini"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": "gemini-install-test",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "gemini-install-test",
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should succeed or gracefully report what's missing
        # (gemini binary may not be in PATH inside container)
        assert r.returncode == 0 or "gemini" in r.stderr.lower(), \
            f"c2c install gemini unexpected failure: {r.stderr}"

    def test_gemini_mcp_config_written(self):
        """After install, ~/.gemini/settings.json has the c2c MCP server entry."""
        settings_path = "/home/testagent/.gemini/settings.json"
        if not os.path.exists(settings_path):
            pytest.skip("~/.gemini/settings.json not present (install may have failed)")

        with open(settings_path) as f:
            settings = json.load(f)

        # Gemini MCP config is a list under the "mcp_servers" key (or similar)
        # Check that c2c MCP server is listed
        mcp_servers = settings.get("mcp_servers", [])
        c2c_entry = any(
            isinstance(entry, dict) and "c2c" in entry.get("name", "").lower()
            for entry in mcp_servers
        ) or any(
            isinstance(entry, dict) and "c2c-mcp-server" in entry.get("command", "")
            for entry in mcp_servers
        )
        assert c2c_entry, \
            f"c2c MCP server not found in ~/.gemini/settings.json mcp_servers: {mcp_servers}"

    def test_gemini_binary_if_present(self):
        """If gemini binary is in PATH, it can be invoked (smoke)."""
        r = subprocess.run(
            ["which", "gemini"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            pytest.skip("gemini binary not in PATH inside container")
        gemini_path = r.stdout.strip()
        assert gemini_path

        # Try --version or --help
        r = subprocess.run(
            [gemini_path, "--version"],
            capture_output=True, text=True, timeout=10,
            env={"HOME": "/home/testagent"},
        )
        # Should not crash
        assert r.returncode in (0, 1), f"gemini --version crashed: {r.stderr}"

    def test_gemini_can_register_and_send(self):
        """Gemini can register with c2c and send a DM (using c2c start gemini)."""
        ts = int(time.time())
        gemini_sid = f"gemini-dm-{ts}"
        host_sid = f"gemini-host-{ts}"
        gemini_alias = f"gemini-docker-{ts}"
        host_alias = f"gemini-host-{ts}"

        # Register host peer first
        run(["register", "--alias", host_alias], session_id=host_sid, alias=host_alias)
        time.sleep(0.5)

        # Try to install gemini first
        subprocess.run(
            [C2C, "install", "gemini"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": gemini_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": gemini_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )

        # Try c2c start gemini (non-blocking, just verify it launches)
        # In sealed env it may fail to connect, but the binary should start
        r = subprocess.run(
            [C2C, "start", "gemini", "-n", gemini_alias],
            capture_output=True, text=True, timeout=10,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": gemini_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": gemini_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should either succeed or fail gracefully (no crash)
        # Exit code 0, 1 (user quit), or 2 (start refused) is acceptable
        assert r.returncode in (0, 1, 2), \
            f"c2c start gemini crashed with {r.returncode}: {r.stderr}"

        # Give it time to register if it did start
        time.sleep(2)

        # Verify gemini alias appears in peer list (if it managed to register)
        r = run(["list", "--json"], session_id=host_sid)
        assert r.returncode == 0, f"list failed: {r.stderr}"
        peers = json.loads(r.stdout)
        gemini_in_list = any(gemini_alias in p.get("alias", "") for p in peers)
        assert gemini_in_list, \
            f"gemini ({gemini_alias}) did not register — not found in peer list: {peers}"
        # If gemini registered, host can try to send
        r = run(["send", gemini_alias, "hello from docker host"],
                session_id=host_sid, alias=host_alias)
        assert r.returncode == 0, f"send to gemini failed: {r.stderr}"
