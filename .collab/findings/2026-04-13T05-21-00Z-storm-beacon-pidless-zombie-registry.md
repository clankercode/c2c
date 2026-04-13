# Pidless zombie registry entries never get swept

- **Discovered:** 2026-04-13 ~15:20Z by storm-beacon while auditing
  registry liveness after sending a cross-client ping that
  opencode-local never drained.
- **Severity:** medium (silent send_all amplification, accumulating
  dead-letter pressure once sweep does start running, and a real
  blocker to using send_all as a presence beacon).

## Symptom

`registry.json` on this working repo currently holds 11 entries:

```
opencode-local     pid=1688797   DEAD
storm-storm        pid=None      treated-as-alive (legacy)
storm-herald       pid=None      treated-as-alive (legacy)
storm-ember        pid=None      treated-as-alive (legacy)
storm-beacon       pid=None      treated-as-alive (legacy)   ← me
storm-silver       pid=None      treated-as-alive (legacy)
storm-banner       pid=None      treated-as-alive (legacy)
storm-lantern      pid=None      treated-as-alive (legacy)
storm-signal       pid=None      treated-as-alive (legacy)
storm-harbor       pid=None      treated-as-alive (legacy)
storm-aurora       pid=None      treated-as-alive (legacy)
```

10 of 11 entries have no pid field. The eleventh has a pid
(1688797) but `kill -0 1688797` reports ESRCH — the process has
exited. Yet the entry survives in the registry.

The actual count of *live* claude/codex/opencode sessions on this
host that could be answering c2c messages right now is at most 2
(storm-ember and storm-beacon = me). The other 9 are zombies.

## Root cause

Two distinct mechanisms compound:

1. **`registration_is_alive` treats `pid=None` as alive.** This is
   a deliberate legacy-compat fallback in `c2c_mcp.ml` —
   `registrations_without_pid_loaded_as_alive` is even one of the
   ocaml broker tests. The intent was to support old YAML registry
   rows that pre-date the JSON broker / pid-passing code path. But
   the consequence is that any legacy-shape registration row is now
   **immortal**: sweep cannot tell it from a live one, and only an
   explicit `register` of the same alias under a new session_id
   (slice-3 alias eviction) can dislodge it.

2. **opencode-local is registered with a real pid that died.** The
   slice-3 alias-dedupe + slice-4 registry-locked enqueue paths
   correctly persist the pid, and `registration_is_alive` correctly
   identifies the pid as dead via `/proc/<pid>` check + (when
   present) pid_start_time match. But sweep only runs on demand —
   it isn't tied to any periodic heartbeat. Until something calls
   `tools/call sweep`, the dead-pid row sits in registry.json
   forever, send_all keeps writing to opencode-local.inbox.json,
   and broker hygiene quietly degrades.

## Why this matters now

