# Event-tag visual indicator UX — design (#392)

**Author**: cairn-vigil (coordinator1) — 2026-04-29
**Status**: #392 base landed; this doc captures rationale + ratifies the
shape so #392b stays shippable and future extensions stay coherent.
**Cross-link**: #392b (envelope attribute + formatter convergence — also
landed; see "What's already in" below).

## 1. Current state

### Envelope shape

Defined in `ocaml/c2c_mcp.ml:360 format_c2c_envelope`:

```
<c2c event="message" from="X" to="Y" source="broker"
     reply_via="c2c_send" action_after="continue"
     [role="..."] [tag="fail|blocking|urgent"] [ts="HH:MM"]>
BODY
</c2c>
```

The envelope is the **wire format**; agents read the **body** as plain
text in their transcript. Attribute-only signals (e.g. just `tag="fail"`
with no body change) are invisible to the reader because no client
surfaces XML attributes specially in the transcript.

### Where it's rendered (host clients differ)

- **Claude Code**: hook stdout → `<c2c …>BODY</c2c>` appears as a tool-
  result block in the transcript. Attributes are not styled. Only body
  text reaches the model.
- **Codex**: PTY sentinel + xml_fd path; same envelope, same
  body-is-the-channel constraint.
- **OpenCode plugin**: drains via plugin and re-emits the envelope into
  the session; renders identically.
