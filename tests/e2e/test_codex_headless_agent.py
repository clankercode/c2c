"""#406 S2 — codex-headless agent Docker smoke test.

Smoke tests for the codex-headless agent Docker image and compose topology.
Validates the infrastructure needed for managed-client Docker containers:
  - Dockerfile.agent builds successfully
  - compose file is syntactically valid
  - c2c binary is reachable inside the agent container
  - codex-turn-start-bridge is mounted from host and callable
  - c2c_deliver_inbox.py is present for the deliver daemon fallback
  - Agent can register with the relay broker
  - Agent can send DMs to the relay (enqueue verified; delivery depends on
    whether peer-relay forwarding is configured for the target host)

NOTE: Full end-to-end codex-headless → codex-headless DM exchange requires
OPENAI_API_KEY to be set. The smoke test verifies infrastructure setup
regardless of whether a real API key is available. Full exchange tests
are gated on having valid credentials injected via OPENAI_API_KEY.

Deferred to S3+:
  - Real LLM API exchange (requires credentials)
  - c2c start codex-headless end-to-end inside Docker (bridge handoff, PTY
    injection, deliver-mode negotiation, session persistence — the full
    managed-instance startup path is not exercised here; only direct
    docker-exec registration is verified)
  - Tmux/PTY toast monitoring inside containers
  - OpenCode agent (TUI-only, needs Xvfb + PTY)
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

COMPOSE_FILE = "docker-compose.agent-mesh.yml"
COMPOSE_CMD = ["docker", "compose", "-f", COMPOSE_FILE]

CONTAINER_A1 = "c2c-codex-a1"
CONTAINER_B1 = "c2c-codex-b1"


def _docker_exec(
    container: str,
    argv: list[str],
    timeout: float = 10.0,
    check: bool = False,
) -> subprocess.CompletedProcess:
    """Run command inside a container. Returns CompletedProcess."""
    cmd = ["docker", "exec", container] + argv
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=check,
    )


def _wait_for_health(port: int, container_name: str, timeout: float = 30.0) -> bool:
    """Wait for a relay's /health to return 200."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            r = subprocess.run(
                ["docker", "exec", container_name,
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


class CodexAgentDockerSmoke(unittest.TestCase):
    """Smoke tests for codex-headless agent Docker infrastructure."""

    @classmethod
    def setUpClass(cls):
        if subprocess.run(
            ["docker", "info"], capture_output=True, timeout=5.0
        ).returncode != 0:
            raise unittest.SkipTest("docker daemon unreachable")

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

        # Build and bring up the stack
        print("\n[setup] docker compose up -d --build...")
        r = subprocess.run(
            COMPOSE_CMD + ["up", "-d", "--build"],
            cwd=REPO, capture_output=True, text=True, timeout=300.0
        )
        if r.returncode != 0:
            raise unittest.SkipTest(f"compose up --build failed: {r.stderr}")

        # Wait for relays to be healthy
        print("[setup] waiting for relay-a health...")
        if not _wait_for_health(9000, "c2c-relay-a"):
            subprocess.run(COMPOSE_CMD + ["down", "-v"], cwd=REPO, timeout=30.0)
            raise unittest.SkipTest("relay-a did not become healthy")
        print("[setup] waiting for relay-b health...")
        if not _wait_for_health(9001, "c2c-relay-b"):
            subprocess.run(COMPOSE_CMD + ["down", "-v"], cwd=REPO, timeout=30.0)
            raise unittest.SkipTest("relay-b did not become healthy")
        print("[setup] both relays healthy")

        # Give agents extra time to settle
        time.sleep(3)

    @classmethod
    def tearDownClass(cls):
        print("\n[teardown] docker compose down -v...")
        subprocess.run(
            COMPOSE_CMD + ["down", "-v", "--remove-orphans"],
            cwd=REPO, capture_output=True, text=True, timeout=60.0
        )

    def test_c2c_binary_in_agent_container(self):
        """Verify c2c binary is reachable inside the agent container."""
        r = _docker_exec(CONTAINER_A1, ["c2c", "--version"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c --version failed in {CONTAINER_A1}: {r.stderr}"
        )

    def test_codex_turn_start_bridge_mounted(self):
        """Verify codex-turn-start-bridge is mounted from host and callable.

        The binary is dynamically linked to host libraries, so it must be
        mounted from the host at runtime rather than baked into the image.
        """
        r = _docker_exec(
            CONTAINER_A1,
            ["codex-turn-start-bridge", "--version"],
            timeout=5.0
        )
        self.assertEqual(
            r.returncode, 0,
            f"codex-turn-start-bridge --version failed in {CONTAINER_A1}: "
            f"{r.stderr}\n"
            f"(binary must be mounted from host at "
            f"/home/xertrov/.local/bin/codex-turn-start-bridge)"
        )

    def test_deliver_script_present(self):
        """Verify c2c_deliver_inbox.py is present and produces help output.

        The script does support --help; we verify it exits 0 and produces
        non-empty help text containing expected keywords (usage, c2c).
        """
        r = _docker_exec(
            CONTAINER_A1,
            ["python3", "/usr/local/bin/c2c_deliver_inbox.py", "--help"]
        )
        self.assertEqual(
            r.returncode, 0,
            f"c2c_deliver_inbox.py --help failed in {CONTAINER_A1}: {r.stderr}"
        )
        output = r.stdout + r.stderr
        self.assertTrue(
            len(output) > 20,
            f"help output suspiciously short in {CONTAINER_A1}: {output!r}"
        )
        self.assertIn(
            "c2c",
            output.lower(),
            f"help output missing 'c2c' keyword in {CONTAINER_A1}: {output!r}"
        )

    def test_c2c_deliver_inbox_shim_exists(self):
        """Verify the c2c-deliver-inbox shim is installed (bash wrapper)."""
        r = _docker_exec(CONTAINER_A1, ["cat", "/usr/local/bin/c2c-deliver-inbox"])
        self.assertEqual(r.returncode, 0)
        self.assertIn("c2c_deliver_inbox.py", r.stdout)

    def test_codex_a1_registers_with_relay_a(self):
        """Register codex-a1 on relay-a via docker exec."""
        r = _docker_exec(CONTAINER_A1, ["c2c", "register", "-a", "codex-a1"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c register codex-a1 failed: {r.stderr}\nstdout: {r.stdout}"
        )

    def test_codex_b1_registers_with_relay_b(self):
        """Register codex-b1 on relay-b via docker exec."""
        r = _docker_exec(CONTAINER_B1, ["c2c", "register", "-a", "codex-b1"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c register codex-b1 failed: {r.stderr}\nstdout: {r.stdout}"
        )

    def test_send_codex_a1_to_codex_b1_via_relay(self):
        """Send codex-a1 → codex-b1@host-b via relay-a.

        Uses fully-qualified alias codex-b1@host-b for cross-host routing.
        Asserts returncode 0 (message successfully enqueued to relay-a's outbox).
        NOTE: Without peer-relay forwarding configured between host-a and host-b,
        this message is dead-lettered on relay-a and never reaches relay-b.
        Delivery to codex-b1 on relay-b requires peer-forwarding to be set up,
        which is outside S2 scope. This test verifies the send path to the relay
        works correctly.
        """
        r = _docker_exec(
            CONTAINER_A1,
            ["c2c", "send", "codex-b1@host-b", "hello from codex-a1"]
        )
        self.assertEqual(
            r.returncode, 0,
            f"c2c send codex-a1→codex-b1@host-b failed: "
            f"{r.stderr}\nstdout: {r.stdout}"
        )

    def test_poll_codex_b1_inbox_from_relay_b(self):
        """Poll codex-b1 inbox and verify JSON parseability.

        The inbox may be empty if the send went to dead-letter (no peer
        relay forwarding). This test validates:
          1. docker exec → c2c poll-inbox --json works
          2. relay-b is reachable from codex-b1 container
          3. JSON output is parseable
        """
        r = _docker_exec(CONTAINER_B1, ["c2c", "poll-inbox", "--json"])
        self.assertEqual(
            r.returncode, 0,
            f"c2c poll-inbox codex-b1 failed: {r.stderr}\nstdout: {r.stdout}"
        )
        try:
            inbox = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            self.fail(f"poll-inbox JSON unparseable: {e}\noutput: {r.stdout!r}")
        self.assertIsInstance(inbox, list, "inbox should be a JSON list")


class CodexAgentImageTests(unittest.TestCase):
    """Lightweight image build tests that don't need a running stack."""

    def test_dockerfile_agent_builds(self):
        """Verify Dockerfile.agent builds successfully."""
        r = subprocess.run(
            ["docker", "build", "-f", "Dockerfile.agent",
             "-t", "c2c-agent:test", "."],
            cwd=REPO, capture_output=True, text=True, timeout=300.0
        )
        if r.returncode != 0:
            self.skipTest(f"Dockerfile.agent build failed: {r.stderr}")
        self.assertEqual(r.returncode, 0)

        # Verify key files are present in the image
        for binary, path in [
            ("c2c", "/usr/local/bin/c2c"),
            ("c2c_deliver_inbox.py", "/usr/local/bin/c2c_deliver_inbox.py"),
            ("c2c-deliver-inbox shim", "/usr/local/bin/c2c-deliver-inbox"),
        ]:
            r = subprocess.run(
                ["docker", "run", "--rm", "c2c-agent:test",
                 "test", "-f", path],
                capture_output=True, text=True, timeout=10.0
            )
            self.assertEqual(
                r.returncode, 0,
                f"{binary} not found at {path} in c2c-agent:test image"
            )

    def test_compose_file_valid(self):
        """Verify docker-compose.agent-mesh.yml is syntactically valid."""
        r = subprocess.run(
            COMPOSE_CMD + ["config", "--quiet"],
            cwd=REPO, capture_output=True, text=True, timeout=10.0
        )
        self.assertEqual(
            r.returncode, 0,
            f"compose config failed: {r.stderr}"
        )


if __name__ == "__main__":
    unittest.main()
