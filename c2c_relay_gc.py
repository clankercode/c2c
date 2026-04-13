#!/usr/bin/env python3
"""c2c relay GC — periodic garbage collection for the relay server.

Calls GET /gc on the relay server to remove expired leases, prune stale room
memberships, and clean up orphan inboxes.  Mirrors the role of `c2c broker-gc`
for the local filesystem broker.

Usage:
    c2c relay gc [--relay-url URL] [--token TOKEN] [--interval N] [--once] [--json]

Options:
    --relay-url URL    Relay base URL (default: from saved relay config)
    --token TOKEN      Bearer token (default: from saved relay config)
    --token-file PATH  File containing Bearer token
    --interval N       Seconds between GC runs (default: 300)
    --once             Run once then exit (instead of looping)
    --json             Print GC result as JSON (useful in --once mode)
    --verbose          Log each GC run to stderr

Relay config is loaded from (in priority order):
  1. --relay-url / --token flags
  2. Environment: C2C_RELAY_URL / C2C_RELAY_TOKEN
  3. Saved config: ~/.config/c2c/relay.json or <broker-root>/relay.json
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Optional

from c2c_relay_config import resolve_relay_params
from c2c_relay_connector import RelayClient


def run_gc(client: RelayClient, *, verbose: bool = False, json_out: bool = False) -> int:
    """Call /gc once and print the result. Returns exit code."""
    resp = client._request("GET", "/gc")
    if json_out:
        print(json.dumps(resp, indent=2))
    if not resp.get("ok"):
        err = resp.get("error", "relay GC failed")
        if not json_out:
            print(f"relay gc: {err}", file=sys.stderr)
        return 1
    if verbose or json_out:
        expired = resp.get("expired_leases", [])
        pruned_inboxes = resp.get("pruned_inboxes", 0)
        if not json_out:
            ts = time.strftime("%H:%M:%S")
            print(f"[{ts}] relay gc: expired_leases={len(expired)}  "
                  f"pruned_inboxes={pruned_inboxes}",
                  file=sys.stderr)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="c2c relay GC daemon — cleans up expired relay state"
    )
    parser.add_argument("--relay-url", default="", help="Relay base URL")
    parser.add_argument("--token", default="", help="Bearer token")
    parser.add_argument("--token-file", default="", help="File containing Bearer token")
    parser.add_argument("--interval", type=float, default=300.0,
                        help="Seconds between GC runs (default: 300)")
    parser.add_argument("--once", action="store_true",
                        help="Run once and exit instead of looping")
    parser.add_argument("--json", action="store_true",
                        help="Print GC result as JSON (useful with --once)")
    parser.add_argument("--verbose", action="store_true",
                        help="Log each GC run to stderr")

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    token = args.token.strip()
    if not token and args.token_file:
        from pathlib import Path
        token = Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()

    params = resolve_relay_params(
        url=args.relay_url or None,
        token=token or None,
    )

    if not params["url"]:
        print(
            "c2c relay gc: relay URL not configured.\n"
            "  Run: c2c relay setup --url http://host:7331\n"
            "  Or:  c2c relay gc --relay-url http://host:7331",
            file=sys.stderr,
        )
        return 1

    client = RelayClient(params["url"], token=params["token"] or None)

    # Verify relay is reachable before entering loop
    health = client.health()
    if not health.get("ok"):
        print(f"relay gc: relay unreachable at {params['url']}", file=sys.stderr)
        return 1

    if not args.json:
        if args.once:
            if args.verbose:
                print(f"relay gc: running once against {params['url']}", file=sys.stderr)
        else:
            print(f"c2c relay gc: starting (interval={args.interval}s, url={params['url']})",
                  file=sys.stderr, flush=True)

    if args.once:
        return run_gc(client, verbose=args.verbose, json_out=args.json)

    # Daemon loop
    try:
        while True:
            run_gc(client, verbose=args.verbose, json_out=False)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
