# #142 PreToolUse approval — side-channel design

- **Author:** stanza-coder
- **Date:** 2026-04-30
- **Status:** DESIGN — drafted in response to e2e dogfood finding;
  awaits coordinator routing for multi-slice scoping
- **Cross-references:**
  - #142 (parent: kimi parity, tool/command permissions forwarded —
    structurally complete on master, functionally incomplete)
  - Slice 1 (`985b05b7` + `674b6230`) — bash hook + `c2c await-reply` CLI
  - Slice 2 (`439765ec`) — `c2c install kimi` writes [[hooks]] block + script
  - Slice 3 (`e0ebce1c`) — `--afk` → `--yolo` + state.json seed flip
  - Slice 4 (`6e29e4eb`) — Claude Code parity via sentinel matcher
  - #489 fix (`f3967e28`) — kimi agent.yaml path regression
  - **e2e finding `b2fe3dd9`** — composite drain-race + TUI-queue mismatch
  - #483 (Cairn's design framing for #142 hooks-as-sole-gate)
  - #484 (Cairn's MCP-strengthening follow-up to text-based token)

## Problem statement

The #142 e2e dogfood (kimi PreToolUse approval round-trip) is
**structurally complete** on master but **functionally broken** in
production due to two architectural mismatches surfaced by Test 1:

### Bug 1 — Drain race

`c2c await-reply` (slice 1) polls the recipient kimi's broker inbox
JSON every 1s using `Broker.read_inbox` (non-draining peek). Looking
for a message containing `<TOKEN> allow` or `<TOKEN> deny`.

When the reviewer DMs the kimi (`c2c send kuura-viima "<TOKEN> allow"`),
the broker enqueues the message in kuura's inbox JSON. The
`c2c_kimi_notifier` daemon detects the new file content (via inotify),
sends a `[c2c] check inbox` tmux nudge to kuura's pane. Kuura's
kimi-cli sees the nudge as user input and calls `mcp__c2c__poll_inbox`
which DRAINS kuura's inbox to deliver to her notification store /
TUI.

**Race**: nudge → poll_inbox → drain happens in <100ms. await-reply's
poll interval is 1s. await-reply finds an empty inbox on its next
poll. Hook fall-closes after timeout (default 60-120s).

Verified via inbox archive (`.git/c2c/mcp/archive/kuura-viima.jsonl`):
```
{"drained_at":1777491690.78,"drained_by":"unknown",
 "from_alias":"stanza-coder","to_alias":"kuura-viima",
 "content":"ka_tool_uQApmQcQlM3U8h9KSSxtD3EF allow"}
```

The `drained_by:"unknown"` is because the drain came through a code
path that didn't tag itself (likely the notifier's drain branch);
poll_inbox-via-MCP would tag `drained_by:"poll_inbox"`.

### Bug 2 — TUI input queueing

The notifier daemon's tmux send-keys delivery puts the verdict
message text into kuura's kimi-cli **input box** as queued user
input. Pane peek confirms `· N queued` lines accumulating with
the approval DMs.

Even if await-reply caught the message in the inbox file, the message
ALSO sits in kuura's input queue waiting for her current turn to
finish. When her turn ends, kimi-cli processes the queued input as
a NEW user instruction. So `<TOKEN> allow` becomes a user prompt
("the user is telling me ka_tool_X allow"), which is semantically
wrong — kuura would interpret it as an instruction, not as an
out-of-band approval verdict.

This is independent of bug 1: even with a fix to bug 1, bug 2 makes
approval DMs poison the user-input stream.

### Composite

Both bugs share a root cause: **the approval verdict travels through
the same channel as normal DMs** (broker inbox + notifier delivery).
The system can't distinguish "approval verdict for hook" from "user
DM to recipient agent". They get processed identically, neither
correctly for the approval use case.

## Why the existing surfaces won't fit

### Why not just lengthen await-reply's timeout?

Doesn't help. Once the inbox is drained (<100ms after arrival),
await-reply will NEVER see the message in the inbox file again, no
matter how long it polls. The window is between "message lands" and
"poll_inbox drains" — measured in milliseconds. await-reply's poll
interval (1s default) is orders of magnitude wider.

### Why not have await-reply also read the archive?

Possible but fragile. The archive is intended as a historical record,
not a live-read API. await-reply would have to:
- Parse the JSONL archive on every poll (growing file → growing
  parse cost).
- Disambiguate "verdict for THIS hook invocation" from "verdict from
  a previous hook with the same token by accident" — solvable via
  tool_call_id-based tokens (which is what slice 1 uses) but adds
  fragility.
- Race resolution: archive write happens AFTER drain; small window
  where the message has been drained from inbox but not yet appended
  to archive. await-reply sees neither.

### Why not change `read_inbox` to also drain?

Would let await-reply consume the verdict before the notifier does.
But:
- `read_inbox` is shared infrastructure; changing semantics would
  break other callers.
- Doesn't fix bug 2 (TUI input queueing) — verdict text still gets
  pushed to operator's input stream by the notifier.
- Reverses the "non-draining peek" property that other use cases
  rely on.

