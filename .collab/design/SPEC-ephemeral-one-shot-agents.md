# SPEC — Ephemeral one-shot agents

**Status**: SHIPPED — implementation complete.

Key commits:
- `b129fd0` — fix #143: suppress default auto-join for ephemerals; thread --auto-join to c2c start
- `4219062` — feat(ephemeral): add mode dispatch + reply-to + no-autojoin for agent run
- `c835c2d` — feat(agent refine): add --agent-mode for peer invocation
- `ef91d58` — design: add ephemeral agents implementation notes from galaxy review

CLI commands: `c2c agent run`, `c2c agent refine`. MCP tool: `mcp__c2c__stop_self`.

**Authors**: coordinator1 (Cairn-Vigil), responding to Max's 2026-04-23 prompt; resolutions folded in from Max's inline comments same day.

## Problem

We already have good tools for the two extremes:

- **Subagent** (`Agent` tool) — spin up a throwaway helper for a single reasoning task within the current conversation. Great for reviews, research, focused implementation. **Limitation**: its dialogue is not visible to c2c peers, and it cannot continue across invocations — no "persistent state" you can DM into.
- **Managed peer** (`c2c start <client> -n <name>`) — spins up a real long-lived client session (claude/opencode/codex/kimi/crush). Fully networked on c2c. **Limitation**: designed to run indefinitely; no clean "do one job and terminate" lifecycle.

There is a real gap between these: a **short-lived, purpose-built agent that participates in c2c for one dialogue then cleanly shuts down**. The canonical example is the **role-designer handoff** — `c2c agent refine` spawns a dedicated session that talks to the human via c2c DM / room, iterates on the role file, and exits when the role is committed. Today we approximate this with subagents, but the dialogue is invisible to the rest of the swarm, which is the whole point of doing it in c2c.

## Kernel (what v1 must do)

- Launch a c2c-registered peer tied to a specific role file + bootstrap prompt
- Participate in c2c like any other peer (DMs, rooms)
- Clean termination via `mcp__c2c__stop_self` tool + idle-timeout backup
- Registration + run + cleanup is one command, not an orchestration sequence

v1 does **not** need:
- Scheduling / cron
- Multi-instance fleets
- Dedicated broker namespace (one-shot bots use normal aliases, same broker)

## Resolved design (Max 2026-04-23)

### R1. Entry point — role-first, name auto-generated

Command: `c2c agent run <role-name> [--prompt "..."] [--timeout 30m]`

User specifies the role file (the "agentfile"), NOT a bot name. Name auto-generated as `eph-<role>-<word>-<word>` (`eph-` prefix makes it obvious in `c2c list`). Explicit `--name` override allowed but rare.

Under the hood this is `c2c start` composed with new `--ephemeral` + `--kickoff-prompt` plumbing.

### R2. Self-termination — dedicated tool + confirm-with-caller + idle-timeout

- Primary: a dedicated tool `mcp__c2c__stop_self` with a short description (keep prompt tokens low). Implementation may just be `c2c_stop` aliased to the caller's own session — decide during implementation based on which is simpler.
- Contract baked into the prompt template: "Once you have confirmed your job is complete with the caller, call `mcp__c2c__stop_self`." Agent MUST correspond with caller to confirm done before stopping.
- Idle timeout: supported via `--timeout` (default TBD). Supervisor kills session if nothing flows in/out for the window.

### R3. Prompt — always present, template-wrapped

`--prompt` is **optional**. Some ephemeral agents don't need a caller prompt — they should start working from role file directives alone.

Caller's `--prompt` (or empty) gets appended into a general **prompt template** that always includes:
- who called this session
- how to signal completion (`mcp__c2c__stop_self`)
- the confirm-with-caller rule
- idle-timeout reminder

### R4. Naming — `eph-<role>-<word>-<word>`

Auto-generated pattern with `eph-` prefix so `c2c list` shows ephemerals clearly. `--name` override supported, not often used.

### R5. Terminal-harness options (pane / background / headless)

Flags control where the ephemeral runs:

- `--pane [TARGET]` — run in a tmux pane. TARGET (cli arg) specifies where: `session-name`, `session:window`, `session:window.pane`, or omitted → autodetect (current tmux context if any, else create a new session named `c2c-ephemerals`). "New window in this session" and "new pane in window xyz" should both be easy to express.
- `--background` — no terminal, run as a detached process. For non-interactive one-shots (review bot, post-commit hook).
- `--headless` — for systems where tmux isn't available or the client supports it (e.g. codex-headless). Reuse existing headless plumbing from `c2c start`.
- Default: `--pane` with autodetect (human-peek friendly), since the first consumer (`refine`) is interactive.

