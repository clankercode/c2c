"""
#407 S7: room ACL E2E — invite-only room enforcement across broker boundary.

Test validates that invite_only rooms enforce access control:
  - Only invited members can join
  - Non-members cannot read room history
  - Invited members who join see full room history

Topology: agent-a1 + agent-a2 on broker-a (host-A),
         agent-b1 + agent-b2 on broker-b (host-B),
         relay in between.

AC: invite-only enforced across broker boundary.
    - a1 creates private room, invites a2
    - b1 (not invited) tries to join → REJECTED
    - b2 (not invited) tries to join → REJECTED
    - a2 (invited) joins successfully, sees history after a1 sends

Depends on: docker-compose.e2e-multi-agent.yml (S1 baseline)
"""
import json
import os
import subprocess
import time

import pytest

from _room_helpers import (
    register,
    room_create,
    room_join,
    room_send,
    room_history,
    room_members,
)

COMPOSE_FILE = "docker-compose.e2e-multi-agent.yml"
COMPOSE = ["docker", "compose", "-f", COMPOSE_FILE]
AGENT_A1 = "c2c-e2e-agent-a1"
AGENT_A2 = "c2c-e2e-agent-a2"
AGENT_B1 = "c2c-e2e-agent-b1"
AGENT_B2 = "c2c-e2e-agent-b2"


def docker_available():
    if not os.path.exists("/var/run/docker.sock"):
        return False
    probe = subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "version"],
        capture_output=True, text=True, timeout=10,
    )
    return probe.returncode == 0


pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="e2e tests require docker CLI + host docker socket",
)


