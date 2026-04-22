#!/usr/bin/env python3
"""c2c relay connector — Phase 3 of the cross-machine broker.

.. deprecated::
    This module is superseded by the OCaml relay implementation
    (ocaml/relay.ml). It remains functional but is no longer actively
    developed. Use ``c2c relay connect`` which forwards to this only
    when the OCaml relay is unavailable.

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
import base64
import hashlib
import json
import os
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Optional

from c2c_relay_contract import derive_node_id


# ---------------------------------------------------------------------------
# Ed25519 peer-route signing (spec §5.1)
# ---------------------------------------------------------------------------

_UNIT_SEP = "\x1f"
_REQUEST_SIGN_CTX = "c2c/v1/request"
_REGISTER_SIGN_CTX = "c2c/v1/register"

# Routes that use Bearer (admin) — everything else is a peer route needing Ed25519.
_ADMIN_PATHS = {"/gc", "/dead_letter", "/admin/unbind"}
_UNAUTH_PATHS = {"/health", "/"}
_SELF_AUTH_PATHS = {"/register"}


def _b64url_nopad(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _load_identity(identity_path: Optional[str] = None) -> Optional[dict]:
    if identity_path is None:
        xdg = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
        identity_path = os.path.join(xdg, "c2c", "identity.json")
    path = Path(identity_path)
    if not path.exists():
        return None
    try:
        stat = path.stat()
        if stat.st_mode & 0o077:
            return None  # refuse to load world/group-readable key (mirrors OCaml)
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _sign_peer_request(identity: dict, alias: str, method: str, path: str,
                       body_bytes: bytes) -> str:
    pk_b64 = identity.get("public_key", "")
    sk_b64 = identity.get("private_key", "")
    if not pk_b64 or not sk_b64:
        raise ValueError("identity missing public_key or private_key")

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    sk_bytes = base64.urlsafe_b64decode(sk_b64 + "==")
    priv = Ed25519PrivateKey.from_private_bytes(sk_bytes)

    ts = f"{time.time():.6f}"
    nonce = _b64url_nopad(secrets.token_bytes(16))

    body_hash = (
        _b64url_nopad(hashlib.sha256(body_bytes).digest()) if body_bytes else ""
    )
    # canonical_request_blob: ctx \x1f METHOD \x1f path \x1f query \x1f body_hash \x1f ts \x1f nonce
    blob = _UNIT_SEP.join([_REQUEST_SIGN_CTX, method.upper(), path, "", body_hash, ts, nonce])
    sig = priv.sign(blob.encode())
    return f"Ed25519 alias={alias},ts={ts},nonce={nonce},sig={_b64url_nopad(sig)}"


def _sign_register_body(identity: dict, alias: str, relay_url: str) -> dict:
    """Build extra body fields for a signed /register request (body-level proof).

    Returns a dict with identity_pk, signature, nonce, timestamp fields that
    should be merged into the register request body. The relay's handle_register
    will verify this proof and bind the identity_pk to the alias for future
    Ed25519 peer route auth.

    Canonical blob (matching OCaml relay_signed_ops.sign_register):
      "c2c/v1/register" + \\x1f + alias + \\x1f + relay_url.lower() + \\x1f
        + pk_b64 + \\x1f + ts + \\x1f + nonce
    """
    pk_b64 = identity.get("public_key", "")
    sk_b64 = identity.get("private_key", "")
    if not pk_b64 or not sk_b64:
        raise ValueError("identity missing public_key or private_key")

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    sk_bytes = base64.urlsafe_b64decode(sk_b64 + "==")
    priv = Ed25519PrivateKey.from_private_bytes(sk_bytes)

    import datetime
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    nonce = _b64url_nopad(secrets.token_bytes(16))

    blob = _UNIT_SEP.join([_REGISTER_SIGN_CTX, alias,
                           relay_url.lower().rstrip("/"), pk_b64, ts, nonce])
    sig = priv.sign(blob.encode())
    return {
        "identity_pk": pk_b64,
        "signature": _b64url_nopad(sig),
        "nonce": nonce,
        "timestamp": ts,
    }


# Room op sign contexts (matching Relay.room_*_sign_ctx in OCaml).
_ROOM_JOIN_SIGN_CTX = "c2c/v1/room-join"
_ROOM_LEAVE_SIGN_CTX = "c2c/v1/room-leave"
_ROOM_SEND_SIGN_CTX = "c2c/v1/room-send"
_ROOM_INVITE_SIGN_CTX = "c2c/v1/room-invite"
_ROOM_UNINVITE_SIGN_CTX = "c2c/v1/room-uninvite"
_ROOM_SET_VISIBILITY_SIGN_CTX = "c2c/v1/room-set-visibility"


def _sign_room_op(identity: dict, ctx: str, room_id: str, alias: str) -> dict:
    """Build body-level Ed25519 proof for a room mutation op.

    Returns a dict with identity_pk, signature, nonce, timestamp fields that
    should be merged into the request body. Mirrors OCaml
    Relay_signed_ops.sign_room_op.

    Canonical blob (matching relay_signed_ops.ml):
      ctx + \\x1f + room_id + \\x1f + alias + \\x1f + pk_b64 + \\x1f + ts + \\x1f + nonce
    """
    pk_b64 = identity.get("public_key", "")
    sk_b64 = identity.get("private_key", "")
    if not pk_b64 or not sk_b64:
        raise ValueError("identity missing public_key or private_key")

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    sk_bytes = base64.urlsafe_b64decode(sk_b64 + "==")
    priv = Ed25519PrivateKey.from_private_bytes(sk_bytes)

    import datetime
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    nonce = _b64url_nopad(secrets.token_bytes(16))

    blob = _UNIT_SEP.join([ctx, room_id, alias, pk_b64, ts, nonce])
    sig = priv.sign(blob.encode())
    return {
        "identity_pk": pk_b64,
        "signature": _b64url_nopad(sig),
        "nonce": nonce,
        "timestamp": ts,
    }


def _sign_send_room(identity: dict, room_id: str, from_alias: str,
                    content: str) -> dict:
    """Build a signed §2 envelope for /send_room.

    Returns the full envelope dict {ct, enc, sender_pk, sig, ts, nonce}
    to attach as the "envelope" field in the send_room body.
    Mirrors OCaml Relay_signed_ops.sign_send_room.

    Canonical blob:
      "c2c/v1/room-send" + \\x1f + room_id + \\x1f + from_alias + \\x1f
      + pk_b64 + \\x1f + "none" + \\x1f + sha256(content) + \\x1f + ts + \\x1f + nonce
    """
    import hashlib
    pk_b64 = identity.get("public_key", "")
    sk_b64 = identity.get("private_key", "")
    if not pk_b64 or not sk_b64:
        raise ValueError("identity missing public_key or private_key")

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    sk_bytes = base64.urlsafe_b64decode(sk_b64 + "==")
    priv = Ed25519PrivateKey.from_private_bytes(sk_bytes)

    ct_bytes = content.encode("utf-8")
    ct_b64 = _b64url_nopad(ct_bytes)
    ct_hash = _b64url_nopad(hashlib.sha256(ct_bytes).digest())

    import datetime
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    nonce = _b64url_nopad(secrets.token_bytes(16))
    enc = "none"

    blob = _UNIT_SEP.join([_ROOM_SEND_SIGN_CTX, room_id, from_alias,
                           pk_b64, enc, ct_hash, ts, nonce])
    sig = priv.sign(blob.encode())
    return {
        "ct": ct_b64,
        "enc": enc,
        "sender_pk": pk_b64,
        "sig": _b64url_nopad(sig),
        "ts": ts,
        "nonce": nonce,
    }


# ---------------------------------------------------------------------------
# HTTP relay client
# ---------------------------------------------------------------------------

class RelayClient:
    """Thin synchronous HTTP client matching the relay server API."""

    def __init__(self, base_url: str, token: Optional[str] = None,
                 timeout: float = 10.0,
                 ca_bundle: Optional[str] = None,
                 identity_path: Optional[str] = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self.ca_bundle = ca_bundle or None
        self._ssl_context: Optional[ssl.SSLContext] = None
        if self.ca_bundle and self.base_url.startswith("https://"):
            self._ssl_context = ssl.create_default_context(cafile=self.ca_bundle)
        # Only load identity when explicitly requested (identity_path supplied or
        # C2C_RELAY_IDENTITY_PATH env var set). Auto-loading would break tests that
        # use the Python relay server stub which only accepts Bearer auth.
        effective_path = identity_path or os.environ.get("C2C_RELAY_IDENTITY_PATH", "")
        self._identity = _load_identity(effective_path) if effective_path else None
        self._alias: Optional[str] = None  # set by caller when known

    def _request(self, method: str, path: str, body: Optional[dict] = None,
                 auth_override: Optional[str] = None, alias: Optional[str] = None) -> dict:
        url = f"{self.base_url}{path}"
        body_bytes = json.dumps(body or {}).encode()
        req = urllib.request.Request(url, data=body_bytes, method=method)
        req.add_header("Content-Type", "application/json")

        base_path = path.split("?")[0]
        effective_alias = alias or self._alias
        is_admin = (
            base_path in _ADMIN_PATHS
            or (path.startswith("/list") and "include_dead" in path)
        )
        is_unauth = base_path in _UNAUTH_PATHS
        if auth_override:
            req.add_header("Authorization", auth_override)
        elif is_unauth:
            pass  # /health, / — no auth
        elif self._identity and effective_alias and not is_admin:
            # Prod OCaml relay: peer routes need Ed25519, not Bearer.
            try:
                auth = _sign_peer_request(self._identity, effective_alias, method, base_path, body_bytes)
                req.add_header("Authorization", auth)
            except Exception:
                if self.token:
                    req.add_header("Authorization", f"Bearer {self.token}")
        elif self.token:
            # Dev mode / Python relay / admin routes: Bearer token.
            req.add_header("Authorization", f"Bearer {self.token}")

        try:
            with urllib.request.urlopen(
                req, timeout=self.timeout, context=self._ssl_context
            ) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            try:
                body = exc.read()
                return json.loads(body)
            except (json.JSONDecodeError, ValueError):
                return {"ok": False, "error_code": str(exc.code), "error": body.decode("utf-8", errors="replace")}
            finally:
                exc.close()
        except (urllib.error.URLError, OSError) as exc:
            return {"ok": False, "error_code": "connection_error", "error": str(exc)}

    def health(self) -> dict:
        return self._request("GET", "/health")

    def register(self, node_id: str, session_id: str, alias: str,
                 client_type: str = "unknown", ttl: float = 300.0) -> dict:
        body: dict = {
            "node_id": node_id, "session_id": session_id, "alias": alias,
            "client_type": client_type, "ttl": int(ttl),
        }
        if self._identity:
            try:
                extra = _sign_register_body(self._identity, alias, self.base_url)
                body.update(extra)
            except Exception:
                pass  # unsigned register — falls back to legacy (no pk binding)
        return self._request("POST", "/register", body)

    def heartbeat(self, node_id: str, session_id: str, alias: Optional[str] = None) -> dict:
        return self._request("POST", "/heartbeat",
                             {"node_id": node_id, "session_id": session_id},
                             alias=alias)

    def list_peers(self, alias: Optional[str] = None) -> list[dict]:
        r = self._request("GET", "/list", alias=alias)
        return r.get("peers", [])

    def send(self, from_alias: str, to_alias: str, content: str,
             message_id: Optional[str] = None) -> dict:
        body: dict[str, Any] = {
            "from_alias": from_alias, "to_alias": to_alias, "content": content,
        }
        if message_id:
            body["message_id"] = message_id
        return self._request("POST", "/send", body, alias=from_alias)

    def poll_inbox(self, node_id: str, session_id: str, alias: Optional[str] = None) -> list[dict]:
        r = self._request("POST", "/poll_inbox",
                          {"node_id": node_id, "session_id": session_id},
                          alias=alias)
        return r.get("messages", [])

    def list_rooms(self) -> list[dict]:
        r = self._request("GET", "/list_rooms")
        return r.get("rooms", [])

    def room_history(self, room_id: str, limit: int = 50) -> list[dict]:
        r = self._request("POST", "/room_history", {"room_id": room_id, "limit": limit})
        return r.get("history", [])

    def join_room(self, alias: str, room_id: str) -> dict:
        body: dict[str, Any] = {"alias": alias, "room_id": room_id}
        if self._identity:
            try:
                body.update(_sign_room_op(self._identity, _ROOM_JOIN_SIGN_CTX,
                                          room_id, alias))
            except Exception:
                pass  # unsigned — falls back to legacy
        return self._request("POST", "/join_room", body, alias=alias)

    def leave_room(self, alias: str, room_id: str) -> dict:
        body: dict[str, Any] = {"alias": alias, "room_id": room_id}
        if self._identity:
            try:
                body.update(_sign_room_op(self._identity, _ROOM_LEAVE_SIGN_CTX,
                                          room_id, alias))
            except Exception:
                pass  # unsigned — falls back to legacy
        return self._request("POST", "/leave_room", body, alias=alias)

    def send_room(self, from_alias: str, room_id: str, content: str,
                  message_id: Optional[str] = None) -> dict:
        body: dict[str, Any] = {
            "from_alias": from_alias, "room_id": room_id, "content": content,
        }
        if message_id:
            body["message_id"] = message_id
        # L4/2: sign the send envelope when identity is available.
        if self._identity:
            try:
                body["envelope"] = _sign_send_room(self._identity, room_id,
                                                    from_alias, content)
            except Exception:
                pass  # unsigned — falls back to legacy
        return self._request("POST", "/send_room", body, alias=from_alias)

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
                r = self.relay.heartbeat(self.node_id, session_id, alias=alias)
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
            msgs = self.relay.poll_inbox(self.node_id, session_id, alias=reg["alias"])
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
    parser.add_argument("--identity-path", default="",
                        help="Path to Ed25519 identity.json for peer-route signing "
                             "(default: $C2C_RELAY_IDENTITY_PATH; omit to use Bearer-only auth)")
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
    identity_path = (
        args.identity_path.strip()
        or _os.environ.get("C2C_RELAY_IDENTITY_PATH", "").strip()
        or None
    )
    client = RelayClient(args.relay_url, token=token, ca_bundle=ca_bundle,
                         identity_path=identity_path)

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
