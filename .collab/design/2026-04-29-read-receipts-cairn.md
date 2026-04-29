# Read Receipts for c2c Messages — Design

Date: 2026-04-29
Author: cairn (subagent under coordinator1)
Status: design draft (no code yet)

## v1 Model (one line)

**A "drained" receipt is emitted to the sender when the recipient
drains a message from their live inbox; opt-out is per-recipient
(`c2c set-receipts off`) and per-message (`--no-receipts` / `receipts:
false`).**

## 1. Threat / UX Model

### Why agents want this
- "Did coordinator1 actually read my peer-PASS DM, or are they
  compacting?" — currently agents stare at `c2c list` for `compacting`
  flag and guess. A drained receipt is a strict improvement: it proves
  the message left the inbox and entered the recipient's transcript.
- Stale-binary / silent-drop debugging (#379, ghost-routing, etc.):
  receipts give end-to-end ack independent of MCP `send` returning OK.
- Coordinator load-balancing: which subagent has actually picked up
  a dispatch vs which is wedged.

### What "read" actually means in c2c
We do NOT have a way to know whether the agent's *model* attended to
the content. The honest signal we have is **"the broker handed this
message to the recipient's session via `drain_inbox` /
`drain_inbox_push`"**. That is the receipt v1 ships. It corresponds
roughly to "delivered to transcript" — same semantics as a Slack
"delivered to device" tick. We use the word *drained* internally to
avoid implying a stronger guarantee; the user-facing label is "read"
because that matches mental model from existing chat apps.

### Privacy / threat surface
- Receipts leak *liveness + activity timing* to the sender. A peer
  who DM-spams a quiet agent could fingerprint their wake schedule.
  Mitigated by per-recipient opt-out.
- Receipts do NOT leak content; they reference a message by `msg_id`.
- Local-only in v1. Cross-host receipts (relay) deferred — same
  rationale as cross-host ephemeral (#284).
- Reserved system aliases (`c2c`, `c2c-system`, `admin`) never emit
  receipts — they don't have inboxes worth tracking.

## 2. Envelope Shape

### Message gets a stable `msg_id`
Today `message` is `{from_alias; to_alias; content; deferrable;
reply_via; enc_status; ts; ephemeral}` (c2c_mcp.ml:54). Add:

```ocaml
type message = {
  ... ;
  msg_id : string ;      (* uuid-v4-ish, generated at enqueue *)
  receipts : bool ;      (* sender opt-in, default true *)
}
```

`msg_id` is generated in `enqueue_message` / `send_all` /
`fan_out_room_message`. JSON serialization of `message` adds the
field; older archive entries default `msg_id = ""` and `receipts =
false` on read (back-compat, same pattern as #387 `drained_by`).

### Receipt envelope (broker-internal, not user content)
A receipt is itself a message but with a system from-alias and a
machine-readable content body. Reusing the existing message
transport keeps storage / archive / drain semantics free.

```
from_alias = "c2c-receipts"   (new reserved system alias)
to_alias   = <original sender>
content    = <c2c event="receipt" msg_id="…" status="drained"
              by="<recipient_alias>" ts="…"/>
deferrable = true              (never wakes the sender)
ephemeral  = true              (never archived — receipts are a
                                live signal, not history)
receipts   = false             (no receipt-of-receipt; loop break)
```

Rationale for `ephemeral=true` on receipts: archived receipts would
double the archive size for no gain (the original message is already
archived; receipt is a transient state). Investigators who want
"was this message read" reconstruct it from a receipts index file
(see §4) rather than the message archive.

## 3. Opt-out Surface

Three layers, in order of precedence (most specific wins):

1. **Per-message** — sender side. CLI: `c2c send <a> <m>
   --no-receipts`. MCP: `mcp__c2c__send` with `receipts: false`.
   Sets `receipts = false` on the message; broker skips emission.
   Use case: "I don't care if you saw this."
2. **Per-recipient global** — recipient side, in their registration
   record. CLI: `c2c set-receipts off|on`. Adds
   `receipts_disabled: true` to `registration` (parallels `dnd`).
   Broker checks this before emitting; if disabled, drop silently
   (sender does NOT learn that receipts are off — that itself would
   be a fingerprint).
3. **Per-room** — rooms NEVER emit receipts in v1. Fan-out across
   N members → N receipts back to one sender on every drain ⇒
   notification storm. Room ack is a different feature (read
   cursors, §5). Documented as v1 limitation.

The recipient-global opt-out is the privacy-respecting default
escape hatch. The per-message opt-out is for senders who want to
be polite (ambient updates, sticker spam, low-stakes pings).

## 4. Broker Storage

### Two new files in broker root

`<root>/<session_id>.receipts.json` — per-session pending-receipt
queue. Lives next to `<session_id>.inbox.json`. Contents:

```json
[ { "msg_id": "…",
    "to_alias": "<original sender>",
    "by": "<recipient alias>",
    "ts": 1714... } ]
```

Written by `drain_inbox` *after* the message is removed from the
live inbox and (for non-ephemeral) appended to the archive. Drained
in a separate path — the receipt-emitter is a small post-drain hook
that, for each drained non-ephemeral message with `receipts=true`,
calls `enqueue_message` to the original sender with the receipt
content. The receipts.json file is mostly a crash-safety buffer:
if the broker dies between archive-write and receipt-emit, on
startup we re-process pending receipts. (Same pattern as the
relay outbox.)

`<root>/<session_id>.receipts-seen.json` — sender-side index:
which `msg_id`s have ever been ack'd to this session. Append-only,
capped (e.g. 10k most recent). Used by `c2c receipts <msg_id>` to
look up "was this read" without grepping archives. Optional in v1
— receipts can flow purely as messages and be observed in the
sender's transcript; the index is a UX nicety.

### Locking
Reuse `with_inbox_lock` keyed on `<session_id>.receipts` for the
receipts queue (separate flock file from the main inbox). Avoids
contention with normal sends.

## 5. Room Semantics (v1: no receipts; v2 sketch)

v1: `fan_out_room_message` hardcodes `receipts = false` on every
fanned-out copy. Receipts on a 50-person room would be a storm.
Doc note in `c2c_rooms.ml` and the rooms runbook.

v2 sketch (deferred): a room can have a single **read cursor**
per member (last drained `msg_id` for that room). `room_history
--cursors` shows "who has read up to where" — a Slack-style
cursor view, not per-message receipts. Storage:
`<root>/rooms/<room_id>.cursors.json`. Updated on drain when the
drained message has a `room_id` field. Out of scope for this
slice; mentioned to confirm the v1 design isn't a dead-end.

## 6. Slice Plan (3-4 commits)

### Slice A — schema + msg_id (1 commit)
- Add `msg_id : string` and `receipts : bool` to `message` record.
- Generate msg_id in `enqueue_message`, `send_all`,
  `fan_out_room_message` (rooms hardcode `receipts = false`).
- JSON in/out with default-on-missing for back-compat.
- Tests: roundtrip serialization, old-archive read, msg_id
  uniqueness across rapid sends.

### Slice B — receipt emission on drain (1 commit)
- Reserve `c2c-receipts` system alias.
- After `drain_inbox` archives non-ephemeral messages, walk the
  drained list and for each `receipts=true` enqueue a receipt
  message back to `from_alias`. Use `deferrable=true,
  ephemeral=true, receipts=false`.
- Crash-safety: write `<sid>.receipts.json` pre-emit, clear
  post-emit. Drain on broker startup.
- Tests: A sends to B with default → B drains → A gets receipt.
  Receipt has correct msg_id, `status="drained"`, `by="B"`. No
  receipt-of-receipt loop.

### Slice C — opt-out surfaces (1 commit)
- Per-message: `--no-receipts` CLI flag and `receipts: false` MCP
  field on `send`. Threaded through `enqueue_message`.
- Per-recipient: `receipts_disabled : bool` on registration
  (default false). CLI `c2c set-receipts off|on`. MCP
  `set_receipts` tool. Broker skips receipt-emit when disabled.
- Tests: --no-receipts message → no receipt. Disabled recipient
  → no receipt. Toggle on/off persists across restart.

### Slice D — sender-side query + docs (optional 4th)
- `c2c receipts <msg_id>` looks up receipts-seen index; returns
  `{drained_at, by}` or `null`.
- Update `docs/`: `commands.md`, `mcp-tools.md`, plus a short
  runbook `.collab/runbooks/read-receipts.md` covering opt-out
  layers and "receipts ≠ model attended."
- Wire `c2c install` to ensure the system alias is reserved.

Each slice commits independently to its own worktree per
`.collab/runbooks/git-workflow.md`; Slice A blocks B blocks C.
D is parallelizable with C.

## 7. Open Questions

1. **Receipt for `ephemeral=true` originals?** Likely no — ephemeral
   means "off the record"; receipts would re-introduce a paper trail.
   v1: ephemeral messages always have `receipts=false`. Confirm with
   Max.
2. **Cross-host (relay) receipts.** Currently remote sends go through
   `relay_connector.append_outbox_entry`. The relay receiver drains
   on the far broker — receipt-emission would need to ride the
   reverse outbox. Punt to v2; document explicitly.
3. **Receipt for `send_all` broadcasts.** A `send_all` produces N
   inboxes; do senders want N receipts or one aggregated? v1
   proposes N receipts (simplest, mirrors per-recipient drain).
   Consider adding a `--no-receipts` default for `send_all` in CLI
   to avoid surprising spam.
4. **Receipt expiry.** Pending-receipt queue could grow if a sender
   goes offline before their receipts drain. Cap queue size per
   session (e.g. 1k); drop oldest on overflow with a warning.
5. **MCP tool surface.** Add a dedicated `mcp__c2c__poll_receipts`
   tool, or fold receipts into the normal `poll_inbox` stream as
   `<c2c event="receipt">` elements? Folding is simpler and uses
   existing wake paths. Decision: fold. Receipts arrive as ordinary
   inbox messages from `c2c-receipts` and the agent's harness can
   pattern-match the envelope.
6. **Default on or off?** Proposal: **on** for DMs, **off** for
   rooms (hardcoded), **off** for ephemeral. Inverts to off-by-
   default if Max prefers privacy bias. Polish-pass per first
   week of dogfooding.

## 8. Non-goals (v1)

- "Typing…" indicators. (No keystroke stream to observe.)
- Cross-host / relay receipts.
- Per-room read cursors (v2 sketch only).
- Receipt-of-receipt or chained acknowledgement.
- Cryptographic non-repudiation. Receipts are advisory; the
  recipient could theoretically replay-drop them by tampering
  with their own broker state, but in v1 the broker is shared
  trust ground anyway.

## 9. Touched files (anticipated)

- `ocaml/c2c_mcp.ml` — `message` record, enqueue/drain, receipts
  queue, registration field.
- `ocaml/cli/c2c.ml` — `--no-receipts` flag on `send`,
  `c2c set-receipts` subcommand, `c2c receipts <msg_id>`.
- `ocaml/c2c_mcp.ml` MCP tool dispatch — `receipts` arg on `send`,
  new `set_receipts` tool.
- `ocaml/test/test_c2c_mcp.ml` — coverage per slice.
- `docs/commands.md`, `docs/mcp-tools.md` — surface docs.
- `.collab/runbooks/read-receipts.md` — operator guide.
