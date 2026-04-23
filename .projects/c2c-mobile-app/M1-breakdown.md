# M1 — Relay-side foundation (draft)

**Status**: draft for peer review 2026-04-23. Awaiting input from galaxy-coder + jungle-coder.
**Parent spec**: [spec.md](spec.md) §7 (Milestones) — M1 = "relay-side observer WebSocket + pairing + X25519 key publication in register + short-queue".
**Scope change vs. spec v0.2**: E2E crypto is a swarm-wide protocol change, not just mobile. This breakdown includes the base layer for all peers (pubkey publication + opportunistic encrypt) so mobile ships onto a working foundation. Proposed new spec §10 tracks the rollout.

---

## Principles

- **Backward compatible throughout M1.** Every change must keep existing agents (Claude/Codex/OpenCode/Kimi) working with zero config change. Peers without a pubkey get plaintext; peers with one get boxed.
- **Relay stays read-only for bodies.** It sees metadata + ciphertext only. Signed envelopes prove provenance.
- **Small, independent slices.** Each slice should land as its own commit with tests; nothing blocks on a long-running monolith PR.
- **OCaml-first.** All new broker/relay code lands in `ocaml/`. No Python regressions.

---

## Slices

Ordered by dependency. Parallelizable pairs flagged with `[parallel: …]`.

### S1 — X25519 keypair in `c2c register` (broker + registry)

**Owner**: TBD (galaxy-coder — prior Ed25519 signing work)
**Blocks**: S3, S5, S7
**Estimate**: ~1 day

- Extend `registration` record in `c2c_registry.ml` with `enc_pubkey: string option` (base64 X25519 public key, 32 bytes).
- On `c2c register` (MCP tool + CLI), generate X25519 keypair if missing; store secret in `~/.c2c/keys/<session_id>.x25519` mode 0600; publish public in registry.
- Add `c2c whoami --show-keys` to print the session's pubkey.
- Migration: existing registrations without `enc_pubkey` remain valid; a new `c2c register --rotate-enc-key` regenerates.
- Tests: alcotest roundtrip (generate → publish → load → matches), keypair persistence, absent-key backward compat.

### S2 — Signed pubkey lookup on relay

**Owner**: TBD (jungle-coder — relay transport v1)
**Blocks**: S3
**Estimate**: ~1 day
**[parallel with S1]**

- Add `GET /pubkey/<canonical_alias>` to `ocaml/relay/relay.ml`. Returns `{alias, ed25519_pubkey, x25519_pubkey, signed_at, signature}`.
- Signature = Ed25519 over `alias || ed25519_pubkey || x25519_pubkey || signed_at` by the advertising peer's Ed25519 key. Relay passes through; does not mint.
- Cache invalidation: relay refreshes from broker on miss or on push from peer's `c2c publish-keys` (new CLI command, cheap).
- Auth: unauthenticated GET (pubkeys are public); rate-limit by IP.
- Tests: relay contract test for lookup round-trip + signature verify + missing-alias 404.

### S3 — Opportunistic E2E in `c2c send` + MCP `send`

**Owner**: TBD (galaxy-coder best-fit — crypto cont.)
**Blocks**: S7 (mobile pairing relies on this working)
**BlockedBy**: S1, S2
**Estimate**: ~1.5 days

- Sender resolves recipient's `x25519_pubkey` via relay (cached); if present, libsodium `crypto_box_easy` over body; otherwise plaintext + warn log.
- Envelope gains `enc: "box-x25519-v1" | "plain"` field; ciphertext base64 in `body_ciphertext`.
- Receiver's broker auto-decrypts on poll_inbox; exposes `enc_status: "decrypted"|"plain"|"failed"` on inbound envelope.
- Failure mode: decrypt fail → message surfaces as `enc_status:"failed"` with raw blob; does NOT silently drop.
- Tests: encrypt → poll → decrypt roundtrip; mixed plain+encrypted session; bad key rejects cleanly.

### S4 — Observer WebSocket endpoint (relay)

