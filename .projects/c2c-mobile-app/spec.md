# c2c Mobile App — Spec v0.2

**Status**: answers locked-in 2026-04-23. Ready to break into milestones + dispatch M1.
**Filed**: 2026-04-23 by Max + coordinator1.
**Stack**: **Tauri Mobile** (share code with existing desktop GUI at `gui/` — Rust core + React/shadcn UI).
**Companion**: desktop GUI at `gui/` (Tauri + Vite + React + shadcn). Full feature parity is the eventual goal; mobile v1 ships narrower.

---

## 1. Goal

Give users oversight and interactive control of the c2c swarm running on their machine(s) from a phone. Key outcomes:

- **Oversight**: see every message flowing between agents on selected machine(s), including messages where one party is remote.
- **Direct comms**: 1:1 DM any registered c2c alias; N:N room participation.
- **Answering prompts**: agents and humans send specially formatted messages that request a user decision (permission, question, ambiguity); the app detects structure and renders actionable cards; text fallback for older envelopes.
- **Design**: sleek, minimal, stylish; themes (including per-agent themes).
- **Parity**: eventual full parity with desktop GUI; v1 is narrower (see §7).

## 2. Non-goals (v1)

- Running a full agent on the phone.
- Editing/deploying code from the phone.
- Managing relays or servers from the phone.

## 3. Architecture

```
[phone: Tauri-mobile + React/shadcn]
    └─ TLS + E2E (libsodium/age) ─→ [relay (OCaml)]
                                          └─ SSH or WebSocket → [machine broker] ←→ [agents]
```

Core points:
- Phone holds an **Ed25519 identity** (signing) + **X25519 encryption keypair** (E2E). Generated on first pair.
- Phone authenticates to relay with signed envelopes.
- E2E encryption layered over relay so the relay sees only ciphertext + metadata (§3.3).
- Phone can bind to **multiple machines** via repeat pairing.
- Phone registers as a normal c2c peer (e.g. `max-phone`) so it appears in `c2c list` and receives DMs like any other peer.

### 3.1 Pairing

