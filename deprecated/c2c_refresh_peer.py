#!/usr/bin/env python3
"""Refresh a stale broker registration to point at a new live PID.

Usage:
    c2c refresh-peer <alias-or-session-id> --pid <pid>
    c2c refresh-peer <alias-or-session-id> # re-register self using current session

Problem this solves (from .collab/findings/):
  OpenCode (or any client) can drift to a dead one-shot process PID while a
  durable TUI remains alive. Direct sends then fail with "recipient is not alive"
  even though the agent is running.  This command updates the registry row to
  point at the correct live PID without requiring Python import incantations.

The command reads the live process's /proc/<pid>/stat start_time for liveness
tracking. If the PID does not appear in /proc, it refuses to update to avoid
creating a worse stale registration.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import c2c_broker_gc
import c2c_mcp  # noqa: F401 (runtime-only module with no stub)


def default_broker_root() -> Path:
    return Path(c2c_mcp.default_broker_root())


def refresh_peer(
    alias: str,
    pid: int | None,
    broker_root: Path,
    *,
    session_id: str | None = None,
    dry_run: bool = False,
    json_out: bool = False,
) -> dict:
    # Validate the PID is actually alive before touching the registry
    start_time: int | None = None
    if pid is not None:
        if not os.path.exists(f"/proc/{pid}"):
            raise SystemExit(
                f"PID {pid} is not alive (/proc/{pid} does not exist). "
                "Refusing to update registration to a dead PID."
            )
        start_time = c2c_mcp.read_pid_start_time(pid)

    with c2c_broker_gc.with_registry_lock(broker_root):
        registrations = c2c_broker_gc.load_broker_registrations(broker_root)

        # Find the matching registration
        match_idx = None
        matched_by = "alias"
        for i, reg in enumerate(registrations):
            if str(reg.get("alias", "")) == alias:
                match_idx = i
                break
        if match_idx is None and session_id:
            for i, reg in enumerate(registrations):
                if str(reg.get("session_id", "")) == session_id:
                    match_idx = i
                    matched_by = "session_id"
                    break

        if match_idx is None:
            raise SystemExit(
                f"No registration found for alias or session_id '{alias}'. "
                "Use 'c2c list --json' to see registered peers."
            )

        old_reg = registrations[match_idx]
        resolved_alias = str(old_reg.get("alias", alias))
        old_pid = old_reg.get("pid")
        old_start_time = old_reg.get("pid_start_time")

        if pid is None:
            # No PID given: check if the current registration is already alive
            if c2c_mcp.broker_registration_is_alive(old_reg):
                result = {
                    "alias": resolved_alias,
                    "matched_by": matched_by,
                    "status": "already_alive",
                    "pid": old_pid,
                    "pid_start_time": old_start_time,
                }
                if json_out:
                    print(json.dumps(result, indent=2))
                else:
                    print(
                        f"Registration for '{resolved_alias}' is already alive "
                        f"(pid={old_pid}). No change needed."
                    )
                return result
            raise SystemExit(
                f"Registration for '{resolved_alias}' has dead PID {old_pid}. "
                "Provide --pid <live-pid> to refresh it."
            )

        old_session_id = old_reg.get("session_id")
        session_id_changed = session_id is not None and session_id != old_session_id

        if dry_run:
            result: dict = {
                "alias": resolved_alias,
                "matched_by": matched_by,
                "status": "dry_run",
                "old_pid": old_pid,
                "new_pid": pid,
                "new_pid_start_time": start_time,
            }
            if session_id_changed:
                result["old_session_id"] = old_session_id
                result["new_session_id"] = session_id
            if json_out:
                print(json.dumps(result, indent=2))
            else:
                session_note = (
                    f", session_id {old_session_id!r} -> {session_id!r}"
                    if session_id_changed
                    else ""
                )
                print(
                    f"[dry-run] Would update '{resolved_alias}': "
                    f"pid {old_pid} -> {pid} "
                    f"(start_time={start_time})"
                    f"{session_note}"
                )
            return result

        # Apply the update
        new_reg = dict(old_reg)
        new_reg["pid"] = pid
        if start_time is not None:
            new_reg["pid_start_time"] = start_time
        else:
            new_reg.pop("pid_start_time", None)
        if session_id_changed:
            new_reg["session_id"] = session_id
        registrations[match_idx] = new_reg

        c2c_broker_gc.save_broker_registrations(broker_root, registrations)

    result = {
        "alias": resolved_alias,
        "matched_by": matched_by,
        "status": "updated",
        "old_pid": old_pid,
        "new_pid": pid,
        "new_pid_start_time": start_time,
    }
    if session_id_changed:
        result["old_session_id"] = old_session_id
        result["new_session_id"] = session_id
    if json_out:
        print(json.dumps(result, indent=2))
    else:
        session_note = (
            f", session_id {old_session_id!r} -> {session_id!r}"
            if session_id_changed
            else ""
        )
        print(
            f"Updated '{resolved_alias}': pid {old_pid} -> {pid} "
            f"(start_time={start_time})"
            f"{session_note}"
        )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Refresh a stale broker registration to a new live PID.",
        epilog=(
            "Example: c2c refresh-peer opencode-local --pid $(pgrep -n opencode)\n"
            "\nThis is an operator escape hatch for when a managed client's\n"
            "registration drifted to a dead one-shot process PID while the\n"
            "durable TUI session remains alive.\n"
            "\nUse --session-id to also correct a wrong session_id in the registry,\n"
            "e.g. when a previous session's entry was left behind with the same alias."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "alias",
        metavar="alias",
        help="alias of the peer whose registration to refresh; if --session-id "
        "is provided and the alias is stale, that session_id is also accepted",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="new live PID to point the registration at (required if current PID is dead)",
    )
    parser.add_argument(
        "--session-id",
        default=None,
        help="correct session_id to write into the registry (fixes session_id drift)",
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        default=None,
        help="broker root directory (default: from C2C_MCP_BROKER_ROOT or repo default)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="show what would change without writing anything",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    args = parser.parse_args(argv)

    broker_root = (
        args.broker_root.resolve()
        if args.broker_root
        else Path(os.environ.get("C2C_MCP_BROKER_ROOT") or default_broker_root())
    )

    try:
        refresh_peer(
            args.alias,
            args.pid,
            broker_root,
            session_id=args.session_id,
            dry_run=args.dry_run,
            json_out=args.json,
        )
    except SystemExit as e:
        print(f"error: {e}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
