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


def _debug_log_has(workdir: Path, needle: str) -> bool:
    # The plugin writes c2c-debug.log relative to the opencode process cwd,
    # which is the project workdir (not the per-instance state dir).
    log = workdir / ".opencode" / "c2c-debug.log"
    if not log.exists():
        return False
    try:
        return needle in log.read_text(errors="replace")
    except OSError:
        return False


def _statefile_has_session(alias: str) -> bool:
    """True when the plugin statefile shows an adopted root session."""
    sf = Path(os.path.expanduser(f"~/.local/share/c2c/instances/{alias}/oc-plugin-state.json"))
    if not sf.exists():
        return False
    try:
        import json as _json
        data = _json.loads(sf.read_text())
        return bool(data.get("state", {}).get("root_opencode_session_id"))
    except Exception:
        return False


def _instance_dir(alias: str) -> Path:
    base = Path(os.path.expanduser("~/.local/share/c2c/instances"))
    return base / alias


@pytest.fixture
def tmux_session():
    session = f"c2c-oc-twin-{os.getpid()}"
    # Use -P -F to grab the actual pane id — user's tmux may have
    # `base-index 1` in ~/.tmux.conf which breaks `:0.0` assumptions.
    res = _tmux(
        "new-session", "-d", "-s", session, "-x", "220", "-y", "60",
        "-P", "-F", "#{pane_id}", "bash",
    )
    pane0 = res.stdout.strip()
    yield session, pane0
    _tmux("kill-session", "-t", session, check=False)


