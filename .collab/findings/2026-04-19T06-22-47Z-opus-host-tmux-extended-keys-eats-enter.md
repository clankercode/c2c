---
title: tmux `extended-keys on` + Claude Code TUI eats plain Enter
date: 2026-04-19T06:22:47Z
author: opus-host (opus session)
severity: medium — blocks automated TUI driving (tmux send-keys, pty inject, test harnesses)
---

# Symptom

Driving a Claude Code TUI inside tmux via `tmux send-keys -t <session> Enter`
did not submit the prompt. The text appeared in the input area but stayed
editable; Enter produced a visible artifact like `^[[27;5;109~` in the input
instead of submitting.

Trying all of the following also failed to submit:
- `tmux send-keys ... Enter`
- `tmux send-keys ... C-m`
- `tmux send-keys ... Return`
- `tmux send-keys -l $'\r'`
- `tmux send-keys -l $'\x1b[13u'` (kitty keyboard CSI-u encoding)

Each one landed as a visible byte in the input area rather than a submit.

# Root cause

The user's `~/.tmux.conf` has:

```
set -s extended-keys on
set -as terminal-features 'xterm*:extkeys'
```

With `extended-keys on`, tmux encodes keystrokes (including Enter) using
xterm's `modifyOtherKeys` protocol — `Enter` goes over the wire as the CSI-u
style sequence `^[[27;5;109~` (Ctrl+Shift+M), not a bare `0x0D`.

Claude Code 2.1.114's TUI enables the kitty keyboard protocol on init. It
treats `^[[27;5;109~` as a literal Ctrl+Shift+M key event, not as Enter. The
original "plain Enter = submit" binding therefore never fires.

This matches the config change the user made earlier to make `Shift+Enter`
insert a newline in Claude: extended-keys is exactly what makes that work.
The cost is that `send-keys Enter` from outside now looks like a modified
key to Claude.

# Workaround

Toggle extended-keys off for the single keystroke, then back on:

```bash
tmux set -s extended-keys off
tmux send-keys -t <session> Enter
tmux set -s extended-keys on
```

Verified working — Claude Code submitted and started processing the prompt.

# Implications for c2c tooling

- Any automation that drives a Claude TUI via `tmux send-keys` must disable
  extended-keys for the submit keystroke. Worth baking into a helper.
- PTY-injection paths (`c2c_pty_inject.inject`) write bracketed paste + `\r`
  directly to the master fd, so they bypass tmux entirely — they are
  **not** affected by this. Only `tmux send-keys`-based drivers are.
- Test harnesses that wrap tmux (e.g. `scripts/tui-snapshot.sh`) should
  either toggle extended-keys or use the PTY-inject path instead.

# Fix status

Documented; not yet scripted. A future helper `c2c_tmux_enter.sh` could
wrap the toggle cleanly. Not on the critical path today.
