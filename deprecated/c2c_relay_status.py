#!/usr/bin/env python3
"""c2c relay status + list — Phase 5 operator visibility.

.. deprecated::
    OCaml relay (ocaml/relay.ml) provides health/status via the MCP
    protocol's ``health`` and ``status`` commands. This Python version
    is retained for existing operator workflows only.

Commands:
    c2c relay status   — show relay health, peer count, node_id
    c2c relay list     — list all remote peers with alive/client_type/rooms

Both read from saved relay config (c2c_relay_config.py) and accept
--relay-url / --token overrides.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Optional

from c2c_relay_config import resolve_relay_params
from c2c_relay_connector import RelayClient


def _make_client(url: str, token: str, ca_bundle: str = "") -> RelayClient:
    return RelayClient(url, token=token or None, ca_bundle=ca_bundle or None)


def cmd_status(
    url: str, token: str, node_id: str, *, ca_bundle: str = "",
    json_out: bool = False,
) -> int:
    """Show relay health and basic stats."""
    client = _make_client(url, token, ca_bundle)

    health = client.health()
    if not health.get("ok"):
        if json_out:
            print(json.dumps({"ok": False, "error": "relay unreachable",
                              "url": url}))
        else:
            print(f"relay UNREACHABLE: {url}", file=sys.stderr)
        return 1

    peers = client.list_peers()
    alive = [p for p in peers if p.get("alive")]

    payload = {
        "ok": True,
        "url": url,
        "node_id": node_id or "(not set)",
        "relay_alive": True,
        "total_peers": len(peers),
        "alive_peers": len(alive),
    }

    if json_out:
        print(json.dumps(payload, indent=2))
    else:
        print(f"relay: {url}")
        print(f"  status:     OK")
        print(f"  node_id:    {payload['node_id']}")
        print(f"  peers:      {len(alive)} alive / {len(peers)} total")
    return 0


def cmd_list(
    url: str, token: str, *, ca_bundle: str = "",
    include_dead: bool = False, json_out: bool = False
) -> int:
    """List all remote peers on the relay."""
    client = _make_client(url, token, ca_bundle)

    health = client.health()
    if not health.get("ok"):
        if json_out:
            print(json.dumps({"ok": False, "error": "relay unreachable", "url": url}))
        else:
            print(f"relay UNREACHABLE: {url}", file=sys.stderr)
        return 1

    # POST /list with include_dead
    resp = client._request("POST", "/list", {"include_dead": include_dead})
    peers = resp.get("peers", [])

    if json_out:
        print(json.dumps({"ok": True, "url": url, "peers": peers}, indent=2))
        return 0

    if not peers:
        print(f"relay {url}: no {'peers' if include_dead else 'alive peers'}")
        return 0

    print(f"relay {url} — {len(peers)} peer(s):")
    for p in peers:
        alive_marker = "●" if p.get("alive") else "○"
        alias = p.get("alias", "?")
        client_type = p.get("client_type", "unknown")
        node_id = p.get("node_id", "?")
        import time as _time
        last_seen_ago = int(_time.time() - p.get("last_seen", _time.time()))
        print(f"  {alive_marker} {alias:<24} {client_type:<12} node={node_id}  "
              f"last_seen={last_seen_ago}s ago")
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    args_list = sys.argv[1:] if argv is None else list(argv)
    if not args_list:
        print(
            "usage: c2c relay status [--relay-url URL] [--token TOKEN] [--json]\n"
            "       c2c relay list   [--relay-url URL] [--token TOKEN] [--dead] [--json]",
            file=sys.stderr,
        )
        return 2

    subcommand = args_list[0]
    remainder = args_list[1:]

    if subcommand not in ("status", "list"):
        print(f"c2c relay: unknown subcommand '{subcommand}'", file=sys.stderr)
        return 2

    parser = argparse.ArgumentParser()
    parser.add_argument("--relay-url", default="")
    parser.add_argument("--token", default="")
    parser.add_argument("--token-file", default="")
    parser.add_argument("--node-id", default="")
    parser.add_argument("--json", action="store_true")
    if subcommand == "list":
        parser.add_argument("--dead", action="store_true",
                            help="Include dead (expired) peers")
    args = parser.parse_args(remainder)

    token = args.token.strip()
    if not token and args.token_file:
        from pathlib import Path
        token = Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()

    params = resolve_relay_params(
        url=args.relay_url or None,
        token=token or None,
        node_id=args.node_id or None,
    )
    ca_bundle = params.get("ca_bundle", "")

    if not params["url"]:
        print(
            "c2c relay: relay URL not configured.\n"
            "  Run: c2c relay setup --url http://host:7331\n"
            "  Or:  c2c relay status --relay-url http://host:7331",
            file=sys.stderr,
        )
        return 1

    if subcommand == "status":
        return cmd_status(params["url"], params["token"], params["node_id"],
                          ca_bundle=ca_bundle, json_out=args.json)
    else:  # list
        return cmd_list(params["url"], params["token"],
                        ca_bundle=ca_bundle,
                        include_dead=getattr(args, "dead", False),
                        json_out=args.json)


if __name__ == "__main__":
    raise SystemExit(main())
