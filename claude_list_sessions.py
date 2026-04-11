#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


HOME = Path.home()
PROFILE_DIRS = [HOME / ".claude-p", HOME / ".claude-w", HOME / ".claude"]


def iter_session_files():
    seen = set()
    for base in PROFILE_DIRS:
        sessions_dir = base / "sessions"
        if not sessions_dir.is_dir():
            continue
        for path in sorted(sessions_dir.glob("*.json")):
            if path in seen:
                continue
            seen.add(path)
            yield base.name, path


def safe_json(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def readlink(path: str):
    try:
        return os.readlink(path)
    except OSError:
        return None


def extract_pts(tty_path: str | None):
    if not tty_path or not tty_path.startswith("/dev/pts/"):
        return None
    return tty_path.rsplit("/", 1)[-1]


def find_terminal_owner(pts_num: str | None):
    if pts_num is None:
        return None, None

    proc = Path("/proc")
    for pid_dir in proc.iterdir():
        if not pid_dir.name.isdigit():
            continue
        fdinfo_dir = pid_dir / "fdinfo"
        if not fdinfo_dir.is_dir():
            continue
        try:
            fdinfos = list(fdinfo_dir.iterdir())
        except PermissionError:
            continue
        for fdinfo in fdinfos:
            try:
                content = fdinfo.read_text()
            except Exception:
                continue
            needle = f"tty-index:\t{pts_num}\n"
            if needle not in content:
                continue
            fd_path = pid_dir / "fd" / fdinfo.name
            target = readlink(str(fd_path))
            if target == "/dev/ptmx":
                return int(pid_dir.name), int(fdinfo.name)
    return None, None


def transcript_path(cwd: str | None, session_id: str | None):
    if not cwd or not session_id:
        return None
    slug = cwd.replace("/", "-")
    return str(HOME / ".claude" / "projects" / slug / f"{session_id}.jsonl")


def process_alive(pid: int | None):
    return isinstance(pid, int) and Path(f"/proc/{pid}").exists()


def print_table(rows):
    headers = ["NAME", "PID", "SESSION ID", "TTY", "CWD"]
    table = [headers]
    for row in rows:
        table.append(
            [
                row.get("name") or "<unnamed>",
                str(row.get("pid", "")),
                row.get("session_id", ""),
                row.get("tty", ""),
                row.get("cwd", ""),
            ]
        )
    widths = [max(len(r[i]) for r in table) for i in range(len(headers))]
    for idx, row in enumerate(table):
        print("  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)))
        if idx == 0:
            print("  ".join("-" * widths[i] for i in range(len(headers))))


def main():
    parser = argparse.ArgumentParser(
        description="List running Claude sessions discoverable on this machine.",
        epilog="Example: claude-list-sessions",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit JSON instead of a table"
    )
    args = parser.parse_args()

    rows = []
    seen_session_ids = set()
    for profile_name, session_file in iter_session_files():
        data = safe_json(session_file)
        if not data:
            continue
        pid = data.get("pid")
        session_id = data.get("sessionId", "")
        if session_id in seen_session_ids:
            continue
        if not process_alive(pid):
            continue
        seen_session_ids.add(session_id)
        tty_path = readlink(f"/proc/{pid}/fd/0")
        pts_num = extract_pts(tty_path)
        terminal_pid, master_fd = find_terminal_owner(pts_num)
        rows.append(
            {
                "profile": profile_name,
                "name": data.get("name", ""),
                "pid": pid,
                "session_id": session_id,
                "cwd": data.get("cwd", ""),
                "tty": tty_path or "",
                "terminal_pid": terminal_pid or "",
                "terminal_master_fd": master_fd or "",
                "transcript": transcript_path(data.get("cwd"), data.get("sessionId"))
                or "",
            }
        )

    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print_table(rows)


if __name__ == "__main__":
    main()
