"""
#407 S10: deferrable DM E2E — push suppression in Docker cross-container topology.

Tests that `c2c send <alias> <msg> --deferrable` delivers the message
but push paths skip it — recipient only sees it on explicit poll_inbox.

Topology: agent-a1 on broker-a (host-A),
          agent-b1 on broker-b (host-B),
          relay in between.

AC:
  1. agent-a1 sends deferrable DM to agent-b1 →
     b1 receives it via poll_inbox, but the relay's tail_log shows NO
     deliver event for this message (push was suppressed).
  2. Contrast: agent-a1 sends non-deferrable DM to agent-b1 →
     b1 receives it via poll_inbox AND the relay's tail_log shows a
     deliver event (push was used).

The sealed env test (test_drain_inbox_push_suppresses_deferrable) already
proves the broker-level contract: drain_inbox_push filters deferrable
messages. This E2E test validates it holds across the Docker relay topology.

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
RELAY = "c2c-e2e-relay"


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


def _run_in(container: str, argv: list[str]) -> subprocess.CompletedProcess:
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


def send_msg(container: str, to_alias: str, msg: str, deferrable: bool = False,
             from_alias: str | None = None) -> subprocess.CompletedProcess:
    """Send a DM from container's registered alias.

    Uses `c2c send` CLI which maps --deferrable to the deferrable flag.
    """
    argv = ["send", to_alias, msg]
    if deferrable:
        argv.append("--deferrable")
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


def relay_tail_log(limit: int = 50) -> list[dict]:
    """Get the relay's tail_log entries as parsed JSON list."""
    r = _run_in(RELAY, ["tail-log", "--json", "--limit", str(limit)])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def relay_log_contains_deliver_for_content(content_fragment: str, log: list[dict]) -> bool:
    """Return True if any log entry is a deliver event mentioning the content."""
    for entry in log:
        # entries are JSON objects with "tool" or "event" keys
        if entry.get("event") == "deliver" or entry.get("tool") == "deliver":
            # The content field is inside the entry body
            entry_str = json.dumps(entry)
            if content_fragment in entry_str:
                return True
    return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_deferrable_skips_push(agent_a1, agent_b1):
    """Deferrable DM: poll_inbox receives it, but relay log shows NO deliver event.

    1. Register a1 and b1 on their respective brokers.
    2. Clear relay tail_log (record baseline timestamp).
    3. a1 sends deferrable DM to b1.
    4. b1 poll_inbox → receives the message.
    5. Relay tail_log → does NOT contain a deliver event for this message.

    This mirrors the sealed env contract:
    drain_inbox_push suppresses deferrable; only poll_inbox can retrieve them.
    """
    # Register both agents
    for agent, alias in [(agent_a1, "a1"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s10] register warning for {}: {}".format(alias, r.stderr))
    time.sleep(1)

    # Capture timestamp before sending so we only look at new log entries
    before_ts = time.time()

    # a1 sends deferrable DM to b1
    deferrable_msg = "deferrable-{}".format(int(time.time() * 1000))
    r = send_msg(agent_a1, "b1", deferrable_msg, deferrable=True)
    assert r.returncode == 0, "deferrable send failed: {}".format(r.stderr)
    print("[s10] a1 sent deferrable to b1: {}".format(deferrable_msg))

    # b1 poll_inbox → must receive it
    time.sleep(1)  # allow routing to settle
    b1_inbox, _ = poll_inbox(agent_b1)
    assert any(deferrable_msg in m.get("content", "") for m in b1_inbox), \
        "b1 should receive deferrable message via poll_inbox: {}".format(b1_inbox)
    print("[s10] b1 received deferrable via poll_inbox ✅")

    # Relay tail_log → must NOT contain a deliver event for this message
    time.sleep(1)  # allow log to flush
    log = relay_tail_log(limit=100)
    # Filter to entries after our before_ts (in case relay logs old entries)
    recent = [e for e in log if e.get("ts", 0) >= before_ts - 1]
    has_deliver = relay_log_contains_deliver_for_content(deferrable_msg, recent)
    assert not has_deliver, \
        "relay log should NOT contain a deliver event for deferrable message, but it does"
    print("[s10] relay correctly suppressed push for deferrable message ✅")


def test_non_deferrable_reaches_push(agent_a1, agent_b1):
    """Non-deferrable DM: poll_inbox receives it AND relay log shows deliver event.

    1. Register a1 and b1.
    2. a1 sends non-deferrable DM to b1.
    3. b1 poll_inbox → receives the message.
    4. Relay tail_log → DOES contain a deliver event for this message.

    Contrast with test_deferrable_skips_push: this message IS delivered via push.
    """
    # Register both agents
    for agent, alias in [(agent_a1, "a1"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s10] register warning for {}: {}".format(alias, r.stderr))
    time.sleep(1)

    before_ts = time.time()

    # a1 sends non-deferrable DM to b1
    normal_msg = "normal-{}".format(int(time.time() * 1000))
    r = send_msg(agent_a1, "b1", normal_msg, deferrable=False)
    assert r.returncode == 0, "normal send failed: {}".format(r.stderr)
    print("[s10] a1 sent normal to b1: {}".format(normal_msg))

    # b1 poll_inbox → must receive it
    time.sleep(1)
    b1_inbox, _ = poll_inbox(agent_b1)
    assert any(normal_msg in m.get("content", "") for m in b1_inbox), \
        "b1 should receive normal message via poll_inbox: {}".format(b1_inbox)
    print("[s10] b1 received normal via poll_inbox ✅")

    # Relay tail_log → must contain a deliver event for this message
    time.sleep(1)
    log = relay_tail_log(limit=100)
    recent = [e for e in log if e.get("ts", 0) >= before_ts - 1]
    has_deliver = relay_log_contains_deliver_for_content(normal_msg, recent)
    assert has_deliver, \
        "relay log should contain a deliver event for normal message, but it doesn't"
    print("[s10] relay correctly delivered normal message via push ✅")


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
