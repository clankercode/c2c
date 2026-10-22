# Recipient contact grants: tested client path and Hermes routing limits

## Follow-up integration

B369/B370 supersede this draft's explicit-only limitation. The draft was reused
in `fix/p9-contact-integration`; current working changes add protected grant
selection, shared CLI/MCP/outbox sends and independent explicit HTTP permissions.
The account below describes the original draft, not final validation or install
status. Exact-source buildbox and NAS/two-host receipts remain required.

## Original result

`c2c relay contact issue/list/revoke` existed but no shipping CLI command consumed a grant. Ordinary `relay dm send` and the broker connector still use `/send`, which intentionally refuses private recipients. This branch adds **explicit** `relay contact deliver`, not transparent grant lookup or a public-default change.

An independent blocker applies to `http://c2c.lan:30434`: `/contact/v1/deliver` requires a token-configured relay and confidential transport. Signed requests alone do not suffice. Use native TLS, or a genuine TLS reverse proxy with `C2C_RELAY_TRUST_FORWARDED_PROTO=1` only behind a proxy that strips/replaces forwarded headers and prevents direct untrusted access. Never spoof `X-Forwarded-Proto` to bypass this check. The new client refuses non-HTTPS URLs.

## Tested commands

Build in this worktree:

```sh
scripts/dune-build-locked.sh build ./ocaml/cli/c2c.exe ./ocaml/test/test_relay_contact_delivery_handlers.exe ./ocaml/test/test_relay_contact_grants.exe
python3 scripts/test-contact-deliver-cli.py _build/default/ocaml/cli/c2c.exe
_build/default/ocaml/test/test_relay_contact_delivery_handlers.exe
_build/default/ocaml/test/test_relay_contact_grants.exe
```

The integration script creates isolated identities, an ephemeral SQLite relay with real TLS and token file, registers three aliases with signed proofs, issues a grant through the live DB, sends successfully, retries the same message id without duplicate delivery, rejects a different sender, refuses HTTP, polls the recipient with a signed request, verifies the drained inbox is empty, rejects a world-readable grant file, and verifies revocation takes effect in the running relay. It never reads live identities or prints generated secrets.

The two existing OCaml suites passed: 37 delivery-handler cases and 36 grant cases. Build succeeded with pre-existing OCaml warnings; no full-suite or real cross-host test was performed.

## Deployment recipe (operator/parent only; not executed on NAS)

After choosing distinct, authorized aliases and public keys, register each sender/recipient using that host's existing identity and the intended lease keys. Do not default-register an alias already owned by a connector: that moves its lease. Either allow the connector to register it or supply its exact `--node-id` and `--session-id` pair.

On the relay host, using the actual persist directory (SQLite backend only):

```sh
umask 077
c2c relay contact issue --persist-dir "$RELAY_PERSIST_DIR" \
  --recipient-pk "$RECIPIENT_PUBLIC_KEY" --sender-pk "$SENDER_PUBLIC_KEY" \
  --delivery-alias "$RECIPIENT_ALIAS" --expires-in 86400 --json > "$GRANT_FILE"
```

Transfer that file confidentially to the bound sender and retain mode 0600. It is the JSON output of `issue`, not a relay bearer token. Issue a separate opposite-direction grant for replies.

On the sender, with this branch's binary:

```sh
C2C_RELAY_IDENTITY_PATH="$SENDER_IDENTITY_PATH" \
C2C_RELAY_CA_BUNDLE="$CA_PEM" \
c2c relay contact deliver --relay-url "$HTTPS_RELAY_URL" \
  --alias "$SENDER_ALIAS" --grant-file "$GRANT_FILE" \
  --message-id "$STABLE_MESSAGE_ID" -- 'message body'
```

`C2C_RELAY_CA_BUNDLE` is optional for public/system-trusted certificates. Stable message id is required: reuse only when retrying the same message. The grant selects the destination, so this command has no recipient alias argument. It signs the exact serialized JSON using `c2c/v1/request`, HTTP POST, `/contact/v1/deliver`, SHA256(body), timestamp, and nonce. No additional room envelope or bearer authorization is required for this signed peer request; server token configuration still selects production policy. The secret never appears in argv or success output.

