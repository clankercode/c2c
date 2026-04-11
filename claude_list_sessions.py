#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


HOME = Path.home()
PROFILE_DIRS = [HOME / ".claude-p", HOME / ".claude-w", HOME / ".claude"]


def fixture_path_from_env() -> Path | None:
    fixture_path = os.environ.get("C2C_SESSIONS_FIXTURE")
    if not fixture_path:
        return None
    return Path(fixture_path)


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
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_fixture_sessions(path: Path) -> list[dict]:
    data = safe_json(path)
    if data is None:
        raise ValueError(f"invalid sessions fixture: {path}")
    if not isinstance(data, list):
        raise ValueError(f"invalid sessions fixture: {path}")
    return data


def load_sessions(with_terminal_owner: bool = False) -> list[dict]:
    fixture_path = fixture_path_from_env()
    if fixture_path is not None:
        return load_fixture_sessions(fixture_path)

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
        terminal_pid = ""
        master_fd = ""
        if with_terminal_owner:
            terminal_pid, master_fd = find_terminal_owner(pts_num, session_pid=pid)
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
    return rows


def find_session(identifier: str, sessions: list[dict]) -> dict | None:
    exact_matches = []
    name_matches = []
    for session in sessions:
        if identifier == session.get("session_id", ""):
            return session
        if identifier == str(session.get("pid", "")):
            return session
        if identifier == session.get("name", ""):
            name_matches.append(session)

    if len(name_matches) == 1:
        return name_matches[0]
    if len(name_matches) > 1:
        raise ValueError(
            f"ambiguous session name: {identifier}; use a session ID or PID"
        )
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


def parent_pid(pid: int | None):
    if not isinstance(pid, int):
        return None
    status_path = Path(f"/proc/{pid}/status")
    try:
        for line in status_path.read_text().splitlines():
            if not line.startswith("PPid:\t"):
                continue
            value = int(line.split("\t", 1)[1])
            return value or None
    except Exception:
        return None
    return None


def find_terminal_owner_in_pid(pid: int | None, pts_num: str | None):
    if not isinstance(pid, int) or pts_num is None:
        return None, None

    fdinfo_dir = Path(f"/proc/{pid}/fdinfo")
    if not fdinfo_dir.is_dir():
        return None, None

    try:
        fdinfos = list(fdinfo_dir.iterdir())
    except PermissionError:
        return None, None

    needle = f"tty-index:\t{pts_num}\n"
    for fdinfo in fdinfos:
        try:
            content = fdinfo.read_text()
        except Exception:
            continue
        if needle not in content:
            continue
        fd_path = fdinfo_dir.parent / "fd" / fdinfo.name
        if readlink(str(fd_path)) == "/dev/ptmx":
            return pid, int(fdinfo.name)

    return None, None


def find_terminal_owner_in_parent_chain(session_pid: int | None, pts_num: str | None):
    current_pid = session_pid
    seen = set()

    while isinstance(current_pid, int) and current_pid not in seen:
        seen.add(current_pid)
        terminal_pid, master_fd = find_terminal_owner_in_pid(current_pid, pts_num)
        if terminal_pid is not None:
            return terminal_pid, master_fd
        current_pid = parent_pid(current_pid)

    return None, None


def find_terminal_owner_in_proc_scan(pts_num: str | None):
    if pts_num is None:
        return None, None

    proc = Path("/proc")
    for pid_dir in proc.iterdir():
        if not pid_dir.name.isdigit():
            continue
        terminal_pid, master_fd = find_terminal_owner_in_pid(int(pid_dir.name), pts_num)
        if terminal_pid is not None:
            return terminal_pid, master_fd


def find_terminal_owner(pts_num: str | None, session_pid: int | None = None):
    if pts_num is None:
        return None, None

    terminal_pid, master_fd = find_terminal_owner_in_parent_chain(session_pid, pts_num)
    if terminal_pid is not None:
        return terminal_pid, master_fd

    return find_terminal_owner_in_proc_scan(pts_num)


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
    parser.add_argument(
        "--with-terminal-owner",
        action="store_true",
        help="include terminal owner metadata needed for PTY injection",
    )
    args = parser.parse_args()

    rows = load_sessions(with_terminal_owner=args.with_terminal_owner)

    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print_table(rows)


if __name__ == "__main__":
    main()
