from __future__ import annotations

import hashlib
import json
import urllib.error
import urllib.request

from c2c_relay_contract import (
    POW_BUCKET,
    POW_CTX,
    POW_D_MAX,
    POW_GRACE,
    POW_SCHEME,
    POW_SEP,
    POW_STEP,
    PowSlidingWindowAccumulator,
    pow_challenge_string,
    pow_leading_zero_bits,
    pow_mint,
    pow_required_difficulty,
    pow_verify,
)
from c2c_relay_server import relay_pow_enabled_from_env, start_server_thread


def _post_json(url: str, payload: dict) -> tuple[int, str, dict]:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            next_header = resp.headers.get("X-C2C-PoW-Next", "")
            return resp.status, next_header, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        try:
            next_header = exc.headers.get("X-C2C-PoW-Next", "")
            return exc.code, next_header, json.loads(exc.read())
        finally:
            exc.close()


def test_leading_zero_bits_counts_full_and_partial_bytes() -> None:
    assert pow_leading_zero_bits(bytes.fromhex("000ff0")) == 12
    assert pow_leading_zero_bits(bytes.fromhex("40")) == 1
    assert pow_leading_zero_bits(bytes.fromhex("80")) == 0


def test_challenge_string_is_deterministic_wire_format() -> None:
    challenge = pow_challenge_string(
        POW_CTX,
        "register",
        "ed25519-public-key",
        12345,
        "server-nonce",
    )

    assert challenge == (
        "c2c/v1/pow"
        f"{POW_SEP}register"
        f"{POW_SEP}ed25519-public-key"
        f"{POW_SEP}12345"
        f"{POW_SEP}server-nonce"
    )


def test_zero_difficulty_verifies_even_empty_nonce() -> None:
    challenge = pow_challenge_string(POW_CTX, "send", "actor", 1, "nonce")

    assert pow_verify(challenge, 0, "")


def test_minted_nonce_verifies() -> None:
    challenge = pow_challenge_string(POW_CTX, "send", "actor", 1, "nonce")
    nonce = pow_mint(challenge, 10)

    assert pow_verify(challenge, 10, nonce)


def test_wrong_nonce_fails_when_difficulty_exceeds_its_hash() -> None:
    challenge = pow_challenge_string(POW_CTX, "send", "actor", 1, "nonce")
    wrong_nonce = "definitely-wrong"
    digest = hashlib.sha256(f"{challenge}{POW_SEP}{wrong_nonce}".encode()).digest()
    difficulty = pow_leading_zero_bits(digest) + 1

    assert not pow_verify(challenge, difficulty, wrong_nonce)


def test_policy_grace_requires_zero_difficulty() -> None:
    assert pow_required_difficulty(0) == 0
    assert pow_required_difficulty(POW_GRACE) == 0


def test_policy_steps_discretely_after_grace() -> None:
    assert pow_required_difficulty(POW_GRACE + 1) == POW_STEP
    assert pow_required_difficulty(POW_GRACE + POW_BUCKET) == POW_STEP
    assert pow_required_difficulty(POW_GRACE + POW_BUCKET + 1) == 2 * POW_STEP


def test_policy_caps_at_max_difficulty() -> None:
    assert pow_required_difficulty(10**9) == POW_D_MAX


def test_sliding_window_accumulator_expires_old_costs() -> None:
    acc = PowSlidingWindowAccumulator(window_s=10.0)

    assert acc.add("actor", 7, now=100.0) == 7
    assert acc.add("actor", 5, now=105.0) == 12
    assert acc.accumulated("actor", now=111.0) == 5


def test_relay_pow_env_flag_defaults_off() -> None:
    assert relay_pow_enabled_from_env({}) is False
    assert relay_pow_enabled_from_env({"C2C_RELAY_POW": "0"}) is False
    assert relay_pow_enabled_from_env({"C2C_RELAY_POW": "1"}) is True


def test_health_advertises_pow_capability(monkeypatch) -> None:
    monkeypatch.setenv("C2C_RELAY_POW", "1")
    server, thread = start_server_thread("127.0.0.1", 0, token=None)
    try:
        host, port = server.server_address
        with urllib.request.urlopen(f"http://{host}:{port}/health", timeout=5) as resp:
            body = json.loads(resp.read())
    finally:
        server.shutdown()
        thread.join(timeout=2)

    assert body["pow"] == {"enabled": True, "scheme": POW_SCHEME}


def test_pow_enabled_rejects_costed_route_after_grace_and_accepts_minted_nonce(
    monkeypatch,
) -> None:
    monkeypatch.setenv("C2C_RELAY_POW", "1")
    server, thread = start_server_thread("127.0.0.1", 0, token=None)
    try:
        host, port = server.server_address
        base = f"http://{host}:{port}"
        actor_id = "actor-public-key"

        for idx in range(3):
            status, _, body = _post_json(base + "/register", {
                "node_id": "node-pow",
                "session_id": f"sess-{idx}",
                "alias": "pow-agent",
                "identity_pk": actor_id,
            })
            assert status == 200
            assert body["ok"] is True

        status, next_header, body = _post_json(base + "/register", {
            "node_id": "node-pow",
            "session_id": "sess-3",
            "alias": "pow-agent",
            "identity_pk": actor_id,
        })
        assert status == 429
        assert next_header.startswith("difficulty=4; ")
        assert set(body) == {"ok", "error_code", "required"}
        assert body["ok"] is False
        assert body["error_code"] == "pow_required"
        required = body["required"]
        assert required["ctx"] == POW_CTX
        assert required["difficulty"] == POW_STEP

        challenge = pow_challenge_string(
            required["ctx"],
            "register",
            actor_id,
            required["epoch"],
            required["server_nonce"],
        )
        nonce = pow_mint(challenge, required["difficulty"])
        status, next_header, body = _post_json(base + "/register", {
            "node_id": "node-pow",
            "session_id": "sess-3",
            "alias": "pow-agent",
            "identity_pk": actor_id,
            "pow_nonce": nonce,
            "pow_epoch": required["epoch"],
            "pow_server_nonce": required["server_nonce"],
        })

        assert status == 200
        assert body["ok"] is True
        assert next_header.startswith("difficulty=8; ")
    finally:
        server.shutdown()
        thread.join(timeout=2)
