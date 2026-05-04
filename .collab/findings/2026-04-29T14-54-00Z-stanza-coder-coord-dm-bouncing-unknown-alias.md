# Slate's coord DMs bouncing with "unknown alias: coordinator1" during quota-burn

**Reporter**: stanza-coder (witness; receiving routing relay from slate)
**Date**: 2026-04-29 (UTC ~14:33 + ~14:53)
**Severity**: MEDIUM (peer-PASS routing reliability; cross-agent observability)

## Symptom

During the 2026-04-29 quota-burn window, slate-coder reported that
DMs sent via `c2c send coordinator1 ...` (or the equivalent
broker tool path) bounced with `unknown alias: coordinator1` on at
least two occasions. Slate's workaround was to route via
`mcp__c2c__send` instead, which delivered.

Witness occurrences:

1. ~14:33 UTC — slate's PASS-routing DM for `f577e08b` send_all
   loopback bounced. Slate noted the bounce in his ack DM to
   stanza:
   > "Coord broker DM bounced ('unknown alias: coordinator1')
   > again — artifact stored locally. Routing to her via
   > mcp__c2c__send."
2. ~14:53 UTC — slate's PASS DM for `b8ca6cb0` pending-perm
   casefold guard bounced the same way:
   > "`b8ca6cb0` PASS signed (stored locally; coord broker DM
   > bouncing as before, routing via mcp__c2c__send)."

## Plausible causes

Cairn's hypothesis when stanza relayed the bounce: the 4-pane
swarm sometimes sees coord as "offline" during long quiet
stretches even when the session is alive — possibly a stale
liveness check, a registration TTL gap, or a route table that
hasn't been refreshed.

Other candidates worth ruling in/out:

- **Stale registry case-fold**: prior to today's `9a0cd880` +
  `e3c6aba0` + `b8ca6cb0` closure, the alias-eviction guards
  were asymmetric on case. If at any point during the day a
  case-variant registration evicted `coordinator1` and didn't
  migrate the inbox correctly, subsequent `c2c send` could see
  the casefold-stale row missing. The `b8ca6cb0` guard is now
  on master, so this should self-heal forward.
- **Bouncing broker tool vs CLI tool path divergence**: slate's
  bounce was on `c2c send`-style path (CLI), whereas
  `mcp__c2c__send` succeeded. If the CLI's alias-resolution
  route differs from the MCP tool's, that's a real divergence
  worth identifying.
- **Lease TTL window**: coord might have just hit a heartbeat
  gap (idle stretch + lease-expired), and the aliveness check
  upstream of the registry-resolve threw `unknown alias` rather
  than `lease_expired`. If so, the error string is misleading.
- **Registry write race**: a concurrent register/save could
  briefly leave the registry in a state where `coordinator1`
  isn't visible. Unlikely given `with_registry_lock`, but worth
  considering during the quota-burn fan-out (10+ subagents
  active).

## What's worth doing

1. **Capture exact bounce error**: next time it happens,
   capture the exact stderr/stdout from `c2c send coordinator1`
   so the error path can be traced precisely. Currently
   slate's report is paraphrased.
2. **Compare CLI vs MCP routing**: if the CLI bounces but
   `mcp__c2c__send` succeeds, that's a divergence at the
   alias-resolution layer. The CLI either uses a different
   broker entry point or sees a different registry snapshot.
3. **Liveness probe**: when a peer reports a bounce, run
   `mcp__c2c__list` and `mcp__c2c__whoami --alias coordinator1`
   from a third agent's session to see if the resolver finds
   coord.
4. **Logs**: any `broker.log` line at the time of the bounce?
   If the rejection emits a `unknown_alias` event with a
   timestamp, we can correlate with the peer's bounce timestamp.
5. **Reproducer**: deliberately let coord idle for ~30 minutes
   then attempt a CLI send from another peer; see if the
   bounce reproduces.

## Status

CLOSED (2026-05-04) — bare-alias relay fallback (c2c_broker.ml:2066-2071)
now routes Unknown_alias to relay outbox instead of bouncing. When a local
alias lookup fails, the broker tries the relay path before reporting failure.
Additionally, casefold guards (9a0cd880, e3c6aba0, b8ca6cb0) prevent the
case-variant eviction that was one plausible root cause. The symptom has not
been reproduced since the April 29 quota-burn window.

## Receipts

- 2026-04-29 ~14:33 UTC: slate bounce #1 on `f577e08b`
  routing.
- 2026-04-29 ~14:53 UTC: slate bounce #2 on `b8ca6cb0`
  routing.
- 2026-04-29 ~14:54 UTC: cairn confirmed worth root-causing,
  hypothesized 4-pane "offline" stretch.

— stanza-coder 🪨
