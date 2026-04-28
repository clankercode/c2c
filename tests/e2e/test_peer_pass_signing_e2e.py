"""
#407 S5: signing keys provisioning E2E — cross-container peer-PASS sign + verify.

Test validates that per-alias ed25519 keys are provisioned inside containers,
and that signed peer-PASS artifacts can be verified across the two-broker
topology (agent-a1 on broker-a, agent-b1 on broker-b, relay in between).

Boot topology → agent-a1 initializes identity + makes a test commit →
signs a peer-PASS verdict → copies artifact to agent-b1's broker volume →
agent-b1 verifies. Full roundtrip validates S5 AC.

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline, already running)
"""
import json
import os
import subprocess
import time
import pytest

COMPOSE_FILE = "-f docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", "docker-compose.e2e-multi-agent.yml"]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_B1 = "c2c-e2e-agent-b1"
RELAY_URL = "http://relay:7331"


def docker_available():
    if not os.path.exists("/var/run/docker.sock"):
        return False
    probe = subprocess.run(
        ["docker", "compose", "-f", "docker-compose.e2e-multi-agent.yml", "version"],
        capture_output=True, text=True, timeout=10,
    )
    return probe.returncode == 0


pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="e2e tests require docker CLI + host docker socket",
)


def compose_up():
    subprocess.run(
        ["docker", "compose", "-f", "docker-compose.e2e-multi-agent.yml",
         "up", "-d", "--build", "--wait", "--wait-timeout", "120"],
        check=True, timeout=180,
    )
    for _ in range(30):
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", "c2c-e2e-relay"],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip() == "healthy":
            return
        time.sleep(2)
    raise RuntimeError("Relay did not become healthy within 60s")


def compose_down():
    subprocess.run(
        ["docker", "compose", "-f", "docker-compose.e2e-multi-agent.yml",
         "down", "-v", "--remove-orphans"],
        capture_output=True, timeout=60,
    )


def docker_exec(service, command, check=True, timeout=60):
    r = subprocess.run(
        ["docker", "exec", "-e", "C2C_CLI_FORCE=1", service] + command,
        capture_output=True, text=True, timeout=timeout,
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"docker exec in {service} failed: {r.stderr}\nstdout: {r.stdout}")
    return r.stdout.strip(), r.returncode


def docker_exec_raw(service, command, timeout=60):
    """Return (stdout, stderr, rc) without raising on non-zero."""
    r = subprocess.run(
        ["docker", "exec", "-e", "C2C_CLI_FORCE=1", service] + command,
        capture_output=True, text=True, timeout=timeout,
    )
    return r.stdout.strip(), r.stderr.strip(), r.returncode


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_identity_show_returns_valid_ed25519_key(agent_a1):
    """S5 AC: `c2c relay identity show --json` returns alg=ed25519 + fingerprint."""
    out, _ = docker_exec(agent_a1, ["c2c", "relay", "identity", "show", "--json"])
    data = json.loads(out)
    assert data.get("alg") == "ed25519", f"Expected ed25519, got {data}"
    assert "fingerprint" in data, f"Expected fingerprint field, got {data}"
    assert data.get("version") == 1, f"Expected version 1, got {data}"


def test_peer_pass_sign_and_verify_cross_broker(agent_a1, agent_b1):
    """S5 AC: agent-a1 signs a peer-PASS verdict; agent-b1 verifies it across the relay."""
    # Step 1: Register both agents on the relay so cross-broker routing works
    for agent, alias in [(agent_a1, "agent-a1"), (agent_b1, "agent-b1")]:
        docker_exec(agent, ["c2c", "relay", "identity", "init"])
        docker_exec(agent, [
            "c2c", "relay", "register",
            "--alias", alias, "--relay-url", RELAY_URL,
        ])

    # Step 2: agent-a1 creates a bare git repo on its broker volume and makes a test commit
    test_sha, _ = docker_exec(agent_a1, [
        "bash", "-c", """
        set -e
        git init --bare /var/lib/c2c/s5-shared.git
        rm -rf /tmp/s5-clone
        git clone /var/lib/c2c/s5-shared.git /tmp/s5-clone
        cd /tmp/s5-clone
        git config user.email "s5@c2c"
        git config user.name "S5 Test"
        echo "s5-$(date +%s)" > s5-fixture.txt
        git add s5-fixture.txt
        git commit -m "S5 fixture commit"
        git push /var/lib/c2c/s5-shared.git HEAD:refs/heads/s5-test
        git rev-parse HEAD
        """
    ])

    # Step 3: agent-a1 clones the shared bare repo, checks out the commit, signs peer-PASS
    sign_out, _ = docker_exec(agent_a1, [
        "bash", "-c", f"""
        set -e
        rm -rf /tmp/s5-clone
        git clone /var/lib/c2c/s5-shared.git /tmp/s5-clone
        cd /tmp/s5-clone
        git fetch /var/lib/c2c/s5-shared.git s5-test
        git checkout FETCH_HEAD
        # Sign peer-PASS verdict (--send to no-one just signs, we capture artifact path)
        # Actually use `peer-pass sign` directly, artifact lands in ~/.c2c/peer-pass/
        c2c relay identity init
        c2c peer-pass sign {test_sha} \
            --verdict PASS \
            --criteria s5-e2e \
            --notes "S5 cross-container signing test" \
            --json
        # Find the artifact file
        ARTIFACT=$(ls -t ~/.c2c/peer-pass/*{test_sha}*.json 2>/dev/null | head -1)
        basename "$ARTIFACT"
        """
    ])

    artifact_basename = sign_out.strip().split("\n")[-1]
    print(f"[s5] artifact basename: {artifact_basename}")

    # Step 4: Copy artifact to shared volume accessible from agent-b1
    docker_exec(agent_a1, [
        "bash", "-c", f"""
        set -e
        cp ~/.c2c/peer-pass/{artifact_basename} /var/lib/c2c/s5-artifact.json
        echo "copied artifact to /var/lib/c2c/s5-artifact.json"
        """
    ])

    # Step 5: agent-b1 clones the shared bare repo, checks out the commit, verifies artifact
    verify_out, verify_err, verify_rc = docker_exec_raw(agent_b1, [
        "bash", "-c", f"""
        set -e
        rm -rf /tmp/s5-clone
        git clone /var/lib/c2c/s5-shared.git /tmp/s5-clone
        cd /tmp/s5-clone
        git fetch /var/lib/c2c/s5-shared.git s5-test
        git checkout FETCH_HEAD
        c2c relay identity init
        c2c peer-pass verify /var/lib/c2c/s5-artifact.json
        """
    ], check=False)

    print(f"[s5] verify stdout: {verify_out}")
    print(f"[s5] verify stderr: {verify_err}")
    print(f"[s5] verify rc: {verify_rc}")

    # verify returns rc=0 + "VERIFIED" on success
    assert verify_rc == 0, f"verify failed with rc={verify_rc}: {verify_err}"
    assert "VERIFIED" in verify_out.upper(), \
        f"Expected 'VERIFIED' in verify output, got: {verify_out}"


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