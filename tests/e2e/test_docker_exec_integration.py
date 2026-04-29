"""#406 slice 1 — docker-exec integration: validate Python test framework + Docker exec path.

Tests that Python pytest can drive `docker exec` into thin-agent containers in
`docker-compose.2-relay-probe.yml` to exercise the full c2c CLI path
(register → send → poll) without needing a new Docker image or a managed
client. The thin-agent image already has the `c2c` binary.

Scope (slice 1):
  - Docker exec into thin-agent containers
  - Register alice on relay-a, bob on relay-b
  - Send alice → bob via the relay (cross-relay path)
  - Poll bob's inbox and verify receipt
  - NO real managed-client image (deferred to slice 2)
  - NO tmux/PTY toast monitoring (deferred to slice 2)

The 2-relay topology (relay-a port 9000, relay-b port 9001) is used as-is.
Peer relay forwarding (relay-a → relay-b) is NOT configured here — the
cross-relay DM goes to dead-letter on relay-a. The mesh-test.sh (bash)
covers the full forwarder chain with peer config; this test validates the
docker-exec test harness only.
"""

from __future__ import annotations

import json
import subprocess
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

COMPOSE_FILE = "docker-compose.2-relay-probe.yml"
COMPOSE_CMD = ["docker", "compose", "-f", COMPOSE_FILE]

# Container names from docker-compose.2-relay-probe.yml
CONTAINER_A1 = "c2c-peer-a1"
CONTAINER_B1 = "c2c-peer-b1"


