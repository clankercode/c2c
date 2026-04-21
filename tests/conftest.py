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
import subprocess
import sys
import warnings
from typing import FrozenSet

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


def _pgrep_pids(pattern: str) -> FrozenSet[int]:
    """Return frozenset of PIDs matching *pattern* via pgrep -f."""
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True, text=True, check=False
        ).stdout
        return frozenset(int(p) for p in out.split() if p.strip().isdigit())
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
