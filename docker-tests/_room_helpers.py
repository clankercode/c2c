"""
#407 S7 — room ACL E2E helpers for cross-container tests.

Provides utilities to:
  - Register agents on their respective brokers
  - Create rooms with visibility and invited_members
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


C2C_CLI = "/usr/local/bin/c2c"


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
    """Register an alias on the local broker inside a container."""
    session_id = f"{alias}-session"
    return _run_c2c_in(container, [
        "register", "--alias", alias, "--session-id", session_id
    ])


def room_create(
    container: str,
    room_id: str,
    visibility: str = "public",
    invites: list[str] | None = None,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Create a room with visibility and optional invited_members.

    Runs: c2c rooms create <room_id> [--visibility <public|invite_only>] [--invite <alias>] ...

    Returns CompletedProcess. Check returncode for success.
    """
    argv = ["rooms", "create", room_id, "--visibility", visibility]
    if invites:
        for inv in invites:
            argv += ["--invite", inv]
    if as_alias:
        argv += ["--alias", as_alias]
    return _run_c2c_in(container, argv)


def room_join(
    container: str,
    room_id: str,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Join a room.

    Runs: c2c room join <room_id> [--alias <alias>]

    Returns CompletedProcess. Check returncode for success.
    """
    argv = ["room", "join", room_id]
    if as_alias:
        argv += ["--alias", as_alias]
    return _run_c2c_in(container, argv)


def room_send(
    container: str,
    room_id: str,
    message: str,
    as_alias: str | None = None,
) -> subprocess.CompletedProcess:
    """Send a message to a room.

    Runs: c2c rooms send <room_id> <message> [--alias <alias>]

    Returns CompletedProcess. Check returncode for success.
    """
    argv = ["rooms", "send", room_id, message]
    if as_alias:
        argv += ["--alias", as_alias]
    return _run_c2c_in(container, argv)


def room_history(
    container: str,
    room_id: str,
    limit: int = 50,
) -> tuple[list[dict[str, Any]], str]:
    """Fetch room history.

    Returns (messages, stderr). messages is a list of dicts on success,
    empty list on failure. stderr contains error text on failure.
    """
    r = _run_c2c_in(container, ["room", "history", room_id, "--limit", str(limit), "--json"])
    if r.returncode == 0:
        try:
            return json.loads(r.stdout), r.stderr
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
