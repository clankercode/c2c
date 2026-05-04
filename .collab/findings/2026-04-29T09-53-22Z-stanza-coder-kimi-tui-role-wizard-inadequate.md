# Kimi launch role-wizard is inadequate for new-agent bootstrap

- **Date:** 2026-04-29 09:53 UTC
- **Filed by:** stanza-coder
- **Severity:** MEDIUM (mild friction in single-shot use; load-bearing during multi-node bring-up)
- **Status:** DEPRIORITIZED (2026-05-04) — wizard still produces stubs for novel names, but agent-self-authoring is the canonical workaround and is well-documented
- **Related issue:** #423 (role template codegen + embedded module — see commits `8377c8c5`, `c49839c9`, `bc54f046`, `fe3e1369`). The wizard MAY be a regression-with-gaps rather than a fresh bug; this finding is the discovery, not the diagnosis.

## Summary

`c2c start kimi -n <new-name>` (and presumably the other `c2c start <client>`
paths that share the launcher) opens an interactive wizard prompting for
the agent's role. The prompt accepts arbitrary input but the resulting
role-file is only meaningful if the input matches a known role-template
class (#423's `Role_templates.lookup`). Novel role names — exactly the
case during multi-node bring-up where each new alias is, by design, novel —
produce a stub that does not encode the agent's swarm conventions, focus
area, or kimi-specific tuning.

The downstream effect: the new agent comes online without the muscle
memory needed to participate as a real peer (worktree discipline, peer-PASS,
push gating, finding-filing cadence). The launcher technically succeeded
(MCP connected, broker registration alive, DM round-trip works), but the
agent it launched is functionally a tabula-rasa kimi session, not a
swarm peer. That gap is not surfaced by the launcher's success indicators.

## Symptom (what I observed)

1. Ran `c2c start kimi -n kuura-viima` from inside pane `0:2.2`.
2. Wizard prompted: "What is this agent's role? (e.g. coder, planner,
   coordinator — press Enter to skip)".
3. I typed `kimi-explorer` (descriptive but novel — not in the
   `Role_templates` lookup table).
4. Wizard accepted the string and proceeded. Kimi TUI launched, MCP
   connected, broker registered alive, wire-daemon auto-started.
5. **No real role file got written for `kuura-viima`** — the wizard's
   success path on a novel name is to record the string and move on.
   The launched agent has no internalized role; she's a stock kimi session
   that happens to have a c2c MCP server attached.
6. Coord-side observation (Max via Cairn, 19:52): the wizard is
   "inadequate" for novel-agent bootstrap. The right path is
   **agent-self-authoring** — DM the freshly-launched agent and ask
   her to draft her own `.c2c/roles/<alias>.md`, then commit.

## Discovery context

This was uncovered during the 2026-04-29 kimi-node bring-up slice
(coord-assigned via DM 19:46 UTC). I drove `c2c start kimi` directly
via `tmux send-keys` rather than via `scripts/c2c_tmux.py launch`,
which exposed the role prompt. (The launch helper has a `--role` flag
that pre-seeds `.c2c/roles/<name>.md` to skip the prompt — see below.)

## Root cause (best-guess pending diagnosis)

#423 added role-template codegen + an embedded module
(`Role_templates`) that renders bodies for known role classes. The
wizard at `prompt_for_role` calls `Role_templates.render` for known
strings (Path A, `c49839c9`) and the same is plumbed into
`agent_new` (Path B, `bc54f046`). Smoke tests landed in
`fe3e1369` / `954f8c55`.

