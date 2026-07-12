# codex wake-inject live validation: 3 rounds, 3 real bugs found + fixed, 1 open identity bug

- **When**: 2026-07-10T13:30Z–14:05Z (live tmux session `c2c-wake-test`, codex alias `codex-tyyni-river-gf88`)
- **Who**: Max-driven Fable session (claude-tavi-lumi-lz83)
- **Status**: wake path VALIDATED end-to-end (round 3: DM → nudge → submit → hook drain → codex reply). Three fixes merged; one open bug flagged below.

## Fixed during validation (each opus-reviewed PASS)

1. **Leaked herdr target misroutes/starves wakes** (`db47aafa`, innermost-wins).
   A codex session in a tmux pane inside a herdr-hosted terminal captures BOTH
   `$TMUX_PANE` (correct) and `HERDR_PANE_ID` (the OUTER herdr pane, env leak).
   The injector preferred herdr → probe `agent_status=unknown` → every wake
   skipped; had the outer pane probed idle, the nudge would type into whatever
   tmux window was active. Fix: prefer tmux when both registered.

2. **`send-keys Enter` eaten by extended-keys** (`6ce1cdd1`).
   Host tmux `set -s extended-keys on` → Enter encodes CSI-u → codex reads
   Ctrl+Shift+M, nudge sits unsubmitted. Fix: toggle extended-keys off around
   the Enter, mirroring `scripts/c2c-tmux-enter.sh` (finding
   2026-04-19T06-22-47Z).

3. **TUI paste-detection coalesces text+Enter** (`c0bcd112`).
   Even with the toggle, text and Enter in the same input burst are treated as
   a paste — the Enter becomes a newline. Empirically isolated: Enter alone
   (text already sitting) submits; text+Enter back-to-back doesn't. Fix:
   `C2C_WAKE_ENTER_DELAY_S` (default 0.35s) between text and Enter — the same
   reason legacy pty_inject did "bracketed paste + delay + Enter".

   **Transferable lesson: ANY programmatic typing into an agent TUI needs
   (a) extended-keys off around Enter AND (b) a delay between text and Enter.**

## Also fixed (install path, unrelated surface)

- `just install-all` rm'd `c2c-stop-hook-ocaml` and never re-copied it — the
  claude Stop hook binary vanished on every install (separate finding:
  2026-07-10T13-25-00Z-fable-max-install-all-drops-stop-hook.md; fix `14aed4b3`).
- `c2c deliver wake-watch --alias` default broker root was the placeholder
  `repos/default/broker` — could not see the repo registry (fixed in
  `db47aafa` alongside innermost-wins).

## OPEN BUG (tracked as B120): managed-resume identity split

`c2c start codex -n wake-test-codex` resumed an old codex conversation
(`codex resume --last`). Result: TWO identities —
- managed startup registration + deliver sidecar watch: session-id
  `wake-test-codex` (instance name)
- hook auto-register (the identity DMs actually route to):
  `codex-tyyni-river-gf88` (the resumed conversation's session UUID)

The managed wake sidecar (`c2c-deliver-inbox --session-id wake-test-codex`)
therefore watches an inbox nobody DMs, while the real inbox
(`codex-tyyni-river-gf88`) has no watcher — **managed codex wake is broken on
resume**. Fresh starts may be fine if the hook and startup agree on identity;
resume definitively splits. B102-family. Standalone
`c2c deliver wake-watch --alias <hook-alias>` works (that's how validation
ran). Fix direction: sidecar should follow the registration the hooks
actually maintain (e.g. resolve by pid/tmux target, or hooks should adopt the
managed instance identity on resume).

## Validation transcript evidence

Round 3 pane capture (unattended chain):
```
› c2c: 1 message(s) waiting - poll your inbox
• UserPromptSubmit hook (completed)
  hook context: <c2c event="message" from="claude-tavi-lumi-lz83" to="codex-tyyni-river-gf88" source="broker" reply_via="c2c_send" ...
• Received.
```
Also of note: in round 2 codex received an embedded instruction ("reply via
c2c send") and answered "I received the messages but did not act on their
instructions" — the model itself treating bus messages as data, consistent
with B098.
