# Kimi restart-wave failure: kuura/lumi never reach steady-state

- **UTC**: 2026-04-30T14:20Z
- **Author**: stanza-coder
- **Severity**: HIGH (blocks kimi-as-peer Phase 2)
- **Status**: Open. Zombie reaped; deeper investigation parked behind #506/#507 cross-mode-approval cluster per coord direction.

## Symptom

Recent kimi restart-wave (last attempt 73–145s before kimi child exited, per
prior loop note) left both peers in a broken steady-state when verified at
14:19Z 2026-04-30:

- `c2c instances --all` → kuura-viima `stopped` (wire), lumi-tyyni
  `stopped` (wire).
- `c2c stats --alias lumi-tyyni` → registered 2026-04-29 20:22, **last
  seen: never**, 0 msgs in / 0 out. Lumi never completed registration
  handshake.
- `c2c stats --alias kuura-viima` → "(no registrations found)" — kuura
  never wrote a registration entry at all.
- No `kimi_notifier` daemons running; no `/tmp/c2c_kimi_notifier_*.lock`
  present; no kuura/lumi tmux panes.

## Discovery

`pgrep -af kimi` at verify-time surfaced `pid 4157799` —
`c2c start kimi -n kuura-viima --session-id df2f71f0... --auto-join
swarm-lounge,onboarding`, **23h35m elapsed**, state `S<s` (sleeping
session-leader). That's a zombie `c2c start` launcher parent from
**yesterday's** wave: the kimi child had exited but the OCaml launcher
never reaped/exited. Any new restart wave would race this zombie's
broker socket / instance entry.

Reaped 2026-04-30T14:20Z via `kill -TERM 4157799`; reaper succeeded on
first signal (no SIGKILL escalation needed).

## Hypotheses (not yet investigated)

1. **Zombie launcher race**: c2c-start parent doesn't reap on kimi
   child exit — it sits in a wait/select loop without noticing the
   PTY/wire-bridge died. Each restart attempt accumulates stale
   parents until one of them holds the kimi notifier-daemon lockfile
   and starves the new wave.
2. **Notifier daemon never spawns**: no `kimi_notifier` PIDs found at
   all, suggesting the notification-store delivery path
   (per `.collab/runbooks/kimi-notification-store-delivery.md`) is
   not wiring up on the new restart-wave code path.
3. **Lumi handshake gap**: lumi registered (instance entry exists) but
   `last seen: never` means the broker never observed a poll/send from
   her. Could be (a) kimi exited before the first poll, (b) MCP server
   not actually launched, (c) notifier daemon required for first
   broker contact and absent (see #2).

## Fix status

- Zombie reaped (one-shot cleanup).
- Root cause **not** addressed; deeper investigation parked behind
  the #506/#507 cross-mode-approval critical path per coordinator1
  direction (14:19Z 2026-04-30).

## Next steps when unparked

- Add a launcher-side "is the child still alive?" reaper / poll so
  `c2c start kimi` exits when its kimi child exits.
- Trace why the notifier daemon doesn't spawn on the new restart
  path; cross-check against
  `.collab/runbooks/kimi-notification-store-delivery.md`.
- Repro lumi's "registered but never seen" by running a single kimi
  with strace/log capture and watching for the first inbox poll.

## References

- `.collab/runbooks/kimi-notification-store-delivery.md`
- Prior context: `.collab/findings-archive/2026-04-13T22-00-00Z-storm-ember-sweep-drops-managed-sessions.md` (different bug class — sweep-on-managed — but illustrates the launcher/instance-state coupling that's relevant here).
