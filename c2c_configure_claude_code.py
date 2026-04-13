#!/usr/bin/env python3
"""Write the c2c MCP entry into ~/.claude.json for Claude Code.

Usage: c2c configure-claude-code [--broker-root DIR] [--session-id ID] [--force] [--json]

Adds or updates `mcpServers.c2c` in ~/.claude.json so Claude Code agents
get the c2c MCP server on next launch — no hand-editing required.

Refuses to overwrite an existing `c2c` MCP entry unless `--force` is given.
Existing keys in ~/.claude.json are left untouched.
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
C2C_MCP_PATH = REPO_ROOT / "c2c_mcp.py"
DEFAULT_BROKER_ROOT = REPO_ROOT / ".git" / "c2c" / "mcp"
CLAUDE_JSON_PATH = Path.home() / ".claude.json"


def resolve_broker_root(override: Path | None) -> Path:
    if override is not None:
        return override.resolve()
    env_val = os.environ.get("C2C_MCP_BROKER_ROOT")
    if env_val:
        return Path(env_val)
    return DEFAULT_BROKER_ROOT


def build_mcp_entry(broker_root: Path, session_id: str | None) -> dict:
    env: dict[str, str] = {
        "C2C_MCP_BROKER_ROOT": str(broker_root),
    }
    if session_id:
        env["C2C_MCP_SESSION_ID"] = session_id
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = session_id
    return {
        "type": "stdio",
        "command": "python3",
        "args": [str(C2C_MCP_PATH)],
        "env": env,
    }


def load_claude_json() -> dict:
    if not CLAUDE_JSON_PATH.exists():
        return {}
    try:
        return json.loads(CLAUDE_JSON_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"cannot parse {CLAUDE_JSON_PATH}: {e}") from e


def write_claude_json(data: dict) -> None:
    CLAUDE_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CLAUDE_JSON_PATH.parent, prefix=".claude.json.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, CLAUDE_JSON_PATH)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def configure(broker_root: Path, session_id: str | None, *, force: bool) -> dict:
    data = load_claude_json()
    mcp_servers = data.setdefault("mcpServers", {})

    if "c2c" in mcp_servers and not force:
        raise SystemExit(
            f"mcpServers.c2c already exists in {CLAUDE_JSON_PATH} "
            f"(re-run with --force to replace)"
        )

    mcp_servers["c2c"] = build_mcp_entry(broker_root, session_id)
    write_claude_json(data)
    return {
        "config_path": str(CLAUDE_JSON_PATH),
        "broker_root": str(broker_root),
        "session_id": session_id,
        "mcp_entry": mcp_servers["c2c"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Configure ~/.claude.json to include the c2c MCP server."
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
        "--force",
        action="store_true",
        help="overwrite an existing mcpServers.c2c entry",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    args = parser.parse_args(argv)

    broker_root = resolve_broker_root(args.broker_root)
    result = configure(broker_root, args.session_id, force=args.force)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"wrote mcpServers.c2c to {result['config_path']}")
        print(f"  broker_root: {result['broker_root']}")
        if result["session_id"]:
            print(f"  session_id:  {result['session_id']}")
        print("Restart Claude Code (or run ./restart-self) to pick up the new MCP server.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
