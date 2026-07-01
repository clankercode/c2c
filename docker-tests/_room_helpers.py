"""
#407 S7 — room ACL E2E helpers for cross-container tests.

Provides utilities to:
  - Register agents on the relay with stable Ed25519 identities
  - Create relay rooms with visibility and invited identity public keys
  - Send messages to rooms
  - Read room history
  - Attempt to join rooms (expecting success or failure)
  - List room members

These helpers run commands via `docker exec` as the testagent user.
"""
from __future__ import annotations

import json
import subprocess
from typing import Any

from _signing_helpers import ensure_testagent_dirs

C2C_CLI = "/usr/local/bin/c2c"
RELAY_URL = "http://relay:7331"

ALIAS_TO_CONTAINER = {
    "a1": "c2c-e2e-agent-a1",
    "a2": "c2c-e2e-agent-a2",
    "b1": "c2c-e2e-agent-b1",
    "b2": "c2c-e2e-agent-b2",
}


def _run_shell_in(container: str, script: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run an arbitrary shell script inside a container as testagent (uid 999)."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += ["-u", "999", container, "bash", "-c", script]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _run_c2c_in(
    container: str,
    argv: list[str],
    timeout: int = 30,
    *,
    as_testagent: bool = True,
) -> subprocess.CompletedProcess:
    """Run c2c CLI inside a named container as the testagent user."""
    env = {
        "C2C_CLI_FORCE": "1",
        "C2C_IN_DOCKER": "1",
        "HOME": "/home/testagent",
        "C2C_MCP_BROKER_ROOT": "/home/testagent/.c2c/broker",
    }
    cmd = ["docker", "exec"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    if as_testagent:
        cmd += ["-u", "999"]
    cmd += [container, C2C_CLI] + argv
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def register(container: str, alias: str) -> subprocess.CompletedProcess:
    """Provision identity, register locally, and bind the alias on the relay."""
    ensure_testagent_dirs(container)
    show = _run_c2c_in(container, ["relay", "identity", "show", "--json"])
    if show.returncode != 0:
        init = _run_c2c_in(container, [
            "relay", "identity", "init", "--alias-hint", alias, "--json"
        ])
        if init.returncode != 0:
            return init
    session_id = f"{alias}-session"
    local = _run_c2c_in(container, [
        "register", "--alias", alias, "--session-id", session_id
    ])
    if local.returncode not in (0, 2):
        return local
    return _run_c2c_in(container, [
        "relay", "register",
        "--alias", alias,
        "--relay-url", RELAY_URL,
    ])


def _alias_container(alias: str) -> str:
    try:
        return ALIAS_TO_CONTAINER[alias]
    except KeyError as exc:
        raise AssertionError(f"no Docker room ACL container mapping for alias {alias}") from exc


def relay_public_key(container: str) -> str:
    """Return this container's relay identity public key."""
    r = _run_c2c_in(container, ["relay", "identity", "show", "--json"])
    assert r.returncode == 0, f"identity show failed in {container}: {r.stderr}"
    data = json.loads(r.stdout)
    pk = data.get("public_key") or data.get("pubkey") or data.get("pk")
    assert pk, f"public key missing from identity show in {container}: {data}"
    return pk


def _relay_rooms_args(subcmd: str, room_id: str, alias: str) -> list[str]:
    return [
        "relay", "rooms", subcmd,
        "--relay-url", RELAY_URL,
        "--room", room_id,
        "--alias", alias,
    ]


def room_create(
    container: str,
    room_id: str,
    visibility: str = "public",
    invites: list[str] | None = None,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Create a relay room with visibility and optional invited identities.

    Runs: c2c relay rooms join --room <room_id> --visibility <public|gated>
          c2c relay rooms invite --invitee-pk <pk> ...

    Returns CompletedProcess. Check returncode for success.
    """
    alias = as_alias or "a1"
    argv = _relay_rooms_args("join", room_id, alias)
    argv += ["--visibility", visibility]
    created = _run_c2c_in(container, argv)
    if created.returncode != 0:
        return created
    if invites:
        for inv in invites:
            invitee_pk = relay_public_key(_alias_container(inv))
            invited = _run_c2c_in(container, [
                "relay", "rooms", "invite",
                "--relay-url", RELAY_URL,
                "--room", room_id,
                "--alias", alias,
                "--invitee-pk", invitee_pk,
            ])
            if invited.returncode != 0:
                return invited
    return created


def room_join(
    container: str,
    room_id: str,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Join a room.

    Runs: c2c relay rooms join --room <room_id> --alias <alias>

    Returns CompletedProcess. Check returncode for success.
    """
    alias = as_alias or _container_alias(container)
    return _run_c2c_in(container, _relay_rooms_args("join", room_id, alias))


def room_send(
    container: str,
    room_id: str,
    message: str,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Send a message to a room.

    Runs: c2c relay rooms send --room <room_id> --alias <alias> <message>

    Returns CompletedProcess. Check returncode for success.
    """
    alias = as_alias or _container_alias(container)
    argv = _relay_rooms_args("send", room_id, alias)
    argv.append(message)
    return _run_c2c_in(container, argv)


def _container_alias(container: str) -> str:
    for alias, mapped in ALIAS_TO_CONTAINER.items():
        if mapped == container:
            return alias
    raise AssertionError(f"no Docker room ACL alias mapping for container {container}")


def room_history(
    container: str,
    room_id: str,
    limit: int = 50,
) -> tuple[list[dict[str, Any]], str]:
    """Fetch room history.

    Returns (messages, stderr). messages is a list of dicts on success,
    empty list on failure. stderr contains error text on failure.
    """
    alias = _container_alias(container)
    r = _run_c2c_in(container, [
        "relay", "rooms", "history",
        "--relay-url", RELAY_URL,
        "--room", room_id,
        "--alias", alias,
        "--limit", str(limit),
    ])
    if r.returncode == 0:
        try:
            data = json.loads(r.stdout)
            if isinstance(data, dict):
                return data.get("history", []), r.stderr
            if isinstance(data, list):
                return data, r.stderr
            return [], r.stderr
        except json.JSONDecodeError:
            return [], r.stderr
    return [], r.stderr


def room_members(
    container: str,
    room_id: str,
) -> tuple[list[str], str]:
    """List room members.

    Returns (members, stderr). members is a list of alias strings on success.
    """
    r = _run_c2c_in(container, ["room", "members", room_id, "--json"])
    if r.returncode == 0:
        try:
            data = json.loads(r.stdout)
            return data.get("members", []), r.stderr
        except json.JSONDecodeError:
            return [], r.stderr
    return [], r.stderr


def room_list(container: str) -> tuple[list[dict[str, Any]], str]:
    """List rooms the caller is a member of.

    Returns (rooms, stderr). rooms is a list of room dicts on success.
    """
    r = _run_c2c_in(container, ["rooms", "list", "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout), r.stderr
        except json.JSONDecodeError:
            return [], r.stderr
    return [], r.stderr
