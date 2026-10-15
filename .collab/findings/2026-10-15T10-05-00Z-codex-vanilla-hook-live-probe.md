# B366 live vanilla Codex attach limitation

- **Observed:** With codex-cli 0.162.1, a normal plain `codex` TUI in tmux registers through `c2c hook codex`. The authenticated machine-wide daemon can `thread/read` the exact hook `session_id`, including the correct workspace and persisted rollout, but reports `status.type=notLoaded` and omits that id from `thread/loaded/list`.
- **Probes:** `thread/resume` on the exact id returns an active-writer error. `thread/inject_items` returns `thread not found`. The TUI remains live and owns its embedded in-process app-server.
- **Root cause:** Codex's public app-server protocol has no cross-process attach, shared-writer, or handoff method. `thread/read` is persisted metadata access; it does not establish a live delivery owner. `thread/resume` is a cold load that would contend with the vanilla writer.
- **Safety decision:** c2c must keep requiring exact loaded-thread proof. It must not force resume, remove writer locks, choose another same-workspace thread, or claim arrival-time health from persisted readiness. B098 and B138 require this fail-closed behavior.
- **User impact:** `c2c codex adopt ALIAS` refuses with an actionable explanation and leaves hook-boundary delivery active. Use `c2c start codex` / `c2c new codex` for arrival-time daemon delivery, or use hook/monitor/poll fallback for the already-running vanilla frontend.
- **Status:** B366 closes the documentation/diagnostic gap. Re-open when Codex exposes a sanctioned authenticated attach/handoff protocol.
