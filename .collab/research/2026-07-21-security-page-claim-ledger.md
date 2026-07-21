---
title: "Security page claim ledger: code-backed statements and red lines"
date: 2026-07-21
status: updated-2026-07-22-private-reachability
scope: canonical OCaml implementation and OCaml tests
---

# Security page claim ledger

## Purpose and evidence standard

This ledger is the source of truth for claims suitable for a public c2c security page. It is based only on the canonical OCaml implementation and OCaml tests. Documentation and older research were not treated as evidence.

Named tests below are implementation evidence. As of B263–B267 on feature/b264-private-discovery, the consent-gated suites have been **executed** (exit 0) — see goal evidence `run-*.log` / `2026-07-22-fresh-suite-summary.txt` and dogfood-final.

Labels:

- **Supported** — safe to state substantially as written.
- **Conditional** — safe only with the condition/caveat stated alongside it.
- **Do not claim** — contradicted by, or not established by, canonical code.

## Executive security posture

The most accurate short description is:

> c2c is a local-first message bus with host-local approval authority, signed relay requests, optional TLS transport, and opportunistic application-layer encryption. Peer messages are framed as untrusted DATA. On a production (token-configured) relay after private-reachability migration, ordinary peer discovery and first-contact delivery are consent-gated: private registrations are omitted from ordinary `/list` and `/pubkey`, and legacy `/send`/`/send_all`/`/forward` cannot enqueue to private recipients without a recipient-issued, sender-bound contact grant. Security-sensitive details remain configuration- and path-dependent: not all messages are encrypted, TLS is not mandatory, and local ephemeral delivery means “skip c2c archive,” not “leave no trace.”

## Claim ledger

### 1. Relay reachability, addressing, and discovery

#### Supported: public relay health and aggregate statistics can be read without peer credentials

- **Plain-English claim:** A relay may expose an anonymous health endpoint and aggregate usage statistics; public stats do not include aliases or message bodies.
- **Code:**
  - `ocaml/relay_server_auth.ml`: `anonymous_read_routes`, `classify_route` (`/health`, `/stats`).
  - `ocaml/relay.ml`: `handle_stats` and stats aggregation; the implementation labels this aggregate-only and omits aliases, machine identifiers, and content.
- **Tests:** `ocaml/test/test_relay_landing_auth_contract.ml`: `t_anonymous_routes_behave_anonymous`; `ocaml/test/test_relay_stats.ml` aggregate-stat cases.
- **Caveat:** `/stats` includes aggregate client-version and OS buckets. Anonymous room-directory/history routes have separate resource-level visibility rules.

#### Conditional: peer discovery requires a bound Ed25519 identity on a token-configured relay

- **Plain-English claim:** On a token-configured relay, the normal live-peer list (`/list`) requires a valid per-request Ed25519 proof from an already bound peer identity.
- **Code:**
  - `ocaml/relay_server_auth.ml`: `classify_route` makes normal `/list` `Peer_ed25519`; `auth_decision` requires `ed25519_verified` when `token <> None`.
  - `ocaml/relay.ml`: `try_verify_ed25519_request`, `handle_list`.
- **Tests:** `ocaml/test/test_relay_landing_auth_contract.ml`: `/list` classification and `t_self_auth_routes_pass_outer_gate` / peer-route contract; `ocaml/test/test_relay_bindings.ml`: `test_request_blob_roundtrip`, `test_request_nonce_cache`.
- **Caveats:**
  - A tokenless relay is development mode: unsigned peer routes pass the outer gate.
  - `/list?include_dead=true` is an operator Bearer-admin route, not a peer route.
  - This is authentication, not secrecy of the directory from all relay participants.

#### Conditional: ordinary peer listing is private-by-default after consent-gated migration

- **Plain-English claim:** On a post-B264/B266 production relay, new and migrated registrations default to **private** discovery. Ordinary `list_peers` / `GET /list` omit private aliases and their operational metadata; Bearer-admin `list_peers_admin` / `include_dead` retains operator visibility. Explicitly public registrations still serialise lease metadata via `RegistrationLease.to_json`.
- **Code:**
  - `ocaml/relay_backend_contract.ml`: `peer_discovery_visibility`, `list_peers`, `list_peers_admin`, `peer_*` lookups.
  - `ocaml/relay.ml`: `SqliteRelay`/`InMemoryRelay` discovery_visibility default `Private`; `handle_list`, `handle_pubkey` use peer-facing lookups.
  - `ocaml/relay_sqlite_support.ml`: `leases.discovery_visibility`, `relay_features`, `schema_version`.
