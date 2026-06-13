# Open Questions, Risks & Corrections

Consolidated from two adversarial critics — **C-adv** (correctness/completeness)
and **C-ux** (solo + flat-mesh persona stress test). Both verdicts:
**solid-with-gaps**. The synthesis (01–03) is directionally right; this file
carries the corrections and the items it missed. Read it before cutting any slice.

---

## 1. Factual corrections to 01–03 (use these numbers)

- **The literal counts are inflated.** "coordinator1 in ~70 sites" / "~85 literal
  call-sites" → actually **~47** non-test occurrences, and most of the `c2c.ml`
  ones are **help / onboarding prose**, not routing logic. Real routing-logic
  sites are **~8–10** (e.g. `kimi_hook.ml:230`, `opencode_plugin:105`,
  `c2c.ml:6509` reviewer default, `agent.ml:721`, `worktree.ml:1887`,
  `coord.ml:127`, `c2c.ml:7711` roster). **Implication:** B1 is an M-effort logic
  change **plus** a separate S-effort prose reword — not a 70-site mechanical
  migration. Don't thunk-route prose strings.
- **The two swarm-lounge prepends are NOT duplicates.** `c2c_broker.ml:4062-4084`
  fires on the unconfirmed→confirmed promotion path; `c2c_identity_handlers.ml:339-361`
  fires on a brand-new already-confirmed registration. They are **complementary
  registration transitions**. Route BOTH through the social-room thunk; do **not**
  "unify them" — a naive collapse drops one transition.
- **Tier-blocked commands are undercounted.** 01/B3 say "~4 agent-blocked
  commands"; `c2c_commands.ml:83-109` also Tier4-hides `state-read`, `state-write`,
  `room-invite`, and the whole `supervisor-*` family. The "collapse to a 2-state
  advanced boolean" conclusion still holds — but more entries carry the flag.
- **`role_class` auto-join "dead code" is an UNVERIFIED assumption**, presented
  with near-certainty. `build_env` (c2c_start.ml:2905-2924) consumes
  `role_class_opt`; whether `cmd_start` threads it was not re-verified. Confirm
  before relying on "it's dead."

## 2. Missed coupling / opportunities

- **The forced wake schedule is the biggest unaddressed persona friction.** Every
  `c2c install <client>` unconditionally calls `ensure_default_wake_schedule`
  (`c2c_setup.ml:1643`), writing a `wake.toml` (4.1m, idle-gated, self-DM). For a
  solo user or a flat mesh this is a poll loop nobody asked for. **Add a quick win:
  gate wake.toml creation on mode (solo → not created).** S-effort, one guard.
- **The broker is NOT "provably role-agnostic" after A2.** It still reads
  `C2C_COORDINATOR` at `c2c_broker.ml:1129-1134` (worktree-mismatch exemption). If
  the "provably agnostic" claim is to be literally true, remove that env-read in
  the same slice — otherwise reword the claim.
- **`c2c list` is the real discovery primitive** — it surfaces all registered
  peers with no room. So the `swarm-lounge` `peer_register` announce is redundant
  with `list` for discovery; state this affirmatively to de-risk A2.
- **The system-sender (`c2c-system`) must be preserved** when routing the prepends
  through the thunk — and when no social room is configured the broker should emit
  **no** registration announce at all (not an empty-room one).
- **Cheap removal left blocked on an un-run grep.** C3 (~50 deprecated Python
  scripts + `data/c2c_alias_words.txt`) is gated on "is `c2c_cli.py` a live
  dispatch path?" — a 2-minute grep closes it. Run it.

## 3. Risks — recategorized

- **A2 risk is Low, not Low-Med** (both critics): `peer_register` is
  **produced-only, never consumed** anywhere in ocaml/scripts/data — it's a
  human-readable room-history breadcrumb. *But* C-ux flags the counter-risk: if any
  live agent's Monitor keys off that line (plausible given CLAUDE.md's "broaden
  Monitor to broker dir" guidance), A2 silently breaks presence detection. → Close
  the open question (grep for consumers) **before** A2, then it's Low.
