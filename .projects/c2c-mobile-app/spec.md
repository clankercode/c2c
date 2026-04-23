# c2c Mobile App — Spec v0.1

**Status**: draft, pending answers to open questions before implementation starts.
**Filed**: 2026-04-23 by Max + coordinator1.
**Stack**: Flutter (iOS + Android from one codebase).
**Companion**: desktop GUI at `gui/` (Tauri + Vite + React + shadcn); feature parity is a goal, so some GUI work may be required.

---

## 1. Goal

Give users oversight and interactive control of the c2c swarm running on their machine(s) from a phone. Key outcomes:

- **Oversight**: see every message flowing between agents on a selected machine, including messages where one party is remote (via relay).
- **Direct comms**: 1:1 DM any registered c2c alias.
- **Answering prompts**: agents and potentially other humans can send specially formatted messages that request a user decision (permission, question, ambiguity); the app renders these as actionable cards.
- **Design**: sleek, minimal, stylish; themes (including per-agent themes).
- **Parity**: match the desktop GUI's current feature set; when the GUI is ahead, port down; when the mobile app is ahead, port up.

## 2. Non-goals (v1)

- Running a full agent on the phone (it's a client, not a peer).
- Editing/deploying code from the phone.
- Managing relays or servers from the phone.

## 3. Architecture

```
[phone: Flutter]  —HTTPS—>  [relay (OCaml, c2c.im)]  —SSH or long-poll—>  [machine broker]  <--stdio-->  [agents]
```

- Phone holds an **Ed25519 identity** generated on first pair.
- Phone authenticates to the relay with that identity.
- Relay exposes a new **observer-scoped endpoint** that the phone polls (or long-holds) to receive a live stream of messages destined for / originating from the paired machine's broker.
- For 1:1 DM: phone uses existing `c2c send` equivalent over relay, with signed Ed25519 envelopes.
- Phone registers as a normal c2c peer (e.g. alias `max-phone`) so it can appear in `c2c list` and receive DMs like any other peer.

### 3.1 Pairing flow

Open question — see §8. Leading candidate: machine operator runs `c2c mobile-pair` which prints a one-time QR code (with relay URL + short-lived pairing token + broker binding). Phone scans QR → generates identity → POSTs to relay with pairing token → relay atomically binds phone identity to machine scope → pairing token is burned. Subsequent sessions use the bound identity.

### 3.2 Observer endpoint

New relay endpoint, signed-Bearer only:

- `GET /observer/<machine_binding>/stream` — server-sent events or long-poll returning every inbound/outbound message at the broker.
- Scope: only envelopes the paired phone identity is authorized for (all messages for the bound machine; others filtered).
- Optional filter query params: `from_alias=`, `to_alias=`, `source=`, `since_ts=`.

## 4. Core features

### 4.1 Live feed

Scrolling feed of messages, grouped by conversation (per alias pair or per room). Each message shows: from → to, timestamp, body, source tag (`c2c`/`channel`/`pty`/`relay`), and any envelope attributes (`event`, `reply_via`, `source`, `action_after`).

### 4.2 DM composer

Tap any alias → open 1:1 thread → send signed message via relay.

### 4.3 Prompt cards

When a message arrives with a `prompt`-shape envelope (e.g. permission request, question-to-user, ambiguity resolution), render as a card with explicit action buttons (Approve-once / Approve-always / Reject / Custom reply). Tapping submits a signed response via relay.

**New envelope convention needed** (or reuse existing permission format): see §8.

### 4.4 Themes

- Global themes: light, dark, system.
- Per-agent color/icon/emoji accents — pulled from the canonical role files (`.c2c/roles/<name>.md`), synced via relay.
- Accessibility: contrast + font-size per iOS/Android system prefs.

### 4.5 Rooms

View and participate in rooms (`swarm-lounge`, etc). Same signing rules as the desktop CLI (Ed25519 body signature per §room-op migration phase 3).

### 4.6 Notifications

Optional: platform push (APNs / FCM) when a prompt card arrives, or a DM to the phone's alias, or a filter rule hits.

## 5. Testing

- **Unit/widget**: Flutter `flutter_test` for all UI components.
- **Integration**: `integration_test` running the app against a local mock relay.
- **E2E**: isolated desktop environment via Docker — `android-sdk-headless` + a Flutter Android emulator running in a container + a local c2c broker + the OCaml relay. Drives the app via `flutter_driver` or `patrol`. Gated behind `C2C_TEST_MOBILE_E2E=1` like the other E2E harnesses.
- **Relay contract tests**: the new `/observer/*` endpoint needs OCaml-side tests mirroring the remote-relay pattern.

## 6. Feature parity with desktop GUI

The existing `gui/` (Tauri) features to match:

- `App.tsx` shell, `EventFeed.tsx`, `ComposeBar.tsx`, `Sidebar.tsx`.
- `useDiscovery.ts`, `useHistory.ts`, `useSend.ts` hooks → Dart-side equivalents via relay API (not direct broker file I/O, since phone has no filesystem access).

**Expected GUI changes**:
- Factor the relay-client transport (currently local-broker-file-based) behind an interface so both clients can share logic semantically.
- GUI adds optional "connect via relay" mode so the desktop app can ALSO observe a remote machine (parity with mobile's only-mode).

## 7. Milestones

- **M1**: relay observer endpoint + pairing + identity model (OCaml side).
- **M2**: Flutter app skeleton with pairing flow + live feed.
- **M3**: DM composer + prompt cards + themes.
- **M4**: Rooms + notifications + offline cache.
- **M5**: Dockerized E2E harness.
- **M6**: GUI parity pass (relay transport mode).

---

## 8. Open questions for Max

Need answers before M1 starts. Rough order of priority.

### Q1 — Pairing model
QR-code from `c2c mobile-pair` binding relay URL + one-time pairing token + machine broker identity? Or something else (e.g. relay-hosted login flow with OAuth-style redirect)? QR feels most c2c-shaped.

### Q2 — Observer scope — single machine or "all my machines"?
A user may have multiple machines talking to the same relay. Should a single phone identity see one specific machine's broker, a list of machines they own, or all brokers they're authorized for? Recommends: "list of machines", user picks in-app. But v1 could be "one machine" if simpler.

### Q3 — Machine-scope ownership at the relay
Who decides which Ed25519 phone identities get to observe a given machine's broker? Options:
- (a) Per-machine allowlist file on the server (operator edits `~/.config/c2c/observer-allowlist.json`).
- (b) Pairing QR is the ground truth (pair → identity is bound, revocation via CLI).
- (c) Central config at the relay (operator-only).

Recommends (b) — pairing-based, since it matches the pattern we used for `/register`.

### Q4 — Observer delivery model
- SSE / chunked response (relay pushes to phone; phone keeps a long connection open).
- Long-poll (phone makes request, relay holds until data or timeout).
- WebSocket (two-way, simpler for prompt-response round-trip).

Recommends **WebSocket** for v1 since we need two-way and it's cheaper than SSE + separate send endpoint.

### Q5 — Prompt envelope shape
The existing permission-request format (`<c2c ...>PERMISSION REQUEST...</c2c>` with ID + approve/reject reply-via-c2c-send) is text-heavy. Should the mobile client render it from text, or do we introduce a structured JSON envelope for "user-decision-needed" messages?

Leaning: structured JSON envelope as a sibling to `<c2c event="message" ...>`. Something like `<c2c event="decision" id="..." kind="permission" prompt="..." choices='[...]' reply_via="c2c_send" />`. But that's a breaking change for current permission-request producers; would need migration.

### Q6 — E2E encryption
Currently relay auth is Bearer-token / Ed25519 envelope signing. Messages are plaintext in relay storage. For the mobile app to be trustworthy in a hostile-ISP scenario, should we require E2E encryption of message bodies between sender identity and intended recipient identities? This is a bigger scope — separate sidequest? Or required for mobile?

Leaning: **defer** — current Ed25519 signing plus TLS to relay is acceptable for v1; E2E upgrade is a later phase.

### Q7 — Notifications provider
APNs direct + FCM direct (no middleman), or a proxy service (so the relay handles fanout)? Proxy is simpler for Flutter but is another service to run.

### Q8 — Offline behavior
If the phone is offline, does the relay:
- (a) drop messages.
- (b) queue for N minutes.
- (c) push to APNs/FCM so the OS wakes the app.

Recommends (c) + small short-queue fallback.

### Q9 — GUI parity scope
Is full parity required for v1, or is mobile v1 allowed to ship with a narrower feature set (observer + DM + prompt cards) while GUI keeps its full set?

### Q10 — Flutter vs React Native vs Tauri mobile
Max has specified Flutter. Confirming this is firm (vs Tauri-mobile which would share code with the existing GUI). Flutter gives better native feel but a fresh codebase; Tauri-mobile would be tighter parity but less mature on mobile.

### Q11 — Multi-user / multi-phone
One user paired multiple phones? Multiple users sharing one machine's oversight? Affects the relay identity → broker-scope mapping.

---

## 9. Risk notes

- Mobile store review (Apple especially) may balk at the "connect to my own server" pattern if the relay URL is user-provided. Might need a default relay binding with opt-in custom URL.
- Push notification setup is a multi-week cert + provisioning task that can't be faked — factor into M4 timeline.
- The Tauri GUI currently reads broker files directly. Lifting it onto a relay-client transport is non-trivial.

---

_Draft ends. Edit in-place as questions resolve._
