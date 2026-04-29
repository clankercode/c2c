# Pidless-zombie systemic audit — sweep + auto_register_startup

**Author:** stanza-coder
**Date:** 2026-04-28 14:25 AEST (UTC 04:25)
**Status:** v0 — first-pass audit findings, no fix yet
**Trigger:** While drafting #335 v2a, ran a parallel codebase audit
for analogous "absence-of-evidence-as-presence" patterns. Two
high/medium-severity siblings to the #335 nudge bug surfaced.

## Tl;dr

The `Broker.registration_is_alive reg = true` for `pid=None` bug
isn't only a nudge problem. The same predicate is consulted on:

- **`sweep` partition logic** (`c2c_mcp.ml:1875`) — pidless rows are
  structurally **un-reapable**. Three of the 13 zombies on this
  broker exist because sweep cannot fix what it considers alive.
- **`auto_register_startup` Guards 1, 2, 4** (`c2c_mcp.ml:3510, 3530, 3566`)
  — three of four startup guards still miss the `reg.pid <> None`
  filter that Guard 3 was specifically hardened with after a
  prior failure (see comment block at `:3540-3545`). A pidless
  zombie can spuriously block a legitimate post-OOM re-registration.

These are likely contributors to the "swarm dance after every OOM"
pattern Max has been working around.

## Finding 1 — sweep is structurally un-reapable for pidless rows

**File:** `ocaml/c2c_mcp.ml:1875` (`sweep` partition predicate)
**Severity:** HIGH (routing-impacting, in production)

```ocaml
(* sweep keeps registration if both conditions hold *)
fun reg ->
  Broker.registration_is_alive reg
  && not (is_provisional_expired reg)
```

For a pidless row (`reg.pid = None`):

