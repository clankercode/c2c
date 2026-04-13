#!/usr/bin/env python3
"""Refresh a stale broker registration to point at a new live PID.

Usage:
    c2c refresh-peer <alias> --pid <pid>
    c2c refresh-peer <alias>           # re-register self using current session

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
import tempfile
from pathlib import Path

import c2c_mcp  # noqa: F401 (runtime-only module with no stub)


def default_broker_root() -> Path:
    return Path(c2c_mcp.default_broker_root())


def refresh_peer(
    alias: str,
    pid: int | None,
    broker_root: Path,
    *,
    dry_run: bool = False,
    json_out: bool = False,
) -> dict:
    registry_path = broker_root / "registry.json"

    # Validate the PID is actually alive before touching the registry
    start_time: int | None = None
    if pid is not None:
        if not os.path.exists(f"/proc/{pid}"):
            raise SystemExit(
                f"PID {pid} is not alive (/proc/{pid} does not exist). "
                "Refusing to update registration to a dead PID."
            )
        start_time = c2c_mcp.read_pid_start_time(pid)

    with c2c_mcp.registry_write_lock(registry_path):
        registrations = c2c_mcp.load_broker_registrations(registry_path)

        # Find the matching registration
        match_idx = None
        for i, reg in enumerate(registrations):
            if str(reg.get("alias", "")) == alias:
                match_idx = i
                break

        if match_idx is None:
            raise SystemExit(
                f"No registration found for alias '{alias}'. "
                "Use 'c2c list --json' to see registered peers."
            )

        old_reg = registrations[match_idx]
        old_pid = old_reg.get("pid")
        old_start_time = old_reg.get("pid_start_time")

        if pid is None:
            # No PID given: check if the current registration is already alive
            if c2c_mcp.broker_registration_is_alive(old_reg):
                result = {
                    "alias": alias,
                    "status": "already_alive",
                    "pid": old_pid,
                    "pid_start_time": old_start_time,
                }
                if json_out:
                    print(json.dumps(result, indent=2))
                else:
                    print(
                        f"Registration for '{alias}' is already alive "
                        f"(pid={old_pid}). No change needed."
                    )
                return result
            raise SystemExit(
                f"Registration for '{alias}' has dead PID {old_pid}. "
                "Provide --pid <live-pid> to refresh it."
            )

        if dry_run:
            result = {
                "alias": alias,
                "status": "dry_run",
                "old_pid": old_pid,
                "new_pid": pid,
                "new_pid_start_time": start_time,
            }
            if json_out:
                print(json.dumps(result, indent=2))
            else:
                print(
                    f"[dry-run] Would update '{alias}': "
                    f"pid {old_pid} → {pid} "
                    f"(start_time={start_time})"
                )
            return result

        # Apply the update
        new_reg = dict(old_reg)
        new_reg["pid"] = pid
        if start_time is not None:
            new_reg["pid_start_time"] = start_time
        else:
            new_reg.pop("pid_start_time", None)
        registrations[match_idx] = new_reg

        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=broker_root,
            prefix=f".{registry_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            handle.write(json.dumps(registrations))
            handle.flush()
            os.fsync(handle.fileno())
            temp_path = Path(handle.name)

        os.replace(temp_path, registry_path)

    result = {
        "alias": alias,
        "status": "updated",
        "old_pid": old_pid,
        "new_pid": pid,
        "new_pid_start_time": start_time,
    }
    if json_out:
        print(json.dumps(result, indent=2))
    else:
        print(
            f"Updated '{alias}': pid {old_pid} → {pid} "
            f"(start_time={start_time})"
        )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Refresh a stale broker registration to a new live PID.",
        epilog=(
            "Example: c2c refresh-peer opencode-local --pid $(pgrep -n opencode)\n"
            "\nThis is an operator escape hatch for when a managed client's\n"
            "registration drifted to a dead one-shot process PID while the\n"
            "durable TUI session remains alive."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("alias", help="alias of the peer whose registration to refresh")
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="new live PID to point the registration at (required if current PID is dead)",
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
            dry_run=args.dry_run,
            json_out=args.json,
        )
    except SystemExit as e:
        print(f"error: {e}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
