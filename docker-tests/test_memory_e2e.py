"""
End-to-end tests for the `c2c memory` CLI surface.

Covers the lifecycle of per-agent memory entries:
  - write creates a Markdown file and returns it via list/read
  - description and type metadata are persisted
  - delete removes the file
  - global sharing lets other aliases read the entry
  - targeted sharing (--shared-with) grants read access without global share
  - revoke removes targeted access and cross-agent read fails closed

Runs in the sealed Docker test environment. Each test gets its own
memory-root temp directory to avoid cross-test state.
"""
import json
import os
import subprocess
import tempfile

import pytest

C2C_CLI = os.environ.get("C2C_CLI", "/usr/local/bin/c2c")
BROKER_ROOT = os.environ.get("C2C_MCP_BROKER_ROOT", "/var/lib/c2c")


pytestmark = pytest.mark.skipif(
    not os.path.exists(C2C_CLI),
    reason=f"c2c binary not found at {C2C_CLI}",
)


def _run(argv, session_id=None, alias=None, memory_root=None, timeout=10):
    """Run the c2c CLI in the test environment."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if memory_root:
        env["C2C_MEMORY_ROOT_OVERRIDE"] = memory_root
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


def _memory_root():
    """Create a fresh temp directory to use as the memory root."""
    return tempfile.mkdtemp(prefix="c2c-memory-e2e-")


def _register(alias, session_id, memory_root):
    r = _run(["register", "--alias", alias], session_id=session_id, alias=alias,
             memory_root=memory_root)
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _write(name, content, *, memory_root, session_id, alias, extra=None):
    argv = ["memory", "write", name, content]
    if extra:
        argv.extend(extra)
    r = _run(argv, session_id=session_id, alias=alias, memory_root=memory_root)
    assert r.returncode == 0, f"memory write {name} failed: {r.stderr}"
    return r


def _list(memory_root, session_id, extra=None):
    argv = ["memory", "list", "--json"]
    if extra:
        argv.extend(extra)
    r = _run(argv, session_id=session_id, memory_root=memory_root)
    assert r.returncode == 0, f"memory list failed: {r.stderr}"
    return json.loads(r.stdout)


def _read(name, memory_root, session_id, extra=None):
    argv = ["memory", "read", name, "--json"]
    if extra:
        argv.extend(extra)
    r = _run(argv, session_id=session_id, memory_root=memory_root)
    return r


def _entry_path(memory_root, alias, name):
    return os.path.join(memory_root, alias, f"{name}.md")


def test_memory_write_creates_file_and_round_trips():
    """`memory write` writes a Markdown file that list/read read back."""
    memory_root = _memory_root()
    session_id = "mem-write-sess"
    alias = "mem-write-alias"

    _register(alias, session_id, memory_root)
    _write("note", "Hello world", memory_root=memory_root,
           session_id=session_id, alias=alias,
           extra=["--description", "A note", "--type", "reference"])

    path = _entry_path(memory_root, alias, "note")
    assert os.path.isfile(path), f"memory entry not created: {path}"

    entries = _list(memory_root, session_id)
    assert len(entries) == 1
    entry = entries[0]
    assert entry["name"] == "note"
    assert entry["description"] == "A note"
    assert entry["type"] == "reference"
    assert entry["shared"] is False
    assert entry["shared_with"] == []

    r = _read("note", memory_root, session_id)
    assert r.returncode == 0, f"memory read failed: {r.stderr}"
    shown = json.loads(r.stdout)
    assert shown["content"] == "Hello world\n"


def test_memory_delete_removes_file():
    """`memory delete` removes the Markdown file and drops it from list."""
    memory_root = _memory_root()
    session_id = "mem-rm-sess"
    alias = "mem-rm-alias"

    _register(alias, session_id, memory_root)
    _write("temp", "temporary", memory_root=memory_root,
           session_id=session_id, alias=alias)

    path = _entry_path(memory_root, alias, "temp")
    assert os.path.isfile(path)

    r = _run(["memory", "delete", "temp"], session_id=session_id,
             memory_root=memory_root)
    assert r.returncode == 0, f"memory delete failed: {r.stderr}"

    entries = _list(memory_root, session_id)
    assert entries == []
    assert not os.path.exists(path)


def test_memory_global_share_allows_cross_agent_read():
    """Globally shared memory is readable by another alias."""
    memory_root = _memory_root()

    alice_session = "mem-alice-sess"
    alice_alias = "mem-alice"
    bob_session = "mem-bob-sess"
    bob_alias = "mem-bob"

    _register(alice_alias, alice_session, memory_root)
    _register(bob_alias, bob_session, memory_root)

    _write("shared-note", "shared content", memory_root=memory_root,
           session_id=alice_session, alias=alice_alias,
           extra=["--shared"])

    # Alice sees it in her list as shared.
    alice_entries = _list(memory_root, alice_session)
    assert len(alice_entries) == 1
    assert alice_entries[0]["shared"] is True

    # Bob can read it when targeting alice's alias.
    r = _read("shared-note", memory_root, bob_session,
              extra=["--alias", alice_alias])
    assert r.returncode == 0, f"bob read of shared note failed: {r.stderr}"
    shown = json.loads(r.stdout)
    assert shown["content"] == "shared content\n"

    # Bob sees it in the global shared scan.
    shared = _list(memory_root, bob_session, extra=["--shared"])
    assert any(e["name"] == "shared-note" and e["alias"] == alice_alias
               for e in shared)


def test_memory_targeted_share_without_global_share():
    """--shared-with grants access without making the entry globally shared."""
    memory_root = _memory_root()

    alice_session = "mem-tgt-alice-sess"
    alice_alias = "mem-tgt-alice"
    bob_session = "mem-tgt-bob-sess"
    bob_alias = "mem-tgt-bob"

    _register(alice_alias, alice_session, memory_root)
    _register(bob_alias, bob_session, memory_root)

    _write("private-note", "private content", memory_root=memory_root,
           session_id=alice_session, alias=alice_alias,
           extra=["--shared-with", bob_alias])

    # Alice's list shows targeted sharing, not global sharing.
    alice_entries = _list(memory_root, alice_session)
    assert len(alice_entries) == 1
    entry = alice_entries[0]
    assert entry["shared"] is False
    assert bob_alias in entry["shared_with"]

    # Bob can still read it.
    r = _read("private-note", memory_root, bob_session,
              extra=["--alias", alice_alias])
    assert r.returncode == 0, f"bob targeted read failed: {r.stderr}"
    shown = json.loads(r.stdout)
    assert shown["content"] == "private content\n"

    # It does NOT appear in the global shared scan.
    shared = _list(memory_root, bob_session, extra=["--shared"])
    assert not any(e["name"] == "private-note" for e in shared)

    # Bob sees it in --shared-with-me.
    with_me = _list(memory_root, bob_session, extra=["--shared-with-me"])
    assert any(e["name"] == "private-note" and e["alias"] == alice_alias
               for e in with_me)


def test_memory_revoke_blocks_cross_agent_read():
    """After revoking a targeted grant, the recipient can no longer read."""
    memory_root = _memory_root()

    alice_session = "mem-rev-alice-sess"
    alice_alias = "mem-rev-alice"
    bob_session = "mem-rev-bob-sess"
    bob_alias = "mem-rev-bob"

    _register(alice_alias, alice_session, memory_root)
    _register(bob_alias, bob_session, memory_root)

    _write("revoke-note", "secret", memory_root=memory_root,
           session_id=alice_session, alias=alice_alias,
           extra=["--shared-with", bob_alias])

    # Bob can read initially.
    r = _read("revoke-note", memory_root, bob_session,
              extra=["--alias", alice_alias])
    assert r.returncode == 0

    # Alice revokes Bob's access.
    r = _run(["memory", "revoke", "--alias", bob_alias, "revoke-note"],
             session_id=alice_session, memory_root=memory_root)
    assert r.returncode == 0, f"revoke failed: {r.stderr}"

    # Bob's read now fails closed.
    r = _read("revoke-note", memory_root, bob_session,
              extra=["--alias", alice_alias])
    assert r.returncode != 0, "revoked entry should not be readable"

    # Alice still sees the entry, but Bob is no longer in shared_with.
    entries = _list(memory_root, alice_session)
    assert bob_alias not in entries[0]["shared_with"]


def test_memory_isolated_per_alias():
    """Each alias only sees its own entries in a plain list."""
    memory_root = _memory_root()

    alice_session = "mem-iso-alice-sess"
    alice_alias = "mem-iso-alice"
    bob_session = "mem-iso-bob-sess"
    bob_alias = "mem-iso-bob"

    _register(alice_alias, alice_session, memory_root)
    _register(bob_alias, bob_session, memory_root)

    _write("alice-note", "alice only", memory_root=memory_root,
           session_id=alice_session, alias=alice_alias)
    _write("bob-note", "bob only", memory_root=memory_root,
           session_id=bob_session, alias=bob_alias)

    alice_entries = _list(memory_root, alice_session)
    assert [e["name"] for e in alice_entries] == ["alice-note"]

    bob_entries = _list(memory_root, bob_session)
    assert [e["name"] for e in bob_entries] == ["bob-note"]

    assert os.path.isfile(_entry_path(memory_root, alice_alias, "alice-note"))
    assert os.path.isfile(_entry_path(memory_root, bob_alias, "bob-note"))
