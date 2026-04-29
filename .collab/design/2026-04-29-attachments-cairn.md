# Attachments for c2c messages — design

Author: cairn (subagent slice)
Date: 2026-04-29
Status: DRAFT — design proposal, not yet sliced

## Problem

Today a c2c message body is a single XML envelope with a string
content payload (`<c2c event="message" from=… alias=…>BODY</c2c>`).
That's fine for chat, but the swarm increasingly wants to share:

- multi-KB code blobs (peer-PASS finding diffs, log excerpts)
- screenshots (TUI captures, terminal recordings, dashboard PNGs)
- structured dumps (JSON tracebacks, transcripts, hook payloads,
  .collab/findings/* snippets)
- small archives (test fixtures, repro tarballs)

Current workarounds: paste into the body (blows up archive files,
breaks the "scrollable transcript" UX, base64'd binaries are
illegible), or write to `.collab/` and DM a file path (works only
in shared-tree, brittle once relay-mediated). Neither is a
designed surface — both are coping.

This doc proposes a deliberate attachment surface with the goal
of (a) keeping the inbox.json compact, (b) making cross-host
delivery work without forcing every byte through the relay text
channel, (c) preserving end-to-end integrity via content
addressing.

## Storage — broker-root content-addressed blob store

v1 stores blobs at:

```
$BROKER_ROOT/blobs/sha256/<2-char prefix>/<remaining 62 chars>
```

Mirrors git's loose-object layout. Filename is the lowercased
hex SHA-256 of the blob; immutable; safe to dedupe globally per
broker. Sidecar `<sha>.meta.json` carries `{ mime, size,
original_filename, created_ts, refcount }`. The blobs/ dir is
gitignored (per-host state, not part of the repo). A small
`blobs/.lock` file (flock) guards concurrent writes from
multi-process broker / relay-connector.

Why broker-root, not CDN/S3:

- The broker root already has the right trust + lifecycle:
  ephemeral local-state, cleared by `c2c migrate-broker` /
  manual `rm -rf`, no auth surface to operate.
- Object-store (S3/R2) is a v3 concern — comes naturally once
  the relay is the bottleneck for >MB blobs. The blob-store
  abstraction (write-blob, read-blob, gc-blob) is small enough
  that swapping the backend is a 1-day port. v1 should NOT
  multi-backend speculatively (`ultra-yagni`).
- Loose-object layout means `find broker/blobs -type f` is the
  GC primitive. No DB.

Refcount field is informational in v1 — GC scans inbox.json +
archive + room history for `sha=…` mentions and prunes blobs
older than N days with zero refs. Swept by `c2c blob gc` (manual
in v1; cron-ish in v2).

## Envelope shape

The XML envelope grows an `<attachment/>` child. A message can
carry zero, one, or multiple attachments. Body text remains
the primary semantic content; attachments are sidecars.

```xml
<c2c event="message" from="cairn" alias="lyra-quill"
     source="broker" reply_via="c2c_send" action_after="continue">
Here's the failing trace and a screenshot.
<attachment
    id="a1"
    sha="ab12…cd"
    mime="application/json"
    size="4823"
    name="trace.json"
    href="c2c-blob:ab12…cd"/>
<attachment
    id="a2"
    sha="ef34…56"
    mime="image/png"
    size="184312"
    name="tui-snapshot.png"
    href="c2c-blob:ef34…56"/>
</c2c>
```

Attribute notes:

- `id` is local-to-envelope (`a1`, `a2`, …) so prose can reference
  attachments unambiguously ("see a2"). NOT globally unique.
- `sha` is the canonical identity. Lowercase hex SHA-256.
- `mime` is the sender-declared media type. Recipients SHOULD
  validate against the actual blob (defense against confused
  deputy renderers).
- `size` is the byte count of the blob. Allows the recipient
  to decide whether to fetch eagerly.
- `name` is a hint for display + save-as. Sanitized by recipient
  (no path separators, no `..`).
- `href` is the resolution scheme. `c2c-blob:<sha>` means "ask
  your local broker"; future schemes (`https://…`,
  `c2c-relay:<host>/<sha>`) slot in without re-touching the
  envelope grammar.

Attachments are XML CHILDREN, not attributes on `<c2c>`, so:

- multiple attachments compose naturally;
- a body-only renderer that doesn't know about attachments
  treats them as inert XML children and the message still reads;
- they don't fight the existing attribute namespace
  (`role`, `tag`, `ts`, `reply_via`).

## Inline vs link vs both

Three regimes by size:

| size                | inline body? | blob written? | href present? |
|---------------------|--------------|---------------|---------------|
| ≤ 4 KiB text/utf-8  | yes (CDATA)  | optional      | yes (always)  |
| ≤ 256 KiB           | no           | yes           | yes           |
| ≤ 4 MiB             | no           | yes           | yes (warn)    |
| > 4 MiB             | reject       | reject        | reject        |

For the small-text case, the attachment carries an `inline="…"`
attribute (XML-escaped CDATA) so recipients with no broker access
(rare, but possible cross-host) still get the content. The blob
is also written so subsequent `c2c attachment fetch a1` works
uniformly. Past 4 KiB the size cost of duplicating into the
envelope outweighs the convenience — link only.

The "both" cell (inline + blob) is intentional for small text:
keeps the chat scrollback self-contained; lets tooling that
post-processes envelopes (search, archive index) operate without
a broker round-trip; matches how Slack/Discord handle code blocks.

For binaries (screenshots, archives): never inline. base64 in an
inbox.json is a footgun — it bloats archive on disk, defeats grep,
and double-encodes through any JSON-string escaping pass.

## Size & quota limits

Per-attachment hard cap: **4 MiB**. Anything bigger is a "share
a link to a real file store" problem, not a chat problem.

Per-message total: **8 MiB across all attachments** (i.e. you can
attach two 4 MiB files but not three). Encourages sender to slim
down before attaching three screenshots of the same thing.

Per-sender per-hour quota (broker-side): **64 MiB written**. Stops
runaway loops where an agent stuck in a compaction spin attaches
the same dump to every message. Quota enforcement is at
`enqueue_message` time; on overflow the send fails fast with a
`{ error: "attachment_quota_exceeded" }` JSON error so the agent
can surface it rather than silently truncate.

Limits live in the broker config (`.c2c/config.toml [attachments]`)
with the above as defaults. Operators with private deployments can
relax them; the relay enforces its own (likely tighter) caps
independently.

## Cross-host considerations

This is the load-bearing concern. Local-only the design is
trivial — both peers see the same broker root. Cross-host (relay
or future federation) breaks if blobs aren't replicated.

Three options:

**(A) Relay mirrors blobs eagerly.** When the relay forwards a
message containing an `<attachment sha=… href="c2c-blob:…">`,
it also pushes the blob bytes to the destination broker over
the same channel. Delivery is a single logical operation
(envelope + blobs land together or not at all). Cost: relay sees
plaintext blobs (or end-to-end ciphertext if the e2e layer wraps
them). Bandwidth scales with payload size. **PREFERRED.**

**(B) Relay rewrites href → relay-hosted URL.** Sender uploads
to the relay's blob store, relay rewrites the `<attachment>` to
`href="https://relay/blobs/<sha>"`, recipient pulls on demand.
Cost: relay becomes a CDN; blobs persist past message TTL; auth
+ retention semantics balloon. Defer.

**(C) Bare links + recipient resolves out-of-band.** Sender
ships only the sha; recipient must already have the blob (e.g.
shared filesystem, prior message). Cost: works for tightly-
coupled local pairs; useless for the cross-host case this section
exists to solve. Reject.

v1 ships **(A)**: the relay forwards blobs alongside envelopes,
chunked if the WS frame size requires. The relay-side enforced
cap is the same 4 MiB/8 MiB pair as local; oversized messages
are rejected at the relay edge so the sender gets a synchronous
failure rather than a silent drop on the recipient side. The
e2e encryption layer (`relay_e2e.ml`) wraps blob bytes the same
way it wraps envelope bytes.

Failure mode to design for explicitly: **partial replication**.
If the envelope arrives and a blob does not, the recipient MUST
NOT silently drop the message. They render the envelope with a
stub `<attachment status="missing" sha=…>` so the user sees
"there was a thing here, it didn't make it" rather than nothing.
Same principle as the `dead_letter` reason field on undeliverable
DMs (#379).

## Slice plan

Five slices, sized for one-worktree-each:

1. **Blob store primitive.** `Broker.Blobs.write_bytes`,
   `read_bytes`, `stat`, `gc`. Loose-object layout under
   `$BROKER_ROOT/blobs/sha256/`. Unit tests: write→stat→read
   roundtrip, dedupe, GC honors refcount, concurrent-writer
   flock. No envelope changes yet. ~300 LOC + tests.

2. **Envelope parser/emitter.** Extend the message-format helper
   (`c2c_mcp.ml` ~L414) to take an optional `attachments` list
   and emit `<attachment/>` children. Parser added in
   `c2c_inbox_hook.ml` and wherever the envelope is consumed
   downstream (`peer_review.ml`, `c2c_role.ml`). Tests cover
   zero/one/many attachments and the inline-text case.

3. **CLI surface.** `c2c send <peer> "body" --attach
   path/to/file [--attach …]`. Reads file, computes sha, writes
   blob, builds envelope. Adds `c2c attachment fetch <sha>
   [--out path]` and `c2c attachment ls --message <msg-id>`.
   Tier1 CLI; functional smoke test in tmux harness against a
   live peer.

4. **MCP surface.** `mcp__c2c__send` gains an optional
   `attachments: [{ path | bytes_b64, mime?, name? }]` parameter.
   Server-side resolves to blob writes, emits the augmented
   envelope. Returns `{ message_id, attachment_ids: [sha…] }`
   so the agent can reference them later. Auto-delivery path
   (PostToolUse hook, channel push) renders attachments inline
   when small, link otherwise.

5. **Relay forwarding.** Extend `relay_remote_broker.ml` to
   ship blob bytes alongside the envelope when the destination
   is cross-host. Wire-frame layout: envelope frame, then N
   blob frames keyed by sha. Recipient broker writes to its
   local blob store before enqueueing the message. Smoke
   test: `scripts/relay-smoke-test.sh` extended with an
   attachment round-trip case.

Slice 1 is a strict prerequisite for 2-5. Slices 2 and 3 can
land before 4-5 (CLI usable as an emergency surface even if MCP
agents can't generate attachments yet). 5 is the most invasive
and ships last.

Out of scope for v1:

- Streaming uploads (everything is a single buffered write).
- Mutable / appendable blobs (immutable content-addressed only).
- Per-recipient ACLs on blobs (any peer that knows the sha and
  has access to the broker can read; same trust model as
  inbox.json today).
- Object-store backends (S3, R2). Hook point exists; no
  implementation.
- Inline rendering of images in agent transcripts (depends on
  client capability — Claude Code can, OpenCode can, Codex
  cannot today). Render-side is a follow-up doc.

## Open questions

- Do we want `<attachment>` to support an `expires` attribute so
  short-lived dumps GC themselves? Adds complexity; defer until
  we see actual storage pressure.
- Should `ephemeral=true` messages (#284) imply
  `attachments-not-archived`? Probably yes for symmetry, but
  requires the archive writer to thread the flag through to
  blob refcount accounting. Worth a finding doc once #284
  has more usage data.
- Does the room broadcast path need any special handling? No —
  rooms fan out via `enqueue_message` per recipient, and blob
  dedupe makes the storage cost O(blob), not O(blob × recipients).
- Compression: do we transparently gzip text blobs > some
  threshold? Saves disk + relay bandwidth, complicates the
  sha-as-identity model (sha-of-compressed vs sha-of-plain).
  Punt to v2; pick sha-of-plain when we add it so identity is
  stable across compression on/off.

## References

- envelope writer: `ocaml/c2c_mcp.ml:413` (`<c2c event="message" …>`)
- enqueue: `ocaml/c2c_mcp.ml:1689` (`enqueue_message`)
- broker root resolution: CLAUDE.md "Key Architecture Notes"
- ephemeral DM precedent: `.collab/runbooks/ephemeral-dms.md`
  (#284) — same "augment envelope, thread through enqueue" shape
- relay e2e wrapper: `ocaml/relay_e2e.ml`
- partial-delivery precedent: dead_letter handling (#379,
  commit 4450cf56)
