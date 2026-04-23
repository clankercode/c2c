# DRAFT — Ephemeral one-shot agents

**Status**: DRAFT — 4/7 open questions resolved with Max 2026-04-23; Q5/Q6/Q7 still open. Cron / scheduled invocation is explicitly **out of scope for v1** and belongs in a future sidequest.

**Authors**: coordinator1 (Cairn-Vigil), responding to Max's 2026-04-23 prompt; resolutions folded in from Max's inline comments same day.

## Problem

We already have good tools for the two extremes:

- **Subagent** (`Agent` tool) — spin up a throwaway helper for a single reasoning task within the current conversation. Great for reviews, research, focused implementation. **Limitation**: its dialogue is not visible to c2c peers, and it cannot continue across invocations — no "persistent state" you can DM into.
- **Managed peer** (`c2c start <client> -n <name>`) — spins up a real long-lived client session (claude/opencode/codex/kimi/crush). Fully networked on c2c. **Limitation**: designed to run indefinitely; no clean "do one job and terminate" lifecycle.

There is a real gap between these: a **short-lived, purpose-built agent that participates in c2c for one dialogue then cleanly shuts down**. The canonical example is the **role-designer handoff** — `c2c agent refine` spawns a dedicated session that talks to the human via c2c DM / room, iterates on the role file, and exits when the role is committed. Today we approximate this with subagents, but the dialogue is invisible to the rest of the swarm, which is the whole point of doing it in c2c.

## Kernel (what v1 must do)

- Launch a c2c-registered peer tied to a specific role file + bootstrap prompt
- Participate in c2c like any other peer (DMs, rooms)
- Clean termination when the task is done via a dedicated `c2c_stop_self` tool + idle-timeout belt-and-braces
- Registration + tmux pane + cleanup is one command, not an orchestration sequence

v1 does **not** need:
- Scheduling / cron
- Multi-instance fleets
- Dedicated broker namespace (one-shot bots use normal aliases, same broker)

## Resolved design choices (Max 2026-04-23)

### R1. Entry point shape — role-first, name auto-generated

Command: `c2c agent run <role-name> [--prompt "..."] [--timeout 30m]`

The user specifies the role file (the "agentfile"), NOT a bot name. Name is auto-generated as `<role>-<word>-<word>` (same pool as other allocations). Explicit `--name` override is allowed but rare — we don't expect callers to need it.

Under the hood this is just `c2c start` with `--ephemeral` + `--kickoff-prompt` plumbing — implementation can largely compose existing pieces.

### R2. Self-termination — dedicated tool, confirm-before-stop, idle-timeout backup

- Primary: a dedicated tool `c2c_stop_self` with a short description (keep prompt tokens low). Implementation-wise this may just be `c2c_stop` aliased to the caller's own session — decide during implementation based on which is simpler.
- Usage contract baked into the prompt template: "Once you have confirmed your job is complete with the caller, call `c2c_stop_self`." The agent MUST correspond with the caller to confirm done before stopping.
- Idle timeout: also supported (configurable via `--timeout`, default TBD). Supervisor kills the session if nothing flows in/out for the timeout window.

### R3. Prompt always present, template-wrapped

`--prompt` is **optional**. Some ephemeral agents don't need a caller prompt — they should just start working from the role file's directives.

Whatever the caller supplies (or nothing) gets appended into a general **prompt template** that always includes the load-bearing bits:
- who called this session
- how to signal completion (`c2c_stop_self`)
- how to confirm done with caller first
- idle-timeout reminder

So there's always a non-empty prompt sent to the child — the caller's `--prompt` is the *task-specific* slot in a fixed wrapper.

### R4. Naming — role-word-word default, explicit override rare

Confirmed: auto-generate `<role>-<word>-<word>`. `--name foo` override supported, not expected to be used often. No special ephemeral prefix (like `eph-`); the role name + word-word pattern is enough to see what's happening in `c2c list`.

## Still-open questions (need Max's next pass)

5. **tmux pane vs background?** — for humans iterating with a role-designer, tmux pane is a nicer UX (can peek). For non-interactive one-shots (post-commit review bot), background is cleaner. Options:
   - a) `--pane` / `--background` flags, no default
   - b) default depends on role type (`primary` → pane, `subagent` → background)
   - c) always background, let caller `tmux new-window` separately if they want to peek
   - _Coordinator lean: (b) — role already distinguishes primary vs subagent, default falls out naturally._
6. **Interaction with `c2c agent new` / `c2c agent refine`** — these already exist. Natural integration: `c2c agent new <name>` creates the role file → `c2c agent refine <name>` runs a role-designer ephemeral against it (i.e. refine becomes a thin wrapper around `c2c agent run role-designer --prompt "refine role <name>"`). **Question: should `c2c agent refine` become that wrapper in the same slice, or is it a follow-up?** _Coordinator lean: same slice — validates the primitive and kills the current "refine" improvisation in one go._
7. **Cleanup guarantees** — if the ephemeral bot crashes mid-dialogue, how do we avoid orphan registrations + dead tmux panes?
   - Proposal: supervisor process holds the pidfile; on exit (clean or crash) fires `c2c stop <name>` + `tmux kill-window`. Same shape as existing `c2c start` cleanup, just shorter-lived.
   - **Question: is a top-level "ephemeral supervisor" worth its own binary, or just a trap handler in the `c2c agent run` command path?** _Coordinator lean: trap handler in `c2c agent run`; no new binary — supervisor is already implicit in the outer loop for `c2c start`._

## First consumer

`c2c agent refine <role-name>` — re-implementing its guts against this ephemeral runner validates the design without any new user-facing feature and replaces the current improvised approach.

## Anti-goals

- **Don't build a job/task queue.** This is not Celery/Sidekiq/whatever. One shot, one purpose, clean exit.
- **Don't build scheduling.** Cron + ephemeral may compose later, but designing for cron now couples concerns and bloats v1.
- **Don't invent a new broker object.** Ephemeral bots register with normal aliases; their ephemerality is a lifecycle property, not a schema change.

## Implementation sketch (post-refinement)

Once Q5-Q7 resolve, shape is roughly:

```
c2c agent run <role> [--prompt "..."] [--name ...] [--timeout 30m] [--pane|--background]
  │
  ├─ load role file
  ├─ allocate ephemeral name (<role>-<word>-<word>)
  ├─ compose prompt = general_template + (role_directives) + (user_prompt or "")
  ├─ exec c2c_start.cmd_start with:
  │     ~client = role.client
  │     ~kickoff_prompt = composed prompt
  │     ~ephemeral = true       ← new
  │     ~idle_timeout = timeout ← new
  │     ~auto_join_rooms = role.rooms
  ├─ register cleanup trap: SIGCHLD / timeout → c2c stop + tmux kill
  └─ wait (if foreground pane) or detach (if background)
```

Plus an MCP tool `c2c_stop_self` (or `c2c_stop` aliased) on the ephemeral session. Short description. Calls the existing cmd_stop path, targeted at `C2C_MCP_SESSION_ID`.

Estimate: ≤150 LOC OCaml. Most of the work is integrating the cleanup trap + the prompt template + the ephemeral flag through `c2c_start`.

## Next step

Max answers Q5-Q7 (or agrees with coordinator leans). Then land implementation slice.

## References

- `c2c start` (OCaml `c2c_start.ml`) — managed peer launcher, reuse its env-building and pidfile plumbing
- `c2c agent new` / `c2c agent refine` — existing role creation flow
- Subagent / `Agent` tool — alternative we're distinguishing this from
- todo.txt entries: `c2c agent new` positional UX, clients-prompt `123` bug, this design doc