def _wait_relay_healthy(timeout: int = 90) -> None:
    """Wait for the relay to become healthy."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Health.Status}}", "c2c-e2e-relay"],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip() == "healthy":
            return
        time.sleep(2)
    raise RuntimeError("Relay did not become healthy within {}s".format(timeout))


def compose_up():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "up", "-d", "--build", "--wait", "--wait-timeout", "120"],
        check=True, timeout=180,
    )
    _wait_relay_healthy()
    time.sleep(2)


def compose_down():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE,
         "down", "-v", "--remove-orphans"],
         capture_output=True, timeout=60,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_invite_only_blocks_non_invited_broker_a(agent_a1, agent_a2, agent_b1):
    """Non-invited agent on broker-A cannot join an invite_only room.

    Steps:
      1. a1 creates an invite_only room and invites only a2
      2. b1 (not invited, on broker-B) tries to join → must FAIL
    """
    # Register all three agents
    for agent, alias in [(agent_a1, "a1"), (agent_a2, "a2"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):  # 2 = already registered
            print("[s7] register warning for {}: {}".format(alias, r.stderr))

    room_id = "s7-invite-only-{}".format(int(time.time()))

    # a1 creates an invite_only room, inviting only a2
    r = room_create(agent_a1, room_id, visibility="invite_only", invites=["a2"], as_alias="a1")
    assert r.returncode == 0, "room create failed: {}".format(r.stderr)
    print("[s7] room created: {} by a1".format(room_id))

    # b1 (not invited) tries to join - must FAIL
    r_join = room_join(agent_b1, room_id, as_alias="b1")
    assert r_join.returncode != 0, \
        "b1 (not invited) should NOT be able to join invite_only room, but got rc={}".format(r_join.returncode)
    print("[s7] b1 correctly rejected from invite_only room")


def test_invite_only_blocks_non_invited_broker_b(agent_a1, agent_b1, agent_b2):
    """Non-invited agent on broker-B cannot join an invite_only room.

    Steps:
      1. a1 creates an invite_only room, invites nobody
      2. b1 (not invited, broker-B) tries to join → must FAIL
      3. b2 (not invited, broker-B) tries to join → must FAIL
    """
    # Register all agents
    for agent, alias in [(agent_a1, "a1"), (agent_b1, "b1"), (agent_b2, "b2")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s7] register warning for {}: {}".format(alias, r.stderr))

    room_id = "s7-invite-only-b-{}".format(int(time.time()))

    # a1 creates invite_only room with NO invites
    r = room_create(agent_a1, room_id, visibility="invite_only", invites=[], as_alias="a1")
    assert r.returncode == 0, "room create failed: {}".format(r.stderr)

    # b1 tries to join - must FAIL
    r1 = room_join(agent_b1, room_id, as_alias="b1")
    assert r1.returncode != 0, \
        "b1 (not invited, broker-B) should NOT be able to join invite_only room"
    print("[s7] b1 correctly rejected from invite_only room (broker-B)")

    # b2 tries to join - must FAIL
    r2 = room_join(agent_b2, room_id, as_alias="b2")
    assert r2.returncode != 0, \
        "b2 (not invited, broker-B) should NOT be able to join invite_only room"
    print("[s7] b2 correctly rejected from invite_only room (broker-B)")


def test_invited_member_joins_and_sees_history(agent_a1, agent_a2):
    """Invited member can join an invite_only room and sees history.

    Steps:
      1. a1 creates invite_only room, invites a2
      2. a1 sends a message
      3. a2 joins the room → must SUCCEED
      4. a2 reads history → must see a1's message
    """
    # Register both agents
    for agent, alias in [(agent_a1, "a1"), (agent_a2, "a2")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s7] register warning for {}: {}".format(alias, r.stderr))

    room_id = "s7-invite-join-{}".format(int(time.time()))

    # a1 creates invite_only room, invites a2
    r = room_create(agent_a1, room_id, visibility="invite_only", invites=["a2"], as_alias="a1")
    assert r.returncode == 0, "room create failed: {}".format(r.stderr)
    print("[s7] room created: {} by a1".format(room_id))

    # a1 sends a message to the room
    msg = "hello from a1 in invite_only room"
    r_send = room_send(agent_a1, room_id, msg, as_alias="a1")
    assert r_send.returncode == 0, "room send failed: {}".format(r_send.stderr)
    print("[s7] a1 sent message: {}".format(msg))

    # a2 joins - must SUCCEED (was invited)
    r_join = room_join(agent_a2, room_id, as_alias="a2")
    assert r_join.returncode == 0, \
        "a2 (invited) should be able to join invite_only room, but got rc={}: {}".format(
            r_join.returncode, r_join.stderr)
    print("[s7] a2 joined invite_only room successfully")

    # a2 reads room history - must see a1's message
    time.sleep(1)  # small settle for async delivery
    msgs, err = room_history(agent_a2, room_id)
    assert msgs, "room history should not be empty after a1 sent a message: {}".format(err)
    content_values = [m.get("content", "") for m in msgs]
    assert any(msg in c for c in content_values), \
        "a2 should see a1's message in room history. Messages: {}".format(content_values)
    print("[s7] a2 saw a1's message in room history: {}".format(content_values))


def test_non_member_cannot_read_history(agent_a1, agent_a2, agent_b1):
    """Non-member cannot read invite_only room history.

    Steps:
      1. a1 creates invite_only room, invites a2 (NOT b1)
      2. a1 sends a message
      3. b1 (not invited) tries to read history → must FAIL or return empty
      4. a2 (invited) reads history → must SUCCEED and see message
    """
    for agent, alias in [(agent_a1, "a1"), (agent_a2, "a2"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s7] register warning for {}: {}".format(alias, r.stderr))

    room_id = "s7-no-history-{}".format(int(time.time()))

    # a1 creates invite_only room, invites only a2
    r = room_create(agent_a1, room_id, visibility="invite_only", invites=["a2"], as_alias="a1")
    assert r.returncode == 0, "room create failed: {}".format(r.stderr)

    # a1 sends a message
    msg = "secret message from a1"
    r_send = room_send(agent_a1, room_id, msg, as_alias="a1")
    assert r_send.returncode == 0, "room send failed: {}".format(r_send.stderr)

    # b1 (not invited) tries to read history
    # The broker should either reject (rc != 0) or return empty
    b1_msgs, b1_err = room_history(agent_b1, room_id)
    # Either b1 gets empty (no access) OR the call fails
    # Either outcome is correct for access control
    b1_sees_msg = any(msg in m.get("content", "") for m in b1_msgs)
    assert not b1_sees_msg, \
        "b1 (not invited) should NOT see messages in invite_only room history. Got: {}".format(b1_msgs)
    print("[s7] b1 correctly cannot read invite_only room history (got {} msgs)".format(len(b1_msgs)))

    # a2 (invited) reads history - must SUCCEED and see message
    time.sleep(1)
    a2_msgs, a2_err = room_history(agent_a2, room_id)
    assert a2_msgs, "a2 (invited) should get room history, got empty: {}".format(a2_err)
    a2_sees_msg = any(msg in m.get("content", "") for m in a2_msgs)
    assert a2_sees_msg, \
        "a2 (invited) should see a1's message. Messages: {}".format(
            [m.get("content", "") for m in a2_msgs])
    print("[s7] a2 correctly sees message in room history")


def test_room_acl_cross_broker_full(agent_a1, agent_a2, agent_b1):
    """Full cross-broker ACL flow: create, invite, join, send, history check.

    a1 (broker-A) creates invite_only room, invites a2.
    b1 (broker-B, not invited) tries to join → FAIL.
    a2 (broker-A, invited) joins → OK.
    a1 sends message → OK.
    a2 reads history → sees message.
    b1 tries history → empty.
    """
    for agent, alias in [(agent_a1, "a1"), (agent_a2, "a2"), (agent_b1, "b1")]:
        r = register(agent, alias)
        if r.returncode not in (0, 2):
            print("[s7] register warning for {}: {}".format(alias, r.stderr))

    room_id = "s7-full-acl-{}".format(int(time.time()))

    # a1 creates invite_only room, invites a2
    r = room_create(agent_a1, room_id, visibility="invite_only", invites=["a2"], as_alias="a1")
    assert r.returncode == 0, "room create failed: {}".format(r.stderr)
    print("[s7] room {} created by a1 (invite_only, invited: a2)".format(room_id))

    # b1 (not invited, broker-B) tries to join → must FAIL
    r_join_b1 = room_join(agent_b1, room_id, as_alias="b1")
    assert r_join_b1.returncode != 0, \
        "b1 (not invited) should NOT be able to join invite_only room"
    print("[s7] b1 rejected from invite_only room (cross-broker ACL working)")

    # a2 (invited, broker-A) joins → must SUCCEED
    r_join_a2 = room_join(agent_a2, room_id, as_alias="a2")
    assert r_join_a2.returncode == 0, \
        "a2 (invited) should join invite_only room, got rc={}: {}".format(
            r_join_a2.returncode, r_join_a2.stderr)
    print("[s7] a2 joined invite_only room successfully")

    # a1 sends a message to the room
    msg = "cross-broker ACL test message from a1"
    r_send = room_send(agent_a1, room_id, msg, as_alias="a1")
    assert r_send.returncode == 0, "room send failed: {}".format(r_send.stderr)
    print("[s7] a1 sent message: {}".format(msg))

    # a2 reads history → must see the message
    time.sleep(1)
    a2_msgs, _ = room_history(agent_a2, room_id)
    a2_sees_msg = any(msg in m.get("content", "") for m in a2_msgs)
    assert a2_sees_msg, \
        "a2 should see a1's message in room history. Got: {}".format(
            [m.get("content", "") for m in a2_msgs])
    print("[s7] a2 sees a1's message in room history ✅")

    # b1 tries to read history → must NOT see the message
    b1_msgs, _ = room_history(agent_b1, room_id)
    b1_sees_msg = any(msg in m.get("content", "") for m in b1_msgs)
    assert not b1_sees_msg, \
        "b1 (not invited) should NOT see room history. Got: {}".format(
            [m.get("content", "") for m in b1_msgs])
    print("[s7] b1 correctly cannot read room history ✅")
    print("[s7] PASS — full cross-broker ACL flow validated")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def topology():
    compose_up()
    yield
    compose_down()


@pytest.fixture
def agent_a1(topology):
    return AGENT_A1


@pytest.fixture
def agent_a2(topology):
    return AGENT_A2


@pytest.fixture
def agent_b1(topology):
    return AGENT_B1


@pytest.fixture
def agent_b2(topology):
    return AGENT_B2
