"""Architecture guards for relay.ml refactors."""

import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


def test_relay_common_helpers_are_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    common_ml = REPO / "ocaml" / "relay_common.ml"

    assert common_ml.exists(), "expected extracted relay common helper module"
    common_src = common_ml.read_text(encoding="utf-8")

    for name in [
        "relay_err_unknown_alias",
        "default_lease_ttl",
        "effective_lease_ttl",
        "alias_release_warning",
        "room_join_sign_ctx",
        "bare_alias",
        "require_signed_room_ops",
        "room_knock",
        "canonical_visibility",
        "parse_ed25519_auth_params",
        "sorted_query_string",
        "body_sha256_b64",
        "b64url_nopad_encode",
    ]:
        assert re.search(rf"\b(let|type)\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\b(let|type)\s+{re.escape(name)}\b", common_src)

    assert re.search(r"\binclude\s+Relay_common\b", relay_ml)


def test_relay_sqlite_support_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    support_ml = REPO / "ocaml" / "relay_sqlite_support.ml"

    assert support_ml.exists(), "expected extracted relay SQLite support module"
    support_src = support_ml.read_text(encoding="utf-8")

    for name in [
        "sqlite_ddl",
        "exec_no_rows",
        "exec_one_row",
        "exec_many_rows",
        "exec_prepared",
    ]:
        assert re.search(rf"\blet\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\blet\s+{re.escape(name)}\b", support_src)

    assert re.search(r"\binclude\s+Relay_sqlite_support\b", relay_ml)


def test_relay_pairing_token_sql_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    token_sql_ml = REPO / "ocaml" / "relay_pairing_token_sql.ml"

    assert token_sql_ml.exists(), "expected extracted pairing-token SQL module"
    token_sql_src = token_sql_ml.read_text(encoding="utf-8")

    for name in [
        "store_pairing_token_db",
        "get_and_burn_pairing_token_db",
        "find_pairing_token_db",
    ]:
        assert re.search(rf"\blet\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\blet\s+{re.escape(name)}\b", token_sql_src)

    assert re.search(r"\binclude\s+Relay_pairing_token_sql\b", relay_ml)


def test_relay_host_routing_helpers_are_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    host_routing_ml = REPO / "ocaml" / "relay_host_routing.ml"

    assert host_routing_ml.exists(), "expected extracted relay host-routing module"
    host_routing_src = host_routing_ml.read_text(encoding="utf-8")

    for name in [
        "split_alias_host",
        "host_acceptable",
        "peer_relay_t",
    ]:
        assert re.search(rf"\b(let|type)\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\b(let|type)\s+{re.escape(name)}\b", host_routing_src)

    assert re.search(r"\binclude\s+Relay_host_routing\b", relay_ml)


def test_relay_observer_bindings_module_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    bindings_ml = REPO / "ocaml" / "relay_observer_bindings.ml"

    assert bindings_ml.exists(), "expected extracted observer bindings module"
    bindings_src = bindings_ml.read_text(encoding="utf-8")

    assert re.search(r"\bmodule\s+ObserverBindings\b", relay_ml) is None
    assert re.search(r"\bmodule\s+ObserverBindings\b", bindings_src)

    for pattern in [
        r"\btype\s+binding\b",
        r"\bphone_pk_to_binding\b",
    ]:
        assert re.search(pattern, relay_ml) is None
        assert re.search(pattern, bindings_src)

    assert re.search(r"\binclude\s+Relay_observer_bindings\b", relay_ml)


def test_relay_observer_sessions_module_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    sessions_ml = REPO / "ocaml" / "relay_observer_sessions.ml"

    assert sessions_ml.exists(), "expected extracted observer sessions module"
    sessions_src = sessions_ml.read_text(encoding="utf-8")

    assert re.search(r"\bmodule\s+ObserverSessions\b", relay_ml) is None
    assert re.search(r"\bmodule\s+ObserverSessions\b", sessions_src)

    for pattern in [
        r"\bmutable\s+sessions\b",
        r"\bRelay_ws_frame\.Session\.t\s+list\b",
    ]:
        assert re.search(pattern, relay_ml) is None
        assert re.search(pattern, sessions_src)

    assert re.search(r"\binclude\s+Relay_observer_sessions\b", relay_ml)


def test_relay_observer_protocol_parser_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    protocol_ml = REPO / "ocaml" / "relay_observer_protocol.ml"

    assert protocol_ml.exists(), "expected extracted observer protocol module"
    protocol_src = protocol_ml.read_text(encoding="utf-8")

    assert re.search(r"\blet\s+parse_observer_ws_msg\b", relay_ml) is None
    assert re.search(r"\blet\s+parse_observer_ws_msg\b", protocol_src)
    assert re.search(r"\binclude\s+Relay_observer_protocol\b", relay_ml)


def test_relay_observer_push_helpers_are_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    push_ml = REPO / "ocaml" / "relay_observer_push.ml"

    assert push_ml.exists(), "expected extracted observer push module"
    push_src = push_ml.read_text(encoding="utf-8")

    for name in [
        "observer_sessions",
        "push_to_observers",
        "push_pseudo_registration_to_observers",
        "push_pseudo_unregistration_to_observers",
    ]:
        assert re.search(rf"\blet\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\blet\s+{re.escape(name)}\b", push_src)

    assert re.search(r"\binclude\s+Relay_observer_push\b", relay_ml)


