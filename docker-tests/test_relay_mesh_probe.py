"""
#330 V3: 2-relay mesh probe — negative tests (pre-forwarder).

Tests validate the cross-host dead-letter contract BEFORE the forwarder
transport (S1) is implemented. Once forwarder lands, assertions flip from
"expect dead_letter" to "expect delivered" (coordinate a re-PASS at that point).

Three scenarios (validation plan §3):
  1. Cross-host DM dead-letters: peer-a1 → peer-b2@host-b via relay-a
     → dead_letter with cross_host_not_implemented.
  2. Peer-relay unreachable: relay-b is stopped. peer-a1 → peer-b2@host-b.
     → dead_letter on relay-a (forwarder POST fails).
  3. Unknown host: peer-a1 → peer-nonexistent@host-nonexistent.
     → dead_letter on relay-a.

Topology:
  peer-a1, peer-a2 on relay-a (host-a:9000)
  peer-b1, peer-b2 on relay-b (host-b:9001)
  Cross-host DMs dead-letter at relay-a (no forwarder yet).

RAM budget: relay×2 @ 80MB + peers×4 @ 40MB + pytest @ 80MB
          + headroom = ≤ 600 MB. Run only when swarm is quiet.
"""
import json
import os
import subprocess
import time

import pytest


COMPOSE_FILE = "docker-compose.2-relay-probe.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]

RELAY_A = "c2c-relay-a"
RELAY_B = "c2c-relay-b"
PEER_A1 = "c2c-peer-a1"
PEER_A2 = "c2c-peer-a2"
PEER_B1 = "c2c-peer-b1"
PEER_B2 = "c2c-peer-b2"

RELAY_A_URL = "http://relay-a:9000"
RELAY_B_URL = "http://relay-b:9001"
HOST_A = "host-a"
HOST_B = "host-b"


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
    reason="2-relay probe requires docker CLI + host docker socket",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_c2c_in(
    container: str,
    argv: list[str],
    timeout: int = 30,
) -> subprocess.CompletedProcess:
    """Run c2c CLI inside a container (runs as root in this compose)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [container, "/usr/local/bin/c2c"] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _relay_dead_letter_count(relay_container: str, persist_dir: str) -> int:
    """Return count of dead_letter rows in relay's SQLite DB."""
    db_path = f"{persist_dir}/c2c_relay.db"
    r = subprocess.run(
        ["docker", "exec", relay_container,
         "sqlite3", db_path,
         "SELECT COUNT(*) FROM dead_letter"],
        capture_output=True, text=True, timeout=10,
    )
    if r.returncode != 0:
        return 0  # DB or table not yet created
    return int(r.stdout.strip())


def _read_last_dead_letter(relay_container: str, persist_dir: str) -> dict:
    """Read the most recent dead_letter entry from relay's SQLite DB."""
    db_path = f"{persist_dir}/c2c_relay.db"
    r = subprocess.run(
        ["docker", "exec", relay_container,
         "sqlite3", "-json", db_path,
         "SELECT message_id, from_alias, to_alias, content, ts, reason "
         "FROM dead_letter ORDER BY ts DESC LIMIT 1"],
        capture_output=True, text=True, timeout=10,
    )
    assert r.returncode == 0, f"failed to read last dead_letter: {r.stderr}"
    rows = json.loads(r.stdout)
    if not rows:
        return {}
    return rows[0]


def _init_peer(peer: str, alias: str, relay_url: str) -> subprocess.CompletedProcess:
    """Initialize identity + register peer on its relay."""
    # Create identity (stored at ~/.config/c2c/identity.json)
    r0 = _run_c2c_in(peer, ["relay", "identity", "init", "--force"])
    if r0.returncode != 0:
        return r0
    # Register on relay for cross-host routing
    r1 = _run_c2c_in(peer, [
        "relay", "register",
        "--alias", alias,
        "--relay-url", relay_url,
    ])
    return r1


def _send_dm_via_relay(
    from_peer: str,
    from_alias: str,
    to_alias_host: str,
    relay_url: str,
    body: str = "test message v3",
) -> subprocess.CompletedProcess:
    """Send a DM to alias@host via specified relay URL.

    Example: _send_dm_via_relay(PEER_A1, "peer-a1", "peer-b2@host-b", RELAY_A_URL)
    """
    return _run_c2c_in(from_peer, [
        "relay", "dm", "send", to_alias_host,
        "--relay-url", relay_url,
        "--body", body,
    ])


