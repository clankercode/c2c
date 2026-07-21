"""
End-to-end tests for the basic `c2c rooms` lifecycle on a single broker.

Covers:
  - create a public room (creator auto-joins)
  - list shows the room
  - members shows the creator
  - another alias joins a public room
  - send delivers to room members
  - history shows room messages
  - leave removes membership
  - delete removes an empty room

Runs in the sealed Docker test environment.
"""
import json
import os
import subprocess

import pytest

C2C_CLI = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


pytestmark = pytest.mark.skipif(
    not os.path.exists(C2C_CLI),
    reason=f"c2c binary not found at {C2C_CLI}",
)


def _run(argv, session_id=None, alias=None, timeout=10):
    """Run the c2c CLI in the test environment."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    if alias:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias
    env["C2C_MCP_CLIENT_PID"] = "0"
    proc = subprocess.Popen(
        [C2C_CLI] + argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    env["C2C_MCP_CLIENT_PID"] = str(proc.pid)
    stdout, stderr = proc.communicate(timeout=timeout)
    return subprocess.CompletedProcess(
        args=[C2C_CLI] + argv,
        returncode=proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )


def _register(alias, session_id):
    r = _run(["register", "--alias", alias], session_id=session_id, alias=alias)
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _create_room(room_id, session_id, alias, visibility="public"):
    r = _run(["rooms", "create", room_id, "--visibility", visibility],
             session_id=session_id, alias=alias)
    assert r.returncode == 0, f"create room {room_id} failed: {r.stderr}"
    return r


def _list_rooms():
    r = _run(["rooms", "list", "--json"])
    assert r.returncode == 0, f"rooms list failed: {r.stderr}"
    return json.loads(r.stdout)


def _room_members(room_id):
    r = _run(["rooms", "members", room_id, "--json"])
    assert r.returncode == 0, f"rooms members {room_id} failed: {r.stderr}"
    return json.loads(r.stdout)


def _join_room(room_id, session_id, alias):
    return _run(["rooms", "join", room_id], session_id=session_id, alias=alias)


def _send_room(room_id, content, session_id, alias):
    r = _run(["rooms", "send", room_id, content], session_id=session_id,
             alias=alias)
    assert r.returncode == 0, f"rooms send {room_id} failed: {r.stderr}"
    return r


def _room_history(room_id):
    r = _run(["rooms", "history", room_id, "--json"])
    assert r.returncode == 0, f"rooms history {room_id} failed: {r.stderr}"
    return json.loads(r.stdout)


def _leave_room(room_id, session_id, alias):
    r = _run(["rooms", "leave", room_id], session_id=session_id, alias=alias)
    assert r.returncode == 0, f"rooms leave {room_id} failed: {r.stderr}"
    return r


def _delete_room(room_id, session_id, alias):
    r = _run(["rooms", "delete", room_id], session_id=session_id, alias=alias)
    assert r.returncode == 0, f"rooms delete {room_id} failed: {r.stderr}"
    return r


def test_room_create_list_and_members():
    """Creating a public room lists it and shows the creator as a member."""
    uid = "rlc-001"
    alias = f"room-creator-{uid}"
    session_id = f"room-creator-sess-{uid}"
    room_id = f"room-lifecycle-{uid}"

    _register(alias, session_id)
    _create_room(room_id, session_id, alias, visibility="public")

    rooms = _list_rooms()
    assert any(r.get("room_id") == room_id for r in rooms), \
        f"room {room_id} not in list: {rooms}"

    members = _room_members(room_id)
    assert any(m.get("alias") == alias for m in members), \
        f"creator not in members: {members}"


def test_room_join_send_and_history():
    """A second member can join, receive room sends, and read history."""
    uid = "rlc-002"
    creator_alias = f"room-creator-{uid}"
    creator_session = f"room-creator-sess-{uid}"
    joiner_alias = f"room-joiner-{uid}"
    joiner_session = f"room-joiner-sess-{uid}"
    room_id = f"room-lifecycle-{uid}"
    msg = f"hello room {uid}"

    _register(creator_alias, creator_session)
    _register(joiner_alias, joiner_session)
    _create_room(room_id, creator_session, creator_alias, visibility="public")

    r = _join_room(room_id, joiner_session, joiner_alias)
    assert r.returncode == 0, f"join failed: {r.stderr}"

    members = _room_members(room_id)
    aliases = {m.get("alias") for m in members}
    assert aliases == {creator_alias, joiner_alias}, f"unexpected members: {members}"

    _send_room(room_id, msg, creator_session, creator_alias)

    history = _room_history(room_id)
    contents = [h.get("content", "") for h in history]
    assert any(msg in c for c in contents), f"message not in history: {contents}"


def test_room_leave_and_delete():
    """Leaving removes membership; the creator can delete an empty room."""
    uid = "rlc-003"
    alias = f"room-creator-{uid}"
    session_id = f"room-creator-sess-{uid}"
    room_id = f"room-lifecycle-{uid}"

    _register(alias, session_id)
    _create_room(room_id, session_id, alias, visibility="public")

    _leave_room(room_id, session_id, alias)

    members = _room_members(room_id)
    assert not any(m.get("alias") == alias for m in members), \
        f"creator still in members after leave: {members}"

    _delete_room(room_id, session_id, alias)

    rooms = _list_rooms()
    assert not any(r.get("room_id") == room_id for r in rooms), \
        f"room {room_id} still listed after delete: {rooms}"


def test_room_non_member_cannot_send():
    """Sending to a room fails when the alias is not a member."""
    uid = "rlc-004"
    creator_alias = f"room-creator-{uid}"
    creator_session = f"room-creator-sess-{uid}"
    outsider_alias = f"room-outsider-{uid}"
    outsider_session = f"room-outsider-sess-{uid}"
    room_id = f"room-lifecycle-{uid}"

    _register(creator_alias, creator_session)
    _register(outsider_alias, outsider_session)
    _create_room(room_id, creator_session, creator_alias, visibility="public")

    r = _run(["rooms", "send", room_id, "should not deliver"],
             session_id=outsider_session, alias=outsider_alias)
    assert r.returncode != 0, "non-member send should fail"
