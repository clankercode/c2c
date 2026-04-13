#!/usr/bin/env python3
"""Kimi Wire Bridge: deliver c2c inbox messages through Kimi's Wire JSON-RPC protocol.

The Kimi Wire protocol (`kimi --wire`) exposes a newline-delimited JSON-RPC 2.0
interface over stdin/stdout.  This bridge:

1. Starts (or wraps) a Kimi Wire subprocess.
2. Polls or watches the c2c broker inbox.
3. Drains broker messages, persists them to a spool, then delivers via Wire `prompt`.
4. Clears the spool after successful delivery.

This is the preferred native Kimi delivery path because it avoids all PTY/direct-
PTS terminal hacks.  The direct-PTS wake daemon (c2c_kimi_wake_daemon.py) remains
as a fallback for manual TUI sessions.

Usage:
    c2c-kimi-wire-bridge --session-id kimi-wire --dry-run --json
    c2c-kimi-wire-bridge --session-id kimi-wire --once --json
"""
from __future__ import annotations

import argparse
import contextlib
import html
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent

import c2c_poll_inbox


# ---------------------------------------------------------------------------
# Wire state tracker
# ---------------------------------------------------------------------------

class WireState:
    """Track Kimi Wire agent turn state from incoming Wire notifications."""

    def __init__(self) -> None:
        self.turn_active: bool = False
        self.steer_inputs: list[str] = []

    def apply_message(self, message: dict[str, Any]) -> None:
        if message.get("method") != "event":
            return
        params = message.get("params") or {}
        event_type = params.get("type")
        payload = params.get("payload") or {}
        if event_type == "TurnBegin":
            self.turn_active = True
        elif event_type == "TurnEnd":
            self.turn_active = False
        elif event_type == "SteerInput":
            user_input = payload.get("user_input")
            if isinstance(user_input, str):
                self.steer_inputs.append(user_input)


# ---------------------------------------------------------------------------
# Message formatting
# ---------------------------------------------------------------------------

def _xml_attr(value: object) -> str:
    return html.escape(str(value or ""), quote=True)


def format_c2c_envelope(message: dict[str, Any]) -> str:
    sender = _xml_attr(message.get("from_alias") or "unknown")
    alias = _xml_attr(message.get("to_alias") or "")
    content = str(message.get("content") or "")
    return (
        f'<c2c event="message" from="{sender}" alias="{alias}" '
        'source="broker" action_after="continue">\n'
        f"{content}\n"
        "</c2c>"
    )


def format_prompt(messages: list[dict[str, Any]]) -> str:
    return "\n\n".join(format_c2c_envelope(message) for message in messages)


# ---------------------------------------------------------------------------
# Durable spool (persists between drain and Wire prompt success)
# ---------------------------------------------------------------------------

