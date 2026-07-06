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
