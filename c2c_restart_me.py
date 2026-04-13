#!/usr/bin/env python3
"""
c2c restart-me — detect current client and restart it.

Priority order:
1. Managed Claude Code ($RUN_CLAUDE_INST_NAME): signal restart-self
2. Managed OpenCode ($RUN_OPENCODE_INST_NAME): signal restart-opencode-self
3. Unmanaged with pty_inject available: fork a daemon that waits for the
   client process to exit, then PTY-injects the restart command into the
   parent terminal. The agent must exit after calling this command.
4. Fallback: print per-client manual restart instructions.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

PTY_INJECT = Path("/home/xertrov/src/meta-agent/apps/ma_adapter_claude/priv/pty_inject")

# Known terminal emulator process names
TERMINAL_EMULATORS = frozenset({
    "ghostty", "xterm", "alacritty", "kitty", "konsole", "gnome-terminal",
    "xfce4-terminal", "lxterminal", "terminator", "tilix", "wezterm",
    "foot", "st", "urxvt", "rxvt", "tmux", "screen",
})


# ---------------------------------------------------------------------------
# Process-tree helpers (Linux /proc)
# ---------------------------------------------------------------------------

def _read_proc(path: str) -> str:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return ""


def _read_proc_bytes(path: str) -> bytes:
    try:
        return Path(path).read_bytes()
    except (FileNotFoundError, OSError):
        return b""


def proc_comm(pid: int) -> str:
    return _read_proc(f"/proc/{pid}/comm")


def proc_cmdline(pid: int) -> list[str]:
    data = _read_proc_bytes(f"/proc/{pid}/cmdline")
    return [p.decode("utf-8", errors="replace") for p in data.split(b"\x00") if p]


def proc_environ(pid: int) -> dict[str, str]:
    data = _read_proc_bytes(f"/proc/{pid}/environ")
    result: dict[str, str] = {}
    for item in data.split(b"\x00"):
        if b"=" in item:
            k, _, v = item.partition(b"=")
            result[k.decode("utf-8", errors="replace")] = v.decode("utf-8", errors="replace")
    return result


def parent_pid(pid: int) -> int | None:
    status = _read_proc(f"/proc/{pid}/status")
    for line in status.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
    return None


def pts_from_fd0(pid: int) -> int | None:
    """Get PTY slave number from a process's stdin fd."""
    try:
        target = os.readlink(f"/proc/{pid}/fd/0")
        if target.startswith("/dev/pts/"):
            return int(target.split("/")[-1])
    except (OSError, ValueError):
        pass
    return None


def find_terminal_pid(start_pid: int) -> int | None:
    """Walk process tree from start_pid to find a terminal emulator ancestor."""
    pid: int | None = start_pid
    visited: set[int] = set()
    while pid and pid not in visited and pid > 1:
        visited.add(pid)
        comm = proc_comm(pid).lower()
        if comm in TERMINAL_EMULATORS:
            return pid
        pid = parent_pid(pid)
    return None


# ---------------------------------------------------------------------------
# Client process detection
# ---------------------------------------------------------------------------

CLIENT_COMMS = {
    "claude": "claude-code",
    "codex": "codex",
    "opencode": "opencode",
}


def find_client_parent() -> tuple[str, int] | None:
    """Walk process tree to find the direct calling client process."""
    pid: int | None = os.getpid()
    visited: set[int] = set()
    while pid and pid not in visited and pid > 1:
        visited.add(pid)
        comm = proc_comm(pid).lower()
        for key, client in CLIENT_COMMS.items():
            if key in comm:
                return (client, pid)
        # Also check cmdline for script-based clients
        for part in proc_cmdline(pid):
            part_lower = part.lower()
            if "c2c" in part_lower:
                continue
            for key, client in CLIENT_COMMS.items():
                if key in part_lower:
                    return (client, pid)
        pid = parent_pid(pid)
    return None


# ---------------------------------------------------------------------------
# Session UUID resolution
# ---------------------------------------------------------------------------

def _uuid_from_cmdline(cmdline: list[str]) -> str | None:
    for i, arg in enumerate(cmdline):
        if arg == "--resume" and i + 1 < len(cmdline):
            val = cmdline[i + 1]
            # Sanity-check: looks like a UUID (8-4-4-4-12 hex)
            parts = val.split("-")
            if len(parts) == 5:
                return val
    return None


