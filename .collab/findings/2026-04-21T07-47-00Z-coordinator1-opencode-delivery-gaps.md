---
author: coordinator1
ts: 2026-04-21T07:47:00Z
severity: high
fix: FIXED — Gap 1: 6e1fd30 (stub size guard). Gap 2: 014a295 (exp-backoff cold-boot retry 3s→6s→12s)
---

# OpenCode c2c delivery: two gaps discovered during opencode-test revive

## Symptom

Two DMs sent to `opencode-test` were written to its inbox but the TUI
never acted on them. opencode-test was running with the c2c plugin
"loaded" per the log — but no promptAsync fired. Only a manual
tmux-keys kick into the TUI pane caused opencode to finally process
the queue (and the plugin then drained fine).

## Discovery

Max asked (2026-04-21 07:43) to bring opencode-test back into the
swarm. DM worked (ok -> opencode-test), registry showed alive,
inbox.json contained the messages. But nothing happened in the TUI
for ~2 minutes. Typing a prompt directly into the pane via
`tmux send-keys` finally kicked it; afterward the plugin functioned
normally.

## Root causes (two independent bugs)

### Gap 1 — global plugin install was a stub

`~/.config/opencode/plugins/c2c.ts` was **9 bytes** (`// plugin`).
OpenCode logs showed both the stub and the project-local real plugin
loading. With two plugin instances on the same session, behavior was
racy — at best, the real plugin's `startBackgroundLoop()` ran; at
worst, the stub no-op'd and the real plugin never initialized.

`c2c install` / `c2c init` / `c2c setup opencode` need to always
copy the live plugin file (or symlink to it) into the global path,
never leave a stub.

### Gap 2 — cold-boot promptAsync doesn't fire without a TTY keystroke

Even with the plugin correctly loaded, a freshly-started opencode
session does **not** call `promptAsync()` on queued inbox messages
until the user types at least one character into the TUI. The
earlier cold-boot audit confirmed `lifecycle.start` calls
`await tryDeliver()` at line 410 — but that delivery silently fails
(or is no-op'd) when the TUI hasn't yet acquired focus / rendered
its first frame / completed a pending auth flow.

After a keystroke-kick, subsequent deliveries work perfectly.

## Evidence

```
$ cat .git/c2c/mcp/opencode-test.inbox.json
[{"from_alias":"coordinator1",...,"content":"ping..."},
 {"from_alias":"coordinator1",...,"content":"welcome back..."}]

# after tmux send-keys 'hi...' + Enter:
$ cat .git/c2c/mcp/opencode-test.inbox.json
[]
```

## Proposed fix

### For Gap 1 (immediate, small)
- `c2c install` / `c2c setup opencode` / `c2c init` must write the
  real plugin to `~/.config/opencode/plugins/c2c.ts`, never the stub.
- Add a health check: `c2c health` (or `c2c doctor`) warns when the
  global plugin is suspiciously small (< 1KB).

### For Gap 2 (medium)
- Investigate the lifecycle.start `await tryDeliver()` path. Add
  logging: does it actually call `promptAsync`? Does the call
  succeed or throw? Is the TUI in a state that accepts it?
- Likely fix: retry loop with exponential backoff on the first
  delivery (TUI may need a beat to be ready).
- Or: plugin injects a no-op keystroke to the TUI on boot to force
  focus before the first delivery attempt.

## Workaround (today)

When reviving an opencode session that has queued DMs, send a
"kick" keystroke into the pane with `tmux send-keys -t <pane> 'hi' &&
scripts/c2c-tmux-enter.sh <pane>`. The first DM will flow; subsequent
ones work automatically.

## Related

- `.collab/findings/2026-04-21T04-01-00Z-coordinator1-opencode-permission-lock.md`
  — different symptom (blocked on dialog), related root area
  (TUI-synchronous delivery path).
- Cold-boot drain audit: `.opencode/plugins/c2c.ts:408-411` (the
  `await tryDeliver()` that *should* handle this).