The reach axis of the group goal ("Codex, Claude Code, and
OpenCode as first-class peers") just got its first real cross-
client send: storm-beacon → opencode-local. The send `queued`
successfully (slice-4 registry-locked enqueue did its job), but
opencode-local never drained the message because the registered
pid is dead. From the sender's perspective the request looked
identical to a successful delivery. **There is no signal in the
send response that distinguishes "queued for live recipient" from
"queued for dead recipient that will never read this".**

This silently breaks the presence-beacon use case from the goal
docs: an agent broadcasting `send_all` to "see who's home" cannot
tell who's home. Every dead-pidless entry plus the dead-pid-with-
real-pid entry shows up as a "delivery." The hygiene cost grows
linearly with how many agents have ever existed.

## Reproduction

```bash
cd /home/xertrov/src/c2c-msg
cat .git/c2c/mcp/registry.json | python3 -c "
import sys, json, os
for r in json.load(sys.stdin):
    p = r.get('pid')
    if not p:
        state = 'no-pid (immortal)'
    else:
        try: os.kill(p, 0); state = 'LIVE'
        except: state = f'DEAD (pid {p})'
    print(f'{r[\"alias\"]:18} {state}')
"
```

## Possible mitigations (none implemented; all need Max input)

All of these would need design review before landing — the
legacy-compat fallback in particular is deliberate.

1. **Make sweep run on a timer** (e.g. on every Nth tool call, or
   from an external `c2c sweep` cron). Removes the dead-pid case
   without touching the legacy code path. Smallest change. Already
   covered by existing sweep tests.

2. **Add a `force_sweep_pidless` flag to sweep** that lets an
   operator explicitly opt into removing pidless rows. Default-off
   so the legacy contract is unchanged; opt-in for clean broker
   state. Pairs naturally with a `c2c gc-registry` Python tool.

3. **Migrate legacy pidless registrations on first contact.** If a
   pidless `<alias>` row exists and the same agent re-registers
   under a different session_id with a real pid, the slice-3 alias
   eviction already handles this. So the live agents (storm-beacon,
   storm-ember) actually self-clean over restart cycles **once
   their next register call passes a pid**. Verify storm-beacon's
   own registration code path is using the pid-aware register —
   if not, that's a one-line fix in the c2c_register flow and the
   immortality property goes away naturally over time.

4. **Add a "drained_at" timestamp to the registry.** A registration
   that hasn't drained its inbox in N hours is presumed dead even
   without pid evidence. Bigger schema change, but removes the
   reliance on /proc and would also catch frozen sessions where
   the process is alive but the agent loop is hung.

## Recommendation

**Investigate option 3 first (zero-cost, fits the existing schema).**
Check whether the current `c2c_register.py` / `claude` registration
path passes `pid` through to `Broker.register`. If it does, the
legacy entries are a pure historical artifact that will age out as
agents restart. If it doesn't, that's the actual bug — and it's
plausibly the same root cause storm-ember just fixed on the read
path (the YAML-prune-on-read alias-churn), but on the write path.

**Then add option 1 (periodic sweep) as a separate, smaller
follow-up.** Doesn't solve the immortality problem on its own but
makes the dead-pid case (opencode-local) self-heal.

## Update — root cause located in Python registration path

Audited at 15:23Z. The bug is two-stage on the Python side; the
OCaml broker contract is fine.

1. **`c2c_registry.py:217-218`** —
   `build_registration_record(session_id, alias)` returns
   `{"session_id": ..., "alias": ...}` with NO pid field. The YAML
   registry row never captures pid in the first place.

2. **`c2c_mcp.py:96-102`** — `merge_broker_registration(existing,
   registration)` only carries `session_id` and `alias` from the
   source row when syncing the YAML registry into the broker JSON
   registry. Even if `build_registration_record` were patched to
   include pid, `sync_broker_registry` would still strip it on the
   way through.

   ```python
   def merge_broker_registration(
       existing: dict[str, object] | None, registration: dict
   ) -> dict:
       merged = dict(existing or {})
       merged["session_id"] = registration["session_id"]
       merged["alias"] = registration["alias"]
       return merged
   ```

So every Python-driven registration lands on the OCaml side as a
legacy pidless row → `registration_is_alive` returns true forever
→ sweep can't dislodge it → my registry has 10 immortal storm-*
entries because that's how many distinct session_ids have ever
called `c2c register` on this host.

## Concrete fix (Python-side, one PR)

Storm-ember is best positioned for this since they own the YAML
registry and just landed the read-path fix. Suggested shape:

1. **`c2c_registry.py`** —
   `build_registration_record(session_id, alias, *, pid=None,
   pid_start_time=None) -> dict` returning the four fields.
   Existing callers can pass nothing and get the current shape;
   `c2c_register.py` should pass `pid=os.getpid()` and read
   pid_start_time via the existing helper if present.

2. **`c2c_mcp.py:merge_broker_registration`** — carry `pid` and
   `pid_start_time` through if present:

   ```python
   for field in ("pid", "pid_start_time"):
       if field in registration:
           merged[field] = registration[field]
   ```

3. **One-shot migration** — for already-existing pidless rows in
   `registry.json`, no action needed: the next time each agent
   calls `register` (e.g. on restart-self), the slice-3 alias
   eviction will replace the pidless row with the new pid-aware
   one. Existing zombies age out naturally.

This is purely Python-side. The OCaml broker tests
(`test_registration_persists_pid`, `test_registration_persists_pid_start_time`)
already prove the broker round-trips both fields — slice 4 even
forks 60 concurrent enqueues against a re-registering target with
explicit pids, so the broker-side contract is locked in.

## OCaml-side complement (optional, smaller)

Not strictly needed once the Python fix lands, but could be
useful for defense-in-depth and faster zombie detection:

- **Add a `force_sweep_pidless` flag to `tools/call sweep`** that
  removes legacy pidless rows. Default off. Pairs with a
  `c2c gc-registry` Python wrapper for operator use. Avoids
  changing the legacy-compat default. ~30 lines + 2 tests.

I'll hold off on this until storm-ember's Python fix is in flight,
to avoid landing two different "what counts as alive?" semantics
in the same week.

## Related

- Slice 3 finding: `2026-04-13T04-38-00Z-storm-beacon-register-inbox-migration.md` —
  alias-dedupe correctly evicts on re-register, which is the
  natural cleaner for legacy rows once register is pid-aware.
- Slice 8 finding (orphan inbox locks): same "state accumulates
  faster than cleanup reclaims it" pattern as this one, just for
  lockfiles instead of registrations. Fix the registration-side
  immortality first because it gates everything else.
- Storm-ember 05:40Z finding (alias-churn-on-restart):
  YAML-side analog. The Python read path was wiping registrations;
  this finding is about the JSON registry being unable to wipe
  them. Same theme of "registry consistency under restart cycles."
