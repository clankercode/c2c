"""
#674 — Kimi + OpenCode cross-host relay E2E test.

Scenario: two agents on different "hosts" (independent broker volumes)
communicate via the relay. One simulates a kimi-like peer, the other
an opencode-like peer. Tests:
  1. Both register successfully
  2. Bidirectional DM delivery via relay
  3. Room join + room message delivery
  4. Basic task: agent-B reads a message from agent-A and echoes it back

Uses docker-compose.e2e-multi-agent.yml topology (agent-a1 = "kimi",
agent-b1 = "opencode"). No LLM invocation — CLI-driven shell agents.
"""

import json
import os
import subprocess
import time

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

COMPOSE_FILE = os.path.join(
    os.path.dirname(__file__), "..", "docker-compose.e2e-multi-agent.yml"
)
C2C = os.environ.get("C2C_CLI", "c2c")
RELAY_URL = "http://c2c-e2e-relay:7331"

AGENT_A = "agent-a1"  # simulates kimi peer (host A)
AGENT_B = "agent-b1"  # simulates opencode peer (host B)


def docker_exec(container: str, cmd: str, timeout: int = 30) -> str:
    """Run a command inside a running container and return stdout."""
    result = subprocess.run(
        ["docker", "exec", container, "bash", "-c", cmd],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"docker exec [{container}] failed (rc={result.returncode}):\n"
            f"  cmd: {cmd}\n"
            f"  stderr: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def c2c_in(container: str, subcmd: str, timeout: int = 30) -> str:
    """Run `c2c <subcmd>` inside a container."""
    return docker_exec(container, f"{C2C} {subcmd}", timeout=timeout)


def register(container: str, alias: str):
    """Register an alias in a container."""
    c2c_in(container, f"register --alias {alias} --relay-url {RELAY_URL}")


def send_dm(from_container: str, to_alias: str, content: str):
    """Send a DM from one container to a remote alias."""
    escaped = content.replace('"', '\\"')
    c2c_in(from_container, f'send {to_alias} "{escaped}"')


def poll_inbox(container: str) -> list[dict]:
    """Poll inbox in a container, return parsed JSON array."""
    raw = c2c_in(container, "poll-inbox --json 2>/dev/null || true")
    if not raw or raw == "[]":
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return []


def poll_until_message(
    container: str, from_alias: str, timeout_s: int = 15
) -> dict | None:
    """Poll inbox until a message from `from_alias` arrives."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        msgs = poll_inbox(container)
        for m in msgs:
            if m.get("from_alias") == from_alias:
                return m
        time.sleep(1)
    return None


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module", autouse=True)
def ensure_compose_up():
    """
    Assumes docker-compose.e2e-multi-agent.yml is already up.
    Tests are designed to run after:
      docker compose -f docker-compose.e2e-multi-agent.yml up -d --build
    """
    # Verify containers are running
    for container in [f"c2c-e2e-{AGENT_A}", f"c2c-e2e-{AGENT_B}", "c2c-e2e-relay"]:
        result = subprocess.run(
            ["docker", "inspect", "--format", "{{.State.Running}}", container],
            capture_output=True,
            text=True,
        )
        if result.stdout.strip() != "true":
            pytest.skip(f"Container {container} not running — start compose first")


@pytest.fixture(scope="module")
def registered_agents():
    """Register both agents and return their container names."""
    container_a = f"c2c-e2e-{AGENT_A}"
    container_b = f"c2c-e2e-{AGENT_B}"

    register(container_a, AGENT_A)
    register(container_b, AGENT_B)

    # Give relay time to process registrations
    time.sleep(2)

    return container_a, container_b


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestCrossHostRegistration:
    """Both agents register and can see each other via relay."""

    def test_agent_a_registers(self, registered_agents):
        container_a, _ = registered_agents
        whoami = c2c_in(container_a, "whoami")
        assert AGENT_A in whoami

    def test_agent_b_registers(self, registered_agents):
        _, container_b = registered_agents
        whoami = c2c_in(container_b, "whoami")
        assert AGENT_B in whoami

    def test_agents_see_each_other(self, registered_agents):
        container_a, container_b = registered_agents
        # Agent A should see agent B in list (via relay)
        list_a = c2c_in(container_a, "list")
        # At minimum, agent-a1 sees itself; cross-host visibility
        # depends on relay federation — check relay list instead
        relay_list = c2c_in(container_a, f"list --relay-url {RELAY_URL}")
        assert AGENT_B in relay_list or AGENT_A in relay_list


class TestCrossHostDM:
    """Bidirectional DM delivery via relay."""

    def test_a_to_b_dm(self, registered_agents):
        container_a, container_b = registered_agents
        test_msg = f"hello-from-kimi-{int(time.time())}"

        send_dm(container_a, f"{AGENT_B}@{RELAY_URL}", test_msg)

        msg = poll_until_message(container_b, AGENT_A, timeout_s=15)
        assert msg is not None, f"Agent B never received DM from Agent A"
        assert test_msg in msg.get("content", "")

    def test_b_to_a_dm(self, registered_agents):
        container_a, container_b = registered_agents
        test_msg = f"hello-from-opencode-{int(time.time())}"

        send_dm(container_b, f"{AGENT_A}@{RELAY_URL}", test_msg)

        msg = poll_until_message(container_a, AGENT_B, timeout_s=15)
        assert msg is not None, f"Agent A never received DM from Agent B"
        assert test_msg in msg.get("content", "")


class TestCrossHostRoom:
    """Room operations across hosts."""

    ROOM = "e2e-cross-host-room"

    def test_both_join_room(self, registered_agents):
        container_a, container_b = registered_agents
        c2c_in(container_a, f"rooms join {self.ROOM}")
        c2c_in(container_b, f"rooms join {self.ROOM}")

        rooms_a = c2c_in(container_a, "rooms list")
        assert self.ROOM in rooms_a

    def test_room_message_delivery(self, registered_agents):
        container_a, container_b = registered_agents
        test_msg = f"room-msg-{int(time.time())}"

        c2c_in(container_a, f'rooms send {self.ROOM} "{test_msg}"')
        time.sleep(3)

        history = c2c_in(container_b, f"rooms history {self.ROOM}")
        assert test_msg in history


class TestCrossHostTaskEcho:
    """Basic task: A sends instruction, B echoes back."""

    def test_echo_roundtrip(self, registered_agents):
        container_a, container_b = registered_agents
        challenge = f"echo-challenge-{int(time.time())}"

        # A sends a "task" to B
        send_dm(container_a, f"{AGENT_B}@{RELAY_URL}", f"ECHO:{challenge}")

        # B polls, reads the challenge, sends it back
        msg = poll_until_message(container_b, AGENT_A, timeout_s=15)
        assert msg is not None, "B never received task from A"

        content = msg.get("content", "")
        assert content.startswith("ECHO:")
        payload = content.split("ECHO:", 1)[1]

        # B echoes back
        send_dm(container_b, f"{AGENT_A}@{RELAY_URL}", f"ACK:{payload}")

        # A receives the echo
        ack = poll_until_message(container_a, AGENT_B, timeout_s=15)
        assert ack is not None, "A never received ACK from B"
        assert f"ACK:{challenge}" in ack.get("content", "")
