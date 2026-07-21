"""
End-to-end tests for the `c2c schedule` CLI surface.

Covers the lifecycle of per-agent schedule files:
  - set creates a TOML file and returns it via list/show
  - disable/enable toggle the schedule without deleting it
  - rm removes the file
  - set overwrites an existing schedule in place
  - --align and --no-only-when-idle are persisted correctly

Runs in the sealed Docker test environment. Each test gets its own
schedule-root temp directory to avoid cross-test state.
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


def _run(argv, session_id=None, alias=None, schedule_root=None, timeout=10):
    """Run the c2c CLI in the test environment."""
    env = dict(os.environ)
    env["C2C_CLI_FORCE"] = "1"
    env["C2C_IN_DOCKER"] = "1"
    env["C2C_MCP_BROKER_ROOT"] = BROKER_ROOT
    if schedule_root:
        env["C2C_SCHEDULE_ROOT_OVERRIDE"] = schedule_root
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


def _schedule_root():
    """Create a fresh temp directory to use as the schedules root."""
    return tempfile.mkdtemp(prefix="c2c-schedule-e2e-")


def _register(alias, session_id, schedule_root):
    r = _run(["register", "--alias", alias], session_id=session_id, alias=alias,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"register {alias} failed: {r.stderr}"
    return r


def _set(name, *, interval, message="tick", schedule_root, session_id, alias,
         extra=None):
    argv = ["schedule", "set", name, "--interval", interval, "--message", message]
    if extra:
        argv.extend(extra)
    r = _run(argv, session_id=session_id, alias=alias, schedule_root=schedule_root)
    assert r.returncode == 0, f"schedule set {name} failed: {r.stderr}"
    return r


def _list(schedule_root, session_id):
    r = _run(["schedule", "list", "--json"], session_id=session_id,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"schedule list failed: {r.stderr}"
    return json.loads(r.stdout)


def _show(name, schedule_root, session_id):
    r = _run(["schedule", "show", name, "--json"], session_id=session_id,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"schedule show {name} failed: {r.stderr}"
    return json.loads(r.stdout)


def _entry_path(schedule_root, alias, name):
    return os.path.join(schedule_root, alias, f"{name}.toml")


def test_schedule_set_creates_file_and_round_trips():
    """`schedule set` writes a TOML file that list/show read back."""
    schedule_root = _schedule_root()
    session_id = "sched-set-sess"
    alias = "sched-set-alias"

    _register(alias, session_id, schedule_root)
    _set("wake", interval="4m", message="wake — poll inbox", schedule_root=schedule_root,
         session_id=session_id, alias=alias)

    path = _entry_path(schedule_root, alias, "wake")
    assert os.path.isfile(path), f"schedule TOML not created: {path}"

    entries = _list(schedule_root, session_id)
    assert len(entries) == 1
    entry = entries[0]
    assert entry["name"] == "wake"
    assert entry["interval_s"] == 240.0
    assert entry["message"] == "wake — poll inbox"
    assert entry["enabled"] is True
    assert entry["only_when_idle"] is True

    shown = _show("wake", schedule_root, session_id)
    assert shown["name"] == "wake"
    assert shown["interval_s"] == 240.0
    assert shown["message"] == "wake — poll inbox"


def test_schedule_disable_and_enable():
    """disable/enable toggle the schedule state without removing the file."""
    schedule_root = _schedule_root()
    session_id = "sched-toggle-sess"
    alias = "sched-toggle-alias"

    _register(alias, session_id, schedule_root)
    _set("tick", interval="5m", message="tick", schedule_root=schedule_root,
         session_id=session_id, alias=alias)

    r = _run(["schedule", "disable", "tick"], session_id=session_id,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"disable failed: {r.stderr}"

    entries = _list(schedule_root, session_id)
    assert entries[0]["enabled"] is False
    path = _entry_path(schedule_root, alias, "tick")
    assert os.path.isfile(path), "disable should keep the file"

    r = _run(["schedule", "enable", "tick"], session_id=session_id,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"enable failed: {r.stderr}"

    entries = _list(schedule_root, session_id)
    assert entries[0]["enabled"] is True


def test_schedule_rm_removes_file():
    """`schedule rm` deletes the TOML file and drops it from list output."""
    schedule_root = _schedule_root()
    session_id = "sched-rm-sess"
    alias = "sched-rm-alias"

    _register(alias, session_id, schedule_root)
    _set("temp", interval="10m", message="temp", schedule_root=schedule_root,
         session_id=session_id, alias=alias)

    path = _entry_path(schedule_root, alias, "temp")
    assert os.path.isfile(path)

    r = _run(["schedule", "rm", "temp"], session_id=session_id,
             schedule_root=schedule_root)
    assert r.returncode == 0, f"rm failed: {r.stderr}"

    entries = _list(schedule_root, session_id)
    assert entries == []
    assert not os.path.exists(path), "rm should delete the TOML file"


def test_schedule_set_overwrites_existing():
    """Setting the same schedule name updates fields in place."""
    schedule_root = _schedule_root()
    session_id = "sched-overwrite-sess"
    alias = "sched-overwrite-alias"

    _register(alias, session_id, schedule_root)
    _set("wake", interval="4m", message="first", schedule_root=schedule_root,
         session_id=session_id, alias=alias)

    first = _show("wake", schedule_root, session_id)
    assert first["message"] == "first"
    assert first["interval_s"] == 240.0

    _set("wake", interval="10m", message="second", schedule_root=schedule_root,
         session_id=session_id, alias=alias)

    second = _show("wake", schedule_root, session_id)
    assert second["message"] == "second"
    assert second["interval_s"] == 600.0

    entries = _list(schedule_root, session_id)
    assert len(entries) == 1


def test_schedule_aligned_and_busy_flags():
    """--align and --no-only-when-idle are persisted into the TOML file."""
    schedule_root = _schedule_root()
    session_id = "sched-flags-sess"
    alias = "sched-flags-alias"

    _register(alias, session_id, schedule_root)
    _set("hourly", interval="1h", message="hourly tick",
         extra=["--align", "@1h+7m", "--no-only-when-idle"],
         schedule_root=schedule_root, session_id=session_id, alias=alias)

    shown = _show("hourly", schedule_root, session_id)
    assert shown["interval_s"] == 3600.0
    assert shown["align"] == "@1h+7m"
    assert shown["only_when_idle"] is False
    assert shown["enabled"] is True


def test_schedule_isolated_per_alias():
    """Each alias has its own schedule directory; one alias cannot see another's."""
    schedule_root = _schedule_root()

    alice_session = "sched-alice-sess"
    alice_alias = "sched-alice"
    bob_session = "sched-bob-sess"
    bob_alias = "sched-bob"

    _register(alice_alias, alice_session, schedule_root)
    _register(bob_alias, bob_session, schedule_root)

    _set("wake", interval="4m", message="alice wake", schedule_root=schedule_root,
         session_id=alice_session, alias=alice_alias)
    _set("sitrep", interval="1h", message="bob sitrep", schedule_root=schedule_root,
         session_id=bob_session, alias=bob_alias)

    alice_entries = _list(schedule_root, alice_session)
    assert [e["name"] for e in alice_entries] == ["wake"]

    bob_entries = _list(schedule_root, bob_session)
    assert [e["name"] for e in bob_entries] == ["sitrep"]

    assert os.path.isfile(_entry_path(schedule_root, alice_alias, "wake"))
    assert os.path.isfile(_entry_path(schedule_root, bob_alias, "sitrep"))
