# #307a — `c2c doctor delivery-mode` histogram design

stanza-coder, 2026-04-26 10:11 UTC. Design pass for the
delivery-mode visibility tool flagged as recommendation #2 from
#303's investigation. Companion to #307b (drop deferrable from
#286 handoff) which already shipped at 120a4cd9.

## Goal

Make the deferrable distribution visible per agent so future audits
can spot sender-side opt-ins to "no push" delivery without grep.
Specifically: when an agent reports "I'm not seeing DMs surface as
push," `c2c doctor delivery-mode --alias <them>` should immediately
show whether their inbound traffic is dominated by deferrable
senders or whether something else is wrong.

This is visibility tooling. Not a behavior change. Not a fix.

## Source: archive replay (v1)

The broker writes per-recipient archives at
`<broker_root>/archive/<session_id>.jsonl` on every `drain_inbox` /
`drain_inbox_push` call. Each line is a JSON record carrying
`drained_at`, `session_id`, `from_alias`, `to_alias`, `content`, and
(when set on the source message) `deferrable: true`.

The histogram reads recent N messages or recent N seconds out of
the relevant session_id's archive, counts by `deferrable`, and
groups by `from_alias`.

**Implementation note**: the archive WRITE path already includes
`deferrable: true` when set (see `append_archive` in
`ocaml/c2c_mcp.ml`). The READ path's `archive_entry` record does
NOT currently expose the field — `archive_entry_of_json` ignores
it. v1 extends `archive_entry` with `ae_deferrable: bool` and
parses it from the JSON (default false). Backward compatible with
existing archive files; no migration.

**Not chosen for v1**: runtime broker-side counters. They'd be
cheaper to query but would require call-site instrumentation in
every enqueue/drain path; the surface area isn't worth it for a
visibility tool, and the archive already exists. If we later want
"delivery actuals" (which path actually surfaced, not which path
the sender intended), runtime counters are the right add — flagged
as v2 in "Out of scope."

## Important caveat: intent vs actuals

The histogram measures **sender intent**, not delivery actuals.
`deferrable=false` means "the sender wanted this to push," not
"this actually pushed via channel-notification." The broker
doesn't record which path actually surfaced a message — push,
hook, or late poll.

For most diagnostic uses ("are senders opting into deferrable
without realizing?") intent is the right axis. If we ever need
actuals, that's a follow-up that adds counters to
`drain_inbox_push` and the hook drain.

The output prints the caveat in the human-readable footer so
operators don't read the numbers as guarantees.

## Granularity (v1)

- **Per-alias** (the recipient): default. Shows the whole inbound
  picture for one agent.
- **By sender** (`from_alias` breakdown): always included as a
  secondary table. Highlights which peers are sending deferrable.
- **Per-call-site** (e.g. relay_nudge vs send-memory vs user-driven
  send): NOT in v1. Would require senders to tag their messages
  with a "reason" or "call_site" field, which is broker schema
  surface and out of scope here. Workaround: by-sender breakdown
  identifies systemic senders (`c2c-system`, `relay`) which is
  enough signal for the immediate audit use.

## CLI surface

```
c2c doctor delivery-mode [--alias ALIAS] [--since DURATION] [--last N] [--json]
```

| Flag | Default | Effect |
|---|---|---|
| `--alias` | current session's alias if registered, else error | recipient to histogram |
| `--since` | `24h` (when `--last` not given) | window of time, e.g. `1h`, `24h`, `7d`. parses standard duration suffixes |
| `--last` | unset | window of last N messages (most recent) |
| `--json` | off | machine-readable output for tooling |

If both `--since` and `--last` are given, `--since` wins (its
constraint is tighter when the archive is sparse; we describe the
intersection in human output if both bound the result).

`c2c doctor` already exists (`ocaml/cli/c2c.ml` doctor group); this
adds a `delivery-mode` subcommand.

## Output shape

### Human-readable (default)

```
Delivery mode for stanza-coder (last 24h, 142 archived messages)

Push intent (deferrable=false):  138  (97.2%)
Poll-only (deferrable=true):       4  (2.8%)

By sender:
  ALIAS                  TOTAL    PUSH   POLL  POLL%
  coordinator1             67      67      0    0.0%
  galaxy-coder             34      33      1    2.9%
  jungle-coder             21      21      0    0.0%
  lyra-quill               16      16      0    0.0%
  c2c-system                4       1      3   75.0%

NOTE: counts measure sender intent (deferrable flag), not which
delivery path actually surfaced the message. Ephemeral messages
(#284) are not archived and not counted. See #303 design doc for
the deferrable contract.
```

### JSON

```json
{
  "alias": "stanza-coder",
  "window": { "since": "24h", "messages": 142 },
  "counts": {
    "push_intent": 138,
    "poll_only": 4
  },
  "by_sender": [
    { "alias": "coordinator1", "total": 67, "push": 67, "poll": 0 },
    { "alias": "galaxy-coder", "total": 34, "push": 33, "poll": 1 }
  ],
  "caveats": ["sender_intent_not_actuals", "ephemeral_excluded"]
}
```

## Implementation sketch

- Extend `Broker.archive_entry` with `ae_deferrable: bool`.
- Update `archive_entry_of_json` to parse `deferrable` field, default
  `false`.
- Add `Broker.delivery_mode_histogram t ~session_id ~since ~last` that
  reads via `read_archive` (extended to take a since-filter) and
  returns a structured result.
- New CLI subcommand under `c2c doctor`:
  resolves alias→session_id via registry, calls the histogram,
  renders human or JSON.
- Test: write a synthetic archive file with mixed deferrable
  messages, invoke histogram-compute, assert counts.
- CLAUDE.md mention of the new doctor subcommand.

## Out of scope

- Runtime metrics / delivery actuals — v2 if needed.
- Per-call-site tagging — would need broker schema change.
- Real-time histogram over a streaming inbox — visibility tool is
  archive-replay only.
- Cross-host (relay) delivery semantics — local archive only.

## Open decisions

1. **Window default**: `--since 24h`. Wall-clock window, doesn't
   depend on traffic volume.
2. **Anchor**: `c2c doctor` (existing diagnostic dispatch) since
   the use is diagnostic.

— stanza-coder, 2026-04-26
