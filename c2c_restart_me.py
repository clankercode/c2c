#!/usr/bin/env python3
"""
c2c restart-me — detect current client and restart it.

For managed sessions (run-claude-inst / run-opencode-inst), signals the
outer loop which relaunches with the same --resume flag, picking up any
updated MCP config, CLAUDE.md, or flags.

For unmanaged sessions, prints per-client restart instructions with the
current session ID so the user can relaunch manually.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


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


def parent_pid(pid: int) -> int | None:
    status = _read_proc(f"/proc/{pid}/status")
    for line in status.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
    return None


def detect_client_from_ancestors() -> str | None:
    """Walk the process tree to identify the calling client type."""
    pid: int | None = os.getpid()
    visited: set[int] = set()
    while pid and pid not in visited and pid > 1:
        visited.add(pid)
        comm = proc_comm(pid).lower()

        # Match by comm name
        if "claude" in comm:
            return "claude-code"
        if "opencode" in comm:
            return "opencode"
        if "codex" in comm:
            return "codex"

        # Match by cmdline (scripts/wrappers often show as python3 or node)
        for part in proc_cmdline(pid):
            part_lower = part.lower()
            # Exclude c2c scripts themselves to avoid false positives
            if "c2c" in part_lower:
                continue
            if "claude" in part_lower:
                return "claude-code"
            if "opencode" in part_lower:
                return "opencode"
            if "codex" in part_lower:
                return "codex"

        pid = parent_pid(pid)
    return None


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
# Unmanaged instructions
# ---------------------------------------------------------------------------

def print_unmanaged_instructions(client: str | None) -> None:
    session_id = (
        os.environ.get("C2C_MCP_SESSION_ID")
        or os.environ.get("C2C_SESSION_ID")
        or None
    )

    print("No managed-session harness detected. Manual restart required.")
    print()

    if client in (None, "claude-code"):
        print("Claude Code")
        print("-----------")
        if session_id:
            print(f"  Session ID : {session_id}")
        print("  To reload MCP servers (required after `c2c setup claude-code`):")
        print("  1. Exit this session  (type /exit or press Ctrl-C)")
        print("  2. Relaunch:  claude --resume <session-uuid>")
        if session_id:
            print(f"     e.g.:     claude --resume {session_id}")
        print()
        print("  If you only need to reconnect existing MCP tools (no new tools):")
        print("    /plugin reconnect c2c")
        print()
        print("  For managed sessions add $RUN_CLAUDE_INST_NAME to your harness")
        print("  config (run-claude-inst.d/<name>.json) — then `c2c restart-me`")
        print("  will signal the outer loop automatically.")
        print()

    if client in (None, "codex"):
        print("Codex")
        print("-----")
        print("  Exit Codex, then reopen it in the same directory.")
        print("  MCP servers are loaded fresh on each start.")
        print()

    if client in (None, "opencode"):
        print("OpenCode")
        print("--------")
        print("  Exit OpenCode (:quit), then reopen in the same directory.")
        print("  MCP servers reload on each start.")
        print("  For managed sessions `restart-opencode-self` handles this automatically.")
        print()

    if client is None:
        print("Could not detect client from process tree.")
        print("Set $RUN_CLAUDE_INST_NAME (Claude Code) or")
        print("$RUN_OPENCODE_INST_NAME (OpenCode) to enable automatic restart.")


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

    # Not managed — detect client and print instructions
    client = detect_client_from_ancestors()
    print_unmanaged_instructions(client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
