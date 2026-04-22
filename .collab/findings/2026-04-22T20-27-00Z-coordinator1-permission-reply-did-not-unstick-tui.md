---
date: 2026-04-22T20:27:00Z (AEST; ~10:27 UTC)
alias: coordinator1
severity: high
status: open
tags: [permission, opencode-plugin, tui, m3-security]
---

# Permission reply did not unstick OpenCode TUI

## Symptom

galaxy-coder sent a PERMISSION REQUEST (`per_db4b50d18001N0JMi2PokX47u2`,
action `external_directory: /home/xertrov/.claude/*`) to coordinator1 + ceo
at 20:21:06 local. coordinator1 replied
`permission:per_db4b50d18001N0JMi2PokX47u2:approve-always` at 20:21:06.

After the reply:
- galaxy-coder's OpenCode TUI remained frozen on the "Permission required"
  prompt for ~5+ minutes.
- No inbound delivery surfaced in the pane; the promise waiting on the
  reply never resolved.
- Max had to flag it ("galaxy-coder is still stuck on a permissions thing").
- coordinator1 unstuck it manually by `scripts/c2c_tmux.py keys galaxy-coder 1 enter` (twice) to pick the TUI's "Allow always" button directly.

## Context

- The M3 mitigation (plugin-side supervisor-list verification) landed
  twice today: `15713e9` was architecturally flawed (stored requester
  alias, rejected legitimate supervisor replies), reverted in
  `3f2d852`, correctly re-landed in `6e4c671` (stores supervisors list,
  accepts any reply whose `from_alias ∈ supervisors`).
- galaxy-coder's OpenCode session was launched **before** `6e4c671`
  landed, so the running plugin is likely the broken `15713e9` code
  (or the reverted pre-ceo code, depending on exact launch timing).
- OpenCode loads `.opencode/plugins/c2c.ts` at process start; there is
  no hot-reload without restart.

## Root cause (hypothesis)

galaxy-coder's running plugin has the broken M3 logic: it stored the
requester's alias (`galaxy-coder`) as the "expected sender" and
rejected any reply from a different alias. coordinator1's reply came
from alias `coordinator1` → rejected → promise never resolves → TUI
frozen indefinitely.

**To confirm**: check the file mtime of `.opencode/plugins/c2c.ts` in
galaxy-coder's process cwd vs the session start time. Or: grep the
pane logs for a rejection message from the plugin.

## Impact

- Any peer whose OpenCode plugin was loaded during the ~10min window
  between `15713e9` and `3f2d852`/`6e4c671` will silently reject all
  permission replies until restart.
- Failure is silent (no error surfaced to the TUI or the supervisor);
  only manual peek uncovers it.
- Same class of bug will re-occur whenever a plugin version is stale
  relative to the broker protocol.

## Mitigations

1. **Plugin version probe**: add a `plugin_version` field to the
   registration, visible via `mcp__c2c__list`. Coordinator / ceo can
   see peers running stale plugins.
2. **TUI timeout surfacing**: permission prompts should show a
   countdown and auto-reject at the TTL so peers don't sit frozen
   indefinitely when replies never arrive.
3. **Reply rejection logging**: when the plugin drops a reply (e.g.
   alias mismatch), log to `~/.local/share/c2c/plugin.log` so
   post-mortem doesn't require pane peeking.
4. **Stale-plugin warning on broker RPC**: once M2 lands, the broker
   can detect that a plugin is not calling `open_permission_request`
   and warn on `poll_inbox` — this surfaces stale plugins as the
   broker protocol evolves.
5. **Operator escape hatch**: document the `scripts/c2c_tmux.py keys
   <alias> enter` approach as the stuck-TUI recovery recipe, and note
   that restarting the peer's session picks up the new plugin.

## Next step

galaxy-coder should restart their OpenCode session (or `./restart-self`
if the harness supports it) to pick up the `6e4c671` plugin. Then
retest the PreCompact hook work from a clean plugin state.

Related design doc: `.collab/design/broker-pending-permissions.md` —
M2/M4 broker-level permission tracking would also shift responsibility
off the plugin and close this class of failure.
