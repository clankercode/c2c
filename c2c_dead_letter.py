#!/usr/bin/env python3
"""Inspect `.git/c2c/mcp/dead-letter.jsonl` — the preserved-content file the
MCP broker `sweep` tool writes when it deletes a non-empty orphan inbox.

Usage:
    c2c_dead_letter.py                          # summary by to_alias
    c2c_dead_letter.py --list                   # one-line per record
    c2c_dead_letter.py --show                   # full pretty-printed records
    c2c_dead_letter.py --to storm-storm         # filter by recipient alias
    c2c_dead_letter.py --from-sid <sid>         # filter by origin session_id
    c2c_dead_letter.py --json                   # machine-readable JSON
    c2c_dead_letter.py --replay --to <alias>    # re-send filtered records
                                                # via c2c-send broker path
    c2c_dead_letter.py --replay --dry-run       # print what would be sent
    c2c_dead_letter.py --purge-orphans          # remove entries whose to_alias
                                                # is unregistered for >1h
    c2c_dead_letter.py --purge-all              # remove all entries

Read-only by default. `--replay` invokes `c2c_send.send_to_alias` for each
filtered record, which will go through the standard broker resolution path
(YAML registry first, broker registry fallback). Dead-letter.jsonl is not
modified — replay is idempotent; operators can re-run after transient
failures.

`--purge-orphans` removes entries older than --orphan-ttl seconds whose
to_alias (stripping @room_id suffix) is no longer in the registry. This
cleans up transient aliases that will never re-register. Safe to run at any
time; aliases that ARE registered are always preserved for redelivery.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def resolve_broker_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    try:
        common_dir = subprocess.check_output(
            ["git", "rev-parse", "--git-common-dir"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        sys.exit("fatal: not inside a git repository (use --root)")
    return (Path(common_dir) / "c2c" / "mcp").resolve()


def load_records(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for lineno, raw in enumerate(path.read_text().splitlines(), start=1):
        if not raw.strip():
            continue
        try:
            out.append(json.loads(raw))
        except json.JSONDecodeError as exc:
            print(
                f"warning: line {lineno} is not valid JSON: {exc}",
                file=sys.stderr,
            )
    return out


def filter_records(
    records: list[dict],
    to_alias: str | None,
    from_sid: str | None,
) -> list[dict]:
    out = []
    for rec in records:
        msg = rec.get("message") or {}
        if to_alias and msg.get("to_alias") != to_alias:
            continue
        if from_sid and rec.get("from_session_id") != from_sid:
            continue
        out.append(rec)
    return out


def format_ts(ts) -> str:
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    except (TypeError, ValueError):
        return str(ts)


def print_summary(records: list[dict]) -> None:
    by_to: dict[str, int] = {}
    by_from: dict[str, int] = {}
    by_orig_sid: dict[str, int] = {}
    for rec in records:
        msg = rec.get("message") or {}
        by_to[msg.get("to_alias", "?")] = by_to.get(msg.get("to_alias", "?"), 0) + 1
        by_from[msg.get("from_alias", "?")] = by_from.get(msg.get("from_alias", "?"), 0) + 1
        by_orig_sid[rec.get("from_session_id", "?")] = (
            by_orig_sid.get(rec.get("from_session_id", "?"), 0) + 1
        )
    print(f"dead-letter records: {len(records)}")
    if not records:
        return
    print()
    print("  by to_alias:")
    for alias, count in sorted(by_to.items(), key=lambda kv: -kv[1]):
        print(f"    {alias:<20} {count}")
    print()
    print("  by from_alias:")
    for alias, count in sorted(by_from.items(), key=lambda kv: -kv[1]):
        print(f"    {alias:<20} {count}")
    print()
    print("  by origin session_id (deleted inbox):")
    for sid, count in sorted(by_orig_sid.items(), key=lambda kv: -kv[1]):
        print(f"    {sid:<40} {count}")


def print_list(records: list[dict]) -> None:
    for rec in records:
        msg = rec.get("message") or {}
        ts = format_ts(rec.get("deleted_at"))
        body = msg.get("content", "")
        if len(body) > 70:
            body = body[:67] + "..."
        print(
            f"{ts}  {msg.get('from_alias','?'):<18} -> {msg.get('to_alias','?'):<18}  {body}"
        )


def replay_records(records: list[dict], dry_run: bool, broker_root: Path) -> dict:
    """Re-send each record via c2c_send.send_to_alias.

    The dead-letter file itself is never modified — replay is idempotent
    and safe to retry on transient failures. Returns a summary dict.
    """
    import c2c_send

    sent = 0
    failed = []
    old_broker_root = os.environ.get("C2C_MCP_BROKER_ROOT")
    os.environ["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    try:
        for i, rec in enumerate(records, start=1):
            msg = rec.get("message") or {}
            to_alias = msg.get("to_alias", "")
            content = msg.get("content", "")
            if not to_alias:
                failed.append({"index": i, "reason": "record has no to_alias"})
                continue
            try:
                result = c2c_send.send_to_alias(to_alias, content, dry_run=dry_run)
                sent += 1
                if dry_run:
                    print(f"  [DRY] {i}. -> {to_alias}: {result.get('to', '?')}")
                else:
                    print(f"  sent {i}. -> {to_alias}")
            except Exception as exc:
                failed.append({"index": i, "to_alias": to_alias, "error": str(exc)})
                print(f"  FAIL {i}. -> {to_alias}: {exc}", file=sys.stderr)
    finally:
        if old_broker_root is None:
            os.environ.pop("C2C_MCP_BROKER_ROOT", None)
        else:
            os.environ["C2C_MCP_BROKER_ROOT"] = old_broker_root
    return {
        "replay_mode": "dry-run" if dry_run else "live",
        "total_considered": len(records),
        "sent": sent,
        "failed": failed,
    }


def print_show(records: list[dict]) -> None:
    for i, rec in enumerate(records):
        msg = rec.get("message") or {}
        print(f"--- record {i + 1}/{len(records)} ---")
        print(f"  deleted_at:       {format_ts(rec.get('deleted_at'))}")
        print(f"  from_session_id:  {rec.get('from_session_id')}")
        print(f"  from_alias:       {msg.get('from_alias')}")
        print(f"  to_alias:         {msg.get('to_alias')}")
        print(f"  content:")
        for line in str(msg.get("content", "")).splitlines() or [""]:
            print(f"    {line}")
        print()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="broker directory (default: $(git rev-parse --git-common-dir)/c2c/mcp)")
    parser.add_argument("--list", action="store_true", help="one-line per record")
    parser.add_argument("--show", action="store_true", help="full records, pretty")
    parser.add_argument("--json", action="store_true", help="raw JSON output")
    parser.add_argument("--to", metavar="ALIAS", help="filter by recipient alias")
    parser.add_argument("--from-sid", metavar="SID", help="filter by origin session_id")
    parser.add_argument(
        "--replay",
        action="store_true",
        help="re-send filtered records via c2c_send.send_to_alias",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="with --replay/--purge-orphans/--purge-all: report without modifying",
    )
    parser.add_argument(
        "--purge-orphans",
        action="store_true",
        help="remove entries whose to_alias is unregistered for longer than --orphan-ttl",
    )
    parser.add_argument(
        "--orphan-ttl",
        type=float,
        default=3600.0,
        metavar="SECONDS",
        help="minimum age for orphan pruning (default: 3600 = 1h)",
    )
    parser.add_argument(
        "--purge-all",
        action="store_true",
        help="remove ALL dead-letter entries (operator override)",
    )
    args = parser.parse_args(argv)

    root = resolve_broker_root(args.root)
    path = root / "dead-letter.jsonl"

    # --- purge-orphans mode ---
    if args.purge_orphans:
        try:
            import c2c_broker_gc
            result = c2c_broker_gc.purge_orphan_dead_letter(
                root, ttl_seconds=args.orphan_ttl, dry_run=args.dry_run
            )
        except ImportError:
            print("error: c2c_broker_gc not available", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            purged = result.get("purged_count", 0)
            before = result.get("before_count", 0)
            after = result.get("after_count", 0)
            dry_str = " (dry-run)" if args.dry_run else ""
            if purged:
                print(f"Purged {purged} orphan entry/entries{dry_str} ({before} → {after} remaining).")
            else:
                print(f"No orphan entries (alias unregistered >{int(args.orphan_ttl)}s). {before} entries remain.")
        return 0 if result.get("ok", True) else 1

    # --- purge-all mode ---
    if args.purge_all:
        if not path.exists():
            print("Dead-letter queue is already empty.")
            return 0
        records_all = load_records(path)
        count = len(records_all)
        if args.dry_run:
            if args.json:
                print(json.dumps({"dry_run": True, "would_purge": count}))
            else:
                print(f"dry-run: would remove {count} entries.")
            return 0
        try:
            import c2c_broker_gc
            with c2c_broker_gc.with_dead_letter_lock(root):
                path.write_text("", encoding="utf-8")
        except ImportError:
            path.write_text("", encoding="utf-8")
        if args.json:
            print(json.dumps({"ok": True, "purged_count": count}))
        else:
            print(f"Purged all {count} dead-letter entries.")
        return 0

    records = load_records(path)
    filtered = filter_records(records, args.to, getattr(args, "from_sid"))

    if args.json:
        print(json.dumps(
            {
                "dead_letter_path": str(path),
                "total_records": len(records),
                "filtered_records": len(filtered),
                "records": filtered,
            },
            indent=2,
        ))
        return 0

    print(f"dead-letter path: {path}")
    if not path.exists():
        print("  (file does not exist — nothing preserved yet)")
        return 0
    print(f"total records:    {len(records)}")
    if args.to or args.from_sid:
        print(f"filtered:         {len(filtered)}")
    print()

    if args.replay:
        if not (args.to or args.from_sid):
            print(
                "refusing to replay without a --to or --from-sid filter "
                "(use --to '' to bypass if you really want to replay all)",
                file=sys.stderr,
            )
            return 2
        result = replay_records(filtered, dry_run=args.dry_run, broker_root=root)
        print()
        print(f"replay result: {result['sent']}/{result['total_considered']} sent, {len(result['failed'])} failed")
        return 0 if not result["failed"] else 1

    if args.show:
        print_show(filtered)
    elif args.list:
        print_list(filtered)
    else:
        print_summary(filtered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
