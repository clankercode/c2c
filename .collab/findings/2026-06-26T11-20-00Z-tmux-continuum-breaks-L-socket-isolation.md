# tmux-resurrect/continuum auto-restore breaks `-L <socket>` test isolation

- **UTC:** 2026-06-26T11:20Z
- **Author:** (Max-driven session, worktree `e2e-pi-opencode-model`)
- **Severity:** High for any live terminal test that spins up its own tmux
  server; medium operator-disruption risk.

## Symptom

1. During long 2-agent live runs (opencode launches especially), the **shared
   default tmux server died**, taking the operator's real sessions (`191`,
   `preview-md-dev`) with it. A plain `tmux new-session` worked again
   immediately after, and there was no OOM in dmesg.
2. The mitigation — run the chess e2e on a dedicated socket via
   `tmux -L c2c-chess-e2e` — did NOT isolate. Inspecting the socket showed the
   operator's **real sessions restored onto it** (`191`, `preview-md-dev` with
   live `~/src/amaroo`, `~/src/preview-md`, a c2c relay pane, a claude pane),
   and the chess game never started (boards stuck at ply 0).

## Root cause

The operator's `~/.tmux.conf` loads **tmux-resurrect/continuum**, which
**auto-restores saved sessions when a tmux server starts**. So:
- `tmux -L <socket> new-session` starts a *fresh server* → continuum's restore
  hook fires → it clones the operator's saved sessions onto the new socket.
- Worse, `new-session -d` **blocks while the restore runs**, so the test's
  `start_agent` hung and the agents never launched (ply 0 forever).

`-L <socket>` gives a separate *socket/server* but NOT a clean *config*: the
server still reads `~/.tmux.conf` and runs its plugins.

(The default-server death in (1) is likely the same family — heavy/rapid
session churn interacting with the continuum/resurrect hooks — though not
proven. Treat opencode live launches as capable of destabilizing a shared tmux
server.)

## Fix

Start the dedicated server with **`-f /dev/null`** so it ignores
`~/.tmux.conf` entirely (no plugins, no continuum, no auto-restore). In
`tests/e2e/framework/tmux_driver.py`, `TmuxDriver(socket=...)` now prepends
`["tmux", "-L", <socket>, "-f", "/dev/null"]` to every invocation.

Verified: `tmux -L probe -f /dev/null new-session -d -s x 'sleep 20'` →
`tmux -L probe -f /dev/null ls` shows ONLY `x` (no restored sessions), and
`new-session -d` returns immediately. The chess e2e then launches its agents
on a clean isolated server; the operator's default-socket sessions are never
touched.

## Lessons for the next agent

- **`-L <socket>` is not enough for isolation — add `-f /dev/null`.** A new
  tmux server still runs the user's config + plugins (resurrect/continuum,
  auto-save, key bindings) unless you suppress the config file.
- **Never run heavy live agents on the operator's default tmux socket.** Use a
  dedicated `-L` socket + `-f /dev/null`, and `kill-server -L <socket>` in
  teardown (it targets only that server).
- When a "dedicated socket" shows the operator's real sessions, do NOT
  `kill-server` blindly thinking it's only test state — confirm the socket
  (`ls /tmp/tmux-1000/`) and pane cwds first. Here the restored copies were
  separate from the live default-socket originals, so cleanup was safe, but
  verify before destroying.
