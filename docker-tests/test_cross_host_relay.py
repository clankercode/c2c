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
    # Use --wait but not --build: images are pre-built by CI or a prior run.
    # `check=True` is intentionally omitted: docker compose up can return exit 1
    # when images already exist locally (docker.io library conflict) even though
    # containers are running correctly.
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "up", "-d", "--wait", "--wait-timeout", "120"],
        capture_output=True, timeout=180,
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


def _run_in(container: str, argv: list[str], session_id: str = "") -> subprocess.CompletedProcess:
    """Run c2c CLI inside a container (runs as root since volumes are root-owned)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/root",
        "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
    }
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [container, C2C_CLI] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def _run_shell_in(container: str, script: str) -> subprocess.CompletedProcess:
    """Run a shell script inside a container (runs as root since volumes are root-owned)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/root",
        "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [container, "bash", "-c", script]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def register(container: str, alias: str) -> subprocess.CompletedProcess:
    """Register alias on local broker inside container."""
    session_id = f"{alias}-session"
    return _run_in(container, ["register", "--alias", alias, "--session-id", session_id])


def send_msg(container: str, to_alias: str, msg: str) -> subprocess.CompletedProcess:
    """Send a DM from container's registered alias to a cross-host recipient."""
    return _run_in(container, ["send", to_alias, msg])


def sync_now(container: str) -> subprocess.CompletedProcess:
    """Trigger an immediate connector sync (register + forward outbox + poll inbound)."""
    return _run_in(container, ["relay", "connect", "--once"])


