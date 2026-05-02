"""S6: tmux smoke test — verifies tmux is functional inside the e2e container.

Validates:
1. `tmux -V` executes inside the container and reports a version.
2. `tmux new-session -d -s <name>` starts a detached session.
3. `tmux capture-pane` returns pane content.
4. `tmux send-keys` injects text; subsequent capture shows it.
5. `tmux kill-session` tears down cleanly.

Depends on: Dockerfile.test installing tmux (S6 core deliverable).
"""

from __future__ import annotations

import subprocess
import time

import pytest

from framework._docker_tmux_helpers import DockerTmux


# Containers available in the e2e multi-agent topology.
VALID_CONTAINERS = [
    "c2c-e2e-agent-a1",
    "c2c-e2e-agent-b1",
]


@pytest.fixture(params=VALID_CONTAINERS)
def container(request: pytest.FixtureRequest) -> str:
    return request.param


@pytest.fixture
def tmux(container: str) -> DockerTmux:
    return DockerTmux(container)


@pytest.fixture
def session_name() -> str:
    return f"tmux-smoke-{int(time.time())}"


def test_tmux_version_executes(container: str) -> None:
    """tmux -V should exit 0 inside any e2e container."""
    result = subprocess.run(
        ["docker", "exec", "-T", container, "tmux", "-V"],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, f"tmux -V failed in {container}: {result.stderr}"
    assert "tmux" in result.stdout.lower()


def test_new_session_starts(tmux: DockerTmux, session_name: str) -> None:
    """tmux new-session -d should start a detached session without error."""
    handle = tmux.new_session(session_name, ["sleep", "30"])
    try:
        assert handle.session_name == session_name
        assert tmux.is_alive(handle), f"session {session_name} not alive"
    finally:
        tmux.kill(handle)


def test_capture_returns_content(tmux: DockerTmux, session_name: str) -> None:
    """tmux capture-pane should return non-empty pane text after echo."""
    handle = tmux.new_session(
        session_name,
        ["bash", "-lc", "echo smoke-test-marker && sleep 30"],
    )
    try:
        time.sleep(0.5)  # let echo settle
        cap = tmux.capture(handle)
        assert "smoke-test-marker" in cap.text, (
            f"expected 'smoke-test-marker' in pane, got: {cap.text!r}"
        )
    finally:
        tmux.kill(handle)


def test_send_text_injects(tmux: DockerTmux, session_name: str) -> None:
    """tmux send-keys should inject text; capture should show it."""
    handle = tmux.new_session(
        session_name,
        ["bash", "-lc", "sleep 30"],
    )
    try:
        tmux.send_text(handle, "echo injected-ok")
        tmux.send_key(handle, "Enter")
        time.sleep(0.5)
        cap = tmux.capture(handle)
        assert "injected-ok" in cap.text, (
            f"expected 'injected-ok' after send_keys, got: {cap.text!r}"
        )
    finally:
        tmux.kill(handle)


def test_kill_session_terminates(tmux: DockerTmux, session_name: str) -> None:
    """tmux kill-session should remove the session; is_alive returns False."""
    handle = tmux.new_session(session_name, ["sleep", "30"])
    tmux.kill(handle)
    assert not tmux.is_alive(handle), f"session {session_name} still alive after kill"
