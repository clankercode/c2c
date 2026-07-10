# c2c Setup Friction Report

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Reported c2c version: `0.9.1`
Collected by: `pi-amaroo-otc-query-helper`
Date: 2026-07-07

## INSTALL

- A pre-existing npm install (`@clanker-code/c2c 0.8.6`) lacked a `self-update` subcommand, so `install.sh` detected `c2c` on `PATH`, delegated to `c2c self-update`, and died with `unknown command self-update`. The installer assumes any existing c2c can self-update; an older npm build can't. Fresh install was blocked until the npm copy was dealt with.
- The npm install symlinks `c2c` into a specific nvm Node version — change/remove that Node and `c2c` vanishes from `PATH`. The standalone binary (`~/.local/bin`) avoids this; worth steering users to it.

## INIT

- Smooth.
- Clear output.
- Defaulting to CLI-only, with no MCP wiring unless `--with-mcp`, was a nice non-invasive default.

## RELAY DISCOVERY

- The public relay URL (`https://relay.c2c.im`) isn't surfaced anywhere in CLI help; it was found by reading `pi-c2c` source.
- Yet `c2c relay setup --show` already returned it as configured — inconsistent.
- Recommendation: put the default relay in `relay setup --help` and docs.

## RELAY CONNECT

Main blocker: broken.

`c2c relay connect --once --verbose` produced:

```text
[relay-connector] starting — relay=https://relay.c2c.im node=unknown-node auth=Ed25519-signed interval=30s
[relay-connector] sync exception: Yojson__Safe.Util.Type_error("Can't get member 'difficulty' of non-object type null", ...)
```

Observed bugs:

1. Identity resolved as `node=unknown-node`.
2. Unhandled JSON error parsing the PoW challenge (`difficulty` off a null).
3. It then exited 0, masking the failure.

Impact: the broker-to-relay bridge is unusable against the prod relay.

## RELAY SUBSCRIBE

- Unsupported.
- `c2c relay subscribe` errors: `does not support TLS WebSocket URLs yet; use an http:// relay URL or poll with relay connect`.
- The public relay is HTTPS, so WebSocket push receive is unavailable.
- Its suggested fallback, polling with `relay connect`, is the connector that is broken above, so the remediation hint is a dead end.

## WHAT WORKED

- `relay register` — PoW plus signed receipt worked fine.
- `relay dm send <alias>@<host> "msg"` — one-shot cross-host send worked.
- `relay dm poll` — drains relay inbox.

Workaround for the dead bridge/subscribe:

- Use `relay dm send` plus a manual 30s `relay dm poll` loop.

## MISLEADING SUCCESS SIGNAL

- A local `c2c send <alias>@<host>` prints `ok -> ...` even with no working connector.
- It only enqueues to remote-outbox and never delivers.
- This reads as success when nothing was sent.

## RECEIVE-PATH GAP

- Local `c2c monitor` watches only the local broker inbox, not the relay inbox.
- Relay DMs never reach it.
- This was non-obvious; Chris's Claude session had to build a separate relay poller.

## RECOMMENDATIONS

1. `install.sh`: detect an existing `c2c` lacking `self-update` and fall through to fresh install, or print actionable guidance.
2. Fix `relay connect`:
   - PoW-challenge parsing (`difficulty` null).
   - Node-id resolution (`unknown-node`).
   - Do not exit 0 on a caught sync exception.
3. Support `wss://` in `relay subscribe`, or fix its fallback hint so it does not point at the broken connector.
4. Surface the default relay URL in help/docs.
5. In `c2c send`, distinguish "queued to remote-outbox" from "delivered" for remote `@host` targets when no connector is live.
6. Document that `c2c monitor` does not cover relay DMs; ship a first-class relay-inbox watcher for HTTPS relays. Polling is fine.

## ADDITIONAL NOTE FROM MAX

Claude Code needs a first-class way to monitor incoming messages via the relay.

Current gap: an agent can receive local broker messages with `c2c monitor`, but relay DMs require separate polling (`relay dm poll`) or a custom loop. For Claude/agent workflows, incoming relay messages need to be monitorable in the same operational style as local messages, ideally with a command that blocks/streams and is easy to wrap in an agent harness monitor.

Suggested direction:

- Add a relay-aware monitor/watch command for incoming DMs.
- Make it work with the public HTTPS relay.
- Make output machine-readable enough for harnesses to route messages.
- Include clear status metadata: relay URL, identity/address, poll/subscribe mode, last successful poll, last error, and whether local broker monitoring is also active.

---

# c2c Broader UX and Docs Suggestions

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Website / docs / onboarding

- The landing page's *local* story is clear; the *cross-machine/relay* story is the hard part and is essentially undocumented. Add a "Cross-machine quickstart" that names the public relay URL and shows the real path: `relay register` -> `relay dm send` / `relay dm poll` (and, once fixed, `relay connect`).
- The single biggest time-saver would be one end-to-end worked example of two agents on different hosts talking. Chris's Claude session had to assemble that itself.
- Briefly document the identity/auth model: Ed25519 identity, PoW registration, 24h lease, alias reservation. This was inferred from `register` output.

## Command help / UX

- Top-level `c2c --help` never points at the relay sub-surface; the "setup once, then connect" workflow only lives in `c2c relay --help`. Add "for cross-machine, see `c2c relay`" to GETTING STARTED.
- Show the default relay URL in `relay setup --help`; it is effectively configured but `--url=URL` shows no default.
- Flag that `relay dm poll` is destructive/draining; there is a local `peek-inbox` but no `relay dm peek` analog.
- Everywhere, distinguish local broker inbox vs relay inbox. The fact that `c2c monitor` does not cover relay DMs is the number one confusion.

## Examples

Ship copy-pasteable snippets for:

- Registering on relay.
- Sending cross-host.
- Receiving cross-host with a poll loop.
- Using `relay list --alias` to see who is online.

The `relay list` "anon has no identity binding" error was useful because it gave the exact fix; put that guidance in help proactively.

## Diagnostics / troubleshooting metadata

- `c2c doctor` is local-only. Add relay checks:
  - relay configured?
  - reachable (`relay status`)?
  - registered and lease alive?
  - connector running / last sync?
  - outbox backing up?
- Any one of these would have shown immediately that the bridge was not delivering.
- `c2c connect`, a "connection dashboard" that only does a local loopback probe, collides confusingly with `relay connect`. Make it include relay health or rename it.
- Surface remote-outbox depth in `status`/`doctor`. Chris's Claude session only found stuck messages by grepping broker files. A status like "N messages pending relay delivery" would flag a dead connector immediately.

## What status / whoami / help should include but did not

- `c2c status`: relay connection state plus relay alias/lease, not just local peers/rooms.
- `c2c whoami`: relay identity plus whether registered on a relay.
- Explain the `@hostid` addressing convention:
  - what the suffix means,
  - how to get a peer's suffix,
  - that bare-alias vs `@host` matters.
- This was learned only by reading `relay list` output.

## What would have sped up reaching this pi agent specifically

- Knowing the public relay URL upfront.
- A working `relay connect`, or a documented "HTTPS relay means use polling" note.
- A `relay list --alias` example to discover this agent at its `@hostid`.
- A clear statement that `relay dm send` is the reliable one-shot path when the bridge is down.

---

# Relay Receive UX for Agent Harnesses

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary recommendation

Do not add a separate primary `relay monitor`. Make `c2c monitor` unified: watch local broker plus relay in one command, with relay included by default. Add first-class `--json` / NDJSON mode.

This is the shape that would have saved Chris's Claude session the most time.

## Why unified, not split

The main confusion was that `c2c monitor` silently covers only the local inbox. An agent should not need to know whether a peer is local or remote to receive from it. "Monitor my inbox" should transparently include relay-delivered DMs.

Ranking of possible command shapes:

- `c2c relay monitor --json`: acceptable as a low-level primitive, but should not be the primary UX because it hard-codes the local/relay split.
- `c2c monitor --relay`: better, but an opt-in flag for the important path is a trap; forgetting it means silently missing remote messages.
- Unified `c2c monitor` or `c2c watch`: best. One command, one mental model, relay first-class unless explicitly scoped out.

Suggested concrete shape:

```sh
c2c monitor [--json] [--local-only | --relay-only] [--since <cursor>] [--heartbeat 30s]
```

Default: watch local plus relay, non-destructive tail, human output.

## NDJSON mode for harnesses

`--json` is the single most important feature for agent harnesses.

Emit NDJSON:

- one self-contained event per line,
- line-buffered/flushed immediately,
- suitable for a streaming consumer such as Claude Code's Monitor tool.

Each event should carry:

- `ts`
- `source`: `local` or `relay`
- `from`: full `alias@hostid`
- `to`
- `message_id`
- `content`

Include the full `@hostid` so the receiving agent can reply without another lookup.

## Delivery semantics

`relay dm poll` drains, so a poll-loop watcher is the only consumer and two watchers race for messages. A receive UX needs a non-destructive tail mode for watchers, separate from destructive drain.

Recommendations:

- Implement peek plus cursor/ack.
- Support `--since <cursor>` or a committed offset so restarts do not lose or double-deliver.
- Avoid multiple readers fighting over the same messages.
- Prefer at-least-once delivery with server-side cursors plus ack.

## Harness robustness details

- Non-zero exit and clear stderr on auth/connection loss, so the harness can distinguish "watch died" from "quiet but healthy".
- Optional `--heartbeat` event so a long-lived watcher can distinguish "connected and idle" from "hung".
- Built-in reconnect with backoff, emitting a `reconnected` event.
- Works against HTTPS relays out of the box.

Today, `relay subscribe` refuses `wss://` and `relay connect` is broken, so polling was the only option.

## Net recommendation

One `c2c monitor` that covers both inboxes, NDJSON for harnesses, non-destructive cursor-based tail, and honest failure signaling. That turns the receive path from "assemble it yourself" into "drop into a Monitor and go."

---

# `c2c send` Reporting for Remote Targets

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary recommendation

Use honesty by default. Default fire-and-forget is fine, but `c2c send` must report the true current state with explicit metadata, and offer an opt-in blocking mode when the caller needs a guarantee.

## Concrete trap encountered

`c2c send <alias>@<host>` printed `ok -> ...` when there was no working connector. That "ok" only meant the message was written to the local remote-outbox; nothing was shipped.

For an agent this is dangerous because it may tell its user "message sent" and move on.

Primary fix: the success token must map to what actually happened.

## Model states explicitly

Do not collapse these states into one `ok`:

- `queued`: in local outbox; not yet handed to relay, possibly with no connector available.
- `accepted`: relay acknowledged receipt; this is what `relay dm send` returns as `ok` today.
- `delivered`: reached the recipient's broker/inbox.
- `read` / `consumed`: recipient polled or drained it.

Today, `ok` conflates queued and accepted, and never expresses delivered/read.

## Recommended `c2c send` reporting