def poll_inbox(container: str, session_id: str) -> list[dict]:
    """Poll inbox and return messages for the given session_id."""
    r = _run_in(container, ["poll-inbox", "--json"], session_id=session_id)
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
    """Return current dead_letter row count in the relay's SQLite DB.

    The relay stores dead-letters in its SqliteRelay database, NOT in the
    broker's file-based dead-letter path that `c2c dead-letter --json` reads.
    We query the relay DB directly via sqlite3.
    """
    r = subprocess.run(
        ["docker", "exec", relay_container,
         "sqlite3", "/var/lib/c2c/c2c_relay.db",
         "SELECT COUNT(*) FROM dead_letter"],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode == 0:
        try:
            return int(r.stdout.strip())
        except ValueError:
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

    # Sync with relay: register aliases so relay knows about them
    r = sync_now(a1)
    assert r.returncode == 0, f"a1 sync failed: {r.stderr}"
    r = sync_now(b1)
    assert r.returncode == 0, f"b1 sync failed: {r.stderr}"
    time.sleep(1)

    # Verify b1 is NOT in a1's peer list (cross-host — must go via relay)
    peers_a1 = list_peers(a1)
    peer_aliases_a1 = [p.get("alias", "") for p in peers_a1]
    assert "b1" not in peer_aliases_a1, \
        "b1 should NOT appear in a1's local peer list (cross-host via relay only)"
    print("[cross-host] a1 cannot see b1 in local broker peers ✅")

    # a1 sends to b1 via relay (must use alias@relay format — broker does not
    # fall back to relay for bare aliases; only remote-format aliases go via relay)
    msg = f"hello-b1-from-a1-{int(time.time() * 1000)}"
    r = send_msg(a1, "b1@relay", msg)
    assert r.returncode == 0, f"a1→b1 send failed: {r.stderr}"
    print(f"[cross-host] a1 sent: {msg}")

    # Sync a1 (forward outbox) then sync b1 (poll inbound) — connector runs every 30s
    # so use sync_now to make it immediate
    r = sync_now(a1)
    assert r.returncode == 0, f"a1 sync failed: {r.stderr}"
    time.sleep(1)
    r = sync_now(b1)
    assert r.returncode == 0, f"b1 sync failed: {r.stderr}"
    time.sleep(1)

    # b1 polls and receives the message
    b1_inbox = poll_inbox(b1, "b1-session")
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

    # Sync with relay: register aliases so relay knows about them
    r = sync_now(b1)
    assert r.returncode == 0, f"b1 sync failed: {r.stderr}"
    r = sync_now(a1)
    assert r.returncode == 0, f"a1 sync failed: {r.stderr}"
    time.sleep(1)

    # b1 sends to a1 via relay (alias@relay format required — broker does not
    # fall back to relay for bare aliases; only remote-format aliases go via relay)
    msg = f"hello-a1-from-b1-{int(time.time() * 1000)}"
    r = send_msg(b1, "a1@relay", msg)
    assert r.returncode == 0, f"b1→a1 send failed: {r.stderr}"
    print(f"[cross-host] b1 sent: {msg}")

    # Sync b1 (forward outbox) then sync a1 (poll inbound) — connector runs every 30s
    # so use sync_now to make it immediate
    r = sync_now(b1)
    assert r.returncode == 0, f"b1 sync failed: {r.stderr}"
    time.sleep(1)
    r = sync_now(a1)
    assert r.returncode == 0, f"a1 sync failed: {r.stderr}"
    time.sleep(1)

    # a1 polls and receives the message
    a1_inbox = poll_inbox(a1, "a1-session")
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
    ghost = f"ghost-msg-{int(time.time())}"
    r = send_msg(a1, "nobody@nowhere-host-xyz", ghost)
    # Send may succeed (queued) or fail — we're checking dead-letter increment
    print(f"[dead-letter] send result: rc={r.returncode}, stderr={r.stderr[:100]}")

    # Sync to forward outbox to relay
    r = sync_now(a1)
    print(f"[dead-letter] a1 sync: {r.stdout.strip()}")
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

    # Pre-sync to register aliases with relay before sending.
    # Without this, sends fire before the relay knows about the aliases,
    # causing unknown_alias errors and outbox retries that hit rate limits.
    r = sync_now(a1)
    print(f"[bidir] a1 pre-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"a1 pre-sync failed: {r.stderr}"
    r = sync_now(b1)
    print(f"[bidir] b1 pre-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"b1 pre-sync failed: {r.stderr}"
    time.sleep(35)  # avoid relay rate limits between sync rounds

    msg_a2b = f"a1-to-b1-bidir-{int(time.time() * 1000)}"
    msg_b2a = f"b1-to-a1-bidir-{int(time.time() * 1000)}"

    # Send both directions
    r1 = send_msg(a1, "b1-bidir@relay", msg_a2b)
    r2 = send_msg(b1, "a1-bidir@relay", msg_b2a)
    assert r1.returncode == 0, f"a1→b1 failed: {r1.stderr}"
    assert r2.returncode == 0, f"b1→a1 failed: {r2.stderr}"
    print(f"[bidir] a1 sent: {msg_a2b}, b1 sent: {msg_b2a}")

    # Sync a1 (forward outbox) then b1 (poll inbound)
    r = sync_now(a1)
    print(f"[bidir] a1 fwd-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"a1 fwd-sync failed: {r.stderr}"
    time.sleep(1)
    r = sync_now(b1)
    print(f"[bidir] b1 poll-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"b1 poll-sync failed: {r.stderr}"
    time.sleep(1)

    # Sync b1 (forward outbox) then a1 (poll inbound)
    r = sync_now(b1)
    print(f"[bidir] b1 fwd-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"b1 fwd-sync failed: {r.stderr}"
    time.sleep(1)
    r = sync_now(a1)
    print(f"[bidir] a1 poll-sync: {r.stdout.strip()}")
    assert r.returncode == 0, f"a1 poll-sync failed: {r.stderr}"
    time.sleep(1)

    b1_inbox = poll_inbox(b1, "b1-bidir-session")
    a1_inbox = poll_inbox(a1, "a1-bidir-session")

    assert any(msg_a2b in m.get("content", "") for m in b1_inbox), \
        f"b1 should receive a1's message: {b1_inbox}"
    assert any(msg_b2a in m.get("content", "") for m in a1_inbox), \
        f"a1 should receive b1's message: {a1_inbox}"
    print("[bidir] both directions delivered ✅")
