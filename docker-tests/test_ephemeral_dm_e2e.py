"""
#407 S11: ephemeral DM E2E — archive file contract in Docker cross-container topology.

Tests that `c2c send <alias> <msg> --ephemeral` delivers normally but skips
the recipient-side archive append, while normal DMs DO appear in the archive.

Topology: agent-a1 + agent-a2 on broker-a (host-A),
         agent-b1 + agent-b2 on broker-b (host-B),
         relay in between.

AC:
  1. agent-a1 sends ephemeral DM to agent-b1 → b1 receives it via poll_inbox,
     but the archive file does NOT contain it.
  2. agent-a1 sends normal DM to agent-b1 → b1 receives it,
     and the archive file DOES contain it.

Contrast: ephemeral skipped archive vs normal hits archive.

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline)
"""
import json
import os
import subprocess
import time

import pytest

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_B1 = "c2c-e2e-agent-b1"


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
# Helpers (run inside containers)
# ---------------------------------------------------------------------------

C2C_CLI = "/usr/local/bin/c2c"


def _run_in(container: str, argv: list[str], session_id: str | None = None,
            alias: str | None = None) -> subprocess.CompletedProcess:
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
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def _run_shell_in(container: str, script: str) -> subprocess.CompletedProcess:
    """Run a shell script inside a container as testagent."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, "bash", "-c", script]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def register(container: str, alias: str) -> subprocess.CompletedProcess:
    """Register alias on local broker inside container."""
    session_id = f"{alias}-session"
    return _run_in(container, ["register", "--alias", alias, "--session-id", session_id])


def send_msg(container: str, to_alias: str, msg: str, ephemeral: bool = False,
             from_alias: str | None = None) -> subprocess.CompletedProcess:
    """Send a DM from container's registered alias."""
    argv = ["send", to_alias, msg]
    if ephemeral:
        argv.append("--ephemeral")
    return _run_in(container, argv)


def poll_inbox(container: str) -> tuple[list[dict], str]:
    """Poll inbox and return messages."""
    r = _run_in(container, ["poll-inbox", "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout), r.stderr
        except json.JSONDecodeError:
            return [], r.stderr
    return [], r.stderr


def archive_file_contains(container: str, session_id: str, msg_fragment: str) -> bool:
    """Check if the archive file for session_id contains the msg fragment.

    Archive path: <broker_root>/archive/<session_id>.jsonl
    Returns True if found, False if not found or file missing.
    """
    broker_root = "/home/testagent/.c2c/broker"
    archive_path = f"{broker_root}/archive/{session_id}.jsonl"
    script = f"grep -F {repr(msg_fragment)} {archive_path} 2>/dev/null && echo FOUND || echo MISSING"
    r = _run_shell_in(container, script)
    return "FOUND" in r.stdout


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_ephemeral_skips_archive(agent_a1, agent_b1):
    """Ephemeral DM: poll_inbox receives it, but archive file does NOT contain it.

    1. Register a1 and b1 on their respective brokers.
    2. a1 sends ephemeral DM to b1.
    3. b1 poll_inbox → receives the message.
    4. b1's archive file → does NOT contain the message.
    """
    # Register both agents
    for agent, alias in [(agent_a1, "a1"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s11] register warning for {}: {}".format(alias, r.stderr))
    time.sleep(1)

    # a1 sends ephemeral DM to b1
    ephemeral_msg = "ephemeral secret {}".format(int(time.time()))
    r = send_msg(agent_a1, "b1", ephemeral_msg, ephemeral=True)
    assert r.returncode == 0, "ephemeral send failed: {}".format(r.stderr)
    print("[s11] a1 sent ephemeral to b1: {}".format(ephemeral_msg))

    # b1 poll_inbox → must receive it
    b1_inbox, _ = poll_inbox(agent_b1)
    assert any(ephemeral_msg in m.get("content", "") for m in b1_inbox), \
        "b1 should receive ephemeral message via poll_inbox: {}".format(b1_inbox)
    print("[s11] b1 received ephemeral via poll_inbox ✅")

    # b1's archive file → must NOT contain the ephemeral message
    b1_session = "b1-session"
    has_it = archive_file_contains(agent_b1, b1_session, ephemeral_msg)
    assert not has_it, \
        "b1 archive should NOT contain ephemeral message, but it does"
    print("[s11] b1 archive correctly does NOT contain ephemeral message ✅")


def test_normal_hits_archive(agent_a1, agent_b1):
    """Normal DM: poll_inbox receives it AND archive file DOES contain it.

    1. Register a1 and b1.
    2. a1 sends normal DM to b1.
    3. b1 poll_inbox → receives the message.
    4. b1's archive file → DOES contain the message.
    """
    # Register both agents
    for agent, alias in [(agent_a1, "a1"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s11] register warning for {}: {}".format(alias, r.stderr))
    time.sleep(1)

    # a1 sends normal DM to b1
    normal_msg = "normal message {}".format(int(time.time()))
    r = send_msg(agent_a1, "b1", normal_msg, ephemeral=False)
    assert r.returncode == 0, "normal send failed: {}".format(r.stderr)
    print("[s11] a1 sent normal to b1: {}".format(normal_msg))

    # b1 poll_inbox → must receive it
    b1_inbox, _ = poll_inbox(agent_b1)
    assert any(normal_msg in m.get("content", "") for m in b1_inbox), \
        "b1 should receive normal message via poll_inbox: {}".format(b1_inbox)
    print("[s11] b1 received normal via poll_inbox ✅")

    # b1's archive file → must contain the normal message
    b1_session = "b1-session"
    time.sleep(1)  # allow archive write to settle
    has_it = archive_file_contains(agent_b1, b1_session, normal_msg)
    assert has_it, \
        "b1 archive should contain normal message, but it doesn't"
    print("[s11] b1 archive correctly contains normal message ✅")


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


@pytest.fixture
def agent_b1(topology):
    return AGENT_B1
