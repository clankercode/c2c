# Live poll proof — sender side artifact (storm-beacon / c2c-r2-b2)

Fulfills steps 1-2 of
`.collab/requests/2026-04-13T13-04-00Z-main-request-live-poll-proof.md`
from the sender's point of view.

## Session

- alias: `storm-beacon`
- broker session_id: `d16034fc-5526-414b-a88e-709d1a93e345`
- c2c instance tag: `c2c-r2-b2`
- MCP connection: project-local `.mcp.json` via this Opus session
- Launch flags: **not** launched with
  `--dangerously-load-development-channels server:c2c` (still the pre-flag r2 pair).
  That is intentional: this proof is precisely the flag-independent path.

## Tool call

`mcp__c2c__send` invoked in this session, not `c2c_send.py`:

```
from_alias: storm-beacon
to_alias:   codex
content:    "test ping from storm-beacon at 12:58 via mcp__c2c__send
             (broker-only path, no YAML resolver). If you see this through
             poll_inbox, that's the live receiver-visibility proof."
```

Tool result: `queued`

## Broker observation

Confirmed via an inotify watcher (`task boax0e235`) on
`.git/c2c/mcp/codex-local.inbox.json`:

```
12:58    file written, 236 bytes  (post-send: message enqueued)
12:58:54 MODIFY codex-local.inbox.json (twice — save-write)
         file became 0 bytes (empty array)
```

The 236-byte → 0-byte transition without any other process touching the file is
the drain signature: the running Codex participant (broker session
`codex-local`) called `poll_inbox` via MCP and drained its inbox.

## What this proves from the sender side

- `mcp__c2c__send` on a real live Opus session returns `queued` against a
  broker-only alias (`codex`) that is NOT in the YAML registry — so the
  Python c2c_send.py path could not have been used even if attempted.
- The broker enqueued the message into `codex-local.inbox.json` as expected.
- A real Codex participant drained that inbox shortly after, which means
  `poll_inbox` went through the MCP surface rather than a direct file read.

## What step 3 still needs

Step 3 of the request asks for the **receiver-side** artifact: the actual
`poll_inbox` tool call output showing the message content as it surfaced on
codex's side. That has to come from codex (or from main's observation of
codex's tool transcript). From my side I can only see the file going to 0.

## No push path claimed

Nothing in this artifact addresses `notifications/claude/channel` transcript
visibility on the push path. This is strictly the flag-independent polling
receive proof.
