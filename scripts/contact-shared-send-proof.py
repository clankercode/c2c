#!/usr/bin/env python3
"""Native B370 shared-send proof. Uses owned fixture actors on one buildbox.

This complements, and never substitutes for, the separate two-host receipt.
"""
import json
import os
from pathlib import Path
import runpy
import re
import stat
import sys

helpers = runpy.run_path(str(Path(__file__).with_name("test-contact-deliver-cli.py")))
Fixture = helpers["Fixture"]
require = helpers["require"]
parse_json = helpers["parse_json"]
private_json = helpers["private_json"]


def outbox(f, who="alice"):
    path = f.root / who / "broker/remote-outbox-v2.jsonl"
    return [parse_json(line, "outbox_json") for line in path.read_text().splitlines() if line] if path.exists() else []


def sync(f, who="alice"):
    return f.run("relay", "connect", "--once", "--relay-url", f.url,
                 "--broker-root", f.root / who / "broker", "--node-id", f.node(who), who=who, ok=False)


def normal_send(f, body, who="alice", recipient="bob", ok=True):
    result = f.run("send", "--json", f.route(recipient), body, who=who, ok=ok)
    if not ok:
        return result
    data = parse_json(result.stdout, "normal_send_receipt")
    require(data.get("delivery", {}).get("state") == "queued", "honest_queued_receipt")
    require(isinstance(data.get("message_id"), str) and data["message_id"], "normal_send_stable_id")
    return data


def mcp_send(f, body):
    calls = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "owned-contact-proof", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "send", "arguments": {"to_alias": f.route("bob"), "content": body}}},
    ]
    result = f.command([f.mcp_binary], f.env(), "native_mcp_send", input_text="".join(json.dumps(call) + "\n" for call in calls))
    replies = [parse_json(line, "mcp_response_json") for line in result.stdout.splitlines() if line.startswith("{")]
    initialized = next((reply for reply in replies if reply.get("id") == 1), {})
    source = initialized.get("result", {}).get("serverInfo", {}).get("git_hash", "")
    require(re.fullmatch(r"[0-9a-f]{8}", source) and f.source_commit.startswith(source), "mcp_compiled_source_matches")
    response = next((reply for reply in replies if reply.get("id") == 2), {})
    result = response.get("result", {})
    require(not result.get("isError") and isinstance(result.get("content"), list), "mcp_send_tool_success")
    text = "".join(item.get("text", "") for item in result["content"])
    receipt = parse_json(text, "mcp_send_receipt")
    require(isinstance(receipt.get("message_id"), str), "mcp_send_stable_id")
    return receipt


