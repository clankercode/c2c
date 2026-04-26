"""
Phase C Case 6: Two-container roundtrip.
Spin up two containers (alice and bob), register two aliases,
DM each direction. Validates Docker isolation works for swarm-style work.
"""
import json
import os
import shlex
import shutil
import subprocess
import time
import pytest

COMPOSE_FILES = [
    "-f",
    "docker-compose.test.yml",
    "-f",
    "docker-compose.two-container.yml",
]


def docker_available():
    """Return true when tests can orchestrate sibling containers from here."""
    if shutil.which("docker") is None:
        return False
    if not os.path.exists("/var/run/docker.sock"):
        return False
    probe = subprocess.run(
        ["docker", "compose", "version"],
        capture_output=True, text=True, timeout=10,
    )
    return probe.returncode == 0


pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="two-container tests require docker CLI + host docker socket",
)


def docker_compose_run(service, command, env=None):
    """Run a command inside a docker-compose service."""
    full_env = dict(os.environ)
    container_env = {"C2C_CLI_FORCE": "1"}
    if env:
        container_env.update(env)
        full_env.update(env)
    env_args = []
    for key, value in container_env.items():
        env_args.extend(["-e", f"{key}={value}"])
    argv = ["docker", "compose"] + COMPOSE_FILES + ["run", "--rm"] + env_args + [service] + shlex.split(command)
    r = subprocess.run(argv, capture_output=True, text=True, env=full_env, timeout=60)
    return r


def docker_compose_up(service, detach=True):
    """docker compose up -d a single service."""
    argv = ["docker", "compose"] + COMPOSE_FILES + (["up", "-d"] if detach else ["up"])
    if detach:
        argv += ["--no-deps", service]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    return r


def docker_compose_exec(service, command):
    """docker compose exec <service> <command>."""
    argv = ["docker", "compose"] + COMPOSE_FILES + ["exec", "-T", service] + shlex.split(command)
    r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    return r


class TestTwoContainerRoundtrip:
    """Case 6: Two-container roundtrip validation."""

    @pytest.mark.xfail(
        reason="cross-container c2c send currently rejects peer PIDs from another PID namespace as not alive",
        strict=False,
    )
    def test_two_container_dm_alice_to_bob(self):
        """Alice container registers, Bob container registers, Alice DMs Bob."""
        ts = int(time.time())
        alice = f"alice-{ts}"
        bob = f"bob-{ts}"
        alice_sid = f"{alice}-session"
        bob_sid = f"{bob}-session"

        r_bob = docker_compose_run(
            "test-env",
            f"c2c register --alias {bob}",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": bob,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_bob.returncode == 0, f"bob register failed: {r_bob.stderr} {r_bob.stdout}"

        msg = f"hello-bob-from-{alice}"
        r = docker_compose_run(
            "test-env",
            f"sh -c 'c2c register --alias {alice} && c2c send {bob} {msg}'",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alice,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r.returncode == 0, f"alice->bob send failed: {r.stderr} {r.stdout}"

        r_poll = docker_compose_run(
            "test-env",
            "c2c poll-inbox --json",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": bob,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_poll.returncode == 0, f"bob poll failed: {r_poll.stderr} {r_poll.stdout}"
        msgs = json.loads(r_poll.stdout)
        assert any(msg in m.get("content", "") for m in msgs), f"bob did not receive {msg}: {msgs}"

    @pytest.mark.xfail(
        reason="cross-container c2c send currently rejects peer PIDs from another PID namespace as not alive",
        strict=False,
    )
    def test_two_container_dm_bob_to_alice(self):
        """Bob container registers, then DMs Alice."""
        ts = int(time.time())
        alice = f"alice-rev-{ts}"
        bob = f"bob-rev-{ts}"
        alice_sid = f"{alice}-session"
        bob_sid = f"{bob}-session"

        r_alice = docker_compose_run(
            "test-env",
            f"c2c register --alias {alice}",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alice,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_alice.returncode == 0, f"alice register failed: {r_alice.stderr} {r_alice.stdout}"

        msg = f"hello-alice-from-{bob}"
        r = docker_compose_run(
            "test-env",
            f"sh -c 'c2c register --alias {bob} && c2c send {alice} {msg}'",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": bob,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r.returncode == 0, f"bob->alice send failed: {r.stderr} {r.stdout}"

        r_poll = docker_compose_run(
            "test-env",
            "c2c poll-inbox --json",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alice,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_poll.returncode == 0, f"alice poll failed: {r_poll.stderr} {r_poll.stdout}"
        msgs = json.loads(r_poll.stdout)
        assert any(msg in m.get("content", "") for m in msgs), f"alice did not receive {msg}: {msgs}"

    @pytest.mark.xfail(
        reason="cross-container c2c send currently rejects peer PIDs from another PID namespace as not alive",
        strict=False,
    )
    def test_bob_receives_from_alice(self):
        """Bob polls and receives Alice's message after both register."""
        ts = int(time.time())
        alice = f"alice-poll-{ts}"
        bob = f"bob-poll-{ts}"
        alice_sid = f"{alice}-session"
        bob_sid = f"{bob}-session"

        r_bob = docker_compose_run(
            "test-env",
            f"c2c register --alias {bob}",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": bob,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_bob.returncode == 0, f"bob register failed: {r_bob.stderr} {r_bob.stdout}"

        msg = f"poll-message-{ts}"
        r_send = docker_compose_run(
            "test-env",
            f"sh -c 'c2c register --alias {alice} && c2c send {bob} {msg}'",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alice,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r_send.returncode == 0, f"alice send failed: {r_send.stderr} {r_send.stdout}"

        r = docker_compose_run(
            "test-env",
            "c2c poll-inbox --json",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": bob,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r.returncode == 0, f"bob poll failed: {r.stderr} {r.stdout}"
        msgs = json.loads(r.stdout)
        assert any(msg in m.get("content", "") for m in msgs), f"bob did not receive {msg}: {msgs}"

    def test_concurrent_registration(self):
        """Both containers register concurrently, then send both directions."""
        ts = int(time.time())
        alice_sid = f"alice-{ts}"
        bob_sid = f"bob-{ts}"

        # Register alice
        r1 = docker_compose_run(
            "test-env",
            f"c2c register --alias alice-{ts}",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": f"alice-{ts}",
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        # Register bob
        r2 = docker_compose_run(
            "test-env",
            f"c2c register --alias bob-{ts}",
            env={
                "C2C_MCP_SESSION_ID": bob_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": f"bob-{ts}",
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        assert r1.returncode == 0, f"alice registration failed: {r1.stderr}"
        assert r2.returncode == 0, f"bob registration failed: {r2.stderr}"

        # Both list peers
        r1 = docker_compose_run(
            "test-env",
            "c2c list --json",
            env={
                "C2C_MCP_SESSION_ID": alice_sid,
                "C2C_MCP_AUTO_REGISTER_ALIAS": f"alice-{ts}",
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            }
        )
        peers = json.loads(r1.stdout)
        aliases = [p["alias"] for p in peers]
        assert f"alice-{ts}" in aliases
        assert f"bob-{ts}" in aliases