def _uuid_from_proc_environ(pid: int) -> str | None:
    env = proc_environ(pid)
    for key in ("C2C_MCP_SESSION_ID", "C2C_SESSION_ID", "CLAUDE_SESSION_ID"):
        val = env.get(key, "").strip()
        if val:
            return val
    return None


def _uuid_from_claude_dir(pid: int) -> str | None:
    """Find the session UUID by looking for the most-recently-modified JSONL
    conversation file in the Claude project directories for the process's CWD."""
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return None

    cwd_slug = cwd.lstrip("/").replace("/", "-")
    search_dirs = [
        Path.home() / ".claude" / "projects" / cwd_slug,
        Path.home() / ".claude-p" / "projects" / cwd_slug,
        Path.home() / ".claude-w" / "projects" / cwd_slug,
    ]

    best_file: Path | None = None
    best_mtime = 0.0
    for d in search_dirs:
        if not d.exists():
            continue
        for f in d.glob("*.jsonl"):
            try:
                mtime = f.stat().st_mtime
                if mtime > best_mtime:
                    best_mtime = mtime
                    best_file = f
            except OSError:
                pass

    if best_file:
        # UUID is the stem of the filename
        return best_file.stem

    return None


def get_session_uuid(client: str, client_pid: int) -> str | None:
    """Resolve session UUID for a client process."""
    if client == "claude-code":
        # 1. --resume flag
        uuid = _uuid_from_cmdline(proc_cmdline(client_pid))
        if uuid:
            return uuid
        # 2. env vars in process environ
        uuid = _uuid_from_proc_environ(client_pid)
        if uuid:
            return uuid
        # 3. Claude project dir (most-recent JSONL)
        uuid = _uuid_from_claude_dir(client_pid)
        if uuid:
            return uuid

    # Codex / OpenCode: session resume flags differ or don't exist
    # Return None — caller will handle
    return None


def build_restart_argv(client: str, uuid: str | None, original_cmdline: list[str]) -> list[str]:
    """Build the argv to use when restarting the client."""
    if client == "claude-code":
        binary = original_cmdline[0] if original_cmdline else "claude"
        argv = [binary]
        if uuid:
            argv += ["--resume", uuid]
        # Copy safe flags (skip positional/prompt args)
        skip_next = False
        for arg in original_cmdline[1:]:
            if skip_next:
                skip_next = False
                continue
            if arg in ("--resume",):
                skip_next = True
                continue
            # Keep --dangerously-skip-permissions and similar flags
            if arg.startswith("--") and "resume" not in arg:
                # Skip the kickoff prompt (long positional string — not a flag)
                argv.append(arg)
        return argv

    if client == "codex":
        binary = original_cmdline[0] if original_cmdline else "codex"
        return [binary]

    if client == "opencode":
        binary = original_cmdline[0] if original_cmdline else "opencode"
        return [binary]

    return []


# ---------------------------------------------------------------------------
# Fork-daemon restart for unmanaged sessions
# ---------------------------------------------------------------------------

def _pty_inject_available() -> bool:
    return PTY_INJECT.exists() and os.access(PTY_INJECT, os.X_OK)


def _fork_restart_daemon(client_pid: int, terminal_pid: int, pts: int, restart_cmd: str) -> None:
    """Double-fork a daemon that waits for client_pid to die, then PTY-injects restart_cmd."""
    # Double-fork: daemon is adopted by init, so it won't become a zombie
    pid = os.fork()
    if pid != 0:
        # Parent: wait for child (intermediate) and return
        os.waitpid(pid, 0)
        return

    # Child (intermediate): fork again and exit so parent can return
    pid2 = os.fork()
    if pid2 != 0:
        os._exit(0)

    # Grandchild (actual daemon): detach from session
    os.setsid()

    # Wait for the client process to exit (up to 5 minutes)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if not Path(f"/proc/{client_pid}").exists():
            break
        time.sleep(0.5)
    else:
        # Timed out — do nothing
        os._exit(1)

    # Brief pause to let the shell prompt appear
    time.sleep(0.3)

    # PTY-inject the restart command followed by Enter
    try:
        subprocess.run(
            [str(PTY_INJECT), str(terminal_pid), str(pts), restart_cmd + "\n"],
            timeout=10,
        )
    except Exception:
        pass

    os._exit(0)


