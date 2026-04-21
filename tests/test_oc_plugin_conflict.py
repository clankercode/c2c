"""
Tests for OpenCode plugin conflict detection (checkConflictingInstances).

Verifies that when two c2c-managed OpenCode instances share the same broker
and one is alive, the second one's plugin startup throws FATAL rather than
silently adopting the peer's session (the cross-contamination bug fixed in
7b063ac; see finding 2026-04-21T09-00-00Z-coordinator1-oc-focus-test-...md).

These tests exercise the logic by constructing mock instance dirs and checking
the conflict-detection helper function embedded in the plugin.  We call a
thin Python shim that reproduces the same filesystem scan + /proc liveness
check that the TypeScript plugin performs.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import types
from pathlib import Path


# ---------------------------------------------------------------------------
# Inline Python reimplementation of checkConflictingInstances for unit tests.
# Must stay in sync with the TypeScript logic in .opencode/plugins/c2c.ts.
# ---------------------------------------------------------------------------

class ConflictError(RuntimeError):
    pass


def check_conflicting_instances(
    session_id: str,
    broker_root: str,
    configured_oc_session_id: str,
    auto_kickoff: bool,
    instances_dir: Path,
) -> None:
    """Raises ConflictError if a conflicting alive peer instance is found."""
    if not instances_dir.exists():
        return

    for name in instances_dir.iterdir():
        if name.name == session_id:
            continue

        state_file = name / "oc-plugin-state.json"
        config_file = name / "config.json"
        if not state_file.exists():
            continue

        try:
            raw = json.loads(state_file.read_text())
            their_state = raw.get("state", raw)
        except Exception:
            continue

        their_pid = their_state.get("opencode_pid")
        if not their_pid:
            continue

        proc_path = Path(f"/proc/{their_pid}")
        if not proc_path.exists():
            continue  # dead

        their_broker_root = ""
        if config_file.exists():
            try:
                their_broker_root = json.loads(config_file.read_text()).get("broker_root", "")
            except Exception:
                pass

        if broker_root and their_broker_root and their_broker_root != broker_root:
            continue  # different project

        their_alias = their_state.get("c2c_session_id", name.name)
        their_root_oc_session = their_state.get("root_opencode_session_id", "")

        conflict = (
            (auto_kickoff and not configured_oc_session_id)
            or (configured_oc_session_id and their_root_oc_session == configured_oc_session_id)
        )

        if conflict:
            msg = (
                f"FATAL: conflicting c2c opencode instance '{their_alias}' "
                f"(pid {their_pid}) owns session {their_root_oc_session or 'unknown'}. "
                f"Stop it first: c2c stop {their_alias}"
            )
            raise ConflictError(msg)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _write_instance(
    instances_dir: Path,
    name: str,
    pid: int,
    broker_root: str = "/tmp/broker",
    root_oc_session: str = "ses_abc123",
) -> None:
    d = instances_dir / name
    d.mkdir(parents=True, exist_ok=True)
    state = {
        "event": "state.snapshot",
        "ts": "2026-04-21T09:00:00.000Z",
        "state": {
            "c2c_session_id": name,
            "opencode_pid": pid,
            "root_opencode_session_id": root_oc_session,
            "plugin_started_at": "2026-04-21T09:00:00.000Z",
        },
    }
    (d / "oc-plugin-state.json").write_text(json.dumps(state))
    config = {"name": name, "client": "opencode", "broker_root": broker_root}
    (d / "config.json").write_text(json.dumps(config))


def _live_pid() -> int:
    """Return the PID of a real live process (our own)."""
    return os.getpid()


def _dead_pid() -> int:
    """Return a PID that is definitely not alive."""
    return 9_999_999


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_no_conflict_when_instances_dir_missing(tmp_path: Path) -> None:
    # Should not raise if instances dir doesn't exist
    check_conflicting_instances(
        session_id="mine",
        broker_root="/tmp/broker",
        configured_oc_session_id="",
        auto_kickoff=True,
        instances_dir=tmp_path / "nonexistent",
    )


def test_no_conflict_when_peer_is_dead(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "peer-a", pid=_dead_pid())
    check_conflicting_instances(
        session_id="mine",
        broker_root="/tmp/broker",
        configured_oc_session_id="",
        auto_kickoff=True,
        instances_dir=instances_dir,
    )


def test_conflict_raised_for_alive_peer_in_auto_kickoff(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "oc-sitrep-demo", pid=_live_pid(), root_oc_session="ses_sitrep")
    try:
        check_conflicting_instances(
            session_id="oc-focus-test",
            broker_root="/tmp/broker",
            configured_oc_session_id="",
            auto_kickoff=True,
            instances_dir=instances_dir,
        )
        assert False, "Should have raised ConflictError"
    except ConflictError as e:
        assert "oc-sitrep-demo" in str(e)
        assert "ses_sitrep" in str(e)
        assert "c2c stop oc-sitrep-demo" in str(e)


def test_no_conflict_when_different_broker_root(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "peer-b", pid=_live_pid(), broker_root="/tmp/other-broker")
    check_conflicting_instances(
        session_id="mine",
        broker_root="/tmp/broker",
        configured_oc_session_id="",
        auto_kickoff=True,
        instances_dir=instances_dir,
    )


def test_no_conflict_for_self(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "mine", pid=_live_pid())
    check_conflicting_instances(
        session_id="mine",
        broker_root="/tmp/broker",
        configured_oc_session_id="",
        auto_kickoff=True,
        instances_dir=instances_dir,
    )


def test_conflict_on_session_id_clash_in_resume_mode(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "peer-c", pid=_live_pid(), root_oc_session="ses_shared")
    try:
        check_conflicting_instances(
            session_id="mine",
            broker_root="/tmp/broker",
            configured_oc_session_id="ses_shared",
            auto_kickoff=False,
            instances_dir=instances_dir,
        )
        assert False, "Should have raised ConflictError"
    except ConflictError as e:
        assert "ses_shared" in str(e)


def test_no_conflict_when_resume_sessions_differ(tmp_path: Path) -> None:
    instances_dir = tmp_path / "instances"
    _write_instance(instances_dir, "peer-d", pid=_live_pid(), root_oc_session="ses_theirs")
    check_conflicting_instances(
        session_id="mine",
        broker_root="/tmp/broker",
        configured_oc_session_id="ses_mine",
        auto_kickoff=False,
        instances_dir=instances_dir,
    )


# ---------------------------------------------------------------------------
# Pytest entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
