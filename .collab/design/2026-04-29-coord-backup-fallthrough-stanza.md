# Coordinator-backup fallthrough for permission-DM auto-reject path

**Author**: stanza-coder (slice author) — feeding back to Cairn-Vigil (coordinator1) for review
**Date**: 2026-04-29
**Slice**: `slice/coord-backup-fallthrough`
**Worktree**: `.worktrees/coord-backup-fallthrough/`
**Issue**: TBD (file when Cairn opens one in the tracker)
**Status**: design + skeleton — full broker-driven DM forwarding deferred to follow-up

---

## 1. Problem statement

Today (2026-04-29), galaxy-coder issued a permission request via
`mcp__c2c__open_pending_reply` and DM'd coordinator1 (Cairn-Vigil)
the `perm_id`. Cairn was mid-cherry-pick batch and didn't surface
the inbound DM within the 600s default TTL, so the request
auto-rejected. Galaxy unblocked manually after surfacing the issue
in `swarm-lounge`.

Max's preference (per Cairn's brief 2026-04-29 ~15:11 UTC):
**redundancy over timeout-bumping.** The fix is not "give Cairn
more time" — it's "if the primary doesn't reply quickly, fan out
to a backup chain so SOMEONE answers."

**Designated backup chain** (per Cairn's brief): primary →
`stanza-coder` → `jungle-coder` → ad-hoc swarm-lounge broadcast.

## 2. Receipt: galaxy 600s incident (2026-04-29)

- Galaxy opened a permission via `open_pending_reply` (perm_id stored in
  `<broker_root>/pending_permissions.json`, supervisors=[`coordinator1`],
  TTL=600s default per `default_permission_ttl_s`).
- Galaxy's send-DM mechanism: standard `mcp__c2c__send` to `coordinator1`
  with the perm_id in the body.
- Cairn's session was busy (cherry-pick batch); no `poll_inbox`/handler
  surfaced the DM; no `check_pending_reply` happened from Cairn's
  alias before TTL.
- At 600s the entry expired. Galaxy's downstream code observed
  the expiry and treated it as auto-reject.
- No fail-soft: there was no second supervisor, no broadcast.

The pending entry already supports `supervisors : string list`
(multi-supervisor listing exists for Codex/Claude permission
parity), but in practice galaxy only listed `coordinator1`. The
swarm has no convention or broker-side default that adds backups
to the list.

## 3. Goals

1. **A primary-coord miss should not auto-reject.** When the primary
   hasn't responded in N seconds, the broker forwards the DM to
   `backup1`, then `backup2`, then ultimately broadcasts to
   `swarm-lounge`.
2. **Fix at the broker level**, not inside each requesting agent.
   Galaxy didn't add a backup chain; the broker should.
3. **Audit every fallthrough fire** so we can measure how often the
   primary is missing.
4. **Idempotent under late primary reply.** Cairn replying at t=180s
   (after backup was DM'd at t=120s) is fine: first valid reply wins.
5. **No new agent obligations.** Senders (galaxy, anyone using
   `open_pending_reply`) keep their existing call shape;
   supervisors (Cairn, stanza, jungle) keep their existing
   `check_pending_reply` flow. The fallthrough is purely additive
   broker behavior driven by config.

## 4. Configuration shape

`.c2c/config.toml` (per-repo, alongside existing `[swarm]`
`restart_intro` from #341):

```toml
[swarm]
# Default supervisor chain for pending-permission DMs. When a
# requester calls open_pending_reply with no supervisors (or with
# only the primary), the broker treats this list as the implicit
# fallthrough chain. Index 0 is primary; later entries are tried
# in order if the primary doesn't ack within
# coord_fallthrough_idle_seconds.
coord_chain = ["coordinator1", "stanza-coder", "jungle-coder"]

# Seconds the primary has to ack before forwarding to backup1.
# Each successive backup gets the same window. After the chain is
# exhausted, the broker broadcasts to swarm-lounge.
coord_fallthrough_idle_seconds = 120

# Room used for the final "all coords missing" broadcast. Defaults
# to swarm-lounge. Set to "" to disable the broadcast tier (the
# request will simply expire at TTL with no fallthrough action).
coord_fallthrough_broadcast_room = "swarm-lounge"
```

Read via three new thunks in `c2c_start.ml` mirroring the
`swarm_config_restart_intro` pattern (#341):

- `swarm_config_coord_chain : unit -> string list`
- `swarm_config_coord_fallthrough_idle_seconds : unit -> float`
- `swarm_config_coord_fallthrough_broadcast_room : unit -> string`

These are advisory: the fallthrough mechanism is also gated by an
env-var off-switch `C2C_COORD_FALLTHROUGH_DISABLED=1` so operators
can shut the feature off at the broker without editing TOML.

## 5. Backup chain semantics (timing)

The fallthrough timeline is **per pending-permission entry**, keyed
on the perm_id. At `open_pending_reply` time the broker stores the
chain (effective_supervisors = config chain ∪ caller-provided
supervisors, deduped, primary first).

```
t = 0s            primary DM sent (by requester, as today)
                  pending entry created with effective_supervisors

t = 0..120s       primary window
                  if any supervisor's session calls
                  check_pending_reply with valid=true → entry
                  resolved, no fallthrough fires

t = 120s          fallthrough scheduler tick observes:
                    - entry still active (not resolved/expired)
                    - fallthrough_fired_at[0] is None
                  ACTION: enqueue DM to backup1 with same perm_id
                          + a "(fallthrough from primary)" prefix
                          set fallthrough_fired_at[0] = now
                          emit coord_fallthrough_fired audit line

t = 240s          if still unresolved and fallthrough_fired_at[1]
                  is None: same action for backup2

t = 360s          backup3 (if any)

t = N*idle        when all backups exhausted, broadcast to
                  swarm-lounge with @coordinator-backup tag
                  set broadcast_fired_at = now (one-shot)

t = TTL (600s)    existing auto-reject path; unchanged
```

`fallthrough_fired_at` is added to the `pending_permission` record
as `float option list` of length `len(effective_supervisors)`,
indexed parallel to the supervisors list. Same atomic-write
discipline as the rest of `pending_permissions.json`.

### 5.1 Why the broker, not each requester

The brief is clear: **"layer at the broker scheduler level, not
inside the requesting agent."** Reasons:

1. **Single source of truth.** If every requester implements its
   own fallthrough, behavior diverges per client (galaxy = python
   wrapper, Cairn = Claude Code, stanza = Claude Code, jungle =
   Codex). A broker-side scheduler is uniform.
2. **Galaxy didn't have backups in its list.** A requester-side
   approach requires every requester to do the right thing; a
   broker-side approach can default the chain from config.
3. **Cross-process safety.** Multiple MCP servers (one per managed
   session) all observe the same `pending_permissions.json`.
   Exactly-once forwarding requires a lock — already implemented
   via `with_pending_lock` in `Broker`. Per-requester schedulers
   would need their own coordination.

### 5.2 Why not just bump TTL to 30 minutes?

Per Max: redundancy > waiting longer. A 30-minute TTL means a
busy primary blocks the requester for 30 minutes; a 2-minute
fallthrough means the requester gets answered in ≤2 minutes by
*someone* even if the primary is unavailable.

## 6. Idempotency under late primary reply

Scenario: backup1 was DM'd at t=120s. Cairn finally polls at
t=180s and replies via `check_pending_reply` (or via a follow-up
DM that triggers her own `check_pending_reply`).

Resolution rule: **first valid reply wins.** `check_pending_reply`
already returns `valid=true` based on supervisor membership; the
broker doesn't currently implement a "reply" verb that mutates
state, but for fallthrough we add a notion of "resolution."

Two sub-options:

### Option A (preferred): no broker-side mutation, just stop firing fallthrough

`check_pending_reply` with `valid=true` from any supervisor sets
`resolved_at` on the pending entry. The fallthrough scheduler
checks `resolved_at` before firing each tier. Late primary reply
sets `resolved_at`, but if backup1 already saw the DM and is
about to reply, that's also fine — the requester gets two
acks, picks the first.

**Pro**: minimal new state; no extra RPC.
**Con**: requester needs to handle two replies (today they only
expect one). Both replies are valid acks, so semantically this is
fine — but worth flagging.

### Option B: explicit "resolve" RPC

Add `mcp__c2c__resolve_pending` that the supervisor calls when
they reply. The broker marks the entry resolved and dead-ends
later fallthrough.

**Pro**: clean lifecycle; fewer concurrent replies.
**Con**: new tool; supervisors have to remember to call it; old
clients don't know about it.

**Decision**: Option A for v1. Option B can layer on later if we
observe duplicate-reply confusion in dogfooding.

## 7. Permission-DM specifics

The pending-permissions surface is `mcp__c2c__open_pending_reply`
+ `mcp__c2c__check_pending_reply`. The DM itself is a normal
`mcp__c2c__send` from the requester to the supervisor with the
perm_id in the body — the broker has no notion of "this DM is
the permission DM."

For fallthrough we have to **synthesize** the forwarded DM. The
broker has the perm_id, the requester_alias, and the supervisor
list — but not the original DM body. Two choices:

### 7.1 Synthesized DM body (recommended)

The broker constructs a forwarded DM body from the pending entry:

```
[coord-fallthrough] Permission request perm_id=<id>
from <requester_alias>. Primary <primary> didn't ack within
<idle>s — escalating to you.
Reply via mcp__c2c__check_pending_reply.
```

This is enough for the backup to act: they call
`check_pending_reply` with the perm_id; if they want to know the
*content* of what they're approving, that's a separate
DM-the-requester step. (Most permission requests in dogfood traffic
don't carry rich content beyond "approve this batch" — the perm_id
is the load-bearing piece.)

### 7.2 Store original DM body on the pending entry

Add `original_request_body : string option` to the pending
permission. Requires `open_pending_reply` to take an optional
`request_body` arg, plus the requester to remember to populate it.
Today's senders don't, so legacy entries would have None and we'd
fall back to 7.1 anyway.

**Decision**: 7.1 for v1; revisit 7.2 if backups complain about
information loss.

## 8. Audit log

Every fallthrough fire emits one line in `<broker_root>/broker.log`:

```json
{"ts": 1714389600.0,
 "event": "coord_fallthrough_fired",
 "perm_id_hash": "abc123...",
 "tier": 1,
 "primary_alias": "coordinator1",
 "backup_alias": "stanza-coder",
 "requester_alias": "galaxy-coder",
 "elapsed_s": 120.5}
```

Tier conventions: 1 = first backup DM'd, 2 = second backup DM'd,
N+1 = swarm-lounge broadcast (with `backup_alias = "<broadcast>"`).

`perm_id_hash` follows the existing `short_hash` discipline from
the #432 Slice D pending-perm audit log.

Helper lives in `c2c_mcp.ml`: `log_coord_fallthrough_fired
~broker_root ~perm_id ~tier ~primary_alias ~backup_alias
~requester_alias ~elapsed_s ~ts`.

## 9. Test plan

All in `ocaml/test/test_coord_backup_fallthrough.ml` (new file).

- **T1**: `swarm_config_coord_chain` reads list from TOML. Default
  is `[]` when key absent; non-empty list returned with order
  preserved when present.
- **T2**: `swarm_config_coord_fallthrough_idle_seconds` reads
  float; default 120.0 when key absent.
- **T3**: open a pending permission with primary=`coord1`, chain
  config `[coord1, stanza, jungle]`. Advance fake clock by 60s.
  Run scheduler tick. Assert: no fallthrough fire (under idle).
- **T4**: same setup, advance clock by 130s. Run tick. Assert:
  one DM enqueued to `stanza`, audit line emitted with tier=1,
  `fallthrough_fired_at[1]` set.
- **T5**: setup as T4; advance to 130s, tick, then
  `check_pending_reply` from `coord1` (late primary) with
  valid=true. Assert: backup2 (jungle) does NOT get DM'd at
  t=250s.
- **T6**: chain exhausted: advance through 130s, 250s, 370s,
  finally 490s. Assert: at the broadcast-tier tick, one
  `send_room` to `swarm-lounge` with `@coord-backup` body
  prefix; audit line tier=N+1.
- **T7**: env `C2C_COORD_FALLTHROUGH_DISABLED=1` short-circuits
  every tick — no fires regardless of elapsed time.
- **T8**: idempotency under double-tick — call the scheduler
  tick twice in a row at t=130s. Assert: only ONE DM enqueued
  to backup1 (the second tick observes
  `fallthrough_fired_at[1] = Some _` and skips).
- **T9**: primary reply BEFORE idle → backup never DM'd
  (covered by check at t<idle, then `check_pending_reply`
  valid=true, then advance past idle, tick → no fire).

## 10. Open questions for Cairn

1. **Chain ownership**: should the chain in `[swarm]
   coord_chain` literally be `[coordinator1, stanza-coder,
   jungle-coder]` (verbatim aliases as Cairn briefed) or should
   we use *roles* (`coordinator`, `coder`, `coder`) and resolve
   via the live registry at fire time? Verbatim aliases is
   simpler and matches Cairn's brief; role-based would survive
   re-aliasing but adds a registry lookup per tick. **Recommendation**:
   verbatim aliases for v1; revisit if alias churn shows up.

2. **What happens if a backup is offline (no live registration)?**
   Today's behavior would be: DM still goes to the inbox and waits.
   Should the fallthrough scheduler skip-and-advance to the next
   backup if the current one has no live session, or should it
   queue and wait? **Recommendation**: skip-and-advance — the
   whole point is "someone alive answers." Use
   `Broker.registration_liveness_state` (same predicate
   `relay_nudge` uses).

3. **Does the broadcast tier replace or augment the
   final-backup tier?** I.e. if the chain is `[a, b, c]`, do we
   tick at t=120s (b), t=240s (c), t=360s (broadcast)? Or
   t=120s (b), t=240s (c), t=360s (still no broadcast — TTL
   handles it)? **Recommendation**: emit the broadcast at
   `(len chain) * idle` to give EVERYONE in the lounge a
   chance, then let TTL auto-reject if even broadcast yields
   no taker.

4. **Should the requester be notified that fallthrough fired?**
   E.g. galaxy gets a DM saying "your perm_id=X was forwarded to
   stanza because coord1 didn't ack." Useful for debugging stale
   primaries; noisy in steady-state. **Recommendation**: log only
   (audit line), no DM-the-requester. Requester sees the eventual
   ack from whoever answers.

5. **Does the existing `check_pending_reply` need a `mark_resolved`
   bool to make Option A explicit?** Today it just *reads* — if
   we want fallthrough to dead-end on first valid check, we need
   a side-effect. **Recommendation**: yes — when
   `check_pending_reply` returns `valid=true`, side-effect the
   pending entry to set `resolved_at = now`. Backwards-compat: old
   clients still work; new behavior is purely a server-side write.

6. **Can the scheduler reuse `relay_nudge`'s `start_*_scheduler`
   pattern, or do we want a dedicated thread?** They have very
   different cadences (nudge: 30min; fallthrough: 60s tick to
   catch the 120s threshold). **Recommendation**: dedicated thread,
   short tick (60s), same Lwt.async dispatch pattern.

## 11. Implementation scope

Per the slice constraint ("if impl > ~200 LoC, STOP after design +
skeleton"), this slice ships:

**LANDED in this slice**:
- This design doc.
- Three TOML thunks in `c2c_start.ml` (~40 LoC + tests).
- Audit-log helper `log_coord_fallthrough_fired` in `c2c_mcp.ml`
  (~25 LoC + tests).
- Skeleton functions (signatures, no bodies) for the scheduler
  hooks: `Broker.fallthrough_tick`,
  `Broker.mark_pending_resolved`. These compile-and-fail-fast so
  the next implementer has a clear surface.

**DEFERRED to a follow-up slice**:
- The actual `Broker.fallthrough_tick` body (DM enqueue per tier,
  fired_at tracking, swarm-lounge broadcast).
- `pending_permission` record gains `fallthrough_fired_at` and
  `resolved_at` fields (touches schema; needs migration thinking).
- `check_pending_reply` side-effects `resolved_at`.
- `start_fallthrough_scheduler` background loop in `relay_nudge`-
  shaped helper.
- The full T1-T9 test matrix (T1-T2 land in this slice; T3-T9 are
  the follow-up's TDD harness).

The follow-up slice is sized at ~200-300 LoC. Keeping it
separate means this slice can land for design review without
blocking on Cairn's answers to §10's open questions.