- **Wire-bridge / inbox-hook**: re-derive the envelope via
  `format_c2c_envelope` (#392b convergence) so the tag attribute is
  preserved across re-delivery surfaces, but again the body is what the
  model reads.

**Conclusion**: any indicator that doesn't change the *body* is invisible
to the receiving agent. Envelope attributes are useful for tooling
(filters, doctor histograms, future styled clients) but cannot be the
primary signal.

### Failure mode this addresses

A peer DM "FAIL: signing chain broken on SHA abc123" looked like every
other tool-result XML block in the transcript. Coordinators routinely
missed FAIL verdicts and blocking findings until a follow-up DM nudged
them. Same envelope shape as a chatty status DM → no visual salience
delta → critical messages got buried.

## 2. Proposed indicator scheme — body-prefix + envelope attribute

**Pick: dual-channel (body-prefix is load-bearing, envelope attribute
mirrors it for tooling).**

### Body prefix (the indicator agents actually see)

| tag       | prefix                  | semantic                                      |
|-----------|-------------------------|-----------------------------------------------|
| `fail`    | `🔴 FAIL: `             | peer-PASS verdict negative; review found bugs |
| `blocking`| `⛔ BLOCKING: `         | downstream work cannot proceed                |
| `urgent`  | `⚠️ URGENT: `           | time-sensitive but not fully-blocking         |

Prefix is **prepended at send-time** (CLI + MCP `send` handler) so the
broker-stored content carries the marker through every delivery surface
without per-client rendering hooks.

### Envelope attribute (mirror, for tooling)

`tag="fail|blocking|urgent"` on `<c2c event="message" …>`. Re-derived
from body prefix at format time via `extract_tag_from_content` so
re-delivery (PostToolUse hook, inbox-hook tool, wire-bridge) keeps the
attribute even when the archived row didn't store it explicitly.

### Why this scheme

- **Body prefix**: only signal the model reliably notices. Emoji + ALL-CAPS
  keyword breaks the visual sea of XML blocks. Three tiers cover the
  observed cases (FAIL, BLOCKING, URGENT) without the analysis-paralysis
  of a 7-level priority enum.
- **Envelope attribute**: gives `c2c doctor` / future styled clients /
  MUA-style mailbox views a structured handle. Without this, every tool
  has to re-grep the body.
- **Three tiers, not five**: rejects `info`/`low` because the default
  (no tag) already *is* "info". Adding `info` would tempt senders to mark
  routine DMs and re-bury the salient ones.
- **Rejected: color-only / ANSI escapes**: not all client transcripts
  preserve ANSI; emoji + uppercase keyword degrades to legible text in
  every surface.
- **Rejected: separate event type (`event="fail"`)**: would fork the
  delivery code path and break peers that filter on
  `event="message"`. Tag-as-attribute is strictly additive.

## 3. Sender API — explicit opt-in (not content-inference)

**Decision: sender opts in. Broker does NOT infer from keywords.**

CLI:

```
c2c send <alias> "signing chain broken on abc123" --fail
c2c send <alias> "need this resolved before merge" --blocking
c2c send <alias> "build broken on master" --urgent
```

MCP:

```
mcp__c2c__send { to_alias: "...", content: "...", tag: "fail" }
```

Flags `--fail`, `--blocking`, `--urgent` are mutually exclusive (CLI
exits 2 with error). Unknown `tag` values rejected at MCP layer.

### Why explicit opt-in beats content-inference

- **False positives kill the signal.** "the test FAILS to compile when X"
  would trigger a FAIL tag under a keyword-grep. A noisy tag is a
  silenced tag — three weeks in, agents would learn to ignore the emoji.
- **Sender knows intent.** A FAIL verdict from `review-and-fix` is a
  different beast from a routine "oh, that test failed locally". Only
  the sender can disambiguate.
- **Future-proof.** Localized peers, non-English text, or a
  Codex-emitted JSON body wouldn't match an English keyword regex.
- **No silent re-tagging.** Inference would mean the broker mutates
  message content semantics; signed-peer-PASS provenance would get
  ugly.

## 4. Backward compatibility

- **Wire**: `tag` is an *optional* attribute. Pre-#392 peers parsing
  `<c2c event="message" …>` ignore unknown attributes — XML readers
  attribute-tolerant by spec, and the OCaml broker only reads `from`/
  `alias`/body anyway. Verified: `format_c2c_envelope` omits the
  attribute when `tag=None`, so untagged DMs are byte-identical to
  pre-#392.
- **Body prefix**: emoji + keyword is just text. A peer that doesn't
  understand the convention sees `🔴 FAIL: …` and renders it like any
  other body — still strictly more visible than the old behavior, just
  without the tooling mirror.
- **Relay**: prefix travels in body content; relay is content-opaque.
  Envelope attribute round-trips through `format_c2c_envelope` on the
  receiving side via tag-recovery from the prefix.
- **Signed peer-PASS**: signature covers archived row content (which
  includes the prefix). No churn.
- **Tests**: existing envelope shape assertions at
  `test_c2c_start.ml:255,2304` still pass — the prefix is a `from=`
  literal check, not a body assertion.

## 5. Implementation slice plan

**Status**: slices 1–3 already landed under #392 and #392b. Slices 4–5
are the remaining surface-area for this design.

| # | slice                                                          | LOC  | status   |
|---|----------------------------------------------------------------|------|----------|
| 1 | `tag_to_body_prefix` + `parse_send_tag` + MCP send handler     | ~50  | LANDED   |
| 2 | CLI `--fail`/`--blocking`/`--urgent` flags (mutex, prefix app) | ~50  | LANDED   |
| 3 | `format_c2c_envelope ?tag` + `extract_tag_from_content`        | ~40  | LANDED   |
|   | + wire-bridge / inbox-hook convergence on shared formatter     |      |          |
| 4 | `c2c send_room` / `mcp__c2c__send_room` accept `tag`           | ~60  | OPEN     |
|   | (rooms are where coord broadcasts of BLOCKING are highest-     |      |          |
|   | leverage today)                                                |      |          |
| 5 | `c2c doctor tags --since 1h`: histogram of fail/blocking/      | ~80  | OPEN     |
|   | urgent inbound by sender, parallel to delivery-mode doctor;    |      |          |
|   | makes "is anyone DOSing me with FAIL?" answerable              |      |          |

### Slice 4 — rooms get tags (proposed)

`fan_out_room_message` currently hardcodes `deferrable=false`; extend to
plumb a `?tag` parameter through `send_room` / `mcp__c2c__send_room` and
apply the body prefix at fan-out time so each per-recipient archive row
carries the marker. Tests: 1 unit (`tag_to_body_prefix` passes through
fan-out), 1 integration (`mcp__c2c__send_room {tag:"blocking"}` →
recipient archive contains `⛔ BLOCKING: `).

### Slice 5 — doctor surface (proposed)

`c2c doctor tags --alias <a> [--since 1h] [--last N]` mirrors the
existing `c2c doctor delivery-mode` command. Reads recipient archive,
counts by tag attribute (preferred) falling back to body-prefix
extraction. NOTE footer documents that counts measure sender INTENT.
Closes the loop: a coordinator can audit "which peers are tagging
sensibly vs spamming `--urgent`".

### Out of scope (explicit non-goals)

- **Push-priority tier coupling** — tempting to make `--blocking` skip
  the watcher delay, but #284 ephemeral + #303 deferrable already
  cover the latency lever, and conflating "visibility" with "delivery
  scheduling" makes the mental model worse. Keep tags purely
  presentation.
- **More tag values** — resist `info`/`question`/`fyi` until concrete
  evidence the existing three are insufficient. Three tiers staying
  scarce is what keeps them salient.
- **Rendering hooks per host client** — the body-prefix design
  deliberately moots the need for client-side rendering. If a styled
  Claude Code render lands later, it can read the envelope `tag`
  attribute additively without changing the wire.

## Acceptance for #392b shippable

- [x] `format_c2c_envelope` accepts `?tag` and emits attribute
- [x] Wire-bridge + inbox-hook share the formatter (no shape drift)
- [x] CLI + MCP send paths apply body prefix + accept tag
- [x] Untagged DMs byte-identical to pre-#392 wire
- [x] `tag` value validation (reject unknown)
- [x] Mutex of `--fail`/`--blocking`/`--urgent` enforced

## References

- `ocaml/c2c_mcp.ml:300-385` — body-prefix + envelope helpers
- `ocaml/cli/c2c.ml:352-396` — CLI flag wiring
- `ocaml/c2c_wire_bridge.ml:17-28` — wire convergence
- `ocaml/tools/c2c_inbox_hook.ml:259-275` — re-delivery convergence
- `ocaml/test/test_c2c_start.ml:2217-2305` — pure-helper + convergence
  tests
