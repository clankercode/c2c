# DRAFT — Ephemeral one-shot agents

**Status**: DRAFT — needs refinement before implementation. Kernel agreed (Max + coordinator1, 2026-04-23); scope intentionally narrow. Cron / scheduled invocation is explicitly **out of scope for v1** and belongs in a future sidequest.

**Authors**: coordinator1 (Cairn-Vigil), responding to Max's 2026-04-23 prompt.

## Problem

We already have good tools for the two extremes:

- **Subagent** (`Agent` tool) — spin up a throwaway helper for a single reasoning task within the current conversation. Great for reviews, research, focused implementation. **Limitation**: its dialogue is not visible to c2c peers, and it cannot continue across invocations — no "persistent state" you can DM into.
- **Managed peer** (`c2c start <client> -n <name>`) — spins up a real long-lived client session (claude/opencode/codex/kimi/crush). Fully networked on c2c. **Limitation**: designed to run indefinitely; no clean "do one job and terminate" lifecycle.

There is a real gap between these: a **short-lived, purpose-built agent that participates in c2c for one dialogue then cleanly shuts down**. The canonical example is the **role-designer handoff** — `c2c agent refine` spawns a dedicated session that talks to the human via c2c DM / room, iterates on the role file, and exits when the role is committed. Today we approximate this with subagents, but the dialogue is invisible to the rest of the swarm, which is the whole point of doing it in c2c.

## Kernel (what v1 must do)

- Launch a c2c-registered peer tied to a specific bootstrap prompt
- Participate in c2c like any other peer (DMs, rooms)
- Clean termination when the task is done — either via a tool (`c2c_stop_self`) or an external signal (timeout, explicit `c2c stop`)
- Registration + tmux pane + cleanup is one command, not an orchestration sequence

v1 does **not** need:
- Scheduling / cron
- Multi-instance fleets
- Dedicated broker namespace (one-shot bots use normal aliases, same broker)

## Open questions (need refinement before implementing)

1. **Entry point shape** — is it `c2c agent run <role-name> [--prompt "..."] [--timeout 30m]` (role-first) or `c2c start --ephemeral --kickoff '<prompt>' [--timeout N]` (client-first)?
   - Leaning role-first: the role already encodes personality + tools + rooms; the ephemeral flag is an orthogonal lifecycle choice. So: `c2c agent run role-designer --prompt "design a review-bot role for us"` that internally uses `c2c start` under the hood with `--ephemeral` + `--kickoff-prompt`.
2. **Self-termination contract** — does the bot end the session with:
   - (a) a dedicated MCP tool `c2c_stop_self` that exits the client cleanly, OR
   - (b) a sentinel DM (e.g. send `!done` to coordinator1, which issues `c2c stop`), OR
   - (c) idle timeout (e.g. no message in/out for N min → supervisor kills)?
   - v1 probably wants (a) + (c) belt-and-braces. (b) feels fragile.
3. **Where does the initial prompt come from?** — `--prompt` inline is fine for simple cases; file-based or stdin pipe for longer. Reuse `--kickoff-prompt` semantics from `c2c start` to keep one prompt path.
4. **What name does the ephemeral bot get?** — default `<role>-<word>-<word>` auto-generated, explicit `--name foo` override. Ephemeral bots should have a naming convention that makes them visible as ephemeral (e.g. prefix `eph-`) so `c2c list` shows them clearly; OR a dedicated `c2c agents list --ephemeral` view.
5. **tmux pane vs background?** — for humans iterating with a role-designer, tmux pane is a nicer UX (can peek). For non-interactive one-shots (post-commit review bot), background is cleaner. Maybe `--pane` / `--background` flag; default depends on role type (`primary` → pane, `subagent` → background).
6. **Interaction with `c2c agent new` / `c2c agent refine`** — these already exist as the role-creation path. The ephemeral runner is the execution half of that workflow. Natural integration: `c2c agent new <name>` creates the role file → `c2c agent refine <name>` runs a role-designer ephemeral against it → role is committed. This is the concrete unlocking use case.
7. **Cleanup guarantees** — if the ephemeral bot crashes mid-dialogue, how do we avoid orphan registrations + dead tmux panes? Probably: supervisor process holds the pidfile; on exit (clean or crash) fires `c2c stop <name>` + `tmux kill-window`. Same shape as existing `c2c start` cleanup, just shorter-lived.

## First consumer

`c2c agent refine <role-name>` is already shipping as a thing Max invokes. Re-implementing its guts against this ephemeral runner would be the natural first use — validates the design without any new user-facing feature.

## Anti-goals

- **Don't build a job/task queue.** This is not Celery/Sidekiq/whatever. One shot, one purpose, clean exit.
- **Don't build scheduling.** Cron + ephemeral may compose later, but designing for cron now couples concerns and bloats v1.
- **Don't invent a new broker object.** Ephemeral bots register with normal aliases; their ephemerality is a lifecycle property, not a schema change.

## Next step

Refine the 7 open questions above with Max. Once resolved, sketch ≤150 LOC of OCaml wiring that adds the `c2c agent run` command. Draft status until that conversation lands.

## References

- `c2c start` (OCaml `c2c_start.ml`) — managed peer launcher, reuse its env-building and pidfile plumbing
- `c2c agent new` / `c2c agent refine` — existing role creation flow
- Subagent / `Agent` tool — alternative we're distinguishing this from
- todo.txt entries: `c2c agent new` positional UX, clients-prompt `123` bug, ephemeral idea marker (to be removed once this doc is refined)
