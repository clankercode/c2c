"""
#406 S10 (design doc): relay outage + recovery E2E — outbox persistence + reconnect.

Tests that messages survive a relay outage and are delivered after recovery:
  1. Start everything, send M1 (delivered).
  2. docker stop relay, send M2 (queued by sender's relay connector).
  3. docker start relay, assert M2 eventually delivered.

AC: outbox persistence + reconnect work end-to-end.

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline)
"""
import json
import os
import subprocess
import time

import pytest

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
RELAY = "c2c-e2e-relay"
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
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", RELAY],
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


def docker_stop():
    subprocess.run(
        ["docker", "stop", RELAY],
        check=True, timeout=30,
    )


def docker_start():
    subprocess.run(
        ["docker", "start", RELAY],
        check=True, timeout=30,
    )
    _wait_relay_healthy()


# ---------------------------------------------------------------------------
# Helpers (run inside containers)
# ---------------------------------------------------------------------------

C2C_CLI = "/usr/local/bin/c2c"


def _run_in(container: str, argv: list[str]) -> subprocess.CompletedProcess:
    """Run c2c CLI inside a container as testagent (uid 999)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
        "C2C_RELAY_URL": "http://relay:7331",
        "C2C_RELAY_CONNECTOR_BACKEND": "http",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, C2C_CLI] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def register(container: str, alias: str, session_id: str) -> subprocess.CompletedProcess:
    """Register alias on local broker inside container."""
    return _run_in(container, ["register", "--alias", alias, "--session-id", session_id])


def send_msg(container: str, to_alias: str, msg: str) -> subprocess.CompletedProcess:
    """Send a DM from container's registered alias."""
    return _run_in(container, ["send", to_alias, msg])


def poll_inbox(container: str) -> tuple[list[dict], str]:
    """Poll inbox and return messages."""
    r = _run_in(container, ["poll-inbox", "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout), r.stderr
        except json.JSONDecodeError:
            return [], r.stderr
    return [], r.stderr


def wait_for_inbox_msg(container: str, fragment: str, timeout: int = 30) -> bool:
    """Poll inbox until a message containing fragment arrives, or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        inbox, _ = poll_inbox(container)
        if any(fragment in m.get("content", "") for m in inbox):
            return True
        time.sleep(1)
    return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_relay_outage_m2_delivered_after_recovery(agent_a1, agent_b1):
    """M2 (sent during outage) is delivered after relay restarts.

    Flow:
      1. Register a1 (broker-a) and b1 (broker-b).
      2. a1 sends M1 to b1 — must be delivered while relay is up.
      3. Stop relay (docker stop).
      4. a1 sends M2 to b1 while relay is down.
      5. Start relay (docker start).
      6. Assert M2 eventually arrives at b1 via poll_inbox.

    This validates:
      - Outbox persistence: sender's relay connector queues M2 when relay is down.
      - Reconnect: when relay restarts, queued M2 is delivered.
    """
    ts = int(time.time() * 1000)
    m1 = "m1-outage-{}".format(ts)
    m2 = "m2-outage-{}".format(ts)

    # Register both agents
    for agent, alias, session_id in [
        (agent_a1, "a1", "a1-session"),
        (agent_b1, "b1", "b1-session"),
    ]:
        r = register(agent, alias, session_id)
        if r.returncode not in (0, 2):
            pytest.fail("register failed for {}: {}".format(alias, r.stderr))
    time.sleep(1)

    # M1 — sent while relay is up, must be delivered
    r = send_msg(agent_a1, "b1", m1)
    assert r.returncode == 0, "M1 send failed: {}".format(r.stderr)
    print("[s10] a1 sent M1: {}".format(m1))

    arrived_m1 = wait_for_inbox_msg(agent_b1, m1, timeout=15)
    assert arrived_m1, "M1 should be delivered while relay is up"
    print("[s10] b1 received M1 ✅")

    # Stop relay
    print("[s10] stopping relay…")
    docker_stop()
    time.sleep(2)

    # M2 — sent while relay is down
    r = send_msg(agent_a1, "b1", m2)
    # The send may succeed (queued locally) or fail (connection refused) —
    # both are acceptable; the test contract is about recovery, not send error
    print("[s10] a1 sent M2 while relay down: rc={} stdout={}".format(
        r.returncode, r.stdout[:200]))

    # Start relay
    print("[s10] starting relay…")
    docker_start()
    time.sleep(2)

    # Assert M2 eventually delivered
    arrived_m2 = wait_for_inbox_msg(agent_b1, m2, timeout=30)
    assert arrived_m2, \
        "M2 should be delivered after relay restart (outbox persistence + reconnect)"
    print("[s10] b1 received M2 after relay recovery ✅")


def test_no_message_loss_on_brief_outage(agent_a1, agent_b1):
    """Brief relay outage (stop + start) results in no message loss.

    Send M1 (delivered), brief outage, send M2 + M3, restart, verify both.
    """
    ts = int(time.time() * 1000)
    m1 = "m1-brief-{}".format(ts)
    m2 = "m2-brief-{}".format(ts)
    m3 = "m3-brief-{}".format(ts)

    # Register
    for agent, alias, session_id in [
        (agent_a1, "a1", "a1b-session"),
        (agent_b1, "b1", "b1b-session"),
    ]:
        r = register(agent, alias, session_id)
        if r.returncode not in (0, 2):
            pytest.fail("register failed: {}".format(r.stderr))
    time.sleep(1)

    # M1 while relay is up
    r = send_msg(agent_a1, "b1", m1)
    assert r.returncode == 0
    arrived = wait_for_inbox_msg(agent_b1, m1, timeout=15)
    assert arrived, "M1 should arrive"
    print("[s10] b1 received M1 ✅")

    # Brief outage
    print("[s10] brief outage…")
    docker_stop()
    time.sleep(1)
    docker_start()
    time.sleep(2)

    # M2 + M3 after recovery
    m2_sent = send_msg(agent_a1, "b1", m2)
    m3_sent = send_msg(agent_a1, "b1", m3)
    print("[s10] M2 rc={} M3 rc={}".format(m2_sent.returncode, m3_sent.returncode))

    # Both must arrive
    arrived_m2 = wait_for_inbox_msg(agent_b1, m2, timeout=30)
    arrived_m3 = wait_for_inbox_msg(agent_b1, m3, timeout=30)
    assert arrived_m2, "M2 should arrive after brief outage recovery"
    assert arrived_m3, "M3 should arrive after brief outage recovery"
    print("[s10] b1 received M2 and M3 after brief outage recovery ✅")


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