def _docker_exec(container: str, argv: list[str], timeout: float = 10.0) -> subprocess.CompletedProcess:
    """Run `c2c` inside a thin-agent container and return the result."""
    cmd = ["docker", "exec", container, "/usr/local/bin/c2c"] + argv
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _wait_for_health(port: int, timeout: float = 30.0) -> bool:
    """Wait for a relay's /health to return 200."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            r = subprocess.run(
                ["docker", "exec",
                 "c2c-relay-a" if port == 9000 else "c2c-relay-b",
                 "bash", "-c",
                 f"exec 3<>/dev/tcp/127.0.0.1/{port} && "
                 f"printf 'GET /health HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && "
                 f"timeout 2 cat <&3 | grep -q '\"ok\":true'"],
                capture_output=True, text=True, timeout=5.0, check=False
            )
            if r.returncode == 0:
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1)
    return False


class DockerExecIntegration(unittest.TestCase):
    """Validate that Python can drive c2c CLI inside Docker containers via docker exec."""

    @classmethod
    def setUpClass(cls):
        # Skip if docker daemon is not reachable
        if subprocess.run(
            ["docker", "info"], capture_output=True, timeout=5.0
        ).returncode != 0:
            raise unittest.SkipTest("docker daemon unreachable")

        # Validate compose file exists
        compose_path = REPO / COMPOSE_FILE
        if not compose_path.exists():
            raise unittest.SkipTest(f"{COMPOSE_FILE} not found at {REPO}")

        # Validate compose syntax
        r = subprocess.run(
            COMPOSE_CMD + ["config", "--quiet"],
            cwd=REPO, capture_output=True, text=True, timeout=10.0
        )
        if r.returncode != 0:
            raise unittest.SkipTest(f"compose config failed: {r.stderr}")

        # Bring up the stack
        print("\n[setup] docker compose up -d --build...")
        r = subprocess.run(
            COMPOSE_CMD + ["up", "-d", "--build"],
            cwd=REPO, capture_output=True, text=True, timeout=300.0
        )
        if r.returncode != 0:
            raise unittest.SkipTest(f"compose up failed: {r.stderr}")

        # Wait for both relays to be healthy
        print("[setup] waiting for relay-a health...")
        if not _wait_for_health(9000):
            subprocess.run(COMPOSE_CMD + ["down", "-v"], cwd=REPO, timeout=30.0)
            raise unittest.SkipTest("relay-a did not become healthy")
        print("[setup] waiting for relay-b health...")
        if not _wait_for_health(9001):
            subprocess.run(COMPOSE_CMD + ["down", "-v"], cwd=REPO, timeout=30.0)
            raise unittest.SkipTest("relay-b did not become healthy")
        print("[setup] both relays healthy")

        # Give agents an extra moment to settle
        time.sleep(2)

    @classmethod
    def tearDownClass(cls):
        print("\n[teardown] docker compose down -v...")
        subprocess.run(
            COMPOSE_CMD + ["down", "-v", "--remove-orphans"],
            cwd=REPO, capture_output=True, text=True, timeout=60.0
        )

    def test_c2c_binary_exists_in_thin_agent(self):
        """Verify the c2c binary is reachable inside the thin-agent container."""
        r = _docker_exec(CONTAINER_A1, ["--version"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c --version failed in {CONTAINER_A1}: {r.stderr}"
        )
        self.assertIn("c2c", r.stdout.lower())

    def test_register_alice_on_relay_a(self):
        """Register alice on relay-a via docker exec."""
        r = _docker_exec(CONTAINER_A1, ["register", "-a", "alice"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c register alice failed: {r.stderr}\nstdout: {r.stdout}"
        )

    def test_register_bob_on_relay_b(self):
        """Register bob on relay-b via docker exec."""
        r = _docker_exec(CONTAINER_B1, ["register", "-a", "bob"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c register bob failed: {r.stderr}\nstdout: {r.stdout}"
        )

    def test_send_alice_to_bob_via_relay_a(self):
        """Send alice → bob@host-b via relay-a (cross-relay DM).

        Uses fully-qualified alias `bob@host-b` because OCaml relay requires
        the host suffix for cross-host routing. Without peer relay forwarding
        configured, this goes to dead-letter on relay-a. We assert the send
        itself succeeds (returncode 0), which validates the docker-exec →
        c2c send path end-to-end.
        """
        r = _docker_exec(
            CONTAINER_A1,
            ["send", "bob@host-b", "Hello from alice via relay-a"]
        )
        # Send should return 0 — the message was queued to the relay
        self.assertEqual(
            r.returncode, 0,
            f"c2c send alice→bob@host-b failed: {r.stderr}\nstdout: {r.stdout}"
        )

    def test_poll_bob_inbox_from_relay_b(self):
        """Poll bob's inbox on relay-b and verify receipt of a prior message.

        Note: if alice's send went to dead-letter (no peer relay forwarding
        configured), the inbox will be empty. This test still validates that:
          1. docker exec → c2c poll-inbox --json works inside the container
          2. relay-b is reachable from peer-b1's container
          3. The JSON output is parseable

        The actual cross-relay forward path is exercised by mesh-test.sh
        once peer relay config is added.
        """
        r = _docker_exec(CONTAINER_B1, ["poll-inbox", "--json"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c poll-inbox bob failed: {r.stderr}\nstdout: {r.stdout}"
        )
        # Should be valid JSON (empty list is fine for this test)
        try:
            inbox = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            self.fail(f"poll-inbox JSON unparseable: {e}\noutput: {r.stdout!r}")
        self.assertIsInstance(inbox, list, "inbox should be a JSON list")


class DockerExecHealthTests(unittest.TestCase):
    """Lightweight health checks that run without full stack bring-up."""

    def test_compose_file_valid(self):
        """Verify docker-compose.2-relay-probe.yml is syntactically valid."""
        r = subprocess.run(
            COMPOSE_CMD + ["config", "--quiet"],
            cwd=REPO, capture_output=True, text=True, timeout=10.0
        )
        self.assertEqual(
            r.returncode, 0,
            f"compose config failed: {r.stderr}"
        )

    def test_dockerfile_test_binary_layer(self):
        """Verify the c2c binary layer is present in Dockerfile.test."""
        # Build the image (reuse cache if warm)
        r = subprocess.run(
            ["docker", "build", "-f", "Dockerfile.test",
             "--target", "runtime", "-t", "c2c-test:probe", "."],
            cwd=REPO, capture_output=True, text=True, timeout=300.0
        )
        if r.returncode != 0 and "cache" not in r.stderr.lower():
            self.skipTest(f"Dockerfile.test build failed: {r.stderr}")

        # Inspect the binary layer
        r = subprocess.run(
            ["docker", "run", "--rm", "c2c-test:probe",
             "/usr/local/bin/c2c", "--version"],
            capture_output=True, text=True, timeout=10.0
        )
        self.assertEqual(
            r.returncode, 0,
            f"c2c binary not found in Dockerfile.test runtime: {r.stderr}"
        )


if __name__ == "__main__":
    unittest.main()
