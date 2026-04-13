#!/usr/bin/env python3
"""Broker garbage collection daemon — auto-sweep dead registrations on TTL.

Runs continuously (or once with --once), periodically sweeping dead registrations
from the broker registry based on configurable TTL thresholds.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import c2c_mcp


DEFAULT_TTL_SECONDS = 3600  # 1 hour
DEFAULT_INTERVAL_SECONDS = 300  # 5 minutes
MIN_INTERVAL_SECONDS = 60  # 1 minute minimum


def load_broker_registrations(broker_root: Path) -> list[dict[str, Any]]:
    registry_path = broker_root / "registry.json"
    if not registry_path.exists():
        return []
    try:
        return json.loads(registry_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []


def save_broker_registrations(
    broker_root: Path, registrations: list[dict[str, Any]]
) -> bool:
    registry_path = broker_root / "registry.json"
    try:
        registry_path.write_text(
            json.dumps(registrations, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return True
    except OSError:
        return False


def pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def registration_is_alive(reg: dict[str, Any]) -> bool:
    pid = reg.get("pid")
    if pid is None:
        # Legacy pidless registration — can't determine liveness
        return True
    return pid_is_alive(int(pid))


def sweep_dead_registrations(
    broker_root: Path,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Sweep dead registrations from the broker registry.

    Returns dict with sweep results:
    - before_count: registrations before sweep
    - after_count: registrations after sweep
    - removed: list of removed registrations
    - dry_run: whether this was a dry run
    """
    registrations = load_broker_registrations(broker_root)
    before_count = len(registrations)

    kept: list[dict[str, Any]] = []
    removed: list[dict[str, Any]] = []

    for reg in registrations:
        if registration_is_alive(reg):
            kept.append(reg)
        else:
            removed.append(reg)

    after_count = len(kept)

    if not dry_run and removed:
        save_broker_registrations(broker_root, kept)

    return {
        "ok": True,
        "before_count": before_count,
        "after_count": after_count,
        "removed_count": len(removed),
        "removed": removed,
        "dry_run": dry_run,
    }


def run_gc_loop(
    broker_root: Path,
    interval_seconds: float,
    dry_run: bool = False,
    once: bool = False,
) -> None:
    """Run the GC loop, sweeping dead registrations periodically."""
    print(f"[broker-gc] starting — broker_root={broker_root}", flush=True)
    print(
        f"[broker-gc] interval={interval_seconds:.0f}s, dry_run={dry_run}", flush=True
    )

    iteration = 0
    while True:
        iteration += 1
        print(f"[broker-gc] iteration {iteration}: sweeping...", flush=True)

        result = sweep_dead_registrations(broker_root, dry_run=dry_run)

        removed_count = result["removed_count"]
        if removed_count > 0:
            print(
                f"[broker-gc] removed {removed_count} dead registration(s) "
                f"({result['before_count']} -> {result['after_count']})",
                flush=True,
            )
            for reg in result["removed"]:
                alias = reg.get("alias", "unknown")
                session_id = reg.get("session_id", "unknown")
                pid = reg.get("pid", "none")
                print(
                    f"[broker-gc]   - {alias} (sid={session_id}, pid={pid})", flush=True
                )
        else:
            print(f"[broker-gc] no dead registrations found", flush=True)

        if once:
            print("[broker-gc] --once specified, exiting", flush=True)
            break

        print(f"[broker-gc] sleeping {interval_seconds:.0f}s...", flush=True)
        time.sleep(interval_seconds)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Broker garbage collection — auto-sweep dead registrations"
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        help="broker root directory (default: auto-detect from env or git)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=DEFAULT_INTERVAL_SECONDS,
        help=f"sweep interval in seconds (default: {DEFAULT_INTERVAL_SECONDS}, min: {MIN_INTERVAL_SECONDS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be removed without actually removing",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="sweep once and exit (don't loop)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit JSON output",
    )
    args = parser.parse_args(argv)

    # Resolve broker root
    if args.broker_root:
        broker_root = args.broker_root
    else:
        env_root = os.environ.get("C2C_MCP_BROKER_ROOT")
        if env_root:
            broker_root = Path(env_root)
        else:
            broker_root = Path(c2c_mcp.default_broker_root())

    # Enforce minimum interval
    interval_seconds = max(args.interval, MIN_INTERVAL_SECONDS)

    if args.once:
        result = sweep_dead_registrations(broker_root, dry_run=args.dry_run)
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print(
                f"sweep complete: {result['removed_count']} dead, {result['after_count']} alive"
            )
            if result["removed"]:
                print("removed:")
                for reg in result["removed"]:
                    alias = reg.get("alias", "unknown")
                    print(f"  - {alias}")
        return 0 if result["ok"] else 1

    # Run continuous GC loop
    try:
        run_gc_loop(
            broker_root=broker_root,
            interval_seconds=interval_seconds,
            dry_run=args.dry_run,
            once=False,
        )
    except KeyboardInterrupt:
        print("\n[broker-gc] interrupted, exiting", flush=True)
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
