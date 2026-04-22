---
alias: galaxy-coder
utc: 2026-04-22T13:50:00Z
severity: low
tags: [lifecycle, kickoff, restart, opencode]
---

# Item 103: Kickoff-on-restart investigation

## What was reported

On peer restart, the "you are a c2c agent" auto-message no longer fires.
Used to happen last session.

## Mechanism inspection (code review, not live test)

### Kickoff prompt flow

1. `c2c start opencode --agent <name>` calls `c2c_start.ml`'s `run_outer_loop`
2. If `--auto` or a role is set, `default_kickoff_prompt` is written to
   `<instance-dir>/kickoff-prompt.txt`
3. The `C2C_KICKOFF_PROMPT_PATH` env var is set so the plugin knows where to read it
4. Plugin's `deliverKickoffPrompt()` reads that file on `session.idle` and delivers
   via `promptAsync`
5. `kickoffDelivered` flag prevents re-delivery on subsequent idle events

### Key code — plugin (`c2c.ts`)

```typescript
// line 1324: module-level flag, initialized to false
let kickoffDelivered = false;

// line 725-729: session.created resets the flag so new root sessions get kickoff
function applyRootSessionCreated(event: Event): void {
  kickoffDelivered = false;
  ...
}

// line 1328-1350: deliverKickoffPrompt reads the file and delivers
function deliverKickoffPrompt(): void {
  if (kickoffDelivered) return;
  const text = fs.readFileSync(kickoffPromptPath, "utf-8").trim();
  ...
  kickoffDelivered = true;
  ...
}

// line 1547: deliverKickoffPrompt called on session.idle
```

### Key code — kickoff prompt content (`c2c.ml` line 6004)

```ocaml
let default_kickoff_prompt ~name ~alias ?role () =
  Printf.sprintf
    "You have been started as a c2c swarm agent.\n\
     Instance: %s  Alias: %s%s\n\
     Getting started:\n\
     1. Poll your inbox:  use the MCP poll_inbox tool...\n\
     ..."
```

### Analysis

The mechanism looks **correct on its face**:
- `kickoffDelivered` is reset to `false` on every `session.created`
- `deliverKickoffPrompt()` fires on `session.idle`
- The file path is per-instance (`<instance-dir>/kickoff-prompt.txt`), not shared

## Possible causes (not yet verified)

1. **Restart path bypasses `c2c start`**: If an agent is restarted via
   `restart_self` (SIGTERM to inner, outer relaunches), does `c2c_start.ml`'s
   `cmd_restart` re-write the kickoff prompt file? Checking `c2c_start.ml`
   `cmd_restart` — it calls `run_outer_loop` which handles kickoff. Should work.

2. **Plugin fails to load on restart**: If the OpenCode plugin fails to load
   silently (syntax error, missing dep), `deliverKickoffPrompt` never fires.
   See BUG item 110 (plugin silent break).

3. **`session.idle` never fires on restart**: If the restarted session enters
   a non-idle state and stays there, `deliverKickoffPrompt` won't fire.

4. **Instance dir cleared on restart**: The per-instance kickoff file might be
   wiped by `c2c start` on restart (fresh state dir), but this is the expected
   behavior since `c2c start` re-writes it.

## What a proper investigation needs

1. **Live restart test**: Start a managed OpenCode peer, send a message,
   restart via `c2c start <name>` (NOT `restart_self`), observe whether the
   kickoff prompt appears on next `session.idle`.

2. **Check `kickoff-prompt.txt` exists after restart**: `ls <instance-dir>/kickoff-prompt.txt`
   immediately after restart — if it's absent, the restart path isn't rewriting it.

3. **Plugin load verification**: Check `.opencode/c2c-debug.log` after restart
   to confirm plugin loaded successfully.

## Status

**Unverified** — code review suggests the mechanism is sound, but live
restart test is needed to confirm. Not actionable without a managed OpenCode peer.

Filed by Max 2026-04-22. Investigation by galaxy-coder 2026-04-22.
