# #320 — CLAUDE.md trim under Claude Code 40k threshold

**Author:** stanza-coder
**Date:** 2026-04-27 11:19 AEST (UTC 01:19)
**Status:** doc-only slice
**Reviewer:** coordinator1 (scope confirmed via DM 11:51 AEST)
**Branch:** `slice/320-claude-md-trim`

## Problem

Max saw a Claude Code perf warning at session start: `⚠ Large
CLAUDE.md will impact performance (40.2k chars > 40.0k)`. Filed as
#320. Every fresh session / post-compact agent eats the full
injection cost on every wake; a CLAUDE.md over the threshold is a
real ongoing latency tax across the swarm.

Pre-trim: CLAUDE.md = 43539 chars / 528 lines.

## Approach

Move long reference sections to `.collab/runbooks/` (per docs-hygiene
discipline — the public Jekyll site at `docs/` would advertise
deprecated content as canonical, so internal-only content lives in
`.collab/`). Replace each in CLAUDE.md with a one-liner summary +
link-out.

## Extractions

| From CLAUDE.md section          | New runbook                                                |
| ---                             | --- |
| Documentation hygiene           | `.collab/runbooks/documentation-hygiene.md` (new) |
| Ephemeral DMs (#284)            | `.collab/runbooks/ephemeral-dms.md` (new) |
| Recommended Monitor setup       | folded into existing `.collab/runbooks/agent-wake-setup.md` |
| Per-agent memory (#163)         | `.collab/runbooks/per-agent-memory.md` (new; e2e doc retained) |
| Python Scripts (deprecated)     | `.collab/runbooks/python-scripts-deprecated.md` (new) |

The "Agent wake-up setup" + "Recommended Monitor setup" sections were
adjacent and both pointed at `agent-wake-setup.md`; merged into a
single CLAUDE.md section.

## Result

Post-trim: CLAUDE.md = 28480 chars / 347 lines. **34.6% reduction;
71% of threshold.** Comfortable headroom for future additions.

Net delta:
- 1 substantial existing runbook extended (agent-wake-setup.md).
- 4 new runbooks created.
- 5 CLAUDE.md sections collapsed to one-liner summaries + link-outs.
- `docs/CLAUDE.md` cross-references updated to point at new runbooks.
- `ocaml/cli/c2c_docs_drift.ml` comment updated (non-functional —
  c2c_docs_drift logic still uses CLAUDE.md as canonical audit
  target; only the comment text changed).

## Acceptance criteria

- AC1: CLAUDE.md ≤ 40k chars (passes Claude Code perf threshold).
- AC2: All 5 extracted sections have a one-line summary + clear
  link-out in CLAUDE.md.
- AC3: All 4 new runbooks present + readable; existing
  agent-wake-setup.md properly extended (not replaced).
- AC4: Cross-references in `docs/CLAUDE.md` updated to point at
  new runbook paths.
- AC5: `c2c_docs_drift.ml` comment updated; binary still builds + no
  functional change.
- AC6: Python Scripts section moved to `.collab/runbooks/`, NOT
  `docs/`, per docs-hygiene + Cairn's plan-PASS correction (don't
  advertise deprecated as canonical).
- AC7: No `c2c_*.py` references in CLAUDE.md after trim — they're
  all under the runbook now.
- AC8: Design doc filed.

## Open questions

- **Q1**: Development Rules section is still ~190 lines (largest
  remaining). Should that get its own trim pass? Lean defer — we're
  at 71% of threshold, additional trim is optional and the
  Development Rules content has a different shape (operational dos
  and don'ts vs reference material) that's harder to extract cleanly.
  Could be its own slice if Cairn wants tighter headroom.
- **Q2**: The `docs/CLAUDE.md` per-directory companion still
  references "Documentation hygiene" — I updated it to point at the
  new runbook. Worth verifying nothing else in `docs/` cross-references
  the old structure. (Searched; only `docs/CLAUDE.md` had the
  reference.)

## Notes

- This slice is the natural complement to #324/#325's runbook-as-
  canonical-home discipline. CLAUDE.md becomes the table-of-contents;
  runbooks hold the substance.
- `agent-wake-setup.md` was the only existing runbook extended (vs
  net-new). Chosen because the heartbeat/sitrep recipes naturally
  belong with the existing wake-up tradeoffs discussion.
- `per-agent-memory-e2e.md` retained as separate sister runbook (e2e
  test procedure is different concern from reference).

— stanza-coder
