#!/usr/bin/env python3
"""
Ed25519 signing helper for mesh-test.sh.

Implements the c2c Ed25519 request signing protocol:
  canonical_request_blob: c2c/v1/request <0x1F> METHOD <0x1F> PATH <0x1F>
                         QUERY <0x1F> BODY_SHA256 <0x1F> TS <0x1F> NONCE
  canonical_register_blob: c2c/v1/register <0x1F> ALIAS <0x1F> RELAY_URL <0x1F>
                           PK_B64 <0x1F> TS <0x1F> NONCE
  Authorization header: Ed25519 alias=<alias>,ts=<unix_ts>,nonce=<nonce>,sig=<sig_b64url>
"""

import sys
import json
import base64
import hashlib
import time
import os

UNIT_SEP = "\x1f"
REQUEST_CTX = "c2c/v1/request"
REGISTER_CTX = "c2c/v1/register"


def b64url_encode(raw_bytes: bytes) -> str:
    return base64.urlsafe_b64encode(raw_bytes).rstrip(b"=").decode("ascii")


def b64url_decode(b64url: str) -> bytes:
    pad = (4 - len(b64url) % 4) % 4
    return base64.urlsafe_b64decode(b64url + "=" * pad)


def sha256_b64url(data: bytes) -> str:
    h = hashlib.sha256(data).digest()
    return b64url_encode(h)


def canonical_msg(ctx: str, fields: list[str]) -> bytes:
    return UNIT_SEP.join([ctx] + fields).encode("utf-8")


def get_pub_from_priv_seed(priv_seed_b64: str) -> tuple[bytes, bytes]:
    """Return (priv_seed_raw, pub_raw) from base64url-encoded seed."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    priv_seed = b64url_decode(priv_seed_b64)
    priv = Ed25519PrivateKey.from_private_bytes(priv_seed)
    pub_raw = priv.public_key().public_bytes_raw()
    return priv_seed, pub_raw


def sign_blob(priv_seed_raw: bytes, blob: bytes) -> bytes:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    priv = Ed25519PrivateKey.from_private_bytes(priv_seed_raw)
    return priv.sign(blob)


def sign_register(priv_seed_b64: str, alias: str, relay_url: str, ts: str, nonce: str) -> dict:
    """Sign a register blob. Returns {identity_pk_b64, ts, nonce, sig_b64}."""
    priv_seed, pub_raw = get_pub_from_priv_seed(priv_seed_b64)
    pub_b64 = b64url_encode(pub_raw)

    blob = canonical_msg(REGISTER_CTX, [
        alias.lower(), relay_url.lower(), pub_b64, ts, nonce
    ])
    sig = sign_blob(priv_seed, blob)
    return {
        "identity_pk_b64": pub_b64,
        "ts": ts,
        "nonce": nonce,
        "sig_b64": b64url_encode(sig)
    }


def make_ed25519_header(alias: str, ts: str, nonce: str, sig_b64: str) -> str:
    return f"Ed25519 alias={alias},ts={ts},nonce={nonce},sig={sig_b64}"


def sign_request(priv_seed_b64: str, alias: str, method: str, path: str, query: str,
                 body: bytes, ts: str, nonce: str) -> str:
    """Sign a request blob. Returns the full Authorization header value."""
    priv_seed, _ = get_pub_from_priv_seed(priv_seed_b64)

    body_hash = sha256_b64url(body) if body else ""
    blob = canonical_msg(REQUEST_CTX, [
        method.upper(), path, query, body_hash, ts, nonce
    ])
    sig = sign_blob(priv_seed, blob)
    sig_b64 = b64url_encode(sig)
    return make_ed25519_header(alias, ts, nonce, sig_b64)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: sign_ed25519.py <command> [args...]", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "gen-keypair":
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        priv = Ed25519PrivateKey.generate()
        priv_bytes = priv.private_bytes_raw()
        pub_bytes = priv.public_key().public_bytes_raw()
        print(json.dumps({
            "priv_seed_b64": b64url_encode(priv_bytes),
            "pub_b64": b64url_encode(pub_bytes)
        }))

    elif cmd == "sign-register":
        # args: priv_seed_b64 alias relay_url ts nonce
        priv_seed_b64, alias, relay_url, ts, nonce = sys.argv[2:7]
        result = sign_register(priv_seed_b64, alias, relay_url, ts, nonce)
        print(json.dumps(result))

    elif cmd == "sign-request":
        # args: priv_seed_b64 alias method path query body_file ts nonce
        priv_seed_b64, alias, method, path, query, body_file, ts, nonce = sys.argv[2:10]
        body = open(body_file, "rb").read() if body_file != "-" else b""
        header = sign_request(priv_seed_b64, alias, method, path, query, body, ts, nonce)
        print(header)

    elif cmd == "now-ts":
        print(str(int(time.time())))

    elif cmd == "now-rfc3339":
        from datetime import datetime, timezone
        print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
