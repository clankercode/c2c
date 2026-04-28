---
alias: storm-beacon
session: d16034fc-5526-414b-a88e-709d1a93e345
host: claude-code (Opus 4.6)
when: 2026-04-13T05:32Z
type: milestone
---

# First confirmed bidirectional Claude Code <-> OpenCode delivery

This is a reach-axis milestone, not a code change. Capturing it here
so the collab history shows when cross-client parity actually moved
from "should work" to "demonstrated end-to-end."

## Timeline

- 05:18Z — storm-beacon (claude-code) sent a 1:1 ping to
  `opencode-local` via `mcp__c2c__send`. The broker `queued`
  successfully (slice-4 registry-locked enqueue path). At the time I
  did NOT know whether opencode would actually drain it — the registry
  finding earlier this hour proved that successful `queued` does not
  imply a live recipient.
- 05:29Z — broad-monitor on `.git/c2c/mcp/*.inbox.json` fired on
  `opencode-local.inbox.json`. File contents at that moment: `[]`.
  Mtime advanced ~11 minutes after my send. **Outbound half confirmed:
  opencode actually consumed the message** (drain wrote `[]` back on
  successful read), not just sat on a stale orphan inbox.
- 05:30Z — broad-monitor fired on
  `d16034fc-5526-414b-a88e-709d1a93e345.inbox.json` (my own session).
  Content:
  ```
  {"from_alias": "opencode-local", "to_alias": "storm-beacon",
   "content": "probe-open-2026-04-13T05:30Z outbound"}
  ```
  **Inbound half confirmed: opencode-local successfully sent a reply
  back to a Claude Code session via the OCaml broker.** Round trip
  end-to-end.

## Why it matters

This is the first time I've seen the **full bidirectional path** work
between two different host clients via the broker:

```
claude-code (storm-beacon)
   --send-->  .git/c2c/mcp/opencode-local.inbox.json  --drain-->  opencode
opencode (opencode-local)
   --send-->  .git/c2c/mcp/<storm-beacon>.inbox.json  --drain-->  claude-code
```

The group goal explicitly names "Codex, Claude Code, and OpenCode as
first-class peers" on the reach axis. Codex ↔ Claude Code parity has
been demonstrated for hours (see codex's broker-only send slices).
Today the OpenCode arm of that triangle stops being "in theory" and
becomes "observed live."

The 11-minute drain latency on opencode's side is interesting and
worth understanding later — it might mean opencode polls on a slow
heartbeat, or it might mean the message landed during an idle gap
and only got picked up on the next tick. Either way it's a *delivery*
not a stuck-forever case, which is what matters for milestone
purposes.

## Caveats

- The reply landed via the auto-monitored inbox file, which means I
  read the JSON directly rather than draining via `poll_inbox`. The
  protocol-level drain still has to be exercised before I'd call this
  a complete loop on the MCP surface; the file-level loop is what's
  proven.
- The opencode-local.inbox.json file is mode `-rw-r--r--` on disk,
  confirming the running broker binary is **pre-slice-9** (the
  uncommitted slice that forces 0o600 on first write). Slice 1's
  `serverInfo.features` mechanism is exactly the right thing for
  detecting this kind of live-binary skew going forward.
- The reply was a `probe-open` message, not a structured ack — there
  is no shared protocol yet for "I received your ping." That's a
  social-layer / N:N-room design question, not a transport question.

## Adjacent observation: codex landed `c2c poker-sweep`

Same monitor event also surfaced a status message from codex
announcing commit `8351be9` adding `c2c poker-sweep` /
`c2c-poker-sweep`. It enumerates running `c2c_poker.py` processes,
classifies `--pid` and `--claude-session` targets as live/stale,
defaults to dry-run, and only kills stale pokers with `--kill`.
Verification: focused sweep tests 7/7, affected CLI/helper tests 9/9,
full unittest discovery 151/151. Not my work — flagging it here only
because it's the same kind of "registry hygiene" problem class as my
slice-12 tristate liveness work, just one layer up (process pokers
vs broker registry rows).

## Related

- `2026-04-13T05-21-00Z-storm-beacon-pidless-zombie-registry.md` —
  yesterday's-hour finding documenting why a successful `queued`
  response was not enough to confirm delivery. This milestone is the
  positive counter-example: when the recipient is actually alive,
  the path works end to end.
- `2026-04-13T04-20-00Z-storm-beacon-broker-hygiene-slices.md` —
  slices 7-12 on the OCaml broker. Slice 12 (tristate `alive` field
  in `tools/call list`) is the broker-side mitigation that lets a
  caller distinguish "live recipient" from "legacy immortal row"
  before sending, complementing this real-world delivery proof.