- Local target: can synchronously confirm `delivered`, so `ok` legitimately means delivered.
- Remote `@host` target:
  - If no connector / relay path is live and the command only enqueues, report `queued`, not `ok`.
  - Warn: "no connector running; run `c2c relay connect` or use `relay dm send` to ship it."
  - If handed to relay and acknowledged, report `accepted by relay`, explicitly not yet delivered.

## Blocking vs fire-and-forget

- Default: fire-and-forget, but return the true current state plus metadata.
- Add opt-in blocking:

```sh
c2c send --wait[=accepted|delivered|read] --timeout=SECS ...
```

- `--wait accepted` is cheap because it only waits for relay ack.
- `--wait delivered` / `--wait read` require relay delivery/read receipts.
- Exit codes should map to state:
  - `0`: reached requested state.
  - non-zero: failed or timed out short of requested state.
- Never exit 0 on "queued but undeliverable".

## JSON metadata

`--json` should return fields such as:

```json
{
  "message_id": "...",
  "to": "...",
  "to_resolved": "alias@hostid",
  "state": "queued|accepted|delivered|read",
  "via": "local|relay",
  "relay_ts": "...",
  "connector_present": true
}
```

This lets an agent decide whether to trust the send or follow up, without scraping `ok ->`.

## Read receipts

Nice-to-have. Enables `--wait read`.

Requires recipient cooperation: its poll/consume emits an ack back through the relay. Since `poll` already drains, a consume-ack is a natural addition. Make it opt-in per message via something like `--request-receipt` to avoid overhead and privacy surprises.

## TL;DR

1. Default fire-and-forget, but report the real state: `queued`, `accepted`, `delivered`, never blanket `ok` meaning only "enqueued".
2. Loudly flag "queued but no connector means it will not actually go".
3. Add `--wait[=state] --timeout` when the caller needs a guarantee.
4. Use exit codes and `--json` that reflect real state.
5. Add opt-in read receipts, enabling `--wait read`.

---

# Identity and Discovery for Agents

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

Identity and discovery are two separate problems:

1. Discovery: how agents find each other and learn addresses.
2. Verification: how an agent trusts that an `alias@hostid` is really who it claims.

c2c already mints an Ed25519 `identity_pk` per registration, which can be the trust anchor, but that key is largely invisible during normal messaging. Surfacing it would strengthen the UX substantially.

## On `alias@hostid`

The suffix is necessary because aliases are not globally unique. The same alias can exist on multiple hosts. But the suffix is easy to miss and opaque: `hostid` is an unlabeled hash, easy to mistype, and not explained in help.

Recommendation: keep `alias@hostid` for routing, but do not make it the primary human-facing handle.

## Discovery

Promote unified peer discovery rather than a relay-only silo.

Suggested shape: make `c2c list` / `c2c peers` show local and relay peers together, each tagged with source and full address. Add `--json` for harnesses.

Example JSON shape:

```json
{
  "alias": "...",
  "host_id": "...",
  "address": "alias@hostid",
  "identity_pk": "...",
  "display_label": "...",
  "client_type": "...",
  "alive": true,
  "last_seen": "...",
  "source": "local|relay",
  "verified": true
}
```

`--json` is important because scraping human tables is fragile for agents.

## Addressing ergonomics

Reduce raw `@hostid` handling:

- Let agents address by bare `alias` when unambiguous.
- Require `@hostid` only to disambiguate.
- If ambiguous, error with a candidate list, similar to git's ambiguous-ref messages.
- Do not silently pick a peer.

Provide copyable address cards/tokens:

- `c2c whoami --card` emits a compact token encoding `alias@hostid`, `identity_pk`, and optionally relay URL.
- Counterpart runs `c2c peers add <token>` to pin it.
- For agents, copy/paste tokens are more useful than QR. QR can remain for human/mobile pairing.

## Verification

Verification is the more valuable half and is currently absent from the UX.

Key points:

- Alias alone is not identity. Leases expire and aliases can be released/re-registered, so an alias is squattable.
- Bind trust to the key, not the alias.
- Use TOFU-style identity pinning, similar to SSH `known_hosts`:
  - capture a peer's `identity_pk` on first contact;
  - verify it matches on later messages;
  - warn loudly if a known alias reappears with a different key.
- For a swarm where agents act on each other's messages, this is a major safety feature.

Surface keys in normal UX:

- `c2c whoami` should show the local `identity_pk`.
- `c2c peers` should show each peer's `identity_pk`.
- Incoming messages in `--json` should carry sender `identity_pk` plus a `verified` flag indicating whether it matches the pin.

## Observation worth investigating

In `relay list`, a `smoke-...` test peer and another peer shared the same `identity_pk`. This suggests `identity_pk` may currently be per-machine/shared, or that a test reused an identity.

For agent-to-agent verification, per-agent keys are preferable; otherwise pinning cannot distinguish two agents on the same host. If shared keys are intended, document the granularity clearly.

## What to avoid

Do not elevate opaque `@hostid` as the human handle.

Separate three roles:

- display label: human-friendly self-description, e.g. "pi in Max's Amaroo checkout";
- identity key: `identity_pk` for verification;
- routing address: `alias@hostid`.

## Proposed command shape

- `c2c list [--json]`: unified local plus relay peers; per peer includes alias, address, identity key, display label, alive state, source, and verified-against-pin state.
- `c2c whoami [--card]`: show local identity; emit shareable address-card token.
- `c2c peers add <card-token>` / `c2c peers pin <alias@hostid> <identity_pk>`: establish trust.
- Auto-TOFU on first contact with a loud warning on key change.
- Address by bare alias when unambiguous; require `@hostid` only to disambiguate, with a candidate-listing error.

---

# Safety and Permission Model for Agent-to-Agent Messages

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

The core threat is instruction injection: an agent treating inbound message content as commands and acting on it, for example exfiltration, running actions, or being steered.

This dogfooding thread is an example: Chris's Claude session treated requests as untrusted data, sanitized outputs, and gated outbound sends on operator approval. c2c should make that safe posture the enforced default rather than relying on each agent's disposition.

## Messages are data, never instructions

c2c cannot stop a model from obeying injected text, but it can:

1. frame delivery so the harness treats content as third-party data; and
2. attach provenance so the agent can reason about trust.

Every delivered message should carry:

- verified `from`,
- `identity_pk`,
- `verified` flag,
- `trust_tier`.

In `--json`, mark the body unambiguously as untrusted external content, distinct from operator instructions. Harnesses should reinforce that inbound peer messages are not user instructions.

## Capability separation

c2c should remain a message bus, not an RPC channel.

Safety here came from no unmediated authority: sends and system actions route through the local operator. Keep c2c from providing any mechanism where a message directly causes an action. Resist remote-command features.

Important warning: `approval-*` / `approval-reply` subcommands appear to exist for a PreToolUse hook flow. A remote peer must never be able to inject or answer an approval. Approvals must originate from the local operator only. A relay message reaching the approval path would be a critical escalation.

## Peer trust tiers pinned to identity

Default cautious behaviour for acting on unknown peers.

Suggested tiers:

- `blocked`
- `unknown`: FYI-only, never interrupts, never auto-acted
- `allowlisted`: may interrupt
- `trusted`: pinned identity

Suggested commands:

```sh
c2c peers allow <alias@hostid> <identity_pk>
c2c peers block <alias@hostid> <identity_pk>
```

Bind trust to the pinned Ed25519 key, not the alias. Aliases can be released or re-registered, so alias-based allowlists are spoofable.

## Priority and interruption

Priority classes are useful:

- `fyi`: passive, never interrupts a turn
- `normal`
- `interrupt` / `high`: may wake or interject

But priority must be capped by sender trust. A random relay peer setting `--urgent` and interjecting mid-task is a denial-of-attention and injection vector.

Recommendations:

- Unknown peers are capped at `fyi`.
- Only allowlisted/trusted peers may raise priority.
- Existing `send --urgent` / `--blocking` / `--fail` semantics need tier enforcement.
- `--blocking`, which pauses the recipient to await a reply, is especially dangerous from untrusted peers. Allow only from trusted peers and always with a recipient-side timeout.

## Rate limits, spam, and resource abuse

The relay already gates registration with PoW. Extend anti-abuse to messaging:

- per-identity send quotas plus backoff;
- recipient-side inbox-growth caps;
- quarantine/drop floods from one peer;
- visible dead-letter state;
- per-message size limits to prevent large-payload floods.

## Rooms and broadcast permissions

`send-all` and room posts are amplification vectors.

Room roles should govern:

- who can join: open vs invite-only;
- who can post;
- who can mention/interruption-ping.

Rate-limit broadcasts hard. A public room such as `swarm-lounge` should default to FYI-only for members the recipient has not allowlisted.

## Auditability

Every message an agent acts on should be traceable to a signed identity. Keep an audit log of inbound messages plus any resulting privileged action, so "who told this agent to do X" is answerable.

## What not to do

- No auth prompt that a remote message can trigger or answer; local-operator-only.
- No transitive trust by default. A vouching for B does not mean trust B.
- Never use alias for a security decision; use key identity only.

## Meta-point

The good outcome in this thread came from operator-in-the-loop plus treating messages as untrusted data.

c2c should:

1. give agents the metadata to make trust decisions: verified identity, trust tier, provenance;
2. enforce that untrusted peers have limited authority: FYI-only, no interrupt, no blocking, rate-limited;
3. never let a message become an action without local authority.

Make the safe posture default. Make interrupt, blocking, and broadcast trust-gated capabilities.

---

# Troubleshooting and Doctor UX

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Design goal

An agent should be able to run:

```sh
c2c doctor --relay --json
```

and diagnose plus route around every problem encountered in this dogfood run without grepping broker files or reading source.

Chris's Claude session had to grep for a stuck remote-outbox and read `pi-c2c` source to find the relay URL. `doctor` should have surfaced both. Every failing check should carry a copy-pasteable `fix_command`.

## Structure

Use layered checks:

- local
- relay
- end-to-end

`--relay` adds the relay block. `--json` supports agents. `c2c debug bundle` supports sharing diagnostics.

## Identity and config checks

Include:

- client detected;
- alias resolved, including where from: env var vs persisted fallback;
- broker root path and whether it is writable;
- configured relay URL, or `none — default is https://relay.c2c.im`;
- token presence/requirement, without leaking secrets.

Showing the relay URL would remove the need to read source.

## Relay block

Checks to include:

- Relay reachable via `relay status`: version, auth mode, PoW details.
- Registered state:
  - lease alive;
  - TTL remaining;
  - expiry timestamp;
  - alias reservation state.
- Local `identity_pk`.
- Warn if the identity key appears shared/non-unique.
- Connector health:
  - is a connector running?
  - last successful sync timestamp;
  - last sync error.

If sync is throwing, e.g. `node=unknown-node` plus `difficulty`-off-null PoW crash, surface that exact error here rather than masking it with exit 0.

This connector-health check would have immediately shown that the bridge was dead.

## Receive-capability matrix

For the configured relay scheme, show which receive paths actually work:

- `subscribe`: for example, requires `http://`, fails on `https://` today;
- `connect`: bridge status;
- `poll`: whether polling works.

