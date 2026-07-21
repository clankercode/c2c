#!/usr/bin/env python3
"""Bootstrap and status command for a c2c broker root.

`c2c init` is the one-shot "welcome mat" for a new agent (or a new
checkout, or a new operator). It:

1. Resolves the broker root (env override or default git-common-dir).
2. Ensures the broker directory exists.
3. Prints the broker root path and how many peers are currently
   registered in the broker registry.
4. Echoes the host client's best entry points (`c2c register`,
   `c2c send`, `c2c send-all`, `c2c poll-inbox`) so a fresh agent can
   self-onboard without reading any docs.

The command is intentionally idempotent and non-destructive: running it
twice never changes state beyond creating the broker directory if it
was missing. Peer-registration remains an explicit `c2c register` step.

Long term this is also the hook for `c2c join <room-id>` (phase 2
rooms design, see
`.collab/findings/2026-04-13T04-00-00Z-storm-echo-broadcast-and-rooms-design.md`).
For now `c2c init` just proves the broker is reachable.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import c2c_mcp


def resolve_broker_root(cli_override: Path | None) -> Path:
    if cli_override is not None:
        return cli_override
    env_value = os.environ.get("C2C_MCP_BROKER_ROOT")
    if env_value:
        return Path(env_value)
    return Path(c2c_mcp.default_broker_root())


def gather_status(broker_root: Path) -> dict[str, Any]:
    registry_path = broker_root / "registry.json"
    peers = c2c_mcp.load_broker_registrations(registry_path)
    aliases = sorted(
        {
            str(registration.get("alias", ""))
            for registration in peers
            if registration.get("alias")
        }
    )
    return {
        "broker_root": str(broker_root),
        "broker_root_exists": broker_root.exists(),
        "registry_exists": registry_path.exists(),
        "peer_count": len(peers),
        "aliases": aliases,
    }


NEXT_STEPS = [
    "c2c register <session-id>   # once per session, hands out a broker alias",
    "c2c list --all           # see who else is on the broker",
    "c2c send <alias> <msg>      # 1:1 message",
    "c2c send-all <msg>          # broadcast to every live peer (1:N)",
    "c2c poll-inbox              # drain your inbox if push delivery is polling-based",
    "c2c room list               # list all N:N rooms",
    "c2c room join <room-id>     # join a room (e.g. swarm-lounge)",
    "c2c room send <room-id> <msg>  # send to a room",
    "c2c health                  # verify your setup (MCP config, wake daemon, etc.)",
    "c2c install claude  # configure Claude Code delivery",
]


def print_status(status: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(status, indent=2))
        return
    print(f"c2c broker root: {status['broker_root']}")
    if not status["broker_root_exists"]:
        print("  (just created)")
    if status["peer_count"] == 0:
        print("peers: 0 registered")
    else:
        print(f"peers: {status['peer_count']} registered")
        for alias in status["aliases"]:
            print(f"  - {alias}")
    print()
    print("next steps:")
    for line in NEXT_STEPS:
        print(f"  {line}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Bootstrap / status check for the c2c broker root. Ensures the"
            " broker directory exists and prints how many peers are"
            " currently registered. With room_id, also creates/joins the room."
        )
    )
    parser.add_argument("room_id", nargs="?", help="optional room to create/join")
    parser.add_argument(
        "--broker-root", type=Path, help="broker root directory override"
    )
    parser.add_argument("--json", action="store_true", help="emit JSON status")
    args = parser.parse_args(argv)

    broker_root = resolve_broker_root(args.broker_root)
    broker_root.mkdir(parents=True, exist_ok=True)

    # If room_id provided, create/init the room and auto-join current session
    if args.room_id:
        import c2c_room
        import c2c_whoami

        # Create/init the room
        init_result = c2c_room.init_room(args.room_id, broker_root)
        if not init_result.get("ok"):
            if args.json:
                print(
                    json.dumps(
                        {"ok": False, "error": init_result.get("error", "unknown")}
                    )
                )
            else:
                print(f"error: {init_result.get('error', 'unknown')}", file=sys.stderr)
            return 1

        # Auto-resolve current identity for joining
        try:
            session_info, registration = c2c_whoami.resolve_identity(None)
            alias = registration.get("alias") if registration else None
            session_id = session_info.get("session_id") if session_info else None
        except Exception:
            alias = None
            session_id = None

        if not alias or not session_id:
            if args.json:
                print(
                    json.dumps(
                        {
                            "ok": False,
                            "error": "cannot resolve identity; run 'c2c register' first",
                            "init": init_result,
                        }
                    )
                )
            else:
                print(
                    "error: cannot resolve identity; run 'c2c register' first",
                    file=sys.stderr,
                )
            return 1

        # Join the room
        join_result = c2c_room.join_room(args.room_id, alias, session_id, broker_root)
        if args.json:
            print(
                json.dumps(
                    {
                        "ok": join_result.get("ok", False),
                        "room_id": args.room_id,
                        "alias": alias,
                        "session_id": session_id,
                        "init": init_result,
                        "join": join_result,
                    }
                )
            )
        else:
            if join_result.get("ok", False):
                print(f"initialized and joined room: {args.room_id}")
                print(f"  alias: {alias}")
                print(f"  session_id: {session_id}")
            else:
                print(
                    f"room initialized but join failed: {join_result.get('error', 'unknown')}"
                )
        return 0 if join_result.get("ok", False) else 1

    status = gather_status(broker_root)
    print_status(status, as_json=args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