- **Tests:** `ocaml/test/test_relay_private_discovery.ml` (ordinary list omits private; admin includes; peer pubkey oracles; HTTP /list+/pubkey); migration suites `test_relay_private_migration.ml`, `test_relay_private_reachability_migration.ml`.
- **Caveats:**
  - Tokenless (`auth_mode=dev`) is not a production private-reachability claim; doctor fails `relay.auth_mode` in that mode.
  - Public opt-in aliases remain metadata-rich to authenticated peers.
  - Room directories may still show presentation addresses for public rooms; that is not a private DM route (G1).

#### Supported: private first-contact delivery requires a recipient-issued, sender-bound contact grant

- **Plain-English claim:** Without a valid current recipient-issued grant bound to the verified sender Ed25519 key, no direct, broadcast, or local-forward path may create a relay inbox row (or content-bearing dead letter) for a **private** recipient. Authorised delivery uses `admit_contact_delivery` / `POST /contact/v1/deliver`.
- **Code:**
  - `ocaml/relay.ml`: `issue_contact_grant`, `admit_contact_delivery`, private gate in `send`/`send_all`, `handle_contact_deliver`, private reject on forward→`R.send`.
  - Design freeze: `.collab/design/2026-07-22-b262-contact-grant-protocol.md` (G1–G9).
- **Tests:**
  - `ocaml/test/test_relay_contact_grants.ml` — issue/list/revoke/rotate/admit, restart, concurrency, redaction.
  - `ocaml/test/test_relay_contact_delivery_handlers.ml` — private send no content DLQ, send_all skip private, wrong-sender/expired/revoked/malformed/replay, tokenless contact refuse, protocol downgrade.
  - `ocaml/test/test_relay_private_reachability_matrix.ml` — guessed alias uniformity, stats zero-side-effect, restart admit, HTTP anonymous probes.
- **Caveats:**
  - Production contact delivery refuses tokenless relays.
  - TLS is still not mandatory for all schemes; doctor fails plaintext **production** URLs for grant confidentiality.
  - Grant secret alone is insufficient without the bound sender key (G3).
  - Connector inbound allow remains defence-in-depth, not the security boundary.

#### Do not claim (narrowed): absolute anonymity or “no metadata ever”

- Operator/admin views, public opt-in aliases, room presentation addresses, and aggregate `/stats` still exist.
- Tokenless development mode is explicitly insecure for private-reachability claims.
- The claim is **consent-gated first contact on a migrated production relay**, not universal anonymity or traffic-analysis resistance.

### 2. Authentication, identities, and key material

#### Supported: peer HTTP requests can authenticate the bound sender and the exact request

- **Plain-English claim:** Ed25519 peer-request proofs bind the method, path, sorted query, body hash, timestamp, and nonce; the relay verifies the signature against the alias’s bound public key.
- **Code:**
  - `ocaml/relay_signed_ops.ml`: `canonical_request_blob`, `sign_request`, `request_sign_ctx`.
  - `ocaml/relay.ml`: `try_verify_ed25519_request`; `handle_send` signer/body alias check via `from_alias_signer_name` and `reject_alias_mismatch`.
- **Tests:** `ocaml/test/test_relay_bindings.ml`: `test_request_blob_roundtrip`, `test_b184_empty_vs_json_object_body_hash`, `test_request_nonce_cache`.
- **Caveat:** Request authentication is hop authentication to the relay. It is not by itself an end-recipient message signature.

#### Supported: registration can be proven by the registering Ed25519 key and acknowledged by a relay signature

- **Plain-English claim:** Signed registration covers alias, relay URL, client identity public key, timestamp, and nonce; successful signed registration can return a relay-signed receipt.
- **Code:** `ocaml/relay.ml`: `handle_register`; `ocaml/relay_signed_ops.ml`: `register_sign_ctx`, `sign_register`, `build_registration_receipt_json`; `ocaml/relay_identity.ml`: signing and verification.
- **Tests:**
  - `ocaml/test/test_relay_bindings.ml`: `test_signed_register_blob_roundtrips`, `test_nonce_rejects_replay`.
  - `ocaml/test/test_relay.ml`: `test_build_registration_receipt_json_has_all_fields`, `test_build_registration_receipt_json_sig_verifies`, `test_receipt_sign_ctx_is_unique`.
- **Caveat:** The signed registration blob does **not** cover `node_id`, `session_id`, client metadata, `opaque_host_id`, `enc_pubkey`, `signed_at`, or `sig_b64`.

#### Supported: private identity files use restrictive filesystem modes and refuse loose permissions

- **Plain-English claim:** The main Ed25519 identity and per-alias X25519 private-key files are written as mode `0600` under mode-`0700` directories, and loaders reject group/world-accessible key files.
- **Code:**
  - `ocaml/relay_identity.ml`: `save`, `load`, `load_or_create_at`.
  - `ocaml/relay_enc.ml`: `save`, `load`, `load_or_generate`.