- **Fail-open approval (A5/B5) has a sequencing hazard.** Its own mitigation
  ("fail-closed iff mode=swarm") depends on the `mode` concept existing — but the
  recommended sequencing puts A5 early and B7/mode late. A window where a
  misconfigured team with empty `supervisors[]` silently stops gating. **Land mode
  before A5's fail-open, or make fail-open contingent on an explicit
  no-supervisors-configured signal.** Also a **cross-client parity** risk: kimi
  hook, opencode TS plugin, and the legacy `c2c-kimi-approval-hook.sh` have
  different failure modes — land A5/B5 as **one atomic slice** across all three
  (TS needs `just codegen-opencode-plugin`).
- **Splitting `C2C_COORDINATOR` (B2) touches the live coordinator privilege path.**
  It backs relay-as-other-alias (`c2c.ml:105-147`) AND git-shim bypass
  (`git-shim.sh:52`) AND cherry-pick (`c2c_coord.ml:202`) simultaneously. A compat
  alias must set **all** new flags atomically or a running coordinator loses a
  capability mid-session.
- **~85-literal migration churns hot shared-tree files** (`c2c_start.ml`,
  `c2c.ml`, `c2c_setup.ml` touched by 4+ slices A1/A3/A4/B1/B2/B7). Real
  cherry-pick/merge-ordering hazard under parallel swarm work — under-weighted.
- **relay_nudge severity is overstated** — it's idle-gated at 25 min, so an active
  solo user is never nudged. Lower B6's priority accordingly.

## 4. Open questions to resolve BEFORE cutting (most are cheap)

1. **[grep, 2 min]** Does anything consume `peer_register` in swarm-lounge? (gates
   A2 risk). *Both critics: verified produced-only — likely already answered "no".*
2. **[grep, 2 min]** Is `c2c_cli.py`/`c2c_registry.py` backing any live
   OCaml-unimplemented surface? (collapses C3 from blocked → one clean slice).
3. **[decide]** When `social_room` is unset, should the broker emit **no**
   registration announce? Confirm no managed-client onboarding depends on seeing
   its own "X registered" echo.
4. **[decide]** Remove the `c2c_broker.ml:1129-1134` `C2C_COORDINATOR` worktree
   exemption in the same slice as A2 to make "broker role-agnostic" literally true?
5. **[design]** Flat-mesh (Persona B) of **independent** peers: the broker root is
   `SHA-256(remote.origin.url)`, so three peers on **unrelated repos do not share a
   broker** and cannot `list`/DM each other at all. Mesh-across-repos needs an
   explicit shared `C2C_MCP_BROKER_ROOT` — **no proposal addresses this.** This is
   the deepest gap for the "flat mesh" north-star.
6. **[design]** Does `mode=mesh` mean "no auto-room, use `join_room` explicitly"?
   `join_room` is agent-visible, so a mesh can self-organize — but `room-invite` is
   Tier4-hidden from agent sessions (CLI), though the `send_room_invite` MCP tool
   may cover it. Check the CLI/MCP asymmetry so mesh peers aren't blocked from
   growing a room.
7. **[decide]** For solo, should the git **attribution** shim (alias-as-author,
   `GIT_AUTHOR_NAME=<alias>@c2c.im`) also default off? A solo user likely wants
   their own git identity, not `cedar-coder@c2c.im`.
8. **[coordinate]** `coordinator1` prose appears in onboarding preambles rendered
   into every role-launched agent's first transcript (`c2c.ml:9501-9502`,
   `9578-9579`). If the swarm operationally relies on "DM coordinator1", the prose
   swap must be coordinated with a config-pin first.

## 5. Cross-validated strongest recommendations

Both critics independently converged on:

1. **A1 (config thunks) is the correct #1** — verified absent, verified it
   unblocks A2/A3/B1/C6. Everything else is a scattered literal-hunt without it.
2. **De-risk + split A2** — downgrade to Low after the peer_register grep; route
   both prepend sites; drop the word "duplicate".
3. **Add wake-schedule gating as an independent A-tier quick win.**
4. **Ship the verified-dead removals now** — `crush` (refuses at
   `c2c_start.ml:5255`), `configure_claude_hook` (zero callers), the dormant
   `coordinator: true` funnel (no role file sets it). High-confidence, low-risk.
5. **Sequence the per-feature default inversions to land independently** of the
   `mode` umbrella (B7) — otherwise the personas aren't actually fixed until the
   very end of the migration.
