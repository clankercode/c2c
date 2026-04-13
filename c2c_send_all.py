#!/usr/bin/env python3
"""Standalone client for the c2c broker send_all fan-out primitive.

Spawns a fresh ``c2c_mcp.py`` child, issues ``tools/call`` for the
``send_all`` tool, and prints the ``{sent_to, skipped}`` result.

This is the Python CLI counterpart to ``c2c_poll_inbox.py``: deliberately
standalone so it can be used from any host client (Claude, Codex, OpenCode)
without depending on ``c2c_cli.py``, which has been under lock while the
``c2c inject`` slice lands. A future ``c2c_cli.py`` dispatch entry can wire
this in as ``c2c send-all`` once that lock clears.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import c2c_mcp

ROOT = Path(__file__).resolve().parent


def default_broker_root() -> Path:
    return Path(os.environ.get("C2C_MCP_BROKER_ROOT") or c2c_mcp.default_broker_root())


def resolve_session_id(value: str | None) -> str:
    if value:
        return value
    for name in ("C2C_MCP_SESSION_ID", "RUN_CLAUDE_INST_C2C_SESSION_ID"):
        candidate = os.environ.get(name, "").strip()
        if candidate:
            return candidate
    return "c2c-send-all"


def call_send_all(
    *,
    from_alias: str,
    content: str,
    exclude_aliases: list[str],
    broker_root: Path,
    session_id: str,
    timeout: float,
) -> dict[str, Any]:
    env = os.environ.copy()
    env["C2C_MCP_BROKER_ROOT"] = str(broker_root)
    env["C2C_MCP_SESSION_ID"] = session_id
    env["C2C_MCP_AUTO_DRAIN_CHANNEL"] = "0"
    proc = subprocess.Popen(
        [sys.executable, str(ROOT / "c2c_mcp.py")],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert proc.stdin is not None and proc.stdout is not None
        arguments: dict[str, Any] = {"from_alias": from_alias, "content": content}
        if exclude_aliases:
            arguments["exclude_aliases"] = exclude_aliases
        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "c2c-send-all", "version": "0"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "send_all", "arguments": arguments},
            },
        ]
        replies = []
        for request in requests:
            proc.stdin.write(json.dumps(request) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("MCP server exited before replying")
            replies.append(json.loads(line))
        payload = replies[-1]
        if payload.get("result", {}).get("isError"):
            raise RuntimeError(json.dumps(payload))
        text = payload["result"]["content"][0]["text"]
        parsed = json.loads(text)
        if not isinstance(parsed, dict):
            raise RuntimeError(f"unexpected send_all payload: {text}")
        return parsed
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        try:
            proc.terminate()
            proc.wait(timeout=timeout)
        except Exception:
            proc.kill()
            proc.wait(timeout=timeout)


def print_result(result: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result))
        return
    sent_to = result.get("sent_to") or []
    skipped = result.get("skipped") or []
    print(f"[c2c-send-all] delivered to {len(sent_to)} peer(s)")
    for alias in sent_to:
        print(f"  ok    {alias}")
    for entry in skipped:
        alias = entry.get("alias", "?") if isinstance(entry, dict) else "?"
        reason = entry.get("reason", "?") if isinstance(entry, dict) else "?"
        print(f"  skip  {alias}  ({reason})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fan out a c2c message to every live registered peer. Thin"
            " standalone client for the broker send_all tool."
        )
    )
    parser.add_argument(
        "--from-alias",
        required=True,
        help="sender alias (required; stamped on each delivered message)",
    )
    parser.add_argument("message", help="message body to broadcast")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="ALIAS",
        help="alias to skip (repeatable). sender is always skipped automatically.",
    )
    parser.add_argument("--broker-root", type=Path, help="broker root directory")
    parser.add_argument("--session-id", help="broker session id used by the child MCP server")
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="seconds to wait for child MCP shutdown (default: 5)",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON result")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    broker_root = args.broker_root or default_broker_root()
    session_id = resolve_session_id(args.session_id)

    try:
        result = call_send_all(
            from_alias=args.from_alias,
            content=args.message,
            exclude_aliases=list(args.exclude),
            broker_root=broker_root,
            session_id=session_id,
            timeout=args.timeout,
        )
    except Exception as exc:
        print(f"[c2c-send-all] {exc}", file=sys.stderr)
        return 1

    print_result(result, as_json=args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