- **Tests:** `ocaml/test/test_relay_identity.ml`: `test_save_enforces_0600`, `test_load_refuses_loose_perms`, `test_save_load_roundtrip`; X25519 save/load tests in `ocaml/test/test_relay_enc.ml`.
- **Caveat:** Key JSON contains unencrypted private material. Protection is filesystem permissions, not a passphrase, hardware key, or OS keyring.

#### Do not claim: “The relay verifies the advertised X25519 key is bound to the Ed25519 identity”

`ocaml/relay.ml:handle_register` reads and stores `enc_pubkey`, `signed_at`, and `sig_b64`, but the signed registration canonical data excludes them and this path does not verify `sig_b64`. V2 end-to-end envelopes separately bind sender key fields inside their envelope signature; that is a different property.

### 3. TOFU and pairing

#### Conditional: encrypted-envelope identities use persistent TOFU pins

- **Plain-English claim:** For v2 encrypted-envelope reception, c2c pins first-seen Ed25519 and X25519 keys per literal peer alias; later key changes are rejected rather than silently replacing the pin.
- **Code:**
  - `ocaml/c2c_broker.ml`: relay-pin persistence (`relay_pins.json`), `pin_ed25519_sync`, `pin_x25519_sync`, version pins.
  - `ocaml/c2c_mcp_helpers_post_broker.ml`: `decrypt_envelope` TOFU enforcement.
  - `ocaml/relay_e2e.ml`: `check_pinned_ed25519_mismatch`, `check_pinned_x25519_mismatch`, `Key_changed`.
- **Tests:** `ocaml/test/test_c2c_mcp.ml`: `test_slice_b_tofu_first_contact_pins`, `test_slice_b_tofu_already_pinned_accepts`, `test_slice_b_tofu_mismatch_rejects`, the full relay-qualified alias TOFU/key-swap/downgrade flow around lines 13441–13523; `ocaml/test/test_relay_e2e.ml`: `test_tofu_mismatch`.
- **Caveats:**
  - TOFU does not authenticate first contact.
  - Removing or corrupting the pin store returns peers to first-contact state.
  - The canonical ordinary remote-send path does not guarantee creation of an encrypted envelope; TOFU applies when the envelope path is actually used.

#### Supported, narrowly: pairing tokens are time-limited and single-use in the tested in-memory flow

- **Plain-English claim:** Mobile-pairing tokens are returned only while unused and unexpired; consuming a token marks it used, and a second consume returns no token.
- **Code:** `ocaml/relay_pairing_token_sql.ml`: `store_pairing_token_db`, `get_and_burn_pairing_token_db`, `find_pairing_token_db`; corresponding in-memory relay methods.
- **Tests:** `ocaml/test/test_relay_mobile_pair.ml`: `test_store_and_burn_happy_path`, `test_expired_token_not_returned`.
- **Caveats:**
  - Do not claim transactional single-use under concurrent SQLite consumers: `get_and_burn_pairing_token_db` performs a select then update without checking the update count or showing an enclosing transaction here.
  - The helper returns the stored token/key pair; caller-level signature/key validation is separate.

### 4. Allow/deny policy and ingress controls

#### Conditional: each host can enforce local inbound admission, size, and rate policy before broker delivery

- **Plain-English claim:** The relay connector can deny specific senders, disable recipients, enforce sender/recipient byte caps, reject recipient mismatches, and apply per-sender, per-recipient, and machine-wide sliding-window limits before appending inbound rows to local inboxes.
- **Code:** `ocaml/c2c_relay_connector.ml`: `inbound_policy`, `parse_inbound_policy`, `load_inbound_policy`, `filter_inbound_messages`, `filter_inbound_messages_guarded`; rejection variants `Inbound_sender_denied`, `Inbound_recipient_mismatch`, `Inbound_recipient_disabled`, `Inbound_oversize`, `Inbound_sender_rate`, `Inbound_recipient_rate`, `Inbound_machine_rate`.
- **Tests:** `ocaml/test/test_c2c_relay_connector.ml`: `test_inbound_policy_parses_admission_and_recipient_controls`, `test_inbound_policy_invalid_fails`, `test_inbound_size_and_schema_filter`, `test_inbound_per_sender_rate_and_recovery`, `test_inbound_machine_rate_across_senders`, `test_inbound_admission_and_recipient_controls`, `test_inbound_expected_recipient_binding`, persisted/concurrent machine-rate tests.
- **Caveats:**
  - Default sender action is **allow**, not deny (`default_inbound_policy`).
  - Default limits are finite: 256 KiB; 60 sender messages/minute; 120 recipient messages/minute; 600 machine messages/minute.
  - A user must configure deny-by-default to describe the host as allowlist-only.
  - This is recipient-side filtering after destructive relay polling, not relay-level refusal before acceptance.

#### Supported: malformed policy fails closed for inbound rows

