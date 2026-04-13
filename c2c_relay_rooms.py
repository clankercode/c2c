#!/usr/bin/env python3
"""c2c relay rooms — CLI wrapper for relay server room operations.

Commands mirror `c2c room` but route through the relay instead of the local
filesystem, so agents on different machines can interact with shared rooms.

Usage:
    c2c relay rooms list     [--relay-url URL] [--token TOKEN] [--json]
    c2c relay rooms join     <room_id> [--alias ALIAS] [--relay-url URL] [--json]
    c2c relay rooms leave    <room_id> [--alias ALIAS] [--relay-url URL] [--json]
    c2c relay rooms send     <room_id> <message...> [--alias ALIAS] [--relay-url URL] [--json]
    c2c relay rooms history  <room_id> [--limit N] [--relay-url URL] [--json]

Relay config (URL + token) is loaded from:
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


# ---------------------------------------------------------------------------
# Relay room helpers
# ---------------------------------------------------------------------------

def _make_client(url: str, token: str) -> RelayClient:
    return RelayClient(url, token=token or None)


def cmd_list(url: str, token: str, *, json_out: bool = False) -> int:
    client = _make_client(url, token)
    resp = client._request("GET", "/list_rooms")
    if not resp.get("ok"):
        err = resp.get("error", "relay request failed")
        print(f"relay rooms list: {err}", file=sys.stderr)
        return 1
    rooms = resp.get("rooms", [])
    if json_out:
        print(json.dumps({"ok": True, "rooms": rooms}, indent=2))
        return 0
    if not rooms:
        print("relay: no rooms found")
        return 0
    print(f"relay {url} — {len(rooms)} room(s):")
    for r in rooms:
        rid = r.get("room_id", "?")
        members = r.get("members", [])
        count = r.get("member_count", len(members))
        names = ", ".join(str(m) for m in members) if members else "(empty)"
        print(f"  {rid:<24} {count} member(s): {names}")
    return 0


def cmd_join(url: str, token: str, room_id: str, alias: str,
             *, json_out: bool = False) -> int:
    client = _make_client(url, token)
    resp = client._request("POST", "/join_room", {"alias": alias, "room_id": room_id})
    if json_out:
        print(json.dumps(resp, indent=2))
        return 0 if resp.get("ok") else 1
    if not resp.get("ok"):
        print(f"relay join_room: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    if resp.get("already_member"):
        print(f"already in room {room_id} as {alias}")
    else:
        print(f"joined room {room_id} as {alias}")
    return 0


def cmd_leave(url: str, token: str, room_id: str, alias: str,
              *, json_out: bool = False) -> int:
    client = _make_client(url, token)
    resp = client._request("POST", "/leave_room", {"alias": alias, "room_id": room_id})
    if json_out:
        print(json.dumps(resp, indent=2))
        return 0 if resp.get("ok") else 1
    if not resp.get("ok"):
        print(f"relay leave_room: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    if resp.get("removed"):
        print(f"left room {room_id} (alias={alias}, {resp.get('member_count', '?')} remaining)")
    else:
        print(f"not a member of room {room_id} (alias={alias})")
    return 0


def cmd_send(url: str, token: str, room_id: str, from_alias: str, content: str,
             *, json_out: bool = False) -> int:
    client = _make_client(url, token)
    resp = client._request("POST", "/send_room", {
        "from_alias": from_alias,
        "room_id": room_id,
        "content": content,
    })
    if json_out:
        print(json.dumps(resp, indent=2))
        return 0 if resp.get("ok") else 1
    if not resp.get("ok"):
        print(f"relay send_room: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    delivered = resp.get("delivered_to", [])
    skipped = resp.get("skipped", [])
    print(f"sent to room {room_id}: {len(delivered)} delivered, {len(skipped)} skipped")
    if skipped:
        for s in skipped:
            print(f"  skipped {s.get('alias', '?')}: {s.get('reason', '?')}")
    return 0


def cmd_history(url: str, token: str, room_id: str, limit: int,
                *, json_out: bool = False) -> int:
    client = _make_client(url, token)
    resp = client._request("POST", "/room_history", {"room_id": room_id, "limit": limit})
    if json_out:
        print(json.dumps(resp, indent=2))
        return 0 if resp.get("ok") else 1
    if not resp.get("ok"):
        print(f"relay room_history: {resp.get('error', 'unknown error')}", file=sys.stderr)
        return 1
    history = resp.get("history", [])
    if not history:
        print(f"room {room_id}: no history")
        return 0
    for entry in history:
        ts = entry.get("ts", 0)
        ts_str = time.strftime("%H:%M:%S", time.localtime(ts)) if ts else "?"
        from_a = entry.get("from_alias", "?")
        content = entry.get("content", "")
        print(f"[{ts_str}] {from_a}: {content}")
    return 0


# ---------------------------------------------------------------------------
# Self-alias resolution (same logic as c2c_room.py, without filesystem dep)
# ---------------------------------------------------------------------------

def _resolve_alias_from_env() -> str:
    """Best-effort alias from environment vars."""
    import os
    env_sid = (os.environ.get("C2C_MCP_SESSION_ID", "").strip()
               or os.environ.get("C2C_SESSION_ID", "").strip())
    if env_sid:
        # Try to look up alias from broker registry
        try:
            import c2c_mcp
            import json as _json
            from pathlib import Path as _Path
            broker_root = _Path(os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root())
            registry = broker_root / "registry.json"
            regs = _json.loads(registry.read_text()) if registry.exists() else []
            for reg in regs:
                if reg.get("session_id") == env_sid and reg.get("alias"):
                    return reg["alias"]
        except Exception:
            pass
        return env_sid  # fall back to session_id as alias
    # Try c2c_whoami
    try:
        import c2c_whoami
        _session, reg = c2c_whoami.resolve_identity(None)
        alias = (reg or {}).get("alias")
        if alias:
            return alias
    except Exception:
        pass
    return "unknown"


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    args_list = sys.argv[1:] if argv is None else list(argv)

    # Parse shared flags first (allowing them before or after the subcommand)
    pre_parser = argparse.ArgumentParser(add_help=False)
    pre_parser.add_argument("--relay-url", default="")
    pre_parser.add_argument("--token", default="")
    pre_parser.add_argument("--token-file", default="")
    pre_parser.add_argument("--json", action="store_true")
    pre_parser.add_argument("--alias", default="")
    # Collect positional (subcommand + subcommand args) separately
    pre_args, positional = pre_parser.parse_known_args(args_list)

    # First positional is the subcommand
    USAGE = (
        "usage: c2c relay rooms <subcommand> ...\n"
        "  list     [--relay-url URL] [--token TOKEN] [--json]\n"
        "  join     <room_id> [--alias ALIAS] [--relay-url URL] [--json]\n"
        "  leave    <room_id> [--alias ALIAS] [--relay-url URL] [--json]\n"
        "  send     <room_id> <message...> [--alias ALIAS] [--relay-url URL] [--json]\n"
        "  history  <room_id> [--limit N] [--relay-url URL] [--json]"
    )

    if not positional or positional[0] in ("-h", "--help"):
        print(USAGE)
        return 2

    subcommand = positional[0]
    sub_args = positional[1:]

    VALID_SUBCOMMANDS = ("list", "join", "leave", "send", "history")
    if subcommand not in VALID_SUBCOMMANDS:
        print(f"c2c relay rooms: unknown subcommand '{subcommand}'", file=sys.stderr)
        return 2

    # Parse subcommand-specific positional args
    room_id: str = ""
    message: str = ""
    limit: int = 50

    if subcommand in ("join", "leave", "send", "history"):
        if not sub_args:
            print(f"c2c relay rooms {subcommand}: room_id required", file=sys.stderr)
            return 2
        room_id = sub_args[0]
        sub_args = sub_args[1:]

    if subcommand == "send":
        # Re-parse remaining for --limit and positional message words
        msg_parser = argparse.ArgumentParser(add_help=False)
        msg_parser.add_argument("words", nargs="*")
        msg_args, _ = msg_parser.parse_known_args(sub_args)
        if not msg_args.words:
            print("c2c relay rooms send: message required", file=sys.stderr)
            return 2
        message = " ".join(msg_args.words)

    if subcommand == "history":
        lim_parser = argparse.ArgumentParser(add_help=False)
        lim_parser.add_argument("--limit", type=int, default=50)
        lim_args, _ = lim_parser.parse_known_args(sub_args)
        limit = lim_args.limit

    # Resolve token from file if given
    token = pre_args.token.strip()
    if not token and pre_args.token_file:
        from pathlib import Path
        token = Path(pre_args.token_file).expanduser().read_text(encoding="utf-8").strip()

    params = resolve_relay_params(
        url=pre_args.relay_url or None,
        token=token or None,
    )

    if not params["url"]:
        print(
            "c2c relay rooms: relay URL not configured.\n"
            "  Run: c2c relay setup --url http://host:7331\n"
            "  Or:  c2c relay rooms list --relay-url http://host:7331",
            file=sys.stderr,
        )
        return 1

    url: str = params["url"]
    tok: str = params["token"]
    alias = pre_args.alias.strip() if pre_args.alias else _resolve_alias_from_env()
    json_out: bool = pre_args.json

    if subcommand == "list":
        return cmd_list(url, tok, json_out=json_out)
    elif subcommand == "join":
        return cmd_join(url, tok, room_id, alias, json_out=json_out)
    elif subcommand == "leave":
        return cmd_leave(url, tok, room_id, alias, json_out=json_out)
    elif subcommand == "send":
        return cmd_send(url, tok, room_id, alias, message, json_out=json_out)
    elif subcommand == "history":
        return cmd_history(url, tok, room_id, limit, json_out=json_out)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