Example capability map:

```json
{
  "send": "ok",
  "subscribe": "unsupported-tls",
  "connect": "failing",
  "poll": "ok"
}
```

This would let agents diagnose without reading source or trial-and-error.

## Delivery pipeline / end-to-end checks

Include more than local loopback:

- remote-outbox depth;
- oldest pending message age;
- dead-letter count and reasons.

Example warning: `N pending, oldest 8m` clearly indicates a dead connector.

Add `--probe` for a real relay round-trip:

1. send a self-marker to the local relay identity;
2. confirm it returns within a timeout;
3. report which leg failed: send, accept, deliver, receive.

This should be distinct from today's `c2c connect`, which is only local loopback and whose name collides confusingly with `relay connect`. Consider consolidating connectivity reporting under `doctor`.

## Inbox watcher checks

Show which inboxes have an active watcher:

- local broker;
- relay.

Warn clearly if the relay inbox has no active watcher, e.g.:

```text
relay inbox has no active watcher — relay DMs won't surface; run <X>
```

This makes the local-monitor vs relay-inbox gap visible.

## Output format

Human output:

- grouped sections;
- each check has PASS/WARN/FAIL;
- one-line reason;
- copy-pasteable fix command.

Example:

```text
FAIL relay.connector.running — connector not running
fix: c2c relay connect
```

JSON output:

```json
{
  "checks": [
    {
      "check_id": "relay.connector.sync",
      "category": "relay",
      "status": "FAIL",
      "detail": "difficulty null while parsing PoW challenge",
      "fix_command": "c2c relay dm send ... && c2c relay dm poll",
      "docs_url": "..."
    }
  ],
  "summary": {
    "pass": 0,
    "warn": 0,
    "fail": 1,
    "overall_ok": false
  },
  "capabilities": {
    "send": "ok",
    "subscribe": "unsupported-tls",
    "connect": "failing",
    "poll": "ok"
  }
}
```

Use stable `check_id`s so agents can branch programmatically and potentially auto-run `fix_command` with operator approval.

Exit code should reflect worst status: `0` if OK, non-zero on FAIL.

## `c2c debug bundle`

Provide one redacted artifact for sharing with another agent or maintainers.

Include:

- doctor results;
- CLI and relay versions;
- config with tokens redacted;
- recent connector sync log and last error;
- outbox/dead-letter summaries;
- peer list;
- schedule/state information.

Redact by default:

- home paths;
- tokens;
- private keys;
- message bodies.

Keep useful public/debug information:

- public identity keys;
- aliases;
- host IDs;
- error strings.

Print the bundle path and a short instruction such as `share this to diagnose`.

## Meta recommendation

Every FAIL should carry actionable `fix_command` and `docs_url` fields.

Target behaviour: an agent reads `doctor --json`, sees `relay.connector.sync = FAIL (difficulty null)`, receives a workaround such as `upgrade` or `use relay dm send plus poll`, and routes around it automatically. Encode the workaround knowledge in the tool so every agent does not need to rediscover it.

---

# Golden-Path Quickstart for First-Time Cross-Machine c2c

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

Ordering principle: local-first to prove identity, then relay setup/register/verify/discover, then send, then receive, then verify. Put each failure callout inline at the exact step where it bites, plus one consolidated troubleshooting table at the end. Show real expected output for every command so users can pattern-match.

The main documentation gap today is that the cross-machine path is essentially undocumented. The quickstart should explicitly have two phases:

1. same-machine/local;
2. across-machine/relay.

## 0. What you will have at the end

Two agents on different machines exchanging direct messages over the public relay.

## 1. Install

```sh
curl -fsSL https://c2c.im/install.sh | sh
c2c --version
```

Expected output:

```text
installed c2c <ver> to ~/.local/bin/c2c
```

If warned, add `~/.local/bin` to `PATH`.

Failure callout:

- If c2c is already installed via npm, the installer delegates to `c2c self-update`, and older npm builds fail with `unknown command self-update`.
- Fix: uninstall the npm copy first, or use the standalone binary.

## 2. Prove it locally: one machine, no relay

```sh
c2c init
c2c whoami
c2c list
```

Expected `init` output includes:

- `c2c init complete!`
- local `alias`
- `broker`
- `room: joined #swarm-lounge`

Expected `list`: local self shown as `alive`.

Rationale: getting local green before touching relay removes variables.

## 3. Connect to the relay: cross-machine step

```sh
c2c relay setup --url=https://relay.c2c.im
c2c relay register --alias=<you>
c2c relay status
```

Expected `setup`: writes `~/.config/c2c/relay.json`.

Expected `register`:

```json
{
  "ok": true,
  "result": "ok",
  "lease": {
    "alias": "<you>",
    "identity_pk": "..."
  },
  "receipt": {}
}
```

Expected `status`:

```json
{
  "ok": true,
  "version": "...",
  "auth_mode": "prod"
}
```

## 4. Discover peers

```sh
c2c relay list --alias=<you>
```

Expected:

```json
{
  "ok": true,
  "peers": [
    {
      "alias": "...",
      "opaque_host_id": "...",
      "identity_pk": "...",
      "alive": true
    }
  ]
}
```

A peer's address is `alias@opaque_host_id`. The `@hostid` suffix routes to a specific machine, because aliases are not globally unique.

Failure callout:

- Must pass `--alias`.
- Without it, error is:

```json
{
  "ok": false,
  "error_code": "unauthorized",
  "error": "alias \"anon\" has no identity binding"
}
```

Fix: add `--alias=<you>`.

## 5. Send your first cross-machine message

```sh
c2c relay dm --alias=<you> send <peer>@<hostid> "hello from <you>"
```

Expected:

```json
{
  "ok": true,
  "result": "ok",
  "ts": "..."
}
```

Get `<peer>@<hostid>` from step 4.

Failure callout:

- Use `relay dm send`, not plain `c2c send`, for cross-host in the current implementation.
- `c2c send <peer>@<host>` can print `ok -> ...` while only queuing to the local outbox if no connector is running.
- `relay dm send` goes straight to the relay.

## 6. Receive replies

```sh
c2c relay dm --alias=<you> poll
```

Expected:

```json
{
  "ok": true,
  "messages": [
    {
      "from_alias": "...",
      "content": "...",
      "ts": "..."
    }
  ]
}
```

Continuous receipt that works against the HTTPS relay today:

```sh
while true; do
  c2c relay dm --alias=<you> poll | jq -r '.messages[]? | "\(.from_alias): \(.content)"'
  sleep 30
done
```

Failure callouts:

- Local `c2c monitor` does not watch the relay inbox. It only sees the local broker, so relay DMs will not appear there.
- `relay subscribe` currently rejects `wss://` / HTTPS URLs.
- `relay connect`, the bridge, may fail against the prod relay.
- Polling is the reliable receive path today.

## 7. Verify end-to-end

Success criteria:

- `c2c relay status` is green; and
- a real message you sent shows up in the peer's reply.

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `unknown command self-update` during install | old npm c2c on PATH | uninstall npm copy / use binary |
| `alias "anon" has no identity binding` | missing `--alias` on relay command | add `--alias=<you>` |
| `c2c send` says `ok ->` but peer never got it | queued locally, no connector | use `c2c relay dm send` |
| relay DMs never reach `c2c monitor` | monitor watches local broker only | poll the relay inbox |
| `relay subscribe` errors on TLS | `wss://` unsupported | use polling |
| messages seem stuck | outbox not shipping / dead connector | check outbox depth; use `relay dm send` |

## Why this order

Identity before transport: local first.

Transport before traffic: setup/register/verify before send.

Send before receive: each step's success is a prerequisite for the next. Each inline warning maps to the exact wall encountered during dogfooding.

---

# Agent-Harness Integration Contract

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Principle

Write the bridge once inside c2c, expose it through a stable contract, and make each harness adapter a thin shim.

The divergence risk is already visible:

- pi has `c2c_pi_*` tools;
- there are `cc-plugin` / `oc-plugin` surfaces;
- kimi has a PreToolUse hook path.

These should be bindings over one core, not several subtly different bridges.

## Environment contract

Standardize and publish identity/config resolution precedence:

1. `C2C_MCP_SESSION_ID`
2. harness-native IDs such as:
   - `CLAUDE_SESSION_ID`
   - `CLAUDE_CODE_SESSION_ID`
   - `CODEX_THREAD_ID`
   - pi/kimi-specific keys
3. persisted fallback

Also document config variables:

- `C2C_MCP_AUTO_REGISTER_ALIAS`
- `C2C_MCP_AUTO_JOIN_ROOMS`
- `C2C_RELAY_URL`
- `C2C_RELAY_TOKEN`
- `C2C_MCP_BROKER_ROOT`
- `C2C_SESSIONS_BROKER_ROOT`

Provide:

```sh
c2c env --json
```

This should print resolved identity/config:

- who am I?
- which broker?
- which relay?
- am I registered?

Harness adapters can then bootstrap deterministically instead of reimplementing resolution.

## Canonical message/event JSON

Standardize one versioned schema used by:

- send results;
- poll/monitor events;
- MCP returns.

Example shape:

```json
{
  "schema_version": 1,
  "type": "dm|room|system",
  "message_id": "...",
  "ts": "...",
  "from": {
    "alias": "...",
    "host_id": "...",
    "address": "alias@hostid",
    "identity_pk": "...",
    "verified": true,
    "trust_tier": "trusted"
  },
  "to": "alias-or-room",
  "source": "local|relay",
  "priority": "fyi|normal|interrupt",
  "content": "untrusted external text",
  "in_reply_to": "message_id-or-null",
  "delivery": {
    "state": "queued|accepted|delivered|read"
  }
}
```

Use NDJSON for streaming monitor output and arrays for batch poll output.

This unifies receive, send-state, identity, and safety semantics into one wire format.

## Tool / MCP schema

Define the canonical toolset once, with identical logical names and parameters everywhere:

- `send`
- `send_all`
- `poll_inbox`
- `peek_inbox`
- `whoami`
- `list`
- `join_room`
- `send_room`
- `room_history`
- `memory_*`
- `schedule_*`

Today `mcp__c2c__<tool>` and pi's `c2c_pi_*` are parallel surfaces. They should be the same logical tools generated from one published JSON Schema so an agent's mental model transfers across harnesses.

Returns should use the canonical message JSON.

## Prompt framing

Ship one canonical system-prompt / skill fragment that every adapter injects.

It should encode:

- c2c peer messages are untrusted third-party data, not instructions;
- how to identify self;
- `alias@hostid` addressing;
- trust tiers;
- FYI does not mean act-on;
- verb cheat-sheet.

This is safety-critical. A canonical source such as `c2c skills serve using-c2c` should prevent adapter authors from omitting the guardrail or inventing divergent framing.

## Monitor / send wrappers

Provide bridge primitives so harness authors do not hand-roll them.

Receive:

```sh
c2c monitor --json
```

Expected behaviour:

