#!/usr/bin/env python3
"""Read-only preview of what the MCP broker `sweep` tool would drop.

Runs without touching any files. Useful when the live MCP server is older
than the sweep-capable binary and you want to see the pending cleanup
before restarting. Mirrors the logic of `Broker.sweep` in
`ocaml/c2c_mcp.ml` but in Python, against the on-disk broker state.

Usage:
    c2c_sweep_dryrun.py [--json]
    c2c_sweep_dryrun.py --root /path/to/.git/c2c/mcp
"""
import argparse
import json
import subprocess
import sys
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


def load_registry(root: Path) -> list[dict]:
    path = root / "registry.json"
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        sys.exit(f"fatal: registry.json is not valid JSON: {exc}")
    if not isinstance(data, list):
        sys.exit("fatal: registry.json is not a list")
    return data


def pid_is_alive(pid: int | None, start_time: int | None) -> bool:
    """Mirror OCaml `registration_is_alive` semantics.

    None pid -> legacy, treat as alive.
    pid but no /proc/<pid> -> dead.
    pid + start_time and they mismatch -> dead (pid reuse).
    """
    if pid is None:
        return True
    proc = Path(f"/proc/{pid}")
    if not proc.exists():
        return False
    if start_time is None:
        return True
    stat_path = proc / "stat"
    try:
        raw = stat_path.read_text()
    except OSError:
        return False
    # field 22 (1-indexed) is starttime, but comm can contain spaces and
    # parens, so split on the LAST ")".
    try:
        tail = raw[raw.rindex(")") + 2 :]
        fields = tail.split()
        # fields[0] is state; starttime is field index 19 in the tail
        current = int(fields[19])
    except (ValueError, IndexError):
        return False
    return current == start_time


def collect_inboxes(root: Path) -> dict[str, Path]:
    if not root.exists():
        return {}
    out = {}
    for child in root.iterdir():
        name = child.name
        if name.endswith(".inbox.json"):
            sid = name[: -len(".inbox.json")]
            out[sid] = child
    return out


def inbox_message_count(path: Path) -> int | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return len(data) if isinstance(data, list) else None


