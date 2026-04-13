#!/usr/bin/env python3
"""SQLite-backed relay implementing the same contract as InMemoryRelay.

This provides persistent storage for the c2c relay server so state survives
restarts. All operations are thread-safe via sqlite3's internal locking plus
an optional threading.Lock for coarse-grained serialization when needed.
"""
from __future__ import annotations

import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

from c2c_relay_contract import (
    RELAY_ERR_ALIAS_CONFLICT,
    RELAY_ERR_RECIPIENT_DEAD,
    RELAY_ERR_UNKNOWN_ALIAS,
    ROOM_SYSTEM_ALIAS,
    RelayError,
    room_join_content,
)


class SQLiteRelay:
    """Persistent relay backed by SQLite.

    Implements the same public interface as InMemoryRelay so it can be used
    interchangeably in c2c_relay_server.py and the test suite.
    """

    def __init__(
        self,
        db_path: str | Path,
        dedup_window: int = 10000,
    ) -> None:
        self._db_path = Path(db_path)
        self._dedup_window = dedup_window
        self._lock = threading.Lock()
        self._local = threading.local()
        self._ensure_schema()

    def _conn(self) -> sqlite3.Connection:
        """Return a thread-local sqlite3 connection."""
        if not hasattr(self._local, "conn") or self._local.conn is None:
            self._local.conn = sqlite3.connect(
                str(self._db_path),
                check_same_thread=False,
                isolation_level=None,
            )
            self._local.conn.row_factory = sqlite3.Row
        return self._local.conn

    def _ensure_schema(self) -> None:
        ddl = """
        CREATE TABLE IF NOT EXISTS leases (
            alias TEXT PRIMARY KEY,
            node_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            client_type TEXT NOT NULL DEFAULT 'unknown',
            registered_at REAL NOT NULL,
            last_seen REAL NOT NULL,
            ttl REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS inboxes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            from_alias TEXT NOT NULL,
            to_alias TEXT NOT NULL,
            content TEXT NOT NULL,
            ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_inboxes_session ON inboxes(node_id, session_id);

        CREATE TABLE IF NOT EXISTS dead_letter (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT NOT NULL,
            from_alias TEXT NOT NULL,
            to_alias TEXT NOT NULL,
            content TEXT NOT NULL,
            ts REAL NOT NULL,
            reason TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS rooms (
            room_id TEXT PRIMARY KEY
        );

        CREATE TABLE IF NOT EXISTS room_members (
            room_id TEXT NOT NULL,
            alias TEXT NOT NULL,
            PRIMARY KEY (room_id, alias)
        );

        CREATE TABLE IF NOT EXISTS room_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            room_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            from_alias TEXT NOT NULL,
            content TEXT NOT NULL,
            ts REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_room_history_room ON room_history(room_id);

        CREATE TABLE IF NOT EXISTS seen_ids (
            message_id TEXT PRIMARY KEY,
            ts REAL NOT NULL
        );
        """
        with self._lock:
            self._conn().executescript(ddl)

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
        now = time.time()
        with self._lock:
            cur = self._conn().execute(
                "SELECT node_id, session_id, last_seen, ttl FROM leases WHERE alias = ?",
                (alias,),
            )
            row = cur.fetchone()
            if row is not None:
                alive = (row["last_seen"] + row["ttl"]) >= now
                if alive and row["node_id"] != node_id:
                    raise RelayError(
                        RELAY_ERR_ALIAS_CONFLICT,
                        f"alias {alias!r} is already held by "
                        f"{row['node_id']}/{row['session_id']}",
                    )
            self._conn().execute(
                """
                INSERT INTO leases (alias, node_id, session_id, client_type,
                                    registered_at, last_seen, ttl)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(alias) DO UPDATE SET
                    node_id=excluded.node_id,
                    session_id=excluded.session_id,
                    client_type=excluded.client_type,
                    registered_at=excluded.registered_at,
                    last_seen=excluded.last_seen,
                    ttl=excluded.ttl
                """,
                (alias, node_id, session_id, client_type, now, now, ttl),
            )
            return {"ok": True, "alias": alias, "node_id": node_id}

    def heartbeat(self, node_id: str, session_id: str) -> dict:
        now = time.time()
        with self._lock:
            cur = self._conn().execute(
                "SELECT alias FROM leases WHERE node_id = ? AND session_id = ?",
                (node_id, session_id),
            )
            row = cur.fetchone()
            if row is None:
                raise RelayError(
                    RELAY_ERR_UNKNOWN_ALIAS,
                    f"no registration for node={node_id!r} session={session_id!r}",
                )
            self._conn().execute(
                "UPDATE leases SET last_seen = ? WHERE node_id = ? AND session_id = ?",
                (now, node_id, session_id),
            )
            return {"ok": True, "alias": row["alias"], "last_seen": now}

    def list_peers(self, *, include_dead: bool = False) -> list[dict]:
        now = time.time()
        with self._lock:
            cur = self._conn().execute("SELECT * FROM leases")
            rows = cur.fetchall()
            result = []
            for row in rows:
                alive = (row["last_seen"] + row["ttl"]) >= now
                if not include_dead and not alive:
                    continue
                result.append(
                    {
                        "node_id": row["node_id"],
                        "session_id": row["session_id"],
                        "alias": row["alias"],
                        "client_type": row["client_type"],
                        "registered_at": row["registered_at"],
                        "last_seen": row["last_seen"],
                        "ttl": row["ttl"],
                        "alive": alive,
                    }
                )
            return result

    # --- messaging ---

    def send(
        self,
        from_alias: str,
        to_alias: str,
        content: str,
        *,
        message_id: Optional[str] = None,
    ) -> dict:
        msg_id = message_id or str(uuid.uuid4())
        ts = time.time()
        with self._lock:
            cur = self._conn().execute(
                "SELECT node_id, session_id, last_seen, ttl FROM leases WHERE alias = ?",
                (to_alias,),
            )
            recipient = cur.fetchone()
            if recipient is None:
                self._conn().execute(
                    """
                    INSERT INTO dead_letter (message_id, from_alias, to_alias,
                                             content, ts, reason)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (msg_id, from_alias, to_alias, content, ts, "unknown_alias"),
                )
                raise RelayError(
                    RELAY_ERR_UNKNOWN_ALIAS,
                    f"no registration for alias {to_alias!r}",
                )
            if (recipient["last_seen"] + recipient["ttl"]) < ts:
                self._conn().execute(
                    """
                    INSERT INTO dead_letter (message_id, from_alias, to_alias,
                                             content, ts, reason)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (msg_id, from_alias, to_alias, content, ts, "recipient_dead"),
                )
                raise RelayError(
                    RELAY_ERR_RECIPIENT_DEAD,
                    f"alias {to_alias!r} is registered but lease has expired",
                )
            if not self._record_message_id(msg_id):
                return {
                    "ok": True,
                    "ts": ts,
                    "to_alias": to_alias,
                    "message_id": msg_id,
                    "duplicate": True,
                }
            self._conn().execute(
                """
                INSERT INTO inboxes (node_id, session_id, message_id,
                                     from_alias, to_alias, content, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    recipient["node_id"],
                    recipient["session_id"],
                    msg_id,
                    from_alias,
                    to_alias,
                    content,
                    ts,
                ),
            )
            return {"ok": True, "ts": ts, "to_alias": to_alias, "message_id": msg_id}

    def poll_inbox(self, node_id: str, session_id: str) -> list[dict]:
        with self._lock:
            conn = self._conn()
            cur = conn.execute(
                """
                SELECT message_id, from_alias, to_alias, content, ts
                FROM inboxes
                WHERE node_id = ? AND session_id = ?
                ORDER BY id
                """,
                (node_id, session_id),
            )
            rows = cur.fetchall()
            conn.execute(
                "DELETE FROM inboxes WHERE node_id = ? AND session_id = ?",
                (node_id, session_id),
            )
            return [dict(r) for r in rows]

    def peek_inbox(self, node_id: str, session_id: str) -> list[dict]:
        with self._lock:
            cur = self._conn().execute(
                """
                SELECT message_id, from_alias, to_alias, content, ts
                FROM inboxes
                WHERE node_id = ? AND session_id = ?
                ORDER BY id
                """,
                (node_id, session_id),
            )
            return [dict(r) for r in cur.fetchall()]

    def dead_letter(self) -> list[dict]:
        with self._lock:
            cur = self._conn().execute(
                """
                SELECT message_id, from_alias, to_alias, content, ts, reason
                FROM dead_letter
                ORDER BY id
                """
            )
            return [dict(r) for r in cur.fetchall()]

    # --- rooms ---

    def join_room(self, alias: str, room_id: str) -> dict:
        with self._lock:
            cur = self._conn().execute(
                "SELECT 1 FROM leases WHERE alias = ?", (alias,)
            )
            if cur.fetchone() is None:
                raise RelayError(
                    RELAY_ERR_UNKNOWN_ALIAS,
                    f"alias {alias!r} is not registered",
                )
            self._conn().execute(
                "INSERT OR IGNORE INTO rooms (room_id) VALUES (?)", (room_id,)
            )
            cur = self._conn().execute(
                "SELECT 1 FROM room_members WHERE room_id = ? AND alias = ?",
                (room_id, alias),
            )
            already_member = cur.fetchone() is not None
            if not already_member:
                self._conn().execute(
                    """
                    INSERT INTO room_members (room_id, alias)
                    VALUES (?, ?)
                    """,
                    (room_id, alias),
                )
                self._broadcast_room_join_locked(
                    room_id=room_id,
                    alias=alias,
                    message_id=str(uuid.uuid4()),
                    ts=time.time(),
                )
            cur = self._conn().execute(
                "SELECT COUNT(*) FROM room_members WHERE room_id = ?", (room_id,)
            )
            member_count = cur.fetchone()[0]
            return {
                "ok": True,
                "room_id": room_id,
                "alias": alias,
                "member_count": member_count,
                "already_member": already_member,
            }

    def _broadcast_room_join_locked(
        self,
        *,
        room_id: str,
        alias: str,
        message_id: str,
        ts: float,
    ) -> None:
        content = room_join_content(alias, room_id)
        conn = self._conn()
        cur = conn.execute(
            "SELECT alias FROM room_members WHERE room_id = ?", (room_id,)
        )
        members = [r["alias"] for r in cur.fetchall()]
        for member_alias in members:
            cur = conn.execute(
                "SELECT node_id, session_id, last_seen, ttl FROM leases WHERE alias = ?",
                (member_alias,),
            )
            lease = cur.fetchone()
            to_alias = f"{member_alias}@{room_id}"
            if lease is None or (lease["last_seen"] + lease["ttl"]) < ts:
                conn.execute(
                    """
                    INSERT INTO dead_letter (message_id, from_alias, to_alias,
                                             content, ts, reason)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        message_id,
                        ROOM_SYSTEM_ALIAS,
                        to_alias,
                        content,
                        ts,
                        "recipient_dead",
                    ),
                )
                continue
            conn.execute(
                """
                INSERT INTO inboxes (node_id, session_id, message_id,
                                     from_alias, to_alias, content, ts)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    lease["node_id"],
                    lease["session_id"],
                    message_id,
                    ROOM_SYSTEM_ALIAS,
                    to_alias,
                    content,
                    ts,
                ),
            )
        conn.execute(
            """
            INSERT INTO room_history (room_id, message_id, from_alias, content, ts)
            VALUES (?, ?, ?, ?, ?)
            """,
            (room_id, message_id, ROOM_SYSTEM_ALIAS, content, ts),
        )

    def leave_room(self, alias: str, room_id: str) -> dict:
        with self._lock:
            cur = self._conn().execute(
                "SELECT 1 FROM room_members WHERE room_id = ? AND alias = ?",
                (room_id, alias),
            )
            removed = cur.fetchone() is not None
            self._conn().execute(
                "DELETE FROM room_members WHERE room_id = ? AND alias = ?",
                (room_id, alias),
            )
            cur = self._conn().execute(
                "SELECT COUNT(*) FROM room_members WHERE room_id = ?", (room_id,)
            )
            member_count = cur.fetchone()[0]
            return {
                "ok": True,
                "room_id": room_id,
                "alias": alias,
                "member_count": member_count,
                "removed": removed,
            }

    def send_room(
        self,
        from_alias: str,
        room_id: str,
        content: str,
        message_id: Optional[str] = None,
    ) -> dict:
        msg_id = message_id or str(uuid.uuid4())
        ts = time.time()
        with self._lock:
            conn = self._conn()
            cur = conn.execute(
                "SELECT alias FROM room_members WHERE room_id = ?", (room_id,)
            )
            members = [r["alias"] for r in cur.fetchall()]
            if not members:
                return {
                    "ok": True,
                    "delivered_to": [],
                    "skipped": [],
                    "room_id": room_id,
                    "ts": ts,
                }
            delivered_to: list[str] = []
            skipped: list[str] = []
            for alias in members:
                if alias == from_alias:
                    continue
                cur = conn.execute(
                    "SELECT node_id, session_id, last_seen, ttl FROM leases WHERE alias = ?",
                    (alias,),
                )
                lease = cur.fetchone()
                if lease is None or (lease["last_seen"] + lease["ttl"]) < ts:
                    conn.execute(
                        """
                        INSERT INTO dead_letter (message_id, from_alias, to_alias,
                                                 content, ts, reason)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (
                            msg_id,
                            from_alias,
                            f"{alias}@{room_id}",
                            content,
                            ts,
                            "recipient_dead",
                        ),
                    )
                    skipped.append(alias)
                    continue
                conn.execute(
                    """
                    INSERT INTO inboxes (node_id, session_id, message_id,
                                         from_alias, to_alias, content, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        lease["node_id"],
                        lease["session_id"],
                        msg_id,
                        from_alias,
                        f"{alias}@{room_id}",
                        content,
                        ts,
                    ),
                )
                delivered_to.append(alias)
            conn.execute(
                """
                INSERT INTO room_history (room_id, message_id, from_alias, content, ts)
                VALUES (?, ?, ?, ?, ?)
                """,
                (room_id, msg_id, from_alias, content, ts),
            )
            return {
                "ok": True,
                "delivered_to": delivered_to,
                "skipped": skipped,
                "room_id": room_id,
                "ts": ts,
            }

    def room_history(self, room_id: str, limit: int = 50) -> list[dict]:
        with self._lock:
            cur = self._conn().execute(
                """
                SELECT message_id, from_alias, room_id, content, ts
                FROM room_history
                WHERE room_id = ?
                ORDER BY id DESC
                LIMIT ?
                """,
                (room_id, limit),
            )
            rows = cur.fetchall()
            return [dict(r) for r in reversed(rows)]

    def list_rooms(self) -> list[dict]:
        with self._lock:
            cur = self._conn().execute(
                """
                SELECT r.room_id, COUNT(m.alias) as member_count,
                       GROUP_CONCAT(m.alias) as members
                FROM rooms r
                LEFT JOIN room_members m ON r.room_id = m.room_id
                GROUP BY r.room_id
                """
            )
            result = []
            for row in cur.fetchall():
                members_str = row["members"]
                members = members_str.split(",") if members_str else []
                result.append(
                    {
                        "room_id": row["room_id"],
                        "member_count": row["member_count"],
                        "members": members,
                    }
                )
            return result

    def send_all(
        self,
        from_alias: str,
        content: str,
        message_id: Optional[str] = None,
    ) -> dict:
        msg_id = message_id or str(uuid.uuid4())
        ts = time.time()
        with self._lock:
            conn = self._conn()
            cur = conn.execute(
                "SELECT alias, node_id, session_id, last_seen, ttl FROM leases"
            )
            delivered_to: list[str] = []
            skipped: list[str] = []
            for row in cur.fetchall():
                alias = row["alias"]
                if alias == from_alias:
                    continue
                if (row["last_seen"] + row["ttl"]) < ts:
                    skipped.append(alias)
                    continue
                conn.execute(
                    """
                    INSERT INTO inboxes (node_id, session_id, message_id,
                                         from_alias, to_alias, content, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["node_id"],
                        row["session_id"],
                        msg_id,
                        from_alias,
                        alias,
                        content,
                        ts,
                    ),
                )
                delivered_to.append(alias)
            return {
                "ok": True,
                "delivered_to": delivered_to,
                "skipped": skipped,
                "ts": ts,
            }

    # --- GC ---

    def gc(self) -> dict:
        now = time.time()
        with self._lock:
            conn = self._conn()
            # Find and delete expired leases
            cur = conn.execute(
                "SELECT alias FROM leases WHERE (last_seen + ttl) < ?", (now,)
            )
            expired = [r["alias"] for r in cur.fetchall()]
            for alias in expired:
                conn.execute("DELETE FROM room_members WHERE alias = ?", (alias,))
            conn.execute(
                "DELETE FROM leases WHERE (last_seen + ttl) < ?", (now,)
            )
            # Count orphan inboxes after lease deletion
            cur = conn.execute(
                """
                SELECT SUM(cnt) FROM (
                    SELECT COUNT(*) as cnt
                    FROM inboxes i
                    LEFT JOIN leases l
                        ON i.node_id = l.node_id AND i.session_id = l.session_id
                    WHERE l.node_id IS NULL
                    GROUP BY i.node_id, i.session_id
                )
                """
            )
            row = cur.fetchone()
            pruned = row[0] if row and row[0] else 0
            # Prune orphan inboxes
            conn.execute(
                """
                DELETE FROM inboxes
                WHERE (node_id, session_id) IN (
                    SELECT i.node_id, i.session_id
                    FROM inboxes i
                    LEFT JOIN leases l
                        ON i.node_id = l.node_id AND i.session_id = l.session_id
                    WHERE l.node_id IS NULL
                )
                """
            )
            return {"ok": True, "expired_leases": expired, "pruned_inboxes": pruned}

    # --- helpers for tests ---

    def _record_message_id(self, msg_id: str) -> bool:
        """Record a message ID. Returns True if it's new (not a duplicate)."""
        ts = time.time()
        conn = self._conn()
        try:
            conn.execute(
                "INSERT INTO seen_ids (message_id, ts) VALUES (?, ?)",
                (msg_id, ts),
            )
            # Evict oldest if over window
            cur = conn.execute("SELECT COUNT(*) FROM seen_ids")
            count = cur.fetchone()[0]
            if count > self._dedup_window:
                excess = count - self._dedup_window
                conn.execute(
                    """
                    DELETE FROM seen_ids
                    WHERE message_id IN (
                        SELECT message_id FROM seen_ids ORDER BY ts LIMIT ?
                    )
                    """,
                    (excess,),
                )
            return True
        except sqlite3.IntegrityError:
            return False

    def _tick_lease(self, alias: str, seconds: float) -> None:
        """Advance last_seen backward by `seconds` to simulate lease expiry."""
        with self._lock:
            self._conn().execute(
                "UPDATE leases SET last_seen = last_seen - ? WHERE alias = ?",
                (seconds, alias),
            )