class C2CSpool:
    """Durable JSON spool: messages are written here before Wire delivery.

    If the process crashes between drain and prompt, messages survive in the
    spool and will be retried on the next bridge run.
    """

    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        raw = self.path.read_text(encoding="utf-8").strip()
        if not raw:
            return []
        loaded = json.loads(raw)
        return [item for item in loaded if isinstance(item, dict)] if isinstance(loaded, list) else []

    def replace(self, messages: list[dict[str, Any]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.path.parent, prefix=self.path.name + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(messages, handle)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, self.path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def append(self, messages: list[dict[str, Any]]) -> None:
        self.replace([*self.read(), *messages])

    def clear(self) -> None:
        self.replace([])


# ---------------------------------------------------------------------------
# MCP config helper
# ---------------------------------------------------------------------------

def build_kimi_mcp_config(
    *,
    broker_root: Path,
    session_id: str,
    alias: str,
    mcp_script: Path,
) -> dict[str, Any]:
    """Build an explicit c2c MCP config dict for a Kimi Wire subprocess."""
    return {
        "mcpServers": {
            "c2c": {
                "type": "stdio",
                "command": "python3",
                "args": [str(mcp_script)],
                "env": {
                    "C2C_MCP_BROKER_ROOT": str(broker_root),
                    "C2C_MCP_SESSION_ID": session_id,
                    "C2C_MCP_AUTO_REGISTER_ALIAS": alias,
                    "C2C_MCP_AUTO_JOIN_ROOMS": "swarm-lounge",
                    "C2C_MCP_AUTO_DRAIN_CHANNEL": "0",
                },
            }
        }
    }


# ---------------------------------------------------------------------------
# Wire JSON-RPC client
# ---------------------------------------------------------------------------

class WireClient:
    """Minimal Kimi Wire JSON-RPC 2.0 client over stdin/stdout streams."""

    def __init__(self, *, stdin: Any, stdout: Any) -> None:
        self.stdin = stdin
        self.stdout = stdout
        self._next_id = 1
        self.state = WireState()

    def _request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = str(self._next_id)
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "id": request_id,
            "params": params,
        }
        self.stdin.write(json.dumps(request) + "\n")
        self.stdin.flush()
        while True:
            line = self.stdout.readline()
            if not line:
                raise RuntimeError(f"wire closed before response to {method!r}")
            message = json.loads(line)
            self.state.apply_message(message)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result") or {}

    def initialize(self) -> dict[str, Any]:
        return self._request(
            "initialize",
            {
                "protocol_version": "1.9",
                "client": {"name": "c2c-kimi-wire-bridge", "version": "0"},
                "capabilities": {"supports_question": False},
            },
        )

    def prompt(self, user_input: str) -> dict[str, Any]:
        return self._request("prompt", {"user_input": user_input})

    def steer(self, user_input: str) -> dict[str, Any]:
        return self._request("steer", {"user_input": user_input})


# ---------------------------------------------------------------------------
# Delivery logic
# ---------------------------------------------------------------------------

def default_spool_path(broker_root: Path, session_id: str) -> Path:
    return broker_root.parent / "kimi-wire" / f"{session_id}.spool.json"


def deliver_once(
    *,
    wire: WireClient,
    spool: C2CSpool,
    broker_root: Path,
    session_id: str,
    timeout: float,
) -> dict[str, Any]:
    """Initialize Wire, drain inbox to spool, deliver via prompt, clear spool.

    Spool is never cleared until after a successful prompt call — crash-safe.
    Raises RuntimeError if Wire responds with an error.
    """
    wire.initialize()
    messages = spool.read()
    if not messages:
        _source, fresh = c2c_poll_inbox.poll_inbox(
            broker_root=broker_root,
            session_id=session_id,
            timeout=timeout,
            force_file=True,
            allow_file_fallback=True,
        )
        if fresh:
            spool.append(fresh)
        messages = spool.read()
    if not messages:
        return {"ok": True, "delivered": 0}
    wire.prompt(format_prompt(messages))
    delivered = len(messages)
    spool.clear()
    return {"ok": True, "delivered": delivered}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_launch(command: str, work_dir: Path, mcp_config_file: Path) -> list[str]:
    return [command, "--wire", "--yolo", "--work-dir", str(work_dir),
            "--mcp-config-file", str(mcp_config_file)]


def run_main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Deliver c2c inbox messages through Kimi Wire JSON-RPC."
    )
    parser.add_argument("--session-id", required=True, help="broker session ID")
    parser.add_argument("--alias", help="broker alias (default: session-id)")
    parser.add_argument(
        "--broker-root", type=Path,
        default=Path(c2c_poll_inbox.default_broker_root()),
        help="broker root directory",
    )
    parser.add_argument("--work-dir", type=Path, default=ROOT, help="Kimi work dir")
    parser.add_argument("--command", default="kimi", help="kimi binary")
    parser.add_argument("--spool-path", type=Path, help="spool file path")
    parser.add_argument("--dry-run", action="store_true",
                        help="print config without starting Kimi")
    parser.add_argument("--once", action="store_true",
                        help="start Kimi, deliver, and exit")
    parser.add_argument("--json", action="store_true", help="emit JSON output")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="inbox poll timeout (seconds)")
    args = parser.parse_args(argv)

    alias = args.alias or args.session_id
    spool_path = args.spool_path or default_spool_path(args.broker_root, args.session_id)
    mcp_config_placeholder = Path("<generated-mcp-config>")
    launch = build_launch(args.command, args.work_dir, mcp_config_placeholder)

    if args.dry_run:
        payload: dict[str, Any] = {
            "ok": True,
            "dry_run": True,
            "session_id": args.session_id,
            "alias": alias,
            "launch": launch,
            "spool_path": str(spool_path),
            "broker_root": str(args.broker_root),
        }
        if args.json:
            print(json.dumps(payload))
        else:
            print(payload)
        return 0

    if args.once:
        raise SystemExit(
            "error: --once live subprocess launch is not yet implemented\n"
            "Use --dry-run to verify config, then launch Kimi manually with --wire."
        )

    parser.print_help()
    return 1


def run_main_capture(argv: list[str]) -> tuple[int, str]:
    import io as _io
    buf = _io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = run_main(argv)
    return rc, buf.getvalue()


def main(argv: list[str] | None = None) -> int:
    return run_main(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    raise SystemExit(main())