def archive_activity_counts(root: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    archive_dir = root / "archive"
    if not archive_dir.exists():
        return counts
    for archive_file in archive_dir.glob("*.jsonl"):
        stem = archive_file.stem
        try:
            lines = archive_file.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for raw in lines:
            raw = raw.strip()
            if not raw:
                continue
            counts[stem] = counts.get(stem, 0) + 1
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            for key in ("from_alias", "to_alias"):
                value = entry.get(key)
                if isinstance(value, str) and value:
                    counts[value] = counts.get(value, 0) + 1
    return counts


def registration_activity(reg: dict, activity_counts: dict[str, int]) -> int:
    session_id = str(reg.get("session_id") or "")
    alias = str(reg.get("alias") or "")
    return activity_counts.get(session_id, 0) + activity_counts.get(alias, 0)


def duplicate_pid_entries(registrations: list[dict], root: Path) -> list[dict]:
    activity_counts = archive_activity_counts(root)
    pid_map: dict[int, list[dict]] = {}
    for reg in registrations:
        pid = reg.get("pid")
        if isinstance(pid, int):
            pid_map.setdefault(pid, []).append(reg)

    entries = []
    for pid, rows in sorted(pid_map.items()):
        if len(rows) < 2:
            continue
        aliases = [str(row.get("alias", "")) for row in rows]
        activity_by_alias = {
            str(row.get("alias", "")): registration_activity(row, activity_counts)
            for row in rows
        }
        sibling_has_activity = any(count > 0 for count in activity_by_alias.values())
        likely_stale_aliases = [
            alias
            for alias, count in activity_by_alias.items()
            if sibling_has_activity and count == 0
        ]
        entries.append(
            {
                "pid": pid,
                "aliases": aliases,
                "likely_stale_aliases": likely_stale_aliases,
            }
        )
    return entries


import os
import time as _time_module


def is_provisional_expired(reg: dict, timeout_s: float | None = None) -> bool:
    """Mirror OCaml is_provisional_expired: pid=None, confirmed_at=None, timed-out registered_at."""
    if reg.get("pid") is not None:
        return False
    if reg.get("confirmed_at") is not None:
        return False
    if reg.get("client_type") == "human":
        return False
    registered_at = reg.get("registered_at")
    if registered_at is None:
        return False
    if timeout_s is None:
        try:
            timeout_s = float(os.environ.get("C2C_PROVISIONAL_SWEEP_TIMEOUT", "1800"))
        except ValueError:
            timeout_s = 1800.0
    return (_time_module.time() - registered_at) > timeout_s


def analyze(root: Path) -> dict:
    regs = load_registry(root)
    inboxes = collect_inboxes(root)

    reg_by_sid: dict[str, dict] = {}
    alias_rows: dict[str, list[dict]] = {}
    dead_regs = []
    live_regs = []
    legacy_regs = []
    provisional_expired_regs = []

    for reg in regs:
        sid = reg.get("session_id", "")
        alias = reg.get("alias", "")
        pid = reg.get("pid")
        start_time = reg.get("pid_start_time")
        reg_by_sid[sid] = reg
        alias_rows.setdefault(alias, []).append(reg)
        entry = {
            "session_id": sid,
            "alias": alias,
            "pid": pid,
            "pid_start_time": start_time,
            "inbox_messages": inbox_message_count(inboxes[sid]) if sid in inboxes else None,
            "registered_at": reg.get("registered_at"),
            "confirmed_at": reg.get("confirmed_at"),
        }
        if pid is None:
            if is_provisional_expired(reg):
                provisional_expired_regs.append(entry)
            else:
                legacy_regs.append(entry)
        elif pid_is_alive(pid, start_time):
            live_regs.append(entry)
        else:
            dead_regs.append(entry)

    # Orphan inboxes = on-disk inbox files with no matching reg.
    orphan_inboxes = []
    for sid, path in inboxes.items():
        if sid not in reg_by_sid:
            orphan_inboxes.append(
                {
                    "session_id": sid,
                    "path": str(path),
                    "messages": inbox_message_count(path),
                }
            )

    duplicate_aliases = {
        alias: [r.get("session_id", "") for r in rows]
        for alias, rows in alias_rows.items()
        if len(rows) > 1
    }

    dropped_inboxes = (
        [e["session_id"] for e in dead_regs]
        + [e["session_id"] for e in provisional_expired_regs]
        + [o["session_id"] for o in orphan_inboxes]
    )
    nonempty_drops = [
        o for o in orphan_inboxes if (o["messages"] or 0) > 0
    ] + [e for e in dead_regs if (e["inbox_messages"] or 0) > 0] + [
        e for e in provisional_expired_regs if (e["inbox_messages"] or 0) > 0
    ]

    return {
        "root": str(root),
        "totals": {
            "registrations": len(regs),
            "inbox_files": len(inboxes),
            "live": len(live_regs),
            "legacy_pidless": len(legacy_regs),
            "provisional_expired": len(provisional_expired_regs),
            "dead": len(dead_regs),
            "orphan_inboxes": len(orphan_inboxes),
            "dropped_if_swept": len(dropped_inboxes),
            "nonempty_content_at_risk": len(nonempty_drops),
        },
        "live_regs": live_regs,
        "legacy_pidless_regs": legacy_regs,
        "provisional_expired_regs": provisional_expired_regs,
        "dead_regs": dead_regs,
        "orphan_inboxes": orphan_inboxes,
        "duplicate_pids": duplicate_pid_entries(regs, root),
        "duplicate_aliases": duplicate_aliases,
        "nonempty_content_at_risk": nonempty_drops,
    }


def print_report(report: dict) -> None:
    t = report["totals"]
    print(f"broker root: {report['root']}")
    print()
    print("totals:")
    print(f"  registrations          {t['registrations']}")
    print(f"    live                 {t['live']}")
    print(f"    legacy (pid=None)    {t['legacy_pidless']}")
    print(f"    provisional expired  {t['provisional_expired']}")
    print(f"    dead                 {t['dead']}")
    print(f"  inbox files on disk    {t['inbox_files']}")
    print(f"  orphan inboxes         {t['orphan_inboxes']}")
    print(f"  would drop if swept    {t['dropped_if_swept']}")
    print(f"  NON-EMPTY content risk {t['nonempty_content_at_risk']}")

    if report["duplicate_aliases"]:
        print()
        print("duplicate aliases (routing black-hole risk):")
        for alias, sids in report["duplicate_aliases"].items():
            print(f"  {alias}: {', '.join(sids)}")

    if report.get("duplicate_pids"):
        print()
        print("duplicate PIDs (likely ghost registrations):")
        for entry in report["duplicate_pids"]:
            aliases = ", ".join(entry["aliases"])
            likely = entry.get("likely_stale_aliases") or []
            suffix = f"  likely stale: {', '.join(likely)}" if likely else ""
            print(f"  pid={entry['pid']}: {aliases}{suffix}")

    if report.get("provisional_expired_regs"):
        print()
        print("provisional expired registrations (pid=None, timed out — would be dropped):")
        for reg in report["provisional_expired_regs"]:
            msgs = reg["inbox_messages"]
            suffix = f"  [{msgs} pending msgs]" if msgs else ""
            age = ""
            if reg.get("registered_at"):
                import time as _t
                elapsed = int(_t.time() - reg["registered_at"])
                age = f"  age={elapsed}s"
            print(f"  {reg['alias']:<20} {reg['session_id']}{age}{suffix}")

    if report["dead_regs"]:
        print()
        print("dead registrations (would be dropped):")
        for reg in report["dead_regs"]:
            msgs = reg["inbox_messages"]
            suffix = f"  [{msgs} pending msgs]" if msgs else ""
            print(f"  {reg['alias']:<20} {reg['session_id']}  pid={reg['pid']}{suffix}")

    if report["nonempty_content_at_risk"]:
        print()
        print("NON-EMPTY content that sweep would delete:")
        for item in report["nonempty_content_at_risk"]:
            sid = item.get("session_id")
            msgs = item.get("messages") or item.get("inbox_messages")
            print(f"  {sid}  ({msgs} msgs)")
        print("  -> consider draining these before running sweep.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="broker directory (default: $(git rev-parse --git-common-dir)/c2c/mcp)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = parser.parse_args(argv)

    root = resolve_broker_root(args.root)
    report = analyze(root)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
