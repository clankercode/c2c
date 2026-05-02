"""
#407 S12: monitor leak guard E2E — inotify watch cleanup after session end.

Tests that `c2c monitor` running inside a container does NOT leak inotify
watches after the process terminates. This is a known failure mode: if
inotify watches are not explicitly closed on exit, they persist until the
kernel realises the holder is dead — but the kernel-only cleanup path can
leave "ghost" watches visible briefly or cause resource exhaustion under
heavy monitor churn.

AC:
  1. Inside a container, start `c2c monitor` for an alias.
  2. Wait for it to arm (inotify watches established).
  3. Verify inotify watches exist for the monitor process.
  4. Kill the monitor process (SIGTERM).
  5. After process exit, verify NO inotify watches remain for that PID.

Contrast with the sealed env circuit-breaker (monitor exits immediately when
second monitor for same alias starts — test_monitor_leak_guard.py). This test
covers the inotify watch lifecycle, not the duplicate-guard.

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline)
"""
import os
import subprocess
import time

import pytest

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"


def docker_available():
    if not os.path.exists("/var/run/docker.sock"):
        return False
    probe = subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "version"],
        capture_output=True, text=True, timeout=10,
    )
    return probe.returncode == 0


pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="e2e tests require docker CLI + host docker socket",
)


def _wait_relay_healthy(timeout: int = 90) -> None:
    """Wait for the relay to become healthy."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", "c2c-e2e-relay"],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip() == "healthy":
            return
        time.sleep(2)
    raise RuntimeError("Relay did not become healthy within {}s".format(timeout))


def compose_up():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "up", "-d", "--build", "--wait", "--wait-timeout", "120"],
        check=True, timeout=180,
    )
    _wait_relay_healthy()
    time.sleep(2)


def compose_down():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "down", "-v", "--remove-orphans"],
         capture_output=True, timeout=60,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

C2C_CLI = "/usr/local/bin/c2c"


def _run_in(container: str, argv: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    """Run c2c CLI inside a container as testagent (uid 999)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, C2C_CLI] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def register(container: str, alias: str, session_id: str) -> subprocess.CompletedProcess:
    """Register alias on local broker inside container."""
    return _run_in(container, ["register", "--alias", alias, "--session-id", session_id])


def count_inotify_watches_in_container(container: str, pid: int) -> int:
    """Count inotify watches for a process inside a container.

    inotify watches appear as entries in /proc/<pid>/fdinfo/ where the
    'inotify' key is present. Returns the number of inotify watches.
    """
    script = """
    count=0
    for fdinfo in /proc/{pid}/fdinfo/*; do
        if grep -q "^inotify" "$fdinfo" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo $count
    """.format(pid=pid)
    r = subprocess.run(
        ["docker", "exec", "-u", "0", container, "bash", "-c", script],
        capture_output=True, text=True, timeout=10,
    )
    try:
        return int(r.stdout.strip())
    except ValueError:
        # PID disappeared (process already dead) — return -1 to signal "gone"
        return -1


