#!/usr/bin/env python3
"""Broker garbage collection daemon — auto-sweep dead registrations on TTL.

Runs continuously (or once with --once), periodically sweeping dead registrations
from the broker registry based on configurable TTL thresholds.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import time
from pathlib import Path
from typing import Any

import c2c_mcp


DEFAULT_TTL_SECONDS = 3600  # 1 hour
DEFAULT_INTERVAL_SECONDS = 300  # 5 minutes
MIN_INTERVAL_SECONDS = 60  # 1 minute minimum
DEFAULT_DEAD_LETTER_TTL_SECONDS = 7 * 24 * 3600  # 7 days


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


@contextlib.contextmanager
def with_dead_letter_lock(broker_root: Path):
    """Exclusive POSIX fcntl lock on dead-letter.jsonl.lock sidecar.

    Uses fcntl.lockf (POSIX), not fcntl.flock (BSD), so it interlocks
    with OCaml's Unix.lockf on the same sidecar file.
    """
    lock_path = broker_root / "dead-letter.jsonl.lock"
    broker_root.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.lockf(fd, fcntl.LOCK_UN)
        except Exception:
            pass
        os.close(fd)


def purge_old_dead_letter(
    broker_root: Path,
    ttl_seconds: float = DEFAULT_DEAD_LETTER_TTL_SECONDS,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Remove dead-letter entries older than ttl_seconds.

    Returns dict with:
    - before_count: lines read
    - after_count: lines kept
    - purged_count: lines removed
    - dry_run: whether this was a dry run
    """
    dl_path = broker_root / "dead-letter.jsonl"
    if not dl_path.exists():
        return {"ok": True, "before_count": 0, "after_count": 0, "purged_count": 0, "dry_run": dry_run}

    cutoff = time.time() - ttl_seconds
    kept: list[str] = []
    purged = 0

    with with_dead_letter_lock(broker_root):
        try:
            lines = dl_path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return {"ok": False, "before_count": 0, "after_count": 0, "purged_count": 0, "dry_run": dry_run}

        before_count = sum(1 for l in lines if l.strip())
        for line in lines:
            stripped = line.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
                deleted_at = record.get("deleted_at")
                if isinstance(deleted_at, (int, float)) and deleted_at < cutoff:
                    purged += 1
                    continue
            except (json.JSONDecodeError, KeyError):
                pass
            kept.append(line)

        after_count = len(kept)
        if not dry_run and purged > 0:
            try:
                content = "\n".join(kept)
                if content and not content.endswith("\n"):
                    content += "\n"
                dl_path.write_text(content, encoding="utf-8")
            except OSError as exc:
                return {"ok": False, "error": str(exc), "before_count": before_count,
                        "after_count": before_count, "purged_count": 0, "dry_run": dry_run}

    return {"ok": True, "before_count": before_count, "after_count": after_count,
            "purged_count": purged, "dry_run": dry_run}


def run_gc_loop(
    broker_root: Path,
    interval_seconds: float,
    dry_run: bool = False,
    once: bool = False,
    dead_letter_ttl: float = DEFAULT_DEAD_LETTER_TTL_SECONDS,
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
        dl_result = purge_old_dead_letter(broker_root, ttl_seconds=dead_letter_ttl, dry_run=dry_run)

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

        dl_purged = dl_result.get("purged_count", 0)
        if dl_purged > 0:
            print(
                f"[broker-gc] purged {dl_purged} stale dead-letter entry/entries "
                f"(>{DEFAULT_DEAD_LETTER_TTL_SECONDS // 86400}d old, "
                f"{dl_result['before_count']} -> {dl_result['after_count']})",
                flush=True,
            )

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
        "--dead-letter-ttl",
        type=float,
        default=DEFAULT_DEAD_LETTER_TTL_SECONDS,
        dest="dead_letter_ttl",
        help=f"dead-letter TTL in seconds (default: {DEFAULT_DEAD_LETTER_TTL_SECONDS}, i.e. 7 days)",
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
        dl_result = purge_old_dead_letter(
            broker_root,
            ttl_seconds=args.dead_letter_ttl,
            dry_run=args.dry_run,
        )
        combined = {**result, "dead_letter": dl_result}
        if args.json:
            print(json.dumps(combined, indent=2))
        else:
            print(
                f"sweep complete: {result['removed_count']} dead, {result['after_count']} alive"
            )
            if result["removed"]:
                print("removed:")
                for reg in result["removed"]:
                    alias = reg.get("alias", "unknown")
                    print(f"  - {alias}")
            dl_purged = dl_result.get("purged_count", 0)
            ttl_days = int(args.dead_letter_ttl) // 86400
            if dl_purged > 0:
                print(f"dead-letter: purged {dl_purged} stale entries (>{ttl_days}d old)")
            else:
                print(f"dead-letter: {dl_result.get('before_count', 0)} entries, none expired")
        ok = result["ok"] and dl_result.get("ok", True)
        return 0 if ok else 1

    # Run continuous GC loop
    try:
        run_gc_loop(
            broker_root=broker_root,
            interval_seconds=interval_seconds,
            dry_run=args.dry_run,
            once=False,
            dead_letter_ttl=args.dead_letter_ttl,
        )
    except KeyboardInterrupt:
        print("\n[broker-gc] interrupted, exiting", flush=True)
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
