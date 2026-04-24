# Ephemeral one-shot agents — review notes + role-specific rooms design sketch

**By**: tundra-coder-live2
**Date**: 2026-04-24

---

## Open questions / concerns on the ephemeral one-shot agents design

### Q1: Confirm-with-caller before stop_self
R2 says: "Agent MUST correspond with caller to confirm done before stopping."

What if the caller is unresponsive? Does the agent just wait indefinitely? There should be a fallback — perhaps after N confirm-attempts with no response, the agent exits anyway with a warning.

> Max says: timeout of 5 minutes. try again after 1 min up to 4 times. 

### Q2: Idle timeout definition
R2: "Supervisor kills session if nothing flows in/out for the window."

Does "broker activity" include the agent polling its own inbox? If the agent is actively thinking but not sending/receiving, does the clock run? The design says "no broker activity" which suggests inbox polls DO reset the clock — worth clarifying.

> Max: polling resets, KISS for the moment

### Q3: Parallel stop_self race
If both caller and ephemeral call `c2c_stop_self` simultaneously (caller says "done, stop" and agent independently decides to stop), is there any race condition? Likely harmless (stop is idempotent) but worth confirming.

> Max: hamrless, error if a stop is in progress already. 

### Q4: --pane autodetect fallback behavior
R5: `--pane` with autodetect — if not in tmux, falls back to `--background`. But `--background` spawns a detached process. What happens to stdout/stderr? Who sees it? For a human-in-the-loop `refine` session, `--background` is wrong. Maybe autodetect should error instead: "tmux required for --pane, pass --background explicitly if you want detached".

> Max: yeah that sounds good. We could support making split panes on some terminals too, but we can leave that for future work.

### Q5: Prompt template — where does the agent start working?
R3: `--prompt` gets appended to a template. But the template doesn't say WHEN the agent should start the work — immediately on role file directives, or only after confirming with caller? The template says "confirm with caller before stop_self" but doesn't say "start working immediately". Probably fine but worth one line clarification.

> Max: Yes start work immediately. 

### Q6: Cleanup on agent crash
If the ephemeral crashes mid-job (segfault, OOM), does `c2c stop <name>` still get called? The supervisor tracks PID — on unexpected exit, does it still run the cleanup?

> Max: shoudl still cleanup but ideally leave logs for recovery / analysis.

---

## Design sketch: role-specific rooms

**Problem**: Today all agents join `swarm-lounge`. There's no team coordination channel. A reviewer agent can't broadcast to all reviewers without joining every room.

**Goal**: Agents auto-join a role-specific room in addition to `swarm-lounge`, enabling targeted broadcasts (e.g., `#reviewers`, `#coders`).

### API shape

```bash
# Agent joins #coders on startup
c2c start claude -n my-coder --role coder
# → joins swarm-lounge + #coders automatically

# Role-specific room is derived from role name
# "coder" → "#coders", "reviewer" → "#reviewers", "coordinator" → "#coordinators"
```

### Implementation

**Option A — room auto-creation on first join** (simpler):
- `c2c start` passes `--auto-join-rooms swarm-lounge,#<role>s` to the agent
- Broker auto-creates the room if it doesn't exist (like any room)
- No explicit room provisioning needed

**Option B — explicit room declaration in role file** (safer):
```yaml
---
role: coder
c2c:
  auto_join_rooms: [swarm-lounge, #coders]
---
```
- Role file explicitly declares its room
- Explicit control, doesn't rely on naming convention

**Decision**: Option B is better. Naming convention (`coder` → `#coders`) is fragile and surprising. Explicit is clearer.

### Security / access control

- Rooms are **public** by default (anyone can join)
- For sensitive roles (e.g., `security`, `coordinator`), could add an access list — deferred to v2
- Room name derived from role slug: `c2c join #<role>s` (plural, e.g., `#coders`)

### Changes needed

1. `c2c_role.ml`: parse `c2c.auto_join_rooms` from role frontmatter
2. `c2c_start.ml`: pass `auto_join_rooms` to `cmd_start`
3. Existing roles: add `auto_join_rooms: [swarm-lounge]` to each role file (current behavior)
4. New roles created via `c2c agent new`: add the appropriate room based on role type

### Open question for role-specific rooms

Who creates the room? If the first `coder` agent starts before `#coders` exists, does the broker auto-create it? Need to verify `c2c join #coders` works when the room doesn't exist yet, or if it requires a `c2c room create #coders` first.

> Max: auto create. use room names like #role-coder or something, rather than #coders or #coder (high collission chance compared to #role-* prefixed rooms). also pluralizing a role can be hard to do right consistently so let's not bother. 
