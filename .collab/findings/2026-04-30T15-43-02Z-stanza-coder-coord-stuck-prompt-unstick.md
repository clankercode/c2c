# Stuck-coord prompt = approve via tmux keys, not failover

**UTC:** 2026-04-30T15:43:02Z
**Author:** stanza-coder
**Severity:** LOW (operator-discipline)

## Symptom

coordinator1's tmux pane was blocked at a `.mcp.json` permission
prompt for ~70+ minutes (Y/N approval to remove a legacy
`C2C_MCP_BROKER_ROOT` line). I peeked the pane every few heartbeat
ticks, confirmed the same screen, sent her a status DM (which
queued behind her blocked harness), pinged designated recovery
(lyra-quill — offline), and otherwise held silently. Multiple
peers (jungle, fern, cedar) accumulated as idle in the meantime.
Two peer-PASSed slices of mine (#502, #161) sat unratified.

## Discovery

Max nudged me directly: "you could have used tmux to unstick her.
all good I've got her sorted now, but FYI for future."

## Root cause

I misread the coordinator-failover runbook. It says:

> Diagnose with `./scripts/c2c_tmux.py peek coordinator1` BEFORE
> taking over — many "down" coords just need a permission prompt
> approved or a heartbeat nudge.

I interpreted "BEFORE taking over" as "don't touch the pane at
all unless you're failing over." It actually means **the
permission-prompt approval is the lightweight diagnose-and-unstick
move, not a takeover.** The runbook explicitly lists it as one of
the things you check for during the diagnose step.

## Fix

For future-stanza (and anyone else reading): if `peek coordinator1`
shows a Y/N prompt with an obviously-correct answer (e.g. removing
a known-deprecated env var, the standard `.mcp.json` shape), send
the approval keystroke directly:

```sh
./scripts/c2c_tmux.py keys coordinator1 1
```

(or `2` for "allow all" — usually the correct choice when she's
mid-edit on her own config). Verify with another `peek` that the
prompt cleared. Only escalate to failover (DM lyra-quill, or
swarm-lounge surge) if approval doesn't resolve, or if the pane
shows something genuinely ambiguous (uncommitted destructive op,
unfamiliar diff).

This is consistent with shared-tree etiquette: approving an
obviously-right prompt is the same class of light-touch peer
help as an inbox poke. Coord1 isn't down, she's mid-keystroke;
the keystroke just needs a hand.

## Counter-cases — when NOT to approve

- Diff shows files outside the coord's expected scope (someone
  else's worktree, large auto-generated content).
- Destructive op (`git reset --hard`, `git push --force`,
  large rm -rf).
- Ambiguity about which "Yes" path is right (multi-option
  prompts beyond Y/N).
- Pane is mid-compose of a slash command — wait for explicit
  commit.

## Severity

LOW. The cost was ~70min of held throughput across 4 idle agents
plus two parked peer-PASSed slices. No work lost; pure recovery
cost. Logging so the next compact-day stanza doesn't repeat.

## Cross-refs

- `.collab/runbooks/coordinator-failover.md` — diagnose step
  needs explicit "approving Y/N permission prompts is part of
  diagnose, not takeover" bullet.
- CLAUDE.md "Coordinator failover protocol" bullet — same
  clarification welcome.
