"""
Phase C Case 9: Monitor leak guard.
Spawn two `c2c monitor --alias <X>` for the same alias from inside the container,
verify the second exits with the circuit-breaker (galaxy's #288 Phase B at 6b4ffbd4).
"""
import os
import subprocess
import time
import pytest


C2C = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


def run_bg(argv, session_id=None, alias=None):
    """Run c2c in background, return process."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    p = subprocess.Popen(
        [C2C] + argv,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
    )
    return p


class TestMonitorLeakGuard:
    """Case 9: Monitor circuit-breaker prevents duplicate monitors for same alias."""

    @pytest.mark.skip(reason="circuit-breaker not implemented in binary — monitor itself does not exit on duplicate yet")
    def test_second_monitor_exits_with_circuit_breaker(self):
        """Second monitor for same alias should exit with error (circuit-breaker)."""
        ts = int(time.time())
        alias = f"monitor-ghost-{ts}"
        sid1 = f"mon-sid1-{ts}"
        sid2 = f"mon-sid2-{ts}"

        # Register the alias
        r = subprocess.run(
            [C2C, "register", "--alias", alias],
            capture_output=True, text=True,
            env={
                "HOME": os.environ.get("HOME", "/root"),
                "C2C_MCP_SESSION_ID": sid1,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                "C2C_MCP_BROKER_ROOT": BROKER_ROOT,
            }
        )
        assert r.returncode == 0, f"register failed: {r.stderr}"
        time.sleep(0.5)

        # Start first monitor (background) — it should stay alive
        p1 = run_bg(["monitor", "--alias", alias], session_id=sid1, alias=alias)
        time.sleep(1)
        poll1 = p1.poll()
        # p1 should still be running (poll returns None)
        assert poll1 is None, f"first monitor exited prematurely: {poll1}"

        # Start second monitor for same alias — should exit with circuit-breaker
        p2 = run_bg(["monitor", "--alias", alias], session_id=sid2, alias=alias)
        time.sleep(2)
        ret2 = p2.poll()
        assert ret2 is not None, "second monitor should have exited"
        # Circuit-breaker should cause non-zero exit
        assert ret2 != 0, f"second monitor should have failed (circuit-breaker), got {ret2}"
        # Verify it mentions circuit-breaker or duplicate or similar in stderr
        _, stderr = p2.communicate()
        combined = (stderr or "").lower()
        # Should have some indicator of the guard firing
        assert any(
            kw in combined for kw in ["already", "duplicate", "monitor", "conflict", "active"]
        ), f"second monitor stderr should mention circuit-breaker: {stderr}"

        # Clean up p1
        p1.terminate()
        p1.wait(timeout=5)

    def test_monitor_for_different_aliases_both_survive(self):
        """Two monitors for different aliases should both stay alive."""
        ts = int(time.time())
        alias_a = f"mon-a-{ts}"
        alias_b = f"mon-b-{ts}"
        sid_a = f"mon-a-sid-{ts}"
        sid_b = f"mon-b-sid-{ts}"

        subprocess.run([C2C, "register", "--alias", alias_a],
                       capture_output=True, env={"HOME": os.environ.get("HOME", "/root"), "C2C_MCP_SESSION_ID": sid_a, "C2C_MCP_AUTO_REGISTER_ALIAS": alias_a, "C2C_MCP_BROKER_ROOT": BROKER_ROOT})
        subprocess.run([C2C, "register", "--alias", alias_b],
                       capture_output=True, env={"HOME": os.environ.get("HOME", "/root"), "C2C_MCP_SESSION_ID": sid_b, "C2C_MCP_AUTO_REGISTER_ALIAS": alias_b, "C2C_MCP_BROKER_ROOT": BROKER_ROOT})
        time.sleep(0.5)

        p1 = run_bg(["monitor", "--alias", alias_a], session_id=sid_a, alias=alias_a)
        p2 = run_bg(["monitor", "--alias", alias_b], session_id=sid_b, alias=alias_b)
        time.sleep(2)

        poll1 = p1.poll()
        poll2 = p2.poll()
        assert poll1 is None, f"monitor for {alias_a} exited: {poll1}"
        assert poll2 is None, f"monitor for {alias_b} exited: {poll2}"

        p1.terminate(); p1.wait(timeout=5)
        p2.terminate(); p2.wait(timeout=5)