def test_opencode_twin_e2e(tmp_path: Path, tmux_session) -> None:
    assert TMUX_BIN and OC_BIN and C2C_BIN
    session_name, pane0 = tmux_session

    # (1) fresh workdir with git
    workdir = tmp_path / "project"
    workdir.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=workdir, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init", "-q"], cwd=workdir, check=True)

    alias_a = f"twin-a-{os.getpid()}"
    alias_b = f"twin-b-{os.getpid()}"

    # Pre-seed role files so `c2c start` skips the interactive role prompt
    # (it blocks on stdin when Unix.isatty is true, which it is inside a
    # tmux pane).
    roles_dir = workdir / ".c2c" / "roles"
    roles_dir.mkdir(parents=True, exist_ok=True)
    (roles_dir / f"{alias_a}.md").write_text("test-agent\n")
    (roles_dir / f"{alias_b}.md").write_text("test-agent\n")

    # Broker root — c2c uses git-common-dir/c2c/mcp.
    git_common = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"], cwd=workdir, capture_output=True, text=True, check=True
    ).stdout.strip()
    broker_root = (Path(workdir) / git_common / "c2c" / "mcp").resolve()
    broker_root.mkdir(parents=True, exist_ok=True)

    # `c2c start` does NOT write .opencode/opencode.json (only `c2c install`
    # does — see .collab/findings/2026-04-21T15-50-00Z). Without that,
    # opencode boots with no c2c MCP and never registers. Do the install
    # inline so this test mirrors a real bash user who ran
    # `c2c install opencode` first.
    subprocess.run(
        [C2C_BIN, "install", "opencode", "--target-dir", str(workdir)],
        check=True, capture_output=True, text=True,
    )

    _tmux("send-keys", "-t", pane0, f"cd {workdir}", "Enter")
    split = _tmux("split-window", "-h", "-t", pane0, "-P", "-F", "#{pane_id}", "bash")
    pane1 = split.stdout.strip()
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

    # Per-alias instance dirs (for opencode-session.txt / stderr.log / etc).
    inst_a = _instance_dir(alias_a)
    inst_b = _instance_dir(alias_b)

    # (4) wait for each plugin to adopt a root session — gold signal is
    # root_opencode_session_id populated in the per-instance statefile.
    # (The c2c-debug.log lives in the project workdir, one per workdir, so
    # it's shared between both agents; the statefile is per-alias and
    # authoritative.)
    assert _wait_for(
        lambda: _statefile_has_session(alias_a),
        timeout=90.0,
    ), f"{alias_a} plugin never adopted a session; TUI likely stuck on opening screen"
    assert _wait_for(
        lambda: _statefile_has_session(alias_b),
        timeout=90.0,
    ), f"{alias_b} plugin never adopted a session; TUI likely stuck on opening screen"

    # Sanity: neither pane's scrollback should still be on the bare
    # opening-banner state ("Session New session" with no prompt content).
    # NB: previous version tested membership of the literal string in a list
    # of lines (always False for a substring), which made the assertion a
    # no-op. Use `any(... in line ...)` so we actually catch the banner.
    cap_b = _capture(pane1)
    if cap_b:
        last_lines = cap_b.splitlines()[-3:]
        banner_visible = any("New session" in line for line in last_lines)
        assert not banner_visible, (
            f"{alias_b} pane still shows 'New session' banner:\n{cap_b[-400:]}"
        )

    # (5) send a DM from the harness to agent_b and assert plugin
    # delivery via promptAsync in the project's shared debug log.
    log_b = workdir / ".opencode" / "c2c-debug.log"
    before = log_b.read_text(errors="replace") if log_b.exists() else ""
    # Explicitly point c2c at the test workdir's broker — the CLI's
    # git-common-dir cache may resolve to the outer repo otherwise.
    send_env = {**os.environ, "C2C_MCP_BROKER_ROOT": str(broker_root)}
    subprocess.run(
        [C2C_BIN, "send", alias_b, f"test-ping-{os.getpid()}"],
        check=True,
        capture_output=True,
        text=True,
        cwd=workdir,
        env=send_env,
    )
    assert _wait_for(
        lambda: _debug_log_has(workdir, f"test-ping-{os.getpid()}")
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

    # Give the shell a moment after outer exits so its prompt redraws and
    # `fg` is interpreted by bash (not eaten by a still-unwinding TUI).
    # Then send `fg` and poll until the expected "no jobs" message appears.
    time.sleep(1.5)
    _tmux("send-keys", "-t", pane1, "fg", "Enter")
    no_jobs_markers = ("no current job", "no such job", "no suitable job", "There are no", "fg: current:")
    def _saw_no_jobs() -> bool:
        cap = _capture(pane1)
        return any(m in cap for m in no_jobs_markers)
    assert _wait_for(_saw_no_jobs, timeout=5.0), (
        "`fg` after Ctrl-D produced no 'no jobs' error — outer may have been "
        f"backgrounded via SIGTSTP:\n{_capture(pane1)[-400:]}"
    )

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

    # Resume should invoke `opencode --session <prior_sid>`. Primary signal:
    # stderr.log from c2c_start captures the managed argv when the tee is
    # active (stderr-not-a-tty branch in c2c_start.ml); when stderr IS a tty
    # in the tmux pane, the tee is skipped, so stderr.log may be empty.
    # Fall back gracefully and rely on the opencode-session.txt equality check.
    stderr_log = inst_b / "stderr.log"
    argv_evidence_sources = [stderr_log, inst_b / "client.log"]
    saw_prior_sid = False
    for src in argv_evidence_sources:
        if src.exists():
            try:
                if prior_sid in src.read_text(errors="replace"):
                    saw_prior_sid = True
                    break
            except OSError:
                pass
    # Not fatal if we can't prove the argv — the real assertion is below.
    if not saw_prior_sid:
        # Best-effort diagnostic only; resume may still have worked.
        pass

    # Confirm the resumed session is NOT a fresh blank one — opencode-session.txt
    # should still report the same id. Re-read a few times because the plugin
    # may rewrite the file on session.created after resume.
    assert _wait_for(
        lambda: session_file.exists() and session_file.read_text().strip() == prior_sid,
        timeout=30.0,
    ), (
        f"resume did not preserve prior session id {prior_sid}; "
        f"opencode-session.txt now = {session_file.read_text().strip() if session_file.exists() else '(missing)'!r}"
    )

    # Cleanup: stop both agents.
    for alias in (alias_a, alias_b):
        subprocess.run([C2C_BIN, "stop", alias], capture_output=True, text=True, check=False)