def _wait_relay_healthy(container: str, port: int, timeout: int = 90) -> None:
    """Wait for a relay to become healthy."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", container],
            capture_output=True, text=True, timeout=5,
        )
        if r.stdout.strip() == "healthy":
            return
        time.sleep(2)
    raise RuntimeError(f"{container} did not become healthy within {timeout}s")


def compose_up():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "up", "-d", "--build", "--wait", "--wait-timeout", "120"],
        check=True, timeout=300,
    )
    _wait_relay_healthy(RELAY_A, 9000)
    _wait_relay_healthy(RELAY_B, 9001)
    time.sleep(2)


def compose_down():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "down", "-v", "--remove-orphans"],
        capture_output=True, timeout=60,
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def topology():
    compose_up()
    yield
    compose_down()


@pytest.fixture
def peer_a1_provisioned(topology):
    """Provision peer-a1 on relay-a."""
    _init_peer(PEER_A1, "peer-a1", RELAY_A_URL)
    return PEER_A1


@pytest.fixture
def peer_b2_provisioned(topology):
    """Provision peer-b2 on relay-b (used for cross-host sends)."""
    _init_peer(PEER_B2, "peer-b2", RELAY_B_URL)
    return PEER_B2


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_cross_host_dead_letter_peer_unknown_host(peer_a1_provisioned, peer_b2_provisioned):
    """Scenario 1: peer-a1 → peer-b2@host-b via relay-a → dead_letter.

    Pre-forwarder: relay-a has no peer_relay for host-b, so it dead-letters
    with cross_host_not_implemented. This test validates the contract that
    will flip to "delivered" once the forwarder (S1) lands.
    """
    persist_dir_a = "/var/lib/c2c/relay-a-state"
    before = _relay_dead_letter_count(RELAY_A, persist_dir_a)

    # peer-a1 sends to peer-b2@host-b — relay-a does not know host-b → dead-letter
    r = _send_dm_via_relay(
        from_peer=peer_a1_provisioned,
        from_alias="peer-a1",
        to_alias_host="peer-b2@host-b",
        relay_url=RELAY_A_URL,
    )

    # Send itself may succeed at the wire level (relay accepts the POST)
    # or return an error — both are fine. The observable contract is the
    # dead_letter row in relay-a's SQLite DB.
    time.sleep(2)

    after = _relay_dead_letter_count(RELAY_A, persist_dir_a)

    assert after > before, (
        f"Expected dead_letter count to increase on {RELAY_A} after "
        f"cross-host send; before={before}, after={after}, send_rc={r.returncode}, "
        f"send_stdout={r.stdout[:200]}"
    )

    # Read the most recent dead_letter and verify reason
    dl = _read_last_dead_letter(RELAY_A, persist_dir_a)
    reason = dl.get("reason", "")
    assert "cross_host_not_implemented" in reason, (
        f"Expected cross_host_not_implemented in dead_letter reason, got: {dl}"
    )


def test_cross_host_dead_letter_relay_b_unreachable(peer_a1_provisioned, peer_b2_provisioned):
    """Scenario 3: relay-b is stopped. peer-a1 → peer-b2@host-b → dead_letter on relay-a.

    When relay-b is down, relay-a's forwarder POST fails (no listener on 9001).
    Pre-forwarder: relay-a dead-letters immediately (no forwarder transport).
    Post-forwarder: relay-a would retry then dead-letter. Either way, no delivery.
    """
    persist_dir_a = "/var/lib/c2c/relay-a-state"
    # Stop relay-b to simulate partition
    subprocess.run(["docker", "stop", RELAY_B], check=True, timeout=30)
    try:
        before = _relay_dead_letter_count(RELAY_A, persist_dir_a)

        r = _send_dm_via_relay(
            from_peer=peer_a1_provisioned,
            from_alias="peer-a1",
            to_alias_host="peer-b2@host-b",
            relay_url=RELAY_A_URL,
        )

        time.sleep(2)

        after = _relay_dead_letter_count(RELAY_A, persist_dir_a)

        assert after > before, (
            f"Expected dead_letter count to increase on {RELAY_A} after relay-b "
            f"went down; before={before}, after={after}, send_rc={r.returncode}, "
            f"send_stdout={r.stdout[:200]}"
        )
    finally:
        # Restart relay-b so subsequent tests can run
        subprocess.run(["docker", "start", RELAY_B], check=True, timeout=30)
        _wait_relay_healthy(RELAY_B, 9001)
        time.sleep(2)


def test_unknown_host_dead_letter(peer_a1_provisioned):
    """Scenario 4 (validation plan §3): peer-a1 → nonexistent@unknown-host → dead_letter.

    Unknown host not in peer_relays table → dead-letter on relay-a.
    """
    persist_dir_a = "/var/lib/c2c/relay-a-state"
    before = _relay_dead_letter_count(RELAY_A, persist_dir_a)

    r = _send_dm_via_relay(
        from_peer=peer_a1_provisioned,
        from_alias="peer-a1",
        to_alias_host="nonexistent@unknown-host",
        relay_url=RELAY_A_URL,
    )

    time.sleep(2)

    after = _relay_dead_letter_count(RELAY_A, persist_dir_a)

    assert after > before, (
        f"Expected dead_letter count to increase on {RELAY_A} for unknown host; "
        f"before={before}, after={after}, send_rc={r.returncode}, "
        f"send_stdout={r.stdout[:200]}"
    )
