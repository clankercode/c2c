"""End-to-end two-agent OpenCode smoke, driven via tmux.

Exercises the full `c2c start opencode --auto` flow cold from bash:

1. Creates a fresh tmp workdir and `git init`s it.
2. Launches two managed opencode agents in separate tmux panes with
   different aliases and `--auto` kickoff prompts.
3. Waits for both to register with the broker as `alive=true` under the
   requested aliases (no phantom word-pair aliases).
4. Asserts neither TUI is stuck on the opening-screen "New session"
   banner (the plugin's session must have been adopted).
5. Sends a DM from the test harness to agent 2 and confirms the plugin
   delivered it (checked via `.opencode/c2c-debug.log`).
6. Closes agent 2 by sending Ctrl-D to its pane.
7. Asserts the outer `c2c start` also exited (did NOT go to bg via
   SIGTSTP) — a subsequent `fg` in the same shell reports no jobs.
8. Re-runs `c2c start opencode -n <agent2>` and asserts opencode resumes
   the prior session (same ses_* id from opencode-session.txt) rather
   than creating a blank one.

Expensive: spawns real opencode processes which talk to a real LLM, so
gated behind `C2C_TEST_OC_TWIN_E2E=1`. Requires `opencode`, `tmux`,
`c2c` binaries on PATH and working LLM credentials.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

TMUX_BIN = shutil.which("tmux")
OC_BIN = shutil.which("opencode")
C2C_BIN = shutil.which("c2c")

pytestmark = pytest.mark.skipif(
    os.environ.get("C2C_TEST_OC_TWIN_E2E") != "1"
    or not TMUX_BIN
    or not OC_BIN
    or not C2C_BIN,
    reason="set C2C_TEST_OC_TWIN_E2E=1 and ensure tmux/opencode/c2c are on PATH",
)


def _tmux(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    assert TMUX_BIN is not None
    return subprocess.run(
        [TMUX_BIN, *args], capture_output=True, text=True, check=check
    )


def _capture(target: str) -> str:
    return _tmux("capture-pane", "-t", target, "-p", "-S", "-200").stdout


def _wait_for(predicate, timeout: float, interval: float = 0.5) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _registry_entry(broker_root: Path, alias: str) -> dict | None:
    reg = broker_root / "registry.json"
    if not reg.exists():
        return None
    try:
        data = json.loads(reg.read_text())
    except json.JSONDecodeError:
        return None
    rows = data if isinstance(data, list) else data.get("registrations", [])
    for r in rows:
        if r.get("alias") == alias:
            return r
    return None


def _alive(broker_root: Path, alias: str) -> bool:
    row = _registry_entry(broker_root, alias)
    if not row:
        return False
    pid = row.get("pid")
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _debug_log_has(instance_dir: Path, needle: str) -> bool:
    log = instance_dir / ".opencode" / "c2c-debug.log"
    if not log.exists():
        # When `c2c start` runs with cwd=instance_dir the plugin writes
        # c2c-debug.log relative to that cwd.
        return False
    try:
        return needle in log.read_text(errors="replace")
    except OSError:
        return False


def _instance_dir(alias: str) -> Path:
    base = Path(os.path.expanduser("~/.local/share/c2c/instances"))
    return base / alias


@pytest.fixture
def tmux_session():
    session = f"c2c-oc-twin-{os.getpid()}"
    _tmux("new-session", "-d", "-s", session, "-x", "220", "-y", "60", "bash", check=False)
    yield session
    _tmux("kill-session", "-t", session, check=False)


def test_opencode_twin_e2e(tmp_path: Path, tmux_session: str) -> None:
    assert TMUX_BIN and OC_BIN and C2C_BIN

    # (1) fresh workdir with git
    workdir = tmp_path / "project"
    workdir.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=workdir, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=workdir, check=True)

    alias_a = f"twin-a-{os.getpid()}"
    alias_b = f"twin-b-{os.getpid()}"

    # Broker root — c2c uses git-common-dir/c2c/mcp.
    git_common = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"], cwd=workdir, capture_output=True, text=True, check=True
    ).stdout.strip()
    broker_root = (Path(workdir) / git_common / "c2c" / "mcp").resolve()
    broker_root.mkdir(parents=True, exist_ok=True)

    pane0 = f"{tmux_session}:0.0"
    _tmux("send-keys", "-t", pane0, f"cd {workdir}", "Enter")
    _tmux("split-window", "-h", "-t", f"{tmux_session}:0", "bash")
    pane1 = f"{tmux_session}:0.1"
    _tmux("send-keys", "-t", pane1, f"cd {workdir}", "Enter")
    time.sleep(0.3)

    # (2) launch both agents with --auto
    _tmux("send-keys", "-t", pane0, f"{C2C_BIN} start opencode --auto -n {alias_a}", "Enter")
    _tmux("send-keys", "-t", pane1, f"{C2C_BIN} start opencode --auto -n {alias_b}", "Enter")

    # (3) wait for both to register as alive with correct aliases
    ok_a = _wait_for(lambda: _alive(broker_root, alias_a), timeout=60.0)
    ok_b = _wait_for(lambda: _alive(broker_root, alias_b), timeout=60.0)
    assert ok_a, f"agent {alias_a} never registered alive in {broker_root}"
    assert ok_b, f"agent {alias_b} never registered alive in {broker_root}"

    # (4) wait for each plugin to see session.created (= plugin adopted a
    # session, so the TUI isn't stuck on the opening screen)
    inst_a = _instance_dir(alias_a)
    inst_b = _instance_dir(alias_b)
    assert _wait_for(
        lambda: _debug_log_has(inst_a, "session.created") or _debug_log_has(inst_a, "promptAsync"),
        timeout=90.0,
    ), f"{alias_a} plugin never adopted a session; TUI likely stuck on opening screen"
    assert _wait_for(
        lambda: _debug_log_has(inst_b, "session.created") or _debug_log_has(inst_b, "promptAsync"),
        timeout=90.0,
    ), f"{alias_b} plugin never adopted a session; TUI likely stuck on opening screen"

    # Sanity: neither pane's scrollback should still be on the bare
    # opening-banner state ("Session New session" with no prompt content).
    cap_b = _capture(pane1)
    assert "New session" not in cap_b.splitlines()[-3:] if cap_b else True, (
        f"{alias_b} pane still shows 'New session' banner:\n{cap_b[-400:]}"
    )

    # (5) send a DM from the harness to agent_b and assert plugin
    # delivery via promptAsync in its debug log.
    before = ""
    log_b = inst_b / ".opencode" / "c2c-debug.log"
    if log_b.exists():
        before = log_b.read_text(errors="replace")
    subprocess.run(
        [C2C_BIN, "send", alias_b, f"test-ping-{os.getpid()}"],
        check=True,
        capture_output=True,
        text=True,
        cwd=workdir,
    )
    assert _wait_for(
        lambda: _debug_log_has(inst_b, f"test-ping-{os.getpid()}")
        or (log_b.exists() and "promptAsync RESULT" in log_b.read_text(errors="replace")[len(before):]),
        timeout=45.0,
    ), f"agent {alias_b} plugin never delivered the test DM; log tail:\n{log_b.read_text()[-800:] if log_b.exists() else '(missing)'}"

    # (6) Ctrl-D to close agent_b
    _tmux("send-keys", "-t", pane1, "C-d")

    # (7) After inner exits, outer must also exit (not be SIGTSTP'd).
    # Eventually the shell prompt returns; `fg` must report no jobs.
    assert _wait_for(
        lambda: not _alive(broker_root, alias_b),
        timeout=30.0,
    ), f"agent {alias_b} outer still alive after Ctrl-D; may have backgrounded"

    # Send fg and capture — accept bash or fish's "no current job" error.
    _tmux("send-keys", "-t", pane1, "fg", "Enter")
    time.sleep(1.0)
    cap = _capture(pane1)
    assert (
        "no current job" in cap
        or "no such job" in cap
        or "no suitable job" in cap
        or "There are no" in cap
    ), f"`fg` after Ctrl-D produced no error — outer may have been backgrounded:\n{cap[-400:]}"

    # Record the session id that should be resumed.
    session_file = inst_b / "opencode-session.txt"
    assert session_file.exists(), f"{alias_b} never saved opencode-session.txt"
    prior_sid = session_file.read_text().strip()
    assert prior_sid.startswith("ses_"), f"bad session id saved: {prior_sid!r}"

    # (8) relaunch same alias → expect resume
    _tmux("send-keys", "-t", pane1, f"{C2C_BIN} start opencode -n {alias_b}", "Enter")

    assert _wait_for(lambda: _alive(broker_root, alias_b), timeout=60.0), (
        f"agent {alias_b} never re-registered after resume"
    )

    # Resume should invoke opencode with -s <prior_sid>; verify via
    # client.log (c2c-start logs the argv) and the saved session file
    # still matches.
    client_log = inst_b / "client.log"
    if client_log.exists():
        txt = client_log.read_text(errors="replace")
        assert prior_sid in txt, (
            f"resume launched but prior session id {prior_sid} not in client.log tail:\n{txt[-400:]}"
        )

    # Confirm the resumed session is NOT a fresh blank one — opencode-session.txt
    # should still report the same id.
    resumed_sid = session_file.read_text().strip()
    assert resumed_sid == prior_sid, (
        f"resume created a new session (was {prior_sid}, now {resumed_sid})"
    )

    # Cleanup: stop both agents.
    for alias in (alias_a, alias_b):
        subprocess.run([C2C_BIN, "stop", alias], capture_output=True, text=True, check=False)
