#!/usr/bin/env python3
"""c2c relay connector — Phase 3 of the cross-machine broker.

Bridges a local broker root to a remote relay server.

Responsibilities:
  1. Register local aliases with the relay (on startup and after each restart).
  2. Forward outbound local-→remote messages to the relay via POST /send.
  3. Pull remote-→local messages from the relay and deliver into local inboxes.
  4. Send periodic heartbeats to keep relay leases alive.

Usage:
    python3 c2c_relay_connector.py \
        --relay-url http://127.0.0.1:7331 \
        --token mytoken \
        --node-id node-laptop-a1b2c3d4 \
        [--broker-root /path/to/.git/c2c/mcp] \
        [--interval 30] \
        [--once]

In normal operation the connector loops forever, polling the relay and syncing
local state.  Use --once for one-shot sync (useful in tests).

Local delivery:
  Inbound messages from the relay are written into the local inbox file
  (<broker-root>/inboxes/<session_id>.inbox.json) using the same append
  semantics as the OCaml broker.  The connector does NOT touch registry.json
  directly — it assumes the local MCP server manages registration there.

Remote forwarding:
  The connector scans <broker-root>/remote-outbox.jsonl for queued outbound
  messages (written by local agents using ``c2c relay send`` or a future MCP
  tool), forwards each to the relay, and removes acknowledged entries.

For the localhost two-broker proof-of-concept test, run two connectors pointing
at the same relay server, each with a different --broker-root.
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

from c2c_relay_contract import derive_node_id


# ---------------------------------------------------------------------------
# HTTP relay client
# ---------------------------------------------------------------------------

class RelayClient:
    """Thin synchronous HTTP client matching the relay server API."""

    def __init__(self, base_url: str, token: Optional[str] = None,
                 timeout: float = 10.0,
                 ca_bundle: Optional[str] = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self.ca_bundle = ca_bundle or None
        self._ssl_context: Optional[ssl.SSLContext] = None
        if self.ca_bundle and self.base_url.startswith("https://"):
            self._ssl_context = ssl.create_default_context(cafile=self.ca_bundle)

    def _request(self, method: str, path: str, body: Optional[dict] = None) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body or {}).encode()
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(
                req, timeout=self.timeout, context=self._ssl_context
            ) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            try:
                return json.loads(exc.read())
            finally:
                exc.close()
        except (urllib.error.URLError, OSError) as exc:
            return {"ok": False, "error_code": "connection_error", "error": str(exc)}

    def health(self) -> dict:
        return self._request("GET", "/health")

    def register(self, node_id: str, session_id: str, alias: str,
                 client_type: str = "unknown", ttl: float = 300.0) -> dict:
        return self._request("POST", "/register", {
            "node_id": node_id, "session_id": session_id, "alias": alias,
            "client_type": client_type, "ttl": ttl,
        })

    def heartbeat(self, node_id: str, session_id: str) -> dict:
        return self._request("POST", "/heartbeat",
                             {"node_id": node_id, "session_id": session_id})

    def list_peers(self) -> list[dict]:
        r = self._request("GET", "/list")
        return r.get("peers", [])

    def send(self, from_alias: str, to_alias: str, content: str,
             message_id: Optional[str] = None) -> dict:
        body: dict[str, Any] = {
            "from_alias": from_alias, "to_alias": to_alias, "content": content,
        }
        if message_id:
            body["message_id"] = message_id
        return self._request("POST", "/send", body)

    def poll_inbox(self, node_id: str, session_id: str) -> list[dict]:
        r = self._request("POST", "/poll_inbox",
                          {"node_id": node_id, "session_id": session_id})
        return r.get("messages", [])

    def list_rooms(self) -> list[dict]:
        r = self._request("GET", "/list_rooms")
        return r.get("rooms", [])

    def room_history(self, room_id: str, limit: int = 50) -> list[dict]:
        r = self._request("POST", "/room_history", {"room_id": room_id, "limit": limit})
        return r.get("history", [])

    def join_room(self, alias: str, room_id: str) -> dict:
        return self._request("POST", "/join_room", {"alias": alias, "room_id": room_id})

    def leave_room(self, alias: str, room_id: str) -> dict:
        return self._request("POST", "/leave_room", {"alias": alias, "room_id": room_id})

    def send_room(self, from_alias: str, room_id: str, content: str,
                  message_id: Optional[str] = None) -> dict:
        body: dict[str, Any] = {
            "from_alias": from_alias, "room_id": room_id, "content": content,
        }
        if message_id:
            body["message_id"] = message_id
        return self._request("POST", "/send_room", body)

    def gc(self) -> dict:
        return self._request("GET", "/gc")


# ---------------------------------------------------------------------------
# Local broker helpers
# ---------------------------------------------------------------------------

def load_local_registrations(broker_root: Path) -> list[dict]:
    registry = broker_root / "registry.json"
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    return [r for r in data if isinstance(r, dict)
            and r.get("session_id") and r.get("alias")]


def local_inbox_path(broker_root: Path, session_id: str) -> Path:
    return broker_root / f"{session_id}.inbox.json"


def append_to_local_inbox(broker_root: Path, session_id: str,
                          messages: list[dict]) -> int:
    """Append messages to a local session inbox JSON array.

    Uses atomic write: read existing, append, write to temp, replace.
    Returns number of messages delivered.
    """
    if not messages:
        return 0
    inbox_path = local_inbox_path(broker_root, session_id)
    try:
        existing = json.loads(inbox_path.read_text(encoding="utf-8"))
        if not isinstance(existing, list):
            existing = []
    except Exception:
        existing = []
    existing.extend(messages)
    tmp = inbox_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(existing, indent=2), encoding="utf-8")
    tmp.replace(inbox_path)
    return len(messages)


def load_outbox(broker_root: Path) -> list[dict]:
    """Read remote-outbox.jsonl (newline-delimited JSON records)."""
    outbox = broker_root / "remote-outbox.jsonl"
    if not outbox.exists():
        return []
    records = []
    for line in outbox.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return records


def save_outbox(broker_root: Path, records: list[dict]) -> None:
    """Rewrite remote-outbox.jsonl with the given records."""
    outbox = broker_root / "remote-outbox.jsonl"
    if not records:
        outbox.unlink(missing_ok=True)
        return
    outbox.write_text(
        "\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8"
    )


# ---------------------------------------------------------------------------
# Connector
# ---------------------------------------------------------------------------

class RelayConnector:
    """Bridges one local broker root to a remote relay server."""

    def __init__(
        self,
        relay_client: RelayClient,
        broker_root: Path,
        node_id: str,
        *,
        heartbeat_ttl: float = 300.0,
        verbose: bool = False,
    ) -> None:
        self.relay = relay_client
        self.broker_root = broker_root
        self.node_id = node_id
        self.heartbeat_ttl = heartbeat_ttl
        self.verbose = verbose
        self._registered: set[str] = set()  # session_ids registered this run

    def _log(self, msg: str) -> None:
        if self.verbose:
            ts = time.strftime("%H:%M:%S")
            print(f"[relay-connector {ts}] {msg}", flush=True)

    def sync(self) -> dict[str, Any]:
        """Run one sync cycle: register, forward outbox, pull inboxes."""
        result: dict[str, Any] = {
            "registered": [],
            "heartbeated": [],
            "outbox_forwarded": 0,
            "outbox_failed": 0,
            "inbound_delivered": 0,
        }

        regs = load_local_registrations(self.broker_root)
        for reg in regs:
            session_id = reg["session_id"]
            alias = reg["alias"]
            client_type = str(reg.get("client_type", "unknown"))

            if session_id not in self._registered:
                r = self.relay.register(
                    self.node_id, session_id, alias,
                    client_type=client_type, ttl=self.heartbeat_ttl,
                )
                if r.get("ok"):
                    self._registered.add(session_id)
                    result["registered"].append(alias)
                    self._log(f"registered {alias} ({session_id})")
                else:
                    # Conflict or error — log and skip
                    self._log(f"register {alias} failed: {r}")
            else:
                r = self.relay.heartbeat(self.node_id, session_id)
                if r.get("ok"):
                    result["heartbeated"].append(alias)

        # Forward outbox entries
        outbox = load_outbox(self.broker_root)
        remaining = []
        for entry in outbox:
            r = self.relay.send(
                entry.get("from_alias", ""),
                entry.get("to_alias", ""),
                entry.get("content", ""),
                message_id=entry.get("message_id"),
            )
            if r.get("ok"):
                result["outbox_forwarded"] += 1
                self._log(f"forwarded → {entry.get('to_alias')}")
            else:
                result["outbox_failed"] += 1
                remaining.append(entry)
                self._log(f"forward failed {entry.get('to_alias')}: {r}")
        save_outbox(self.broker_root, remaining)

        # Pull inbound messages for each registered session
        for reg in regs:
            session_id = reg["session_id"]
            if session_id not in self._registered:
                continue
            msgs = self.relay.poll_inbox(self.node_id, session_id)
            if msgs:
                delivered = append_to_local_inbox(self.broker_root, session_id, msgs)
                result["inbound_delivered"] += delivered
                self._log(f"delivered {delivered} inbound → {reg['alias']}")

        return result

    def run(self, interval: float = 30.0, once: bool = False) -> None:
        """Loop: sync, sleep interval, repeat.  Use once=True for one-shot."""
        while True:
            try:
                result = self.sync()
                self._log(f"sync done: {result}")
            except Exception as exc:
                self._log(f"sync error: {exc}")
            if once:
                break
            time.sleep(interval)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="c2c relay connector (Phase 3)")
    parser.add_argument("--relay-url", required=True, help="Relay server URL")
    parser.add_argument("--token", default="", help="Bearer token")
    parser.add_argument("--token-file", default="", help="File containing Bearer token")
    parser.add_argument(
        "--node-id", default="",
        help="Stable node identifier (default: auto-derived from hostname+git-remote)",
    )
    parser.add_argument(
        "--broker-root", default="",
        help="Local broker root directory (default: .git/c2c/mcp relative to git repo)",
    )
    parser.add_argument("--interval", type=float, default=30.0,
                        help="Sync interval in seconds (default: 30)")
    parser.add_argument("--ttl", type=float, default=300.0,
                        help="Relay lease TTL in seconds (default: 300)")
    parser.add_argument("--once", action="store_true", help="Run one sync and exit")
    parser.add_argument("--verbose", action="store_true", help="Log to stderr")
    parser.add_argument("--ca-bundle", default="",
                        help="PEM CA bundle for self-signed relay TLS (or C2C_RELAY_CA_BUNDLE)")
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    # Load token
    token: Optional[str] = args.token.strip() or None
    if not token and args.token_file:
        token = Path(args.token_file).expanduser().read_text(encoding="utf-8").strip()

    # Resolve node_id
    node_id = args.node_id.strip()
    if not node_id:
        try:
            node_id = derive_node_id()
        except Exception as exc:
            print(f"relay-connector: could not derive node_id: {exc}", file=sys.stderr)
            return 1

    # Resolve broker root
    broker_root: Optional[Path] = None
    if args.broker_root:
        broker_root = Path(args.broker_root).expanduser()
    else:
        try:
            import subprocess
            result = subprocess.run(
                ["git", "rev-parse", "--git-common-dir"],
                capture_output=True, text=True, timeout=3,
            )
            if result.returncode == 0:
                git_dir = Path(result.stdout.strip())
                broker_root = git_dir / "c2c" / "mcp"
        except Exception:
            pass
    if broker_root is None:
        print("relay-connector: could not find broker root; pass --broker-root",
              file=sys.stderr)
        return 1

    import os as _os
    ca_bundle = (
        args.ca_bundle.strip()
        or _os.environ.get("C2C_RELAY_CA_BUNDLE", "").strip()
        or None
    )
    client = RelayClient(args.relay_url, token=token, ca_bundle=ca_bundle)

    # Health check
    health = client.health()
    if not health.get("ok"):
        print(f"relay-connector: relay not reachable at {args.relay_url}: {health}",
              file=sys.stderr)
        return 1

    if args.verbose:
        print(f"[relay-connector] connected to {args.relay_url}, node_id={node_id}",
              flush=True)

    connector = RelayConnector(
        client, broker_root, node_id,
        heartbeat_ttl=args.ttl, verbose=args.verbose,
    )
    connector.run(interval=args.interval, once=args.once)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
