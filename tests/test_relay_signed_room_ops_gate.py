#!/usr/bin/env python3
"""E2e tests for signed room-op / room-send enforcement (B114).

Since B114, signed room-operation proofs and signed /send_room envelopes are
MANDATORY by default. The legacy unsigned compatibility path exists only as an
explicit development gate: C2C_REQUIRE_SIGNED_ROOM_OPS=0, and that gate is
honored ONLY when the relay has no Bearer token configured (dev mode). A
token-configured (production) relay always requires signed proofs/envelopes.

Coverage (all against a locally spawned OCaml relay, token-configured unless
stated otherwise):
  - default (no env var): unsigned join/leave/set_visibility/knock/invite/
    uninvite/list_knocks/approve/deny → rejected with unsigned_room_op
  - default: envelope-less /send_room → rejected with unsigned_room_op
  - signed room ops and signed /send_room envelopes → accepted
  - dev gate (no token + C2C_REQUIRE_SIGNED_ROOM_OPS=0): unsigned ops and
    envelope-less sends accepted (legacy path)
  - prod ignores the dev gate (token + C2C_REQUIRE_SIGNED_ROOM_OPS=0):
    unsigned ops / envelope-less sends still rejected

These tests require the OCaml relay binary (c2c relay serve). They are NOT
run against the prod relay.

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
        # The relay applies a per-IP token-bucket rate limit (e.g. /room_history
        # burst 20, refill 1/s). A tight test loop from 127.0.0.1 can exhaust it
        # and get {"error":"rate_limit_exceeded","retry_after":N} — a harness
        # artifact, not the behaviour under test. Retry a bounded number of
        # times, honouring retry_after, so the assertions see the real response.
        for _attempt in range(8):
            req = urllib.request.Request(url, data=data or None, method=method)
            req.add_header("Content-Type", "application/json")
            if auth_header:
                req.add_header("Authorization", auth_header)
            elif self.token:
                req.add_header("Authorization", f"Bearer {self.token}")
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    result = json.loads(resp.read())
            except urllib.error.HTTPError as exc:
                try:
                    result = json.loads(exc.read())
                finally:
                    exc.close()
            if isinstance(result, dict) and result.get("error") == "rate_limit_exceeded":
                retry_after = result.get("retry_after", 0.5)
                time.sleep(min(float(retry_after) + 0.05, 3.0))
                continue
            return result
        return result

    def get(self, path: str) -> dict:
        return self._request("GET", path)

    def post(self, path: str, body: dict, auth_header: str | None = None) -> dict:
        return self._request("POST", path, body, auth_header=auth_header)

    def register(self, node_id: str, session_id: str, alias: str, **kw) -> dict:
        return self.post("/register", {"node_id": node_id, "session_id": session_id,
                                       "alias": alias, **kw})


class OCamlRelayServer:
    """Context manager: starts OCaml relay server as a subprocess, tears it down on exit."""

    def __init__(self, token: str | None, signed_env: str | None = None,
                 identity_path: str | None = None, port: int = TEST_PORT,
                 storage: str = "memory", persist_dir: str | None = None) -> None:
        """token=None starts a dev-mode relay (no --token flag).

        signed_env is the C2C_REQUIRE_SIGNED_ROOM_OPS value: None leaves the
        variable unset (the secure source default), "0" requests the legacy
        unsigned dev gate, "1" is the explicit strict setting.

        storage="sqlite" + persist_dir spins up a durable relay so a
        stop/restart cycle exercises on-disk persistence (B117)."""
        self.token = token
        self.signed_env = signed_env
        self.identity_path = identity_path
        self.port = port
        self.storage = storage
        self.persist_dir = persist_dir
        self._proc: subprocess.Popen | None = None

    def _build_env(self) -> dict:
        env = dict(os.environ)
        env.pop("C2C_MCP_SESSION_ID", None)
        if self.signed_env is None:
            env.pop("C2C_REQUIRE_SIGNED_ROOM_OPS", None)
        else:
            env["C2C_REQUIRE_SIGNED_ROOM_OPS"] = self.signed_env
        if self.identity_path:
            env["C2C_RELAY_IDENTITY_PATH"] = self.identity_path
        return env

    def start(self) -> "OCamlRelayServer":
        cmd = [
            C2C, "relay", "serve",
            "--listen", f"127.0.0.1:{self.port}",
            "--storage", self.storage,
        ]
        if self.persist_dir is not None:
            cmd += ["--persist-dir", self.persist_dir]
        if self.token is not None:
            cmd += ["--token", self.token]
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

    def sign_room_op_with_extra(self, sign_ctx: str, room_id: str,
                                *extra_fields: str) -> dict:
        """Proof for room ops whose canonical blob carries extra fields between
        alias and identity_pk, such as approve/deny knock requester_pk."""
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        nonce = self._b64url_nopad_encode(os.urandom(16))
        blob = "\x1f".join([
            sign_ctx,
            room_id,
            self.alias,
            *extra_fields,
            self.identity_pk_b64,
            ts,
            nonce,
        ])
        sig = self._sign(blob)
        return {
            "identity_pk": self.identity_pk_b64,
            "sig": self._b64url_nopad_encode(sig),
            "ts": ts,
            "nonce": nonce,
        }

    def sign_send_room(self, room_id: str, content: str) -> dict:
        """Signed /send_room envelope (spec §2, ctx c2c/v1/room-send).

        Mirrors OCaml Relay_signed_ops.sign_send_room: the canonical blob is
        [room_id, from_alias, sender_pk_b64, enc, ct_hash, ts, nonce] and
        ct is base64url-nopad of the UTF-8 content (enc="none" in v1)."""
        ct = content.encode()
        ct_b64 = self._b64url_nopad_encode(ct)
        ct_hash = self._b64url_nopad_encode(hashlib.sha256(ct).digest())
        enc = "none"
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        nonce = self._b64url_nopad_encode(os.urandom(16))
        blob = "\x1f".join([
            "c2c/v1/room-send",
            room_id,
            self.alias,
            self.identity_pk_b64,
            enc,
            ct_hash,
            ts,
            nonce,
        ])
        sig = self._sign(blob)
        return {
            "ct": ct_b64,
            "enc": enc,
            "sender_pk": self.identity_pk_b64,
            "sig": self._b64url_nopad_encode(sig),
            "ts": ts,
            "nonce": nonce,
        }


class RequireSignedRoomOpsTests(unittest.TestCase):
    """Tests for the secure source default (B114).

    C2C_REQUIRE_SIGNED_ROOM_OPS is left UNSET and the relay is
    token-configured: unsigned room ops must be rejected with
    relay_err_unsigned_room_op = "unsigned_room_op" out of the box.
    """

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None)
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


class RequireSignedRoomOpsKnockTests(RequireSignedRoomOpsTests):
    def test_unsigned_knock_room_rejected(self):
        """Unsigned /knock_room must be rejected with relay_err_unsigned_room_op."""
        r = self.client.post("/knock_room", {
            "alias": ALICE_ALIAS,
            "room_id": ROOM_ID,
        })
        self.assertFalse(r["ok"], f"unsigned knock_room should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")


class RequireSignedRoomOpsInviteTests(RequireSignedRoomOpsTests):
    FAKE_PK = _b64url_nopad(b"\x01" * 32)

    def _assert_unsigned_rejected(self, path: str, body: dict):
        r = self.client.post(path, body)
        self.assertFalse(r["ok"], f"unsigned {path} should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op for {path}, "
                         f"got {r.get('error_code')}: {r.get('error')}")

    def test_unsigned_invite_room_rejected(self):
        self._assert_unsigned_rejected("/invite_room", {
            "alias": ALICE_ALIAS, "room_id": ROOM_ID, "invitee_pk": self.FAKE_PK,
        })

    def test_unsigned_uninvite_room_rejected(self):
        self._assert_unsigned_rejected("/uninvite_room", {
            "alias": ALICE_ALIAS, "room_id": ROOM_ID, "invitee_pk": self.FAKE_PK,
        })

    def test_unsigned_list_room_knocks_rejected(self):
        self._assert_unsigned_rejected("/list_room_knocks", {
            "alias": ALICE_ALIAS, "room_id": ROOM_ID,
        })

    def test_unsigned_approve_room_knock_rejected(self):
        self._assert_unsigned_rejected("/approve_room_knock", {
            "alias": ALICE_ALIAS, "room_id": ROOM_ID, "requester_pk": self.FAKE_PK,
        })

    def test_unsigned_deny_room_knock_rejected(self):
        self._assert_unsigned_rejected("/deny_room_knock", {
            "alias": ALICE_ALIAS, "room_id": ROOM_ID, "requester_pk": self.FAKE_PK,
        })


class SendRoomEnvelopeEnforcementTests(unittest.TestCase):
    """B114: /send_room must reject an absent envelope by default and accept a
    valid signed envelope. Uses its own relay + a signed member identity."""

    ALIAS = "send-e2e-alice"
    ROOM = "send-e2e-room"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None,
                                      port=TEST_PORT + 3)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.helper = SignedRoomOpHelper(generate_identity(cls.ALIAS))
        cls.client.register(
            "n-send", "s-send", cls.ALIAS,
            **cls.helper.sign_register(cls.server.base_url),
        )
        proof = cls.helper.sign_room_op("c2c/v1/room-join", cls.ROOM)
        r = cls.client.post("/join_room", {
            "alias": cls.ALIAS, "room_id": cls.ROOM, **proof,
        })
        assert r.get("ok"), f"signed join_room failed in setup: {r}"

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def test_envelope_less_send_room_rejected(self):
        """An absent envelope must be rejected (unsigned_room_op), even from a
        current member alias — anonymous impersonation closure (B111/B114)."""
        r = self.client.post("/send_room", {
            "from_alias": self.ALIAS,
            "room_id": self.ROOM,
            "content": "no envelope here",
        })
        self.assertFalse(r["ok"], f"envelope-less send_room should be rejected: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")

    def test_signed_envelope_send_room_accepted(self):
        content = "hello signed room"
        envelope = self.helper.sign_send_room(self.ROOM, content)
        r = self.client.post("/send_room", {
            "from_alias": self.ALIAS,
            "room_id": self.ROOM,
            "content": content,
            "envelope": envelope,
        })
        self.assertTrue(r["ok"], f"signed send_room should be accepted: {r}")

    def test_forged_envelope_send_room_rejected(self):
        """An envelope signed by a key that is not bound to from_alias must be
        rejected — the envelope requirement must not be satisfiable by any
        random self-signed envelope."""
        imposter = SignedRoomOpHelper(generate_identity(self.ALIAS))
        content = "imposter message"
        envelope = imposter.sign_send_room(self.ROOM, content)
        r = self.client.post("/send_room", {
            "from_alias": self.ALIAS,
            "room_id": self.ROOM,
            "content": content,
            "envelope": envelope,
        })
        self.assertFalse(r["ok"], f"forged-envelope send_room should be rejected: {r}")
        self.assertEqual(r.get("error_code"), "alias_identity_mismatch",
                         f"expected alias_identity_mismatch: {r}")


class UnboundAliasProofRejectionTests(unittest.TestCase):
    """B114 review finding 1 (blocker): a valid *self-signed* proof/envelope
    for an alias that has NO registered identity binding must be REJECTED. A
    signed proof only authenticates the alias if the signing key is the one
    bound to that alias — otherwise any attacker key impersonates any
    unsigned-registered (unbound) alias. No first-proof TOFU pinning: room
    ops require a pre-existing matching binding."""

    VICTIM = "unbound-victim"
    ROOM = "unbound-room"

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None,
                                      port=TEST_PORT + 5)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        # Register the victim WITHOUT an identity proof (legacy unsigned
        # register) — the alias exists but has no bound identity_pk.
        cls.client.register("n-unbound", "s-unbound", cls.VICTIM)

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def test_arbitrary_key_join_as_unbound_alias_rejected(self):
        attacker = SignedRoomOpHelper(generate_identity(self.VICTIM))
        proof = attacker.sign_room_op("c2c/v1/room-join", self.ROOM)
        r = self.client.post("/join_room", {
            "alias": self.VICTIM, "room_id": self.ROOM, **proof,
        })
        self.assertFalse(r["ok"],
                         f"self-signed join for an unbound alias must be rejected: {r}")
        self.assertEqual(r.get("error_code"), "alias_identity_mismatch",
                         f"expected alias_identity_mismatch: {r}")

    def test_arbitrary_key_send_as_unbound_alias_rejected(self):
        attacker = SignedRoomOpHelper(generate_identity(self.VICTIM))
        content = "impersonated content"
        envelope = attacker.sign_send_room(self.ROOM, content)
        r = self.client.post("/send_room", {
            "from_alias": self.VICTIM, "room_id": self.ROOM,
            "content": content, "envelope": envelope,
        })
        self.assertFalse(r["ok"],
                         f"self-signed send for an unbound alias must be rejected: {r}")
        self.assertEqual(r.get("error_code"), "alias_identity_mismatch",
                         f"expected alias_identity_mismatch: {r}")


class InviteTargetBindingTests(unittest.TestCase):
    """B114 review finding 2 (major): the invite/uninvite signature must bind
    invitee_pk so the authorized target cannot be substituted by an
    intermediary. Also covers positive signed invite/uninvite/leave (missing
    from the original suite)."""

    ALIAS = "invite-e2e-owner"
    ROOM = "invite-e2e-room"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None,
                                      port=TEST_PORT + 6)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.helper = SignedRoomOpHelper(generate_identity(cls.ALIAS))
        cls.client.register(
            "n-inv", "s-inv", cls.ALIAS,
            **cls.helper.sign_register(cls.server.base_url),
        )
        # Owner creates a gated room (so invites are meaningful).
        proof = cls.helper.sign_room_op_with_visibility(
            "c2c/v1/room-join", cls.ROOM, "gated")
        r = cls.client.post("/join_room", {
            "alias": cls.ALIAS, "room_id": cls.ROOM,
            "visibility": "gated", **proof,
        })
        assert r.get("ok"), f"gated join failed in setup: {r}"

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def _target_pk(self) -> str:
        return SignedRoomOpHelper(generate_identity("some-invitee")).identity_pk_b64

    def test_signed_invite_accepted(self):
        target = self._target_pk()
        proof = self.helper.sign_room_op_with_extra(
            "c2c/v1/room-invite", self.ROOM, target)
        r = self.client.post("/invite_room", {
            "alias": self.ALIAS, "room_id": self.ROOM,
            "invitee_pk": target, **proof,
        })
        self.assertTrue(r["ok"], f"signed invite should be accepted: {r}")
        self.assertIn(target, r.get("invited_members", []),
                      f"invited target must be in ACL: {r}")

    def test_invitee_pk_substitution_rejected(self):
        """A proof produced for target A must NOT authorize inviting a
        substituted target B — invitee_pk is authorization-relevant and must
        be covered by the signature."""
        target_a = self._target_pk()
        target_b = self._target_pk()
        proof = self.helper.sign_room_op_with_extra(
            "c2c/v1/room-invite", self.ROOM, target_a)
        r = self.client.post("/invite_room", {
            "alias": self.ALIAS, "room_id": self.ROOM,
            "invitee_pk": target_b, **proof,
        })
        self.assertFalse(r["ok"],
                         f"substituted invitee_pk must be rejected: {r}")
        self.assertEqual(r.get("error_code"), "signature_invalid",
                         f"expected signature_invalid: {r}")

    def test_unbound_extra_field_invite_rejected(self):
        """The old unbound-target signature form (no invitee_pk in the blob)
        must no longer verify — proves the fix actually binds the target."""
        target = self._target_pk()
        proof = self.helper.sign_room_op("c2c/v1/room-invite", self.ROOM)
        r = self.client.post("/invite_room", {
            "alias": self.ALIAS, "room_id": self.ROOM,
            "invitee_pk": target, **proof,
        })
        self.assertFalse(r["ok"],
                         f"target-less invite signature must be rejected: {r}")

    def test_signed_uninvite_accepted(self):
        target = self._target_pk()
        # First invite (target-bound), then uninvite (target-bound).
        p_inv = self.helper.sign_room_op_with_extra(
            "c2c/v1/room-invite", self.ROOM, target)
        self.client.post("/invite_room", {
            "alias": self.ALIAS, "room_id": self.ROOM,
            "invitee_pk": target, **p_inv,
        })
        p_uninv = self.helper.sign_room_op_with_extra(
            "c2c/v1/room-uninvite", self.ROOM, target)
        r = self.client.post("/uninvite_room", {
            "alias": self.ALIAS, "room_id": self.ROOM,
            "invitee_pk": target, **p_uninv,
        })
        self.assertTrue(r["ok"], f"signed uninvite should be accepted: {r}")
        self.assertNotIn(target, r.get("invited_members", []),
                         f"uninvited target must be gone from ACL: {r}")

    def test_signed_leave_accepted(self):
        room = self.ROOM + "-leave"
        p_join = self.helper.sign_room_op("c2c/v1/room-join", room)
        j = self.client.post("/join_room", {
            "alias": self.ALIAS, "room_id": room, **p_join,
        })
        self.assertTrue(j["ok"], f"join for leave test failed: {j}")
        p_leave = self.helper.sign_room_op("c2c/v1/room-leave", room)
        r = self.client.post("/leave_room", {
            "alias": self.ALIAS, "room_id": room, **p_leave,
        })
        self.assertTrue(r["ok"], f"signed leave should be accepted: {r}")


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


class DevGateAllowsUnsignedTests(unittest.TestCase):
    """The legacy unsigned path survives ONLY as an explicit development gate:
    C2C_REQUIRE_SIGNED_ROOM_OPS=0 on a token-less (dev-mode) relay."""

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=None, signed_env="0",
                                      port=TEST_PORT + 1)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=None)
        cls.client.register("n", ALICE_SESSION + "-devgate",
                            ALICE_ALIAS + "-devgate")

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def test_unsigned_join_room_accepted_under_dev_gate(self):
        r = self.client.post("/join_room", {
            "alias": ALICE_ALIAS + "-devgate",
            "room_id": ROOM_ID + "-devgate",
        })
        self.assertTrue(r["ok"],
                        f"unsigned join_room should be accepted under the dev gate: {r}")

    def test_envelope_less_send_room_accepted_under_dev_gate(self):
        # Membership first (unsigned join, allowed under the dev gate).
        room = ROOM_ID + "-devgate-send"
        j = self.client.post("/join_room", {
            "alias": ALICE_ALIAS + "-devgate",
            "room_id": room,
        })
        self.assertTrue(j["ok"], f"dev-gate join for send test failed: {j}")
        r = self.client.post("/send_room", {
            "from_alias": ALICE_ALIAS + "-devgate",
            "room_id": room,
            "content": "legacy dev-gate message",
        })
        self.assertTrue(r["ok"],
                        f"envelope-less send_room should be accepted under the dev gate: {r}")


class ProdIgnoresDevGateTests(unittest.TestCase):
    """A token-configured (production) relay must ignore
    C2C_REQUIRE_SIGNED_ROOM_OPS=0 — there is no unsigned downgrade in prod."""

    server: OCamlRelayServer
    client: RelayClient

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env="0",
                                      port=TEST_PORT + 4)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.client.register("n", ALICE_SESSION + "-prodgate",
                            ALICE_ALIAS + "-prodgate")

    @classmethod
    def tearDownClass(cls):
        cls.server.close()

    def test_unsigned_join_room_still_rejected(self):
        r = self.client.post("/join_room", {
            "alias": ALICE_ALIAS + "-prodgate",
            "room_id": ROOM_ID + "-prodgate",
        })
        self.assertFalse(r["ok"],
                         f"token-configured relay must ignore the dev gate: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")

    def test_envelope_less_send_room_still_rejected(self):
        r = self.client.post("/send_room", {
            "from_alias": ALICE_ALIAS + "-prodgate",
            "room_id": ROOM_ID + "-prodgate",
            "content": "should not land",
        })
        self.assertFalse(r["ok"],
                         f"token-configured relay must ignore the dev gate for sends: {r}")
        self.assertEqual(r["error_code"], "unsigned_room_op",
                         f"expected unsigned_room_op, got {r.get('error_code')}: {r.get('error')}")


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
    KNOCK_CTX = "c2c/v1/room-knock"
    LIST_KNOCKS_CTX = "c2c/v1/room-list-knocks"
    APPROVE_KNOCK_CTX = "c2c/v1/room-approve-knock"
    DENY_KNOCK_CTX = "c2c/v1/room-deny-knock"
    ALIAS = "vis-e2e-alice"
    ALIAS2 = "vis-e2e-bob"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper
    helper2: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None,
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

    def _signed_knock(self, room_id: str) -> dict:
        proof = self.helper2.sign_room_op(self.KNOCK_CTX, room_id)
        return self.client.post("/knock_room", {
            "alias": self.ALIAS2,
            "room_id": room_id,
            **proof,
        })

    def _signed_list_knocks(self, room_id: str) -> dict:
        proof = self.helper.sign_room_op(self.LIST_KNOCKS_CTX, room_id)
        return self.client.post("/list_room_knocks", {
            "alias": self.ALIAS,
            "room_id": room_id,
            **proof,
        })

    def _signed_approve_knock(self, room_id: str) -> dict:
        proof = self.helper.sign_room_op_with_extra(
            self.APPROVE_KNOCK_CTX,
            room_id,
            self.helper2.identity_pk_b64,
        )
        return self.client.post("/approve_room_knock", {
            "alias": self.ALIAS,
            "room_id": room_id,
            "requester_pk": self.helper2.identity_pk_b64,
            **proof,
        })

    def _signed_deny_knock(self, room_id: str) -> dict:
        proof = self.helper.sign_room_op_with_extra(
            self.DENY_KNOCK_CTX,
            room_id,
            self.helper2.identity_pk_b64,
        )
        return self.client.post("/deny_room_knock", {
            "alias": self.ALIAS,
            "room_id": room_id,
            "requester_pk": self.helper2.identity_pk_b64,
            **proof,
        })

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

    def test_gated_knock_approve_then_join(self):
        room_id = "knock-e2e-approve"
        r = self._signed_join(room_id, "gated")
        self.assertTrue(r["ok"], f"signed join (gated) should be accepted: {r}")

        proof = self.helper2.sign_room_op(self.JOIN_CTX, room_id)
        pre_join = self.client.post("/join_room", {
            "alias": self.ALIAS2, "room_id": room_id, **proof,
        })
        self.assertFalse(pre_join["ok"],
                         f"uninvited requester should not join before approval: {pre_join}")

        knock = self._signed_knock(room_id)
        self.assertTrue(knock["ok"], f"signed knock should be accepted: {knock}")
        self.assertFalse(knock.get("already_pending"),
                         f"first knock should not be already_pending: {knock}")

        dup = self._signed_knock(room_id)
        self.assertTrue(dup["ok"], f"duplicate signed knock should be ok: {dup}")
        self.assertTrue(dup.get("already_pending"),
                        f"duplicate knock should be already_pending: {dup}")

        listed = self._signed_list_knocks(room_id)
        self.assertTrue(listed["ok"], f"member should list knocks: {listed}")
        knocks = listed.get("knocks", [])
        self.assertEqual(len(knocks), 1, f"expected one pending knock: {listed}")
        self.assertEqual(knocks[0]["requester_pk"], self.helper2.identity_pk_b64)

        approve = self._signed_approve_knock(room_id)
        self.assertTrue(approve["ok"], f"member should approve knock: {approve}")

        proof = self.helper2.sign_room_op(self.JOIN_CTX, room_id)
        joined = self.client.post("/join_room", {
            "alias": self.ALIAS2, "room_id": room_id, **proof,
        })
        self.assertTrue(joined["ok"], f"approved requester should join: {joined}")

    def test_gated_knock_deny_keeps_join_blocked(self):
        room_id = "knock-e2e-deny"
        r = self._signed_join(room_id, "gated")
        self.assertTrue(r["ok"], f"signed join (gated) should be accepted: {r}")

        knock = self._signed_knock(room_id)
        self.assertTrue(knock["ok"], f"signed knock should be accepted: {knock}")

        deny = self._signed_deny_knock(room_id)
        self.assertTrue(deny["ok"], f"member should deny knock: {deny}")

        listed = self._signed_list_knocks(room_id)
        self.assertTrue(listed["ok"], f"member should list knocks: {listed}")
        self.assertEqual(listed.get("knocks", []), [],
                         f"denied knock should be removed: {listed}")

        proof = self.helper2.sign_room_op(self.JOIN_CTX, room_id)
        joined = self.client.post("/join_room", {
            "alias": self.ALIAS2, "room_id": room_id, **proof,
        })
        self.assertFalse(joined["ok"],
                         f"denied requester should remain unable to join: {joined}")

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
        # The signed blob and body must both carry the canonical value the
        # server stores ("private").
        r = self._signed_join("vis-e2e-flip", "public")
        self.assertTrue(r["ok"], f"signed join should be accepted: {r}")
        self.assertIn("vis-e2e-flip", self._list_room_ids())
        proof = self.helper.sign_room_op_with_visibility(
            self.SETVIS_CTX, "vis-e2e-flip", "private")
        r2 = self.client.post("/set_room_visibility", {
            "alias": self.ALIAS, "room_id": "vis-e2e-flip",
            "visibility": "private", **proof,
        })
        self.assertTrue(r2["ok"],
                        f"signed set_room_visibility should be accepted: {r2}")
        self.assertNotIn("vis-e2e-flip", self._list_room_ids(),
                         "room must be hidden from /list_rooms after going private")


class HistoryPublicE2ETests(unittest.TestCase):
    """B117: history readability is a persisted per-room policy.

    Matrix:
      - anonymous /room_history on a public/unlisted room is allowed ONLY when
        history_public is true (default true; closing it makes it member-only);
      - a valid member can still read a history-closed listed room;
      - a visibility downgrade to gated/private atomically clears history_public
        (and stays anonymous-unreadable);
      - setting history_public=true on a gated/private room is rejected.

    Self-contained: generates its own signed identities; the first signed room
    op pins each key to its alias (TOFU). No on-disk identity fixture needed."""

    JOIN_CTX = "c2c/v1/room-join"
    SETVIS_CTX = "c2c/v1/room-set-visibility"
    SETHP_CTX = "c2c/v1/room-set-history-public"
    ALIAS = "hp-e2e-alice"
    ALIAS2 = "hp-e2e-bob"

    server: OCamlRelayServer
    client: RelayClient
    helper: SignedRoomOpHelper
    helper2: SignedRoomOpHelper

    @classmethod
    def setUpClass(cls):
        cls.server = OCamlRelayServer(token=TOKEN, signed_env=None,
                                      port=TEST_PORT + 7)
        cls.server.start()
        cls.client = RelayClient(cls.server.base_url, token=TOKEN)
        cls.helper = SignedRoomOpHelper(generate_identity(cls.ALIAS))
        cls.client.register(
            "n-hp", "s-hp", cls.ALIAS,
            **cls.helper.sign_register(cls.server.base_url),
        )
        cls.helper2 = SignedRoomOpHelper(generate_identity(cls.ALIAS2))
        cls.client.register(
            "n-hp2", "s-hp2", cls.ALIAS2,
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

    def _set_history_public(self, helper: SignedRoomOpHelper, alias: str,
                            room_id: str, value: bool) -> dict:
        proof = helper.sign_room_op_with_extra(
            self.SETHP_CTX, room_id, "true" if value else "false")
        return self.client.post("/set_room_history_public", {
            "alias": alias, "room_id": room_id, "history_public": value,
            **proof,
        })

    def _anon_history(self, room_id: str) -> dict:
        return self.client.post("/room_history", {"room_id": room_id, "limit": 20})

    def _member_history(self, helper: SignedRoomOpHelper, room_id: str) -> dict:
        body = {"room_id": room_id, "limit": 20}
        return self.client.post(
            "/room_history", body,
            auth_header=helper.sign_request("POST", "/room_history", body),
        )

    def test_public_default_open_then_close_gates_anon(self):
        room = "hp-public-close"
        self.assertTrue(self._signed_join(room, "public")["ok"])
        # default true → anonymous read allowed
        self.assertTrue(self._anon_history(room)["ok"],
                        "public room defaults to open history")
        # close it → anonymous read now rejected
        r = self._set_history_public(self.helper, self.ALIAS, room, False)
        self.assertTrue(r["ok"], f"member should close history: {r}")
        self.assertIs(r.get("history_public"), False)
        anon = self._anon_history(room)
        self.assertFalse(anon["ok"],
                         f"closed public history must be member-only: {anon}")
        self.assertEqual(anon.get("error_code"), "not_a_member")

    def test_member_reads_closed_listed_room(self):
        room = "hp-public-member-read"
        self.assertTrue(self._signed_join(room, "public")["ok"])
        self.assertTrue(
            self._set_history_public(self.helper, self.ALIAS, room, False)["ok"])
        # anon blocked, member (creator) still allowed
        self.assertFalse(self._anon_history(room)["ok"])
        member = self._member_history(self.helper, room)
        self.assertTrue(member["ok"],
                        f"member must read a history-closed listed room: {member}")

    def test_unlisted_close_gates_anon(self):
        room = "hp-unlisted-close"
        self.assertTrue(self._signed_join(room, "unlisted")["ok"])
        self.assertTrue(self._anon_history(room)["ok"],
                        "unlisted room defaults to open history")
        self.assertTrue(
            self._set_history_public(self.helper, self.ALIAS, room, False)["ok"])
        self.assertFalse(self._anon_history(room)["ok"],
                         "closed unlisted history must be member-only")

    def test_reopen_restores_anon_read(self):
        room = "hp-reopen"
        self.assertTrue(self._signed_join(room, "public")["ok"])
        self.assertTrue(
            self._set_history_public(self.helper, self.ALIAS, room, False)["ok"])
        self.assertFalse(self._anon_history(room)["ok"])
        self.assertTrue(
            self._set_history_public(self.helper, self.ALIAS, room, True)["ok"])
        self.assertTrue(self._anon_history(room)["ok"],
                        "reopened public history must be anon-readable again")

    def test_set_true_on_gated_rejected(self):
        room = "hp-gated-reject"
        self.assertTrue(self._signed_join(room, "gated")["ok"])
        r = self._set_history_public(self.helper, self.ALIAS, room, True)
        self.assertFalse(r["ok"],
                         f"history_public=true must be rejected for gated: {r}")
        self.assertEqual(r.get("error_code"), "history_public_gated")

    def test_set_true_on_private_rejected(self):
        room = "hp-private-reject"
        self.assertTrue(self._signed_join(room, "private")["ok"])
        r = self._set_history_public(self.helper, self.ALIAS, room, True)
        self.assertFalse(r["ok"],
                         f"history_public=true must be rejected for private: {r}")
        self.assertEqual(r.get("error_code"), "history_public_gated")

    def test_visibility_downgrade_clears_and_gates_anon(self):
        room = "hp-downgrade"
        self.assertTrue(self._signed_join(room, "public")["ok"])
        self.assertTrue(self._anon_history(room)["ok"])
        # public → gated must atomically clear history_public
        proof = self.helper.sign_room_op_with_visibility(
            self.SETVIS_CTX, room, "gated")
        r = self.client.post("/set_room_visibility", {
            "alias": self.ALIAS, "room_id": room, "visibility": "gated", **proof,
        })
        self.assertTrue(r["ok"], f"set_room_visibility should succeed: {r}")
        self.assertIs(r.get("history_public"), False,
                      "downgrade must report history_public cleared")
        anon = self._anon_history(room)
        self.assertFalse(anon["ok"],
                         "gated room history must be member-only after downgrade")
        self.assertEqual(anon.get("error_code"), "not_a_member")

    def test_non_member_cannot_set_history_public(self):
        room = "hp-nonmember"
        self.assertTrue(self._signed_join(room, "public")["ok"])
        # helper2 is registered but NOT a member of this room
        r = self._set_history_public(self.helper2, self.ALIAS2, room, False)
        self.assertFalse(r["ok"],
                         f"non-member must not change history_public: {r}")
        self.assertEqual(r.get("error_code"), "not_a_member")


class HistoryPublicPersistenceTests(unittest.TestCase):
    """B117: the history_public setting survives a relay restart on the SQLite
    (durable) storage path. Start sqlite-backed relay, close history, stop,
    restart on the same persist-dir, and confirm the setting is retained."""

    ALIAS = "hp-persist-alice"
    ROOM = "hp-persist-room"

    def test_history_public_survives_restart(self):
        data_dir = tempfile.mkdtemp(prefix="c2c-hp-persist-")
        port = TEST_PORT + 8
        helper = SignedRoomOpHelper(generate_identity(self.ALIAS))
        try:
            # --- first boot: register, join public, close history ---
            with OCamlRelayServer(token=TOKEN, signed_env=None, port=port,
                                  storage="sqlite", persist_dir=data_dir):
                client = RelayClient(f"http://127.0.0.1:{port}", token=TOKEN)
                client.register("n-hpp", "s-hpp", self.ALIAS,
                                **helper.sign_register(f"http://127.0.0.1:{port}"))
                join = helper.sign_room_op_with_visibility(
                    "c2c/v1/room-join", self.ROOM, "public")
                r = client.post("/join_room", {
                    "alias": self.ALIAS, "room_id": self.ROOM,
                    "visibility": "public", **join,
                })
                self.assertTrue(r["ok"], f"join failed: {r}")
                proof = helper.sign_room_op_with_extra(
                    "c2c/v1/room-set-history-public", self.ROOM, "false")
                r = client.post("/set_room_history_public", {
                    "alias": self.ALIAS, "room_id": self.ROOM,
                    "history_public": False, **proof,
                })
                self.assertTrue(r["ok"], f"close history failed: {r}")
                self.assertFalse(
                    client.post("/room_history",
                                {"room_id": self.ROOM, "limit": 5})["ok"],
                    "closed history should be anon-unreadable before restart")

            # --- second boot on the same DB: setting must persist ---
            with OCamlRelayServer(token=TOKEN, signed_env=None, port=port,
                                  storage="sqlite", persist_dir=data_dir):
                client = RelayClient(f"http://127.0.0.1:{port}", token=TOKEN)
                anon = client.post("/room_history",
                                   {"room_id": self.ROOM, "limit": 5})
                self.assertFalse(
                    anon["ok"],
                    f"history_public=false must persist across restart: {anon}")
                self.assertEqual(anon.get("error_code"), "not_a_member")
        finally:
            subprocess.run(["rm", "-rf", data_dir], check=False)


if __name__ == "__main__":
    unittest.main()
