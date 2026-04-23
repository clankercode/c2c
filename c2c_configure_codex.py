#!/usr/bin/env python3
"""Write the c2c MCP entry into ~/.codex/config.toml for Codex.

Usage: c2c configure-codex [--broker-root DIR] [--alias NAME] [--force] [--json]

Appends (or replaces with --force) the [mcp_servers.c2c] section in
~/.codex/config.toml. Existing non-c2c config is untouched.

c2c MCP tools are auto-approved so the swarm agent can poll, send,
and join rooms without manual approval on every call.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import socket
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
C2C_MCP_PATH = REPO_ROOT / "c2c_mcp.py"
DEFAULT_BROKER_ROOT = REPO_ROOT / ".git" / "c2c" / "mcp"
CODEX_CONFIG_PATH = Path.home() / ".codex" / "config.toml"

# All c2c MCP tools — auto-approved for swarm operation
C2C_TOOLS = [
    "register", "whoami", "list",
    "send", "send_all",
    "poll_inbox", "peek_inbox", "history",
    "join_room", "leave_room", "send_room", "list_rooms", "my_rooms", "room_history",
    "sweep", "tail_log",
]

_C2C_SECTION_PATTERN = re.compile(
    r'^\[mcp_servers\.c2c\]', re.MULTILINE
)


def default_alias() -> str:
    user = getpass.getuser()
    host = socket.gethostname().split(".")[0]
    return f"codex-{user}-{host}"


def resolve_broker_root(override: Path | None) -> Path:
    if override is not None:
        return override.resolve()
    env_val = os.environ.get("C2C_MCP_BROKER_ROOT")
    if env_val:
        return Path(env_val)
    return DEFAULT_BROKER_ROOT


def build_toml_block(broker_root: Path, alias: str) -> str:
    args_toml = f'["{C2C_MCP_PATH}"]'
    lines = [
        "",
        "[mcp_servers.c2c]",
        f'command = "python3"',
        f"args = {args_toml}",
        "",
        "[mcp_servers.c2c.env]",
        f'C2C_MCP_BROKER_ROOT = "{broker_root}"',
        'C2C_MCP_AUTO_JOIN_ROOMS = "swarm-lounge"',
        'C2C_MCP_CLIENT_TYPE = "codex"',
        'C2C_AUTO_JOIN_ROLE_ROOM = "1"',
        "",
    ]
    for tool in C2C_TOOLS:
        lines.append(f"[mcp_servers.c2c.tools.{tool}]")
        lines.append('approval_mode = "auto"')
        lines.append("")
    return "\n".join(lines)


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _strip_c2c_sections(content: str) -> str:
    """Remove all [mcp_servers.c2c*] sections from TOML content."""
    lines = content.splitlines(keepends=True)
    result: list[str] = []
    in_c2c = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            # TOML section header
            in_c2c = bool(re.match(r'^\[mcp_servers\.c2c[\.\]]', stripped)
                         or stripped == "[mcp_servers.c2c]")
        if not in_c2c:
            result.append(line)
    return "".join(result).rstrip()


def configure(broker_root: Path, alias: str, *, force: bool) -> str:
    existing = CODEX_CONFIG_PATH.read_text(encoding="utf-8") if CODEX_CONFIG_PATH.exists() else ""

    if _C2C_SECTION_PATTERN.search(existing):
        if not force:
            raise SystemExit(
                f"[mcp_servers.c2c] already exists in {CODEX_CONFIG_PATH} "
                f"(re-run with --force to replace)"
            )
        existing = _strip_c2c_sections(existing)

    new_content = existing + build_toml_block(broker_root, alias) + "\n"
    _atomic_write(CODEX_CONFIG_PATH, new_content)
    return "written"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Configure ~/.codex/config.toml to include the c2c MCP server."
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        default=None,
        help=f"broker root directory (default: {DEFAULT_BROKER_ROOT})",
    )
    parser.add_argument(
        "--alias",
        default=None,
        help=f"alias label for CLI output (default: {default_alias()})",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace existing [mcp_servers.c2c] block",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    args = parser.parse_args(argv)

    broker_root = resolve_broker_root(args.broker_root)
    alias = args.alias or default_alias()
    status = configure(broker_root, alias, force=args.force)

    result = {
        "config_path": str(CODEX_CONFIG_PATH),
        "broker_root": str(broker_root),
        "alias": alias,
        "status": status,
    }

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"wrote [mcp_servers.c2c] to {result['config_path']}")
        print(f"  broker_root: {result['broker_root']}")
        print(f"  alias:       {result['alias']}")
        print("Restart Codex to pick up the new MCP server.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
