"""
Regression tests for `c2c start opencode -s ses_*` session propagation.

Bug (911c0b2): When resuming an opencode session via -s ses_<id>, the session
ID was passed to opencode via --session CLI flag (so opencode loaded it in the
TUI) but was NOT set as C2C_OPENCODE_SESSION_ID in the child environment.

The c2c.ts plugin reads C2C_OPENCODE_SESSION_ID to prime activeSessionId and
configuredOpenCodeSessionId. Without it, bootstrapRootSession treated the
launch as auto-kickoff, ignored the configured session, and created a fresh
"c2c kickoff" session that clobbered the requested one.

Fix: c2c_start.ml now appends C2C_OPENCODE_SESSION_ID=<sid> to the child env
when client=opencode and resume_session_id starts with "ses_".

These tests verify the env is set correctly WITHOUT launching real opencode,
by using a fake binary that prints its environment then exits 0.
"""
from __future__ import annotations

import os
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

C2C_BIN = subprocess.run(["which", "c2c"], capture_output=True, text=True).stdout.strip() or "c2c"


def _make_env_printer(tmp_path: Path, known_session_id: str = "ses_test_fixture") -> Path:
    """Create a fake 'opencode' binary that:
    - On 'session list --format json': returns JSON with the known session ID
      (so c2c's pre-flight validation passes).
    - Otherwise: prints the environment to stderr and exits 0.
    """
    script = tmp_path / "opencode"
    script.write_text(
        "#!/bin/sh\n"
        '# Fake opencode for c2c start env-propagation tests\n'
        'if [ "$1" = "session" ] && [ "$2" = "list" ]; then\n'
        f'  echo \'[{{"id": "{known_session_id}", "title": "fixture"}}]\'\n'
        '  exit 0\n'
        'fi\n'
        "env >&2\n"
        "exit 0\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return script


def _run_c2c_start(
    tmp_path: Path,
    fake_bin_dir: Path,
    instance_name: str,
    extra_args: list[str],
    timeout: int = 10,
) -> subprocess.CompletedProcess:
    env = {
        **os.environ,
        "C2C_INSTANCES_DIR": str(tmp_path / "instances"),
        "PATH": str(fake_bin_dir) + ":" + os.environ.get("PATH", ""),
    }
    return subprocess.run(
        [C2C_BIN, "start", "opencode", "-n", instance_name] + extra_args,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_resume_ses_id_sets_c2c_opencode_session_id(tmp_path: Path) -> None:
    """c2c start opencode -s ses_abc → C2C_OPENCODE_SESSION_ID=ses_abc in child env."""
    fake_bin = _make_env_printer(tmp_path)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="resume-test",
        extra_args=["-s", "ses_abc123"],
    )
    assert "C2C_OPENCODE_SESSION_ID=ses_abc123" in result.stderr, (
        f"Expected C2C_OPENCODE_SESSION_ID=ses_abc123 in child env.\nstderr:\n{result.stderr[:2000]}"
    )


def test_resume_non_ses_id_does_not_set_var(tmp_path: Path) -> None:
    """c2c start opencode -s <uuid> (not ses_*) does NOT set C2C_OPENCODE_SESSION_ID."""
    fake_bin = _make_env_printer(tmp_path)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="resume-no-ses",
        extra_args=["-s", "00000000-0000-0000-0000-000000000001"],
    )
    assert "C2C_OPENCODE_SESSION_ID=" not in result.stderr, (
        f"C2C_OPENCODE_SESSION_ID should NOT be set for non-ses_* ids.\nstderr:\n{result.stderr[:2000]}"
    )


def test_no_session_flag_does_not_set_var(tmp_path: Path) -> None:
    """c2c start opencode without -s does NOT set C2C_OPENCODE_SESSION_ID."""
    fake_bin = _make_env_printer(tmp_path)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="fresh-no-resume",
        extra_args=[],
    )
    assert "C2C_OPENCODE_SESSION_ID=" not in result.stderr, (
        f"C2C_OPENCODE_SESSION_ID should NOT be set when no -s given.\nstderr:\n{result.stderr[:2000]}"
    )


def test_session_id_set_correctly_without_duplicates(tmp_path: Path) -> None:
    """Child env has exactly one C2C_MCP_SESSION_ID and one C2C_OPENCODE_SESSION_ID."""
    fake_bin = _make_env_printer(tmp_path)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="dedup-test",
        extra_args=["-s", "ses_dedup123"],
    )
    lines = result.stderr.splitlines()
    session_id_lines = [l for l in lines if l.startswith("C2C_MCP_SESSION_ID=")]
    oc_session_lines = [l for l in lines if l.startswith("C2C_OPENCODE_SESSION_ID=")]

    assert len(session_id_lines) == 1, (
        f"Expected exactly 1 C2C_MCP_SESSION_ID in env, got {len(session_id_lines)}:\n"
        + "\n".join(session_id_lines)
    )
    assert session_id_lines[0] == "C2C_MCP_SESSION_ID=dedup-test", (
        f"Wrong session ID: {session_id_lines[0]}"
    )
    assert len(oc_session_lines) == 1, (
        f"Expected exactly 1 C2C_OPENCODE_SESSION_ID in env, got {len(oc_session_lines)}:\n"
        + "\n".join(oc_session_lines)
    )
    assert oc_session_lines[0] == "C2C_OPENCODE_SESSION_ID=ses_dedup123", (
        f"Wrong opencode session ID: {oc_session_lines[0]}"
    )