def restart_unmanaged(client: str, client_pid: int) -> int:
    """Attempt a process-level restart for an unmanaged client session."""
    cmdline = proc_cmdline(client_pid)
    uuid = get_session_uuid(client, client_pid)
    restart_argv = build_restart_argv(client, uuid, cmdline)

    if not restart_argv:
        print(f"[c2c restart-me] could not build restart command for {client}")
        print_unmanaged_instructions(client)
        return 1

    restart_cmd = " ".join(restart_argv)

    # Find terminal info for PTY injection
    pts = pts_from_fd0(client_pid)
    terminal_pid = find_terminal_pid(client_pid) if pts is not None else None

    if not _pty_inject_available() or pts is None or terminal_pid is None:
        # Fallback: print instructions with the exact restart command
        print(f"[c2c restart-me] cannot inject restart automatically")
        if pts is None:
            print(f"  (no PTY slave found on fd 0 of pid {client_pid})")
        elif terminal_pid is None:
            print(f"  (no terminal emulator found in process tree)")
        elif not _pty_inject_available():
            print(f"  (pty_inject not found at {PTY_INJECT})")
        print()
        print(f"Restart command: {restart_cmd}")
        print()
        print_unmanaged_instructions(client)
        return 0

    # Arm the restart daemon
    _fork_restart_daemon(client_pid, terminal_pid, pts, restart_cmd)

    print(f"[c2c restart-me] restart daemon armed for {client} (pid={client_pid})")
    print(f"  terminal: pid={terminal_pid} pts={pts}")
    print(f"  restart command: {restart_cmd}")
    print()
    print(f"Daemon will inject the restart command once this {client} session exits.")
    if client == "claude-code":
        print("To restart now: type /exit")
    elif client == "codex":
        print("To restart now: type :quit or Ctrl-C")
    elif client == "opencode":
        print("To restart now: type :quit")
    return 0


# ---------------------------------------------------------------------------
# Managed restart paths
# ---------------------------------------------------------------------------

def _run_restart_script(script_name: str, inst_name: str, reason: str) -> int:
    script = HERE / script_name
    if not script.exists():
        print(f"[c2c restart-me] {script_name} not found at {script}", file=sys.stderr)
        return 2
    cmd = [str(script), inst_name]
    if reason and script_name == "restart-opencode-self":
        cmd += ["--reason", reason]
    result = subprocess.run(cmd, check=False)
    return result.returncode


# ---------------------------------------------------------------------------
# Unmanaged instructions (fallback)
# ---------------------------------------------------------------------------

def print_unmanaged_instructions(client: str | None) -> None:
    session_id = (
        os.environ.get("C2C_MCP_SESSION_ID")
        or os.environ.get("C2C_SESSION_ID")
        or None
    )

    if client in (None, "claude-code"):
        print("Claude Code")
        print("-----------")
        if session_id:
            print(f"  Session ID : {session_id}")
        print("  1. Exit this session  (/exit or Ctrl-C)")
        print("  2. Relaunch:  claude --resume <session-uuid>")
        if session_id:
            print(f"     e.g.:     claude --resume {session_id}")
        print("  Quick reload (existing MCP tools only — no new servers):")
        print("    /plugin reconnect c2c")
        print()

    if client in (None, "codex"):
        print("Codex")
        print("-----")
        print("  Exit Codex, then reopen in the same directory.")
        print()

    if client in (None, "opencode"):
        print("OpenCode")
        print("--------")
        print("  Exit OpenCode (:quit), then reopen in the same directory.")
        print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(_argv: list[str] | None = None) -> int:
    # Managed Claude Code (run-claude-inst harness)
    cc_name = os.environ.get("RUN_CLAUDE_INST_NAME", "").strip()
    if cc_name:
        print(f"[c2c restart-me] managed Claude Code session: {cc_name}", flush=True)
        return _run_restart_script("restart-self", cc_name, "")

    # Managed OpenCode (run-opencode-inst harness)
    oc_name = os.environ.get("RUN_OPENCODE_INST_NAME", "").strip()
    if oc_name:
        print(f"[c2c restart-me] managed OpenCode session: {oc_name}", flush=True)
        return _run_restart_script("restart-opencode-self", oc_name, "c2c restart-me")

    # Unmanaged: detect client from process tree
    result = find_client_parent()
    if result is None:
        print("[c2c restart-me] could not detect client from process tree")
        print_unmanaged_instructions(None)
        return 1

    client, client_pid = result
    return restart_unmanaged(client, client_pid)


if __name__ == "__main__":
    raise SystemExit(main())
