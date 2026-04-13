#!/usr/bin/env python3
"""Configure Claude Code for c2c: MCP server + PostToolUse inbox hook.

Usage: c2c configure-claude-code [--broker-root DIR] [--session-id ID] [--force] [--json]

Writes two config targets:

  1. `mcpServers.c2c` in ~/.claude.json — the MCP server entry that exposes
     c2c tools (register, send, poll_inbox, rooms, …).

  2. A PostToolUse hook entry in ~/.claude/settings.json that auto-delivers
     inbox messages after every tool call (file-fallback path, no dev channels
     required). Only added when ~/.claude/hooks/c2c-inbox-check.sh exists.

Both writes are idempotent. Use --force to overwrite existing entries.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
C2C_MCP_PATH = REPO_ROOT / "c2c_mcp.py"
DEFAULT_BROKER_ROOT = REPO_ROOT / ".git" / "c2c" / "mcp"

CLAUDE_JSON_PATH = Path.home() / ".claude.json"
SETTINGS_JSON_PATH = Path.home() / ".claude" / "settings.json"
HOOK_SCRIPT_PATH = Path.home() / ".claude" / "hooks" / "c2c-inbox-check.sh"

HOOK_MATCHER = ".*"


def resolve_broker_root(override: Path | None) -> Path:
    if override is not None:
        return override.resolve()
    env_val = os.environ.get("C2C_MCP_BROKER_ROOT")
    if env_val:
        return Path(env_val)
    return DEFAULT_BROKER_ROOT


def default_alias() -> str:
    import getpass
    import socket
    user = getpass.getuser()
    host = socket.gethostname().split(".")[0]
    return f"claude-{user}-{host}"


def build_mcp_entry(broker_root: Path, session_id: str | None, alias: str | None) -> dict:
    env: dict[str, str] = {
        "C2C_MCP_BROKER_ROOT": str(broker_root),
    }
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
    env["C2C_MCP_AUTO_JOIN_ROOMS"] = "swarm-lounge"
    return {
        "type": "stdio",
        "command": "python3",
        "args": [str(C2C_MCP_PATH)],
        "env": env,
    }


def _atomic_write(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"cannot parse {path}: {e}") from e


def configure_mcp(
    broker_root: Path, session_id: str | None, alias: str | None, *, force: bool
) -> dict:
    data = _load_json(CLAUDE_JSON_PATH)
    mcp_servers = data.setdefault("mcpServers", {})

    if "c2c" in mcp_servers and not force:
        raise SystemExit(
            f"mcpServers.c2c already exists in {CLAUDE_JSON_PATH} "
            f"(re-run with --force to replace)"
        )

    mcp_servers["c2c"] = build_mcp_entry(broker_root, session_id, alias)
    _atomic_write(CLAUDE_JSON_PATH, data)
    return mcp_servers["c2c"]


def _hook_entry() -> dict:
    return {"type": "command", "command": str(HOOK_SCRIPT_PATH)}


def _hook_already_registered(settings: dict) -> bool:
    hook_cmd = str(HOOK_SCRIPT_PATH)
    for group in settings.get("hooks", {}).get("PostToolUse", []):
        for h in group.get("hooks", []):
            if h.get("command") == hook_cmd:
                return True
    return False


def configure_hook(*, force: bool) -> str | None:
    """Register the PostToolUse hook in settings.json. Returns status string."""
    if not HOOK_SCRIPT_PATH.exists():
        return "hook_script_missing"

    settings = _load_json(SETTINGS_JSON_PATH)

    if _hook_already_registered(settings) and not force:
        return "already_registered"

    # Ensure the PostToolUse list exists
    hooks_section = settings.setdefault("hooks", {})
    post_tool_use = hooks_section.setdefault("PostToolUse", [])

    # Find existing group with HOOK_MATCHER or append a new one
    target_group = None
    for group in post_tool_use:
        if group.get("matcher") == HOOK_MATCHER:
            target_group = group
            break
    if target_group is None:
        target_group = {"matcher": HOOK_MATCHER, "hooks": []}
        post_tool_use.append(target_group)

    # Add hook entry if not already in this group
    hook_cmd = str(HOOK_SCRIPT_PATH)
    if not any(h.get("command") == hook_cmd for h in target_group.get("hooks", [])):
        target_group.setdefault("hooks", []).append(_hook_entry())

    _atomic_write(SETTINGS_JSON_PATH, settings)
    return "registered"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Configure ~/.claude.json (MCP server) and ~/.claude/settings.json"
            " (PostToolUse inbox hook) for c2c."
        )
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        default=None,
        help=f"broker root directory (default: {DEFAULT_BROKER_ROOT})",
    )
    parser.add_argument(
        "--session-id",
        default=None,
        help="fixed MCP session ID (optional; omit for auto-resolution)",
    )
    parser.add_argument(
        "--alias",
        default=None,
        help=(
            "stable alias for auto-registration on every restart "
            f"(default: {default_alias()})"
        ),
    )
    parser.add_argument(
        "--no-alias",
        action="store_true",
        help="do not configure an auto-register alias",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite existing mcpServers.c2c and hook entries",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    parser.add_argument(
        "--auto-wake",
        action="store_true",
        help="start the idle wake daemon for the current Claude Code session",
    )
    args = parser.parse_args(argv)

    broker_root = resolve_broker_root(args.broker_root)
    alias = None if args.no_alias else (args.alias or default_alias())
    mcp_entry = configure_mcp(broker_root, args.session_id, alias, force=args.force)
    hook_status = configure_hook(force=args.force)

    wake_daemon_pid: int | None = None
    wake_log: str | None = None
    claude_session_id = args.session_id or os.environ.get("CLAUDE_SESSION_ID", "")
    if args.auto_wake:
        if claude_session_id:
            log_path = Path.home() / ".claude" / f"c2c-wake-{claude_session_id}.log"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                proc = subprocess.Popen(
                    [
                        sys.executable,
                        str(REPO_ROOT / "c2c_claude_wake_daemon.py"),
                        "--claude-session",
                        claude_session_id,
                        "--session-id",
                        claude_session_id,
                    ],
                    stdout=log_path.open("ab"),
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                wake_daemon_pid = proc.pid
                wake_log = str(log_path)
            except Exception as exc:
                wake_daemon_pid = None
                wake_log = str(exc)
        else:
            wake_log = "CLAUDE_SESSION_ID not set; run inside a Claude Code session"

    result = {
        "claude_json": str(CLAUDE_JSON_PATH),
        "settings_json": str(SETTINGS_JSON_PATH),
        "broker_root": str(broker_root),
        "session_id": args.session_id,
        "alias": alias,
        "mcp_entry": mcp_entry,
        "hook_status": hook_status,
        "wake_daemon_pid": wake_daemon_pid,
        "wake_log": wake_log,
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"wrote mcpServers.c2c to {result['claude_json']}")
        print(f"  broker_root: {result['broker_root']}")
        if result["alias"]:
            print(f"  alias:       {result['alias']} (auto-registers on every restart)")
        if result["session_id"]:
            print(f"  session_id:  {result['session_id']}")
        if hook_status == "registered":
            print(f"registered PostToolUse hook: {HOOK_SCRIPT_PATH}")
        elif hook_status == "already_registered":
            print(f"PostToolUse hook already registered (use --force to re-add)")
        elif hook_status == "hook_script_missing":
            print(f"skipped hook: {HOOK_SCRIPT_PATH} not found")
        print()
        print("⚠️  Restart this Claude Code session to load the c2c MCP server.")
        print("   New Claude sessions opened after setup will already have it.")
        print()
        if wake_daemon_pid:
            print(f"✓ Started idle wake daemon (pid {wake_daemon_pid})")
            print(f"  log: {wake_log}")
        elif args.auto_wake:
            print(f"✗ Failed to start idle wake daemon: {wake_log}")
        if claude_session_id:
            print()
            print("To manually start the idle wake daemon later:")
            print(f"  nohup c2c-claude-wake --claude-session {claude_session_id} &")
        else:
            print()
            print("To manually start the idle wake daemon later:")
            print("  nohup c2c-claude-wake --claude-session <session-name-or-id> &")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
