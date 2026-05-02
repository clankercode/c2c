"""
#407 S4: peer-PASS lifecycle E2E — full sign → DM → verify roundtrip.

Test validates the complete peer-PASS lifecycle across two independent
broker volumes (agent-a1 on broker-a, agent-b1 on broker-b) with a relay
container in between.

Full flow:
  1. agent-a1 creates a test commit and pushes to bare repo (shared via volume)
  2. agent-a1 sends a relay DM to agent-b1: "review SHA: <sha>"
  3. agent-b1 polls relay inbox, receives the review request
  4. agent-b1 clones the bare repo, verifies commit exists (scripted review)
  5. agent-b1 signs a PASS verdict artifact for the SHA
  6. agent-b1 sends the artifact path back to agent-a1 via relay DM
  7. agent-a1 polls relay inbox, receives the verdict DM with artifact path
  8. agent-a1 copies the artifact from b1's container and verifies it

AC: full sign → DM → verify roundtrip across broker boundary.

Depends on: S1 (docker-compose.e2e-multi-agent.yml), S2 (cross-host relay),
            S5 (signing keys provisioned).
"""
import json
import os
import subprocess
import time

import pytest

from _signing_helpers import (
    init_identity,
    make_test_commit_in_container,
    artifact_path_in_container,
    docker_cp,
    sign_artifact_in_container,
    verify_peer_pass,
    _run_c2c_in,
    _run_shell_in,
)

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_B1 = "c2c-e2e-agent-b1"
RELAY_URL = "http://relay:7331"
ALIAS_A1 = "agent-a1"
ALIAS_B1 = "agent-b1"
BARE_REPO = "/tmp/s4-bare-repo.git"


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


def relay_dm_send(container: str, to_alias: str, message: str, from_alias: str) -> subprocess.CompletedProcess:
    """Send a relay DM from one alias to another."""
    return _run_c2c_in(container, [
        "relay", "dm", "send", to_alias, message,
        "--alias", from_alias,
        "--relay-url", RELAY_URL,
    ])