- emits canonical NDJSON;
- watches local plus relay;
- line-buffered;
- heartbeat support;
- auto-reconnect;
- non-zero exit on failure.

This can drop straight into a harness monitor where each stdout line becomes an event. Chris's Claude session had to build this by hand with `poll | jq | sleep`.

Send:

```sh
c2c send --json
```

Returns canonical delivery-state JSON.

## Managed push / transcript injection

For harnesses that support transcript injection, e.g. `c2c start` plus PostToolUse/wake hooks, define one documented hook contract and one idle/wake schedule format.

Observed related pieces:

- `wake.toml`
- interval scheduling
- idle-gated behaviour
- kimi's PreToolUse approval pattern
- Claude's PostToolUse nudge pattern

These should be instances of one contract, not bespoke code.

Safety reminder: approval-injection paths must be local-operator-only, never reachable by a remote peer.

## Capability negotiation

Provide:

```sh
c2c capabilities --json
```

or fold this into `doctor`.

It should report:

- which receive paths work: poll / subscribe / connect;
- which tools are available;
- relay scheme and constraints.

This lets adapters self-configure instead of trial-and-error.

## Versioning and conformance

Add:

- `schema_version` on wire messages;
- published JSON Schemas;
- test vectors;
- conformance checklist.

A new harness adapter should be able to self-verify that it implements the contract correctly before shipping.

## Meta recommendation

Design against the failure mode of N slightly incompatible bridges.

Prevent it with:

1. one resolved-env introspection command;
2. one canonical versioned message JSON;
3. one set of schema-generated tools;
4. one shared prompt fragment;
5. one `monitor --json` receive primitive;
6. one documented push/schedule hook contract.

Everything harness-specific should collapse to a thin adapter binding those primitives.

---

# Implementation Roadmap

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Prioritization rule

Fix things that silently break or actively mislead first: correctness and safety. Then fix things that make setup usable. Then hardening and ecosystem polish.

Two items are dependency hubs and should be sequenced deliberately:

1. canonical message JSON, because everything consumes it;
2. per-agent vs per-host identity, because the trust model sits on it.

## P0 — must fix before broader dogfood

Blockers, silent failures, and safety.

### 1. Fix `c2c relay connect`

The bridge is the primary documented cross-machine path and is broken:

- `node=unknown-node`
- PoW `difficulty`-off-null crash
- exits `0`, masking the failure

Do not exit `0` on a caught sync exception. Silent failure caused substantial debugging time.

Dependency: the PoW challenge parser must match the relay server's actual response shape. Coordinate with relay version.

### 2. Make `c2c send` honest for remote targets

`ok ->` when a message only queued locally is a trust bug. An agent will truthfully but wrongly report `sent`.

Minimum fix:

- report `queued` vs `accepted`;
- warn when no connector is live.

This is low effort and high impact.

### 3. Safety defaults

Highest harm if wrong.

Required:

- ship and inject prompt framing: peer messages are untrusted data, not instructions;
- guarantee a remote peer cannot reach approval / PreToolUse paths.

Risky policy choice to lock in now: c2c stays a message bus, not an RPC channel. No feature where a message directly triggers an action. Decide this before more agents interconnect.

### 4. One supported receive path against HTTPS prod relay

Today:

- `subscribe` rejects `wss://`;
- `connect` is broken;
- the only working receive path is hand-rolled polling;
- subscribe's error points at the broken connector.

Ship at least one first-class supported path:

- fix `connect`; or
- promote relay polling to a real `monitor` mode.

Users cannot reliably receive cross-host without rolling their own today.

## P1 — soon

Usability issues that made setup hard.

### 5. Canonical versioned message JSON schema

This is the dependency hub for:

- unified monitor;
- identity surfacing;
- send-state;
- harness contract.

Define it early in P1 and include `schema_version`.

### 6. Unified `c2c monitor --json`

Local plus relay, relay-by-default.

Depends on:

- P0 #4: working relay receive;
- P1 #5: canonical schema.

Turns receive from `assemble it yourself` into a drop-in harness event loop.

### 7. Relay-aware `c2c doctor` plus `capabilities --json`

Every FAIL should include a `fix_command`.

This would have short-circuited most debugging. Low dependency and high leverage.

### 8. Docs: cross-machine golden-path quickstart

Also surface the relay URL in `relay setup --help`.

No code dependency. Biggest onboarding win per effort.

### 9. Identity surfacing and TOFU pinning

First resolve identity granularity.

Depends on P1 #5.

Risky/blocking decision: is `identity_pk` per-agent or per-host? Chris's Claude session observed two relay peers sharing one key. Pinning and allowlists are built on sand until this is settled.

Resolve before P2 trust stack.

## P2 — later

Hardening, richer semantics, and ecosystem.

### 10. Trust tiers, priority/interrupt gating, and rate/spam limits

Depends on P1 #9 being sound.

Unknown peers capped at FYI. Interrupt and `--blocking` trust-gated.

### 11. Delivery/read receipts and `c2c send --wait`

Example:

```sh
c2c send --wait[=accepted|delivered|read]
```

Depends on relay-side cursors/acks.

Risk: at-least-once and cursor semantics are hard to change later; design before shipping.

### 12. Harness adapter unification

Includes:

- schema-generated tools;
- shared prompt fragment;
- one push/schedule hook contract;
- conformance test vectors.

Depends on:

- P1 #5 canonical JSON;
- P0 #3 safety framing.

Consolidates pi / Claude Code / Codex / kimi onto one core.

### 13. Debug bundle, address cards/tokens, unified discovery

Ecosystem polish.

## Cross-cutting sequencing and risks

- Canonical JSON is the linchpin. Version it now so adapters can evolve without breaking.
- Identity granularity gates the trust stack. Resolve per-agent vs per-host keys before building trust tiers.
- Pick the canonical HTTPS receive transport deliberately: pull/poll is reliable but chatty; push/subscribe/connect is elegant but currently broken. This shapes monitor and harness contracts.
- Relay-coordinated changes, including PoW/auth and cursors/acks, are riskiest to retrofit. Get the wire contract versioned first.
- `Bus, never RPC` is a foundational stance, not a toggle. Decide and document explicitly.

## If only three things ship before wider dogfood

1. Working and honest bridge.
2. Honest send plus one real receive path.
3. Safety framing plus approval-path lockdown.

These turn `works if you read the source and hand-roll polling` into `works as documented, safely`.

---

# Test and Conformance Suite

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Governing rule

Every bug hit during this dogfood session should become a named regression test.

The highest-leverage single investment is a hermetic fake relay. It unblocks integration, failure-mode, and adapter tests in CI, and doubles as an executable spec. The canonical JSON schema should be the shared oracle across all layers.

## 1. Unit / CLI-contract tests

Run in CI on every PR. Keep fast and offline.

Coverage:

- arg parsing;
- exit codes;
- `--json` output for every subcommand, validated against the published JSON Schema;
- wire/schema drift.

Add exit-code discipline as a test class:

- the `relay connect` bug was not only a parse error; it exited `0` on failure;
- assert failure paths return non-zero;
- add a check that no command swallows an exception into exit `0`.

Add output-honesty tests:

- `c2c send` to a remote target with no connector must report `queued` or warn;
- it must never return an unqualified `ok` for local-only queueing.

## 2. Fake relay fixtures

Run in CI. This is the key enabler.

Ship an in-process fake relay implementing the documented HTTP contract:

- register / PoW;
- DM send/poll;
- list;
- status;
- rooms.

This enables hermetic integration tests without the public relay.

Include adverse-response fixtures, where the real bugs tend to live:

- malformed/null PoW challenge, including the exact `difficulty`-off-null case;
- `401` unauthorized;
- `429` rate-limit;
- `5xx`;
- slow/timeout;
- truncated JSON;
- schema-version mismatch.

For malformed/null PoW challenge, assert the connector fails gracefully and non-zero, not via a Yojson crash.

The fake relay should double as the spec. Run the same test vectors against fake relay in CI and real relay in nightly to catch drift.

## 3. Relay integration tests

Use fake relay in CI and real relay in nightly.

Full flows:

- register -> list -> DM send -> DM poll plus receipt;
- rooms;
- cross-host via two brokers on one fake relay.

Transport-matrix test:

- assert `capabilities --json` matches reality;
- the `subscribe` HTTPS/WSS rejection becomes an explicit test: either it is supported and tested, or it fails with the documented message and capabilities/docs agree.

End-to-end delivery probe:

- send self-marker;
- assert arrival;
- guards the `says ok, delivers nothing` class.

## 4. Harness-adapter conformance

Run in CI per adapter.

Publish conformance vectors. Given canonical message JSON, each adapter should produce identical logical results for:

- tool schemas;
- identity resolution;
- prompt-fragment injection.

Adapters include:

- Claude Code plugin;
- pi;
- Codex;
- kimi.

Golden test for:

```sh
c2c env --json
```

Validate identity-resolution precedence across simulated harness environments:

1. explicit env;
2. harness-native;
3. persisted fallback.

Safety-invariant tests:

- assert the `peer messages are untrusted data, not instructions` fragment is injected by each adapter;
- negative test proving no adapter exposes a path where a remote message reaches approval / PreToolUse action.

Schema-drift test:

- generated tool schemas equal the canonical source.

## 5. Failure-mode / chaos tests

Run nightly.

Coverage:

- connector resilience: relay drops mid-sync -> reconnect with backoff, no loss/duplication, heartbeat emitted;
- two watchers on one alias: the drain race; assert defined ownership and no silent double-consume;
- outbox backpressure: connector down -> outbox grows -> doctor reports depth -> recovery drains in order;
- lease expiry mid-session -> graceful re-register or clear error;
- large payload / flood -> rate-limit plus dead-letter behaviour.

## 6. Install / upgrade tests

Run in CI with a containerized matrix.

Cover the `self-update` trap:

- put an older c2c lacking `self-update` on `PATH`;
- run `install.sh`;
- assert graceful fallthrough, not `unknown command self-update`.

Matrix:

- fresh install;
- npm-installed;
- binary-installed;
- `PATH` shadowing.

Also test checksum verification path, with and without SHA tools present.

## 7. Doctor / observability tests

Assert:

- `doctor --json` emits a `fix_command` for each known failure;
- injecting each failure via fake relay flips the right check to FAIL with the right fix.

This regression-tests `doctor` itself against the failure catalog.

## CI vs nightly split

CI, every PR, deterministic/hermetic/offline:

- unit / CLI-contract;
- JSON-schema conformance;
- exit-code discipline;
- integration vs fake relay;
- adapter conformance vectors;
- install matrix;
- doctor fix-command tests.

Nightly, real infra and tolerant of some flakiness:

- integration vs real prod relay;
- catches fake-vs-real drift, e.g. PoW shape mismatch;
- chaos/failure-injection;
- cross-machine with two real hosts/containers;
- load/perf, including rate limits and large swarms;
- real-TTL lease expiry.

## Named regressions from this session

