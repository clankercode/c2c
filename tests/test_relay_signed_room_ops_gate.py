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
import hashlib
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

    def _request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        auth_header: str | None = None,
    ) -> dict:
        url = f"{self.base_url}{path}"
        data = json.dumps(body or {}).encode() if body is not None else b""
        req = urllib.request.Request(url, data=data or None, method=method)
        req.add_header("Content-Type", "application/json")
        if auth_header:
            req.add_header("Authorization", auth_header)
        elif self.token:
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

    def post(self, path: str, body: dict, auth_header: str | None = None) -> dict:
        return self._request("POST", path, body, auth_header=auth_header)

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

    def sign_register(self, relay_url: str) -> dict:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        nonce = self._b64url_nopad_encode(os.urandom(16))
        blob = "\x1f".join([
            "c2c/v1/register",
            self.alias,
            relay_url.lower(),
            self.identity_pk_b64,
            ts,
            nonce,
        ])
        sig = self._sign(blob)
        return {
            "identity_pk": self.identity_pk_b64,
            "signature": self._b64url_nopad_encode(sig),
            "timestamp": ts,
            "nonce": nonce,
        }

    def sign_request(self, method: str, path: str, body: dict) -> str:
        ts = f"{time.time():.6f}"
        nonce = self._b64url_nopad_encode(os.urandom(16))
        body_str = json.dumps(body or {})
        body_hash = self._b64url_nopad_encode(
            hashlib.sha256(body_str.encode()).digest()
        )
        blob = "\x1f".join([
            "c2c/v1/request",
            method.upper(),
            path,
            "",
            body_hash,
            ts,
            nonce,
        ])
        sig = self._sign(blob)
        return (
            f"Ed25519 alias={self.alias},ts={ts},nonce={nonce},"
            f"sig={self._b64url_nopad_encode(sig)}"
        )

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
        canonical value the server stores
        ("public" | "unlisted" | "gated" | "private")."""
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
    """E2e for the 4-level room-visibility feature on the signed path:
      - a signed join/set_room_visibility that carries a visibility value is
        accepted (visibility is covered by the Ed25519 proof — a forged value
        would fail verification), and
      - GET /list_rooms returns public AND gated rooms (unlisted/private hidden),
      - gated/private join is invite-gated (a non-invited second signed identity
        is rejected) while unlisted/public join is open (a second identity joins).

    Self-contained: generates its own client identities and registers the
    aliases unsigned; the first signed room op pins the key to the alias via
    TOFU. No on-disk identity fixture needed, so this always runs.
    """

    JOIN_CTX = "c2c/v1/room-join"
    SETVIS_CTX = "c2c/v1/room-set-visibility"
    ALIAS = "vis-e2e-alice"
    ALIAS2 = "vis-e2e-bob"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper
    helper2: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, require_signed=True,
                                      port=TEST_PORT + 2)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.helper = SignedRoomOpHelper(generate_identity(cls.ALIAS))
        cls.client.register(
            "n-vis", "s-vis", cls.ALIAS,
            **cls.helper.sign_register(cls.server.base_url),
        )
        # A second signed identity used to exercise the join-gate cells.
        cls.helper2 = SignedRoomOpHelper(generate_identity(cls.ALIAS2))
        cls.client.register(
            "n-vis2", "s-vis2", cls.ALIAS2,
            **cls.helper2.sign_register(cls.server.base_url),
        )

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

    def _signed_history(self, helper: SignedRoomOpHelper, room_id: str) -> dict:
        body = {"room_id": room_id, "limit": 20}
        return self.client.post(
            "/room_history",
            body,
            auth_header=helper.sign_request("POST", "/room_history", body),
        )

    def test_signed_join_public_is_listed(self):
        r = self._signed_join("vis-e2e-public", "public")
        self.assertTrue(r["ok"], f"signed join (public) should be accepted: {r}")
        self.assertIn("vis-e2e-public", self._list_room_ids(),
                      "public room must appear in /list_rooms")

    def test_signed_join_unlisted_not_listed(self):
        r = self._signed_join("vis-e2e-unlisted", "unlisted")
        self.assertTrue(r["ok"], f"signed join (unlisted) should be accepted: {r}")
        self.assertNotIn("vis-e2e-unlisted", self._list_room_ids(),
                         "unlisted room must NOT appear in /list_rooms")

    def test_signed_join_gated_is_listed(self):
        r = self._signed_join("vis-e2e-gated", "gated")
        self.assertTrue(r["ok"], f"signed join (gated) should be accepted: {r}")
        self.assertIn("vis-e2e-gated", self._list_room_ids(),
                      "gated room must appear in /list_rooms")

    def test_signed_join_private_not_listed(self):
        r = self._signed_join("vis-e2e-private", "private")
        self.assertTrue(r["ok"], f"signed join (private) should be accepted: {r}")
        self.assertNotIn("vis-e2e-private", self._list_room_ids(),
                         "private room must NOT appear in /list_rooms")

    def test_gated_listed_but_uninvited_second_identity_rejected(self):
        # Creator opens a gated room: it IS listed for discovery...
        r = self._signed_join("vis-e2e-gated-gate", "gated")
        self.assertTrue(r["ok"], f"signed join (gated) should be accepted: {r}")
        self.assertIn("vis-e2e-gated-gate", self._list_room_ids(),
                      "gated room must be listed")
        # ...but a second, non-invited signed identity is rejected from joining.
        proof = self.helper2.sign_room_op(self.JOIN_CTX, "vis-e2e-gated-gate")
        r2 = self.client.post("/join_room", {
            "alias": self.ALIAS2, "room_id": "vis-e2e-gated-gate", **proof,
        })
        self.assertFalse(r2["ok"],
                         f"uninvited join into a gated room must be rejected: {r2}")

    def test_unlisted_not_listed_but_second_identity_joins_ok(self):
        # Creator opens an unlisted room: NOT listed...
        r = self._signed_join("vis-e2e-unlisted-open", "unlisted")
        self.assertTrue(r["ok"], f"signed join (unlisted) should be accepted: {r}")
        self.assertNotIn("vis-e2e-unlisted-open", self._list_room_ids(),
                         "unlisted room must NOT be listed")
        # ...but a second signed identity can still JOIN it (open join).
        proof = self.helper2.sign_room_op(self.JOIN_CTX, "vis-e2e-unlisted-open")
        r2 = self.client.post("/join_room", {
            "alias": self.ALIAS2, "room_id": "vis-e2e-unlisted-open", **proof,
        })
        self.assertTrue(r2["ok"],
                        f"open join into an unlisted room must be accepted: {r2}")

    def test_gated_history_member_gated(self):
        r = self._signed_join("vis-e2e-gated-history", "gated")
        self.assertTrue(r["ok"], f"signed join (gated) should be accepted: {r}")

        outsider = self._signed_history(self.helper2, "vis-e2e-gated-history")
        self.assertFalse(
            outsider["ok"],
            f"non-member must not read gated history: {outsider}",
        )
        self.assertEqual(outsider.get("error_code"), "not_a_member")

        member = self._signed_history(self.helper, "vis-e2e-gated-history")
        self.assertTrue(member["ok"], f"member must read gated history: {member}")

    def test_private_history_member_gated(self):
        r = self._signed_join("vis-e2e-private-history", "private")
        self.assertTrue(r["ok"], f"signed join (private) should be accepted: {r}")

        outsider = self._signed_history(self.helper2, "vis-e2e-private-history")
        self.assertFalse(
            outsider["ok"],
            f"non-member must not read private history: {outsider}",
        )
        self.assertEqual(outsider.get("error_code"), "not_a_member")

        member = self._signed_history(self.helper, "vis-e2e-private-history")
        self.assertTrue(member["ok"], f"member must read private history: {member}")

    def test_public_and_unlisted_history_open_read(self):
        for room_id, visibility in [
            ("vis-e2e-public-history", "public"),
            ("vis-e2e-unlisted-history", "unlisted"),
        ]:
            r = self._signed_join(room_id, visibility)
            self.assertTrue(
                r["ok"],
                f"signed join ({visibility}) should be accepted: {r}",
            )
            anon = self.client.post("/room_history", {"room_id": room_id, "limit": 20})
            self.assertTrue(
                anon["ok"],
                f"{visibility} history should be open-read without auth: {anon}",
            )

    def test_signed_set_visibility_gated_stays_listed(self):
        # Create as public (listed), then flip to gated — still listed.
        r = self._signed_join("vis-e2e-flip-gated", "public")
        self.assertTrue(r["ok"], f"signed join should be accepted: {r}")
        self.assertIn("vis-e2e-flip-gated", self._list_room_ids())
        proof = self.helper.sign_room_op_with_visibility(
            self.SETVIS_CTX, "vis-e2e-flip-gated", "gated")
        r2 = self.client.post("/set_room_visibility", {
            "alias": self.ALIAS, "room_id": "vis-e2e-flip-gated",
            "visibility": "gated", **proof,
        })
        self.assertTrue(r2["ok"],
                        f"signed set_room_visibility should be accepted: {r2}")
        self.assertIn("vis-e2e-flip-gated", self._list_room_ids(),
                      "gated room must REMAIN listed after public→gated")

    def test_signed_set_visibility_hides_room(self):
        # Create as public (listed), then flip to private (hidden).
        # The signed blob must carry the CANONICAL value the server stores;
        # body sends "invite_only", server canonicalizes to "private".
        r = self._signed_join("vis-e2e-flip", "public")
        self.assertTrue(r["ok"], f"signed join should be accepted: {r}")
        self.assertIn("vis-e2e-flip", self._list_room_ids())
        proof = self.helper.sign_room_op_with_visibility(
            self.SETVIS_CTX, "vis-e2e-flip", "private")
        r2 = self.client.post("/set_room_visibility", {
            "alias": self.ALIAS, "room_id": "vis-e2e-flip",
            "visibility": "invite_only", **proof,
        })
        self.assertTrue(r2["ok"],
                        f"signed set_room_visibility should be accepted: {r2}")
        self.assertNotIn("vis-e2e-flip", self._list_room_ids(),
                         "room must be hidden from /list_rooms after going private")


if __name__ == "__main__":
    unittest.main()
