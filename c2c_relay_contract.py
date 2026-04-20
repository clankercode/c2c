#!/usr/bin/env python3
"""In-process relay for cross-machine broker contract tests (Phase 1).

This module defines the contracts that any c2c relay implementation must honour,
and provides an `InMemoryRelay` that implements those contracts entirely in
process — no network, no filesystem — for fast, deterministic unit tests.

When the real relay server (Phase 2) exists, its tests should use the same
`RelayContract` test mix-in to verify parity.

Contracts (from docs/cross-machine-broker.md):
  - Alias resolves to one current session (by {node_id, session_id})
  - send appends to one recipient inbox atomically
  - poll_inbox drains and returns each message exactly once
  - peek_inbox is read-only and returns the same shape as poll
  - Liveness is heartbeat-lease based, not PID-based
  - Dead recipients produce dead-letter or clear errors, not silent loss
  - node_id is stable per machine/workspace and included in all registry rows

Usage in tests:
    relay = InMemoryRelay()
    relay.register("node-a", "session-1", alias="codex")
    relay.send("codex", "codex", "hello from myself")  # same alias is ok
    msgs = relay.poll_inbox("node-a", "session-1")
    assert msgs[0]["content"] == "hello from myself"
"""
from __future__ import annotations

import socket
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# node_id derivation
# ---------------------------------------------------------------------------

def derive_node_id(repo_root: Optional[Path] = None) -> str:
    """Return a stable, collision-resistant node identifier for this machine.

    Combines hostname (machine-local) with a hash of the git remote URL
    (workspace-local) so two machines using different repos stay distinct even
    if they share a hostname (e.g., docker containers).

    Format: ``<hostname>-<8-char-prefix-of-sha256(remote-url)>``.

    Falls back to ``<hostname>-local`` when the git remote URL is unavailable.
    """
    hostname = socket.gethostname()
    try:
        result = subprocess.run(
            ["git", "config", "--get", "remote.origin.url"],
            capture_output=True,
            text=True,
            timeout=3,
            cwd=str(repo_root) if repo_root else None,
        )
        remote_url = result.stdout.strip()
    except Exception:
        remote_url = ""

    if remote_url:
        import hashlib
        digest = hashlib.sha256(remote_url.encode()).hexdigest()[:8]
        return f"{hostname}-{digest}"
    return f"{hostname}-local"


# ---------------------------------------------------------------------------
# Relay error codes
# ---------------------------------------------------------------------------

