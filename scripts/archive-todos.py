#!/usr/bin/env python3
"""Archive completed (- [x]) items from todo.txt into todo-archive-YYYY-MM.txt.

Usage:
    python3 scripts/archive-todos.py [--dry-run] [--all]

By default, archives completed items that look "old enough" (have a date tag
older than 7 days, or have no date tag). With --all, archives every completed
item regardless of age.

The archive file is todo-archive-<YYYY-MM>.txt (current month). Items are
appended with a header indicating when they were archived.
"""

import argparse
import os
import re
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TODO_PATH = os.path.join(REPO_ROOT, "todo.txt")

DATE_RE = re.compile(r'\b(\d{4}-\d{2}-\d{2})\b')

def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true", help="Print what would be archived, don't write")
    p.add_argument("--all", action="store_true", help="Archive ALL completed items, ignoring age")
    p.add_argument("--cutoff-days", type=int, default=7, help="Age in days before archiving (default: 7)")
    return p.parse_args()

def should_archive(line: str, cutoff_days: int, archive_all: bool) -> bool:
    if not line.strip().startswith("- [x]"):
        return False
    if archive_all:
        return True
    now = datetime.now(timezone.utc).date()
    dates = DATE_RE.findall(line)
    if not dates:
        return True  # no date → archive (old-style entry)
    for d in dates:
        try:
            entry_date = datetime.strptime(d, "%Y-%m-%d").date()
            age = (now - entry_date).days
            if age >= cutoff_days:
                return True
        except ValueError:
            pass
    return False  # has a recent date → keep

def main():
    args = parse_args()

    with open(TODO_PATH, "r") as f:
        lines = f.readlines()

    keep = []
    archive = []

    for line in lines:
        if should_archive(line, args.cutoff_days, args.all):
            archive.append(line)
        else:
            keep.append(line)

    if not archive:
        print("Nothing to archive.")
        return

    # Collapse multiple consecutive blank lines left by removed items
    collapsed = []
    prev_blank = False
    for line in keep:
        is_blank = line.strip() == ""
        if is_blank and prev_blank:
            continue
        collapsed.append(line)
        prev_blank = is_blank

    now = datetime.now(timezone.utc)
    archive_path = os.path.join(REPO_ROOT, f"todo-archive-{now.strftime('%Y-%m')}.txt")
    header = f"\n## Archived {now.strftime('%Y-%m-%d')} (from todo.txt)\n\n"

    print(f"Archiving {len(archive)} completed items → {os.path.basename(archive_path)}")
    for line in archive:
        print(f"  {line.rstrip()}")

    if args.dry_run:
        print("\n[dry-run] no files written")
        return

    with open(archive_path, "a") as f:
        f.write(header)
        f.writelines(archive)

    with open(TODO_PATH, "w") as f:
        f.writelines(collapsed)

    print(f"\nDone. {len(keep)} lines remain in todo.txt.")

if __name__ == "__main__":
    main()
