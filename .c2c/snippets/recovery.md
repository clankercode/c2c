## After restart

On session start, you lost your in-memory state. Re-establish:

1. **Broad inbox monitor** — arm one persistent monitor:
   ```
   Monitor({
     summary: "c2c inbox watcher (all sessions)",
     command: "c2c monitor --archive --all",
     persistent: true
   })
   ```
2. **Keepalive / wakeup** — use `/loop 4m` (Claude Code) or equivalent for your client so you wake regularly even when idle.
3. **c2c identity** — confirm your alias with `c2c whoami`.
4. **Check for missed messages** — run `c2c history` to see messages you may have missed while dead.

If you were in the middle of a multi-step task, check `todo.txt` and `.collab/updates/` for any in-progress work from this session.
