"""
B140/B179: deliberate alias rename end-to-end.

Tests that `c2c rename` atomically updates the local identity stores:
  - registry row alias changes
  - room memberships are rewritten
  - old alias is no longer routable
  - new alias is routable
  - noop self-rename succeeds
  - rename to an alias that already has key material is refused

Runs in the sealed Docker test environment using the local broker.
"""
import json
import os
import subprocess
import time
import uuid

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


def _fresh_id():
    """Return a short unique id for alias/session isolation."""
    return f"{int(time.time())}-{uuid.uuid4().hex[:8]}"


def _register(alias, session_id):
    r = _run(["register", "--alias", alias, "--session-id", session_id])
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _rename(session_id, new_alias):
    return _run(["rename", new_alias, "--json"], session_id=session_id)


def _list_json():
    r = _run(["list", "--json"])
    assert r.returncode == 0, f"list failed: {r.stderr}"
    return json.loads(r.stdout)


def _create_room(alias, session_id, room_id):
    r = _run(
        ["rooms", "create", room_id, "--visibility", "public"],
        session_id=session_id,
        alias=alias,
    )
    assert r.returncode == 0, f"create room {room_id} failed: {r.stderr}"
    return r


def _room_members(room_id):
    r = _run(["rooms", "members", room_id, "--json"])
    assert r.returncode == 0, f"rooms members {room_id} failed: {r.stderr}"
    return json.loads(r.stdout)


def _send(from_alias, to_alias, content, session_id):
    r = _run(["send", to_alias, content], session_id=session_id, alias=from_alias)
    return r


def _poll_inbox(session_id):
    r = _run(["poll-inbox", "--json"], session_id=session_id)
    if r.returncode != 0:
        return []
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return []


def _find_alias(rows, alias):
    return [row for row in rows if row.get("alias") == alias]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_rename_updates_registry_and_rooms():
    """Rename changes the registry alias and room memberships."""
    uid = _fresh_id()
    old_alias = f"ren-old-{uid}"
    new_alias = f"ren-new-{uid}"
    session_id = f"ren-sess-{uid}"
    room_id = f"ren-room-{uid}"

    _register(old_alias, session_id)
    _create_room(old_alias, session_id, room_id)

    # Sanity: registry and room show the old alias.
    rows = _list_json()
    assert _find_alias(rows, old_alias), f"old alias missing from registry: {rows}"
    assert not _find_alias(rows, new_alias), f"new alias already present: {rows}"
    members = _room_members(room_id)
    assert any(m.get("alias") == old_alias for m in members), f"old alias missing from room: {members}"

    # Rename.
    r = _rename(session_id, new_alias)
    assert r.returncode == 0, f"rename failed: {r.stderr}"
    result = json.loads(r.stdout)
    assert result.get("ok") is True, f"rename returned ok=false: {result}"
    assert result.get("old_alias") == old_alias
    assert result.get("new_alias") == new_alias
    assert room_id in result.get("rooms_renamed", []), f"room not reported as renamed: {result}"

    # Registry now shows the new alias, not the old one.
    rows = _list_json()
    assert _find_alias(rows, new_alias), f"new alias missing from registry: {rows}"
    assert not _find_alias(rows, old_alias), f"old alias still in registry: {rows}"

    # Room membership is updated.
    members = _room_members(room_id)
    assert any(m.get("alias") == new_alias for m in members), f"new alias missing from room: {members}"
    assert not any(m.get("alias") == old_alias for m in members), f"old alias still in room: {members}"


def test_rename_makes_old_alias_unroutable_and_new_alias_works():
    """After rename, DMs to the old alias fail and DMs to the new alias deliver."""
    uid = _fresh_id()
    old_alias = f"ren-sender-old-{uid}"
    new_alias = f"ren-sender-new-{uid}"
    session_id = f"ren-sender-sess-{uid}"
    recipient = f"ren-recipient-{uid}"
    recipient_session = f"ren-recipient-sess-{uid}"

    _register(old_alias, session_id)
    _register(recipient, recipient_session)

    r = _rename(session_id, new_alias)
    assert r.returncode == 0, f"rename failed: {r.stderr}"

    # Sending to the old alias should fail.
    r_old = _send(new_alias, old_alias, "should not route", session_id)
    assert r_old.returncode != 0, f"send to old alias should fail, got rc={r_old.returncode}"
    assert "not registered" in r_old.stderr.lower(), f"unexpected failure text: {r_old.stderr}"

    # Sending to the new alias should deliver (recipient poll-inbox sees it).
    msg = f"rename delivery test {uid}"
    r_new = _send(new_alias, recipient, msg, session_id)
    assert r_new.returncode == 0, f"send to new alias failed: {r_new.stderr}"

    inbox = _poll_inbox(recipient_session)
    assert any(msg in m.get("content", "") for m in inbox), f"recipient did not receive DM: {inbox}"


def test_rename_noop_same_alias():
    """Renaming to the current alias is a successful noop."""
    uid = _fresh_id()
    alias = f"ren-noop-{uid}"
    session_id = f"ren-noop-sess-{uid}"

    _register(alias, session_id)
    r = _rename(session_id, alias)
    assert r.returncode == 0, f"noop rename failed: {r.stderr}"
    result = json.loads(r.stdout)
    assert result.get("ok") is True, f"noop rename returned ok=false: {result}"
    assert result.get("noop") is True, f"noop rename missing noop flag: {result}"


def test_rename_refuses_over_existing_key_material():
    """Renaming to an alias that already has key material is refused."""
    uid = _fresh_id()
    original = f"ren-original-{uid}"
    original_session = f"ren-original-sess-{uid}"
    occupied = f"ren-occupied-{uid}"
    occupied_session = f"ren-occupied-sess-{uid}"

    _register(original, original_session)
    _register(occupied, occupied_session)

    r = _rename(original_session, occupied)
    assert r.returncode != 0, "rename to occupied alias should fail"
    result = json.loads(r.stdout)
    assert result.get("ok") is False, f"rename returned ok=true for occupied alias: {result}"
    error = result.get("error", "")
    assert "held by an alive session" in error or "refusing to overwrite" in error.lower() or "already has" in error.lower(), \
        f"unexpected refusal text: {error}"

    # Original alias must still be intact (rollback).
    rows = _list_json()
    assert _find_alias(rows, original), f"original alias lost after failed rename: {rows}"
