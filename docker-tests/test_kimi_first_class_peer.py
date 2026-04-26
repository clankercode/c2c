"""
Phase C Case 10: Kimi as first-class peer.
Kimi inside the container DMs Claude/Codex/OpenCode peers.
Today's special goal — core validation.

In the sealed Docker environment, we validate:
1. All four Kimi auth files are mounted and readable.
2. c2c install kimi succeeds inside container.
3. `c2c start kimi` can be launched (may not complete auth without network).
4. If kimi binary is present, try a smoke interaction.
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
    # Use Popen so we capture the real subprocess PID before it exits.
    # Setting C2C_MCP_CLIENT_PID before Popen uses a placeholder; the real PID
    # is captured from proc.pid and stored for the *next* call's env so the
    # broker tracks the subprocess PID rather than the pytest PID.
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


class TestKimiFirstClassPeer:
    """Case 10: Kimi as first-class peer in sealed Docker environment."""

    def test_kimi_auth_files_present(self):
        """All four Kimi auth files are mounted and readable."""
        import os
        kimi_dir = "/home/testagent/.kimi"
        required = ["credentials", "device_id", "kimi.json", "config.toml"]
        missing = []
        for f in required:
            path = os.path.join(kimi_dir, f)
            if not os.path.exists(path):
                missing.append(f)
            else:
                # Readable?
                assert os.access(path, os.R_OK), f"{f} not readable"
        assert not missing, f"missing kimi auth files: {missing}"

    def test_kimi_credentials_content(self):
        """credentials file has content (load-bearing per Max)."""
        with open("/home/testagent/.kimi/credentials") as f:
            content = f.read().strip()
        assert len(content) > 0, "credentials file is empty"

    def test_c2c_install_kimi(self):
        """c2c install kimi succeeds inside container."""
        # c2c install writes config files; uses HOME=/home/testagent
        r = subprocess.run(
            [C2C, "install", "kimi"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": "kimi-install-test",
                "C2C_MCP_AUTO_REGISTER_ALIAS": "kimi-install-test",
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should succeed or gracefully report what's missing
        # (kimi binary may not be in PATH inside container)
        assert r.returncode == 0 or "kimi" in r.stderr.lower(), \
            f"c2c install kimi unexpected failure: {r.stderr}"

    def test_kimi_binary_if_present(self):
        """If kimi binary is in PATH, it can be invoked (smoke)."""
        r = subprocess.run(
            ["which", "kimi"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            pytest.skip("kimi binary not in PATH inside container")
        kimi_path = r.stdout.strip()
        assert kimi_path

        # Try --version or --help
        r = subprocess.run(
            [kimi_path, "--version"],
            capture_output=True, text=True, timeout=10,
            env={"HOME": "/home/testagent"},
        )
        # Should not crash
        assert r.returncode in (0, 1), f"kimi --version crashed: {r.stderr}"

    def test_kimi_can_register_and_send(self):
        """Kimi can register with c2c and send a DM (using c2c start kimi)."""
        ts = int(time.time())
        kimi_sid = f"kimi-dm-{ts}"
        host_sid = f"kimi-host-{ts}"
        kimi_alias = f"kimi-docker-{ts}"
        host_alias = f"kimi-host-{ts}"

        # Register host peer first
        run(["register", "--alias", host_alias], session_id=host_sid, alias=host_alias)
        time.sleep(0.5)

        # Try to install kimi first
        subprocess.run(
            [C2C, "install", "kimi"],
            capture_output=True, text=True, timeout=30,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": kimi_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": kimi_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )

        # Try c2c start kimi (non-blocking, just verify it launches)
        # In sealed env it may fail to connect, but the binary should start
        r = subprocess.run(
            [C2C, "start", "kimi", "-n", kimi_alias],
            capture_output=True, text=True, timeout=10,
            env={
                "HOME": "/home/testagent",
                "C2C_MCP_SESSION_ID": kimi_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": kimi_alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        # Should either succeed or fail gracefully (no crash)
        # Exit code 0 or 1 (user quit) is acceptable
        assert r.returncode in (0, 1, 2), \
            f"c2c start kimi crashed with {r.returncode}: {r.stderr}"

        # Give it time to register if it did start
        time.sleep(2)

        # Verify kimi alias appears in peer list (if it managed to register)
        r = run(["list", "--json"], session_id=host_sid)
        assert r.returncode == 0, f"list failed: {r.stderr}"
        peers = json.loads(r.stdout)
        kimi_in_list = any(kimi_alias in p.get("alias", "") for p in peers)
        assert kimi_in_list, \
            f"kimi ({kimi_alias}) did not register — not found in peer list: {peers}"
        # If kimi registered, host can try to send
        r = run(["send", kimi_alias, "hello from docker host"],
                session_id=host_sid, alias=host_alias)
        assert r.returncode == 0, f"send to kimi failed: {r.stderr}"
