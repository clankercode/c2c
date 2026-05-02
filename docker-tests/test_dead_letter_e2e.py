"""
#406 S13: c2c list --alive filter E2E in Docker.
Validates that `c2c list --alive` correctly filters sessions based on liveness state.
In Docker mode, liveness is determined by file-based lease (pid-based sessions) or
always-alive (pid=0 sessions from ephemeral subprocesses).
Sessions with alive:false must not appear in --alive output.

Coordinator-approved pivot 2026-05-02 (from S9 which required session-death
dead-letter path incompatible with Docker file-based lease liveness).
"""
import json
import os
import subprocess
import time
import pytest


BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")
C2C = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")


def _run_c2c(argv, session_id=None, alias=None, timeout=10):
    """Run c2c CLI and return stdout with correct C2C_MCP_CLIENT_PID."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
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


class TestListAliveFilter:
    """#406 S13: c2c list --alive filter E2E in Docker.

    Key Docker-mode semantics:
    - pid=0 sessions (from ephemeral Python subprocesses): always alive
    - pid>0 sessions: lease-file mtime determines liveness
    - Sessions with alive:false must NOT appear in --alive output
    """

    def test_alive_filter_shows_only_alive_sessions(self):
        """Verify --alive shows only sessions with alive:true; dead sessions excluded."""
        ts = int(time.time())
        live_alias = f"alive-{ts}"
        live_sid = f"alive-sid-{ts}"

        # Register a live session
        r = _run_c2c(["register", "--alias", live_alias], session_id=live_sid, alias=live_alias)
        assert r.returncode == 0, f"register failed: {r.stderr}"
        time.sleep(0.3)

        # list --alive --all --json shows only alive sessions
        r = _run_c2c(["list", "--alive", "--all", "--json"], session_id=live_sid, alias=live_alias)
        assert r.returncode == 0, f"list --alive failed: {r.stderr}"
        alive_regs = json.loads(r.stdout)

        # Every session in --alive output must have alive:true
        for reg in alive_regs:
            assert reg.get("alive") is True, (
                f"Session {reg.get('session_id')} has alive:{reg.get('alive')} "
                f"but appeared in --alive output"
            )

        # The session we just registered must appear
        live_sids = [reg["session_id"] for reg in alive_regs]
        assert live_sid in live_sids, f"Live session {live_sid} not in --alive output: {live_sids}"

    def test_alive_filter_excludes_dead_sessions(self):
        """Sessions with alive:false must not appear in --alive output.

        Broker state from prior test runs may contain sessions that the broker
        considers dead (e.g. pid-based sessions whose lease is stale).
        These must be excluded from --alive output.
        """
        ts = int(time.time())
        checker_sid = f"checker-{ts}"
        checker_alias = f"checker-{ts}"

        _run_c2c(["register", "--alias", checker_alias], session_id=checker_sid, alias=checker_alias)
        time.sleep(0.3)

        r = _run_c2c(["list", "--alive", "--all", "--json"], session_id=checker_sid, alias=checker_alias)
        assert r.returncode == 0, f"list --alive failed: {r.stderr}"
        alive_regs = json.loads(r.stdout)

        # Key invariant: no session with alive:false may appear in --alive output
        for reg in alive_regs:
            assert reg.get("alive") is not False, (
                f"Session {reg.get('session_id')} has alive:false but appeared "
                f"in --alive output: {reg}"
            )

    def test_alive_subset_of_all(self):
        """--alive output must be a subset of --all output (same session IDs)."""
        ts = int(time.time())
        sid = f"compare-{ts}"
        alias = f"compare-{ts}"

        r = _run_c2c(["register", "--alias", alias], session_id=sid, alias=alias)
        assert r.returncode == 0
        time.sleep(0.3)

        r_all = _run_c2c(["list", "--all", "--json"], session_id=sid, alias=alias)
        assert r_all.returncode == 0
        all_regs = json.loads(r_all.stdout)
        all_sids = {reg["session_id"] for reg in all_regs}

        r_alive = _run_c2c(["list", "--alive", "--all", "--json"], session_id=sid, alias=alias)
        assert r_alive.returncode == 0
        alive_regs = json.loads(r_alive.stdout)
        alive_sids = {reg["session_id"] for reg in alive_regs}

        # --alive session IDs must be a subset of --all session IDs
        assert alive_sids <= all_sids, (
            f"--alive sids {alive_sids} is not a subset of --all sids {all_sids}"
        )
