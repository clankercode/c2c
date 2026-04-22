# `include:` Snippet Loader — v1.1 Spec

## Motivation

Canonical role files repeat common stanzas across many agents:
- How to use c2c (DMs, rooms, poll_inbox)
- How to set up monitors
- Push discipline / coordinator gate

The `include:` field lets these be defined once in `.c2c/snippets/<name>.md`
and imported into any role's body, rather than copy-pasted.

## Schema

```yaml
---
description: My agent
include: [c2c-basics, monitors-setup]
---

My custom persona body here.
```

`include` is a top-level frontmatter field (not per-client). It's a list of
snippet names. Order matters — snippets are prepended in order.

## Loader Behavior

1. Parse canonical role file → extract `include: [...]` list
2. For each snippet name in order:
   - Read `.c2c/snippets/<name>.md`
   - Prepend snippet content to the role's body
3. Render the expanded body with per-client renderer

**Prepend vs append**: Snippets are prepended so the role's own body
appears last (dominates). Append is available if needed.

## Snippet Paths

- `.c2c/snippets/c2c-basics.md` — DMs, rooms, poll_inbox conventions
- `.c2c/snippets/monitors-setup.md` — c2c monitor --all + heartbeat + ScheduleWakeup
- `.c2c/snippets/push-policy.md` — coordinator gate, when to push

Snippets live alongside canonical roles — committed to git.

## Error Handling

- Missing snippet → abort with clear error: `snippet not found: <name>`
- Empty include → no-op, body unchanged

## Starter Snippet Content

### c2c-basics.md
```
## c2c basics

- Poll inbox at the start of each turn: `c2c poll_inbox`
- Send DMs: `c2c send <alias> <message>`
- Join rooms: `c2c rooms join <room-id>`
- Check swarm roster: `c2c list`
```

### monitors-setup.md
```
## Monitor setup

Arm a persistent inbox monitor:
```
c2c monitor --archive --all
```

Heartbeat every 4.1 minutes:
```
heartbeat 4.1m "Continue available work..."
```
```

### push-policy.md
```
## Push policy

Do NOT run `git push` yourself. The coordinator1 agent is the push gate.
When you have a commit ready to deploy, DM coordinator1 with the SHA
and what needs to go live.
```
