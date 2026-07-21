"""
B140 continuation: `c2c rename` moves per-agent schedule and memory dirs.

The main rename e2e tests registry/room updates. This file verifies that
alias rename also renames the `.c2c/schedules/<alias>/` and
`.c2c/memory/<alias>/` directories so the new alias continues to own its
named schedules and memory entries.

Runs in the sealed Docker test environment.
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


def _run(argv, session_id=None, alias=None, root_dir=None, timeout=10):
    """Run the c2c CLI in the test environment."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if root_dir:
        env["C2C_SCHEDULE_ROOT_OVERRIDE"] = os.path.join(root_dir, "schedules")
        env["C2C_MEMORY_ROOT_OVERRIDE"] = os.path.join(root_dir, "memory")
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


def _fresh_root():
    """Create a fresh temp directory containing schedules/ and memory/ roots."""
    return tempfile.mkdtemp(prefix="c2c-rename-sm-")


def _register(alias, session_id, root_dir):
    r = _run(["register", "--alias", alias], session_id=session_id, alias=alias,
             root_dir=root_dir)
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _rename(session_id, new_alias, root_dir):
    return _run(["rename", new_alias, "--json"], session_id=session_id,
                root_dir=root_dir)


def _schedule_path(root_dir, alias, name):
    return os.path.join(root_dir, "schedules", alias, f"{name}.toml")


def _memory_path(root_dir, alias, name):
    return os.path.join(root_dir, "memory", alias, f"{name}.md")


def test_rename_moves_schedule_and_memory_dirs():
    """Rename renames per-agent schedule and memory directories."""
    root_dir = _fresh_root()
    session_id = "ren-sm-sess"
    old_alias = "ren-sm-old"
    new_alias = "ren-sm-new"

    _register(old_alias, session_id, root_dir)

    # Create a schedule and a memory entry under the old alias.
    r = _run(["schedule", "set", "wake", "--interval", "4m",
              "--message", "wake — poll inbox"],
             session_id=session_id, alias=old_alias, root_dir=root_dir)
    assert r.returncode == 0, f"schedule set failed: {r.stderr}"

    r = _run(["memory", "write", "note", "remember this"],
             session_id=session_id, alias=old_alias, root_dir=root_dir)
    assert r.returncode == 0, f"memory write failed: {r.stderr}"

    old_sched = _schedule_path(root_dir, old_alias, "wake")
    old_mem = _memory_path(root_dir, old_alias, "note")
    assert os.path.isfile(old_sched), "schedule file missing before rename"
    assert os.path.isfile(old_mem), "memory file missing before rename"

    # Rename the alias.
    r = _rename(session_id, new_alias, root_dir)
    assert r.returncode == 0, f"rename failed: {r.stderr}"
    result = json.loads(r.stdout)
    assert result.get("ok") is True, f"rename returned ok=false: {result}"

    # Old alias directories should no longer hold the files.
    assert not os.path.exists(old_sched), "old schedule file still exists"
    assert not os.path.exists(old_mem), "old memory file still exists"

    # New alias directories should hold the moved files.
    new_sched = _schedule_path(root_dir, new_alias, "wake")
    new_mem = _memory_path(root_dir, new_alias, "note")
    assert os.path.isfile(new_sched), "schedule file not moved to new alias"
    assert os.path.isfile(new_mem), "memory file not moved to new alias"

    # The schedule still shows under the new alias.
    r = _run(["schedule", "show", "wake", "--json"], session_id=session_id,
             root_dir=root_dir)
    assert r.returncode == 0, f"schedule show after rename failed: {r.stderr}"
    sched_shown = json.loads(r.stdout)
    assert sched_shown["name"] == "wake"

    # The memory entry still reads under the new alias.
    r = _run(["memory", "read", "note", "--json"], session_id=session_id,
             root_dir=root_dir)
    assert r.returncode == 0, f"memory read after rename failed: {r.stderr}"
    mem_shown = json.loads(r.stdout)
    assert mem_shown["content"] == "remember this\n"


def test_rename_rolls_back_partial_schedule_move():
    """If memory move fails, schedule move is rolled back (best-effort)."""
    # Exact rollback coverage requires mocking the filesystem, which is hard
    # from the CLI. This test at least confirms rename succeeds atomically
    # under normal conditions and both directories are consistent.
    root_dir = _fresh_root()
    session_id = "ren-sm-rollback-sess"
    old_alias = "ren-sm-rollback-old"
    new_alias = "ren-sm-rollback-new"

    _register(old_alias, session_id, root_dir)
    _run(["schedule", "set", "tick", "--interval", "1m", "--message", "tick"],
         session_id=session_id, alias=old_alias, root_dir=root_dir)
    _run(["memory", "write", "memo", "memo body"],
         session_id=session_id, alias=old_alias, root_dir=root_dir)

    r = _rename(session_id, new_alias, root_dir)
    assert r.returncode == 0, f"rename failed: {r.stderr}"

    # Consistency: either both old paths are gone or both remain (never half).
    old_sched = _schedule_path(root_dir, old_alias, "tick")
    old_mem = _memory_path(root_dir, old_alias, "memo")
    new_sched = _schedule_path(root_dir, new_alias, "tick")
    new_mem = _memory_path(root_dir, new_alias, "memo")

    old_exists = os.path.exists(old_sched) or os.path.exists(old_mem)
    new_exists = os.path.exists(new_sched) and os.path.exists(new_mem)
    assert not old_exists, "old schedule/memory paths still present after rename"
    assert new_exists, "new schedule/memory paths missing after rename"