**Owner**: TBD (jungle-coder — relay transport)
**Blocks**: S7
**BlockedBy**: none (can start immediately; doesn't require S1-S3)
**Estimate**: ~2 days
**[parallel with S1-S3]**

- `wss://relay/observer/<machine_binding>` in `ocaml/relay/relay.ml`.
- Auth: Bearer header = Ed25519-signed token `{binding, phone_pubkey, issued_at, nonce}` signed by phone's identity; relay verifies against stored binding.
- Server push: every envelope arriving at the bound broker (inbound + outbound) is forwarded to connected observers. Observer-destined messages also go to a short queue (S6) when no socket is connected.
- Phone→relay messages: DM/room/reply envelopes come back over the same socket; relay injects them into the broker as if the phone were a normal peer.
- Reconnect: client sends `since_ts` cursor; relay replays queue + auth-gated history request.
- Tests: relay contract test harness (mirror remote-relay pattern). Ws-client stub, auth success + failure, push + reconnect.

### S5 — `c2c mobile-pair` (machine-side QR)

**Owner**: TBD (galaxy-coder or jungle-coder)
**BlockedBy**: S1 (needs X25519), S4 partial (needs binding model defined)
**Estimate**: ~1.5 days

- New OCaml CLI: `c2c mobile-pair [--claim <user-code>]`.
- Default mode: generate one-time pairing token (5 min TTL), signed by machine's Ed25519 identity. Emit a QR to terminal (qrencode).
- Payload: `{relay_url, binding_id, token, machine_ed25519_pubkey}`.
- Relay endpoint `POST /mobile-pair` accepts `{token, phone_ed25519_pubkey, phone_x25519_pubkey}` → verifies token → binds phone identity to machine scope → burns token → returns binding confirmation.
- `--claim` mode: used with device-login fallback (S5b).
- Tests: token issue+verify+burn; double-use rejected; TTL expiry.

### S5b — Device-login OAuth fallback

**Owner**: same as S5
**BlockedBy**: S5
**Estimate**: ~1 day

- Relay endpoints: `POST /device-pair/init` returns `{user_code, device_code, poll_interval}`. Phone hits `POST /device-pair/<user-code>` to register its pubkeys against the pending code. Machine operator runs `c2c mobile-pair --claim <user-code>` to confirm.
- Same binding result as QR flow; user-code 8-char base32, 10-minute TTL.
- Tests: e2e fake-phone flow; user-code collision; expiry.

### S6 — Short-queue + auth-gated history backfill

**Owner**: TBD
**BlockedBy**: S4
**Estimate**: ~1 day

- In-memory ring per binding, ~1h or ~1000 msgs whichever first. Persisted snapshot on relay restart (optional; ok to lose on restart in v1).
- On reconnect, phone sends `since_ts`; relay replays from ring; if gap precedes ring start, relay issues broker history request bounded to 500 msgs / 24h.
- Auth: every history fetch re-verifies binding signature and machine authorization.
- Tests: drop-and-reconnect replays; ring overflow drops oldest; bounded backfill.

### S7 — OCaml-side contract tests (observer + mobile-pair)

**Owner**: TBD (likely jungle-coder, mirrors her remote-relay test pattern)
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
                      ├─→ S3 (opportunistic E2E) ─→ S7-tests
S2 (pubkey lookup) ───┘                            ↘
                                                     S8 (docs)
S4 (observer ws) ─→ S5 (mobile-pair QR) ─→ S5b ─┐   ↗
              └──→ S6 (short-queue) ────────────┴→ S7-tests
```

## Open questions (to resolve in peer review)

- **Q1 — machine_binding_id shape.** Hash of machine hostname + relay-assigned nonce? Or purely relay-assigned? → recommend relay-assigned UUIDv4, bound at pair-time.
- **Q2 — phone identity on relay.** Store by Ed25519 pubkey hash, or by human-named binding? → recommend pubkey-hash primary, human name a display-only nick.
- **Q3 — key rotation.** If a peer rotates X25519, inflight ciphertext to the old key fails. Ship rotation UX in M1 or defer to M3? → recommend defer; M1 ships regen-only, no grace window.
- **Q4 — libsodium vs age.** Spec says "pick when M1 starts." → recommend libsodium: lower-level, well-known, existing OCaml bindings (`sodium` package on opam).
- **Q5 — does the phone need Ed25519 separate from X25519?** Yes — X25519 for E2E, Ed25519 for auth envelopes. Phone generates both on first pair.
- **Q6 — legacy peer behavior on encrypted inbound.** If a legacy broker without decrypt support receives ciphertext, what happens? → recommend: sender falls back to plaintext when recipient advertises no pubkey; so this shouldn't occur. Belt-and-braces: receivers MUST preserve `body_ciphertext` untouched even if they can't decrypt, so a later-upgraded agent can re-process.

## Outstanding issues for Max

*(logged here; Max is AFK. Will pursue defaults above and flag on return.)*

- None blocking yet. If peer review surfaces disagreements we can't resolve among ourselves, they land here.

---

_Next step after peer review: assign owners, create TaskCreate entries, dispatch._
