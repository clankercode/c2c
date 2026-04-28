"""
#407 S5: signing keys provisioning E2E — cross-container peer-PASS sign + verify.

Test validates that per-alias Ed25519 keys are provisioned inside containers,
and that signed peer-PASS artifacts can be verified across the two-broker
topology (agent-a1 on broker-a, agent-b1 on broker-b, relay in between).

Boot topology → agent-a1 initializes identity + makes a test commit →
signs a peer-PASS verdict → copies artifact to agent-b1's container →
agent-b1 verifies. Full roundtrip validates S5 AC.

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline, already running)
"""
import json
import os
import subprocess
import time

import pytest

# Import the fixture helpers (in same directory)
from _signing_helpers import (
    init_identity,
    get_identity_show,
    get_pubkey,
    get_fingerprint,
    make_test_commit_in_container,
    sign_artifact_in_container,
    artifact_copy_across_broker,
    verify_peer_pass,
    artifact_path_in_container,
)

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_B1 = "c2c-e2e-agent-b1"
RELAY_URL = "http://relay:7331"
ALIAS_A1 = "agent-a1"
ALIAS_B1 = "agent-b1"


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
    # Small settle time for agent containers
    time.sleep(2)


def compose_down():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "down", "-v", "--remove-orphans"],
        capture_output=True, timeout=60,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_identity_show_returns_valid_ed25519(agent_a1):
    """S5 AC part 1: `c2c relay identity show --json` returns alg=ed25519 + fingerprint."""
    data = get_identity_show(agent_a1)
    assert data.get("alg") == "ed25519", "Expected alg=ed25519, got: {}".format(data)
    assert "fingerprint" in data, "Expected fingerprint field, got: {}".format(data)
    assert data.get("version") == 1, "Expected version 1, got: {}".format(data)


def test_fingerprint_is_sha256_format(agent_a1):
    """Fingerprint should be in SHA256:... format."""
    fp = get_fingerprint(agent_a1)
    assert fp.startswith("SHA256:"), "Fingerprint should start with SHA256:, got: {}".format(fp)


def test_pubkey_is_returned(agent_a1):
    """Public key should be a non-empty base64url string."""
    pk = get_pubkey(agent_a1)
    assert pk, "Public key should be non-empty"
    assert len(pk) > 10, "Public key seems too short: {}".format(pk)


def test_peer_pass_sign_and_verify_cross_broker(agent_a1, agent_b1):
    """S5 AC: agent-a1 signs a peer-PASS verdict; agent-b1 verifies it across the relay.

    Full flow:
      1. Both agents register on relay (for cross-broker routing)
      2. agent-a1 creates a test git commit in a local bare repo
      3. agent-a1 initializes its identity and signs a peer-PASS artifact for that SHA
      4. Artifact is copied to agent-b1's container via docker cp
      5. agent-b1 verifies the artifact — signature must be valid
    """
    # Step 1: Register both agents on the relay
    for agent, alias in [(agent_a1, ALIAS_A1), (agent_b1, ALIAS_B1)]:
        init_identity(agent, alias)
        r = subprocess.run(
            ["docker", "exec", "-e", "C2C_CLI_FORCE=1", agent,
             "c2c", "relay", "register", "--alias", alias, "--relay-url", RELAY_URL],
            capture_output=True, text=True, timeout=30,
        )
        # Registration may succeed or fail if already registered — that's fine for the test

    # Step 2: agent-a1 creates a test git commit
    test_sha = make_test_commit_in_container(
        agent_a1,
        repo_path="/tmp/s5-test-repo",
        file_name="s5-fixture.txt",
        commit_msg="S5 cross-container signing test commit",
    )
    assert test_sha, "make_test_commit_in_container returned empty SHA"
    print("[s5] test commit SHA: {}".format(test_sha))

    # Step 3: agent-a1 initializes identity and signs the peer-PASS artifact
    init_identity(agent_a1, ALIAS_A1, force=True)
    artifact_a1 = sign_artifact_in_container(
        agent_a1,
        sha=test_sha,
        reviewer_alias=ALIAS_A1,
        verdict="PASS",
        criteria="s5-e2e,identity-provisioned",
        notes="S5 cross-container signing test",
        allow_self=True,  # Test context: signer IS the reviewer alias
    )
    print("[s5] artifact path in agent-a1: {}".format(artifact_a1))

    # Step 4: Copy artifact to agent-b1's container via docker cp
    # (docker cp goes through the host filesystem, so it works across
    # independent broker volumes broker-a and broker-b)
    dst_path, err = artifact_copy_across_broker(
        src_container=agent_a1,
        dst_container=agent_b1,
        sha=test_sha,
        reviewer_alias=ALIAS_A1,
    )
    assert not err, "artifact_copy_across_broker failed: {}".format(err)
    print("[s5] artifact copied to agent-b1 at: {}".format(dst_path))

    # Step 5: agent-b1 initializes its identity and verifies the artifact
    init_identity(agent_b1, ALIAS_B1, force=True)
    ok, out = verify_peer_pass(agent_b1, dst_path)
    assert ok, "verify_peer_pass failed: {}".format(out)
    assert "VERIFIED" in out.upper(), "Expected 'VERIFIED' in output, got: {}".format(out)
    print("[s5] agent-b1 verify output: {}".format(out))
    print("[s5] PASS — artifact signed by agent-a1, verified by agent-b1 across broker boundary")


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
