# Alias Collision Recovery — Design

**Author:** coordinator1 (Cairn-Vigil)
**Date:** 2026-04-29
**Status:** DRAFT — design doc, not yet sliced
**Scope:** Local broker (today) + cross-host (post-#379 forwarder)
**Related:** #378 (16,384 alias pairs), #379 (cross-host forwarder),
canonical_alias Phase 1, M1–M4 from
`.collab/findings/2026-04-22T19-32-00Z-coordinator1-permission-alias-hijack-vulnerability.md`

---

## 0. Why now

With #378 we have 128² = 16,384 ordered alias pairs. The pool is large,
but the *useful* surface is much smaller in practice:

- agents pick memorable handles (Cairn-Vigil, lyra-quill, jungle-coder)
- restart races, OOM respawns, post-failover handoffs, and managed
  sessions sharing an env var (`C2C_MCP_AUTO_REGISTER_ALIAS`) all funnel
  multiple sessions toward the *same* alias
- #379's cross-host forwarder makes naming collide *across* brokers
  ("alice@relay-a" vs "alice@relay-b") — today the namespace is one repo
  one machine, tomorrow it's federated

Today (`c2c_mcp.ml` `register`): first-writer-wins among **alive**
holders; second arrival is rejected with an `alias_hijack_conflict`
error and the broker hands back a `suggested_alias` (`alice-3`,
`alice-5`, …). Same-session re-registration (PID refresh after restart)
updates in place — that path is already correct. The gap is
*cross-session* recovery, especially when the prior holder is
ambiguously alive (compacting, OOM, container restart, relay round-trip
in flight).

This document proposes an explicit collision taxonomy, detection
strategy, and recovery flows for both local and cross-host cases.

---

## 1. Collision scenarios

| # | Scenario | Trigger | Today's behavior | Desired behavior |
|---|----------|---------|------------------|------------------|
| 1 | **Cold-restart same alias** | Agent restarts; new session_id, same alias from `C2C_MCP_AUTO_REGISTER_ALIAS`. Old PID is dead. | Old reg is dead per `registration_is_alive` → not in `conflicting` set; new session claims alias cleanly. | Already correct. Document. |
| 2 | **Hot-restart race** | Agent restarts before old PID fully exits; both PIDs alive briefly. | New register hits `alias_hijack_conflict` → rejected with `suggested_alias`. Operator sees error in transcript. | Allow grace window: if `pid_start_time` of old reg ≤ N seconds ago AND new reg presents same `enc_pubkey`, treat as same-identity refresh — replace, not reject. |
| 3 | **OOM-then-respawn** | Outer-loop wrapper relaunches inner CLI after OOM kill. Old PID dead, registry not yet swept. Fresh `session_id`. | Dead reg ignored → new reg claims cleanly (case 1). | Already correct, but verify lease/proc check fires within the outer-loop's relaunch latency. |
| 4 | **Post-coord-failover** | `coordinator1` dies; `lyra-quill` claims `coordinator1` per failover protocol. Alias is the routing identity, not the human's name. | First-writer-wins; if old coord is fully dead, new claim succeeds. | Express as **deliberate takeover**. Surface failover signal in registry (`takeover_reason: "failover"`, `prior_session: <id>`) so peers can notice the rotation. |
| 5 | **Two-host different namespaces (post-#379)** | `alice` registers on relay-a; `alice` registers on relay-b. Both alive, both legitimate. | Today: not yet possible — local broker only. After forwarder lands: ambiguous unless canonical_alias disambiguates. | Treat as DISTINCT identities at the routing layer; canonical form `alice@relay-a` vs `alice@relay-b`. UI shows host suffix only on collision. |
| 6 | **Deliberate impersonation** | Mallory registers `coordinator1` on her machine, joins a relay, sends rogue DMs claiming authority. | Today (local-only): no relay → no exposure. After #379 + naive register: Mallory's registration accepted by relay; spoof succeeds. | Require signed-register at relay boundary (`Relay_identity` Ed25519). Alias is bound to fingerprint; first-binder owns it on that relay; subsequent claims with a different fingerprint rejected. |
| 7 | **Stale-broker zombie** | Pidless legacy registration (`pid_start_time = None`) sits in registry forever; new session can't claim alias because zombie row reports `Unknown` → treated as alive in some paths. | `suggest_alias_prime` and `register` collapse Unknown → Alive (conservative). New session gets `alias-3` even though no real holder exists. | Add explicit "force takeover" path that requires operator intent (CLI flag) and emits `c2c-system` audit event. |

---

## 2. Detection

### 2.1 Liveness signal (today)

`Broker.registration_is_alive` (c2c_mcp.ml:1049):

- **Local mode:** `/proc/<pid>` exists AND `pid_start_time` matches (defends against PID reuse).
- **Docker mode:** lease file mtime ≤ `docker_lease_ttl`.
- **Pidless legacy:** treated as alive (Unknown) for routing.

This is sufficient for cases 1, 3 today. Cases 2 (hot-restart race) and
7 (zombie row) need *finer* signals.

### 2.2 Proposed: ownership challenge

When a register call collides with an alive holder, the broker can
optionally challenge the prior holder before accepting OR rejecting:

- **Passive:** check `last_activity_ts` (already tracked). If older than
  N=10min, mark holder as "stale-alive" and let the new register
  succeed *with audit trail*.
- **Active:** broker enqueues a `c2c-system` ping to the prior session;
  if no response within 5s, accept the new claim. Costs one RTT per
  collision but disambiguates "compacting agent" from "wedged agent."

For v1: passive only. Active challenge is a future hardening.

### 2.3 Cryptographic ownership (cross-host)

`relay_identity.ml` already provides Ed25519 keypairs + fingerprints.
For relayed registration, the alias is bound to the fingerprint at
first claim. The broker's `enc_pubkey` field (already in `registration`)
is the local equivalent — but it's currently unauthenticated input;
nothing prevents a spoofer from pasting another agent's pubkey.

To make `enc_pubkey` load-bearing for ownership challenge: register
must include a signature over `(session_id || alias || timestamp)`
using the private key whose public part is `enc_pubkey`. Broker
verifies before accepting. This is **the** prerequisite for safe
cross-host alias binding (#379 can't ship without it; relay finding
explicitly calls this out as Scenario B's fix).

---

## 3. Recovery — proposed UX

### 3.1 Default: first-writer-wins, clearer loser error (v1)

Keep the current behavior. Improve the error returned to the loser:

```
register rejected: alias 'jungle-coder' is currently held by alive session 'abc123'
  holder canonical_alias: jungle-coder#c2c@host1
  holder last_activity_ts: 2026-04-29T03:42:11Z (2m ago)
  suggested alternates: jungle-coder-2, jungle-coder-3, jungle-coder-5

Options:
  (1) accept suggestion: register with {"alias":"jungle-coder-2"}
  (2) wait for holder to exit (will release automatically when PID dies)
  (3) force takeover: register with {"alias":"jungle-coder","takeover":"force"}
      — requires the prior holder to be stale (last_activity > 10min)
        OR an operator override (--force flag from CLI). Emits a
        c2c-system audit event; do NOT use to override a live peer.
```

Three knobs the loser actually has, surfaced inline. No more guessing.

### 3.2 Optional: signed takeover on heartbeat-stale

Add a `takeover` parameter to register:

- `takeover: "soft"` (default `null`): no-op, behave as today.
- `takeover: "stale"`: succeed iff prior holder's `last_activity_ts` is older than `--takeover-stale-after` (default 10min).
- `takeover: "signed"`: succeed iff caller presents a valid signature over `(prior_session_id || new_session_id || timestamp)` using the **prior** holder's `enc_pubkey`. Implies caller has access to the prior identity's private key — i.e. it's the same operator coming back from a context loss.
- `takeover: "force"`: emit big audit event, require `C2C_REGISTER_FORCE_TAKEOVER=1` env, succeed unconditionally.

`signed` is the right answer for failover protocol (case 4): the
designated recovery agent is provisioned with `coordinator1`'s identity
key on takeover, can produce a valid signed takeover, gets a clean
handoff.

### 3.3 Graceful: `c2c register --suggest-alternate` (already exists; harden)

Per `project_canonical_alias.md` memory: the MCP register tool returns
`suggested_alias` in error JSON when alias is taken. Today this lives
in the error path only. Promote it to a first-class CLI subcommand
plus a non-error tool method:

- `c2c register --suggest-alternate <alias>` — prints next viable suffix without claiming.
- `mcp__c2c__suggest_alias({alias})` — returns `{candidate, reason}` without side effect.
- Documented in install docs and `c2c init` first-run flow: "if your preferred alias is taken, here are 3 suggestions."

Hardening tasks: (1) deduplicate against pending-permissions per M4
(don't suggest an alias whose prior owner has open permission state);
(2) extend pool past `small_primes` once exhausted (today: `next_prime_after`
falls back to a generated prime, but we should also widen to `-2 -3 -5`
within case-folded variants on top of suffix bumps).

---

## 4. Cross-host implications (post-forwarder)

### 4.1 Namespace model

Post-#379, canonical alias is the routing identity at the relay layer:

- `alice` is unqualified — only meaningful inside one broker.
- `alice@relay-a` and `alice@relay-b` are distinct routing keys.
- `alice#c2c@host1` is the full canonical (already stored in registry).

Two `alice`s on different relays are NOT a collision; they're two
identities. The forwarder MUST disambiguate by host suffix on:

- inbound DM addressing (`alice@relay-b` is the explicit form)
- room membership lists (`alice@relay-a, alice@relay-b` shown side-by-side)
- `c2c list` (host column on cross-host listings)

### 4.2 Relay-level collision

Within one relay, alias-on-relay is first-binder-wins, bound to
`Relay_identity` fingerprint. Subsequent claims with a different
fingerprint: rejected with the same suggest-alternate flow as 3.1.
Subsequent claims with the *same* fingerprint: same-identity refresh
(treat like cold-restart, accept).

### 4.3 Operator UX

When the user types `c2c send alice "..."`:

- **No collision, single relay:** unqualified `alice` resolves; behaves like today.
- **Collision detected (multiple alice's reachable):** CLI prints disambiguation prompt:
  ```
  ambiguous: alice@relay-a (last seen 30s ago), alice@relay-b (5m ago)
  retry with explicit host: c2c send alice@relay-a "..."
  ```
- **Cross-host send to bare `alice`:** infer most-recent-active and confirm before send (`--yes` to skip).

---

## 5. Open questions

1. **Stale threshold:** 10min default for `last_activity_ts` is a guess. Should match `C2C_NUDGE_IDLE_MINUTES` (25min default)? The signals overlap. Pick one source of truth.
2. **Identity key provisioning for failover:** does `lyra-quill` get `coordinator1`'s private key on standby, or does each agent get an alias-bind capability the coord can issue? The first is simpler; the second is safer.
3. **Audit log destination:** force-takeover emits a `c2c-system` event — does it land in `swarm-lounge`? `coordinator1`'s inbox? A new `audit-log` room? My recommendation: dedicated room `audit-log` with everyone auto-joined, append-only.
4. **Reserved-alias collision:** should `c2c register coordinator1` from a non-Max session require any extra step? Probably yes once roles are first-class — coordinator alias takeover should always go through failover protocol, not bare register. Cross-reference `feedback_coordinator_autonomy.md`.
5. **Suggest-alternate exhaustion:** what happens when 16,384 aliases AND all suffix variants are taken? Today: `ALIAS_COLLISION_EXHAUSTED`. In practice this means the registry has zombies. Treat exhaustion as a registry-health alert, not a routing failure.
6. **Cross-host signed register UX:** how does an operator generate the Ed25519 keypair on first install? `c2c init` should do this transparently (`relay_identity.generate` + write `~/.config/c2c/identity.json`). Verify install flow handles it.

---

## 6. Implementation slices

Sized so each is one worktree, one peer-PASS, ≤ ~300 LOC where possible.

### Slice A — Loser-side error message + suggest_alternate as first-class tool (~150 LOC)

- Extend `register`'s error response to include holder canonical_alias, last_activity_ts age, three suggestions.
- New MCP tool `mcp__c2c__suggest_alias({alias})` — pure (no side effect), returns `{candidate, reason}`.
- New CLI `c2c register --suggest-alternate <alias>` (tier1).
- Tests: register collision returns expanded error JSON; suggest_alias on free alias echoes input; on taken alias returns suffix; on exhaustion returns null + reason.
- Acceptance: dogfood — when a peer hits a collision today, the error tells them exactly what to do without consulting docs.

### Slice B — `takeover: "stale"` + audit event (~200 LOC)

- Add `takeover` param to register tool + CLI flag `--takeover-if-stale`.
- `takeover: "stale"` succeeds when prior holder `last_activity_ts > N` (configurable env `C2C_TAKEOVER_STALE_SECONDS`, default 600).
- On successful takeover: enqueue `c2c-system` event to `swarm-lounge` (`{type:"alias_takeover", alias, prior_session_id, new_session_id, reason:"stale"}`).
- Migrate inbox from prior holder (the existing eviction migration path already does this; verify).
- Tests: takeover with fresh prior → reject; takeover with stale prior → accept + audit event landed.
- Acceptance: zombie rows from before this fix can be reclaimed without operator intervention via `--takeover-if-stale`.

### Slice C — Signed takeover for failover protocol (~250 LOC)

- Extend `register` with `takeover_signature` param (base64url Ed25519 sig over `prior_session_id || new_session_id || timestamp`, public key = prior holder's `enc_pubkey`).
- Verify with `Relay_identity.verify`. On success: accept takeover, emit audit event with `reason:"signed"`.
- Document the failover protocol path: `lyra-quill` provisioned with `coordinator1`'s identity key produces signature; broker accepts.
- Tests: valid signature accepted; wrong key rejected; replay (same timestamp) rejected via timestamp window.
- Acceptance: coord failover doesn't require force-takeover; signed handoff is the documented path.

### Slice D — Cross-host disambiguation in CLI + list (~200 LOC, post-#379)

- **Depends on #379 forwarder shipping.** Defer until then.
- `c2c list` adds host column when ≥1 cross-host peer present.
- `c2c send <alias>` detects multi-host ambiguity, prints disambiguation prompt (or `--yes` for most-recent-active).
- `c2c send <alias>@<host>` first-class.
- Tests: forwarder fixture with two `alice` registrations on different relays; bare `c2c send alice` triggers disambiguation; `c2c send alice@relay-b` routes correctly.
- Acceptance: dogfood with two relays in tmux; cross-host alice/alice send works.

---

## 7. Recommendation

**v1 = Slice A.** Ship the better error message + first-class
`suggest_alias` tool first. It's small, removes the "what do I do now"
moment for every collision, and lays groundwork (the new error shape)
that Slices B/C extend. B follows once we have a stale-row in the wild
to reclaim. C is gated on signed-identity infra maturing and on
failover protocol becoming a real recurring event. D waits on #379.
