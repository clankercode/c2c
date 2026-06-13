# Role / Coordinator Decoupling — Research & Ideation

**Date:** 2026-06-13 · **Status:** research only (no implementation) · **Driver:** orchestrator-claude (Max-requested)

## The question

> Do we depend on the coordinator role anywhere? Make roles much less integral
> to how c2c normally works — modularize so users can choose a more or less
> structured team. Also identify improvements (removing things counts). Research
> / brainstorm / analyze only.

## Headline finding

**"Coordinator" is not a real role — and the messaging core is already
role-agnostic.** Concretely, "coordinator" is three loosely-coupled things:

1. one env flag `C2C_COORDINATOR=1` — the *only* thing that gates code;
2. a role-file boolean `coordinator: true` that just sets that flag (and is
   **dormant** — no shipped role file actually sets it);
3. a hardcoded alias string `"coordinator1"` used as a last-resort default that
   never gates privilege.

The broker delivery path (register / list / send / drain / rooms / send_all /
schedules / memory) opens **no** role or coordinator module. Decoupling is
therefore an **exterior refactor of defaults and edges**, not delivery-path
surgery — which is what makes it low-risk.

The work to reach "solo + flat-mesh + structured-swarm as a spectrum" is mostly
**subtraction and default-inversion**, plus finishing one indirection layer that
was designed but never built (the `swarm_config_social_room` /
`swarm_config_coordinator_alias` thunks — comment-only stubs today).

## The one place the swarm assumption leaks into the clean core

On every confirmed registration the broker **unconditionally prepends
`"swarm-lounge"`** to the new peer's rooms and posts a `peer_register` announce
(`c2c_broker.ml:4073`, `c2c_identity_handlers.ml:349`) — so even a solo user who
never opts in gets a phantom swarm-lounge room materialized. Removing this (routed
through the new social-room thunk) is the load-bearing de-swarm fix.

## Artifacts

| File | What |
| --- | --- |
| `01-current-state-role-coupling-map.md` | Every coupling point, tagged HARD/SOFT/CONVENTION-ONLY/NONE, with file:line. 24-row subsystem table. **1 HARD** coupling total (`coord cherry-pick`, outside the core). |
| `02-decoupling-architecture-proposal.md` | The Solo ⊂ Flat-mesh ⊂ Structured-swarm spectrum, the universal core, per-feature opt-in seams, a `mode` selector, and a 6-phase swarm-safe migration. |
| `03-improvements-and-removals.md` | Prioritized catalog: A quick-wins / B structural / C removals / D net-new. Removals-first, opinionated cut-list of verified-dead code. |
| `04-open-questions-and-risks.md` | **Read before acting.** Consolidated adversarial + solo/mesh-UX critique: factual corrections to 01–03, missed coupling, underweighted risks, and the cheap checks that close open questions. |
| `raw-findings/investigator-findings.json` | The 9 investigators' structured findings (evidence base). |
| `raw-findings/critiques.json` | The two critics' full structured output. |

## Top recommended moves (cross-validated by both critics)

1. **A1 — build the two config thunks** (`swarm_config_social_room`,
   `swarm_config_coordinator_alias`), mirroring the working
   `swarm_config_restart_intro`. This is the keystone that unblocks everything
   else. *Verified absent (comment-only).*
2. **A2 — remove the broker swarm-lounge prepend** (both complementary sites),
   routed through A1. *Risk is actually Low: `peer_register` is produced-only,
   never consumed — see 04.*
3. **Gate the forced 4.1-minute wake schedule** on mode (solo → not created). A
   self-DM poll loop is written into every install today; neither persona asked
   for it. *Missed by 02/03; surfaced by the UX critic.*
4. **Ship the confirmed-dead-code removals now** — `crush` residue,
   `configure_claude_hook`, the dormant `coordinator: true` funnel,
   no-op `C2c_poker`, legacy launchers (all verified safe).

## Method & caveats

- **9 parallel investigators** (grounded in current `master`, file:line evidence)
  → **3 synthesizers** wrote 01–03 → **2 adversarial critics** (correctness +
  solo/mesh-UX). Run via the Workflow tool.
- **Trust 04 over 01–03 on the numbers.** The synthesis inflated some counts
  (e.g. "coordinator1 in ~70 sites" → really ~47, many of them help/onboarding
  *prose*, not routing logic ≈ 8–10 real sites). 04 carries the corrections.
- This is analysis, not a decision. Several cuts hinge on open questions that a
  2-minute grep can close (listed in 04) — those should be answered before any
  slice is cut.
