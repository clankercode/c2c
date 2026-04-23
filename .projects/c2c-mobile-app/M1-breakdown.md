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
- **TOFU key pinning (per-broker)**: each broker maintains a `known_keys` store (`~/.c2c/known_keys/<canonical_alias>.json`) of the first-observed `{ed25519_pubkey, x25519_pubkey, first_seen_ts}` for every peer it has ever received a signed envelope from or resolved via S2 lookup. On subsequent lookups/receipts, broker compares advertised keys against the pinned record. Silent key changes are REJECTED at the receive path (envelope dropped) and surfaced to the local consumer via `enc_status:"key-changed"` (new S3 variant) so the user can re-pin deliberately (`c2c trust --repin <alias>`, stubbed here; real CLI in S8 runbook).
- Rationale: TOFU closes the MITM window opened by an unauthenticated `GET /pubkey`; the relay is explicitly untrusted for body content but it *could* swap keys. Pinning makes any such swap loud.
- Tests: relay contract test for lookup round-trip + signature verify + missing-alias 404; broker-side pin-on-first-sight; key-change detection surfaces `enc_status:"key-changed"` and drops the envelope.

### S3 — Opportunistic E2E in `c2c send` + MCP `send`

**Owner**: galaxy-coder (claimed 2026-04-23)
**Blocks**: S7 (mobile pairing relies on this working)
**BlockedBy**: S1, S2 (can stub — see below)
**Estimate**: ~3-4 days (revised up from 2d: canonical JSON, Ed25519 sign/verify, hacl-star NaCl multi-recipient, downgrade state machine, pinned-key verify against S2 TOFU store, failure-mode surfacing, S2 stub for unit tests).

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
- **[C3 strict binding — x25519 pin check on OUTBOUND]**: before encrypting to a recipient, sender MUST compare the resolved `x25519_pubkey` against the recipient's pinned `x25519_pubkey` in the local `known_keys` store (populated by prior S2 lookups or inbound envelopes). On mismatch: abort the send, surface `enc_status:"key-changed"` locally, and require explicit `c2c trust --repin <alias>` (stubbed in S2) before the next attempt. This closes the symmetric gap where a malicious relay might swap ONLY the x25519 (leaving Ed25519 intact) to exfiltrate outbound replies to an attacker-controlled key.
- **[C1+C3] Signed outer envelope**: sender ALWAYS signs the canonical JSON with Ed25519 identity key, regardless of `enc`. Receiver MUST verify signature BEFORE attempting decrypt. If sig fails, drop the message and log.
- **[C3 strict binding] `from` field binding to pinned key**: the receiver MUST resolve `from`'s pinned Ed25519 pubkey via the S2 TOFU `known_keys` store and verify `sig` against THAT exact key. A valid signature by *any other* key (even one the relay currently serves for that alias) is a MISMATCH → drop the envelope + surface `enc_status:"key-changed"` locally. This is what makes S2 TOFU meaningful: the relay cannot substitute keys mid-stream without the receiver noticing. The relay SHOULD also verify `sig` against the pubkey it has on file for `from` (defense-in-depth, cheap) before injecting into the bound broker; a relay-side mismatch closes the inbound frame with error and logs. Broker-side verification is AUTHORITATIVE; relay-side is advisory.
- **Multi-recipient room-membership semantics**: `recipients[]` is the send-time membership snapshot of the room (for room sends) or `[{alias: <to>}]` for DMs. Consequence: (a) peers who join the room AFTER the send is committed do NOT appear in `recipients[]` and therefore cannot decrypt that specific envelope — they must backfill via `room_history` to see it; (b) peers who were members at send-time but LEAVE before receiving the envelope are still in `recipients[]` and CAN decrypt it — this is acceptable (they were a legitimate recipient at send-time). This trades perfect post-compromise secrecy for simplicity; forward-secrecy work is tracked under [N1] for M3+.
- **[C1] `enc_status` is receiver-local, never wire-serialized.** Do not include in outbound envelope; compute post-decrypt for display only.
- **[C1] Downgrade protection**: receiver maintains a per-sender "seen encrypted" bit; if a sender who previously sent `enc:"box-x25519-v1"` sends `enc:"plain"`, surface as `enc_status:"downgrade-warning"` (not silent). Applies only once recipient has observed sender's x25519 pubkey.
- **[C2] Nonce**: fresh 24B random per recipient per message; random-nonce collision probability accepted (2^-96 per pair).
- Receiver's broker on poll_inbox: (1) verify sig, (2) if `enc="box-x25519-v1"`, find own entry in `recipients[]` by alias, `crypto_box_open_easy` with sender's x25519 pubkey + own x25519 secret, (3) expose `enc_status` locally.
- Failure mode: sig fail → drop + log; decrypt fail → surface with `enc_status:"failed"` preserving raw blob; recipient-not-in-list → `enc_status:"not-for-me"`; pinned-key mismatch (from S2 TOFU) → `enc_status:"key-changed"` + drop.
- **`enc_status` variants (receiver-local only, never wire-serialized)**: `"ok"`, `"plain"`, `"failed"` (decrypt fail), `"not-for-me"` (own alias absent from `recipients[]`), `"downgrade-warning"` (previously-encrypted sender now plain), `"key-changed"` (NEW: pinned-key mismatch against S2 TOFU store).
- **[I6] Unit-test stub for S2 dependency**: galaxy may use an in-memory `Pubkey_lookup.t` module-type with a test implementation; integration tests that hit the real relay block on S2 landing.
- Tests: sign+encrypt → verify+decrypt roundtrip; tamper `recipients[]` → sig fail; tamper `enc` field → sig fail; downgrade detection; multi-recipient (len=2) roundtrip; mixed plain+encrypted session; **pinned Ed25519 mismatch on INBOUND (sig verifies against key other than pinned) → `enc_status:"key-changed"` + drop**; **pinned x25519 mismatch on OUTBOUND (resolved `x25519_pubkey` differs from pinned) → abort send + `enc_status:"key-changed"`**; first-contact pin creates `known_keys` entry.