**Primary**: `c2c mobile-pair` on the target machine prints a QR code with:
- relay URL
- one-time pairing token (short TTL, signed by machine's Ed25519 identity)
- machine binding identifier

Phone scans → generates identity + encryption keypair → POSTs to relay with token → relay atomically binds phone identity to machine scope → token burned.

**Fallback**: **device-login OAuth-style flow** for when QR isn't viable (e.g. headless server, user pairing from far away). Relay hosts `/device-pair/init` returning a short user-code; phone hits `/device-pair/<user-code>`; machine operator confirms on CLI via `c2c mobile-pair --claim <user-code>`. Same binding result as QR.

### 3.2 Observer & two-way transport

**WebSocket** per paired machine.

- `wss://relay/observer/<machine_binding>` — authenticated with signed Bearer (Ed25519 envelope).
- Server pushes every inbound/outbound message envelope at the bound broker to the phone.
- Phone sends DMs, permission replies, room messages back through the same socket.
- Reconnect resumes from a `since_ts` cursor; short-window queue backfills (§3.4).

### 3.3 E2E encryption

Required from v1 because relay must not be a read-capable party on message bodies.

- Per-recipient X25519 + libsodium box (or age-compatible primitive — pick when M1 starts).
- Sender encrypts body to each recipient's published encryption key; plaintext never leaves sender.
- Relay ferries ciphertext + metadata envelope.
- Observer endpoint delivers ciphertext; phone decrypts with its keypair.
- **Open: key distribution** — extend `c2c register` to publish X25519 pubkey alongside Ed25519. Agents/clients fetch recipient pubkeys via relay (signed lookup).
- Backwards compatibility: legacy unsigned/unencrypted messages still accepted during migration; phone renders them with a "unencrypted" indicator.

### 3.4 Offline / reconnect

- Relay queues observer-destined messages for ~1 hour when phone is offline.
- After 1h, messages are dropped from the short queue (but remain in broker history).
- On reconnect, phone requests `since_ts` via relay protocol — relay checks phone identity is authorized for this machine, then returns history from broker (bounded — e.g. last 500 messages or last 24h).
- All history requests are auth-gated the same way as live observer traffic.

### 3.5 Multi-machine

- Phone can pair with N machines, each with its own binding.
- In-app selector: "Which machine?" Switch between machines; each has its own feed + DM list.
- UI indicates which machine a message belongs to (color-code by machine or in a header strip).

## 4. Core features

### 4.1 Live feed
Scrolling feed per machine. Messages grouped by conversation (alias pair or room). Each shows: from → to, timestamp, body, source tag, envelope attributes.

### 4.2 DM composer
Tap alias → 1:1 thread → send signed + E2E-encrypted message.

### 4.3 Prompt cards (text fallback + structured detection)
- Text-based envelope (current shape): parsed with pattern matching; if matches a permission request, rendered as a card.
- Structured envelope (future): if the sender uses a richer JSON envelope for decisions, phone uses it directly.
- Both paths produce the same card UI (Approve-once / Approve-always / Reject / Custom reply).
- Outbound reply is a signed + encrypted message using the existing `c2c send` reply pattern.

### 4.4 Themes
- Global: light, dark, system.
- Per-agent: color/icon/emoji accents pulled from canonical role files (`.c2c/roles/<name>.md`), synced via relay.
- Accessibility: system contrast + font-size respect.

### 4.5 Rooms
N:N rooms from v1. Phone joins/leaves/sends with Ed25519-signed room ops per phase-3 migration.

### 4.6 Notifications

**Approach**: keep it simple + principled so we can swap providers later.

- **v1 provider**: **Firebase Cloud Messaging** for Android (free, standard) + **APNs** for iOS (required). Tauri-mobile provides an interface for both.
- **Principle**: all push logic behind a `NotificationProvider` trait in Rust core → we can swap FCM for OneSignal / AWS SNS / etc. without changing app code.
- **Payload**: minimal — encrypted blob containing `{kind: "prompt"|"dm"|"room", from, preview_hash}`. Actual body fetched over WebSocket after OS wake.
- **What triggers push**: prompt cards, DMs to phone's alias, filter-rule matches.

## 5. Testing

- **Unit**: Rust crate tests + React component tests.
- **Integration**: Tauri-driven UI tests against a local mock relay.
- **E2E**: **isolated Docker environment** — mobile SDK emulator + mock relay + mock broker + Tauri-mobile debug build. Driven by `tauri-driver` or `webdriverio`. Gated behind `C2C_TEST_MOBILE_E2E=1`.
- **Relay contract tests**: new `/observer/*` WebSocket endpoint needs OCaml-side tests mirroring the remote-relay pattern.
- **E2E encryption tests**: roundtrip sender → relay → receiver with relay-side MITM assertion (ciphertext only).

## 6. Feature parity with desktop GUI

**v1 mobile scope** (narrower):
- Live feed.
- DM composer.
- Prompt cards.
- Multi-machine switcher.
- Themes + per-agent styling.
- Notifications (minimal).
- Basic room view (read + send).

**Deferred to parity phase**:
- Advanced filters / search.
- Any feature the GUI has that doesn't fit a phone screen well.

**Expected GUI changes during parity phase**:
- Factor the relay-client transport behind an interface so both clients share logic.
- GUI adds a "connect via relay" mode (matches mobile's only-mode).

## 7. Milestones

- **M1**: relay-side — observer WebSocket endpoint + pairing (QR + device-login) + X25519 key publication in register + short-queue. [**dispatched on M1 start**]
- **M2**: Tauri-mobile skeleton + pairing UX + identity/keypair storage in secure enclave / keystore + live feed (read-only).
- **M3**: DM composer + prompt cards + themes + E2E encryption end-to-end.
- **M4**: Rooms + notifications (FCM + APNs) + offline cache.
- **M5**: Dockerized E2E harness.
- **M6**: GUI parity pass (relay transport mode + feature alignment).

## 8. Resolved answers (from Max, 2026-04-23)

1. **Pairing**: QR primary + device-login OAuth-style fallback.
2. **Observer scope**: multi-machine — phone binds to several.
3. **Ownership**: pairing-based.
4. **Transport**: WebSocket.
5. **Prompt envelope**: keep text; add structured detection + handling; fall back to text rendering.
6. **E2E encryption**: required in v1 (scope increase accepted).
7. **Push**: FCM + APNs direct, behind a provider trait for later swap.
8. **Offline**: ~1h short queue then drop; reconnect triggers authed ad-hoc history fetch via relay protocol.
9. **Parity scope**: narrower v1; full parity in second-half plan.
10. **Stack**: Tauri-mobile (reuse existing GUI Rust + React code).
11. **Multi-user / multi-phone**: N:N supported upfront.

## 9. Risk notes

- **E2E encryption is the biggest scope add** — key-exchange UX, key rotation, backup/restore, and recipient-pubkey distribution all need design before M3.
- **Tauri-mobile maturity** — less battle-tested on iOS/Android than Flutter or native. Spike early in M2 to validate.
- **Apple App Store review** for "connect to your own server" apps — may need default relay binding (c2c.im) with custom relay opt-in hidden behind a settings toggle.
- **Push cert/provisioning** (APNs) is a multi-week task; factor into M4.
- **X25519 pubkey distribution** requires extending broker + relay protocols; must stay backwards-compatible with existing agents.

---

_Answers applied. Next step: dispatch M1 to a peer when ready._
