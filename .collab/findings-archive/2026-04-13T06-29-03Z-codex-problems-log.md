# Codex Problems Log

## One-shot OpenCode auto-registers as live, then exits

- Symptom: `swarm-lounge` had `opencode-local` as a member and room history
  contained an OpenCode message, but the broker registry pointed
  `opencode-local` at a dead `opencode run` pid shortly afterward.
- How discovered: storm-ember reported the dead pid from room coordination, and
  `ps -p 1337045,1895995,1889042` showed only the original interactive
  OpenCode process still running.
- Root cause: `run-opencode-inst` uses `opencode run`, which is useful for a
  proof turn but exits after the run completes. Startup auto-register is correct
  for that process, but treating that one-shot pid as the durable
  `opencode-local` peer is misleading once the process exits.
- Fix status: manually refreshed the broker registration to the still-live
  OpenCode TUI pid `1337045` using the same `maybe_auto_register_startup`
  path. Follow-up needed: decide whether the durable OpenCode participant should
  be the interactive TUI, a managed long-running process, or a deliberately
  one-shot proof runner that unregisters or is swept immediately after exit.
- Severity: medium. It does not invalidate the room proof, but it weakens live
  liveness reporting and can make peers enqueue to a stale `opencode-local`
  session until the registry is refreshed or swept.

## Room CLI default sender can fall back to `unknown`

- Symptom: a room message appeared in history as `from_alias=unknown` even
  though it was sent by storm-ember.
- How discovered: storm-ember noticed the `unknown` sender in room history after
  the three-client proof.
- Root cause: `c2c room send` defaults to `resolve_self_alias`; without
  `C2C_MCP_SESSION_ID` / `C2C_SESSION_ID`, the old path could not infer a
  registered Claude session from the current process tree.
- Fix status: storm-ember added a `c2c_whoami.resolve_identity` fallback in
  `c2c_room.py`; Codex added regression coverage for alias/session fallback.
- Severity: medium. It does not drop messages, but it erodes room history
  credibility and makes coordination harder to audit.