class RelayError(Exception):
    """Structured relay error with a machine-readable code and human message."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message

    def to_dict(self) -> dict:
        return {"ok": False, "error_code": self.code, "error": self.message}


RELAY_ERR_UNKNOWN_ALIAS = "unknown_alias"
RELAY_ERR_ALIAS_CONFLICT = "alias_conflict"
RELAY_ERR_SESSION_DEAD = "session_dead"
RELAY_ERR_RECIPIENT_DEAD = "recipient_dead"
ROOM_SYSTEM_ALIAS = "c2c-system"


def room_join_content(alias: str, room_id: str) -> str:
    return f"{alias} joined room {room_id}"


# ---------------------------------------------------------------------------
# Registration lease
# ---------------------------------------------------------------------------

@dataclass
class RegistrationLease:
    """A single registered session with a heartbeat-based liveness lease."""

    node_id: str
    session_id: str
    alias: str
    client_type: str = "unknown"
    registered_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)
    ttl: float = 300.0  # seconds; dead if last_seen + ttl < now

    def is_alive(self, now: Optional[float] = None) -> bool:
        t = now if now is not None else time.time()
        return (self.last_seen + self.ttl) >= t

    def to_dict(self) -> dict:
        now = time.time()
        return {
            "node_id": self.node_id,
            "session_id": self.session_id,
            "alias": self.alias,
            "client_type": self.client_type,
            "registered_at": self.registered_at,
            "last_seen": self.last_seen,
            "ttl": self.ttl,
            "alive": self.is_alive(now),
        }


# ---------------------------------------------------------------------------
# In-memory relay (implements the Phase-1 relay contract)
# ---------------------------------------------------------------------------

class InMemoryRelay:
    """Thread-safe in-process relay for contract tests and local experiments.

    Semantics match the cross-machine relay design from
    docs/cross-machine-broker.md, Phase 1 scope:
      - register / heartbeat / list
      - 1:1 send + poll_inbox + peek_inbox
      - dead-letter for unreachable recipients
      - alias-conflict detection
    """

    def __init__(self, dedup_window: int = 10000) -> None:
        """Create an InMemoryRelay.

        Args:
            dedup_window: number of recently-seen message_ids to keep for
                          exactly-once delivery deduplication. Older IDs are
                          evicted in FIFO order.
        """
        self._lock = threading.Lock()
        # alias → RegistrationLease (one live registration per alias)
        self._leases: dict[str, RegistrationLease] = {}
        # (node_id, session_id) → list[dict]  (message inbox)
        self._inboxes: dict[tuple[str, str], list[dict]] = {}
        # dead-letter records
        self._dead_letter: list[dict] = []
        # room_id → list of member aliases (ordered by join time)
        self._rooms: dict[str, list[str]] = {}
        # room_id → list of message history records
        self._room_history: dict[str, list[dict]] = {}
        # exactly-once dedup: set of recently-seen message_ids (FIFO window)
        self._seen_ids: dict[str, bool] = {}   # ordered dict used as ordered set
        self._dedup_window = dedup_window

    # --- registration ---

    def register(
        self,
        node_id: str,
        session_id: str,
        alias: str,
        *,
        client_type: str = "unknown",
        ttl: float = 300.0,
    ) -> dict:
        """Register (or re-register) a session under an alias.

        Re-registration with the same alias and session_id refreshes last_seen.
        Re-registration with the same alias but a different session_id replaces
        the old entry (managed session restart).
        Registration with an alias already held by a different node+session
        raises RelayError(RELAY_ERR_ALIAS_CONFLICT).
        """
        with self._lock:
            existing = self._leases.get(alias)
            if existing is not None and existing.is_alive():
                # Same node → allow replacement (managed session restart).
                # Different node → conflict (two machines fighting for same alias).
                if existing.node_id != node_id:
                    raise RelayError(
                        RELAY_ERR_ALIAS_CONFLICT,
                        f"alias {alias!r} is already held by "
                        f"{existing.node_id}/{existing.session_id}",
                    )
            lease = RegistrationLease(
                node_id=node_id,
                session_id=session_id,
                alias=alias,
                client_type=client_type,
                registered_at=time.time(),
                last_seen=time.time(),
                ttl=ttl,
            )
            self._leases[alias] = lease
            key = (node_id, session_id)
            if key not in self._inboxes:
                self._inboxes[key] = []
            return {"ok": True, "alias": alias, "node_id": node_id}

    def heartbeat(self, node_id: str, session_id: str) -> dict:
        """Refresh the liveness lease for an existing registration."""
        with self._lock:
            for lease in self._leases.values():
                if lease.node_id == node_id and lease.session_id == session_id:
                    lease.last_seen = time.time()
                    return {"ok": True, "alias": lease.alias, "last_seen": lease.last_seen}
            raise RelayError(
                RELAY_ERR_UNKNOWN_ALIAS,
                f"no registration for node={node_id!r} session={session_id!r}",
            )

    def list_peers(self, *, include_dead: bool = False) -> list[dict]:
        """List all registered sessions, optionally including expired leases."""
        with self._lock:
            now = time.time()
            return [
                lease.to_dict()
                for lease in self._leases.values()
                if include_dead or lease.is_alive(now)
            ]

    # --- messaging ---

    def send(
        self,
        from_alias: str,
        to_alias: str,
        content: str,
        *,
        message_id: Optional[str] = None,
    ) -> dict:
        """Deliver a message to to_alias's inbox.

        Returns {"ok": True, "ts": <epoch>} on success.
        Raises RelayError if to_alias is unknown or dead (message goes to dead-letter).
        """
        import uuid as _uuid
        msg_id = message_id or str(_uuid.uuid4())
        ts = time.time()

        with self._lock:
            recipient = self._leases.get(to_alias)
            if recipient is None:
                self._dead_letter.append({
                    "ts": ts,
                    "message_id": msg_id,
                    "from_alias": from_alias,
                    "to_alias": to_alias,
                    "content": content,
                    "reason": "unknown_alias",
                })
                raise RelayError(
                    RELAY_ERR_UNKNOWN_ALIAS,
                    f"no registration for alias {to_alias!r}",
                )
            if not recipient.is_alive():
                self._dead_letter.append({
                    "ts": ts,
                    "message_id": msg_id,
                    "from_alias": from_alias,
                    "to_alias": to_alias,
                    "content": content,
                    "reason": "recipient_dead",
                })
                raise RelayError(
                    RELAY_ERR_RECIPIENT_DEAD,
                    f"alias {to_alias!r} is registered but lease has expired",
                )
            # Exactly-once: only record ID after recipient is confirmed alive;
            # failed sends (unknown alias, dead recipient) don't consume the ID
            # so retries can succeed after the recipient registers/recovers.
            if not self._record_message_id(msg_id):
                return {"ok": True, "ts": ts, "to_alias": to_alias,
                        "message_id": msg_id, "duplicate": True}

            key = (recipient.node_id, recipient.session_id)
            msg = {
                "message_id": msg_id,
                "from_alias": from_alias,
                "to_alias": to_alias,
                "content": content,
                "ts": ts,
            }
            if key not in self._inboxes:
                self._inboxes[key] = []
            self._inboxes[key].append(msg)
            return {"ok": True, "ts": ts, "to_alias": to_alias, "message_id": msg_id}

    def poll_inbox(self, node_id: str, session_id: str) -> list[dict]:
        """Drain and return all queued messages for this session.

        Each message is returned exactly once (drain semantics).
        """
        with self._lock:
            key = (node_id, session_id)
            msgs = self._inboxes.get(key, [])
            self._inboxes[key] = []
            return msgs

    def peek_inbox(self, node_id: str, session_id: str) -> list[dict]:
        """Return queued messages without consuming them (read-only snapshot)."""
        with self._lock:
            return list(self._inboxes.get((node_id, session_id), []))

    def dead_letter(self) -> list[dict]:
        """Return dead-letter entries (not consumed)."""
        with self._lock:
            return list(self._dead_letter)

    # --- rooms ---

    def join_room(self, alias: str, room_id: str) -> dict:
        """Add alias to a room. Creates room on first join. No-op if already a member."""
        import uuid as _uuid

        with self._lock:
            if alias not in self._leases:
                raise RelayError(RELAY_ERR_UNKNOWN_ALIAS,
                                 f"alias {alias!r} is not registered")
            members = self._rooms.setdefault(room_id, [])
            already_member = alias in members
            if not already_member:
                members.append(alias)
            if room_id not in self._room_history:
                self._room_history[room_id] = []
            if not already_member:
                self._broadcast_room_join_locked(
                    alias=alias,
                    room_id=room_id,
                    message_id=str(_uuid.uuid4()),
                    ts=time.time(),
                )
            return {"ok": True, "room_id": room_id, "alias": alias,
                    "member_count": len(members), "already_member": already_member}

    def _broadcast_room_join_locked(
        self,
        *,
        alias: str,
        room_id: str,
        message_id: str,
        ts: float,
    ) -> None:
        content = room_join_content(alias, room_id)
        self._room_history.setdefault(room_id, []).append({
            "message_id": message_id,
            "from_alias": ROOM_SYSTEM_ALIAS,
            "room_id": room_id,
            "content": content,
            "ts": ts,
        })
        for member_alias in list(self._rooms.get(room_id, [])):
            lease = self._leases.get(member_alias)
            msg = {
                "message_id": message_id,
                "from_alias": ROOM_SYSTEM_ALIAS,
                "to_alias": f"{member_alias}#{room_id}",
                "content": content,
                "ts": ts,
                "room_id": room_id,
            }
            if lease is None or not lease.is_alive(ts):
                self._dead_letter.append({**msg, "reason": "recipient_dead"})
                continue
            key = (lease.node_id, lease.session_id)
            self._inboxes.setdefault(key, []).append(msg)

    def leave_room(self, alias: str, room_id: str) -> dict:
        """Remove alias from a room. No-op if not a member."""
        with self._lock:
            members = self._rooms.get(room_id, [])
            removed = alias in members
            if removed:
                members.remove(alias)
            return {"ok": True, "room_id": room_id, "alias": alias,
                    "member_count": len(members), "removed": removed}

    def send_room(self, from_alias: str, room_id: str, content: str,
                  message_id: Optional[str] = None) -> dict:
        """Fan out to all alive room members except the sender.

        Delivers to members whose alias has a live lease; dead or missing
        aliases are added to dead-letter and listed in skipped.
        """
        import uuid as _uuid
        msg_id = message_id or str(_uuid.uuid4())
        ts = time.time()

        with self._lock:
            members = list(self._rooms.get(room_id, []))
            if not members:
                return {"ok": True, "delivered_to": [], "skipped": [],
                        "room_id": room_id, "ts": ts}
            delivered_to: list[str] = []
            skipped: list[str] = []
            for alias in members:
                if alias == from_alias:
                    continue
                lease = self._leases.get(alias)
                msg = {
                    "message_id": msg_id,
                    "from_alias": from_alias,
                    "to_alias": f"{alias}#{room_id}",
                    "content": content,
                    "ts": ts,
                    "room_id": room_id,
                }
                if lease is None or not lease.is_alive():
                    self._dead_letter.append({**msg, "reason": "recipient_dead"})
                    skipped.append(alias)
                    continue
                key = (lease.node_id, lease.session_id)
                self._inboxes.setdefault(key, []).append(msg)
                delivered_to.append(alias)
            # Append to room history
            self._room_history.setdefault(room_id, []).append({
                "message_id": msg_id,
                "from_alias": from_alias,
                "room_id": room_id,
                "content": content,
                "ts": ts,
            })
            return {"ok": True, "delivered_to": delivered_to, "skipped": skipped,
                    "room_id": room_id, "ts": ts}

    def room_history(self, room_id: str, limit: int = 50) -> list[dict]:
        """Return up to `limit` most recent messages from a room."""
        with self._lock:
            history = self._room_history.get(room_id, [])
            return list(history[-limit:])

    def list_rooms(self) -> list[dict]:
        """Return all rooms with member counts."""
        with self._lock:
            return [
                {"room_id": rid, "member_count": len(members),
                 "members": list(members)}
                for rid, members in self._rooms.items()
            ]

    def send_all(self, from_alias: str, content: str,
                 message_id: Optional[str] = None) -> dict:
        """Broadcast to all alive registered aliases except the sender."""
        import uuid as _uuid
        msg_id = message_id or str(_uuid.uuid4())
        ts = time.time()

        with self._lock:
            delivered_to: list[str] = []
            skipped: list[str] = []
            for alias, lease in self._leases.items():
                if alias == from_alias:
                    continue
                msg = {
                    "message_id": msg_id,
                    "from_alias": from_alias,
                    "to_alias": alias,
                    "content": content,
                    "ts": ts,
                }
                if not lease.is_alive():
                    skipped.append(alias)
                    continue
                key = (lease.node_id, lease.session_id)
                self._inboxes.setdefault(key, []).append(msg)
                delivered_to.append(alias)
            return {"ok": True, "delivered_to": delivered_to, "skipped": skipped,
                    "ts": ts}

    # --- GC ---

    def gc(self) -> dict:
        """Garbage-collect expired leases and empty inboxes for dead sessions.

        Returns a summary of what was removed:
          {"expired_leases": [alias, ...], "pruned_inboxes": N}
        """
        with self._lock:
            now = time.time()
            expired = [alias for alias, lease in self._leases.items()
                       if not lease.is_alive(now)]
            for alias in expired:
                del self._leases[alias]
                # Remove from all rooms
                for members in self._rooms.values():
                    if alias in members:
                        members.remove(alias)

            # Prune inboxes for sessions with no matching live lease
            live_keys = {
                (lease.node_id, lease.session_id)
                for lease in self._leases.values()
            }
            stale_keys = [k for k in self._inboxes if k not in live_keys]
            pruned = len(stale_keys)
            for k in stale_keys:
                del self._inboxes[k]

            return {"ok": True, "expired_leases": expired, "pruned_inboxes": pruned}

    # --- helpers for tests ---

    def _record_message_id(self, msg_id: str) -> bool:
        """Record a message ID. Returns True if it's new (not a duplicate)."""
        # Must be called while holding self._lock
        if msg_id in self._seen_ids:
            return False
        self._seen_ids[msg_id] = True
        # Evict oldest entries when window is full
        if len(self._seen_ids) > self._dedup_window:
            oldest = next(iter(self._seen_ids))
            del self._seen_ids[oldest]
        return True

    def _tick_lease(self, alias: str, seconds: float) -> None:
        """Advance last_seen backward by `seconds` to simulate lease expiry."""
        with self._lock:
            lease = self._leases.get(alias)
            if lease is not None:
                lease.last_seen -= seconds