def mode_proof(binary, mcp_binary, source_commit, tls):
    with Fixture(binary, tls=tls, server_flag=None if tls else "--allow-contact-http") as f:
        f.mcp_binary, f.source_commit = mcp_binary, source_commit
        flags = () if tls else ("--allow-http",)
        path, grant = f.issue()
        reverse_path, reverse = f.issue(sender="bob", recipient="alice")
        f.import_grant(path, flags=flags)
        f.import_grant(reverse_path, who="bob", recipient="alice", flags=flags)
        mark = f.observer.mark()
        f.accepted(f.direct("direct-first", "shared direct private DM"))
        f.expect_message(f.poll(), "shared direct private DM")
        f.accepted(f.direct("direct-reply", "separate reverse grant reply", who="bob", recipient="alice"))
        f.expect_message(f.poll("alice"), "separate reverse grant reply", sender="bob")
        f.assert_network(mark, count=2)
        f.check("direct_shared_send_and_separate_reverse_reply")

        mark = f.observer.mark()
        receipt = normal_send(f, "normal CLI grant delivery")
        pending = outbox(f)
        require(len(pending) == 1 and pending[0].get("message_id") == receipt["message_id"], "outbox_receipt_id_matches")
        require(pending[0].get("relay_url") == f.url, "outbox_destination_pinned")
        require("grant_secret" not in json.dumps(pending), "outbox_no_grant_secret")
        sync(f)
        require(not outbox(f), "normal_outbox_acknowledged")
        f.assert_network(mark, count=1, grant_id=grant["grant_id"], message_id=receipt["message_id"])
        f.expect_message(f.poll(), "normal CLI grant delivery")
        f.check("normal_cli_selects_contact_grant_and_exposes_id")

        mark = f.observer.mark()
        receipt = mcp_send(f, "MCP shared grant delivery")
        sync(f)
        f.assert_network(mark, count=1, grant_id=grant["grant_id"], message_id=receipt["message_id"])
        f.expect_message(f.poll(), "MCP shared grant delivery")
        f.check("mcp_tool_inherits_shared_selection")

        # Independent grants may reuse a client ID. Exercise the receiving
        # connector itself, including a fresh process reading its durable
        # dedupe ledger, rather than checking only relay admission counts.
        outsider_path, _ = f.issue(sender="outsider")
        f.import_grant(outsider_path, who="outsider", flags=flags)
        mark = f.observer.mark()
        f.accepted(f.direct("independent-id", "same ID from alice"))
        f.accepted(f.direct("independent-id", "same ID from outsider", who="outsider"))
        sync(f, "bob")
        inbox_path = f.root / "bob" / "broker" / (f.sid("bob") + ".inbox.json")
        rows = parse_json(inbox_path.read_text(), "native_receiver_inbox")
        f.expect_message(rows, "same ID from alice")
        f.expect_message(rows, "same ID from outsider", sender="outsider")
        delivered_ids = [row.get("message_id") for row in rows]
        require(len(delivered_ids) == 2
                and all(isinstance(value, str) and value for value in delivered_ids)
                and len(set(delivered_ids)) == 2,
                "grant_namespaced_inbox_ids")
        f.accepted(f.direct("independent-id", "same ID from alice"), duplicate=True)
        sync(f, "bob")
        require(parse_json(inbox_path.read_text(), "native_receiver_restart_inbox") == rows,
                "receiver_restart_duplicate_not_reappended")
        f.assert_network(mark, count=3)
        f.check("inbound_connector_preserves_independent_sender_ids")

        # Lose a response only after native relay admission. Restart only the
        # owned native relay, then the next CLI connector process must replay
        # the original ID and grant, with exactly one relay inbox effect.
        mark = f.observer.mark()
        receipt = normal_send(f, "response loss survives restart")
        f.observer.lose_next_contact_response = True
        sync(f)
        pending = outbox(f)
        require(len(pending) == 1 and pending[0].get("message_id") == receipt["message_id"], "uncertain_send_retained")
        f.start_server(None if tls else "--allow-contact-http")
        sync(f)
        require(not outbox(f), "replayed_duplicate_acknowledged")
        events = f.assert_network(mark, count=2, grant_id=grant["grant_id"], message_id=receipt["message_id"])
        require(events[0].get("response_lost") is True, "native_response_loss_observed")
        f.expect_message(f.poll(), "response loss survives restart")
        f.expect_message(f.poll(), "response loss survives restart", count=0)
        f.check("response_loss_native_relay_and_connector_restart_dedup")

        # Disable does not discard queued mail. Reimporting the same explicitly
        # verified grant re-enables it while retaining its original retry pin.
        receipt = normal_send(f, "held pending mail survives disable")
        f.run("relay", "contact", "disable", "--relay-url", f.url, "--to", f.route("bob"))
        mark = f.observer.mark()
        sync(f)
        f.assert_network(mark, count=0)
        require(len(outbox(f)) == 1, "disabled_pending_mail_retained")
        f.denied(normal_send(f, "disabled new message refused", ok=False), "disabled_enqueue_refused", "disabled")
        f.import_grant(path, flags=flags)
        sync(f)
        f.assert_network(mark, count=1, message_id=receipt["message_id"])
        f.expect_message(f.poll(), "held pending mail survives disable")
        f.check("disabled_route_holds_and_preserves_pending_mail")

        mark = f.observer.mark()
        f.denied(f.import_grant(path, who="outsider", ok=False, flags=flags), "wrong_sender_import", "sender mismatch")
        f.denied(f.import_grant(path, url=f.url.replace("localhost", "127.0.0.1"), ok=False, flags=flags),
                 "wrong_url_import", "mismatch")
        f.denied(f.direct("direct-first", "conflicting content", ok=False), "id_payload_conflict", "payload conflict")
        f.assert_network(mark, count=0)
        f.check("wrong_sender_url_and_id_conflicts_refused_locally")

        metadata = f.run("relay", "contact", "stored").stdout
        require(grant["grant_secret"] not in metadata and "grant_secret" not in metadata, "stored_metadata_redacted")
        export_path = f.root / "exported-private-contact.json"
        f.run("relay", "contact", "export", "--relay-url", f.url, "--to", f.route("bob"), "--grant-file", export_path)
        require(stat.S_IMODE(export_path.stat().st_mode) == 0o600, "export_owner_only")
        f.denied(f.run("relay", "contact", "export", "--relay-url", f.url, "--to", f.route("bob"),
                       "--grant-file", export_path, ok=False), "export_no_overwrite")
        f.check("metadata_redaction_and_exclusive_private_export")

        # Rotation is recipient-authorized. It changes selection for new IDs;
        # the old ID must keep its revoked original grant and never fall back.
        rotated_path, rotated = f.issue(rotate_grant_id=grant["grant_id"])
        require(rotated["generation"] > grant["generation"], "recipient_rotation_generation")
        f.import_grant(rotated_path, flags=flags)
        mark = f.observer.mark()
        f.denied(f.direct("direct-first", "shared direct private DM", ok=False), "old_pin_held_after_rotation", "contact_unauthorised")
        f.assert_network(mark, count=1, grant_id=grant["grant_id"])
        mark = f.observer.mark()
        f.accepted(f.direct("rotated-new", "new message selects rotated grant"))
        f.assert_network(mark, count=1, grant_id=rotated["grant_id"])
        f.expect_message(f.poll(), "new message selects rotated grant")
        f.check("rotation_changes_only_new_ids_and_never_falls_back")
        return f.checks


def shared_proof(binary, mcp_binary, source_commit):
    return mode_proof(binary, mcp_binary, source_commit, True) + mode_proof(binary, mcp_binary, source_commit, False)


if __name__ == "__main__":
    sys.exit(helpers["entrypoint"](shared_only=True))
