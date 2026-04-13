#!/usr/bin/env python3
"""c2c relay server — Phase 2 of the cross-machine broker.

Runs a small HTTP relay that wraps InMemoryRelay with Bearer-token auth.
Agents on different machines connect via ``c2c relay connect`` (Phase 3).

Usage:
    python3 c2c_relay_server.py --listen 127.0.0.1:7331 --token mytoken
    python3 c2c_relay_server.py --listen 127.0.0.1:7331 --token-file ~/.config/c2c/relay.token

API (all POST, JSON body + JSON response):
    POST /register       {node_id, session_id, alias, client_type?, ttl?}
    POST /heartbeat      {node_id, session_id}
    POST /list           {}  (or GET /list)
    POST /send           {from_alias, to_alias, content, message_id?}
    POST /poll_inbox     {node_id, session_id}
    POST /peek_inbox     {node_id, session_id}
    GET  /dead_letter    — returns dead-letter queue (read-only)
    GET  /health         — no auth required; returns {"ok": true}

All endpoints except GET /health require:
    Authorization: Bearer <token>

Responses are always JSON. Errors return {"ok": false, "error_code": "...", "error": "..."}.
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from typing import Any, Optional

from c2c_relay_contract import InMemoryRelay, RelayError


# ---------------------------------------------------------------------------
# Threaded HTTP server
# ---------------------------------------------------------------------------

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in a separate thread."""
    daemon_threads = True


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

class RelayHandler(BaseHTTPRequestHandler):
    """Minimal HTTP handler for the c2c relay.

    ``server.relay``:  InMemoryRelay instance
    ``server.token``:  str — Bearer token; None means auth disabled
    """

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: D102
        # Silence default stderr logging; callers can enable via --verbose.
        if getattr(self.server, "verbose", False):
            super().log_message(fmt, *args)

    # --- auth ---

    def _authorized(self) -> bool:
        token = getattr(self.server, "token", None)
        if token is None:
            return True
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {token}"

    # --- response helpers ---

    def _send_json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, payload: dict) -> None:
        self._send_json(200, payload)

    def _err(self, code: int, error_code: str, message: str) -> None:
        self._send_json(code, {"ok": False, "error_code": error_code, "error": message})

    def _read_json(self) -> Optional[dict]:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            return None

    # --- routing ---

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._ok({"ok": True})
            return
        if not self._authorized():
            self._err(401, "unauthorized", "missing or invalid Bearer token")
            return
        if self.path == "/list":
            self._handle_list({})
        elif self.path == "/dead_letter":
            self._ok({"ok": True, "dead_letter": self.server.relay.dead_letter()})
        else:
            self._err(404, "not_found", f"unknown endpoint: {self.path}")

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._err(401, "unauthorized", "missing or invalid Bearer token")
            return
        body = self._read_json()
        if body is None:
            self._err(400, "bad_request", "request body is not valid JSON")
            return
        routes = {
            "/register": self._handle_register,
            "/heartbeat": self._handle_heartbeat,
            "/list": self._handle_list,
            "/send": self._handle_send,
            "/poll_inbox": self._handle_poll_inbox,
            "/peek_inbox": self._handle_peek_inbox,
        }
        handler = routes.get(self.path)
        if handler is None:
            self._err(404, "not_found", f"unknown endpoint: {self.path}")
            return
        try:
            handler(body)
        except RelayError as exc:
            self._send_json(409, exc.to_dict())
        except Exception as exc:
            self._err(500, "internal_error", str(exc))

    # --- endpoint handlers ---

    def _handle_register(self, body: dict) -> None:
        node_id = str(body.get("node_id", "")).strip()
        session_id = str(body.get("session_id", "")).strip()
        alias = str(body.get("alias", "")).strip()
        if not node_id or not session_id or not alias:
            self._err(400, "bad_request", "node_id, session_id, and alias are required")
            return
        kwargs: dict[str, Any] = {}
        if "client_type" in body:
            kwargs["client_type"] = str(body["client_type"])
        if "ttl" in body:
            try:
                kwargs["ttl"] = float(body["ttl"])
            except (TypeError, ValueError):
                pass
        result = self.server.relay.register(node_id, session_id, alias, **kwargs)
        self._ok(result)

    def _handle_heartbeat(self, body: dict) -> None:
        node_id = str(body.get("node_id", "")).strip()
        session_id = str(body.get("session_id", "")).strip()
        if not node_id or not session_id:
            self._err(400, "bad_request", "node_id and session_id are required")
            return
        result = self.server.relay.heartbeat(node_id, session_id)
        self._ok(result)

    def _handle_list(self, body: dict) -> None:
        include_dead = bool(body.get("include_dead", False))
        self._ok({"ok": True, "peers": self.server.relay.list_peers(include_dead=include_dead)})

    def _handle_send(self, body: dict) -> None:
        from_alias = str(body.get("from_alias", "")).strip()
        to_alias = str(body.get("to_alias", "")).strip()
        content = str(body.get("content", "")).strip()
        if not from_alias or not to_alias or not content:
            self._err(400, "bad_request", "from_alias, to_alias, and content are required")
            return
        message_id = body.get("message_id") or None
        result = self.server.relay.send(from_alias, to_alias, content, message_id=message_id)
        self._ok(result)

    def _handle_poll_inbox(self, body: dict) -> None:
        node_id = str(body.get("node_id", "")).strip()
        session_id = str(body.get("session_id", "")).strip()
        if not node_id or not session_id:
            self._err(400, "bad_request", "node_id and session_id are required")
            return
        msgs = self.server.relay.poll_inbox(node_id, session_id)
        self._ok({"ok": True, "messages": msgs})

    def _handle_peek_inbox(self, body: dict) -> None:
        node_id = str(body.get("node_id", "")).strip()
        session_id = str(body.get("session_id", "")).strip()
        if not node_id or not session_id:
            self._err(400, "bad_request", "node_id and session_id are required")
            return
        msgs = self.server.relay.peek_inbox(node_id, session_id)
        self._ok({"ok": True, "messages": msgs})


