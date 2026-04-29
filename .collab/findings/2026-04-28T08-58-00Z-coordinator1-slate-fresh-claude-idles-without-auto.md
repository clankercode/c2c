---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-28T08:58:00Z
slice: onboarding-ux
related: #341 (restart_intro), #389 (first-5-turns runbook), #390 (#onboarding room)
severity: MED
status: OPEN
---

# Fresh Claude Code session idles even with role + restart_intro configured

## Symptom

Launched slate-coder in pane 0:1.4:
```
c2c start claude --agent slate-coder -n slate-coder
```

Slate's role file (`.c2c/roles/slate-coder.md`) has `auto_join_rooms: [swarm-lounge, onboarding]` and `c2c.alias: slate-coder`. `.c2c/config.toml` has `[swarm]` section (restart_intro commented but `builtin_swarm_restart_intro` should fall back).

After channels-permission prompt approval (manual `1` + Enter — also a UX hit; Max had to point out the prompt), Claude Code lands at an empty `❯` prompt. **No orientation happens.**

Expected (per `.collab/runbooks/first-5-turns-for-new-agents.md`):
- whoami → list → memory_list → room_history → arm heartbeat Monitor → DM coordinator

Actual: idle prompt, indefinite wait for human/peer stimulus.

## Diagnosis

`--auto` flag isn't passed. Claude Code without `--auto` waits for explicit user input. The `restart_intro` (or the builtin fallback) gets prepended to the transcript but doesn't itself trigger a turn — it's just text the agent will see when she eventually starts processing.

Three paths to wake a fresh Claude session:
1. `c2c start claude --auto …` — auto-runs intro as the first prompt (already implemented per #341 era)
2. A human types something at the prompt (Max would normally do this)
3. A peer c2c DM lands → channel-push surfaces the `<c2c>` tag → Claude processes it as a turn (requires a peer who knows she's up)

In this session, I (coordinator1) DM'd her to manually wake — but that means **the coordinator is filling the role a human normally would**. That's not scalable: every new agent spin-up requires either Max-at-keyboard OR coord intervention.

## Outcome on this run (2026-04-28 18:59 AEST)

After my DM landed, slate's channel-push surfaced the `<c2c>` tag and she
processed it as her first turn. She executed the full runbook in **one turn**:
whoami → list → memory_list → room_history skim → heartbeat Monitor armed →
DM-back to coord. So the runbook itself is sound. The bootstrap problem is
strictly "who provides the first stimulus."

**This means coord-DM-as-bootstrap is actually a viable production pattern**:
- Operator launches `c2c start claude --agent <X>`
- New agent registers (auto, via role-file)
- New agent joins configured rooms (auto)
- c2c-system broadcasts `<X> registered` → coord sees the join in
  swarm-lounge → coord DMs welcome → new agent wakes & orients

Today that loop required me to notice the broadcast and DM. The c2c-system
broadcast IS the signal — coord could programmatically respond to it. That's
a separate enhancement (auto-welcome on peer-register).

## Severity assessment

MED, not HIGH:
- The runbook is correct; the role-file is correct; `c2c start` is correct.
- The flow just requires `--auto` or human/peer intervention.
- Real fix is documenting the convention or making `--auto` the default for role-file-launched sessions.

HIGH if we're aiming for "Max launches an agent and walks away" — which is the dogfood goal.

## Proposed fixes (pick one)

A. **Default `--auto` for role-file launches.** When `--agent <name>` is set AND `--auto` is not explicitly disabled, behave as if `--auto` was passed. Rationale: a role file IS the spec for what the agent should do; idling at prompt is meaningless.

B. **Document the convention.** Update CLAUDE.md / role-file template to remind operators to pass `--auto` for autonomous swarm spins.

C. **Hybrid — opt-out via role-file.** Add `auto: bool` to role-file frontmatter; default `true`; opt out via `auto: false` for cases where the operator wants an interactive launch.

C is probably right — preserves operator-choice while making autonomous-by-default the path of least resistance.

## Adjacent finding: channels-permission prompt

`--dangerously-load-development-channels server:c2c` triggers an interactive permission prompt on first session start of a new install (or whenever Claude doesn't have it cached). Slate hit this; I had to manually press `1` + Enter via `c2c_tmux.py keys`. Max flagged.

Possible mitigations:
- A `claude.permissions.json` or similar pre-approved channels config that `c2c install claude` writes
- Pre-approve channels via env var if Claude Code supports it
- Pass `--dangerously-skip-permissions` (heavy hammer, may not be safe)

Worth a separate finding if a clean path exists.

## Reproducer

```bash
# Launch slate (or any role-file agent) without --auto
c2c start claude --agent slate-coder -n slate-coder
# observe pane: lands at ❯, no whoami/list/orientation
```

## Open question for Max

Which fix shape do you prefer for the auto-orient gap? My instinct is C (role-file `auto: bool`, default true) but B (just document) is cheapest if you don't want to touch the launcher.
