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

if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import c2c_pty_inject  # pure-Python pidfd_getfd backend

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
    # Pure-Python backend: always available at import time. The only
    # failure mode is missing CAP_SYS_PTRACE, which surfaces as
    # PermissionError when we actually call inject() — we can't probe
    # for it cheaply here, so we report True and let the caller handle
    # the EPERM path.
    return True


def _fork_restart_daemon(
    client_pid: int,
    terminal_pid: int | None,
    pts: int | None,
    restart_cmd: str,
) -> None:
    """Double-fork a daemon that closes the client after ~1s then relaunches it.

    After 1s: PTY-injects /exit (if PTY available) or sends SIGTERM.
    After client exits: PTY-injects restart_cmd (if PTY available).
    """
    pid = os.fork()
    if pid != 0:
        os.waitpid(pid, 0)
        return

    pid2 = os.fork()
    if pid2 != 0:
        os._exit(0)

    # Grandchild (daemon): detach
    os.setsid()

    pty_ok = terminal_pid is not None and pts is not None and _pty_inject_available()

    # Wait ~1 second for the agent to finish up, then close the client
    time.sleep(1.0)

    if pty_ok:
        try:
            c2c_pty_inject.inject(int(terminal_pid), pts, "/exit\n")
        except Exception:
            # Fall back to SIGTERM
            try:
                if client_pid > 1:
                    os.kill(client_pid, 15)
            except (ProcessLookupError, PermissionError):
                pass
    else:
        try:
            if client_pid > 1:
                os.kill(client_pid, 15)
        except (ProcessLookupError, PermissionError):
            pass

    # Wait for the client process to exit (up to 5 minutes)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if not Path(f"/proc/{client_pid}").exists():
            break
        time.sleep(0.5)
    else:
        os._exit(1)

    if not pty_ok:
        os._exit(0)

    # Brief pause to let the shell prompt appear
    time.sleep(0.3)

    try:
        c2c_pty_inject.inject(int(terminal_pid), pts, restart_cmd + "\n")
    except Exception:
        pass

    os._exit(0)


def restart_unmanaged(client: str, client_pid: int) -> int:
    """Process-level restart for an unmanaged client session.

    Flow:
    1. Resolve session UUID + build restart argv
    2. Fork a daemon: waits 1s, sends /exit (or SIGTERM), then relaunches
    3. Print instructions and return — the agent should stop responding immediately
    """
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
    pty_ok = _pty_inject_available() and pts is not None and terminal_pid is not None

    # Fork the daemon before printing
    _fork_restart_daemon(
        client_pid,
        terminal_pid if pty_ok else None,
        pts if pty_ok else None,
        restart_cmd,
    )

    print(f"[c2c restart-me] restarting {client} (pid={client_pid})")
    print(f"  restart command: {restart_cmd}")
    if pty_ok:
        print(f"  close via: /exit (PTY inject), terminal={terminal_pid} pts={pts}")
        print(f"  relaunch via: pty_inject after exit")
    else:
        reasons = []
        if not _pty_inject_available():
            reasons.append("pty_inject backend unavailable")
        if pts is None:
            reasons.append("no PTY on fd 0")
        if terminal_pid is None:
            reasons.append("no terminal emulator in process tree")
        print(f"  close via: SIGTERM — {'; '.join(reasons)}")
        print(f"  relaunch after exit: {restart_cmd}")
    print()
    print("IMPORTANT: Stop responding immediately — this session will close in ~1 second.")

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
