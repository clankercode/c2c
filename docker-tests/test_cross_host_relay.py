"""
#407 S2 — cross-host relay smoke (pytest wrapper).

Thin wrapper around `tests/e2e/00-smoke-cross-container.sh` so the e2e
multi-agent topology participates in the existing pytest harness
alongside `test_two_container_roundtrip.py`, `test_four_client_mesh.py`
etc. The bash script owns the heavy lifting (compose up --build,
healthcheck wait, register, send, poll, teardown). Keeping the wrapper
thin avoids duplicated container-orchestration logic and means the
smoke is also runnable standalone (`bash tests/e2e/00-smoke-cross-container.sh`)
for operators without pytest.

CI hint: running with `--validate` exercises only `docker compose
config` + `bash -n` (no daemon) — fast and useful as a syntax gate.
This wrapper drives the full smoke; gate on `docker_available()` so
no-docker CI environments cleanly skip.
"""
import os
import shutil
import subprocess

import pytest


REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir)
)
SMOKE_SCRIPT = os.path.join(
    REPO_ROOT, "tests", "e2e", "00-smoke-cross-container.sh"
)


def docker_available():
    """Return true when tests can orchestrate sibling containers from here."""
    if shutil.which("docker") is None:
        return False
    if not os.path.exists("/var/run/docker.sock"):
        return False
    probe = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True, text=True, timeout=10,
    )
    return probe.returncode == 0


pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="cross-host relay smoke requires docker CLI + host docker socket",
)


def test_cross_host_dm_via_relay():
    """agent-a1 (broker-a) -> agent-b1 (broker-b) via relay container.

    AC (#407 S2): relay forwards DM across two independent broker volumes;
    agent-b1 sees the DM in its inbox within 10s.
    """
    assert os.path.isfile(SMOKE_SCRIPT), f"smoke script missing: {SMOKE_SCRIPT}"
    result = subprocess.run(
        ["bash", SMOKE_SCRIPT],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        # Build + boot can take ~3-5min on a cold image cache.
        timeout=600,
    )
    if result.returncode != 0:
        pytest.fail(
            "cross-host smoke failed:\n"
            f"--- stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}"
        )