### S4 — Observer WebSocket endpoint (relay)

**Owner**: jungle-coder (claimed 2026-04-23)
**Blocks**: S7
**BlockedBy**: none (can start immediately; doesn't require S1-S3)
**Estimate**: ~3 days (revised up from 2d: per-frame bearer re-auth, nonce replay LRU, revocation hook, reconnect cursor, AND phone→broker envelope sig verification path).
**[parallel with S1-S3]**
**Lib**: **`ocaml-websocket`** (vbmithr/ocaml-websocket) preferred — integrates with our existing cohttp-lwt-unix stack and supports OCaml 5.2. Fallback: manual RFC 6455 framing on `Conduit_lwt_unix.flow` in `ocaml/relay/ws_frame.ml` (~200 LOC server-side) if ocaml-websocket proves unusable. **Do NOT use `websocketaf`** — its dependency chain (httpaf <0.6, jbuilder) is incompatible with OCaml 5.2. Verified by jungle-coder 2026-04-23.

- `wss://relay/observer/<machine_binding>` in `ocaml/relay/relay.ml`.
- Auth: Bearer header = Ed25519-signed token `{binding, phone_pubkey, issued_at, nonce}` signed by phone's identity; relay verifies against stored binding.
- **[C5] Bearer token freshness**: relay rejects if `now - issued_at > 60s`. Relay keeps LRU of seen `(phone_pubkey, nonce)` pairs for ≥120s window; rejects replay.
- **[C5] Per-frame authorization**: binding→phone_pubkey lookup is re-checked on every inbound frame, not just at handshake. Binding revoked mid-session → server closes socket with status 4401.
- **[C5] Revocation hook**: new CLI `c2c mobile-unpair <binding_id>` removes a binding and broadcasts to relay (binding table update). Implement stub in S4; CLI surface lands in S5.
- Server push: every envelope arriving at the bound broker (inbound + outbound) is forwarded to connected observers. Observer-destined messages also go to a short queue (S6) when no socket is connected.
- Phone→relay messages: DM/room/reply envelopes come back over the same socket; relay injects them into the broker as if the phone were a normal peer. Each inbound frame re-verifies phone's identity via bearer.
- **Phone→broker envelope signing (MANDATORY)**: every phone-originated DM/room frame MUST be a full S3-format signed envelope — the phone's Ed25519 identity signature over the canonical JSON of `{from, to, room, ts, enc, recipients}`, where `from` is the phone's canonical alias (e.g. `max-phone`). The relay:
  1. Verifies the frame's envelope `sig` matches the phone's Ed25519 pubkey bound to this observer socket (the `phone_ed25519_pubkey` from `POST /mobile-pair`).
  2. On mismatch: CLOSE the socket with status **4403** (forbidden / envelope sig does not match bound phone identity); log via S4b structured logs with `result:"sig_mismatch"`.
  3. Only after sig verification passes does the relay inject the envelope into the bound broker's inbox path. Broker then re-verifies sig against the pinned `known_keys` entry for the phone alias (S2 TOFU) exactly as for any other peer — no relay-provided shortcut.
- Rationale: bearer auth proves the *socket owner* is the phone; per-frame envelope sig proves the *individual message* came from the phone's Ed25519 key (not a relay operator smuggling messages on behalf of a compromised binding). Both are required.
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
- Relay endpoint `POST /mobile-pair` accepts `{token, phone_ed25519_pubkey, phone_x25519_pubkey}` → verifies token → binds phone identity to machine scope → burns token → returns binding confirmation (itself signed by the machine's Ed25519 identity over `{binding_id, phone_ed25519_pubkey, phone_x25519_pubkey, bound_at}`).
- **Phone-side token verification (MUST, before POST)**: phone verifies the QR payload's pairing-token signature against `machine_ed25519_pubkey` (also in the QR payload) BEFORE sending its pubkeys to the relay. Rationale: a malicious QR (displayed on a compromised terminal / photographed + replayed) cannot impersonate a machine the user thinks they're pairing with — the token sig binds the token to a specific machine identity the user is committing to trust.
- **Phone-side binding-confirmation re-verification (MUST, after POST)**: the `POST /mobile-pair` response includes the machine-signed binding confirmation described above; phone re-verifies that sig against the same `machine_ed25519_pubkey` it pinned at QR-scan time. Mismatch → abort pair + surface "relay-tampered binding" error. This closes the relay-in-the-middle window between token-issue and binding-commit.
- **Phone multi-machine key scoping**: the phone holds a single Ed25519 *identity* root but derives a DISTINCT X25519 subkey per machine binding, via `HKDF-SHA256(x25519_root_seed, info = "c2c-binding-v1" || binding_id)` at pair-time. Only the per-binding X25519 pubkey is POSTed to the relay; the root seed never leaves the phone. Consequence: machine-A's agents can encrypt only to the X25519 pubkey scoped to binding-A, so they cannot decrypt ciphertext an unrelated sender produced for the phone's binding-B key on binding-B. This gives binding isolation "for free" without a per-machine Ed25519 identity (the phone remains a single signer across all its bindings — which is what users expect and what matches `max-phone` as one c2c alias). Alternative considered: single global X25519 + rely on recipient-alias scoping only — rejected because agents on different machines would encrypt to the same key, defeating the isolation goal once the relay sees traffic across multiple machines.
- **Root-seed rotation cascade (known limitation)**: because all per-binding X25519 subkeys are HKDF-derived from a single `x25519_root_seed`, rotating that root (e.g. phone reinstall, user-initiated "reset keys") simultaneously invalidates EVERY binding's derived subkey — the phone must re-pair with every machine it was previously bound to. This is acceptable for v1 (rotation is a rare, explicit user action) but MUST be surfaced in S8 runbook as part of the re-pair/key-loss flow ([I4]). No automated cross-binding recovery in M1; deferred to M3 as part of the broader rotation-UX work (Q3).
- **[C4] Atomic burn**: token burn is compare-and-swap (SQLite `UPDATE … WHERE token=? AND used=0` or equivalent). Concurrent claims: only one wins; loser gets HTTP 409.
- **[I4] Revocation flow**: `c2c mobile-pair --revoke <binding_id>` calls `DELETE /binding/<id>` (machine auth via Ed25519 sig). Removes binding + active observer sockets for that binding close immediately.
- **[I2] Rate limits**: governed by S4b (10/min/IP on the endpoint).
- Tests: token issue+verify+burn; double-use rejected (409); concurrent-claim test (only one wins); TTL expiry; revocation closes active socket; phone-side token-sig verification rejects QR with invalid machine sig; phone-side binding-confirmation re-verification rejects tampered relay response; per-binding X25519 subkey derivation is deterministic given root seed + binding_id, and two distinct binding_ids produce distinct pubkeys.

### S5b — Device-login OAuth fallback

**Owner**: same as S5a (can parallelize once token format is locked)
**BlockedBy**: S5a token format; independent of S5a binding endpoint
**Estimate**: ~1 day
**[parallel with S5a once format agreed]**

- Relay endpoints: `POST /device-pair/init` returns `{user_code, device_code, poll_interval}`. Phone hits `POST /device-pair/<user-code>` to register its pubkeys against the pending code. Machine operator runs `c2c mobile-pair --claim <user-code>` to confirm.
- Same binding result as QR flow; user-code 8-char base32, 10-minute TTL.
- **[I2] Brute-force defence**: rate-limit per S4b (5/min/IP per user-code; 10 failed attempts → code invalidated).
- Tests: e2e fake-phone flow; user-code collision; expiry; 10-fail invalidation.

### S5c — Relay-driven phone pseudo-registration propagation to bound broker (NEW per review)

**Owner**: TBD (likely jungle-coder — it's a relay→broker push path that reuses the observer socket plumbing).
**BlockedBy**: S5a (needs a committed binding + phone's X25519 pubkey bundle).
**Estimate**: ~0.5 day

- On successful `POST /mobile-pair` (and on each successful device-login claim), the relay pushes a pseudo-registration into the bound broker's registry so the phone appears as a normal c2c peer. Payload: `{alias: <chosen, e.g. "max-phone">, ed25519_pubkey, x25519_pubkey, binding_id, bound_at, provenance_sig}`.
- `provenance_sig` = Ed25519 signature by the machine's Ed25519 identity key (which originally minted the pairing token) over the canonical JSON of the payload MINUS the sig field. Broker verifies sig against the machine's own identity key before accepting the pseudo-registration. This means the relay cannot forge phone registrations — it can only propagate ones that were part of a pairing flow the machine itself authorized.
- Stored with a `pseudo_registration: true` flag and the originating `binding_id`, so `c2c mobile-unpair <binding_id>` (S5a `--revoke`) cleanly removes the corresponding registry entry.
- Without this slice, existing agents cannot DM the phone (`c2c send max-phone …` would fail "unknown alias"), `c2c list` would not show the phone as a peer, and mobile end-to-end reach is effectively blocked. This is a necessary connective tissue slice, not gold-plating.
- Alias collision rule: if requested alias is already live, relay returns the same 409 behavior as alias allocation elsewhere; phone retries with a variant (`max-phone-2`, etc).
- Tests: pair flow produces pseudo-registration visible in `c2c list`; `c2c send max-phone hi` reaches the broker and surfaces on the observer socket; unpair removes the registry entry; forged pseudo-registration payload (bad provenance sig) rejected by broker; collision retry path.

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
- **Legacy-compat matrix** (explicit tests — we are live-upgrading a running swarm, so this is load-bearing):
  - (a) Legacy peer (no X25519 advertised, no sig field) → mobile-era recipient: receiver renders plaintext + surfaces `enc_status:"plain"` + no sig-drop. Must NOT reject on missing `sig`.
  - (b) Mobile-era peer → legacy recipient: legacy code path ignores unknown `sig` / `recipients` / `enc` fields gracefully (treats body as plaintext). If legacy cannot be made to ignore the new fields, sender detects legacy via absence of advertised `x25519_pubkey` AND advertised protocol version, and falls back to a pure-plain envelope with no new fields at all.
  - (c) Legacy peer receives a signed-but-plain envelope (mobile-era sender had no recipient pubkey yet): legacy path MUST NOT reject on the unknown `sig` field — test by running an older broker build against a newer sender.
- **C1-C6 negative-case coverage** (review gap):
  - C1: first-contact plain (no prior sighting of sender) does NOT false-positive `downgrade-warning` — downgrade state is only armed after observing an encrypted envelope from that sender.
  - C3: envelope with a valid Ed25519 sig but signed by a key OTHER than the one pinned in `known_keys` for that alias → rejected, surfaces `enc_status:"key-changed"`.
  - C4: pair-token burn under crash-midway — simulate partial-failure (process dies between CAS success and binding insert) and verify recovery: either both committed or neither, never a burned-but-unbound token.
  - C5: bearer with `issued_at` in the FUTURE (clock-skew / attacker-crafted) rejected; bearer with a nonce replayed within the 120s LRU window rejected.
  - C6: phone-A previously bound to machine-A, then rebound to machine-B with a stale `since_ts` — machine-A history MUST NOT leak into the machine-B observer stream via the reused cursor.
- **M4-forward test**: synthetic 3-recipient room-shaped send roundtrip (sender + 3 recipients, `recipients[]` of length 3, `room` non-null) TODAY, even before the M4 room path lands, to prove the envelope shape survives and multi-recipient decrypt paths all resolve. Prevents discovering in M4 that M1's envelope format silently broke under N>1.
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
                      ├─→ S3 (opportunistic E2E, signed envelope, TOFU verify) ─┐
S2 (pubkey lookup +   ┘                                                          │
    broker-side TOFU pin)                                                        │
                                                                                 ├─→ S8 (docs)
S4 (observer ws) ─→ S5a (mobile-pair QR) ─→ S5c (phone pseudo-reg push) ─┐       │
              ├──→ S4b (rate + logs) ──────────────────────────────┬─→ S7 (contract tests + legacy matrix + C1-C6 negatives + M4-forward)
              └──→ S6 (short-queue) ───────────────────────────────┤
                                 S5b (device-login) (parallel to S5a, also feeds S5c)
```

Critical path: S1 → S3 → S7 (E2E side) and S4 → S5a → **S5c** → S7 (mobile side — S5c is now on the critical path because without it the phone is not a reachable peer and mobile end-to-end cannot be verified). S4b can land incrementally against any relay endpoint.

**Task list summary (for tracker sync)**: S1, S2, S3, S4, S4b, S5a, S5b, **S5c (NEW)**, S6, S7, S8.

## Open questions (to resolve in peer review)

- **Q1 — machine_binding_id shape.** → **RESOLVED: relay-assigned UUIDv4 at pair-time.** No hostname (unstable + leaks identity). Confirmed jungle-coder 2026-04-23.
- **Q2 — phone identity on relay.** → **RESOLVED: Ed25519 pubkey-hash primary, human name display-only.** Confirmed jungle-coder 2026-04-23.
- **Q3 — key rotation.** If a peer rotates X25519, inflight ciphertext to the old key fails. Ship rotation UX in M1 or defer to M3? → **RESOLVED: defer to M3.** M1 ships `--rotate-enc-key` for manual regen; no automated grace window. Confirmed galaxy-coder 2026-04-23.
- **Q4 — crypto library.** → **RESOLVED (pass 3 — 2026-04-23): `hacl-star` via `Hacl.NaCl`.** Original pick was libsodium (opam `sodium`) but that package requires OCaml <5.0, incompatible with c2c's OCaml 5.2+. Evaluated alternatives: (a) mirage-crypto-ec + cryptokit — rejected, missing HSalsa20/XSalsa20 required for NaCl box; (b) HKDF + ChaCha20-Poly1305 — rejected, wire-format departure from NaCl with no affirmative reason; (c) **hacl-star 0.7.2 — accepted**, already installed in c2c opam switch, exposes `Hacl.NaCl.box`/`box_open`/`secretbox` with 24B nonce (input parameter), formally verified (Project Everest F*→C), pure OCaml+C with no system libsodium dep. Confirmed galaxy-coder 2026-04-23 pass 3.
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
- **Phone multi-machine X25519 key scoping**: S5a now specifies HKDF-derived per-binding X25519 subkeys (phone retains single Ed25519 identity, distinct encryption subkey per paired machine, for binding isolation). This is a defensible default but contentious — alternatives are (a) single global X25519 key + rely on alias/recipient scoping, or (b) per-binding Ed25519 too (phone shows up as distinct peer per machine). Flagging explicitly so Max can weigh in before S5a ships; will pursue the HKDF-per-binding default in the meantime.
- **HKDF root-seed rotation cascade**: a direct consequence of the per-binding HKDF derivation is that rotating the phone's `x25519_root_seed` invalidates ALL bindings at once (every machine must re-pair). Acceptable in v1 as an explicit recovery action but worth confirming Max is OK with this before we ship. Alternative mitigation in M3: use a per-binding independently-stored X25519 keypair (no HKDF) so each binding can rotate independently at cost of per-binding encrypted-backup complexity.
- **TOFU re-pin UX**: `enc_status:"key-changed"` surfaces mismatches but M1 does not yet ship the operator-facing `c2c trust --repin <alias>` CLI. Until that lands, a legitimate key rotation (e.g. peer reran `c2c register --rotate-enc-key`) will hard-fail every subsequent receive on the pinning peer. Acceptable for dev-phase M1 (rotations are rare and operators can edit `known_keys/*.json` manually); must ship the CLI before we declare M1 production-ready.

---

_Next step after peer review: assign owners, create TaskCreate entries, dispatch._