Receive using `relay dm peek/poll --alias "$RECIPIENT_ALIAS" --relay-url "$HTTPS_RELAY_URL"`, or the existing connector's inbound bridge. Poll follows a live connector's lease keys or accepts explicit `--node-id/--session-id`; it drains, peek does not. For custom identity paths, current `relay dm` loads `Relay_identity.load ()` rather than `load_client_identity ()`: its signed poll/send path ignores `C2C_RELAY_IDENTITY_PATH`. Use the correct `XDG_CONFIG_HOME` default identity location until that separate gap is fixed. The new deliver command honors the explicit identity override.

The connector already receives contact-admitted messages via its usual inbox bridge. Its outbound path does **not** consume grants. Normal `c2c send alias@host` therefore is not made grant-aware by this change. A future durable contact address book must bind each entry to relay URL, sender identity, target, expiry and private grant file; explicitly route to contact deliver and never fall back to `/send` after denial. Avoid claiming generic c2c tools have gained cross-host private send merely by installing the binary.

## Hermes: smallest safe explicit-target change (assessment, not implemented)

The existing Python plugin is process-global: one alias, session id, environment and watcher. It calls `ctx.inject_message(body, role="user")` without a target. NAS Hermes v0.22.2 was verified by the coordinating parent to require `session_key=...` for non-classic CLI delivery, plus `plugins.entries.c2c.allow_gateway_injection: true`. The native TUI accepts only an exact live session key and queues while busy. The visible database session id/title must not be assumed to be that runtime key.

A one-line injection change alone is **unsafe**: any session's start hook can rebind the global c2c identity; any other session's pre-LLM hook can drain the shared inbox first, and tools/commands currently share that identity too.

Smallest safe fixed-target mode should:

1. Read explicit operator settings once through `ctx.get_config`, e.g. `target_session_key` plus a separately verified `target_session_id`. Require nonempty exact strings; never choose most-recent/active/fallback session. No key in peer content controls routing.
2. Wrap start/pre-LLM hooks to require the exact configured session id. Reject unmatched/missing context *before* environment writes, alias registration, room joins, or inbox reads. Keep one immutable session-bound identity and isolate subprocess env rather than mutating process-wide env.
3. Route the watcher to `ctx.inject_message(body, role="user", session_key=target_key)`. A `False` result or exception must preserve the queue; never retry keyless or select another session.
4. Scope every LLM tool and slash command to the same session, rejecting unmatched/missing invocation identity before touching the broker. A configured fixed target must not expose its mailbox to unrelated sessions in a gateway process.
5. Retain peek → inject → drain-on-success and test failed injection, inactive target, busy queueing, unrelated hooks, unrelated tool calls and identity immutability.
6. Opt in separately with `hermes config set plugins.entries.c2c.allow_gateway_injection true`. Do not infer this from target configuration.

This is viable for one operator-selected target, not full multi-session support. Runtime compatibility of hook/tool session context must be checked against NAS v0.22.2 before implementing guards; if unavailable, disable those process-global tools/hooks in fixed-target gateway mode and use a narrowly scoped bridge instead. Existing live sessions cannot acquire the plugin by copying files: a supported plugin reload is needed, or explicit user-approved restart/resume. Do not restart the named live session just to make a connectivity claim.

## Fastest HTTP-only alternative

An explicitly created **private room with signed owner invitation of the other identity** can provide a shared mailbox without a DM grant. Use `relay rooms join --visibility private`, `invite`, `join`, signed `send`, and signed `history`. Do not use `unlisted`: it permits open joins and is not invite-gated. This is room-based messaging, not private DMs, and does not fix existing-session wake. HTTP still exposes message content on the wire even though signatures authenticate requests. It must be reported transparently and should not be described as equivalent confidentiality. No live room was created in this investigation.