def test_relay_mobile_pair_nonce_cache_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    nonce_cache_ml = REPO / "ocaml" / "relay_mobile_pair_nonce_cache.ml"

    assert nonce_cache_ml.exists(), "expected extracted mobile-pair nonce cache module"
    nonce_cache_src = nonce_cache_ml.read_text(encoding="utf-8")

    assert re.search(r"\bmodule\s+NonceCache\b", relay_ml) is None
    assert re.search(r"\bmodule\s+NonceCache\b", nonce_cache_src)

    for name in [
        "nonce_cache",
        "is_nonce_seen",
        "record_nonce",
        "cleanup_nonce_cache",
    ]:
        assert re.search(rf"\blet\s+{re.escape(name)}\b", relay_ml) is None
        assert re.search(rf"\blet\s+{re.escape(name)}\b", nonce_cache_src)

    assert re.search(r"\binclude\s+Relay_mobile_pair_nonce_cache\b", relay_ml)


def test_relay_registration_lease_module_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    lease_ml = REPO / "ocaml" / "relay_registration_lease.ml"

    assert lease_ml.exists(), "expected extracted registration lease module"
    lease_src = lease_ml.read_text(encoding="utf-8")

    assert re.search(r"\bmodule\s+RegistrationLease\b", relay_ml) is None
    assert re.search(r"\bmodule\s+RegistrationLease\b", lease_src)

    for pattern in [
        r"\bval\s+make\b",
        r"\blet\s+to_json\b",
        r"\blet\s+opaque_host_id\b",
    ]:
        assert re.search(pattern, lease_src)

    assert re.search(r"\binclude\s+Relay_registration_lease\b", relay_ml)


def test_relay_pow_challenge_helpers_are_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    pow_ml = REPO / "ocaml" / "relay_pow_challenge.ml"

    assert pow_ml.exists(), "expected extracted relay PoW challenge module"
    pow_src = pow_ml.read_text(encoding="utf-8")

    assert re.search(r"\bmodule\s+PowChallenges\b", relay_ml) is None
    assert re.search(r"\bmodule\s+PowChallenges\b", pow_src)

    for name in [
        "pow_challenge_ttl_s",
        "pow_header_name",
        "relay_pow_policy",
        "relay_pow_enabled",
        "stateless_pow_challenge",
        "issue_pow_challenge",
        "pow_header_value",
        "pow_header",
    ]:
        assert re.search(rf"^let\s+{re.escape(name)}\b", relay_ml, re.MULTILINE) is None
        assert re.search(rf"^let\s+{re.escape(name)}\b", pow_src, re.MULTILINE)

    assert re.search(r"\btype\s+pow_challenge\b", pow_src)
    assert re.search(r"\binclude\s+Relay_pow_challenge\b", relay_ml)


def test_relay_client_module_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    client_ml = REPO / "ocaml" / "relay_client.ml"

    assert client_ml.exists(), "expected extracted relay client module"
    client_src = client_ml.read_text(encoding="utf-8")

    assert re.search(r"^module\s+Relay_client\b", relay_ml, re.MULTILINE) is None
    assert re.search(r"^module\s+Relay_client\b", client_src, re.MULTILINE)

    for pattern in [
        r"\bval\s+request\b",
        r"\blet\s+post_with_pow_retry\b",
        r"\blet\s+register_signed\b",
        r"\blet\s+room_history\b",
        r"\blet\s+mobile_pair_prepare\b",
    ]:
        assert re.search(pattern, client_src)

    assert re.search(r"\binclude\s+Relay_client\b", relay_ml)


def test_relay_backend_contract_is_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    contract_ml = REPO / "ocaml" / "relay_backend_contract.ml"

    assert contract_ml.exists(), "expected extracted relay backend contract module"
    contract_src = contract_ml.read_text(encoding="utf-8")

    for pattern in [
        r"^type\s+device_pair_pending\b",
        r"^let\s+get_now\b",
        r"^let\s+with_lock\b",
        r"^module\s+type\s+RELAY\b",
    ]:
        assert re.search(pattern, relay_ml, re.MULTILINE) is None
        assert re.search(pattern, contract_src, re.MULTILINE)

    assert re.search(r"\binclude\s+Relay_backend_contract\b", relay_ml)


def test_relay_alias_helpers_are_extracted_from_relay_ml():
    relay_ml = (REPO / "ocaml" / "relay.ml").read_text(encoding="utf-8")
    alias_ml = REPO / "ocaml" / "relay_alias_helpers.ml"

    assert alias_ml.exists(), "expected extracted relay alias helper module"
    alias_src = alias_ml.read_text(encoding="utf-8")

    for name in [
        "normalize_relay_alias",
        "alias_matches_display",
    ]:
        assert re.search(rf"^let\s+{re.escape(name)}\b", relay_ml, re.MULTILINE) is None
        assert re.search(rf"^let\s+{re.escape(name)}\b", alias_src, re.MULTILINE)

    assert re.search(r"\binclude\s+Relay_alias_helpers\b", relay_ml)
