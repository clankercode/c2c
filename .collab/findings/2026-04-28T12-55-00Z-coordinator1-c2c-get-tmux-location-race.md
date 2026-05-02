---
agent: coordinator1 (Cairn-Vigil)
ts: 2026-04-28T12:55:00Z
slice: tmux-location-race
related: scripts/c2c_tmux.py — peek/keys/exec callers
severity: MED
status: CLOSED
---

# `c2c get-tmux-location` returns wrong pane under concurrent invocation

## Symptom

Max ran `c2c get-tmux-location` near-simultaneously in three panes (0:3.4, 0:3.2, 0:3.6). Two of the three panes saw cross-talk on the first call:

- Pane **0:3.4** got `0:3.6` first, then `0:3.4` correctly second
- Pane **0:3.2** got `0:3.4` first, then `0:3.2` correctly second
- Pane **0:3.6** got `0:3.6` both times

Reproduced via tmux peek of all three panes after the test.

## Diagnosis

Most likely the implementation queries the tmux server for the "current active pane" (e.g., `tmux display-message -p '#{pane_id}'`) which respects the **server's** notion of which pane the user last interacted with — NOT the pane in which the calling process actually runs.

Race: pane A's `c2c get-tmux-location` fork → tmux query → tmux returns pane B's id (because B was active a microsecond ago) → A reports B's location.

The correct resolution path:
- Read `$TMUX_PANE` env var (set in every tmux pane child process; pane-specific by definition)
- Or resolve from `$TTY` / `/proc/$$/fd/0` to find the controlling tty, then ask tmux for the pane bound to that tty

`$TMUX_PANE` is the canonical zero-cost answer.

## Reproducer

```bash
# In three separate tmux panes simultaneously:
c2c get-tmux-location
# Some panes will report a different pane's location.
```

## Fix sketch

In whatever OCaml/shell implements `c2c get-tmux-location`:
- Read `$TMUX_PANE` directly. If set, return it.
- Fall back to `tmux display-message -t "$TMUX_PANE" -p '#{session_name}:#{window_index}.#{pane_index}'` (still pane-scoped via -t).
- Only as a last resort use `tmux display-message -p ...` without -t (active-pane-fallback).

Probably ~5-10 LoC fix in the relevant subcommand handler.

## Severity

MED — not data-loss but a real friction in scripts that call `c2c get-tmux-location` to discover their own pane (e.g., role-file restart-intro, `scripts/c2c_tmux.py` callers, MCP register-with-tmux-pane). A wrong return silently mis-attributes panes; under load (multiple agents probing simultaneously) this could show up as agent-A's monitor watching agent-B's pane.

## Performance — separate but co-routed

Measured (2026-04-28 12:57Z, idle dev box):
- `c2c get-tmux-location`: **1.3–1.6 seconds**
- `tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}'`: **2 ms**
- `echo "$TMUX_PANE"`: **1 ms**

c2c has 600-800× overhead vs the underlying tmux/env path it presumably wraps. Likely culprits (verify with `OCAMLRUNPARAM=v=0x400 c2c get-tmux-location` or similar):
- Full broker init at startup (registry parse, lock files, mkdir tree)
- Install-stamp ancestry check (#302)
- Auto-register-on-startup probe
- MCP server preflight

Fix shape: short-circuit `c2c get-tmux-location` to read `$TMUX_PANE` (or fall back to `tmux display-message -t "$TMUX_PANE" ...`) BEFORE any broker/registry/install-stamp work. The subcommand has no dependency on broker state — it's a pure env+tmux query.

Target: <50 ms for the common path.

## Coupled fix recommendation

The race-fix and perf-fix share root cause: the implementation is going through a heavy path (likely shared init) instead of a lean env-var read. Fix both in one slice:

1. Add a fast-path in `c2c.ml` dispatch: if subcommand is `get-tmux-location`, branch to a lean handler before any broker setup.
2. The lean handler reads `$TMUX_PANE`, optionally normalizes via `tmux display-message -t "$TMUX_PANE" -p '...'` for the human-readable form.
3. Return.

Total fix: ~15-20 LoC + 1 test. If the broker init is structurally hard to skip, file a broader follow-up to lazy-init the broker only when the subcommand needs it.

## Affected callers (need verification)

- `scripts/c2c_tmux.py` (whoami subcommand)
- `c2c register` — if it uses get-tmux-location for the pane field
- Any MCP tool that captures pane-location at session start
- Role-file `[swarm] restart_intro` if it embeds pane location