Different terminal-harnesses for different roles is a supported dimension — role-file can hint (future), but v1 ships the three flags and defaults.

### R6. `c2c agent refine` integration — same slice

Natural composition: `c2c agent new <name>` (creates role file) → `c2c agent refine <name>` (runs role-designer ephemeral against it) → role committed. `refine` becomes a thin wrapper around `c2c agent run role-designer --prompt "refine role <name>"` in the same implementation slice that lands the primitive. Kills the current improvisation.

### R7. Cleanup — run c2c directly so pane closes on exit, NO kill-window

Max explicit constraint: **do not kill-window**. With complex tmux setups (multi-pane sessions, user's working window) this is dangerous. Preferred shape:

- The ephemeral supervisor runs the `c2c start`-equivalent call **directly** in the pane (not as a detached child).
- When the child exits (clean via `c2c_stop_self`, idle-timeout, or crash), the pane dies with it — and the window dies naturally if it was the only pane. No `tmux kill-window` needed.
- Supervisor still tracks PID, sends updates back to the calling agent (e.g. "ephemeral exited cleanly at 18:32" / "ephemeral hit idle-timeout"), and ensures `c2c stop <name>` on crash so the broker registration is released.

## First consumer

`c2c agent refine <role-name>` — rewriting against the ephemeral runner validates the design. **Max will dogfood the first version by having coordinator1 (Cairn-Vigil) test it with a brand-new role** — a direct feedback path, agent-to-feature.

## Anti-goals

- **Don't build a job/task queue.** One shot, one purpose, clean exit.
- **Don't build scheduling.** Cron + ephemeral may compose later; designing for cron now bloats v1.
- **Don't invent a new broker object.** Ephemeral bots register with normal aliases; ephemerality is a lifecycle property, not a schema change.
- **Don't `tmux kill-window`.** Let the pane close naturally with its child process.

## Implementation sketch

```
c2c agent run <role> [--prompt "..."] [--name ...] [--timeout 30m]
                     [--pane [TARGET] | --background | --headless]
  │
  ├─ load role file
  ├─ allocate name = --name or "eph-<role>-<word>-<word>"
  ├─ compose prompt = general_template.fill(
  │     caller = <calling session alias>,
  │     stop_procedure = "call c2c_stop_self once caller confirms done",
  │     idle_timeout = timeout,
  │     user_prompt = --prompt or "",
  │   )
  ├─ supervisor = fork()
  │     │
  │     ├─ if --pane: exec tmux new-window/new-pane (depending on TARGET) running
  │     │    c2c start <client> -n <name> --ephemeral --kickoff-prompt <composed>
  │     │    directly in the pane (NOT as detached child)
  │     ├─ if --background: spawn c2c start with --ephemeral, detach
  │     └─ if --headless: exec headless mode of the client
  │
  ├─ supervisor waits on child; on exit:
  │     ├─ report exit_reason to caller via c2c DM
  │     ├─ invoke c2c stop <name> (releases registration)
  │     └─ pane dies naturally with child; no kill-window
  │
  └─ idle-timeout watcher: if no c2c traffic for --timeout, SIGTERM child
```

Plus an MCP tool `c2c_stop_self` (or `c2c_stop` aliased) on the ephemeral session. Short description. Calls `cmd_stop` targeted at `C2C_MCP_SESSION_ID`.

Estimate: ~150 LOC OCaml wiring across `c2c_start.ml` (ephemeral flag, timeout, kickoff) + a new `c2c_agent_run` sub-command. Additional ~30 LOC for `c2c_stop_self` MCP tool. Total under ~200 LOC real code plus tests.

## Test plan

Dogfood-first: once the primitive lands, Max runs `c2c agent refine <new-role>` against a fresh role. Cairn-Vigil verifies the ephemeral:
- spins up with correct name (`eph-role-designer-<word>-<word>`)
- appears in `c2c list` with eph- prefix
- receives kickoff prompt + template wrapper
- can DM the calling session + the human
- closes cleanly on `c2c_stop_self` (pane dies, registration released, caller notified)
- hits idle-timeout correctly when unattended

Then: unit tests around prompt template composition, name allocation, flag parsing, timeout watcher. Integration: end-to-end with a minimal role file in a test harness.

## References

- `c2c start` (OCaml `c2c_start.ml`) — managed peer launcher, reuse its env-building and pidfile plumbing
- `c2c agent new` / `c2c agent refine` — existing role creation flow
- Subagent / `Agent` tool — alternative we're distinguishing this from
- todo.txt entries: `c2c agent new` positional UX, clients-prompt `123` bug, this design doc
