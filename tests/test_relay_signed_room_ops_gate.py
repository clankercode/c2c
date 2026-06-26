#!/usr/bin/env python3
"""E2e tests for C2C_REQUIRE_SIGNED_ROOM_OPS gate (Phase 3 prerequisite).

Starts a local OCaml relay server with C2C_REQUIRE_SIGNED_ROOM_OPS=1 and
verifies:
  - unsigned join_room → rejected with relay_err_unsigned_room_op
  - unsigned leave_room → rejected with relay_err_unsigned_room_op
  - unsigned set_room_visibility → rejected with relay_err_unsigned_room_op
  - signed join_room (with Ed25519 proof) → accepted

These tests require the OCaml relay binary (c2c relay serve) and an Ed25519
identity fixture (C2C_RELAY_IDENTITY_PATH). They are NOT run against the
prod relay.

Requires: cryptography (pip install cryptography)
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

C2C = os.environ.get("C2C_BIN", "/home/xertrov/.local/bin/c2c")
TOKEN = "gate-test-token"
ALICE_ALIAS = "gate-test-alice"
ALICE_SESSION = "gate-test-s-alice"
ROOM_ID = "gate-test-room"
TEST_PORT = 18765


class RelayClient:
    """Minimal synchronous HTTP client for the OCaml relay server."""

    def __init__(self, base_url: str, token: str | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, body: dict | None = None) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body or {}).encode() if body is not None else b""
        req = urllib.request.Request(url, data=data or None, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            try:
                return json.loads(exc.read())
            finally:
                exc.close()

    def get(self, path: str) -> dict:
        return self._request("GET", path)

    def post(self, path: str, body: dict) -> dict:
        return self._request("POST", path, body)

    def register(self, node_id: str, session_id: str, alias: str, **kw) -> dict:
        return self.post("/register", {"node_id": node_id, "session_id": session_id,
                                       "alias": alias, **kw})


class OCamlRelayServer:
    """Context manager: starts OCaml relay server as a subprocess, tears it down on exit."""

    def __init__(self, token: str, require_signed: bool = True,
                 identity_path: str | None = None, port: int = TEST_PORT) -> None:
        self.token = token
        self.require_signed = require_signed
        self.identity_path = identity_path
        self.port = port
        self._proc: subprocess.Popen | None = None

    def _build_env(self) -> dict:
        env = dict(os.environ)
        env.pop("C2C_MCP_SESSION_ID", None)
        if self.require_signed:
            env["C2C_REQUIRE_SIGNED_ROOM_OPS"] = "1"
        else:
            env.pop("C2C_REQUIRE_SIGNED_ROOM_OPS", None)
        if self.identity_path:
            env["C2C_RELAY_IDENTITY_PATH"] = self.identity_path
        return env

    def start(self) -> "OCamlRelayServer":
        cmd = [
            C2C, "relay", "serve",
            "--listen", f"127.0.0.1:{self.port}",
            "--token", self.token,
            "--storage", "memory",
        ]
        self._proc = subprocess.Popen(
            cmd,
            env=self._build_env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(50):
            try:
                r = urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/health", timeout=1
                )
                if r.status == 200:
                    break
            except Exception:
                pass
            time.sleep(0.1)
        else:
            raise RuntimeError("OCaml relay server failed to start")
        return self

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def close(self):
        if self._proc:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
                self._proc.wait()

    def __enter__(self) -> "OCamlRelayServer":
        return self.start()

    def __exit__(self, *args):
        self.close()


def load_identity(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _b64url_nopad(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def generate_identity(alias: str) -> dict:
    """Generate a fresh Ed25519 client identity in the {alias, identity_pk_b64,
    secret_b64} shape SignedRoomOpHelper expects. Used so the signed-op e2e
    tests can run without an on-disk identity fixture (the alias is pinned to
    this key via TOFU on the first signed room op)."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519
    key = ed25519.Ed25519PrivateKey.generate()
    seed = key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return {
        "alias": alias,
        "identity_pk_b64": _b64url_nopad(pub),
        "secret_b64": _b64url_nopad(seed),
    }


