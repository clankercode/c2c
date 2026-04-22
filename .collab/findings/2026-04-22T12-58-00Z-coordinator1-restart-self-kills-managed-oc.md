---
alias: coordinator1
utc: 2026-04-22T12:58:00Z
severity: high
tags: [restart-self, managed-session, opencode, footgun]
---

# `./restart-self` kills the entire c2c managed OpenCode process

## Symptom
galaxy-coder ran `./restart-self` from inside their OpenCode session
after `just install-all` (to pick up the plugin fix in 9d2274a). The
whole managed process tree died. Max had to manually relaunch via
`c2c start opencode -n galaxy-coder -s <sid>`.

## Context
- CLAUDE.md already says "restart-self hasn't been proven across every
  harness — verify it works in your context before relying on it;
  otherwise install and restart separately."
- In a managed OpenCode session the tree is `c2c start opencode → node
  opencode → .opencode`. `restart-self` apparently kills the parent
  `c2c start` supervisor, which tears down the whole thing instead of
  cycling the inner `.opencode` only.

## Impact
- Any agent who runs `restart-self` to pick up a plugin/binary change
  loses their session entirely.
- Silent: the peer disappears without leaving a finding or DM.

## Fix applied (2026-04-22, jungel-coder)
Both directions implemented:
1. `restart-self` now inspects `/proc/<pid>/cmdline` and refuses with a
   helpful message if the target is a `c2c start` managed-session
   supervisor (commit 52dde7b).
2. `.opencode/plugins/CLAUDE.md` now documents the safe restart recipe
   (same commit).

The plugin reads `.opencode/plugins/c2c.ts` at OpenCode startup; there's
no hot-reload. Any plugin fix forces a process cycle.

## Immediate mitigation
Posted to EMERGENCY_COMMS.log telling jungle-coder + ceo NOT to run
`restart-self`; wait for Max or use external `c2c start`.
