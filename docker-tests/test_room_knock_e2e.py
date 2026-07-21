"""
End-to-end tests for gated-room knock/approve/deny on a single broker.

Covers:
  - non-invited aliases cannot join a gated room
  - an alias can request to join via `rooms knock`
  - room members see the pending knock via `rooms knocks`
  - approving a knock lets the alias join
  - denying a knock blocks the alias from joining

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


def _create_gated_room(room_id, session_id, alias):
    r = _run(["rooms", "create", room_id, "--visibility", "gated"],
             session_id=session_id, alias=alias)
    assert r.returncode == 0, f"create gated room {room_id} failed: {r.stderr}"
    return r


def test_gated_room_blocks_uninvited_join():
    """A non-invited alias cannot join a gated room."""
    uid = "rk-001"
    creator = f"rk-creator-{uid}"
    creator_session = f"rk-creator-sess-{uid}"
    outsider = f"rk-outsider-{uid}"
    outsider_session = f"rk-outsider-sess-{uid}"
    room_id = f"rk-gated-{uid}"

    _register(creator, creator_session)
    _register(outsider, outsider_session)
    _create_gated_room(room_id, creator_session, creator)

    r = _run(["rooms", "join", room_id], session_id=outsider_session,
             alias=outsider)
    assert r.returncode != 0, "uninvited join should fail"


def test_knock_approve_then_join():
    """Requesting to join, then approving, lets the alias enter the room."""
    uid = "rk-002"
    creator = f"rk-creator-{uid}"
    creator_session = f"rk-creator-sess-{uid}"
    knocker = f"rk-knocker-{uid}"
    knocker_session = f"rk-knocker-sess-{uid}"
    room_id = f"rk-gated-{uid}"

    _register(creator, creator_session)
    _register(knocker, knocker_session)
    _create_gated_room(room_id, creator_session, creator)

    r = _run(["rooms", "knock", room_id], session_id=knocker_session,
             alias=knocker)
    assert r.returncode == 0, f"knock failed: {r.stderr}"

    r = _run(["rooms", "knocks", room_id, "--json"], session_id=creator_session,
             alias=creator)
    assert r.returncode == 0, f"knocks list failed: {r.stderr}"
    knocks = json.loads(r.stdout)
    assert any(k.get("requester_alias") == knocker for k in knocks), \
        f"knocker not in knocks: {knocks}"

    r = _run(["rooms", "approve-knock", room_id, knocker],
             session_id=creator_session, alias=creator)
    assert r.returncode == 0, f"approve-knock failed: {r.stderr}"

    r = _run(["rooms", "join", room_id], session_id=knocker_session,
             alias=knocker)
    assert r.returncode == 0, f"join after approval failed: {r.stderr}"

    r = _run(["rooms", "members", room_id, "--json"])
    assert r.returncode == 0, f"members failed: {r.stderr}"
    members = json.loads(r.stdout)
    aliases = {m.get("alias") for m in members}
    assert aliases == {creator, knocker}, f"unexpected members: {members}"


def test_knock_deny_blocks_join():
    """Denying a knock prevents the alias from joining the gated room."""
    uid = "rk-003"
    creator = f"rk-creator-{uid}"
    creator_session = f"rk-creator-sess-{uid}"
    knocker = f"rk-knocker-{uid}"
    knocker_session = f"rk-knocker-sess-{uid}"
    room_id = f"rk-gated-{uid}"

    _register(creator, creator_session)
    _register(knocker, knocker_session)
    _create_gated_room(room_id, creator_session, creator)

    r = _run(["rooms", "knock", room_id], session_id=knocker_session,
             alias=knocker)
    assert r.returncode == 0, f"knock failed: {r.stderr}"

    r = _run(["rooms", "deny-knock", room_id, knocker],
             session_id=creator_session, alias=creator)
    assert r.returncode == 0, f"deny-knock failed: {r.stderr}"

    r = _run(["rooms", "join", room_id], session_id=knocker_session,
             alias=knocker)
    assert r.returncode != 0, "join after deny should fail"


def test_invited_alias_skips_knock():
    """An alias on the invite list can join a gated room directly."""
    uid = "rk-004"
    creator = f"rk-creator-{uid}"
    creator_session = f"rk-creator-sess-{uid}"
    invited = f"rk-invited-{uid}"
    invited_session = f"rk-invited-sess-{uid}"
    room_id = f"rk-gated-{uid}"

    _register(creator, creator_session)
    _register(invited, invited_session)
    r = _run(["rooms", "create", room_id, "--visibility", "gated",
              "--invite", invited],
             session_id=creator_session, alias=creator)
    assert r.returncode == 0, f"create with invite failed: {r.stderr}"

    r = _run(["rooms", "join", room_id], session_id=invited_session,
             alias=invited)
    assert r.returncode == 0, f"invited join failed: {r.stderr}"

    r = _run(["rooms", "members", room_id, "--json"])
    members = json.loads(r.stdout)
    aliases = {m.get("alias") for m in members}
    assert invited in aliases, f"invited alias not in members: {members}"
