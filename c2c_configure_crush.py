#!/usr/bin/env python3
"""Configure c2c MCP for Crush CLI.

Writes ~/.config/crush/crush.json with a c2c MCP server entry.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import c2c_mcp


def default_crush_config_path() -> Path:
    """Return the default Crush config path."""
    home = Path.home()
    # Crush uses XDG_CONFIG_HOME if set, otherwise ~/.config
    xdg_config = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config:
        return Path(xdg_config) / "crush" / "crush.json"
    return home / ".config" / "crush" / "crush.json"


def load_existing_config(config_path: Path) -> dict:
    """Load existing Crush config if it exists."""
    if config_path.exists():
        try:
            return json.loads(config_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            pass
    return {"$schema": "https://charm.land/crush.json"}


def write_crush_config(
    config_path: Path,
    broker_root: Path,
    session_hint: str | None = None,
    alias_hint: str | None = None,
    force: bool = False,
) -> dict:
    """Write or update Crush config with c2c MCP server.

    Returns dict with operation result.
    """
    existing = load_existing_config(config_path)

    # Check if c2c already configured
    mcp_servers = existing.get("mcp", {})
    if "c2c" in mcp_servers and not force:
        return {
            "ok": False,
            "error": "c2c already configured (use --force to overwrite)",
            "path": str(config_path),
        }

    # Build c2c server config
    repo_root = Path(__file__).resolve().parent
    mcp_script = repo_root / "c2c_mcp.py"

    env = {
        "C2C_MCP_BROKER_ROOT": str(broker_root),
    }
    if session_hint:
        env["C2C_MCP_SESSION_ID"] = session_hint
    if alias_hint:
        env["C2C_MCP_AUTO_REGISTER_ALIAS"] = alias_hint

    c2c_config = {
        "type": "stdio",
        "command": "python3",
        "args": [str(mcp_script)],
        "env": env,
    }

    # Update config
    mcp_servers["c2c"] = c2c_config
    existing["mcp"] = mcp_servers

    # Ensure directory exists
    config_path.parent.mkdir(parents=True, exist_ok=True)

    # Write config
    try:
        config_path.write_text(
            json.dumps(existing, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        return {
            "ok": True,
            "path": str(config_path),
            "server_name": "c2c",
            "broker_root": str(broker_root),
        }
    except OSError as e:
        return {
            "ok": False,
            "error": str(e),
            "path": str(config_path),
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Configure c2c MCP for Crush CLI")
    parser.add_argument(
        "--config-path",
        type=Path,
        help="path to Crush config (default: ~/.config/crush/crush.json)",
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
        help="suggested alias for auto-registration",
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
    config_path = args.config_path or default_crush_config_path()

    if args.broker_root:
        broker_root = args.broker_root
    else:
        env_root = os.environ.get("C2C_MCP_BROKER_ROOT")
        if env_root:
            broker_root = Path(env_root)
        else:
            broker_root = Path(c2c_mcp.default_broker_root())

    result = write_crush_config(
        config_path=config_path,
        broker_root=broker_root,
        session_hint=args.session_id,
        alias_hint=args.alias,
        force=args.force,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if result["ok"]:
            print(f"✓ Crush config written: {result['path']}")
            print(f"  Server: c2c")
            print(f"  Broker: {result['broker_root']}")
            print()
            print("Next steps:")
            print("  1. Restart Crush to load the MCP server")
            print("  2. The c2c tools should appear in your tool list")
            print("  3. Call mcp__c2c__register to claim an alias")
        else:
            print(f"✗ Error: {result['error']}", file=sys.stderr)
            print(f"  Path: {result['path']}", file=sys.stderr)

    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