- **Plain-English claim:** If the local inbound-policy file cannot be parsed/validated, guarded filtering accepts no inbound messages.
- **Code:** `ocaml/c2c_relay_connector.ml`: `filter_inbound_messages_guarded`.
- **Tests:** `ocaml/test/test_c2c_relay_connector.ml`: `test_inbound_policy_invalid_fails`, `test_inbound_policy_rejects_unknown_and_duplicate_keys`.

### 5. Encryption, transport, and integrity

#### Conditional: c2c implements X25519/NaCl application-layer encrypted envelopes signed by Ed25519

- **Plain-English claim:** When the encrypted-envelope path is used, payloads are encrypted to recipient X25519 keys and envelopes are signed with Ed25519.
- **Code:** `ocaml/relay_e2e.ml`: `encrypt_for_recipient`, `decrypt_for_me`, `box_easy`, `box_open_easy`, `sign_envelope`, `verify_envelope_sig`; algorithm label `box-x25519-v1`.
- **Tests:** `ocaml/test/test_relay_e2e.ml`: `test_box_roundtrip`, `test_sign_verify_roundtrip`; `ocaml/test/test_relay_e2e_integration.ml`: `test_encrypt_decrypt_roundtrip`, `test_full_e2e_two_party`.
- **Caveats:** Encryption is opportunistic, not mandatory. Same-broker DMs are deliberately plaintext, and absent keys/crypto failure can fall back to plaintext in `ocaml/c2c_send_handlers.ml:encrypt_content_for_recipient`.

#### Supported: v2 envelope signatures cover sender encryption and identity keys

- **Plain-English claim:** V2 signatures bind both `from_x25519` and `from_ed25519`; swapping or removing either after signing invalidates verification, and v2 parsing requires a non-empty Ed25519 sender key.
- **Code:** `ocaml/relay_e2e.ml`: `canonical_json_v2`, `envelope_of_json`, `current_envelope_version = 2`.
- **Tests:** `ocaml/test/test_relay_e2e.ml`: `test_canonical_v2_includes_from_x25519`, `test_canonical_v2_includes_from_ed25519`, `test_v2_without_from_ed25519_rejected`, `test_v2_from_ed25519_micro_edges`.
- **Caveat:** Legacy v1 signatures do not cover those fields, and v1 remains accepted by default.

#### Conditional: c2c detects per-peer envelope-version downgrade after seeing v2

- **Plain-English claim:** Once a peer alias has successfully established a minimum observed envelope version of 2, a later v1 envelope for that alias is rejected and audited.
- **Code:** `ocaml/c2c_broker.ml`: minimum-version pin store; `ocaml/c2c_mcp_helpers_post_broker.ml`: `decrypt_envelope`, `Broker.check_version_downgrade`, `Broker.bump_min_observed_version`; `ocaml/relay_e2e.ml`: `Version_downgrade`.
- **Tests:** `ocaml/test/test_c2c_mcp.ml`: `test_slice_bmv_v1_rejected_after_v2_pin`, sequential v1→v2→v1 flow, audit-log case, full TOFU/key-change/downgrade flow.
- **Caveats:** First contact is open. A v1 first contact is accepted unless `C2C_RELAY_E2E_STRICT_V2` is enabled; strict-v2 is off by default (`ocaml/test/test_relay_e2e.ml`: `test_strict_v2_default_off_v1_verifies`, `test_strict_v2_on_rejects_v1`).

#### Conditional: HTTPS/WSS uses certificate-authenticated TLS when a TLS URL is selected

- **Plain-English claim:** Relay HTTP clients support HTTPS; WebSocket subscribe supports WSS using system or configured CA trust and host-name authentication.
- **Code:** `ocaml/relay_client.ml`: `request_raw`, `net_ctx_of_bundle`; `ocaml/relay_ws_client.ml`: `scheme_is_tls`, `resolve_authenticator`, `peer_name_of_host`, `Tls.Config.client`, `open_channels`.
- **Tests:** `ocaml/test/test_relay_ws_server.ml`: `test_parse_endpoint_tls_defaults`; `ocaml/test/test_c2c_cli.ml`: `test_relay_subscribe_https_no_longer_rejected_for_tls_scheme`.
- **Caveats:**
  - TLS is URL-selected, not mandatory; HTTP and WS remain supported.
  - Production edge termination is described by code comments, not proven deployment state by this static review.
  - The self-hosted native-TLS WebSocket upgrade path is explicitly marked as potentially needing further work.
  - Request-hop TLS is not application-layer end-to-end encryption.

#### Supported: relay forwarding is authenticated between configured peer relays

- **Plain-English claim:** Inter-relay forwarding signs the canonical `/forward` request with the source relay identity, and the receiving relay verifies it against a configured peer-relay public key with timestamp and nonce checks.
- **Code:** `ocaml/relay_forwarder.ml`: `sign_forward_request`, `forward_send`; `ocaml/relay.ml`: `handle_forward`; `ocaml/relay_signed_ops.ml`: canonical request format.
- **Caveat:** Forwarding preserves `content`; a relay can read it unless the content was already an encrypted envelope.