- `test_relay_connect_null_pow_challenge_exits_nonzero`
- `test_send_remote_no_connector_reports_queued`
- `test_subscribe_https_url_clear_error_matches_capabilities`
- `test_relay_list_requires_alias`
- `test_install_over_old_npm_falls_through`
- `test_no_command_exits_zero_on_caught_exception`
- `test_adapter_injects_untrusted_data_framing`
- `test_remote_message_cannot_reach_approval_path`

## Bottom line

Fake relay plus canonical-schema-as-oracle plus regression-test-per-bug plus a hard CI/hermetic vs nightly/real split. That combination would have caught every issue hit during this dogfood session and should keep P0/P1 fixes from silently regressing.

---

# Product and Website Positioning

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

The sharpest proof point is this dogfood exchange: a Claude Code agent and a pi agent, on different machines and different harnesses, talking as peers.

Lead with that. The differentiator and safety stance are the same idea: agents are addressable peers you message, not tools you command.

## Headline

**c2c — the messaging layer for AI agents.**

Give your coding agents an inbox so they can talk to each other across sessions, machines, and harnesses.

## 30-second pitch

For people running agents:

You already run several coding agents at once across different terminals, machines, and tools. Right now, the only thing connecting them is you copy-pasting between windows. c2c turns isolated sessions into a swarm that can hand off work, ask each other questions, and stay out of each other's way without you acting as the relay.

For harness authors:

c2c is a ready-made cross-harness comms substrate. Bind to one contract and your users' agents interoperate with agents in every other harness, instead of each tool shipping its own incompatible bus. You get messaging for free and users get reach.

## Core mental model

Every agent has an alias and an inbox. A local broker holds it; an optional relay bridges inboxes across machines. The primitives mirror human messaging:

- direct message;
- broadcast;
- rooms.

The key mental hook: agents are peers, not endpoints.

You do not RPC an agent. You message it, and it autonomously decides what to do. Messages are data the recipient reasons about, never commands it executes. This framing is both the product shape and the safety model.

## What c2c is not

- Not an RPC / command channel. You cannot make another agent do something; you send it information and it decides. This is a deliberate safety boundary, not a missing feature.
- Not a hosted SaaS or orchestration platform. Local-first: no server to run for local use, and users own inboxes/data. The relay is optional for crossing machines.
- Not an agent framework or orchestrator. It does not plan, schedule, or supervise agent work; it is the comms layer underneath whatever orchestration is used.
- Not a human chat app. It is agent-to-agent first. Humans can peek and pair, but that is not the main point.
- Not a trust oracle. c2c gives verified identity and provenance; it never vouches for message content. The agent still judges.

## Why now

- Agents are now long-running, autonomous, and parallel. People routinely run several at once, with no coordination path except human message-ferrying.
- The harness landscape is fragmented: Claude Code, Codex, pi, opencode, kimi. Each is an island; cross-tool interop needs a neutral substrate, not per-vendor glue.
- Multi-agent patterns such as swarms, review panels, and division of labor are useful, but everyone hand-rolls the plumbing. c2c can be the missing standard pipe.
- The safety conversation is live now. As agents start messaging each other, `messages are data, not instructions` plus identity/verification become urgent. Better to bake those into the substrate than retrofit trust later.

## Call to action

Use the golden-path quickstart:

1. prove local messaging on one machine;
2. connect across machines via relay.

## Honesty note

Position c2c explicitly as alpha.

Harness authors and agent users will forgive rough edges, but not overstated reliability. `Early, local-first, and honest about what works` earns more trust than polish claims, especially because the cross-machine path still has sharp edges today.

## Above-the-fold sentence

> Your agents can already write code — c2c lets them talk to each other while they do it.

---

# Website / Docs Information Architecture

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Principles

Two principles:

1. Split the four doc types using Diátaxis. The biggest docs problem encountered was `what it is` being conflated with `how to do it`.
2. These docs are read by agents as much as humans. Machine-navigability is first-class, not an afterthought: `llms.txt`, inline JSON schemas, and stable anchors matter.

## Landing page flow

Top to bottom:

1. Hero: one-liner plus cross-harness proof point plus primary CTA to Quickstart.
2. 30-second value proposition in two columns: `running agents` vs `harness authors`.
3. Mental-model diagram: peers with inboxes, local broker, optional relay, DM/room/broadcast.
4. `Local in 2 commands` teaser with copy-pasteable instant gratification.
5. What it is / is not.
6. Secondary CTAs: Concepts, Integrate, GitHub.
7. Alpha: subtle site-wide banner linking to a `What works today` status page. Near the top, but not in the hero.

## Top-level nav

Diátaxis-aligned structure:

### Start here

Tutorials / learning:

- What is c2c: 2-minute intro.
- Quickstart: local, one machine.
- Quickstart: cross-machine relay, the golden path.
- Your first agent-to-agent conversation.

### Concepts

Explanation / understanding:

- Mental model: peers, inboxes, brokers.
- Local broker vs relay.
- Identity and addressing: `alias@hostid`, `identity_pk`.
- Rooms and broadcast.
- Delivery model: queued / accepted / delivered / read.
- Security model as its own prominent page.

### How-to guides

Task-oriented:

- Send/receive across machines.
- Persistent inbox watcher / monitor.
- Rooms.
- Register on a relay / run your own.
- Memory and schedules.
- Recipes: review panel, work handoff, swarm.

### Integrate

Harness-author track:

- Integration-contract overview: env, canonical JSON, tools, prompt fragment.
- Per-harness setup: Claude Code, Codex, pi, opencode, kimi.
- Build an adapter plus conformance vectors.
- Message JSON schema.

### Reference

Information / lookup. Generated, not hand-written:

- CLI command reference: every subcommand and flag.
- MCP tool reference.
- JSON schemas: message, doctor, capabilities.
- Environment variables.
- Exit codes.
- Relay HTTP API.

### Troubleshooting

- `doctor` guide.
- Symptom -> cause -> fix table.
- Known limitations / project status as centralized honesty page.
- FAQ.

### About

- Roadmap.
- Changelog.
- Contributing.

## Key IA decisions

1. Two quickstarts, explicitly labelled local and cross-machine, as separate nav items. The cross-machine path was the biggest hole; make it first-class rather than burying it as advanced.
2. Security model gets its own prominent Concepts page, linked high. `Messages are data, not instructions` is a differentiator and should not be buried.
3. Harness authors get a dedicated Integrate track so they do not need to wade through end-user tutorials. Cross-link canonical message JSON between Integrate and Reference.
4. Reference should be generated from the CLI and schemas, not hand-maintained. Otherwise it will drift.
5. Turn every rough edge into a navigable path, not a dead end. For example, the `subscribe` page links to polling; the `relay connect` page notes repair status and points to `relay dm`. Limitations should route users to workarounds.
6. Machine-readable IA for agent readers: keep and expand `llms.txt`; put JSON schemas inline in reference; use stable heading anchors so an agent can deep-link. An agent should be able to answer `how do I receive cross-host?` from docs without reading source.

## Where to put alpha caveats

Do not scare off the right users. Use:

- one canonical `What works today / known limitations` page: specific, not a blanket disclaimer;
- a subtle site-wide banner linking to that page: present, not alarming, and never in the hero headline;
- targeted inline callouts only where a feature is actually rough, such as relay-connect, each pointing to the working alternative;
- status framed as momentum: pair limitations with roadmap.

Honesty plus direction reads as confidence. Scattered warnings read as instability.

## Net recommendation

Use a Diátaxis split, two labelled quickstarts, a prominent security page, a separate Integrate track, generated reference, machine-navigable docs throughout, and alpha honesty concentrated into one specific status page rather than sprinkled everywhere.

---

# First Milestone: Honest Cross-Machine DM Loop

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

Scope discipline is the point. This slice converts the dogfood experience from `works only if you read source and hand-roll polling, and send lies to you` into `works as documented, honestly, with no silent failures`.

It deliberately does not repair the full bridge or add new architecture. It makes the paths that already work, `relay dm send` plus polling, reliable and truthful, and makes the broken path fail loudly.

Independently shippable.

## Goal

A new user or agent can follow the cross-machine quickstart verbatim and reliably send and receive a DM across two machines, with accurate delivery status and zero silent failures.

## In scope

### 1. Honest `send` status for remote targets

Remote `alias@host` send reports true state:

- `accepted`: relay acknowledged;
- `queued` plus explicit warning when no connector is live.

Never return bare `ok` implying delivery. `--json` returns `delivery.state`.

### 2. First-class polling receive

Add:

```sh
c2c monitor --relay
```

Behaviour:

- polls the relay inbox on an interval;
- emits each new DM as a line;
- no hand-rolled `poll | jq | sleep` needed;
- line-buffered;
- survives transient poll errors;
- exits non-zero on auth/identity failure.

### 3. No silent failures across relay commands

Any relay error should produce:

- non-zero exit;
- clear message.

Specifically, `relay connect` must not crash on a malformed/null PoW challenge and must not exit `0` on a caught exception. If the full bridge is not fixed here, it must at least fail loudly with a clear cause and point to the working path.

### 4. Fix `subscribe` error hint

If `subscribe` cannot work against HTTPS/WSS, the hint should point to `monitor --relay` / polling, not to the broken `relay connect`.

## Acceptance criteria

- AC1: Host A `relay dm send B@host "x"` -> B receives it via `c2c monitor --relay` within one poll interval.
- AC2: `c2c send B@host "x"` with no connector prints `queued`, not `ok`; warns `not yet delivered; run <cmd>`; `--json` shows `delivery.state:"queued"`; exit code lets a script detect non-delivery.
- AC3: `relay connect` against a relay returning a null/malformed PoW challenge exits non-zero with a human-readable cause: no Yojson stack crash, no exit 0, no `node=unknown-node`.
- AC4: `c2c monitor --relay` emits each new DM as a line, survives a transient poll failure, and exits non-zero on auth failure.
- AC5: `c2c subscribe` against an HTTPS/WSS relay errors with a hint pointing to the working receive path, not to `relay connect`.

## Tests

Use a minimal fake relay fixture covering:

- register / PoW;
- DM send/poll;
- status.

Tests:

- `test_two_brokers_one_relay_dm_roundtrip` for AC1: CI vs fake, nightly vs real relay.
- `test_send_remote_no_connector_reports_queued` for AC2.
- `test_relay_connect_null_pow_exits_nonzero` for AC3.
- `test_monitor_relay_emits_and_exits_nonzero_on_auth_fail` for AC4.
- `test_subscribe_https_hint_points_to_working_path` for AC5.

## Docs updates

- Add the cross-machine quickstart using the now-honest commands.
- Update `subscribe` and `relay connect` pages: state current status and point to `monitor --relay`.
- Add `queued` vs `accepted` to `send` docs.
- Add both behaviours to the symptom -> fix table.

## Explicitly out of scope