def start_monitor_bg(container: str, alias: str, session_id: str) -> int:
    """Start c2c monitor in background inside container. Returns the monitor PID."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
        "C2C_MCP_SESSION_ID": session_id,
        "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, C2C_CLI, "monitor", "--alias", alias]
    # Start in background — we only need the PID, not the output
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    # Wait a moment for the process to fork/exec
    time.sleep(1.5)
    # Get the PID of the inotifywait subprocess (it's the child of the c2c monitor)
    # The c2c monitor itself is the parent; inotifywait is the one with inotify fds.
    # Better: find the c2c monitor PID via pgrep in the container
    pid_script = "pgrep -P $(pgrep -f 'c2c monitor') 2>/dev/null | head -1 || pgrep -f inotifywait | head -1 || echo NONE"
    r = subprocess.run(
        ["docker", "exec", "-u", "0", container, "bash", "-c", pid_script],
        capture_output=True, text=True, timeout=10,
    )
    pid_str = r.stdout.strip()
    if pid_str == "NONE" or not pid_str:
        # Fall back: use pgrep to find c2c monitor directly
        pid_script2 = "pgrep -f 'c2c monitor' | head -1 || echo NONE"
        r2 = subprocess.run(
            ["docker", "exec", "-u", "0", container, "bash", "-c", pid_script2],
            capture_output=True, text=True, timeout=10,
        )
        pid_str = r2.stdout.strip()
    if not pid_str or pid_str == "NONE":
        proc.terminate()
        raise RuntimeError("Could not find monitor PID in container {}".format(container))
    return int(pid_str)


def kill_monitor(container: str, pid: int) -> None:
    """Send SIGTERM to the monitor PID inside the container."""
    r = subprocess.run(
        ["docker", "exec", "-u", "0", container, "kill", str(pid)],
        capture_output=True, text=True, timeout=10,
    )
    # Don't assert on return code — process may already be dead


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_monitor_inotify_watches_cleaned_up_on_exit(agent_a1):
    """Monitor inotify watches are fully released after process termination.

    1. Register alias 'monitor-test' on broker inside agent-a1 container.
    2. Start c2c monitor for that alias (background).
    3. Wait for inotify watches to be established.
    4. Verify inotify watches exist for the monitor process.
    5. Kill the monitor (SIGTERM).
    6. Verify inotify watch count for that PID is 0 (PID may be reaped —
       in that case -1 means the PID is gone, which is also "watches cleaned").

    The key assertion: after kill, either the PID is gone (watches died with it)
    OR the PID is still there but has 0 inotify watches.
    """
    alias = "monitor-test"
    session_id = "monitor-test-session"
    ts = int(time.time() * 1000)
    unique = f"mon-{ts}"

    # Register the alias
    r = register(agent_a1, alias, session_id)
    if r.returncode not in (0, 2):
        pytest.fail("register failed: {}".format(r.stderr))
    time.sleep(0.5)

    # Start monitor in background — capture its PID
    pid = start_monitor_bg(agent_a1, alias, session_id)
    print("[s12] monitor started with PID {} inside {}".format(pid, agent_a1))

    # Wait for inotify watches to be established (inotifywait arms asynchronously)
    time.sleep(2)

    # Verify watches exist while monitor is alive
    watch_count_before = count_inotify_watches_in_container(agent_a1, pid)
    assert watch_count_before > 0, \
        "monitor should have established inotify watches (got {})".format(watch_count_before)
    print("[s12] inotify watches while monitor alive: {} ✅".format(watch_count_before))

    # Kill the monitor
    kill_monitor(agent_a1, pid)
    print("[s12] sent SIGTERM to PID {}".format(pid))

    # Wait for the process to exit and kernel to clean up
    time.sleep(2)

    # Check: PID should either be gone (reaped) OR have 0 inotify watches
    watch_count_after = count_inotify_watches_in_container(agent_a1, pid)
    if watch_count_after == -1:
        # PID was reaped — watches died with it
        print("[s12] PID {} reaped after SIGTERM, watches cleaned ✅".format(pid))
    else:
        assert watch_count_after == 0, \
            "after SIGTERM, monitor PID {} should have 0 inotify watches, got {}".format(
                pid, watch_count_after)
        print("[s12] PID {} still alive but inotify watches = 0 ✅".format(pid))


def test_no_inotify_watch_leak_under_rapid_restart(agent_a1):
    """Rapid start-kill cycles do not accumulate inotify watches.

    1. Register alias.
    2. Start + kill monitor 5 times in quick succession.
    3. After all cycles, verify the container's total inotify watch count
       is NOT significantly higher than baseline.

    Under a leaking monitor, each kill would leave watches dangling, and the
    cumulative watch count would grow with each cycle. Under a correct monitor,
    each cycle's watches are cleaned up on exit.
    """
    alias = "mon-rapid"
    session_id = "mon-rapid-session"
    ts = int(time.time() * 1000)
    n_cycles = 5

    # Register the alias
    r = register(agent_a1, alias, session_id)
    if r.returncode not in (0, 2):
        pytest.fail("register failed: {}".format(r.stderr))
    time.sleep(0.5)

    # Measure baseline inotify watches in the container (before any monitor)
    baseline_script = """
    total=0
    for pid in /proc/[0-9]*/fdinfo/*; do
        if grep -q "^inotify" "$pid" 2>/dev/null; then
            total=$((total + 1))
        fi
    done
    echo $total
    """
    r_base = subprocess.run(
        ["docker", "exec", "-u", "0", agent_a1, "bash", "-c", baseline_script],
        capture_output=True, text=True, timeout=10,
    )
    baseline = int(r_base.stdout.strip())
    print("[s12] baseline inotify watches in {}: {}".format(agent_a1, baseline))

    # Rapid start-kill cycles
    pids = []
    for i in range(n_cycles):
        pid = start_monitor_bg(agent_a1, alias, session_id)
        pids.append(pid)
        print("[s12] cycle {}: started PID {}".format(i + 1, pid))
        time.sleep(0.3)
        kill_monitor(agent_a1, pid)
        time.sleep(0.3)

    # Wait for all processes to exit
    time.sleep(3)

    # Measure final inotify watch count
    r_final = subprocess.run(
        ["docker", "exec", "-u", "0", agent_a1, "bash", "-c", baseline_script],
        capture_output=True, text=True, timeout=10,
    )
    final = int(r_final.stdout.strip())
    print("[s12] final inotify watches in {}: {} (baseline: {})".format(
        agent_a1, final, baseline))

    # Allow some tolerance (the broker itself uses inotify for some watches),
    # but the difference should be small — definitely not +5 (one per cycle).
    # The test broker may have a few persistent watches; we check the delta.
    delta = final - baseline
    assert delta <= 2, \
        "after {} rapid start-kill cycles, inotify watch delta should be <= 2 " \
        "(leak would give ~{} extra watches), got delta={}".format(
            n_cycles, n_cycles, delta)
    print("[s12] inotify watch delta after {} cycles: {} ✅ (no leak)".format(
        n_cycles, delta))


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def topology():
    compose_up()
    yield
    compose_down()


@pytest.fixture
def agent_a1(topology):
    return AGENT_A1
