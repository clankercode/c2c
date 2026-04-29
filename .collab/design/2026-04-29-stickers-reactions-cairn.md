# Design: `c2c sticker react` — emoji reactions on messages

- author: cairn (UX subagent)
- date: 2026-04-29
- status: design — proposal, not implemented
- companion: existing `c2c sticker {list,send,wall,verify}` (signed appreciation tokens)

## 1. Current state

`c2c sticker` already exists and ships **signed appreciation tokens**, not
reactions:

- Sources: `ocaml/cli/c2c_stickers.ml` (~396 LOC), `ocaml/cli/c2c_stickers.mli`.
- Subcommands today: `list`, `send <peer> <sticker-id> [--note] [--scope]`,
  `wall [--alias] [--scope] [--json]`, `verify <file>`.
- Storage: `.c2c/stickers/<alias>/{received,sent}/*.json` (private) and
  `.c2c/stickers/public/*.json` (public).
- Identity: each envelope is Ed25519-signed with the sender's per-alias key
  (`<broker>/keys/<alias>.ed25519`); canonical blob is
  `from|to|sticker_id|note|scope|ts|nonce`.
- Closed-set kinds in `.c2c/stickers/registry.json` (9 entries today:
  solid-work, brilliant, helpful, clean-fix, save, insight, on-point,
  good-catch, first-slice).
- **Crucially: a sticker today is addressed to a peer alias, NOT to a
  message.** It is "thanks for being you" recognition, not "I acknowledge
  *this* DM". There is no `target_message_id` field in the envelope.

So the substrate is excellent (signed, replayable, scoped, registry-keyed)
but the surface is missing the message-anchored reaction case — which is
the lightweight inter-agent ack the task is asking for.

Adjacent: messages already carry a `message_id` at the relay layer
(`ocaml/relay.ml:230` and friends — used for de-dup). That's the natural
anchor for reactions.

Today, agents who want to ack a DM either send a full text DM ("ack 👍") or
nothing. There's no in-between, and "nothing" is the dominant failure mode
because text-DM-just-to-ack feels like noise.

## 2. Proposed model (v1)

**Add `c2c sticker react <msg-id> <sticker-id> [--note]` as a new verb in
the existing `sticker` group.** Reuse the envelope format with one new
field; reuse the registry; reuse signing.

### 2.1 Envelope extension

Add `target_msg_id : string option` to `sticker_envelope` (default `None`
for legacy peer-addressed stickers). Canonical blob becomes:

    from|to|sticker_id|note|scope|ts|nonce|target_msg_id_or_empty

A reaction is a sticker with `target_msg_id = Some <id>` and `to_` set to
the original message's sender. A peer-addressed sticker is a sticker with
`target_msg_id = None`. Same code path, same wall view, same verify.

### 2.2 Delivery: push, not pull

A reaction IS a DM under the hood — `Broker.enqueue_message` to the original
sender, with body XML:

    <c2c event="reaction" from="cairn" alias="cairn" target="<msg-id>" sticker="brilliant" emoji="✨"/>

The recipient's MCP client renders this in transcript as a one-liner:
`✨ cairn reacted to <msg-id-short>` rather than as a full message. The
envelope JSON is *also* archived to `.c2c/stickers/<recipient>/received/`
so `c2c sticker wall` shows it. This is the only delivery path — no
separate "reaction stream" channel. Push is the right default because
reactions are time-sensitive ("did anyone see my DM?") and the body is
tiny so the ordering noise is acceptable.

`deferrable=true` is **not** appropriate here despite the small payload —
the whole point is the original sender sees the ack soon. (Cross-ref the
`deferrable` rule in CLAUDE.md.)

### 2.3 Storage

Reactions live alongside other stickers in `.c2c/stickers/<alias>/...`. Add
one denormalised index: `.c2c/stickers/<alias>/by-msg/<msg-id>.json`
(append-only list of pointers to envelope files), so `c2c sticker reactions
<msg-id>` is O(1) instead of scanning the wall. The index is regenerable
from the envelopes — never the source of truth.

### 2.4 Where do the message IDs come from?

Two surfaces:

1. **Inbox display already knows them** — `poll_inbox` returns envelopes
   that include the relay `message_id`. Render them next to each message
   so the operator can copy-paste. Today the MCP tool returns them but the
   CLI inbox view drops them; small change to `c2c poll-inbox` /
   `peek-inbox` to surface a short form (first 8 chars of the id).
2. **`c2c inbox last <peer>` shortcut** — react to the most recent message
   from a peer without typing the id. Implemented as a thin wrapper over
   the local archive (`.c2c/archive/<self>/inbound.jsonl` or wherever the
   archive lives — verify before coding).

### 2.5 What does `sticker react` add over text DM with one emoji?

| Concern | Text DM "👍" | `sticker react` |
|---|---|---|
| Anchored to a specific message | No (operator infers from context) | Yes, by `target_msg_id` |
| Renders inline / non-noisy | No (full transcript message) | Yes (one-liner / counter) |
| Aggregatable across many reactors | No | Yes (`reactions` index) |
| Signed + auditable | Inherits relay sig | Yes, Ed25519 envelope |
| Counts toward "appreciation wall" | No | Yes (reuses `sticker wall`) |
| Cheap to send mid-flow | Costs an LLM turn to compose | Single tool call with two args |

The win that matters most: **anchored + aggregatable**. Three peers all
reacting `🎯` to the same coord sitrep is one signal; three peers all
texting "agreed" is three messages the coord has to read.

## 3. Sample sessions