1. `registration_is_alive reg` returns `true` (the canonical bug
   under #335 audit; `c2c_mcp.ml:917`).
2. `is_provisional_expired` returns `false` whenever **either**:
   - `reg.confirmed_at <> None` (`:1065`) — once a session has ever
     drained, it stops being provisional.
   - `reg.registered_at = None` (`:1086`) — pre-`registered_at`
     legacy rows have no anchor for expiry.

**Net effect:** any pidless row that has ever drained, or any
pre-`registered_at` legacy row, is kept by sweep forever. The 13
zombies on this broker (out of 20 registrations) demonstrate this
in production.

**Why it matters:** even after #335 v2a stops nudging zombies, the
zombies remain in the registry. They show up in `c2c list`, can
collide with new alias claims, and clutter the auto-register
guard checks in Finding 2.

**Suggested fix slice:** sweep should consult a stricter predicate
for the partition decision — something like:

```ocaml
let is_sweep_keepable reg =
  match reg.pid with
  | None ->
      (* Pidless row: only keep if recently registered_at AND has
         drained, otherwise it's a zombie from a long-dead session. *)
      let recent = match reg.registered_at with
        | None -> false  (* legacy row, no anchor — let it go *)
        | Some ts -> Unix.gettimeofday () -. ts < pidless_keep_window
      in
      recent && reg.confirmed_at <> None
  | Some _ ->
      (* PID-tracked row: existing alive + provisional logic. *)
      Broker.registration_is_alive reg && not (is_provisional_expired reg)
```

`pidless_keep_window` is a small TTL (e.g. 1 hour) — enough to
cover OpenCode-plugin-handoff transitions where a row may briefly
have `pid=None` mid-spawn, but not so long that 3-day-dead rows
linger.

**Complications:** Docker-mode (`c2c_mcp.ml:923`) deliberately
returns `pid=None → alive=true` because the lease file is the
liveness signal, not pid. The fix needs to preserve Docker
semantics — likely by routing through `registration_liveness_state`
(which already handles Docker mode correctly per the comment at
`:947-953`).

## Finding 2 — auto_register_startup Guards 1, 2, 4 inherit the bug

**File:** `ocaml/c2c_mcp.ml:3510, 3530, 3566`
**Severity:** MEDIUM (post-OOM resume reliability)

Guard 3 (`:3551`) was specifically hardened with `reg.pid <> None`
after a prior failure mode. The hardening comment at `:3540-3545`
explicitly explains why pidless rows must not block re-registration.

But Guards 1, 2, and 4 still call `Broker.registration_is_alive reg`
without the matching `reg.pid <> None` filter:

- **Guard 1** (`hijack_guard`, `:3510`) — checks for an alive
  registration with the same alias but a different `session_id`.
  If a zombie pidless row has the alias, hijack-guard fires and
  the legitimate restart is rejected as a hijack attempt.
- **Guard 2** (`alias_occupied_guard`, `:3530`) — same shape, same
  vulnerability.
- **Guard 4** (`same_pid_alive_different_session`, `:3566`) — same.

The `alias_hijack_conflict` site at `:3884` was hardened correctly
with `Option.is_some reg.pid`. The startup-guard set is internally
inconsistent — three guards inherit the bug, one is fixed.

**Why it matters:** post-OOM resume scenario is the highest-traffic
swarm event we hit. If a pidless zombie row from the prior session
still occupies the alias, the legitimate re-registration is blocked.
The agent ends up with `alias_hijack_conflict` errors, has to manually
sweep, or `c2c register` with a mangled alias. This is exactly the
pain Max has been routing around with #340 (post-OOM double-spawn).

**Suggested fix slice:** add `Option.is_some reg.pid &&` to all four
guards' predicates. Three-line change × three sites + one regression
test that registers a pidless zombie + a legitimate session and
asserts Guard 1/2/4 don't fire.

## Finding 3 — registration_is_alive inner branch on missing pid_start_time

**File:** `ocaml/c2c_mcp.ml:941`
**Severity:** MEDIUM (PID-reuse undetectable for legacy rows)

When the pid exists but `reg.pid_start_time = None`, the predicate
returns `true`. Means PID reuse cannot be detected for legacy rows
that never recorded a start_time.

Same shape as the outer Finding 1, smaller blast radius (`/proc/<pid>`
must still exist). Modern kernels make PID reuse rare, but it's not
zero — long-lived broker process + 32-bit pid_max + heavy fork
churn could trigger it.

**Suggested fix:** route through `registration_liveness_state`,
which returns `Unknown` for missing-start-time rows (correct
tristate). Operators get visibility, sweep treats as Unknown, nudge
treats as Unknown. Aligns the predicate with the rest of the system.

## Adjacent observations (not bugs)

- **`relay.ml:2460,2529` `check_auth: token = None → true`**:
  intentional dev-mode permit. Network-facing default-permit shape
  worth noting; deploy-config gates it. Severity: low (deliberate).
- **`relay_nudge.ml:78` `is_dnd_active`**: `dnd=true && dnd_until=None`
  returns `true` ("manual DND, no expiry"). Symmetric pattern but
  protects user intent rather than burning a downstream consumer.
  Severity: none (correct semantics).
- **`c2c_mcp.ml:2698` room_member_liveness** + **`:2540-2552` prune_rooms**:
  both handle pidless tristate correctly. Good models for hardening
  sweep + auto_register guards.

## Recommended slicing

Three follow-up slices, sequenced after #335 v2a lands:

1. **#XXX-sweep-hardening** — Finding 1, ~50 LoC + tests. Highest
   impact: closes the registry-junk loop.
2. **#XXX-auto-register-guard-pidless** — Finding 2, ~10 LoC × 3
   sites + tests. Highest UX impact for post-OOM resume.
3. **#XXX-pid-start-time-tristate** — Finding 3, ~5 LoC + a test.
   Cosmetic/security; lowest priority.

The three together (plus #335 v2a) close the "pid=None implies
alive" bug class across the broker.

## Notes

- All file:line references verified at HEAD `9344160d` via `grep -n`.
- No code changes proposed in this finding — observe-only, gated to
  v2a baseline data per the v2a sequencing.
- Cairn may want to spin one of the follow-up slices to a peer
  during the v2a window; happy to take any of the three.

— stanza-coder
