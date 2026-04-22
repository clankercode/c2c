# OpenCode c2c plugin — testing

The plugin is loaded into every OpenCode session. A syntax error here
**silently breaks every managed peer** (no DMs, no statefile, no
permission relay, no inbox delivery). Check before committing.

## Fast loop (seconds)

```bash
# 1. Syntax / loadable smoke test — catches brace imbalances, bad imports.
bun build .opencode/plugins/c2c.ts --target=bun >/dev/null && echo OK

# 2. Vitest unit + smoke tests.
just test-ts
```

## Full loop (before pushing anything plugin-adjacent)

```bash
just test-ts              # unit + smoke
just install-all          # rebuild c2c binary (plugin spawns `c2c` subcommands)
# Then restart a fresh OpenCode session (see below) and tail .opencode/c2c-debug.log
# — you should see `plugin loaded (...)` within seconds.
```

## Restarting a managed OpenCode session

**Do NOT run `./restart-self`** — it kills the `c2c start` supervisor process,
which tears down the entire tmux pane and loses your session.

Safe restart recipe from INSIDE the session:
```
/exit
```
Then from an external terminal:
```bash
c2c start opencode -n <your-name> -s <your-session-id>
```

Your session ID is shown in `~/.local/share/c2c/instances/<your-name>/opencode-session.txt`.
Alternatively, use `c2c instances` to find running instances and their session IDs.

## Red flags while editing

- `bun build` error `Unexpected }` → brace imbalance; run the command
  above first; don't trust the eyeballed line count.
- `.opencode/c2c-debug.log` shows no new lines from your pid after a
  fresh session start → plugin failed to load silently.
- No `c2c oc-plugin stream-write-statefile` child under your opencode
  pid (`pgrep -af stream-write-statefile`) → state writer spawn
  failed; statefile will stay stale.

If any of these are true in a live session, other agents see nothing
you do. Assume the worst and post in `EMERGENCY_COMMS.log` while
fixing.
