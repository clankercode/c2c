#!/usr/bin/env python3
"""Configure c2c MCP for Kimi Code CLI.

Writes ~/.kimi/mcp.json with a c2c server entry pointing at this repo's broker.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import c2c_mcp


def default_alias() -> str:
    import getpass
    import socket
    user = getpass.getuser()
    host = socket.gethostname().split(".")[0]
    return f"kimi-{user}-{host}"


def default_kimi_mcp_path() -> Path:
    """Return the default Kimi MCP config path."""
    home = Path.home()
    return home / ".kimi" / "mcp.json"


def load_existing_config(mcp_path: Path) -> dict:
    """Load existing Kimi MCP config if it exists."""
    if mcp_path.exists():
        try:
            return json.loads(mcp_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def write_kimi_config(
    mcp_path: Path,
    broker_root: Path,
    session_hint: str | None = None,
    alias_hint: str | None = None,
    force: bool = False,
) -> dict:
    """Write or update Kimi MCP config with c2c server.

    Returns dict with operation result.
    """
    existing = load_existing_config(mcp_path)

    # Check if c2c already configured
    servers = existing.get("mcpServers", {})
    if "c2c" in servers and not force:
        return {
            "ok": False,
            "error": "c2c already configured (use --force to overwrite)",
            "path": str(mcp_path),
        }

    # Build c2c server config
    repo_root = Path(__file__).resolve().parent
    mcp_script = repo_root / "c2c_mcp.py"

    env = {
        "C2C_MCP_BROKER_ROOT": str(broker_root),
    }
    # Kimi has no native session ID env var; use alias as stable session ID
    # so auto_register_startup works on every restart.
    effective_session = session_hint or alias_hint
    if effective_session:
        env["C2C_MCP_SESSION_ID"] = effective_session
    if alias_hint:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias_hint
    env["C2C_MCP_AUTO_JOIN_ROOMS"] = "swarm-lounge"

    c2c_config = {
        "type": "stdio",
        "command": "python3",
        "args": [str(mcp_script)],
        "env": env,
    }

    # Update config
    servers["c2c"] = c2c_config
    existing["mcpServers"] = servers

    # Ensure directory exists
    mcp_path.parent.mkdir(parents=True, exist_ok=True)

    # Write config
    try:
        mcp_path.write_text(
            json.dumps(existing, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return {
            "ok": True,
            "path": str(mcp_path),
            "server_name": "c2c",
            "broker_root": str(broker_root),
        }
    except OSError as e:
        return {
            "ok": False,
            "error": str(e),
            "path": str(mcp_path),
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Configure c2c MCP for Kimi Code CLI")
    parser.add_argument(
        "--mcp-path",
        type=Path,
        help="path to Kimi MCP config (default: ~/.kimi/mcp.json)",
    )
    parser.add_argument(
        "--broker-root",
        type=Path,
        help="broker root directory (default: auto-detect)",
    )
    parser.add_argument(
        "--session-id",
        help="suggested session ID for auto-registration",
    )
    parser.add_argument(
        "--alias",
        help=f"stable alias for auto-registration on every restart (default: {default_alias()})",
    )
    parser.add_argument(
        "--no-alias",
        action="store_true",
        help="do not configure an auto-register alias",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite existing c2c configuration",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit JSON output",
    )
    args = parser.parse_args(argv)

    # Resolve paths
    mcp_path = args.mcp_path or default_kimi_mcp_path()

    if args.broker_root:
        broker_root = args.broker_root
    else:
        env_root = os.environ.get("C2C_MCP_BROKER_ROOT")
        if env_root:
            broker_root = Path(env_root)
        else:
            broker_root = Path(c2c_mcp.default_broker_root())

    alias = None if args.no_alias else (args.alias or default_alias())
    result = write_kimi_config(
        mcp_path=mcp_path,
        broker_root=broker_root,
        session_hint=args.session_id,
        alias_hint=alias,
        force=args.force,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if result["ok"]:
            print(f"✓ Kimi MCP config written: {result['path']}")
            print(f"  Server: c2c")
            print(f"  Broker: {result['broker_root']}")
            if alias:
                print(f"  Alias:  {alias} (auto-registers on every restart)")
            print()
            print("Next steps:")
            print("  1. Restart Kimi Code CLI to load the MCP server")
            print("  2. Run: kimi mcp test c2c")
            print("  3. Call mcp__c2c__register to claim an alias")
            print()
            print("For near-real-time auto-delivery:")
            print("  Tier 1 (manual TUI): start the wake daemon alongside Kimi:")
            print("    nohup c2c-kimi-wake --terminal-pid <ghostty-pid> --pts <pts> &")
            print("  Tier 2 (managed harness):")
            print("    1. Create run-kimi-inst.d/<name>.json with command/cwd/c2c_alias")
            print("    2. Run: ./run-kimi-inst-outer <name>")
        else:
            print(f"✗ Error: {result['error']}", file=sys.stderr)
            print(f"  Path: {result['path']}", file=sys.stderr)

    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
