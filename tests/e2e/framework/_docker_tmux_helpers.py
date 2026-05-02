"""Docker-internal tmux helpers for e2e tests.

Provides a thin wrapper around `docker exec <container> tmux ...` so tests
running on the host can drive tmux sessions that live inside a container.
Used by S3 (channel-push) and S7 (PTY inject) which need to inspect pane
content after delivering a message to a containerised agent.

Unlike ``tmux_driver.py`` (which drives the host's own tmux from the host),
these helpers target tmux running inside a named container.  The container must
have tmux installed (added in Dockerfile.test S6).

Usage::

    from docker_tmux_helpers import DockerTmux

    tmux = DockerTmux("c2c-e2e-agent-a1")
    handle = tmux.new_session("test1", ["bash", "-c", "echo hello; sleep 30"])
    capture = tmux.capture(handle)
    assert "hello" in capture.text
    tmux.send_keys(handle, "world\\n")
    tmux.send_key(handle, "Enter")
    tmux.kill(handle)
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass
from typing import List


@dataclass
class DockerTmuxHandle:
    """Opaque handle returned by DockerTmux.new_session."""

    container: str
    session_name: str


class DockerTmux:
    def __init__(self, container: str) -> None:
        self.container = container

    # ------------------------------------------------------------------
    # Wrappers for `docker exec <container> tmux new-session ...`
    # ------------------------------------------------------------------

    def new_session(
        self,
        session_name: str,
        command: List[str],
        *,
        rows: int = 24,
        cols: int = 80,
        cwd: str = "/",
    ) -> DockerTmuxHandle:
        """Start a new detached tmux session inside the container.

        The session runs ``command`` as a login shell so the agent
        environment (PATH, env vars) is fully populated.
        """
        cmd = [
            "docker", "exec", "-d",
            self.container,
            "tmux",
            "new-session",
            "-s", session_name,
            "-x", str(cols),
            "-y", str(rows),
            "-D",  # stay detached
            "bash", "-lc", f"cd {cwd} && " + " ".join(_shlex_quote(a) for a in command),
        ]
        subprocess.run(cmd, check=True, capture_output=True)
        # tmux takes a moment to initialise the socket
        time.sleep(0.25)
        return DockerTmuxHandle(container=self.container, session_name=session_name)

    def capture(self, handle: DockerTmuxHandle) -> "Capture":
        """Return the visible pane content for a session."""
        result = subprocess.run(
            [
                "docker", "exec", handle.container,
                "tmux", "capture-pane",
                "-t", handle.session_name,
                "-p",    # print to stdout
                "-S", "-200",  # last 200 lines
            ],
            capture_output=True, text=True, check=True,
        )
        return Capture(text=result.stdout, raw=result.stdout)

    def send_text(self, handle: DockerTmuxHandle, text: str) -> None:
        """Send plain text to the session pane (no Enter)."""
        subprocess.run(
            [
                "docker", "exec", "-T", handle.container,
                "tmux", "send-keys", "-t", handle.session_name, "-l", text,
            ],
            check=True, capture_output=True,
        )

    def send_key(self, handle: DockerTmuxHandle, key: str) -> None:
        """Send a named key (e.g. ``"Enter"``, ``"C-c"``) to the pane."""
        if key == "Enter":
            # tmux send-keys with no flag treats the argument as a literal key name
            subprocess.run(
                [
                    "docker", "exec", "-T", handle.container,
                    "tmux", "send-keys", "-t", handle.session_name, "Enter",
                ],
                check=True, capture_output=True,
            )
        else:
            subprocess.run(
                [
                    "docker", "exec", "-T", handle.container,
                    "tmux", "send-keys", "-t", handle.session_name, key,
                ],
                check=True, capture_output=True,
            )

    def is_alive(self, handle: DockerTmuxHandle) -> bool:
        """Return True if the session pane is still attached (not dead)."""
        result = subprocess.run(
            [
                "docker", "exec", "-T", handle.container,
                "tmux", "display-message", "-t", handle.session_name,
                "-p", "#{pane_dead}",
            ],
            capture_output=True, text=True,
        )
        return result.returncode == 0 and result.stdout.strip() == "0"

    def kill(self, handle: DockerTmuxHandle) -> None:
        """Kill the session (forced, no check)."""
        subprocess.run(
            [
                "docker", "exec", "-T", handle.container,
                "tmux", "kill-session", "-t", handle.session_name,
            ],
            check=False, capture_output=True,
        )


@dataclass
class Capture:
    text: str
    raw: str


def _shlex_quote(s: str) -> str:
    """Pure-Python shlex.quote for portability (no external deps)."""
    if not s:
        return "''"
    if s.replace("-_./", "").isalnum():
        return s
    return "'" + s.replace("'", "'\"'\"'") + "'"