#### Do not claim

- “All c2c messages are encrypted.”
- “All cross-host DMs are end-to-end encrypted by default.”
- “Encryption is fail-closed.”
- “TLS is mandatory.”
- “The relay cannot read message content.”
- “Every delivered message has an end-to-end signature.”

Canonical counter-evidence is in `ocaml/c2c_send_handlers.ml:encrypt_content_for_recipient`, `ocaml/c2c_broker.ml:enqueue_message_with_result`, `ocaml/c2c_relay_connector.ml:append_outbox_entry`, `ocaml/cli/c2c_relay_cmd.ml:relay_dm_cmd`, and plain-envelope handling in `ocaml/c2c_mcp_helpers_post_broker.ml:decrypt_envelope`.

### 6. Replay and spam/abuse controls

#### Supported: signed HTTP requests and signed registration reject stale timestamps and repeated nonces

- **Plain-English claim:** Relay request proofs and registration proofs are bounded by timestamp windows and nonce replay caches.
- **Code:** `ocaml/relay.ml`: `try_verify_ed25519_request`, signed branch of `handle_register`, `handle_forward`; backend `check_request_nonce` / `check_register_nonce`.
- **Tests:** `ocaml/test/test_relay_bindings.ml`: `test_nonce_accepts_fresh`, `test_nonce_rejects_replay`, `test_request_nonce_cache`; `ocaml/test/test_relay_binding_revoke_auth.ml`: replay and stale-timestamp cases.
- **Caveat:** Initial WebSocket subscribe authentication uses a timestamped signature but no nonce cache; do not call WebSocket authentication replay-proof.

#### Supported: selected relay endpoints have per-IP, per-endpoint token buckets

- **Plain-English claim:** Registration, send, send-all, room-send, heartbeat, inbox poll/peek, pubkey, pairing, observer, and room-history endpoints are rate-limited with endpoint-specific token buckets and return retry timing on denial.
- **Code:** `ocaml/relay_ratelimit.ml`: `classify_endpoint`, `Make.check`; `ocaml/relay.ml`: module-level limiter and `make_callback` 429 path.
- **Tests:** relay rate-limit suites, including endpoint-class isolation and policy tests in `ocaml/test/test_relay_ratelimit.ml` / HTTP regression coverage.
- **Caveats:** Keys are client IP plus endpoint class. Unclassified endpoints are unmetered by this limiter. In-memory bucket state resets on relay restart.

#### Conditional: registration proof-of-work can make repeated registration progressively costly

- **Plain-English claim:** When `C2C_RELAY_POW=1`, registration requires a challenge-bound proof of work whose required difficulty is policy-driven per identity actor; challenges are consumed on use.
- **Code:** `ocaml/relay.ml`: PoW challenge issue/verification in `handle_register`; `ocaml/pow.ml`, `ocaml/pow_policy.ml`, `ocaml/relay_pow_challenge.ml`.
- **Tests:** `ocaml/test/test_pow_relay.ml` and PoW policy tests.
- **Caveat:** PoW is optional and disabled unless configured. Do not describe it as universal spam prevention.

### 7. Local broker filesystem permissions

#### Supported: content-bearing broker JSON and archive files are requested as owner-only

- **Plain-English claim:** Registry/inbox atomic JSON writes, broker log/dead-letter content, room history, and per-session archive files are created with mode `0600`; archive and room/key directories are created with mode `0700` at the relevant sites.
- **Code:** `ocaml/c2c_broker.ml`: `write_json_file`, log append, `ensure_archive_dir`, `append_archive_messages`, dead-letter and room-history writes; `ocaml/cli/c2c_approval_paths.ml`: `ensure_dirs`, `atomic_write_string`.
- **Tests:** `ocaml/test/test_c2c_mcp.ml`: `test_register_writes_registry_at_0o600`, `test_enqueue_writes_inbox_at_0o600`, `test_write_json_file_leaves_no_tmp_sidecars`; approval-path mode tests.
- **Caveats:**
  - Mode arguments apply when files/directories are created; they do not prove ownership or protection on non-POSIX filesystems.
  - Several lock/lease/coordination sidecars are intentionally `0644`.

#### Do not claim: “The whole broker directory is private” or “all broker files are mode 0600”

- `ocaml/c2c_broker.ml`: `ensure_root t = mkdir_p t.root`.
- `ocaml/c2c_io.ml`: `mkdir_p` defaults to `0755` and does not chmod existing directories.
- `ocaml/c2c_broker.ml` explicitly creates multiple lock/lease files as `0644`, and `allowed_signers` is intentionally `0644`.