class SignedRoomOpHelper:
    """Builds canonical room-op proof blobs and signs them with a local identity.

    Mirrors the logic in the OCaml relay_identity and relay_signed_ops modules.
    """

    def __init__(self, identity: dict) -> None:
        self.alias = identity["alias"]
        self.identity_pk_b64 = identity["identity_pk_b64"]
        self.secret_b64 = identity["secret_b64"]

    def _b64url_nopad_encode(self, data: bytes) -> str:
        return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

    def _sign(self, msg: str) -> bytes:
        from cryptography.hazmat.primitives.asymmetric import ed25519
        secret = base64.urlsafe_b64decode(self.secret_b64 + "==")
        key = ed25519.Ed25519PrivateKey.from_private_bytes(secret)
        return key.sign(msg.encode())

    def sign_room_op(self, sign_ctx: str, room_id: str) -> dict:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        nonce = self._b64url_nopad_encode(os.urandom(16))
        blob = "\x1f".join([sign_ctx, room_id, self.alias,
                             self.identity_pk_b64, ts, nonce])
        sig = self._sign(blob)
        sig_b64 = self._b64url_nopad_encode(sig)
        return {
            "identity_pk": self.identity_pk_b64,
            "sig": sig_b64,
            "ts": ts,
            "nonce": nonce,
        }

    def sign_room_op_with_visibility(self, sign_ctx: str, room_id: str,
                                     visibility: str) -> dict:
        """Proof for a visibility-carrying room op (join with visibility,
        set_room_visibility). The canonical blob inserts the (canonical)
        visibility value between alias and identity_pk — mirrors the OCaml
        relay_signed_ops.sign_room_op_with_visibility. [visibility] must be the
        canonical value the server stores ("public" | "private" | "invite")."""
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        nonce = self._b64url_nopad_encode(os.urandom(16))
        blob = "\x1f".join([sign_ctx, room_id, self.alias, visibility,
                            self.identity_pk_b64, ts, nonce])
        sig = self._sign(blob)
        return {
            "identity_pk": self.identity_pk_b64,
            "sig": self._b64url_nopad_encode(sig),
            "ts": ts,
            "nonce": nonce,
        }


class RequireSignedRoomOpsTests(unittest.TestCase):
    """Tests for C2C_REQUIRE_SIGNED_ROOM_OPS=1 gate.

    When the gate is ON, unsigned room ops must be rejected with
    relay_err_unsigned_room_op = "unsigned_room_op".
    """

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, require_signed=True)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.client.register("n", ALICE_SESSION, ALICE_ALIAS)

    @classmethod
    def tearDownClass(cls):
        cls.server.close()


class RequireSignedRoomOpsJoinRoomTests(RequireSignedRoomOpsTests):
    def test_unsigned_join_room_rejected(self):
        """Unsigned /join_room must be rejected with relay_err_unsigned_room_op."""
        r = self.client.post("/join_room", {
            "alias": ALICE_ALIAS,
            "room_id": ROOM_ID,
        })
        self.assertFalse(r["ok"], f"unsigned join_room should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")


class RequireSignedRoomOpsLeaveRoomTests(RequireSignedRoomOpsTests):
    def test_unsigned_leave_room_rejected(self):
        """Unsigned /leave_room must be rejected with relay_err_unsigned_room_op."""
        r = self.client.post("/leave_room", {
            "alias": ALICE_ALIAS,
            "room_id": ROOM_ID,
        })
        self.assertFalse(r["ok"], f"unsigned leave_room should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")


class RequireSignedRoomOpsSetVisibilityTests(RequireSignedRoomOpsTests):
    def test_unsigned_set_room_visibility_rejected(self):
        """Unsigned /set_room_visibility must be rejected with relay_err_unsigned_room_op."""
        r = self.client.post("/set_room_visibility", {
            "alias": ALICE_ALIAS,
            "room_id": ROOM_ID,
            "visibility": "public",
        })
        self.assertFalse(r["ok"], f"unsigned set_room_visibility should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")


class RequireSignedRoomOpsSignedJoinTests(RequireSignedRoomOpsTests):
    def test_signed_join_room_accepted(self):
        """Signed /join_room with Ed25519 proof must be accepted when identity is registered."""
        identity_path = os.environ.get("C2C_RELAY_IDENTITY_PATH")
        if not identity_path or not Path(identity_path).exists():
            self.skipTest("C2C_RELAY_IDENTITY_PATH not set or file not found")
        identity = load_identity(identity_path)
        helper = SignedRoomOpHelper(identity)

        proof = helper.sign_room_op("c2c/v1/room-join", ROOM_ID)
        r = self.client.post("/join_room", {
            "alias": ALICE_ALIAS,
            "room_id": ROOM_ID,
            **proof,
        })
        self.assertTrue(r["ok"], f"signed join_room should be accepted: {r}")


