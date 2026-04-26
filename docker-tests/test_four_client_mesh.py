"""
Phase C Case 7: Four-container mesh.
Spin up four containers (alice, bob, carol, dave), register four aliases,
verify all 6 ordered-pair DMs arrive correctly.
Validates Docker cross-container liveness fix (#310) at mesh scale.
"""
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import pytest

COMPOSE_FILES = [
    "-f", "docker-compose.test.yml",
    "-f", "docker-compose.two-container.yml",
    "-f", "docker-compose.4-client.yml",
]

# 4 clients → 6 ordered pairs
_PAIRS = [
    ("alice", "bob"),
    ("alice", "carol"),
    ("alice", "dave"),
    ("bob", "carol"),
    ("bob", "dave"),
    ("carol", "dave"),
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
    reason="four-container mesh tests require docker CLI + host docker socket",
)


def docker_compose_run(service, command, env=None):
    """Run a command inside a docker-compose service."""
    full_env = dict(os.environ)
    container_env = {"C2C_CLI_FORCE": "1", "C2C_IN_DOCKER": "1"}
    if env:
        container_env.update(env)
        full_env.update(env)
    env_args = []
    for key, value in container_env.items():
        env_args.extend(["-e", f"{key}={value}"])
    argv = (
        ["docker", "compose"] + COMPOSE_FILES
        + ["run", "-T", "--rm"] + env_args
        + [service] + shlex.split(command)
    )
    r = subprocess.run(argv, capture_output=True, text=True, env=full_env, timeout=60)
    return r


def docker_compose_up(service, detach=True):
    """docker compose up -d a single service."""
    argv = ["docker", "compose"] + COMPOSE_FILES + (["up", "-d"] if detach else ["up"])
    if detach:
        argv += ["--no-deps", service]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    return r


def register_and_send(sender, recipient, msg, ts):
    """Register sender, then send msg to recipient. Returns CompletedProcess."""
    sender_sid = f"{sender}-{ts}-session"
    sender_alias = f"{sender}-{ts}"
    r = docker_compose_run(
        sender,
        f"sh -c 'c2c register --alias {sender_alias} && c2c send {recipient} {msg}'",
        env={
            "C2C_MCP_SESSION_ID": sender_sid,
            "C2C_MCP_AUTO_REGISTER_ALIAS": sender_alias,
            "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
        },
    )
    return r, sender_sid, sender_alias


def poll_for_msg(service, session_id, alias, expected_msg, timeout=30):
    """Poll inbox every 2s until expected_msg appears or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = docker_compose_run(
            service,
            "c2c poll-inbox --json",
            env={
                "C2C_MCP_SESSION_ID": session_id,
                "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
            },
        )
        if r.returncode == 0:
            try:
                msgs = json.loads(r.stdout)
                if any(expected_msg in m.get("content", "") for m in msgs):
                    return True, msgs
            except json.JSONDecodeError:
                pass
        time.sleep(2)
    return False, []


class TestFourClientMesh:
    """Case 7: Four-container mesh validation."""

    def test_mesh_all_6_ordered_pairs(self):
        """
        Register all 4 clients, then send all 6 ordered-pair DMs.
        Each recipient polls and confirms receipt.
        """
        ts = int(time.time())
        aliases = {
            "alice": f"alice-{ts}",
            "bob": f"bob-{ts}",
            "carol": f"carol-{ts}",
            "dave": f"dave-{ts}",
        }
        sids = {name: f"{aliases[name]}-session" for name in aliases}

        # Register all 4 in parallel via their respective services
        services = {
            "alice": "peer-a",
            "bob":   "peer-b",
            "carol": "peer-c",
            "dave":  "peer-d",
        }

        for name, alias in aliases.items():
            r = docker_compose_run(
                services[name],
                f"c2c register --alias {alias}",
                env={
                    "C2C_MCP_SESSION_ID": sids[name],
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
                },
            )
            assert r.returncode == 0, f"{name} registration failed: {r.stderr} {r.stdout}"

        # Send all 6 ordered-pair DMs
        send_results = {}
        for sender, recipient in _PAIRS:
            msg = f"{sender}-to-{recipient}-{ts}"
            r, sender_sid, sender_alias = register_and_send(
                services[sender], aliases[recipient], msg, ts
            )
            send_results[(sender, recipient)] = (r, msg, sender_sid, sender_alias)
            assert r.returncode == 0, (
                f"{sender}->{recipient} send failed: {r.stderr} {r.stdout}"
            )

        # Poll each recipient for their expected message
        failures = []
        for sender, recipient in _PAIRS:
            r, msg, sender_sid, sender_alias = send_results[(sender, recipient)]
            # The docker_compose_run returns (returncode, stdout, stderr)
            send_stderr = r.stderr if hasattr(r, 'stderr') else ''
            found, inbox_content = poll_for_msg(
                services[recipient],
                sids[recipient],
                aliases[recipient],
                msg,
            )
            if not found:
                failures.append(f"{sender}->{recipient}: inbox={inbox_content} send_stderr={send_stderr[:500]}")
            else:
                print(f"OK: {sender}->{recipient}", flush=True)

        # Debug: check leases and inbox files
        r_debug = subprocess.run(
            ["docker", "compose", "-f", "docker-compose.test.yml", "-f", "docker-compose.two-container.yml", "-f", "docker-compose.4-client.yml",
             "run", "--rm", "test-env", "sh", "-c",
             "echo '=== LEASES ===' && ls -la /var/lib/c2c/.leases/ && echo '=== INBOXES ===' && ls -la /var/lib/c2c/inboxes/ 2>/dev/null || echo 'no inboxes dir' && echo '=== REGISTRY ===' && cat /var/lib/c2c/registry.json | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(r[\"alias\"], r[\"session_id\"]) for r in d]'"],
            capture_output=True, text=True, timeout=30,
        )
        sys.stderr.write(f"\nDEBUG state:\n{r_debug.stdout}\n")
        sys.stderr.flush()

        assert not failures, f"Messages not received: {failures}"

    def test_concurrent_registration_mesh(self):
        """All 4 containers register concurrently, then list peers."""
        ts = int(time.time())
        aliases = {
            "alice": f"alice-{ts}",
            "bob":   f"bob-{ts}",
            "carol": f"carol-{ts}",
            "dave":  f"dave-{ts}",
        }
        services = {
            "alice": "peer-a",
            "bob":   "peer-b",
            "carol": "peer-c",
            "dave":  "peer-d",
        }
        sids = {name: f"{aliases[name]}-session" for name in aliases}

        # Concurrent registration
        results = {}
        for name, alias in aliases.items():
            r = docker_compose_run(
                services[name],
                f"c2c register --alias {alias}",
                env={
                    "C2C_MCP_SESSION_ID": sids[name],
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
                },
            )
            results[name] = r
            assert r.returncode == 0, f"{name} registration failed: {r.stderr}"

        # Each peer lists and sees all 3 others
        for name, alias in aliases.items():
            r = docker_compose_run(
                services[name],
                "c2c list --json",
                env={
                    "C2C_MCP_SESSION_ID": sids[name],
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_BROKER_ROOT": "/var/lib/c2c",
                },
            )
            assert r.returncode == 0, f"{name} list failed: {r.stderr}"
            peers = json.loads(r.stdout)
            peer_aliases = [p["alias"] for p in peers]
            for other_name, other_alias in aliases.items():
                if other_name != name:
                    assert other_alias in peer_aliases, (
                        f"{name} did not see {other_alias} in peer list: {peer_aliases}"
                    )