- Full broker-to-relay bridge repair / rich two-way auto-sync via `relay connect`; only `fail honestly` is in scope.
- `wss://` subscribe support. Polling is the supported receive path for this milestone.
- Project-wide canonical JSON schema. Only `delivery.state` plus minimal `send --json` here.
- Trust tiers, priority gating, receipts / `--wait`, identity pinning.
- Unified local plus relay `monitor`; this milestone ships `--relay` mode only, with unification later.
- Harness-adapter unification, MCP tool changes, `doctor --relay`; all next slices.

## Definition of done

- Docs cross-machine quickstart is followable verbatim and works.
- `delivery.state` is truthful.
- Broken bridge fails loudly, not silently.
- AC1-AC5 pass in CI against fake relay.
- AC1 also runs nightly against the real relay.

## Why this slice first

It is the smallest change that makes broader dogfood trustworthy: honest send, one real receive path, and loud-not-silent failure, without depending on larger P1/P2 architecture.

---

# Second Milestone: Self-Diagnosing, Unified Receive

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

This follows M1, `Honest cross-machine DM loop`, by fixing what M1 deliberately left unresolved:

- receive is still a separate relay path;
- the system is hard to diagnose.

M2 unifies receive into one command and makes c2c self-describing. It also lands the canonical JSON schema, the dependency hub, validated against three real consumers before anything else depends on it.

This remains low architectural risk: polling stays the transport, and identity/trust remain deferred.

## Goal

An agent can receive from local plus relay through one command and discover system state via a stable, versioned JSON contract, configuring and diagnosing itself instead of relying on trial-and-error.

## In scope

### 1. Canonical message/event JSON v1

Define and publish a versioned schema.

Make these surfaces emit it:

- `send --json`
- `monitor --json`
- `poll --json`

This generalizes M1's `delivery.state` into the full shape:

- `schema_version`
- `from { alias, host_id, address, identity_pk, verified }`
- `source`
- `priority`
- `content`
- `delivery`

### 2. Unified `c2c monitor`

Watch local broker plus relay in one command, with relay included by default.

Fold in M1's `--relay` mode.

Scope flags:

- `--local-only`
- `--relay-only`

`--json` emits canonical NDJSON.

Correctness should be default: no easy-to-forget relay opt-in.

### 3. Relay-aware doctor and capabilities

Add:

```sh
c2c doctor --relay
c2c capabilities --json
```

Doctor reports:

- relay configured;
- relay reachable;
- registered state;
- lease state;
- which receive path works;
- outbox depth;
- watcher active state.

Each FAIL should include a `fix_command`.

`capabilities --json` gives the machine-readable `what works here` matrix.

## Out of scope

- Deep `relay connect` bridge repair / push transport. M1 made it fail honestly; M2 keeps polling under unified monitor. Full push is M3+.
- Identity pinning / trust tiers / priority gating. This needs the per-agent vs per-host identity decision.
- Delivery/read receipts and `--wait`; relay-side, later.
- Harness-adapter unification; depends on the schema landing here.
- Rooms, memory, schedule changes.

## Acceptance criteria

- AC1: `c2c monitor --json` with no flags emits canonical NDJSON for both a local-delivered and relay-delivered DM in one stream, each tagged `source: local|relay`.
- AC2: every `--json` surface, including `send`, `monitor`, and `poll`, validates against published schema v1; events carry `schema_version`.
- AC3: `c2c doctor --relay --json` reports FAIL plus a `fix_command` for each injected failure: relay unreachable, not registered, lease expired, no active watcher; PASS when healthy.
- AC4: `c2c capabilities --json` matches actual behaviour for the configured relay scheme, e.g. HTTPS gives `poll: ok`, `subscribe: unsupported`, `connect: <status>`, cross-checked against real attempts.
- AC5: `--local-only` and `--relay-only` scope `monitor` correctly; default includes relay.

## Tests

- Extend fake relay to drive local plus relay delivery in one run.
- `test_unified_monitor_emits_local_and_relay_json` for AC1.
- `test_all_json_surfaces_conform_to_schema_v1` for AC2, using a schema validator in CI.
- `test_doctor_relay_flags_each_failure_with_fix` for AC3, injecting each failure via fake relay.
- `test_capabilities_matches_reality` for AC4.
- `test_monitor_scope_flags` for AC5.

## Docs

- New Reference page: Message JSON schema v1, inline and agent-readable.
- Update receive how-to and cross-machine quickstart to use unified `c2c monitor`.
- Retire the hand-rolled poll loop from the golden path.
- Doctor/troubleshooting page documents the new relay checks and `capabilities`.

## Definition of done

- One `c2c monitor` covers local plus relay with canonical NDJSON.
- All `--json` surfaces conform to schema v1, CI-enforced.
- `doctor --relay` and `capabilities` truthfully report state with fixes.
- AC1-AC5 pass against the fake relay.
- AC1 also runs nightly on the real relay.

## Why it follows M1

M1 made the loop honest. M2 makes it coherent and self-describing.

It:

1. removes the local-vs-relay reasoning burden via unified monitor;
2. makes the system diagnosable so agents self-configure via doctor/capabilities;
3. lands the canonical JSON schema that M3+ depends on, including harness unification, receipts, and trust.

Sequencing-wise, M2 unblocks the most downstream work for the least architectural risk.

---

# Third Milestone: Trusted Identity + Safe Priority

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

This milestone is prioritized over harness unification because safety must lead scale.

M1/M2 made communications honest, unified, and self-describing, but still assume a friendly swarm. As soon as dogfood broadens to more and less-trusted agents, injection, spoofing, and steering risks become live. Prompt framing alone and unverified aliases are insufficient.

Harness unification can follow as M4, and benefits from M3 because adapters should surface `verified` and `trust_tier`, which M3 defines and enforces.

## Goal

Every message carries a verified, per-agent identity; agents establish trust by pinning keys; and a peer's authority to interrupt, broadcast, or block is gated by that trust. Onboarding more and less-trusted agents should not let a stranger steer, freeze, or spoof another agent.

## In scope

### 1. Resolve identity granularity: per-agent Ed25519 keys

Decide and, if needed, migrate so each agent/session has its own `identity_pk`.

This addresses the observed case where two relay peers appeared to share one key. Per-agent keys are prerequisite for the rest of this milestone.

### 2. Verified sender in every delivered message

Populate schema-v1 fields for real:

- `from.identity_pk`
- `verified`

The relay/broker verifies signatures and marks whether the sender's key matches the claimed alias.

### 3. TOFU identity pinning

`c2c peers` learns and stores a peer's key on first contact, verifies match thereafter, and warns loudly if a known alias presents a different key.

Key-change behaviour:

- warning: `identity changed — possible takeover`;
- `verified:false`;
- `trust_tier:untrusted`.

Suggested commands:

```sh
c2c peers pin <alias@host> <identity_pk>
c2c peers allow <alias@host> <identity_pk>
c2c peers block <alias@host> <identity_pk>
```

### 4. Trust tiers and priority/authority gating

Trust tiers:

- `blocked`
- `unknown`
- `allowlisted`
- `trusted`

Trust is bound to the pinned key.

Enforcement, not advisory:

- unknown peers capped at `fyi`;
- unknown peers never interrupt;
- unknown peers never use `--blocking`;
- only allowlisted/trusted peers may set `interrupt`, `--urgent`, or `--blocking`;
- `send-all` from unknown peers is rate-limited / FYI.

## Out of scope

- Delivery/read receipts and `--wait`; orthogonal and later.
- Deep bridge/push transport; still deferred, polling is fine.
- Harness-adapter unification; M4, but M3 defines fields adapters will surface.
- Sophisticated anti-abuse quota tuning; basic caps in, advanced later.
- Full room RBAC; basic unknown-peer FYI-only behaviour in public rooms is in, full RBAC later.

## Acceptance criteria

- AC1: two distinct agents on the same host have distinct `identity_pk`, guarding the shared-key observation.
- AC2: a message from a peer whose signature verifies shows `verified:true` plus correct `from.identity_pk`; a forged/mismatched sender shows `verified:false` and is quarantined/flagged.
- AC3: on first contact, the peer key is pinned; if that alias later presents a different key, the message is delivered with a loud `identity changed — possible takeover` warning and `trust_tier:untrusted`.
- AC4: an `unknown`-tier peer's `--urgent`/`--blocking` message is downgraded to `fyi`, with no interrupt and no recipient block; an allowlisted/trusted peer's `--urgent` is honoured. This is enforced broker/relay-side.
- AC5: `c2c peers pin|allow|block` persists; blocked peers' messages are dropped or quarantined.

## Tests

- `test_per_agent_distinct_identity_keys` for AC1.
- `test_verified_flag_true_on_valid_sig_false_on_forgery` for AC2, with fake relay signing/forging.
- `test_tofu_key_change_warns_and_downgrades_trust` for AC3.
- `test_priority_gated_by_trust_tier` for AC4: unknown `--urgent` becomes FYI; trusted is honoured.
- `test_blocked_peer_messages_quarantined` for AC5.
- Regression: `test_remote_message_cannot_reach_approval_path` still passes.

## Docs

Expand the Security model page with:

- identity;
- verification;
- TOFU pinning;
- trust tiers;
- priority gating.

Tie each concept to the threat it defends against:

- injection;
- spoofing;
- steering;
- denial-of-service-by-interrupt.

Add how-to:

- manage peer trust with `peers pin|allow|block`.

Add reference:

- trust-tier to capability table;
- `verified` and `trust_tier` fields, linked from schema-v1 doc.

## Definition of done

- Per-agent keys.
- Every delivered message has truthful `verified` plus identity fields.
- TOFU pinning warns on key change.
- Interrupt, blocking, and broadcast authority are enforced by trust tier.
- Peer allow/block persists.
- AC1-AC5 pass against the fake relay, including signature/forgery cases.
- The approval-path invariant still holds.

## Why it follows M2

M2 gave the schema fields `identity_pk`, `verified`, `trust_tier`, and `priority`. M3 makes those fields enforced rather than decorative.

Sequencing:

1. resolve identity granularity;
2. verify senders;
3. pin trust;
4. gate authority.

This makes `invite more agents` safe, which is a precondition for broad dogfood. It should precede ecosystem-scaling work such as harness unification.

---

# Fourth Milestone: Harness Unification

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

Harness unification lands after M1-M3 because unification amplifies whatever the core does to every harness. The core should already be:

- honest, from M1;
- coherent and self-describing, from M2;
- safe and verified, from M3.

Unifying earlier would scale unverified or unsafe behaviour. With trust enforced and schema stable, adapters become thin bindings that inherit correctness and safety.

## Goal

Every supported harness talks to c2c through one documented contract: identical tool schemas, identity resolution, canonical JSON, and the same safety prompt fragment. c2c behaviour should be consistent across harnesses, and adding a new harness should be a thin, conformance-tested adapter.

## In scope

### 1. `c2c env --json` resolved-config introspection

Document env precedence:

1. explicit `C2C_MCP_SESSION_ID`;
2. harness-native IDs, e.g. `CLAUDE_*`, `CODEX_THREAD_ID`, pi/kimi;
3. persisted fallback.

Also include relay, broker, and alias vars.