### Why not have the notifier filter approval-token messages?

This is the cleanest band-aid for bug 1, but doesn't fix bug 2
unless the notifier ALSO suppresses the tmux send-keys for approval
messages. And we'd still be sending the message text through the
broker DM path, which means it lives in the message archive +
recipient's history alongside normal DMs. Keeping operator
attention separate from approval audit is desirable.

## Design proposals

Three options ranked by isolation strength:

### Option A — File-based side-channel (RECOMMENDED)

Hook script writes pending-approval state to a dedicated path:
```
~/.c2c/<repo-fingerprint>/approval-pending/<token>.json
```

with content like:
```json
{
  "token": "ka_tool_<id>",
  "agent_alias": "kuura-viima",
  "tool_name": "Shell",
  "tool_input": {...},
  "timeout_at": <epoch>,
  "reviewer_alias": "stanza-coder"
}
```

Reviewer replies via a NEW dedicated CLI subcommand:
```bash
c2c approval-reply <token> {allow|deny [reason...]}
```

This subcommand atomically writes:
```
~/.c2c/<repo-fingerprint>/approval-verdict/<token>.json
```

with content:
```json
{
  "token": "ka_tool_<id>",
  "verdict": "allow" | "deny",
  "reason": "<text>",
  "reviewer_alias": "stanza-coder",
  "ts": <epoch>
}
```

await-reply watches the verdict file (inotify on the directory) +
falls back to polling on platforms without inotify. On verdict file
appearance: read, validate token match, print verdict, exit.

The DM the reviewer SEES (in the kimi-approval format) is still
sent via normal c2c send for human awareness, but the actionable
verdict goes through the side-channel.

**Pros:**
- Complete isolation from broker inbox + notifier delivery
- File-based: portable, simple, no broker schema changes
- await-reply's logic stays simple (watch one file)
- Reviewer's UX has a dedicated verb (`c2c approval-reply`), reduces
  ambiguity vs. raw DM
- Audit trail: verdict files persist; can be archived for record

**Cons:**
- Requires new CLI subcommand (`c2c approval-reply`)
- Two write paths (hook side: pending; reviewer side: verdict) — needs
  cleanup discipline (delete after consumption + TTL on stale)
- Reviewer must remember to use `c2c approval-reply` instead of `c2c send`

**Slicing:**
- Slice 5a: c2c approval-pending writer (hook script side) +
  approval-reply reader update for await-reply
- Slice 5b: `c2c approval-reply` CLI subcommand
- Slice 5c: notifier filter to skip approval-* messages OR remove the
  human-awareness DM entirely (operator can `c2c approval-list` to
  see pending)
- Slice 5d: cleanup logic (TTL + post-consumption delete)
- Slice 5e: re-run e2e dogfood; close #142 + #145

### Option B — Broker-side flag on inbox messages

Extend the message envelope schema with an `approval_token` field.
When set, the message:
- Is enqueued to broker inbox normally
- Is SKIPPED by `mcp__c2c__poll_inbox` (stays in inbox file)
- Is NOT delivered by notifier daemon's tmux send-keys path
- Is consumable by `c2c await-reply --token <T>` which atomically
  removes-by-token after match

Reviewer side:
```bash
c2c send <recipient> "ka_tool_X allow" --approval-token ka_tool_X
```

(or auto-detect by content prefix if reviewer omits the flag)

**Pros:**
- Keeps the broker as single source of truth
- Reuses existing `c2c send` UX
- Simpler than separate side-channel files
- Explicit schema field — debuggable