def relay_dm_poll(container: str, alias: str, timeout: int = 15) -> tuple[bool, str]:
    """Poll relay inbox until message received or timeout.

    Returns (True, message_content) on receipt, (False, last_output) on timeout.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = _run_c2c_in(container, [
            "relay", "dm", "poll",
            "--alias", alias,
            "--relay-url", RELAY_URL,
        ])
        if r.returncode == 0 and r.stdout.strip():
            return True, r.stdout.strip()
        time.sleep(1)
    return False, ""


def ensure_bare_repo(container: str) -> str:
    """Create a bare git repo at BARE_REPO inside container, return the repo path."""
    script = f"mkdir -p /tmp && git init --bare {BARE_REPO} 2>/dev/null || true && echo {BARE_REPO}"
    r = _run_shell_in(container, script)
    assert r.returncode == 0, f"bare repo init failed in {container}: {r.stderr}"
    return r.stdout.strip()


def clone_and_check_commit(container: str, sha: str) -> bool:
    """Clone bare repo and verify the commit exists."""
    script = f"""
        set -e
        rm -rf /tmp/s4-clone
        git clone {BARE_REPO} /tmp/s4-clone 2>/dev/null
        cd /tmp/s4-clone
        git cat-file -t {sha} >/dev/null 2>&1 && echo FOUND || echo MISSING
    """
    r = _run_shell_in(container, script)
    return "FOUND" in r.stdout


def create_test_commit_in_a1() -> str:
    """agent-a1 creates a test commit in bare repo and returns the SHA."""
    # a1 creates bare repo and makes a commit
    script = f"""
        set -e
        rm -rf {BARE_REPO} /tmp/s4-clone
        git init --bare {BARE_REPO}
        git clone {BARE_REPO} /tmp/s4-clone
        cd /tmp/s4-clone
        git config user.email "s4@c2c"
        git config user.name "S4 Test"
        echo "s4-$(date +%s)" > s4-fixture.txt
        git add s4-fixture.txt
        git commit -m "S4 test commit"
        git push {BARE_REPO} HEAD:refs/heads/s4-test
        git rev-parse HEAD
    """
    r = _run_shell_in(AGENT_A1, script)
    assert r.returncode == 0, f"create_test_commit failed in agent-a1: {r.stderr}"
    sha = r.stdout.strip()
    assert sha, "empty SHA"
    return sha


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_peer_pass_lifecycle_send_review_request(agent_a1, agent_b1):
    """S4 AC: agent-a1 sends a review request DM to agent-b1 via relay.

    Verifies:
      - agent-b1 receives the DM within 15s
      - DM body contains the SHA
    """
    # Init identities + register on relay
    for agent, alias in [(agent_a1, ALIAS_A1), (agent_b1, ALIAS_B1)]:
        r = init_identity(agent, alias, relay_url=RELAY_URL)
        if r.returncode not in (0, 2):
            print(f"[s4] init_identity warning for {alias}: {r.stderr}")

    # Ensure bare repo exists in a1
    ensure_bare_repo(agent_a1)

    # a1 creates test commit
    sha = create_test_commit_in_a1()
    print(f"[s4] test commit SHA: {sha}")

    # a1 sends review request via relay DM
    review_msg = f"review SHA: {sha}"
    r = relay_dm_send(agent_a1, ALIAS_B1, review_msg, ALIAS_A1)
    assert r.returncode == 0, f"relay dm send failed: {r.stderr}"
    print(f"[s4] sent review request: {review_msg}")

    # b1 polls for the DM
    received, content = relay_dm_poll(agent_b1, ALIAS_B1, timeout=15)
    assert received, f"agent-b1 did not receive DM within 15s. Last output: {content}"
    assert sha in content, f"SHA {sha} not found in DM body: {content}"
    print(f"[s4] agent-b1 received review request: {content}")


def test_peer_pass_lifecycle_review_and_verdict(agent_a1, agent_b1):
    """S4 AC: agent-b1 reviews the commit and sends PASS verdict back to agent-a1.

    Full flow:
      1. b1 polls for review request DM (already sent in prior test — topology is shared)
      2. b1 clones bare repo, verifies commit exists
      3. b1 signs PASS verdict artifact
      4. b1 sends artifact path back to a1 via relay DM
      5. a1 polls for verdict DM
      6. a1 copies artifact from b1's container and verifies signature
    """
    # Init identities + register on relay
    for agent, alias in [(agent_a1, ALIAS_A1), (agent_b1, ALIAS_B1)]:
        r = init_identity(agent, alias, relay_url=RELAY_URL)
        if r.returncode not in (0, 2):
            print(f"[s4] init_identity warning for {alias}: {r.stderr}")

    # Ensure bare repo exists in b1 too
    ensure_bare_repo(agent_b1)

    # b1 polls for the review request DM (from prior test in same topology)
    received, content = relay_dm_poll(agent_b1, ALIAS_B1, timeout=5)
    if not received or "review SHA:" not in content:
        pytest.skip("Review request DM not found in b1 inbox — test_peer_pass_lifecycle_send_review_request must run first in same topology")

    # Extract SHA from DM body
    import re
    m = re.search(r"review SHA: ([a-f0-9]+)", content)
    assert m, f"Could not extract SHA from DM body: {content}"
    sha = m.group(1)
    print(f"[s4] b1 extracted SHA: {sha}")

    # b1 clones bare repo and verifies commit exists (scripted review)
    commit_found = clone_and_check_commit(agent_b1, sha)
    assert commit_found, f"Commit {sha} not found in bare repo on b1"
    print(f"[s4] b1 verified commit {sha} exists in bare repo")

    # b1 signs PASS verdict artifact
    artifact_b1 = sign_artifact_in_container(
        agent_b1,
        sha=sha,
        reviewer_alias=ALIAS_B1,
        verdict="PASS",
        criteria="s4-e2e,commit-exists,scripted-review",
        notes="S4 peer-PASS lifecycle E2E test",
        allow_self=True,
        repo_path="/tmp/s4-clone",
    )
    print(f"[s4] b1 signed PASS artifact: {artifact_b1}")

    # b1 sends artifact path back to a1 via relay DM
    verdict_msg = f"PASS verdict: {artifact_b1}"
    r = relay_dm_send(agent_b1, ALIAS_A1, verdict_msg, ALIAS_B1)
    assert r.returncode == 0, f"relay dm send verdict failed: {r.stderr}"
    print(f"[s4] b1 sent PASS verdict DM: {verdict_msg}")

    # a1 polls for verdict DM
    received, verdict_content = relay_dm_poll(agent_a1, ALIAS_A1, timeout=15)
    assert received, f"agent-a1 did not receive verdict DM within 15s. Last output: {verdict_content}"
    assert "PASS verdict" in verdict_content, f"PASS verdict not found in DM: {verdict_content}"
    print(f"[s4] a1 received verdict DM: {verdict_content}")

    # Extract artifact path from verdict DM
    m2 = re.search(r"PASS verdict: (.+)", verdict_content)
    assert m2, f"Could not extract artifact path from verdict DM: {verdict_content}"
    artifact_on_b1 = m2.group(1).strip()
    print(f"[s4] a1 extracted artifact path on b1: {artifact_on_b1}")

    # a1 copies artifact from b1's container to a1's container via docker cp
    artifact_a1_path = artifact_path_in_container(AGENT_A1, sha, ALIAS_B1)
    r_cp = docker_cp(AGENT_B1, artifact_on_b1, AGENT_A1, artifact_a1_path)
    assert r_cp.returncode == 0, f"docker cp artifact failed: {r_cp.stderr}"
    print(f"[s4] a1 copied artifact to: {artifact_a1_path}")

    # a1 verifies the artifact signature
    ok, out = verify_peer_pass(AGENT_A1, artifact_a1_path)
    assert ok, f"verify_peer_pass failed: {out}"
    assert "VERIFIED" in out.upper(), f"Expected 'VERIFIED' in output, got: {out}"
    print(f"[s4] a1 verified PASS artifact: {out}")
    print("[s4] PASS — full peer-PASS lifecycle validated across broker boundary")


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