class GateOffAcceptsUnsignedTests(unittest.TestCase):
    """Verify that when C2C_REQUIRE_SIGNED_ROOM_OPS is OFF, unsigned ops are accepted.

    This is the legacy behavior — a sanity check that the gate itself is functional.
    """

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, require_signed=False,
                                      port=TEST_PORT + 1)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.client.register("n", ALICE_SESSION + "-gateoff",
                            ALICE_ALIAS + "-gateoff")

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def test_unsigned_join_room_accepted_when_gate_off(self):
        """When gate is off, unsigned /join_room must be accepted (with warn log)."""
        r = self.client.post("/join_room", {
            "alias": ALICE_ALIAS + "-gateoff",
            "room_id": ROOM_ID + "-gateoff",
        })
        self.assertTrue(r["ok"],
                        f"unsigned join_room should be accepted when gate is off: {r}")


class SignedRoomVisibilityE2ETests(unittest.TestCase):
    """E2e for the room-visibility feature on the signed path:
      - a signed join/set_room_visibility that carries a visibility value is
        accepted (visibility is covered by the Ed25519 proof — a forged value
        would fail verification), and
      - GET /list_rooms returns only public rooms (private/invite hidden).

    Self-contained: generates its own client identity and registers the alias
    unsigned; the first signed room op pins the key to the alias via TOFU. No
    on-disk identity fixture needed, so this always runs.
    """

    JOIN_CTX = "c2c/v1/room-join"
    SETVIS_CTX = "c2c/v1/room-set-visibility"
    ALIAS = "vis-e2e-alice"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, require_signed=True,
                                      port=TEST_PORT + 2)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.helper = SignedRoomOpHelper(generate_identity(cls.ALIAS))
        cls.client.register("n-vis", "s-vis", cls.ALIAS)

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def _signed_join(self, room_id: str, visibility: str) -> dict:
        proof = self.helper.sign_room_op_with_visibility(
            self.JOIN_CTX, room_id, visibility)
        return self.client.post("/join_room", {
            "alias": self.ALIAS, "room_id": room_id,
            "visibility": visibility, **proof,
        })

    def _list_room_ids(self) -> set:
        r = self.client.get("/list_rooms")
        self.assertTrue(r.get("ok"), f"list_rooms failed: {r}")
        return {room["room_id"] for room in r.get("rooms", [])}

    def test_signed_join_public_is_listed(self):
        r = self._signed_join("vis-e2e-public", "public")
        self.assertTrue(r["ok"], f"signed join (public) should be accepted: {r}")
        self.assertIn("vis-e2e-public", self._list_room_ids(),
                      "public room must appear in /list_rooms")

    def test_signed_join_private_not_listed(self):
        r = self._signed_join("vis-e2e-private", "private")
        self.assertTrue(r["ok"], f"signed join (private) should be accepted: {r}")
        self.assertNotIn("vis-e2e-private", self._list_room_ids(),
                         "private room must NOT appear in /list_rooms")

    def test_signed_set_visibility_hides_room(self):
        # Create as public (listed), then flip to invite_only (hidden).
        r = self._signed_join("vis-e2e-flip", "public")
        self.assertTrue(r["ok"], f"signed join should be accepted: {r}")
        self.assertIn("vis-e2e-flip", self._list_room_ids())
        # The signed blob must carry the CANONICAL value the server stores;
        # body sends "invite_only", server canonicalizes to "invite".
        proof = self.helper.sign_room_op_with_visibility(
            self.SETVIS_CTX, "vis-e2e-flip", "invite")
        r2 = self.client.post("/set_room_visibility", {
            "alias": self.ALIAS, "room_id": "vis-e2e-flip",
            "visibility": "invite_only", **proof,
        })
        self.assertTrue(r2["ok"],
                        f"signed set_room_visibility should be accepted: {r2}")
        self.assertNotIn("vis-e2e-flip", self._list_room_ids(),
                         "room must be hidden from /list_rooms after going invite_only")


if __name__ == "__main__":
    unittest.main()
