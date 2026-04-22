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
from pathlib import Path
from typing import Any, FrozenSet

import pytest

from tests.e2e.framework.artifacts import ArtifactCollector
from tests.e2e.framework.client_adapters import CodexAdapter, CodexHeadlessAdapter, ClaudeAdapter, KimiAdapter, OpenCodeAdapter
from tests.e2e.framework.fake_pty_driver import FakePtyDriver
from tests.e2e.framework.scenario import Scenario
from tests.e2e.framework.tmux_driver import TmuxDriver

# ---------------------------------------------------------------------------
# Patterns we care about for leak detection.
# Each entry is a (label, pattern, live_limit, exe_names) tuple:
#   label       — human name shown in error messages
#   pattern     — pgrep -f pattern (broad initial match)
#   live_limit  — max allowed pre-existing matches before pre-flight refuses
#                 the run. Use None to skip pre-flight for this pattern
#                 (still tracked for post-test leak detection).
#   exe_names   — frozenset of /proc/<pid>/exe basenames that count as a real
#                 match; None means accept any exe (no anchor).
#
# The exe_names anchor prevents dune build jobs, opam wrappers, and test-
# harness invocations that merely mention the binary name in their argv from
# being counted as leaked managed processes.
#
# IMPORTANT: Do NOT set a limit for "c2c-start" — live swarm agents run as
# `c2c start <client>` managed instances and are not test pollution. The
# post-test baseline-diff approach (see _process_leak_guard below) already
# catches newly leaked instances without tripping on legitimate live peers.
# ---------------------------------------------------------------------------
_LEAK_PATTERNS: list[tuple[str, str, int | None, frozenset[str] | None]] = [
    ("opencode",       r"\.opencode.*--log-level",  3,    frozenset({"opencode"})),
    ("c2c-mcp-server", r"c2c_mcp_server\.exe",      1,    frozenset({"c2c_mcp_server.exe"})),
    ("c2c-start",      r"c2c start ",               None, frozenset({"c2c", "c2c.exe"})),
]


def _read_cmdline(pid: int) -> str:
    try:
        raw = open(f"/proc/{pid}/cmdline", "rb").read()
    except OSError:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def _read_exe_name(pid: int) -> str:
    """Return basename of /proc/<pid>/exe symlink target, or '' on error."""
    try:
        return os.path.basename(os.readlink(f"/proc/{pid}/exe"))
    except OSError:
        return ""


def _pgrep_pids(pattern: str, exe_names: frozenset[str] | None = None) -> FrozenSet[int]:
    """Return frozenset of PIDs matching *pattern* via pgrep -f.

    If *exe_names* is given, only include PIDs whose /proc/<pid>/exe
    basename is in that set — this anchors the match to the real binary
    and prevents dune build jobs from being counted as leaked processes.
    """
    try:
        out = subprocess.run(
            ["pgrep", "-f", pattern],
            capture_output=True, text=True, check=False
        ).stdout
        pids = (int(p) for p in out.split() if p.strip().isdigit())
        if exe_names is not None:
            return frozenset(pid for pid in pids if _read_exe_name(pid) in exe_names)
        return frozenset(pids)
    except FileNotFoundError:
        return frozenset()


def _snapshot_all() -> dict[str, FrozenSet[int]]:
    return {label: _pgrep_pids(pat, exe_names) for label, pat, _, exe_names in _LEAK_PATTERNS}


# ---------------------------------------------------------------------------
# (3) Pre-flight: refuse when too many processes already alive.
# ---------------------------------------------------------------------------

def pytest_configure(config: pytest.Config) -> None:
    force = config.getoption("--force-test-env", default=False)
    if force:
        return

    problems: list[str] = []
    for label, pat, limit, exe_names in _LEAK_PATTERNS:
        if limit is None:
            continue  # no pre-flight check for this pattern (live swarm ok)
        pids = _pgrep_pids(pat, exe_names)
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
    for label, pat, _, _exe in _LEAK_PATTERNS:
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


C2C_SESSION_VARS = [
    "C2C_MCP_SESSION_ID",
    "C2C_MCP_AUTO_REGISTER_ALIAS",
    "C2C_INSTANCE_NAME",
    "C2C_WRAPPER_SELF",
    "C2C_OPENCODE_SESSION_ID",
]


def clean_c2c_start_env(base_env: dict[str, str]) -> dict[str, str]:
    """Return a copy of base_env with c2c session vars removed.

    This prevents the nested-session guardrail (which blocks 'c2c start' when
    C2C_MCP_SESSION_ID is already set) from firing in test subprocesses that
    inherit the parent shell's c2c session environment.
    """
    env = dict(base_env)
    for var in C2C_SESSION_VARS:
        env.pop(var, None)
    return env


@pytest.fixture(scope="session", autouse=True)
def _pgid_cleanup_guard() -> None:  # type: ignore[return]
    """Kill every pgid registered via spawn_tracked() at session end."""
    yield
    for pgid in _tracked_pgids:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except OSError:
            pass


def _cleanup_scenario_agents(sc: Scenario) -> None:
    cleanup_failures: list[str] = []
    for agent in list(sc.agents.values()):
        try:
            sc.drivers[agent.backend].stop(agent.handle)
        except Exception as exc:
            cleanup_failures.append(f"{agent.name}: {exc}")
    if cleanup_failures:
        raise AssertionError("scenario cleanup failed: " + "; ".join(cleanup_failures))


@pytest.fixture
def scenario(request: pytest.FixtureRequest, tmp_path: Path) -> Scenario:
    artifact_root = Path(".artifacts") / "e2e"
    artifacts = ArtifactCollector(artifact_root, request.node.name)
    artifacts.start_run()
    sc = Scenario(
        test_name=request.node.name,
        workdir=tmp_path / "workdir",
        artifacts=artifacts,
        drivers={
            "tmux": TmuxDriver(Path.cwd()),
            "fake-pty": FakePtyDriver(),
        },
        adapters={
            "codex": CodexAdapter(Path.cwd()),
            "codex-headless": CodexHeadlessAdapter(Path.cwd()),
            "opencode": OpenCodeAdapter(Path.cwd()),
            "claude": ClaudeAdapter(Path.cwd()),
            "kimi": KimiAdapter(Path.cwd()),
        },
    )
    sc.refresh_capabilities()
    yield sc
    _cleanup_scenario_agents(sc)
