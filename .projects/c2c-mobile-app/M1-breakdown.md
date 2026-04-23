# M1 — Relay-side foundation (draft)

**Status**: draft for peer review 2026-04-23. Awaiting input from galaxy-coder + jungle-coder.
**Parent spec**: [spec.md](spec.md) §7 (Milestones) — M1 = "relay-side observer WebSocket + pairing + X25519 key publication in register + short-queue".
**Scope change vs. spec v0.2**: E2E crypto is a swarm-wide protocol change, not just mobile. This breakdown includes the base layer for all peers (pubkey publication + opportunistic encrypt) so mobile ships onto a working foundation. Proposed new spec §10 tracks the rollout.

---

## Review policy (added 2026-04-23 per Max)

**Every commit touching M1 gets reviewed by coordinator1 (or a dispatched subagent) before the slice is considered landed.** This is explicit — crypto + auth + WebSocket layer is load-bearing for mobile trust model, so no silent merges.

- Implementers: after each commit on an M1 slice, DM coordinator1 with `SHA + slice-id + one-line summary`. Coordinator1 reviews against spec + slice AC and signs off (or requests changes).
- Review latency target: <1h during active swarm hours; <4h otherwise.
- If coordinator1 is offline, reviews can be delegated to a peer with explicit hand-off (DM'd to swarm-lounge).
- Merge to master is allowed pre-review (we commit fast locally), but **no push to origin** without review sign-off on every M1 commit in the batch.

## Principles

- **Backward compatible throughout M1.** Every change must keep existing agents (Claude/Codex/OpenCode/Kimi) working with zero config change. Peers without a pubkey get plaintext; peers with one get boxed.
- **Relay stays read-only for bodies.** It sees metadata + ciphertext only. Signed envelopes prove provenance.
- **Small, independent slices.** Each slice should land as its own commit with tests; nothing blocks on a long-running monolith PR.
- **OCaml-first.** All new broker/relay code lands in `ocaml/`. No Python regressions.

---

## Slices

Ordered by dependency. Parallelizable pairs flagged with `[parallel: …]`.

### S1 — X25519 keypair in `c2c register` (broker + registry)

**Owner**: galaxy-coder (claimed 2026-04-23)
**Blocks**: S3, S5, S7
**Estimate**: ~1 day

- Extend `registration` record in `c2c_registry.ml` with `enc_pubkey: string option` (base64 X25519 public key, 32 bytes).
- On `c2c register` (MCP tool + CLI), generate X25519 keypair if missing; store secret in `~/.c2c/keys/<session_id>.x25519` mode 0600; publish public in registry.
- Add `c2c whoami --show-keys` to print the session's pubkey.
- Migration: existing registrations without `enc_pubkey` remain valid; a new `c2c register --rotate-enc-key` regenerates.
- **Threat model note (I1)**: mode 0600 is sufficient vs other Unix users but not vs other processes running as the same user (including child agents). Document this in S8 runbook; OS keyring integration deferred to M3.
- Tests: alcotest roundtrip (generate → publish → load → matches), keypair persistence, absent-key backward compat.

### S2 — Signed pubkey lookup on relay

**Owner**: jungle-coder (claimed 2026-04-23)
**Blocks**: S3
**Estimate**: ~1 day
**[parallel with S1]**

- Add `GET /pubkey/<canonical_alias>` to `ocaml/relay/relay.ml`. Returns `{alias, ed25519_pubkey, x25519_pubkey, signed_at, signature}`.
- Signature = Ed25519 over `alias || ed25519_pubkey || x25519_pubkey || signed_at` by the advertising peer's Ed25519 key. Relay passes through; does not mint.
- Cache invalidation: relay refreshes from broker on miss or on push from peer's `c2c publish-keys` (new CLI command, cheap).
- Auth: unauthenticated GET (pubkeys are public); rate-limit by IP.
- Tests: relay contract test for lookup round-trip + signature verify + missing-alias 404.

### S3 — Opportunistic E2E in `c2c send` + MCP `send`

**Owner**: galaxy-coder (claimed 2026-04-23)
**Blocks**: S7 (mobile pairing relies on this working)
**BlockedBy**: S1, S2 (can stub — see below)
**Estimate**: ~2 days (up from 1.5 due to signed outer envelope + multi-recipient)

**Envelope format v1 (locked — no breaking change in M4 rooms):**

```
{
  "from": "<canonical_alias>",
  "to":   "<canonical_alias>" | null,       // null for room sends
  "room": "<room_id>" | null,                // non-null for room sends
  "ts":   <epoch_ms>,
  "enc":  "box-x25519-v1" | "plain",
  "recipients": [                            // len=1 for DM, len=N for rooms (future)
    { "alias": "<canonical>", "nonce": "<b64 24B>", "ciphertext": "<b64>" }
  ],
  "sig":  "<b64 Ed25519 signature>"          // sender signs canonical JSON of
                                             // {from,to,room,ts,enc,recipients}
}
```

For `enc:"plain"`, `recipients` is `[{alias, nonce:null, ciphertext:<b64 plaintext>}]` to keep shape uniform. `sig` is still required.

- Sender resolves recipient's `x25519_pubkey` via relay (cached); if present, libsodium `crypto_box_easy(body, nonce, recipient_x25519_pub, sender_x25519_priv)` per recipient. Nonce is fresh 24B random per recipient per message. Otherwise plaintext + warn log.
- **[C1+C3] Signed outer envelope**: sender ALWAYS signs the canonical JSON with Ed25519 identity key, regardless of `enc`. Receiver MUST verify signature BEFORE attempting decrypt. If sig fails, drop the message and log.
- **[C1] `enc_status` is receiver-local, never wire-serialized.** Do not include in outbound envelope; compute post-decrypt for display only.
- **[C1] Downgrade protection**: receiver maintains a per-sender "seen encrypted" bit; if a sender who previously sent `enc:"box-x25519-v1"` sends `enc:"plain"`, surface as `enc_status:"downgrade-warning"` (not silent). Applies only once recipient has observed sender's x25519 pubkey.
- **[C2] Nonce**: fresh 24B random per recipient per message; random-nonce collision probability accepted (2^-96 per pair).
- Receiver's broker on poll_inbox: (1) verify sig, (2) if `enc="box-x25519-v1"`, find own entry in `recipients[]` by alias, `crypto_box_open_easy` with sender's x25519 pubkey + own x25519 secret, (3) expose `enc_status` locally.
- Failure mode: sig fail → drop + log; decrypt fail → surface with `enc_status:"failed"` preserving raw blob; recipient-not-in-list → `enc_status:"not-for-me"`.
- **[I6] Unit-test stub for S2 dependency**: galaxy may use an in-memory `Pubkey_lookup.t` module-type with a test implementation; integration tests that hit the real relay block on S2 landing.
- Tests: sign+encrypt → verify+decrypt roundtrip; tamper `recipients[]` → sig fail; tamper `enc` field → sig fail; downgrade detection; multi-recipient (len=2) roundtrip; mixed plain+encrypted session.

### S4 — Observer WebSocket endpoint (relay)

**Owner**: jungle-coder (claimed 2026-04-23)
**Blocks**: S7
**BlockedBy**: none (can start immediately; doesn't require S1-S3)
**Estimate**: ~2 days
**[parallel with S1-S3]**
**Lib**: `websocketaf` (integrates with existing conduit-lwt-unix/cohttp-lwt-unix stack; no extra C stubs).

- `wss://relay/observer/<machine_binding>` in `ocaml/relay/relay.ml`.
- Auth: Bearer header = Ed25519-signed token `{binding, phone_pubkey, issued_at, nonce}` signed by phone's identity; relay verifies against stored binding.
- **[C5] Bearer token freshness**: relay rejects if `now - issued_at > 60s`. Relay keeps LRU of seen `(phone_pubkey, nonce)` pairs for ≥120s window; rejects replay.
- **[C5] Per-frame authorization**: binding→phone_pubkey lookup is re-checked on every inbound frame, not just at handshake. Binding revoked mid-session → server closes socket with status 4401.
- **[C5] Revocation hook**: new CLI `c2c mobile-unpair <binding_id>` removes a binding and broadcasts to relay (binding table update). Implement stub in S4; CLI surface lands in S5.
- Server push: every envelope arriving at the bound broker (inbound + outbound) is forwarded to connected observers. Observer-destined messages also go to a short queue (S6) when no socket is connected.
- Phone→relay messages: DM/room/reply envelopes come back over the same socket; relay injects them into the broker as if the phone were a normal peer. Each inbound frame re-verifies phone's identity via bearer.
- Reconnect: client sends `since_ts` cursor; relay replays queue + auth-gated history request (see S6 for scoping rules).
- Tests: relay contract test harness (mirror remote-relay pattern). Ws-client stub, auth success + failure, bearer replay rejection, mid-session revocation, push + reconnect.

### S4b — Rate limiting + structured pairing logs (NEW per review)

**Owner**: jungle-coder (claim with S4)
**BlockedBy**: none (can land incrementally alongside S2/S4/S5)
**Estimate**: ~0.5 day

- Token-bucket rate limiter module in `ocaml/relay/ratelimit.ml`. Apply to: `/pubkey/*` (generous, pubkeys are public), `/mobile-pair` (strict: 10/min/IP), `/device-pair/*` (strict: 5/min/IP per user-code; 10 failed attempts invalidates the code), `/observer/*` handshake (strict: 20/min/IP).
- Structured JSON logs for every pair/unpair/handshake event: `{event, ts, binding_id_prefix, phone_pubkey_prefix, source_ip_prefix, result, reason?}`. Prefixes are first 8 chars — enough to correlate without leaking full identifier.
- Tests: rate-limit rejects over-threshold; log shape stable.

### S5a — `c2c mobile-pair` (QR token issuance + binding endpoint)

**Owner**: TBD (open between galaxy/jungle; claim after S1 + S4 land)
**BlockedBy**: S1 (needs X25519), S4 partial (needs binding model defined)
**Estimate**: ~1.5 days

- New OCaml CLI: `c2c mobile-pair [--claim <user-code>] [--revoke <binding_id>]`.
- Default mode: generate one-time pairing token (5 min TTL), signed by machine's Ed25519 identity. Emit a QR to terminal (qrencode).
- Payload: `{relay_url, binding_id, token, machine_ed25519_pubkey}` — binding_id is relay-assigned UUIDv4, fetched by CLI from `POST /mobile-pair/prepare`.
- Relay endpoint `POST /mobile-pair` accepts `{token, phone_ed25519_pubkey, phone_x25519_pubkey}` → verifies token → binds phone identity to machine scope → burns token → returns binding confirmation.
- **[C4] Atomic burn**: token burn is compare-and-swap (SQLite `UPDATE … WHERE token=? AND used=0` or equivalent). Concurrent claims: only one wins; loser gets HTTP 409.
- **[I4] Revocation flow**: `c2c mobile-pair --revoke <binding_id>` calls `DELETE /binding/<id>` (machine auth via Ed25519 sig). Removes binding + active observer sockets for that binding close immediately.
- **[I2] Rate limits**: governed by S4b (10/min/IP on the endpoint).
- Tests: token issue+verify+burn; double-use rejected (409); concurrent-claim test (only one wins); TTL expiry; revocation closes active socket.

### S5b — Device-login OAuth fallback

**Owner**: same as S5a (can parallelize once token format is locked)
**BlockedBy**: S5a token format; independent of S5a binding endpoint
**Estimate**: ~1 day
**[parallel with S5a once format agreed]**

- Relay endpoints: `POST /device-pair/init` returns `{user_code, device_code, poll_interval}`. Phone hits `POST /device-pair/<user-code>` to register its pubkeys against the pending code. Machine operator runs `c2c mobile-pair --claim <user-code>` to confirm.
- Same binding result as QR flow; user-code 8-char base32, 10-minute TTL.
- **[I2] Brute-force defence**: rate-limit per S4b (5/min/IP per user-code; 10 failed attempts → code invalidated).
- Tests: e2e fake-phone flow; user-code collision; expiry; 10-fail invalidation.

### S6 — Short-queue + auth-gated history backfill

**Owner**: jungle-coder (claimed 2026-04-23)
**BlockedBy**: S4
**Estimate**: ~1 day

- In-memory ring per binding, ~1h or ~1000 msgs whichever first. Persisted snapshot on relay restart (optional; ok to lose on restart in v1 — document in S8).
- On reconnect, phone sends `since_ts`; relay replays from ring; if gap precedes ring start, relay issues broker history request bounded to 500 msgs / 24h.
- **[C6] Authorization scoping**: history fetch returns ONLY messages where `(to == phone_alias) OR (room_id IN phone_joined_rooms) OR (machine_binding == one of phone's bound machines)`. A phone paired to machine-A MUST NOT receive machine-B history via the same socket. Test explicitly.
- Auth: every history fetch re-verifies bearer sig + binding→phone_pubkey mapping (per C5).
- **[I8] Broker-offline handling**: if broker is unreachable, observer socket stays open, emits `{event:"broker_offline"}` status frames. Phone→machine sends buffer on relay for ≤5min then 503 back to phone.
- Tests: drop-and-reconnect replays; ring overflow drops oldest; bounded backfill; cross-machine scope isolation (phone-A cannot read machine-B); broker-offline buffering.

### S7 — OCaml-side contract tests (observer + mobile-pair)

**Owner**: jungle-coder (claimed 2026-04-23)
**BlockedBy**: S4, S5
**Estimate**: ~1 day
**[parallel with S6]**

- New `ocaml/test/test_relay_observer.ml` mirroring `test_relay_remote_broker.ml`.
- Coverage: websocket handshake, auth pass/fail, push fidelity (ciphertext preserved), reconnect cursor, short-queue drop at TTL.
- Add to `just test-ocaml` gate.

### S8 — Docs + runbook

**Owner**: coordinator1
**BlockedBy**: S1-S7 landing
**Estimate**: ~0.5 day

- `docs/mobile-pairing.md` runbook (QR flow + device-login).
- Update `docs/e2e-encryption.md` (new) describing opportunistic encrypt + rollout phase.
- Update CLAUDE.md key architecture notes.
- Update todo-ongoing.txt project entry.

---

## Dependency graph

```
S1 (X25519 register) ─┐
                      ├─→ S3 (opportunistic E2E, signed envelope) ─┐
S2 (pubkey lookup) ───┘                                             │
                                                                    ├─→ S8 (docs)
S4 (observer ws) ─→ S5a (mobile-pair QR) ─┐                         │
              ├──→ S4b (rate + logs) ─────┼─→ S7 (contract tests) ──┘
              └──→ S6 (short-queue) ──────┤
                                 S5b (device-login) (parallel to S5a)
```

Critical path: S1 → S3 → S7 (E2E side) and S4 → S5a → S7 (mobile side). S4b can land incrementally against any relay endpoint.

## Open questions (to resolve in peer review)

- **Q1 — machine_binding_id shape.** → **RESOLVED: relay-assigned UUIDv4 at pair-time.** No hostname (unstable + leaks identity). Confirmed jungle-coder 2026-04-23.
- **Q2 — phone identity on relay.** → **RESOLVED: Ed25519 pubkey-hash primary, human name display-only.** Confirmed jungle-coder 2026-04-23.
- **Q3 — key rotation.** If a peer rotates X25519, inflight ciphertext to the old key fails. Ship rotation UX in M1 or defer to M3? → **RESOLVED: defer to M3.** M1 ships `--rotate-enc-key` for manual regen; no automated grace window. Confirmed galaxy-coder 2026-04-23.
- **Q4 — libsodium vs age.** Spec says "pick when M1 starts." → **RESOLVED: libsodium.** opam `sodium` package, direct X25519 support. Confirmed galaxy-coder 2026-04-23.
- **Q5 — does the phone need Ed25519 separate from X25519?** → **RESOLVED: yes, both.** X25519 for E2E, Ed25519 for auth envelopes; phone generates both on first pair. No peer objected.
- **Q6 — legacy peer behavior on encrypted inbound.** → **RESOLVED: sender falls back to plaintext when recipient advertises no pubkey; receivers MUST preserve `body_ciphertext` untouched even if they can't decrypt.** No peer objected.

**All Q1-Q6 resolved 2026-04-23. No outstanding decisions blocking implementation.**

## Review findings (2026-04-23 — code-reviewer subagent pre-code pass)

All CRITICAL items landed in slice specs above. Summary:

- **[C1]** Downgrade + metadata tamper: S3 envelope now signed outer (Ed25519), `enc_status` is receiver-local only, downgrade-warning when previously-encrypted sender goes plain.
- **[C2]** Nonce: fresh 24B random per recipient per message, transmitted in envelope.
- **[C3]** Sender identity: Ed25519 sig over canonical envelope, verified before decrypt.
- **[C4]** Pair token burn: atomic CAS, concurrent claim → 409 for loser.
- **[C5]** WS bearer: 60s freshness, nonce LRU for replay, per-frame auth re-check, revocation closes socket.
- **[C6]** `since_ts` scoping: history filtered to phone's bound machines + own alias + joined rooms.

IMPORTANT items:
- **[I1]** Key storage threat model noted in S1; OS keyring deferred to M3.
- **[I2]** Rate limits → new slice S4b.
- **[I3]** Observability → S4b structured logs.
- **[I4]** Re-pair/revoke flow → S5a `--revoke`.
- **[I5]** Multi-recipient envelope shape baked into S3 now (ready for M4 rooms, no breaking change).
- **[I6]** S3 unit tests stub S2 via a module-type interface.
- **[I7]** S5 split into S5a + S5b, parallelizable after format agreed.
- **[I8]** Broker-offline handling → S6.

NICE items (deferred):
- **[N1]** Forward secrecy (Noise/X3DH) — documented limitation v1, consider M3+.
- **[N2]** QR payload size — verify in test (should be <400B → QR v6-8, fine).
- **[N3]** Pair audit log — defer to M5 runbook.

## Outstanding issues for Max

*(logged here; Max is AFK. Will pursue defaults above and flag on return.)*

- **Forward secrecy**: v1 uses raw `crypto_box` which has NO forward secrecy. If a long-lived X25519 secret ever leaks, all historical ciphertext encrypted to that key is recoverable. Consider Noise_XK or libsignal X3DH in M3. Pre-flagging for Max because the decision belongs to him, not us.
- **OS keyring integration**: key storage at mode-0600 files is cross-agent-readable (any process as same user, including managed agent children, can read the key file). This is an M3 item but worth flagging: if the threat model should include other user-space processes, we need keyring integration (libsecret on Linux, Keychain on macOS) earlier.
- **Relay-side binding persistence**: if the relay process restarts mid-M1, all in-memory bindings are lost and every phone needs to re-pair. Acceptable for v1 dev but NOT for production deploy. Need to decide before M4: SQLite-backed binding table vs in-memory only.

---

_Next step after peer review: assign owners, create TaskCreate entries, dispatch._