### 3.1 Reacting to a DM you just received

    $ c2c poll-inbox
    [a3f7c2..] from coordinator1: "ack — push deferred until lunch window"
    [b81e9d..] from stanza-coder: "PR #427 ready for peer-PASS, sha 9df9a5b"

    $ c2c sticker react a3f7c2 on-point
    Reacted 🎯 to coordinator1's message a3f7c2..

### 3.2 Coordinator sees aggregate

    $ c2c sticker reactions a3f7c2  # on coord1's session
    🎯 cairn          2026-04-29T14:02:11Z
    🤝 stanza-coder   2026-04-29T14:02:38Z
    🪨 jungle         2026-04-29T14:03:01Z

### 3.3 In a room

    [swarm-lounge] cairn: design landed at .collab/design/...stickers...md
    $ c2c sticker react --room swarm-lounge --last brilliant
    Reacted ✨ to cairn's last room message in swarm-lounge

Room reactions broadcast as room events to all members (re-using
`fan_out_room_message` with a reaction body), so the room transcript shows
`✨ stanza-coder reacted to cairn's design link`.

### 3.4 MCP tool

`mcp__c2c__sticker_react { target_msg_id, sticker_id, note? }` — same
shape, no `to_` (derived from the target message's sender). Falls back to
`mcp__c2c__send` with structured body if the recipient broker is older.

## 4. Slice plan (4 commits)

Each commit is a worktree (`.worktrees/sticker-react-<slice>/`), peer-PASS
between slices.

1. **Schema + envelope extension.** Add `target_msg_id : string option`
   to `sticker_envelope`, update canonical blob (with empty-string
   sentinel for back-compat), update `envelope_of_json` /
   `json_of_envelope`, update `verify_envelope` golden tests with old +
   new envelopes both verifying. Pure data-layer commit; no CLI surface
   change yet.

2. **CLI `sticker react` + `sticker reactions`.** Wire two new
   subcommands. `react` resolves the target message from the local
   archive (errors clearly if not found — "did you poll-inbox? id may
   have aged out"), constructs the envelope, *also* enqueues a DM to the
   target sender via `Broker.enqueue_message` with the reaction XML
   body. `reactions <msg-id>` reads `by-msg/<id>.json` index. Includes
   integration test using `C2C_REGISTRY_PATH` + an in-process broker.

3. **MCP surface + inbox-id surfacing.** Add `mcp__c2c__sticker_react`
   tool. Update `c2c poll-inbox` / `peek-inbox` text rendering to show
   `[<msg-id-8>]` prefix. Add `--last` shorthand for `react`. Doctor a
   small E2E in tmux: cairn DMs jungle, jungle reacts, cairn sees the
   reaction inline in their next poll.

4. **Room reactions.** `sticker react --room <id> --last` + render in
   room transcripts. `room_history` annotates messages with their
   reactions inline. This slice is optional v1; ship if (3) lands clean
   under budget, otherwise punt to v1.1.

Stop conditions per slice: build clean in worktree (rc captured per #427
Pattern 8), `just test` green, peer-PASS DM with SHA.

## 5. Open questions

1. **Does the original sender's broker need to know about reactions, or
   just their session?** v1 says "just the session via DM"; if a sender
   was offline when a reaction came in, they see it on next poll like
   any other DM — fine. But aggregating across sessions of the same
   alias (multi-instance same agent) means we should write to the
   sender's archive, not just push.

2. **Cross-host reactions (post #379).** A reaction to a cross-host
   message should round-trip the relay like any other DM. The
   `target_msg_id` is the relay-assigned id, so it's already globally
   unique. **Risk**: if a host doesn't recognize the reaction event
   tag, it should dead-letter (consistent with #379's send rejection
   behaviour) rather than silently drop. Add a relay capability bit
   `supports_reactions=true` and degrade to "fall back to text DM
   `<sticker_id>`" for older relays.

3. **Should reactions ever be unreact-able?** Slack lets you remove
   reactions. v1 says no — every reaction is signed and append-only,
   matching the existing sticker-wall semantics. If you misreact, send
   a clarifying DM. (We can add `unreact` later as a tombstone envelope
   that the index honours; do not bake it into v1.)

4. **Open set vs closed set for reactions.** Today's sticker registry
   has 9 entries, all positive. Reactions naturally want a wider
   palette (`👀` "looking", `🚧` "WIP", `❌` "no", `❓` "confused").
   Proposal: keep closed set, but **double the registry** with a
   `reaction_kind` flag — entries marked `reaction:true` are valid
   targets for `react`, entries marked `appreciation:true` are valid
   for `send`, some can be both. This keeps "stickers as currency"
   semantics intact while making reactions expressive.

5. **Rate limits.** Should an agent be able to react 50 times in a
   minute? Probably cap at, say, 1 reaction per (target_msg_id,
   sticker_id, sender) — already enforced trivially by treating the
   tuple as primary key in the by-msg index. Multiple *different*
   reactions from the same sender on the same message: allowed (Slack
   parity).

6. **Sticker name collision with reactions UI.** Some operators may
   read `c2c sticker react` and assume reactions are a separate
   feature; consider aliasing `c2c react` as a top-level shortcut for
   `c2c sticker react` (no semantic difference, just discoverability).

## 6. Recommendation

**v1 model:** A reaction is a sticker with `target_msg_id` set; delivered
as a tiny DM with a `<c2c event="reaction" .../>` body; archived in the
existing sticker store; aggregated via a regenerable per-message index.
Single new envelope field, four-commit slice plan, reuses every piece of
crypto + storage we already have.

---

## Subagent stub (done)

- status: DONE
- output: this file
- in-progress marker: `.collab/research/SUBAGENT-IN-PROGRESS-stickers-design.md`
  (can be removed by caller; left as audit trail of dispatch)
