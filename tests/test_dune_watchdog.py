from __future__ import annotations

import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
WATCHDOG = REPO_ROOT / "scripts" / "dune-watchdog.sh"


def _run_watchdog(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = dict(os.environ)
    if env:
        merged_env.update(env)
    return subprocess.run(
        [str(WATCHDOG), *args],
        cwd=REPO_ROOT,
        env=merged_env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_dune_watchdog_passes_through_success() -> None:
    result = _run_watchdog("5", "bash", "-lc", "printf ok")

    assert result.returncode == 0
    assert result.stdout == "ok"
    assert result.stderr == ""


def test_dune_watchdog_times_out_and_returns_124() -> None:
    result = _run_watchdog("0.2", "bash", "-lc", "sleep 5")

    assert result.returncode == 124
    assert "DUNE WATCHDOG: killed command after" in result.stderr


def test_dune_watchdog_disable_env_bypasses_watchdog() -> None:
    result = _run_watchdog(
        "0.1",
        "bash",
        "-lc",
        "sleep 0.2; printf bypassed",
        env={"DUNE_WATCHDOG": "0"},
    )

    assert result.returncode == 0
    assert result.stdout == "bypassed"
    assert result.stderr == ""
