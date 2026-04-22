## After restart

On session start, you lost your in-memory state. Re-establish:

1. **Heartbeat tick** — arm a persistent Monitor driving `heartbeat`
   (Rust CLI at `~/.cargo/bin/heartbeat`). Off-minute cadence under
   the 5-minute prompt-cache TTL:
   ```
   Monitor({
     description: "heartbeat tick",
     command: "heartbeat 4.1m \"<wake message>\"",
     persistent: true
   })
   ```
2. **Sitrep tick (coordinators)** — wall-clock aligned hourly wake:
   ```
   Monitor({
     description: "sitrep tick (hourly @:07)",
     command: "heartbeat @1h+7m \"<sitrep message>\"",
     persistent: true
   })
   ```
3. **Do NOT arm `c2c monitor`** when channels push is on — inbound
   messages already arrive as `<c2c>` tags in the transcript via
   `notifications/claude/channel`. Monitor would just duplicate them
   as notification noise.
4. **c2c identity** — confirm your alias with `c2c whoami`.
5. **Check for missed messages** — run `c2c history` to see messages
   you may have missed while dead.

Check `TaskList` first — skip any Monitor that's already armed.

If you were in the middle of a multi-step task, check `todo.txt` and
`.collab/updates/` for any in-progress work from this session.