# ---------------------------------------------------------------------------
# Server lifecycle helpers
# ---------------------------------------------------------------------------

def make_server(
    host: str,
    port: int,
    token: Optional[str] = None,
    relay: Optional[InMemoryRelay] = None,
    *,
    verbose: bool = False,
) -> ThreadingHTTPServer:
    """Create (but do not start) a relay server."""
    server = ThreadingHTTPServer((host, port), RelayHandler)
    server.relay = relay or InMemoryRelay()  # type: ignore[attr-defined]
    server.token = token  # type: ignore[attr-defined]
    server.verbose = verbose  # type: ignore[attr-defined]
    return server


def start_server_thread(
    host: str = "127.0.0.1",
    port: int = 0,
    token: Optional[str] = None,
    relay: Optional[InMemoryRelay] = None,
    *,
    verbose: bool = False,
) -> tuple[ThreadingHTTPServer, threading.Thread]:
    """Start a relay server in a background thread. Returns (server, thread).

    Pass port=0 to let the OS pick a free port; read it back from
    server.server_address[1].
    """
    server = make_server(host, port, token=token, relay=relay, verbose=verbose)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def load_token(token: Optional[str], token_file: Optional[str]) -> Optional[str]:
    if token:
        return token
    if token_file:
        return Path(token_file).expanduser().read_text(encoding="utf-8").strip()
    return None


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="c2c relay server (Phase 2)")
    parser.add_argument(
        "--listen",
        default="127.0.0.1:7331",
        help="host:port to bind (default: 127.0.0.1:7331)",
    )
    parser.add_argument("--token", default="", help="Bearer token for auth")
    parser.add_argument("--token-file", default="", help="File containing Bearer token")
    parser.add_argument("--verbose", action="store_true", help="Log requests to stderr")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    token = load_token(args.token or None, args.token_file or None)

    host, _, port_str = args.listen.rpartition(":")
    if not host:
        host = "127.0.0.1"
    try:
        port = int(port_str)
    except ValueError:
        print(f"relay: invalid --listen value: {args.listen!r}", file=sys.stderr)
        return 1

    server = make_server(host, port, token=token, verbose=args.verbose)
    actual_host, actual_port = server.server_address
    print(f"c2c relay serving on http://{actual_host}:{actual_port}", flush=True)
    if token:
        print("auth: Bearer token required", flush=True)
    else:
        print("auth: DISABLED (no token set — do not expose publicly)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
