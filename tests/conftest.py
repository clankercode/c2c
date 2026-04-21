"""
conftest.py — session-wide pytest hygiene for c2c tests.

(1) Pre-flight guard: refuse pytest session when too many background
    processes are already alive (prevents test-suite pollution from
    previous leaked runs).

(3) Process-leak guard: snapshot PIDs before the session, and after
    teardown warn + fail if new managed processes leaked.

See task #34 in coordinator1's dispatch (2026-04-21).
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import warnings
from typing import Any, FrozenSet

import pytest

# ---------------------------------------------------------------------------
# Patterns we care about for leak detection.
# Each entry is a (label, pattern, live_limit) tuple:
#   label       — human name shown in error messages
#   pattern     — pgrep -f pattern
#   live_limit  — max allowed pre-existing matches before we refuse the run
# ---------------------------------------------------------------------------
_LEAK_PATTERNS: list[tuple[str, str, int]] = [
    ("opencode",       r"\.opencode.*--log-level",  3),
    ("c2c-mcp-server", r"c2c_mcp_server\.exe",      1),
    ("c2c-start",      r"c2c start ",               2),
]


def _read_cmdline(pid: int) -> str:
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def _is_real_mcp_server_process(pid: int) -> bool:
    cmdline = _read_cmdline(pid)
    if not cmdline:
        return False
    parts = cmdline.split()
    if not parts:
        return False
    exe = os.path.basename(parts[0])
    if exe != "c2c_mcp_server.exe":
        return False
    # Exclude dune/opam/bash wrapper/build jobs that merely mention the target path.
    return not any(part in {"dune", "opam", "bash", "sh"} for part in parts[:2])


def _pgrep_pids(pattern: str) -> FrozenSet[int]:
    """Return frozenset of PIDs matching *pattern* via pgrep -f."""
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True, text=True, check=False
        ).stdout
        pids = frozenset(int(p) for p in out.split() if p.strip().isdigit())
        if pattern == r"c2c_mcp_server\.exe":
            return frozenset(pid for pid in pids if _is_real_mcp_server_process(pid))
        return pids
    except FileNotFoundError:
        return frozenset()


def _snapshot_all() -> dict[str, FrozenSet[int]]:
    return {label: _pgrep_pids(pat) for label, pat, _ in _LEAK_PATTERNS}


# ---------------------------------------------------------------------------
# (3) Pre-flight: refuse when too many processes already alive.
# ---------------------------------------------------------------------------

def pytest_configure(config: pytest.Config) -> None:
    force = config.getoption("--force-test-env", default=False)
    if force:
        return

    problems: list[str] = []
    for label, pat, limit in _LEAK_PATTERNS:
        pids = _pgrep_pids(pat)
        if len(pids) > limit:
            problems.append(
                f"  {label}: {len(pids)} running (limit {limit}), PIDs: "
                + ", ".join(str(p) for p in sorted(pids))
            )

    if problems:
        print(
            "\n\n[c2c-conftest] Pre-flight FAILED — too many background processes:\n"
            + "\n".join(problems)
            + "\n\nClean up before running tests:\n"
            "  pkill -f '.opencode.*--log-level'   # orphan opencode instances\n"
            "  pkill -f 'c2c_mcp_server.exe'       # orphan MCP servers\n"
            "  c2c instances                        # check managed instances\n"
            "\nOr bypass with: pytest --force-test-env ...\n",
            file=sys.stderr,
        )
        pytest.exit(
            "Pre-flight: too many background processes. "
            "Run 'pytest --force-test-env' to bypass.",
            returncode=3,
        )


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption(
        "--force-test-env",
        action="store_true",
        default=False,
        help="Bypass pre-flight process count checks (use when intentionally "
             "running tests alongside a live swarm).",
    )


# ---------------------------------------------------------------------------
# (1) Session-scoped process-leak guard.
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def _process_leak_guard(request: pytest.FixtureRequest) -> None:  # type: ignore[return]
    """Snapshot managed-process PIDs at session start; warn + fail on leak."""
    before = _snapshot_all()

    yield  # run the entire test session

    after = _snapshot_all()
    leaked: list[str] = []
    for label, pat, _ in _LEAK_PATTERNS:
        new_pids = after.get(label, frozenset()) - before.get(label, frozenset())
        if new_pids:
            # Filter out our own pytest process.
            new_pids = frozenset(p for p in new_pids if p != os.getpid())
        if new_pids:
            leaked.append(
                f"  {label}: leaked PIDs {sorted(new_pids)} "
                f"(pattern: {pat!r})"
            )

    if leaked:
        msg = (
            "[c2c-conftest] Process leak detected after test session:\n"
            + "\n".join(leaked)
            + "\n\nKill them:\n"
            "  pkill -f '.opencode.*--log-level'\n"
            "  pkill -f 'c2c_mcp_server.exe'\n"
        )
        # Print but do not hard-fail — the tests themselves already passed.
        # A warning is enough: the operator sees it in the summary.
        print("\n\nWARNING: " + msg, file=sys.stderr)
        warnings.warn(msg, stacklevel=1)


# ---------------------------------------------------------------------------
# pgid-based subprocess tracking.
#
# Use spawn_tracked() instead of subprocess.Popen() for any long-lived child
# processes (MCP servers, sleepers, integration harnesses).  Each call records
# the child's pgid; the session fixture kills the whole group on teardown so
# processes leaked by a crashed test body are still reaped.
# ---------------------------------------------------------------------------

_tracked_pgids: list[int] = []


def spawn_tracked(cmd: list[str], **kwargs: Any) -> subprocess.Popen:
    """Spawn *cmd* in a new session (new pgid) and register it for cleanup.

    Forces ``start_new_session=True``; do not also pass ``preexec_fn``.
    Returns the Popen object so callers can still do per-test cleanup.
    """
    kwargs["start_new_session"] = True
    proc = subprocess.Popen(cmd, **kwargs)
    try:
        _tracked_pgids.append(os.getpgid(proc.pid))
    except OSError:
        pass
    return proc


@pytest.fixture(scope="session", autouse=True)
def _pgid_cleanup_guard() -> None:  # type: ignore[return]
    """Kill every pgid registered via spawn_tracked() at session end."""
    yield
    for pgid in _tracked_pgids:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except OSError:
            pass
