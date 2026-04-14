#!/usr/bin/env python3
"""Send a one-shot notify-only PTY nudge to a peer with a stale inbox.

Usage:
    c2c wake-peer <alias>
    c2c wake-peer <alias> --dry-run
    c2c wake-peer <alias> --json

Resolves the alias in the broker registry, checks liveness, and runs
c2c_deliver_inbox.py --notify-only --once to inject a poll_inbox prompt
into the peer's terminal. This is the manual escape-hatch when a managed
session's deliver daemon or poker has stopped and messages are piling up.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import c2c_mcp


def redact_deliver_result(result: dict) -> dict:
    def sanitize(value):
        if isinstance(value, dict):
            sanitized = {key: sanitize(item) for key, item in value.items()}
            messages = value.get("messages")
            if isinstance(messages, list):
                if "message_count" not in value:
                    sanitized["message_count"] = len(messages)
                sanitized["messages"] = []
                sanitized["messages_redacted"] = True
            return sanitized
        if isinstance(value, list):
            return [sanitize(item) for item in value]
        return value

    return sanitize(result)


def default_broker_root() -> Path:
    return Path(c2c_mcp.default_broker_root())


def wake_peer(
    alias: str,
    *,
    broker_root: Path,
    dry_run: bool = False,
    json_out: bool = False,
) -> int:
    registry_path = broker_root / "registry.json"
    registrations = c2c_mcp.load_broker_registrations(registry_path)

    reg = next(
        (r for r in registrations if r.get("alias") == alias),
        None,
    )
    if reg is None:
        error = f"alias not found in registry: {alias}"
        if json_out:
            print(json.dumps({"ok": False, "error": error}, indent=2))
        else:
            print(error, file=sys.stderr)
        return 1

    session_id = reg.get("session_id", "")
    pid = reg.get("pid")
    pid_start_time = reg.get("pid_start_time")

    # Liveness check
    alive = False
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, 0)
            alive = True
        except (ProcessLookupError, PermissionError):
            pass

    if alive and pid_start_time is not None:
        current_start_time = c2c_mcp.read_pid_start_time(pid)
        if current_start_time is not None and current_start_time != pid_start_time:
            alive = False

    if not alive:
        error = f"peer {alias!r} is not alive (pid={pid})"
        if json_out:
            print(json.dumps({"ok": False, "error": error, "alias": alias, "session_id": session_id}, indent=2))
        else:
            print(error, file=sys.stderr)
        return 1

    deliver_cmd = [
        sys.executable,
        str(Path(__file__).resolve().parent / "c2c_deliver_inbox.py"),
        "--client",
        "generic",
        "--pid",
        str(pid),
        "--session-id",
        session_id,
        "--notify-only",
    ]
    if dry_run:
        deliver_cmd.append("--dry-run")
    if json_out:
        deliver_cmd.append("--json")

    if dry_run and not json_out:
        print(f"[dry-run] Would wake {alias!r} (pid {pid}, session {session_id})")
        print(f"[dry-run] Command: {' '.join(deliver_cmd)}")
        return 0

    result = subprocess.run(deliver_cmd, capture_output=True, text=True)
    ok = result.returncode == 0

    if json_out:
        output = {
            "ok": ok,
            "alias": alias,
            "session_id": session_id,
            "pid": pid,
            "deliver_returncode": result.returncode,
        }
        if result.stdout.strip():
            try:
                output["deliver_result"] = redact_deliver_result(
                    json.loads(result.stdout)
                )
            except json.JSONDecodeError:
                output["deliver_stdout"] = result.stdout.strip()
        if result.stderr.strip():
            output["deliver_stderr"] = result.stderr.strip()
        print(json.dumps(output, indent=2))
    else:
        if ok:
            print(f"✓ Wake nudge sent to {alias!r} (pid {pid})")
        else:
            print(f"✗ Failed to wake {alias!r} (pid {pid})", file=sys.stderr)
            if result.stderr.strip():
                print(result.stderr.strip(), file=sys.stderr)

    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Send a one-shot notify-only PTY nudge to a peer with a stale inbox."
    )
    parser.add_argument("alias", help="alias of the peer to wake")
    parser.add_argument(
        "--broker-root",
        type=Path,
        default=None,
        help="broker root directory (default: auto-detect)",
    )
    parser.add_argument("--dry-run", action="store_true", help="show what would be done")
    parser.add_argument("--json", action="store_true", help="emit JSON output")
    args = parser.parse_args(argv)

    broker_root = args.broker_root or default_broker_root()
    return wake_peer(
        args.alias,
        broker_root=broker_root,
        dry_run=args.dry_run,
        json_out=args.json,
    )


if __name__ == "__main__":
    raise SystemExit(main())