The gap is at the **input-domain boundary**: an arbitrary
human-typed role name is silently accepted even when it doesn't
match any template. The wizard does not warn ("no template for
'kimi-explorer' — agent will start with no role body, are you sure?")
and does not redirect to a fallback authoring path
(self-author / pick-from-list / cancel).

For a single-operator one-shot run, this is mild — the operator knew
what they meant. For multi-node bring-up (the actual production
workflow as the swarm grows), this is load-bearing: every new alias
is by definition novel, and the wizard's silent-stub behavior means
every newly-launched peer is born role-less.

## Recommended fixes (short → long term)

1. **Document the workflow.** Update `CLAUDE.md` "Launch managed
   sessions" bullet to call out: for novel aliases, prefer
   `scripts/c2c_tmux.py launch --role-file <path>` OR pre-write
   `.c2c/roles/<alias>.md` BEFORE launching, so the wizard does not
   prompt. Cross-link to the agent-self-authoring path as the
   bootstrap-from-zero recipe (see "Workaround" below).

2. **Wizard upgrade — Path A** (catch novel names early): when input
   is not in `Role_templates.lookup`, surface a clear branch:
   ```
   No template for 'kimi-explorer'. Options:
     [s]elf-author    — launch with a stub role; the agent drafts
                        her own role file as her first task
     [l]ist          — pick from known templates
     [c]ancel        — abort launch, write a role file manually first
   ```
   Default to `s` (self-author) for the multi-node case to be
   ergonomic.

3. **Wizard upgrade — Path B** (post-launch nudge): the launched
   agent's first kickoff prompt could include a self-author task if
   the role file is a stub. This requires plumbing a "is-stub"
   signal into the kickoff prompt assembly path; not trivial.

4. **Verify #423 coverage**: that issue's smoke tests cover the known-
   template case. They don't appear to cover the novel-name case
   (the failure mode I just hit). A follow-up test that asserts
   "novel-name → wizard surfaces self-author option (or rejects)"
   would close the loop.

## Workaround (the bootstrap-via-agent loop)

This is what coord1 directed and what I'm doing for `kuura-viima` /
`lumi-tyyni` right now:

1. Launch with stub role (or pre-seed a minimal role file).
2. DM the freshly-online agent with a self-author brief covering:
   (a) what they're tuned for given client strengths;
   (b) the `.c2c/roles/<name>.md` shape (frontmatter + body, point
       at sibling roles to compare);
   (c) the swarm conventions to bake in (worktree-per-slice,
       peer-PASS, no `git push`, no destructive git ops, findings
       cadence, heartbeat = work-trigger);
   (d) commit in `.worktrees/<alias>-role/` branched from
       `origin/master`, DM SHA back, coord cherry-picks.
3. Verify the committed role file is real (not a stub) before
   marking bring-up done.

This dogfoods the swarm-authoring-its-own-peers pattern, which is
quintessentially c2c. Worth keeping as a deliberate workflow even
once the wizard is fixed — there's value in an agent describing
herself rather than picking from a menu.

## Cross-references

- Commits: #423 chain (`8377c8c5`, `c49839c9`, `bc54f046`,
  `fe3e1369`, `411ae2c1`, `3ad5f62f`, `0e0cc4a0`, `954f8c55`).
- Related runbook: `.collab/runbooks/git-workflow.md` (worktree
  discipline that the new agent needs to internalize).
- Related runbook: `.collab/runbooks/first-5-turns-for-new-agents.md`
  (companion path: what a fresh agent should do in their first turns;
  authoring own role file is a reasonable extension).
- `scripts/c2c_tmux.py launch --role <ROLE>` is the existing
  pre-seed escape hatch (writes `.c2c/roles/<name>.md` before
  invoking `c2c start`) — works around the wizard for the
  c2c_tmux-driven launch path. Direct `tmux send-keys` callers
  hit the wizard.

## Status: DEPRIORITIZED (2026-05-04)

The wizard still produces stubs for novel role names, but this is
no longer blocking. The agent-self-authoring workaround (§ Workaround
above) has been the canonical bring-up path since the original
filing and is well-established. The wizard upgrade (Path A/B) remains
a nice-to-have for UX polish but is not on the critical path.
Deprioritized per stanza-coder triage 2026-05-04.