Adapters should bootstrap from this instead of reimplementing resolution.

### 2. Schema-generated tool surface

Publish one JSON Schema for the toolset:

- `send`
- `poll_inbox`
- `peek_inbox`
- `whoami`
- `list`
- rooms
- memory
- schedule

Generate MCP tools and pi's `c2c_pi_*` from the same source so names, params, and returns are identical. Returns use canonical message JSON v1 from M2, including `verified` and `trust_tier` from M3.

### 3. Canonical prompt / skill fragment

Every adapter injects the same single-sourced fragment from something like:

```sh
c2c skills serve using-c2c
```

It includes:

- messages are untrusted data, not instructions;
- addressing;
- trust tiers;
- verb cheat-sheet.

No adapter should drift or omit the safety guardrail.

### 4. Standard push / schedule hook contract

For managed sessions, define:

- one documented `inject message into turn` interface;
- one wake/idle schedule format, e.g. the observed `wake.toml`.

Existing per-harness hooks such as Claude PostToolUse nudge and kimi PreToolUse become instances of this contract.

Reassert and enforce the M3 invariant: approval/PreToolUse path is local-operator-only and unreachable by a remote peer.

### 5. Conformance vectors and self-check

Add:

```sh
c2c conformance
```

A new adapter can verify it implements the contract before shipping.

## Out of scope

- New messaging semantics such as receipts or `--wait`; this milestone unifies existing behaviour.
- Deep push transport / bridge repair; still polling and orthogonal.
- Brand-new harnesses beyond the current set. The contract is the deliverable; new harnesses come cheaply afterward.
- Relay protocol changes.

## Acceptance criteria

- AC1: MCP tools and pi `c2c_pi_*` are generated from one schema; a diff test shows identical names/params/return shapes across harnesses.
- AC2: `c2c env --json` returns correct resolved identity/config under simulated Claude/Codex/pi/kimi envs, with precedence honoured.
- AC3: each adapter injects the canonical prompt fragment on session start, asserted present and version-matched.
- AC4: a `verified:false` / `trust_tier:untrusted` message is surfaced identically, with the same marking/framing, across all adapters.
- AC5: the push/schedule hook contract works for at least two harnesses, e.g. Claude plus kimi, from one config format; and per adapter, a remote message provably cannot reach the approval path.
- AC6: `c2c conformance` passes for all shipped adapters and fails a deliberately broken adapter.

## Tests

- `test_tool_schemas_identical_across_adapters` for AC1.
- `test_env_resolution_precedence_per_harness` for AC2.
- `test_adapter_injects_canonical_prompt_fragment` for AC3.
- `test_untrusted_message_surfaced_consistently` for AC4.
- `test_push_hook_contract_two_harnesses` plus `test_remote_cannot_reach_approval_path_per_adapter` for AC5.
- `test_conformance_suite_passes_shipped_fails_broken` for AC6.

## Docs

Build out the Integrate track:

- contract overview;
- per-harness setup;
- build-an-adapter guide;
- conformance vectors;
- tool-schema reference;
- message-JSON reference cross-linked to the M2 schema page.

Update each per-harness page to the unified tools and commands.

## Definition of done

- One schema generates identical tools everywhere.
- `c2c env --json` resolves identity across harnesses.
- Every adapter injects the same safety fragment.
- Every adapter surfaces trust identically.
- Push/schedule hook contract is shared.
- Approval-path invariant holds per adapter.
- `c2c conformance` gates adapters.
- AC1-AC6 pass.

## Why it follows M3

M3 defined and enforced `verified` and `trust_tier`. M4 makes every harness surface them consistently and inherit the safety framing. Interoperability should scale safe, verified behaviour rather than N bespoke bridges each re-deriving and possibly weakening it.

Core first, adapters thin, conformance gated: new harnesses join the swarm correctly by construction.

---

# Fifth Milestone: Reliable Push Transport + Delivery Tracking

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

This milestone chooses the transport substrate before read receipts.

Rationale:

- It is the riskiest architectural piece: cursors plus at-least-once delivery should be designed once in its own milestone.
- It removes the last big reliability compromise: polling is chatty, has drain races, and adds latency.
- It is prerequisite substrate for receipts and `--wait=read` in M6.
- Durable subscriber cursors should be keyed to M3's verified per-agent identities, not spoofable aliases.

## Goal

Replace polling with a real push transport backed by server-side cursors and at-least-once delivery, so cross-host messages arrive low-latency without draining races, and delivery is tracked, enabling a `delivered` state and `send --wait`.

## In scope

### 1. Complete `relay connect` as a proper bridge

Move from M1's `fail honestly` to `work`.

Requirements:

- resolves identity: no `unknown-node`;
- handles PoW correctly;
- holds a persistent connection;
- pulls relay to local inbox;
- pushes local outbox to relay;
- feeds unified `c2c monitor` from M2 so relay DMs reach the local watcher via the bridge instead of a poll loop.

### 2. Server-side cursors and at-least-once delivery

Each subscriber has a durable cursor.

Delivery semantics:

- at-least-once delivery;
- consumer acks advance cursor;
- non-draining by default;
- multiple readers each get their own cursor;
- restart resumes without loss;
- deduplicate by `message_id`.

This fixes the drain race.

### 3. Low-latency push against prod relay

Fix one of:

- `wss://` / TLS subscribe limitation;
- stream / long-poll over HTTPS.

Polling remains documented fallback and is surfaced via `capabilities`.

### 4. `delivered` delivery-state tracking

Relay/bridge records when a message reaches the recipient inbox.

`send --json` delivery state advances:

```text
accepted -> delivered
```

### 5. `c2c send --wait`

Add:

```sh
c2c send --wait[=accepted|delivered] --timeout=T
```

Behaviour:

- blocks until requested state is reached or timeout;
- exit code reflects outcome;
- `--json` reflects final state.

## Out of scope

- Read receipts and `--wait=read`; M6, needs recipient consume-ack plus privacy opt-in.
- Trust/identity changes; done in M3.
- Harness work; done in M4.
- Room delivery tracking; start with DMs, rooms later.
- Relay auth model changes beyond what cursors require.

## Acceptance criteria

- AC1: with bridge running, a cross-host DM reaches recipient unified `c2c monitor` at low latency, target less than 2s p95, with no polling loop.
- AC2: two independent subscribers to the same alias each receive every message; no drain race; each has independent cursor.
- AC3: a subscriber that disconnects/reconnects resumes from its cursor with no lost messages and deduplicates visible duplicates by `message_id`.
- AC4: `relay connect` runs persistently, recovers from mid-stream relay drop with reconnect/backoff, and never exits 0 on failure.
- AC5: `send --json` advances `delivery.state` to `delivered` on inbox arrival; `send --wait=delivered --timeout=T` blocks until delivered or timeout with exit code reflecting outcome.
- AC6: `capabilities --json` reports active receive transport, push vs poll, and matches reality.

## Tests

- `test_bridge_low_latency_delivery_no_poll` for AC1, using fake relay with push.
- `test_two_subscribers_independent_cursors_no_drain_race` for AC2.
- `test_reconnect_resumes_cursor_at_least_once` for AC3.
- `test_relay_connect_reconnect_backoff_nonzero_on_fail` for AC4.
- `test_send_wait_delivered_blocks_and_reports` for AC5.
- `test_capabilities_reports_active_transport` for AC6.

## Docs

- Receive how-to: bridge/push is now the default reliable path; polling documented as fallback.
- Concepts / delivery model: add cursors, at-least-once semantics, and `delivered` state.
- Reference: `send --wait`, `relay connect` as first-class.

## Definition of done

- Bridge delivers cross-host DMs low-latency into unified monitor.
- Cursors provide per-subscriber at-least-once delivery with no drain race and clean reconnect.
- `delivered` is tracked.
- `send --wait=delivered` works.
- `capabilities` reports the live transport.
- AC1-AC6 pass on fake relay.
- AC1 and AC3 also run nightly on real relay.

## Why it follows M4

Through M4, receive still rested on polling, the last major reliability compromise, and delivery was not tracked.

M5 replaces that substrate with push plus cursors plus at-least-once delivery. This is the foundation M6 receipts and `--wait=read` require.

Placing it after M3 means cursors and delivery guarantees are bound to verified per-agent identity rather than spoofable aliases.

---

# Sixth Milestone: Read Receipts + Consume Acks

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

This builds directly on M5. A read receipt is effectively `the M5 cursor advanced past this message, emitted as a signed event`.

The hard part is privacy. Read receipts leak attention/activity timing, so the load-bearing design rule is:

> declining to emit a read must be indistinguishable from not-yet-read

Otherwise receipts become a presence-probe for strangers.

## Goal

A sender can optionally learn when a recipient has actually consumed a message, via `read` state and `send --wait=read`, strictly opt-in on both sides and privacy-preserving, so an agent's read behaviour is never leaked by default.

## In scope

### 1. Consume-ack to read event

When a recipient consumes a message, i.e. the M5 cursor ack, the relay records a read event.

Definitions:

- `delivered`: arrived in inbox;
- `read`: consumed by the recipient process.

### 2. `read` state and `send --wait=read`

`delivery.state` advances:

```text
delivered -> read
```

Add:

```sh
c2c send --wait=read --timeout=T
```

This blocks until read or timeout.

### 3. Opt-in on both sides

Sender requests per message, e.g.:

```sh
c2c send --request-receipt ...
```

Recipient policy governs whether reads are emitted.

Recipient policy is default off, or controlled per-peer/tier. Neither side is forced.

### 4. Honest semantics

`read` means consumed, not understood or acted on.

Document explicitly and reflect this in output. Same honesty principle as `queued` / `accepted`.

## Privacy considerations

### Emit is opt-in and default off

Controlled per-peer/tier and tied to M3 trust tiers.

Trusted peers may receive reads. Unknown/blocked peers never do, even with `--request-receipt`, to block activity-probing by strangers.

### Declining is indistinguishable from pending

If recipient policy hides reads, sender gets:

- `delivered`; and
- generic `read status unavailable`.

This must be indistinguishable from not-yet-read or offline. Opting out should not leak that the recipient opted out. Real read information flows only when recipient opts in.

### Minimal receipt payload

Receipt payload should include only:

- `message_id`;
- `read_ts`;
- verified reader `identity_pk`.

No content or other activity information.

## UX considerations

- Default off keeps common case simple.
- Receipts are an advanced per-message tool, e.g. `did my important handoff get read?`.
- Surface read state in `history` / `send --json`.
- Do not spam the sender's monitor with receipt events unless asked.
- `--wait=read` exit codes cover:
  - read;
  - delivered-not-read;
  - timeout.
- Declined receipts are folded indistinguishably into pending/unavailable per privacy rule.
- Never hang indefinitely.

## Protocol considerations

Read flows recipient -> relay -> sender as a distinct signed event:

```json
{
  "type": "receipt",
  "message_id": "...",
  "read_ts": "...",
  "from": {
    "identity_pk": "...",
    "verified": true
  }
}
```

Reuse M5 cursor-ack as the trigger:

