"""
#407 S2 — cross-host relay E2E tests.

Replaces the old bash-wrapper stub. Tests DM delivery across two
independent broker volumes (broker-a, broker-b) with a relay in between.

Topology: agent-a1 on broker-a  ←→  relay  ←→  agent-b1 on broker-b

AC:
  1. a1 → b1 via relay: b1 receives via poll_inbox
  2. b1 → a1 via relay: a1 receives via poll_inbox
  3. Dead-letter: send to unknown@unknown-host → dead_letter count increases

Depends on: docker-compose.e2e-multi-agent.yml
"""
import json
import os
import subprocess
import time

import pytest

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_A2 = "c2c-e2e-agent-a2"
AGENT_B1 = "c2c-e2e-agent-b1"
AGENT_B2 = "c2c-e2e-agent-b2"
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
    reason="cross-host relay tests require docker CLI + host docker socket",
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


def send_msg(container: str, to_alias: str, msg: str) -> subprocess.CompletedProcess:
    """Send a DM from container's registered alias to a cross-host recipient."""
    return _run_in(container, ["send", to_alias, msg])


def poll_inbox(container: str) -> list[dict]:
    """Poll inbox and return messages."""
    r = _run_in(container, ["poll-inbox", "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def list_peers(container: str) -> list[dict]:
    """List peers visible to this container's broker."""
    r = _run_in(container, ["list", "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            return []
    return []


def dead_letter_count(relay_container: str = RELAY) -> int:
    """Return current dead_letter row count in the relay's broker."""
    r = _run_in(relay_container, ["dead-letter", "--json"])
    if r.returncode == 0:
        try:
            entries = json.loads(r.stdout)
            return len(entries) if isinstance(entries, list) else 0
        except json.JSONDecodeError:
            pass
    return -1


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def topology():
    compose_up()
    yield
    compose_down()


@pytest.fixture
def a1(topology):
    return AGENT_A1


@pytest.fixture
def a2(topology):
    return AGENT_A2


@pytest.fixture
def b1(topology):
    return AGENT_B1


@pytest.fixture
def b2(topology):
    return AGENT_B2


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_a1_to_b1_via_relay(a1, b1):
    """agent-a1 (broker-a) sends DM to agent-b1 (broker-b) via relay.

    AC: b1 receives the message in its poll_inbox within 10s.
    """
    # Register a1 on broker-a
    r = register(a1, "a1")
    assert r.returncode == 0, f"a1 register failed: {r.stderr}"
    # Register b1 on broker-b
    r = register(b1, "b1")
    assert r.returncode == 0, f"b1 register failed: {r.stderr}"
    time.sleep(1)

    # Verify b1 is NOT in a1's peer list (cross-host — must go via relay)
    peers_a1 = list_peers(a1)
    peer_aliases_a1 = [p.get("alias", "") for p in peers_a1]
    assert "b1" not in peer_aliases_a1, \
        "b1 should NOT appear in a1's local peer list (cross-host via relay only)"
    print("[cross-host] a1 cannot see b1 in local broker peers ✅")

    # a1 sends to b1 via relay
    msg = f"hello-b1-from-a1-{int(time.time() * 1000)}"
    r = send_msg(a1, "b1", msg)
    assert r.returncode == 0, f"a1→b1 send failed: {r.stderr}"
    print(f"[cross-host] a1 sent: {msg}")

    # b1 polls and receives the message
    time.sleep(2)
    b1_inbox = poll_inbox(b1)
    assert any(msg in m.get("content", "") for m in b1_inbox), \
        f"b1 should receive a1's message via relay: {b1_inbox}"
    print("[cross-host] b1 received a1's message via relay ✅")


def test_b1_to_a1_via_relay(a1, b1):
    """agent-b1 (broker-b) sends DM to agent-a1 (broker-a) via relay.

    AC: a1 receives the message in its poll_inbox within 10s.
    """
    # Register b1 on broker-b
    r = register(b1, "b1")
    assert r.returncode == 0, f"b1 register failed: {r.stderr}"
    # Register a1 on broker-a
    r = register(a1, "a1")
    assert r.returncode == 0, f"a1 register failed: {r.stderr}"
    time.sleep(1)

    # b1 sends to a1 via relay
    msg = f"hello-a1-from-b1-{int(time.time() * 1000)}"
    r = send_msg(b1, "a1", msg)
    assert r.returncode == 0, f"b1→a1 send failed: {r.stderr}"
    print(f"[cross-host] b1 sent: {msg}")

    # a1 polls and receives the message
    time.sleep(2)
    a1_inbox = poll_inbox(a1)
    assert any(msg in m.get("content", "") for m in a1_inbox), \
        f"a1 should receive b1's message via relay: {a1_inbox}"
    print("[cross-host] a1 received b1's message via relay ✅")


def test_unknown_host_dead_letter(a1):
    """Send to unknown@unknown-host → dead_letter count increases on relay.

    AC: dead-letter count increases after attempting DM to unknown host.
    """
    # Register a1 so relay knows about it
    r = register(a1, "a1")
    assert r.returncode == 0, f"a1 register failed: {r.stderr}"
    time.sleep(1)

    baseline = dead_letter_count()
    print(f"[dead-letter] baseline: {baseline}")

    # Send to a non-existent alias on a non-existent host
    r = send_msg(a1, "nobody@nowhere-host-xyz", f"ghost-msg-{int(time.time())}")
    # Send may succeed (queued) or fail — we're checking dead-letter increment
    print(f"[dead-letter] send result: rc={r.returncode}, stderr={r.stderr[:100]}")

    time.sleep(2)
    after = dead_letter_count()
    print(f"[dead-letter] after: {after}")
    assert after > baseline, \
        f"dead-letter count should increase for unknown host (baseline={baseline}, after={after})"
    print("[dead-letter] unknown@unknown-host correctly dead-lettered ✅")


def test_bidirectional_cross_host_dm(a1, b1):
    """Simultaneous cross-host send both directions — both deliver.

    AC: a1→b1 and b1→a1 both succeed, both sides receive.
    """
    r = register(a1, "a1-bidir")
    assert r.returncode == 0, f"a1 register failed: {r.stderr}"
    r = register(b1, "b1-bidir")
    assert r.returncode == 0, f"b1 register failed: {r.stderr}"
    time.sleep(1)

    msg_a2b = f"a1-to-b1-bidir-{int(time.time() * 1000)}"
    msg_b2a = f"b1-to-a1-bidir-{int(time.time() * 1000)}"

    # Send both simultaneously
    r1 = send_msg(a1, "b1-bidir", msg_a2b)
    r2 = send_msg(b1, "a1-bidir", msg_b2a)
    assert r1.returncode == 0, f"a1→b1 failed: {r1.stderr}"
    assert r2.returncode == 0, f"b1→a1 failed: {r2.stderr}"
    print(f"[bidir] a1 sent: {msg_a2b}, b1 sent: {msg_b2a}")

    time.sleep(2)
    b1_inbox = poll_inbox(b1)
    a1_inbox = poll_inbox(a1)

    assert any(msg_a2b in m.get("content", "") for m in b1_inbox), \
        f"b1 should receive a1's message: {b1_inbox}"
    assert any(msg_b2a in m.get("content", "") for m in a1_inbox), \
        f"a1 should receive b1's message: {a1_inbox}"
    print("[bidir] both directions delivered ✅")
