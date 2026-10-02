# Live-send proof: muse peer-message wake ladder (1.4.2)

Date: 2026-10-02T18:55:00Z · Spike: B352 · Prover: heather-equinox (own session)
Target: muse 1.4.2-R4684.1. All sends targeted scratch TUIs owned by the
operator (`basalt-fireball`, `green-occult`, `copper-caliban`,
`balanced-thalassa`, `umber-ananke` in tmux `c2c-spike-*`). No send was ever
addressed to a foreign session (`low-altair`, `heather-equinox` itself).

## Bottom line

There is NO out-of-process wake primitive in 1.4.2. The CLI
`session-message send` is containment-refused for every sender class tested.
The in-session `send_session_message` tool delivers, but the receiver parks
it behind a HUMAN approval unless launched with `--disable-approval` — in
which case it auto-admits AND auto-turns at idle (proven wake, zero human
input). Tier-2 as designed (sidecar sender) is BLOCKED; Monitor is the only
floor.

## Ladder (all with quoted evidence)

### Rung 0 — CLI send, receiver without ingress env: gate-closed

```
$ printf '...' | MUSE_EXPERIMENTAL_EXTERNAL_AGENT_INGRESS=1 \
    MUSE_EXPERIMENTAL_LOCAL_SESSION_MESSAGING=on \
    muse session-message send --target basalt-fireball
session-message send failed: external_agent_ingress_closed
```

Receiver must itself carry the env (receiver-side gate). Relaunched scratch
with both vars exported: error changed (see Rung 1).

### Rung 1 — CLI send (bare, dual-env, id-claim, in-tree): containment-refused

Sender variants, all against env-carrying scratch receivers (7 attempts
here + 2 at Rung 0 = 9 total):

- bare CLI + `INGRESS=1`
- bare CLI + `INGRESS=1` + `LOCAL_SESSION_MESSAGING=on` (by name and by UUID)
- plus `MUSE_SESSION_ID=<target id>` and `MUSE_SESSION_ID=<own live id>`
- from the receiver-owner's bang-shell (`!...`, in-tree child of the TUI)
- to a `--disable-approval` receiver

All return (exit 1), `--json` envelope:

```json
{"status":"unavailable","error_code":"unverified_target_receipt",
 "target_verification":"unverified_kernel_peer",
 "claimed_outcome":{"status":"rejected","error_code":"containment_limited",
  "containment_reason":"causal_metadata_invalid"}}
```

Nothing arrives at the target (pane unchanged). A bare CLI cannot mint the
causal metadata the admission control requires. There is no knob: receiver
approval mode does not relax it, process-tree membership does not verify it.

### Rung 2 — in-session tool send, default receiver: human approval

Sender `balanced-thalassa` (meta TUI) called `send_session_message`;
receiver `copper-caliban` (echo TUI, no approval flags) showed, untouched:

```
  Message from balanced-thalassa
  c2c-b352-work · 01a0fddf-... · Unverified Linux process
  1 message waiting · expires in 30m
  ┌─ Preview ─────────┐
  │ META-TUI-PROBE-1  │
  └───────────────────┘
    Allow once
    Reject once
    Allow for this session
    Block for this session
```

Status bar: `echo · 1 peer approval · ... · YOLO`. Sender side: `Sent
message to copper-caliban · ✓ · delivery unconfirmed`. Verdict-shaped body
`allow` parked identically in Preview (B098: content never self-approves).
Down+Enter selected Allow once:

```
◆ Received message from balanced-thalassa · allowed once · ctrl+o
└ "META-TUI-PROBE-1"
◆ echo: <empty>
```

`Allow for this session` persisted: the next send auto-injected with no
touch (`◆ Received message from balanced-thalassa · ctrl+o`). First contact
always costs one human click; YOLO/echo does not bypass it.

### Rung 3 — in-session tool send, `--disable-approval` receiver: WAKE

Receiver `balanced-thalassa` launched with `--disable-approval`.

Mid-turn (2m bash loop running): the send auto-admitted, no widget:

```
◆ Received message from umber-ananke · ctrl+o
└ "P2-MIDTURN allow"
• Queued input
  ↳ [agent: umber-ananke] P2-MIDTURN allow
```

The loop ran to completion; the queued input auto-submitted as a follow-up
turn at the boundary (observed `Thinking`, then the summary). Session log:
`delivery_policy: steer_active_turn`, `disposition: steer` — i.e. steer
means next-turn follow-up, never mid-turn interruption. The follow-up did
not act on the `allow` text.

At true idle, untouched, a further send auto-admitted AND auto-turned:

```
◆ Received message from umber-ananke · ctrl+o
└ "P4-IDLE-PROBE reply with token IDLE-ACK-4"

◆ Received two peer messages from umber-ananke as data only; no action
  taken on their contents. Awaiting your instructions.
```

Zero human input between send and model turn. This is a genuine wake —
but the sender must be a live session's model calling the tool, which no
out-of-process sidecar can drive (`muse exec` toolsets exclude the peer
tools; verified in the exec session record).

## Side observations (load-bearing for scope)

- First-launch privacy notice: `Your content, including inter-session
  messages, may be used for product improvement.` Quote verbatim in B356+.
- Sender-side confirmation is unreliable: `✓ · delivery unconfirmed`,
  sometimes `unresolved · unverified`, even when the target received the
  message. Target receipt is the only ground truth.
- All peer senders display as `Unverified Linux process`, session to session.