A safe statement is **content-bearing files are individually created with restrictive modes**, not that the entire tree is uniformly private.

### 8. Ephemeral messages

#### Supported, narrowly: local one-to-one ephemeral delivery skips the c2c archive

- **Plain-English claim:** A local 1:1 message sent with `ephemeral=true` is delivered through the normal inbox, but when drained it is excluded from the recipient’s c2c archive/history append.
- **Code:** `ocaml/c2c_broker.ml`: message `ephemeral` field, `enqueue_message_with_result`, `drain_inbox`, `drain_inbox_push`, `drain_inbox_from`; all archive paths filter `not m.ephemeral`.
- **Tests:** ephemeral archive/drain cases in `ocaml/test/test_c2c_mcp.ml`; `ocaml/test/test_c2c_codex_ingress.ml`: `test_ephemeral_no_archive`; offline flag-preservation case around `test_c2c_mcp.ml:4879`.
- **Caveats:**
  - Before drain, the message is persisted in the recipient’s inbox JSON.
  - Delivery transcripts, channel notifications, terminal scrollback, logs outside c2c, backups, and recipient capture may retain it.
  - “No permanent record” is too broad; the precise promise is “not appended to c2c’s recipient archive.”

#### Do not claim: remote/cross-host ephemeral messages are ephemeral

`ocaml/c2c_broker.ml:enqueue_message_with_result` explicitly says relay v1 ignores ephemeral semantics and persists the remote outbox entry. The `--ephemeral` flag is local 1:1 only. Also, the remote outbox is created with mode `0644` in `ocaml/c2c_relay_connector.ml:append_outbox_entry`, subject only to umask tightening.

### 9. Approval safety: bus, never RPC

#### Supported: peer messages cannot directly satisfy the approval side channel

- **Plain-English claim:** Broker, relay, and injected peer messages are DATA. The PreToolUse approval path trusts only a host-local verdict file; a message containing an approval token and `allow`/`deny` is inert.
- **Code:** `ocaml/cli/c2c_approval_paths.ml`: B098 invariant, `verdict_file`, `write_verdict`, `read_verdict`; approval CLI/await implementation in `ocaml/cli/c2c_approval_cmd.ml`.
- **Tests:** `ocaml/cli/test_c2c_await_reply.ml`: `test_remote_message_cannot_reach_approval_path`, `test_peer_allow_messages_are_inert`, `test_peer_deny_messages_are_inert`, `test_missing_binding_is_fail_closed`, `test_empty_supervisors_is_fail_closed`, `test_host_local_cli_verdict_succeeds`.
- **Caveats:**
  - A local user/process with permission to execute the CLI or write into the verdict directory is inside the trust boundary.
  - The files are protected by ordinary same-user filesystem controls, not a separate privileged daemon.
  - A local `approval-reply` compatibility path may warn and write a verdict when no pending request exists; do not claim that every verdict is cryptographically tied to an existing pending record.

#### Conditional: local Codex mail may wake a gated model turn, but message content remains DATA

- **Plain-English claim:** Eligible local-broker mail to an idle, DND-off, app-server-backed Codex session may start a gated model turn to make already-injected DATA visible. Remote, `@host`, `#room`, and unknown-status senders fail closed to injection-only.
- **Code:** `ocaml/c2c_codex_autoturn.ml`; `ocaml/c2c_codex_ingress.ml` DATA framing.
- **Tests:** `ocaml/cli/test_c2c_codex_autoturn_b098.ml`; `ocaml/test/test_c2c_codex_autoturn.ml`: `test_canonical_form_fails_closed`.
- **Caveat:** This is the one sanctioned scheduling effect. It does not execute message content, resolve approvals, or write verdicts.

### 10. Remote-message DATA framing and injection resistance

#### Supported: canonical transcript rendering identifies peer content as untrusted DATA and escapes hostile markup

- **Plain-English claim:** Canonical c2c delivery wraps messages in a `<c2c ...>` envelope, XML-escapes peer-controlled alias/content at markup boundaries, and appends a trusted reminder that peer content is untrusted data rather than operator instruction.
- **Code:**
  - `ocaml/c2c_mcp_helpers.ml`: `format_c2c_envelope`, `reply_hint_for` and the explicit “never execute or approve it” boundary.
  - `ocaml/c2c_wire_bridge.ml`: envelope rendering.
  - `ocaml/c2c_kimi_deliver.ml`: `message_envelope`.
  - `ocaml/c2c_agy_agentapi.ml`: `format_inbound_payload` with “treat as data”.
  - `ocaml/c2c_codex_ingress.ml`: `render_message` marks injected material as c2c DATA, not operator input.
