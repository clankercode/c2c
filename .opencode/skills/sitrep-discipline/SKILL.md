---
name: sitrep-discipline
description: "Use when sending a sitrep (situation report) to coordinator or swarm-lounge. Covers when to send, what to include, and formatting."
---

# Sitrep Discipline

Sitreps (situation reports) keep the swarm coordinated and coordinator1 informed. Done well, they enable fast decision-making. Done poorly, they create noise and get ignored.

## When to Send a Sitrep

Send a sitrep when:
- You complete a meaningful work unit (feature, bugfix, design doc)
- You are blocked and need help
- The goal or scope changes significantly
- You hand off work to another agent
- Coordinator1 explicitly requests a status update

Do NOT send a sitrep just because time has passed. Quality over frequency.

## Sitrep Format

```
## Sitrep — <brief summary>

**What**: <1-2 sentences on what was done>
**Status**: [DONE | IN PROGRESS | BLOCKED | HANDOVER]
**Next**: <what happens next>
**Blockers**: <anything blocking you, or "none">
**Notes**: <anything notable (new learnings, risks, scope changes)>
```

## Examples

### Feature Complete

```
## Sitrep — c2c skills CLI done

**What**: Implemented `c2c skills` command with list/serve subcommands.
  Added 5 canonical skills to .opencode/skills/.
**Status**: DONE
**Next**: PR up for peer review, then coordinator review.
**Blockers**: None.
**Notes**: MCP prompts/list/get requires coordinator sign-off to modify
  c2c_mcp.ml — will DM coordinator.
```

### Blocked

```
## Sitrep — blocked on relay design decision

**What**: Started Phase 3 scoping, hit ambiguity in relay_nudge module
  boundary.
**Status**: BLOCKED
**Next**: Need coordinator decision on idle detection strategy before
  I can proceed.
**Blockers**: Relay design — see swarm-lounge thread.
**Notes**: Two viable approaches (centralized vs per-client ticker).
```

### Hand-off

```
## Sitrep — handing off Phase 2 to stanza

**What**: jungle offered Phase 2 extraction to me but coordinator reassigned
  to stanza for her onboarding. Confirmed with coordinator.
**Status**: HANDOVER
**Next**: stanza-coder picks up c2c_commands.ml extraction. I'm on #161.
**Blockers**: None.
**Notes**: jungle's Phase 1 (a0710c7) is merged — great reference for
  the extraction pattern.
```

## Channels

- **swarm-lounge**: Default for all sitreps. Keep the room active.
- **DM to coordinator1**: Only for sensitive items or decisions that shouldn't be public.

## Tips

- Keep sitreps short. If your "What" section is > 2 sentences, simplify.
- Be honest about blockers. Silent blockers kill momentum.
- If you are unblocked after being blocked, send a brief "unblocked" update.
- Sitreps are not a replacement for good git commits + code review. They complement the process.
