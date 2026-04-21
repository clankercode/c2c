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

SES_ID = "ses_test_fixture_abc"


def test_resume_ses_id_sets_c2c_opencode_session_id(tmp_path: Path) -> None:
    """c2c start opencode -s ses_* → C2C_OPENCODE_SESSION_ID=<sid> in child env."""
    fake_bin = _make_env_printer(tmp_path, known_session_id=SES_ID)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="resume-test",
        extra_args=["-s", SES_ID],
    )
    assert f"C2C_OPENCODE_SESSION_ID={SES_ID}" in result.stderr, (
        f"Expected C2C_OPENCODE_SESSION_ID={SES_ID} in child env.\nstderr:\n{result.stderr[:2000]}"
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


DEDUP_SES_ID = "ses_dedup_fixture_xyz"


def test_session_id_set_correctly_without_duplicates(tmp_path: Path) -> None:
    """Child env has exactly one C2C_MCP_SESSION_ID and one C2C_OPENCODE_SESSION_ID.

    Regression for build_env duplicate-key bug (0648a87): when running from
    inside an existing managed session (CLAUDE_SESSION_ID set), the parent's
    C2C_MCP_SESSION_ID was leaking into the child alongside the intended one.
    """
    fake_bin = _make_env_printer(tmp_path, known_session_id=DEDUP_SES_ID)
    result = _run_c2c_start(
        tmp_path=tmp_path,
        fake_bin_dir=fake_bin.parent,
        instance_name="dedup-test",
        extra_args=["-s", DEDUP_SES_ID],
    )
    lines = result.stderr.splitlines()
    session_id_lines = [l for l in lines if l.startswith("C2C_MCP_SESSION_ID=")]
    oc_session_lines = [l for l in lines if l.startswith("C2C_OPENCODE_SESSION_ID=")]

    assert len(session_id_lines) == 1, (
        f"Expected exactly 1 C2C_MCP_SESSION_ID (no duplicates), got {len(session_id_lines)}:\n"
        + "\n".join(session_id_lines)
    )
    assert session_id_lines[0] == "C2C_MCP_SESSION_ID=dedup-test", (
        f"Wrong session ID: {session_id_lines[0]}"
    )
    assert len(oc_session_lines) == 1, (
        f"Expected exactly 1 C2C_OPENCODE_SESSION_ID, got {len(oc_session_lines)}:\n"
        + "\n".join(oc_session_lines)
    )
    assert oc_session_lines[0] == f"C2C_OPENCODE_SESSION_ID={DEDUP_SES_ID}", (
        f"Wrong opencode session ID: {oc_session_lines[0]}"
    )


# ---------------------------------------------------------------------------
# Live E2E: resume + TUI focus combined (requires C2C_TEST_RESUME_E2E=1)
# ---------------------------------------------------------------------------

import json
import time

pytestmark_e2e = pytest.mark.skipif(
    not os.environ.get("C2C_TEST_RESUME_E2E"),
    reason="Set C2C_TEST_RESUME_E2E=1 to run live resume+TUI-focus E2E tests",
)


@pytestmark_e2e
def test_resume_e2e_plugin_tracks_correct_session(tmp_path: Path) -> None:
    """Live E2E: c2c start opencode -s ses_* → plugin's root_opencode_session_id
    matches the requested session (not a fresh 'c2c kickoff' session).

    Validates both:
    - 911c0b2: C2C_OPENCODE_SESSION_ID propagated so plugin doesn't auto-kickoff
    - 7667564 / ddb81ba: TUI focuses the resumed session via ctx.client.tui.publish()

    Requires: a valid ses_* session ID in C2C_TEST_RESUME_SESSION_ID env var,
    and opencode to be installed.
    """
    ses_id = os.environ.get("C2C_TEST_RESUME_SESSION_ID", "")
    if not ses_id.startswith("ses_"):
        pytest.skip("Set C2C_TEST_RESUME_SESSION_ID=ses_<id> to a valid session")

    inst_name = f"resume-e2e-{int(time.time())}"
    # The OCaml binary uses C2C_INSTANCES_DIR for its own state, but the
    # TypeScript plugin always writes oc-plugin-state.json to the canonical
    # ~/.local/share/c2c/instances/<name>/ path regardless of that env var.
    canonical_instances = Path.home() / ".local" / "share" / "c2c" / "instances"
    env = {**os.environ}

    proc = subprocess.Popen(
        [C2C_BIN, "start", "opencode", "-n", inst_name, "-s", ses_id],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    state_file = canonical_instances / inst_name / "oc-plugin-state.json"
    deadline = time.monotonic() + 30.0
    root_session = None
    while time.monotonic() < deadline:
        time.sleep(1)
        if state_file.exists():
            try:
                raw = json.loads(state_file.read_text())
                root_session = raw.get("state", raw).get("root_opencode_session_id")
                if root_session:
                    break
            except Exception:
                pass

    proc.terminate()
    proc.wait(timeout=5)

    assert root_session is not None, "Plugin never wrote root_opencode_session_id"
    assert root_session == ses_id, (
        f"Plugin adopted wrong session: got {root_session!r}, expected {ses_id!r}. "
        "This is the auto-kickoff clobber bug (911c0b2 regression)."
    )