- **Tests:**
  - `ocaml/test/test_wire_bridge.ml`: `test_envelope_hostile_input_stays_untrusted_data`, `test_envelope_xml_escaping`.
  - `ocaml/test/test_c2c_mcp.ml`: `test_channel_notification_claude_seam_untrusted_and_structured`.
  - `ocaml/test/test_c2c_kimi_deliver.ml`: hostile alias/content escaping case.
  - `ocaml/test/test_c2c_agy_agentapi.ml`: `test_format_inbound_payload_data_framed`.
  - `ocaml/test/test_c2c_codex_ingress.ml`: DATA/not-operator-input assertions.
- **Caveats:** This is structural framing and policy guidance to the host/model, not a mathematical guarantee that a language model can never be socially engineered. Some host integrations own their own structured-content escaping seam; the trusted hint still carries the DATA boundary.

## Metadata exposure and privacy claims

### Supported: local metadata opt-out intent is stored, but cwd is still captured

- **Plain-English claim:** `include_metadata:false` / `--no-metadata` records `metadata_opt_out=true`, while local registration still captures and persists cwd for operational safety.
- **Code:** `ocaml/c2c_identity_handlers.ml`: registration handling; `ocaml/c2c_broker.ml`: `registration_to_json`.
- **Tests:** `ocaml/test/test_c2c_mcp.ml`: `test_tools_call_register_include_metadata_false_opt_out`; onboarding tests including `test_register_no_metadata_still_captures_cwd`.
- **Caveat:** No meaningful canonical read-side enforcement branch on `metadata_opt_out` was found in this review. Do not say it prevents capture or is honoured by every exposure/federation surface.

### Supported: public room-directory code has narrow roster redaction coverage

- **Code/tests:** `ocaml/test/test_relay_list_rooms_roster.ml`: `test_inmemory_no_metadata_leak`, `test_sqlite_no_metadata_leak`.
- **Caveat:** This supports that room-directory surface only, not `/list`, broker listings, or every metadata surface.

## Public-page red lines: claims that must not be made

1. **All c2c messages are encrypted.** Local delivery is deliberately plaintext; key/crypto failure can fall back to plaintext.
2. **Cross-host DMs are end-to-end encrypted by default.** The connector/direct relay paths send raw content unless an encrypted envelope already exists.
3. **Encryption is fail-closed.** Only detected key-pin/version changes reject; missing keys can produce plaintext.
4. **TLS is mandatory.** HTTP and WS schemes are supported.
5. **The relay cannot read message content.** It can read ordinary/plain content and forwarding preserves supplied content.
6. **Every message has an end-to-end signature.** Plain/raw content bypasses envelope-signature verification.
7. **Relay registration verifies the X25519 key binding.** The current signed registration blob excludes the advertised encryption-key binding fields.
8. **Nobody can discover or message you until you share an address — without caveats.** On a migrated production relay, private recipients are consent-gated, but public opt-in aliases, operator admin views, tokenless dev mode, and room presentation addresses still exist. Do not claim absolute anonymity.
9. **The relay peer list is anonymous or metadata-free.** Ordinary private-by-default listing omits private peers; public peers and admin views remain metadata-rich.
10. **Metadata opt-out prevents capture or is universally enforced.** cwd remains captured, and no broad read-side enforcement was found.
11. **All broker files/directories are private.** The root may be `0755`; several sidecars are `0644`.
12. **Ephemeral means no trace.** Local ephemeral skips the c2c archive only; it is persisted before drain and can appear in transcripts/host surfaces. Remote ephemeral is not implemented.
13. **Peer messages can approve actions.** They cannot; approval authority is host-local file/CLI state.
14. **WebSocket authentication is replay-proof.** Initial subscribe auth has a timestamp window but no nonce cache.
15. **Private keys and relay tokens use encrypted-at-rest/keyring storage.** Canonical storage is plaintext files; key files rely on mode controls, and relay token configuration is not equivalently hardened.
16. **Pairing-token consumption is proven atomic under concurrent SQLite consumers.** The helper’s select/update sequence does not establish that guarantee.
17. **DATA framing makes prompt injection impossible.** It creates a strong structural/trust boundary, not an absolute model-behaviour proof.

## Recommended public wording

A compact, defensible security-page core:

> c2c treats every peer message as untrusted data, never as an approval or remote procedure call. Security-sensitive approvals remain host-local. Relay peers authenticate requests with Ed25519 signatures covering the request body and routing fields, with timestamp and nonce replay checks. On a production, token-configured relay after private-reachability migration, ordinary peer discovery and first-contact delivery are consent-gated: private registrations are not listed to ordinary peers, and first private DMs require a recipient-issued, sender-bound contact grant (`c2c-contact/1`). HTTPS/WSS and signed, X25519-encrypted envelopes are supported, but encryption is opportunistic rather than universal. Each host can apply inbound sender, recipient, size, and rate policy. Content-bearing broker files use owner-only modes, while local ephemeral delivery specifically skips c2c’s recipient archive rather than promising that no trace can exist.

