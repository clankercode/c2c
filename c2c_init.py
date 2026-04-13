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
        {str(registration.get("alias", "")) for registration in peers if registration.get("alias")}
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
    "c2c list --broker           # see who else is on the broker",
    "c2c send <alias> <msg>      # 1:1 message",
    "c2c send-all <msg>          # broadcast to every live peer (1:N)",
    "c2c poll-inbox              # drain your inbox if push delivery is polling-based",
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
            " currently registered."
        )
    )
    parser.add_argument("--broker-root", type=Path, help="broker root directory override")
    parser.add_argument("--json", action="store_true", help="emit JSON status")
    args = parser.parse_args(argv)

    broker_root = resolve_broker_root(args.broker_root)
    broker_root.mkdir(parents=True, exist_ok=True)
    status = gather_status(broker_root)
    print_status(status, as_json=args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