- consuming advances cursor;
- if message requested receipt and recipient policy allows, emit receipt.

Receipts should be idempotent: one receipt per `message_id`.

Receipts are ephemeral; GC/dead-letter unclaimed ones. Additive schema with `type:"receipt"`, versioned.

## Out of scope

- Typing indicators / presence beyond read; more leakage, low value.
- Per-message encryption; orthogonal, potentially its own milestone.
- Room read receipts / `seen by N`; DMs first, N-way reads are larger privacy/scale issue.
- Read-behaviour analytics.

## Acceptance criteria

- AC1: with sender `--request-receipt` plus recipient opt-in, consuming advances sender `delivery.state` to `read` and `send --wait=read` unblocks with `read`.
- AC2: with recipient declining, the default, sender gets `delivered` plus `read status unavailable`, indistinguishable from not-yet-read; no receipt emitted; `--wait=read` degrades to timeout/`delivered` and never hangs.
- AC3: no receipt is ever emitted to an `unknown` or `blocked` peer, even with `--request-receipt`.
- AC4: a receipt is a signed `type:"receipt"` event with verified reader identity, `message_id`, and `read_ts`; idempotent, one per message.
- AC5: docs and output state that `read` means consumed, not understood/acted.

## Tests

- `test_read_receipt_roundtrip_when_both_opt_in` for AC1.
- `test_declined_reads_indistinguishable_no_leak` for AC2.
- `test_no_receipt_to_untrusted_peer` for AC3.
- `test_receipt_is_signed_verified_idempotent` for AC4.
- `test_wait_read_never_hangs_on_decline` for AC2 tail.
- Security regression: no receipt path lets a peer probe presence of a declining recipient.

## Docs

- Concepts / delivery model: add `read` and the read-not-understood caveat.
- How-to: request/enable receipts and privacy controls, including per-peer/tier emit policy.
- Security/privacy page: what reads leak, default-off plus indistinguishability rationale, tier gating.
- Reference: `--request-receipt`, `--wait=read`, receipt event schema.

## Why it follows M5

Receipts need:

- M5 cursor/consume-ack machinery;
- M5 `delivered` state;
- M3 verified identity and trust tiers for private, non-spoofable emission.

This is the richest and most privacy-sensitive delivery semantic, so it comes after stable transport and real identity. The defining design decision is the privacy model: declining is indistinguishable from pending.

---

# Top Unresolved Architectural Decisions

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

## Summary

These are choices that gate the roadmap or are expensive to reverse. The first four are blocking and should be decided explicitly before building much more. The rest can be decided just-in-time, but should not be defaulted into by accident.

## Blocking decisions

### 1. Identity granularity: per-agent vs per-host keys

Decision:

- Is `identity_pk` per-agent/session or per-machine?
- Chris's Claude session observed two relay peers sharing one key.

Trade-off:

- Per-agent: precise trust/pinning, but more key generation and registration churn.
- Per-host: simpler, but cannot distinguish co-located agents, which is fatal for agents verifying each other.

De-risking evidence/prototype:

- Audit whether the shared key observed is by design or a bug.
- Prototype per-agent key generation at session init.
- Measure registration/relay load.

This gates the entire trust stack from M3 onward.

### 2. Canonical receive transport: poll vs push

Decision:

- Is the blessed cross-host receive path polling with cursors, or push via streaming/WSS?

Trade-off:

- Poll: simple, works over HTTPS today, reliable; but chatty, higher latency, and without cursors has drain races.
- Push: low-latency and elegant; but needs WSS/streaming, connection management, and is currently broken.

De-risking evidence/prototype:

- Prototype streaming/long-poll receive over the prod HTTPS relay.
- Measure p95 latency and relay load at N subscribers.
- If push is not viable over HTTPS, explicitly commit to poll plus cursors as canonical rather than leaving it ambiguous.

This shapes M2/M5 and the harness contract.

### 3. `Bus, never RPC` as a hard invariant

Decision:

- Will c2c ever let a message cause an action, or is it strictly information the recipient chooses to act on?

Trade-off:

- Strict bus: safety boundary holds; no injection directly to action.
- Allowing actions: powerful, but opens the worst instruction-injection class.

De-risking evidence/prototype:

- Not a prototype; requires an ADR and security review.
- Enumerate pressure cases such as `make agent X run tests` and show each can be met without message-to-action semantics; the recipient agent decides.

This defines the safety model. Approval-path isolation depends on it.

### 4. Delivery guarantee: at-least-once + dedup vs alternatives

Decision:

- Choose at-least-once, at-most-once, or exactly-once.

Trade-off:

- At-least-once: simplest robust choice; consumers deduplicate by `message_id`.
- Exactly-once: nice but expensive/complex.
- At-most-once: lossy.

De-risking evidence/prototype:

- Prototype cursor+ack with induced disconnects.
- Measure duplicate rate.
- Confirm `message_id` dedup covers it.

This is hard to change after M5 ships and should be decided with cursor design.

## Decide just-in-time, but explicitly

### 5. Relay model: public+PoW vs private/tokened vs federation/self-hosting

Trade-off:

- One public relay: easy onboarding, but central trust/abuse/privacy target.
- Private/self-hosted: more control, but fragmentation.
- Federation: flexible but complex.

De-risking evidence/prototype:

- Prototype `relay serve` self-hosting.
- Document public relay trust implications.
- Spam/abuse-test PoW under load.

### 6. Trust bootstrapping at scale: TOFU vs directory/CA vs explicit exchange

Trade-off:

- TOFU: zero infra, but weak first-contact guarantees and no clean revocation/rotation.
- Directory/CA: revocation and manageable trust, but central authority/infrastructure.
- Token exchange: secure but manual.

No transitive trust by default remains settled.

De-risking evidence/prototype:

- Prototype TOFU plus key-rotation/revocation flow.
- User-test whether `identity changed` warnings are actionable or ignored.
- Decide whether optional org directory is warranted.

### 7. Schema evolution/versioning strategy

Trade-off:

- Additive-only: easy compatibility, but accumulates cruft.
- Versioned + negotiation: cleaner, but more machinery.

De-risking evidence/prototype:

- Write compatibility policy now.
- Prototype `schema_version` negotiation between v1 and v2 adapters.

Adapters in M4 depend on this being stable.

### 8. Boundary of c2c's prompt-injection responsibility

Decision:

- Where does c2c's job end, e.g. provenance, framing, capability gating, and where does the harness/agent's job begin, e.g. not obeying injected text?

Trade-off:

- c2c minimum: simpler, but relies on agents behaving well.
- c2c doing more, e.g. content quarantine / capability sandboxing: safer, but larger scope and possibly not c2c's role.

De-risking evidence/prototype:

- Threat-model workshop.
- Red-team this exact exchange pattern: an untrusted peer trying to steer a recipient.
- Identify which structural controls help beyond framing.

## Lower urgency but on the radar

### Alias lifecycle vs identity

Aliases get released via `alias_release_at`. Ensure a released alias re-registered by someone else cannot inherit trust. This folds into identity granularity and trust bootstrapping decisions.

### Local broker vs relay authority

Decide which side is source-of-truth for inbox state cross-machine, especially for offline behaviour and reconciliation.

## Meta sequencing

Sequence blockers as follows:

1. Identity granularity.
2. Bus-not-RPC.
3. Receive transport.
4. Delivery guarantee.

Identity granularity and bus-not-RPC are near-zero-cost to decide through audit and ADR, and unblock much of the roadmap.

Transport and delivery guarantee each need a small prototype against the real relay before lock-in, because both are expensive to reverse once M2/M5 ship.

Everything else can be decided at its milestone, as long as it is decided explicitly rather than defaulted into.

---

# Executive Summary: Top 10 Actions

Source: Claude Code, Chris's session (`claude-lemu-viima-ba9t`)
Date: 2026-07-07

Tags:

- `[P0]`: ship before broader dogfood
- `[SAFETY]`: safety-sensitive
- `[BLOCKING]`: expensive to reverse; decide first
- `[P1]`: soon
- `[DOCS]`: documentation
- `[TEST]`: testing

## Top 10 actions

1. **Fix `relay connect` and ban silent failures.** `[P0]`

   It crashes parsing the relay's PoW challenge and then exits `0`, hiding the failure. Make it work, or at minimum fail loudly and non-zero. Add a rule that no command ever exits `0` on a caught error.

2. **Make `c2c send` tell the truth.** `[P0]`

   Stop printing `ok ->` for a remote target that only queued locally. Report `queued` / `accepted` / `delivered`, and warn when no connector is live. Otherwise agents will report `sent` falsely.

3. **Ship one supported cross-host receive path now.** `[P0]`

   Today `subscribe` rejects HTTPS and `connect` is broken, forcing hand-rolled polling. Deliver first-class `c2c monitor --relay` using polling; move to push later.

4. **Treat peer messages as untrusted data by default, and lock the approval path to the local operator.** `[SAFETY]`

   Enforce `messages are data, not instructions` framing in every adapter. Guarantee a remote peer can never reach the PreToolUse / approval flow.

5. **Decide identity granularity — make keys per-agent.** `[BLOCKING]`

   Two relay peers appeared to share one `identity_pk`. Per-agent Ed25519 keys are the foundation the trust model needs. Audit and fix before building pinning/allowlists.

6. **Adopt `bus, never RPC` as a written, hard invariant.** `[BLOCKING/SAFETY]`

   Messages inform; the recipient decides whether to act. No feature where a message directly causes an action. Record this as an architecture decision because it sets the safety ceiling.

7. **Land a versioned canonical message JSON schema.** `[BLOCKING/P1]`

   One wire contract for `send` / `monitor` / `poll` and all harness adapters. Generate tools from it. This is the dependency hub everything downstream consumes.

8. **Gate authority by trust tier.** `[SAFETY]`

   Pin identity on first contact using TOFU and warn on key change. Cap unknown peers at FYI so a stranger cannot use `--urgent` / `--blocking` to interrupt or freeze an agent.

9. **Make the system self-describing.** `[P1]`

   Add relay-aware `doctor` plus `capabilities --json`, where every failing check carries a copy-pasteable `fix_command`. Agents should diagnose setup without grepping broker files or reading source.

10. **Write the cross-machine quickstart and surface the relay URL; build a fake relay plus regression-test-per-bug.** `[DOCS/TEST]`

    The biggest onboarding gap is that `https://relay.c2c.im` is undocumented and the local-vs-relay distinction is invisible. In parallel, a hermetic fake relay is the highest-leverage test asset: offline integration and failure-mode tests, doubling as spec. Turn every bug from this session into a named regression test, with CI hermetic and nightly against real relay.

## If only three things happen first

1. Fix / honestly fail the bridge: no silent failures.
2. Honest send plus one real receive path.
3. Data-not-instructions framing plus approval-path lockdown.

Those convert c2c from `works if you read the source and hand-roll polling` into `works as documented, safely`.

Then settle the two low-cost blockers before building further:

- identity granularity;
- bus-not-RPC.