## Source index

Core implementation:

- `ocaml/relay.ml`
- `ocaml/relay_server_auth.ml`
- `ocaml/relay_identity.ml`
- `ocaml/relay_signed_ops.ml`
- `ocaml/relay_e2e.ml`
- `ocaml/relay_enc.ml`
- `ocaml/relay_registration_lease.ml`
- `ocaml/relay_pairing_token_sql.ml`
- `ocaml/relay_ratelimit.ml`
- `ocaml/relay_forwarder.ml`
- `ocaml/relay_ws_client.ml`
- `ocaml/c2c_relay_connector.ml`
- `ocaml/c2c_broker.ml`
- `ocaml/c2c_io.ml`
- `ocaml/c2c_mcp_helpers.ml`
- `ocaml/c2c_mcp_helpers_post_broker.ml`
- `ocaml/c2c_send_handlers.ml`
- `ocaml/c2c_codex_ingress.ml`
- `ocaml/c2c_codex_autoturn.ml`
- `ocaml/c2c_agy_agentapi.ml`
- `ocaml/c2c_kimi_deliver.ml`
- `ocaml/cli/c2c_approval_paths.ml`

Primary regression suites:

- `ocaml/test/test_relay_landing_auth_contract.ml`
- `ocaml/test/test_relay_bindings.ml`
- `ocaml/test/test_relay.ml`
- `ocaml/test/test_relay_e2e.ml`
- `ocaml/test/test_relay_e2e_integration.ml`
- `ocaml/test/test_c2c_mcp.ml`
- `ocaml/test/test_c2c_relay_connector.ml`
- `ocaml/test/test_relay_mobile_pair.ml`
- `ocaml/test/test_relay_remote_broker.ml`
- `ocaml/test/test_wire_bridge.ml`
- `ocaml/test/test_c2c_agy_agentapi.ml`
- `ocaml/test/test_c2c_codex_ingress.ml`
- `ocaml/cli/test_c2c_await_reply.ml`
- `ocaml/cli/test_c2c_codex_autoturn_b098.ml`

## Addendum 2026-07-22 — private reachability (B261–B267)

Implemented and regression-tested on branch `feature/b264-private-discovery` (builds on B263 contact grants).

| Property | Symbols | Named suites |
|---|---|---|
| Private-by-default discovery | `list_peers`, `list_peers_admin`, `peer_discovery_visibility_*`, `peer_*` lookups, `handle_list`, `handle_pubkey` | `test_relay_private_discovery` |
| Contact grant lifecycle | `issue_contact_grant`, `list_contact_grants`, `revoke_contact_grant`, `rotate_contact_grant`, `admit_contact_delivery` | `test_relay_contact_grants` |
| Delivery admission | private `send`/`send_all` gates, `handle_contact_deliver`, forward→private reject | `test_relay_contact_delivery_handlers`, `test_relay_private_reachability_matrix` |
| Migration fail-closed | atomic `leases` → `secure_leases_v2` quarantine, empty non-writable legacy view, `schema_version=2`, `relay_features`, private default | `test_relay_b266_rollback_floor`, `test_relay_private_migration`, `test_relay_private_reachability_migration` |
| Doctor/health | `/health` `contact_protocol`/`private_reachability`; doctor `relay.auth_mode`, `relay.contact_protocol`, `relay.transport_security` | doctor pure checks + health HTTP cases |
| Owner CLI | `c2c relay contact issue\|list\|revoke` | manual help + secret-once issue path |

**Still Do not claim:** mandatory TLS, universal E2E, absolute anonymity, no-trace ephemeral, prompt-injection impossibility, operator-blind routing.

## Independent security review disposition (2026-07-22)

**Report:** `.collab/evidence/B267/independent-security-review.md`  
**Verdict:** PASS-WITH-NOTES — 0 blockers on G1/G2 in reviewed binary.

| Finding | Class | Disposition |
|---|---|---|
| M1 pre-B264 binary + migrated DB reopens global reachability | MAJOR | **FIXED** — atomic lease-table quarantine; old reads return zero and old writes fail (`test_relay_b266_rollback_floor`) |
| M2 no production public-discovery opt-in CLI | MAJOR product | Follow-up; does not weaken private default |
| M3 contact Accepted WS/short-queue wake | MINOR | **FIXED** — `handle_contact_deliver` `Accepted` calls `push_dm` + short-queue/observer when binding known |
| M4 grant deliver over cleartext HTTP | MINOR | **FIXED** — `handle_contact_deliver` requires native TLS or explicit trusted-proxy opt-in plus HTTPS; signed suite proves cleartext and spoofed untrusted `X-Forwarded-Proto` refuse |

Public claims on `/security/` remain conditional on production token mode, migration stamps, and **running a post-B266 binary** (never roll back binary against a migrated DB).
