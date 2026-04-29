# Finding: DM mis-delivered to wrong alias

**Date**: 2026-04-29T
**Severity**: medium
**Status**: observed, root cause TBD

## Symptom

Stanza-coder sent a FAIL review DM for `d95bf079` intended for `galaxy-coder`.
The message was delivered to `cedar-coder` instead.

The DM used `to_alias: galaxy-coder` explicitly in the c2c_send call.
Envelope correctly showed `from="stanza-coder"` (stanza's own alias).
The misdelivery was in the *to* path — routed to cedar instead of galaxy.

## Context

This occurred after #379 S2/S3 cross-host alias@host changes landed.
Stanza's FAIL review was for `d95bf079` (a local worktree commit).

## Possible causes (per stanza)

1. **Alias collision in routing**: `galaxy-coder` and `cedar-coder` may share the same
   alias pool hash or some routing key that caused `to_alias: galaxy-coder`
   to resolve to cedar's session
2. **Cross-host routing bug (post-#379)**: the `alias@host` resolution may have
   matched cedar instead of galaxy when the alias was looked up
3. **Broker registration issue**: stanza's registered alias may have drifted
   to cedar's registration entry
4. **Pre-existing routing bug unmasked by #379**: the root cause may predate
   #379 but surface only now

## Investigation path (per stanza)

1. Pull `broker.log` lines around the timestamp of the misdelivery
2. Check registry state: were stanza/galaxy/cedar all registered with distinct session_ids and aliases at that moment?
3. Look at `Broker.send_to` (or whatever the routing path is) for any alias→session_id resolution that could silently fall through to a different match

## Evidence

- Stanza's FAIL review was explicitly addressed to `galaxy-coder` in the `c2c_send` call
- cedar received it instead
- No explicit routing to cedar was intended by stanza
- This is an isolated incident — other DMs to galaxy-coder have arrived correctly
- Timestamp: approximately when stanza filed the FAIL for `d95bf079` (2026-04-29, mid-session)

## Next step

Need broker.log entries + registry state at time of misdelivery.
Filed by: stanza-coder (acknowledged to cedar); noted here for investigation.
Priority: medium — could be a regression from #379 cross-host changes.

**Status update (stanza, 2026-04-29):** evidence flips the conclusion — see Investigation section. No broker bug found; symptom appears to be a false-positive misattribution by cedar.

## Investigation (stanza, 2026-04-29)

### Direct archive evidence — the FAIL DM is in galaxy's archive, NOT cedar's

The actual FAIL DM exists in only one place:

```
/home/xertrov/src/c2c/.git/c2c/mcp/archive/galaxy-coder.jsonl
  ts=1777422707.258607 stanza-coder -> galaxy-coder
  | "**`d95bf079` #422 v2 FAIL** — no artifact (skill rubric: …)"
```

`grep d95bf07` across **every** `archive/*.jsonl` returned exactly two
stanza-from rows, both `stanza-coder -> galaxy-coder`
(ts 1777422707 + ts 1777422875 the resend). **Zero rows of any
`stanza-coder -> cedar-coder` carrying the FAIL content** in either
broker (legacy `.git/c2c/mcp/` or canonical
`~/.c2c/repos/8fef2c369975/broker/`).

Cedar's archive in the bounce window (1777421000–1777422800) contains
only her own session heartbeats + four coordinator1 DMs about #330
V1. The most recent before her bounce (sent at ts=1777422750) was
coord at ts=1777422721 telling cedar "Stanza on V2" — the only
mention of stanza in her inbox at that moment.

Cedar's bounce DM to stanza arrived 29s after coord's "Stanza on V2"
note. The FAIL DM stanza claims was misrouted is provably **not in
cedar's inbox archive at all**.

### Code review of the routing paths

1. `Broker.enqueue_message` (c2c_mcp.ml:1689) — local path resolves
   via `resolve_live_session_id_by_alias` (line 1206), which filters
   `reg.alias = alias` (case-sensitive equality, line 1208). A live
   match yields `Resolved session_id`; the inbox is written to
   `inbox_path t ~session_id`. There is no fall-through to a sibling
   alias on miss — `Unknown_alias` raises `invalid_arg`, not "pick
   another." Lookup ordering returns the FIRST alive registration if
   duplicates exist, but galaxy and cedar are on distinct
   session_ids + distinct PIDs + distinct enc_pubkeys (verified in
   `.git/c2c/mcp/registry.json`). No collision possible.

2. `is_remote_alias` (c2c_mcp.ml:1686) only fires when `to_alias`
   contains `'@'`. Plain `"galaxy-coder"` never enters the relay
   outbox path. So the #379 S2 `alias@host` resolution
   (`split_alias_host` in relay.ml:407, `host_acceptable` line 418)
   was not on the codepath for this DM.

3. Alias rename (c2c_mcp.ml:4510-4527) requires the same `session_id`
   to re-register under a different alias with PID continuity.
   Galaxy's session_id is `galaxy-coder`, cedar's is `cedar-coder`
   — they never shared a session_id, so no rename could have
   crossed the streams.

4. `alias_casefold` is used in suggest_alias_prime (line 1572) and
   collision detection but not in `resolve_live_session_id_by_alias`
   itself (#332 risk noted: case-sensitive resolve vs case-insensitive
   collision check is a real latent inconsistency, but not the cause
   here — both aliases are already lowercase).

5. `broker.log` has no per-DM `from`/`to` field on `tool":"send"`
   entries (only `ok` boolean), so it can't refute or confirm
   routing — but the `archive/*.jsonl` files DO record the canonical
   delivered envelope, and they unambiguously place the FAIL at
   galaxy.

### Hypothesis ranking

1. **Most likely — false positive from cedar's side.** Cedar saw
   coord's "Stanza on V2" DM, may have been juggling context from
   her #422 review history (cedar reviewed #422 v1 earlier in the
   session — see ts=1777389733/1777389804 entries in her archive),
   and conflated "stanza mentioned + #422 history + V2/v2 token
   collision" into "stanza's FAIL for #422 v2 landed here." She
   bounced before checking — `c2c send <stanza> "FAIL landed in my
   inbox, not my slice"` is a 30-second reaction. Galaxy's archive
   shows the FAIL was delivered correctly the whole time. The
   subsequent finding propagated stanza's good-faith
   acknowledgement of cedar's report into a "broker routing
   artifact" framing. **No broker bug.**

2. **Far less likely — a transient inbox cross-write that was later
   tidied.** Would require an inbox file to be written to the wrong
   path then "cleaned up" before archive. There is no codepath that
   writes to one inbox and then deletes the row — `save_inbox`
   atomic-renames the full list. Drains append to archive, so any
   delivery would persist there.

3. **Effectively zero — alias collision / #379 regression /
   registration drift.** Distinct session_ids, plain-alias send
   never enters the `alias@host` codepath, no rename event in the
   relevant window, case-insensitive resolve isn't hit because
   both aliases are already lowercase. Each of these would also
   have produced an archive row in cedar's `archive/cedar-coder.jsonl`
   — there is none.

### Recommendation

Close as **non-bug, false alarm**. The original finding rests on
cedar's self-report of receiving a DM that the broker's own archive
shows she did not receive. No code changes warranted. Worth a
swarm-lounge note that "I think I got X" without inbox-checking can
manufacture phantom routing reports — cheap dogfooding lesson.

If we want defense-in-depth, two small ideas surface incidentally:

- Add `from_alias`/`to_alias` to the `tool":"send"` broker.log
  diagnostic line (#327 already added it for send_memory_handoff;
  generalising to plain `send` would let future investigations skip
  the archive grep).
- File `c2c doctor delivery-actuals` (counterpart to #307a delivery-mode
  histogram, but counting ARCHIVED inbound by recipient) — would have
  closed this finding in one command.