**Cons:**
- Broker schema change → relay impact (alias=/to= rename territory,
  cross-ref #485)
- Adds branching logic in poll_inbox (skip-if-approval) — easy to
  miss in test coverage
- Notifier daemon needs the same skip-if-approval logic — TWO places
  to keep in sync
- Race window: between broker enqueue and the skip-checks running, a
  poll_inbox could still drain. Needs explicit ordering guarantees.

**Slicing**: similar to Option A but more cross-cutting through broker code.

### Option C — Dedicated MCP tool

New broker MCP tool: `mcp__c2c__check_approval_reply` that:
- Takes `token: <T>`
- Reads broker inbox + archive looking for `<T> {allow|deny}`
- Returns verdict on match + atomically removes from both
- Returns nothing on no-match

Hook script calls this instead of `c2c await-reply`.

**Pros:**
- MCP-native, fits existing tooling pattern
- Atomic match-and-remove via broker
- No new file paths

**Cons:**
- Requires hook script to be MCP-aware (currently uses `c2c await-reply`
  CLI which is broker-aware but not MCP-protocol-aware)
- Doesn't solve bug 2 unless poll_inbox + notifier skip approval
  messages (which they wouldn't, by default)
- Adds a tool to the c2c MCP surface — drift risk with tool-list
  centralization (#137 / #479)

## Recommendation

**Option A**, with these refinements:

1. Slice incremental:
   - Slice 5a (small): introduce `c2c approval-reply` CLI; hook
     script writes pending file at hook fire; await-reply switches
     to reading verdict file. **No broker schema changes.**
   - Slice 5b (small): notifier ALSO filters approval-token DMs
     (defense-in-depth — if reviewer sends raw DM by habit, notifier
     doesn't push it to TUI).
   - Slice 5c (small): cleanup TTL on pending/verdict files.
   - Slice 5d (test): re-run e2e dogfood per
     `2026-04-30-stanza-coder-142-e2e-dogfood-design.md`.

2. Reviewer-side compat: still allow `c2c send <recipient> "<TOKEN> allow"`
   via the canonical hook DM body's "Reply with" hint. The hook DM
   to reviewer can offer BOTH:
   ```
   Reply with:
     c2c approval-reply <TOKEN> allow
     c2c send <kimi-alias> "<TOKEN> allow"  (legacy, may be drained)
   ```
   Document the dedicated path as preferred; legacy still works for
   MCP-only flows where `c2c approval-reply` isn't available.

3. Audit trail: persist consumed verdicts to a per-repo log
   (`~/.c2c/<repo-fp>/approval-log.jsonl`) so reviewers can audit
   "what did I approve" historically, separate from the noisy DM
   archive.

## Cross-cutting concerns

- **Multi-reviewer**: out of scope for v1; one reviewer per hook
  fire. Future work: weighted-quorum, fallback chain, etc.
- **Cross-host approval**: today the verdict files live in the
  recipient's broker root. For relay/cross-host, the verdict needs
  to traverse the relay. The same way DMs do. v1 is local-only;
  cross-host is a follow-up.
- **Hash-based idempotency** (lumi's #483 Phase B note): in v1,
  tokens are tool_call_id-based (kimi mints unique IDs). For
  Claude Code, tool_call_id may not be stable; need to verify or
  fall back to hash-based.
- **TTL** (Phase C territory): pending files older than
  C2C_KIMI_APPROVAL_TIMEOUT can be GC'd. Verdict files older than
  e.g. 1h after consumption can also be GC'd.

## Operator UX

When operator has a pending approval, the hint they see is:
```
[kimi-approval] PreToolUse:
  tool: Shell
  args: {"command":"rm -rf /tmp/foo","timeout":60}
  token: ka_tool_<id>
  timeout: 60s

Approve via:
  c2c approval-reply ka_tool_<id> allow
  c2c approval-reply ka_tool_<id> deny because <reason>
```

(Note: `c2c approval-reply` instead of the slice-1 raw `c2c send`.)

For maximum operator-friendliness, also:
- `c2c approval-list` — show all pending approvals across all kimis
  in this repo
- `c2c approval-show <token>` — print the full input + tool details
  for a token (in case the operator dropped the original DM)

These are slice-5b/5c territory; not load-bearing for the basic flow.

## Implementation notes

- `c2c approval-reply <token> <verdict>` takes the token as an exact
  match (case-insensitive), validates verdict is `allow` or `deny`
  (with optional `because <reason>` suffix on deny), atomically
  writes the verdict file via temp + rename.
- Hook script writes the pending file BEFORE sending the awareness
  DM, so reviewer can `approval-reply` even before seeing the DM
  (e.g. via `c2c approval-list` polling).
- await-reply reads the verdict file, validates the verdict,
  optionally validates reviewer alias matches expected, then
  prints + exits.
- File ownership / permissions: per-user `~/.c2c/...` (no shared
  multi-user broker yet), 0600 file mode (auth-by-filesystem).

## Test plan addendum

Once Option A lands, re-run the e2e per the original design doc
(`2026-04-30-stanza-coder-142-e2e-dogfood-design.md`):
- Test 1 (allow): verdict file appears → await-reply reads → hook
  exit 0 → tool proceeds.
- Test 2 (deny): same shape, verdict=deny → hook exit 2 with reason
  in stderr.
- Test 3 (timeout): no verdict file ever → await-reply timeout → hook
  fall-closed.
- Test 4 (Claude parity): same flow from Claude Code session.
- Test 5 (token uniqueness): two hooks fire concurrently, two
  pending files, two verdict files, no cross-talk.

Plus new tests Option A enables:
- Test 6: `c2c approval-list` shows pending; `c2c approval-show <T>`
  shows details.
- Test 7: TTL cleanup removes stale pending after timeout.

## Open questions

- Do we want the verdict file write to be reviewer-authenticated
  (signed)? For local-only v1, filesystem perms are sufficient.
  For cross-host, signing matters.
- Should `c2c approval-reply` be MCP-callable too (so peer agents
  can reply via MCP, not just CLI)? Probably yes — symmetric with
  send.
- Cleanup ordering: hook process owns the pending file? Or shared
  ownership? If hook crashes, who cleans up the pending file? TTL
  is the simple answer.

## Closeout for #142

After Option A lands + e2e validates green:
- Mark TaskList #142 completed
- Mark TaskList #145 (3rd kimi tyttö e2e dogfood) completed
- Write `.collab/runbooks/142-e2e-approval-test.md` as the canonical
  playbook
- File the deprecation note for the slice-1 raw-DM verdict path (
  keep working but document as "best-effort, use approval-reply for
  reliability")

---

🪨 — stanza-coder, e2e-dogfood-derived design proposal
