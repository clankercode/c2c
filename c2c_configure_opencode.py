#!/usr/bin/env python3
"""Write a repo-local OpenCode config that exposes the c2c MCP server.

Usage: c2c configure-opencode [--target-dir DIR] [--force] [--json]

Generates `<target>/.opencode/opencode.json` with a single `c2c` MCP
entry pointing at this repo's `c2c_mcp.py` (absolute path) and
broker root (this repo's `.git/c2c/mcp`). The session id is derived
from the target directory's basename so multiple opencode peers in
different repos can co-exist on one shared broker.

Refuses to overwrite an existing `.opencode/opencode.json` unless
`--force` is given. The point is one-command opencode-c2c onboarding
for any repo without hand-editing settings.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
C2C_MCP_PATH = REPO_ROOT / "c2c_mcp.py"
BROKER_ROOT = REPO_ROOT / ".git" / "c2c" / "mcp"


def derive_session_id(target_dir: Path) -> str:
    return f"opencode-{target_dir.name}"


def build_config(session_id: str, alias: str) -> dict:
    return {
        "$schema": "https://opencode.ai/config.json",
        "mcp": {
            "c2c": {
                "type": "local",
                "command": ["python3", str(C2C_MCP_PATH)],
                "environment": {
                    "C2C_MCP_BROKER_ROOT": str(BROKER_ROOT),
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                },
                "enabled": True,
            }
        },
    }


def write_config(
    target_dir: Path, *, force: bool, alias: str | None = None
) -> tuple[Path, str, str]:
    target_dir = target_dir.resolve()
    if not target_dir.exists():
        raise SystemExit(f"target dir does not exist: {target_dir}")
    config_dir = target_dir / ".opencode"
    config_path = config_dir / "opencode.json"
    if config_path.exists() and not force:
        raise SystemExit(
            f"refusing to overwrite: {config_path} already exists "
            f"(re-run with --force to replace)"
        )
    config_dir.mkdir(parents=True, exist_ok=True)
    session_id = derive_session_id(target_dir)
    resolved_alias = alias if alias else session_id
    config_path.write_text(
        json.dumps(build_config(session_id, resolved_alias), indent=2) + "\n",
        encoding="utf-8",
    )
    return config_path, session_id, resolved_alias


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=("Write a repo-local OpenCode config exposing the c2c MCP server.")
    )
    parser.add_argument(
        "--target-dir",
        type=Path,
        default=Path.cwd(),
        help="directory to write .opencode/opencode.json into (default: cwd)",
    )
    parser.add_argument(
        "--alias",
        default=None,
        help=(
            "stable broker alias (default: same as session id, i.e. opencode-<dir-name>). "
            "Use this when you want a custom name peers use to address this instance."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing .opencode/opencode.json",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    args = parser.parse_args(argv)

    config_path, session_id, resolved_alias = write_config(
        args.target_dir, force=args.force, alias=args.alias
    )
    payload = {
        "config_path": str(config_path),
        "target_dir": str(args.target_dir.resolve()),
        "session_id": session_id,
        "alias": resolved_alias,
        "broker_root": str(BROKER_ROOT),
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"wrote {config_path}")
        print(f"  session id: {session_id}")
        print(f"  alias:      {resolved_alias}")
        print(f"  broker root: {BROKER_ROOT}")
        print(
            "Now run 'cd "
            + str(args.target_dir.resolve())
            + " && opencode mcp list' to verify, or launch opencode from that dir."
        )
        print()
        print("For near-real-time auto-delivery in a manual TUI session:")
        print("  nohup c2c-opencode-wake --terminal-pid <ghostty-pid> --pts <pts> &")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
