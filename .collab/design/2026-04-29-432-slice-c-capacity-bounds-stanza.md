# #432 Slice C — Capacity Bounds for `pending_permissions.json`

**Author:** stanza-coder · **Date:** 2026-04-29 · **Status:** design / pending-review
**Audit ref:** `.collab/research/2026-04-29-stanza-coder-pending-permissions-audit.md` Finding 2 (MED).
**Code refs:** `ocaml/c2c_mcp.ml:711-790` (Broker pending API), `:5797-5840` (`open_pending_reply` MCP handler), `:4575` (M4 register-guard caller of `pending_permission_exists_for_alias`).

## Problem

`Broker.open_pending_permission` (line 759) prepends to the on-disk list with no cap. A malicious or buggy agent calling `mcp__c2c__open_pending_reply` in a loop grows the file unbounded. Side effects: (a) every public API on this store does an O(N) `List.filter`/`List.exists` (e.g. M4 register-guard at :4575), so an unbounded list also degrades the `Broker.register` hot path; (b) each call writes a JSON re-serialization under the cross-process lock from Slice A, so big lists stall every other pending-permission caller.

## 1. Cap shape — recommend BOTH per-alias and global

Two failure modes worth distinguishing:

- **One bad actor.** Single alias spamming `open_pending_reply`. A per-alias cap stops them without affecting peers.
- **Coordinated / cumulative drift.** N agents each within their per-alias cap, but the file is still huge. A global cap caps the worst case for the M4 scan.

**Recommended numbers:**

| Scope | Cap | Reasoning |
|---|---|---|
| Per-alias | **16** | Permissions are TTL-600s; a legitimate agent opens ~1-2 in flight at a time. 16 is ~10× normal in-flight, comfortable for hooks/multi-perm flows, well below abuse. |
| Global | **1024** | Current swarm peaks ~10-15 live agents. 1024 is 64× per-alias × ~16 agents — fits in memory trivially, M4 register-guard's `List.exists` over 1024 entries is sub-millisecond, but a single 1024-entry payload is small enough that a malicious append loop is bounded to ~kB-scale before rejection. |

Caps are constants in the broker module (not env-tunable in v1 — keep blast-radius small; can promote to env later if real workloads bump them).

## 2. Reject-on-cap behavior

- **Broker layer** (`open_pending_permission`): raise a typed exception, e.g. `exception Pending_capacity_exceeded of [`Per_alias of string | `Global]`.
- **MCP handler** (`open_pending_reply` at :5830): catch and return `tool_result ~is_error:true` with content `"open_pending_reply rejected: per-alias pending-permission cap (16) exceeded for alias '<x>'"` (or global variant). Mirrors the impersonation-rejection style used at :5777-5779.
- **Logging:** one line to `broker.log` per rejection, format
  `[pending-cap] reject open_pending_permission alias=<a> kind=<k> reason=<per_alias|global> active=<n> cap=<c>`. Same level as existing broker.log diagnostics; gives operators visibility into runaway agents without spamming on every call.

No silent drop. The calling agent sees `is_error: true` and an explanatory message in its tool response.

## 3. Implementation sketch

In `open_pending_permission` (line 759), after acquiring `with_pending_lock` and computing `entries = get_active_pending_permissions t` (which already filters expired):

```
let global_count = List.length entries in
if global_count >= global_cap then
  raise (Pending_capacity_exceeded `Global);
let alias_count =
  List.fold_left (fun n e ->
    if String.equal e.requester_alias p.requester_alias then n+1 else n
  ) 0 entries
in
if alias_count >= per_alias_cap then
  raise (Pending_capacity_exceeded (`Per_alias p.requester_alias));
save_pending_permissions t (p :: entries)
```

Cost is essentially free: we already walked `entries` once to filter expired, the count walks the same already-loaded list. No extra I/O. Caps live as named constants (`pending_per_alias_cap`, `pending_global_cap`) at module top.

Handler change at :5830: wrap the call in `try ... with Pending_capacity_exceeded variant -> tool_result ~is_error:true ...`.

## 4. Test approach

`tests/test_broker.ml` (or the existing pending-permission test file from Slice A):

1. **Per-alias cap.** Fresh broker, register alias `t`. Loop `i=1..16` calling `open_pending_permission` with distinct `perm_id`; assert each succeeds. 17th call: assert `Pending_capacity_exceeded (`Per_alias "t")` raised. Then `remove_pending_permission` one entry; 17th retry succeeds.
2. **Global cap.** Inject 64 distinct aliases × 16 perms each = 1024 entries. 1025th `open_pending_permission` (any alias) raises `Pending_capacity_exceeded `Global`.
3. **Expiry interaction.** Fill to per-alias cap with `expires_at = now - 1.0` (already expired). Next `open_pending_permission` for that alias **succeeds** because `get_active_pending_permissions` drops expired before counting. Pin via `Unix.gettimeofday` test fixture or by constructing entries directly.
4. **MCP handler surface.** Drive `open_pending_reply` 17× via the in-process MCP fixture for one alias; assert the 17th response has `is_error: true` and content matches the rejection string.
5. **broker.log line.** Tail broker.log after rejection; assert `[pending-cap] reject` line present with the right alias + reason.

## 5. Acceptance criteria

- AC1: `open_pending_permission` raises typed exception on per-alias overflow at exactly cap+1; passes (1).
- AC2: Same on global overflow at exactly 1025; passes (2).
- AC3: Expired entries do not count toward either cap; passes (3).
- AC4: MCP `open_pending_reply` returns `is_error: true` with informative content on cap; passes (4). No partial state — rejection must NOT mutate `pending_permissions.json`.
- AC5: One `[pending-cap] reject` log line per rejection in `broker.log`; passes (5).
- AC6: M4 register-guard scan (`pending_permission_exists_for_alias`, :783) remains O(N) over a list bounded by 1024 — measured `< 5ms` in a microbench at full saturation. (Validation: not a perf ask, just a sanity floor.)
- AC7: `dune build` and full `just test` pass; review-and-fix peer-PASS recorded.

## 6. Open design questions for Cairn / Max

- **Q1.** Should the per-alias cap be promoted to env (`C2C_PENDING_PER_ALIAS_CAP`) in v1, or constants-only? Recommendation: constants-only for #432; promote later if real flows bump 16.
- **Q2.** Should we also log per-rejection to a structured channel so doctor can surface "alias X is hitting the cap" as a swarm-health signal (akin to `c2c doctor delivery-mode`)? Out-of-scope for Slice C, but worth a follow-up issue.
- **Q3.** Reject vs LRU-evict on cap: I recommend **reject** because permissions are security-load-bearing (M4 alias-reuse guard) — silently evicting an old pending entry could open a hijack window. Confirm.
- **Q4.** Do we need a separate cap for `kind = something else` vs default? Current pending-permission kinds are uniform-cost; recommend single cap until kinds diverge.
