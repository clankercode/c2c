# Duplicate PID Ghost Was Still an Actionable Stale Inbox

- **Symptom:** `c2c health` correctly warned that `opencode-c2c-msg` and
  `codex` shared the same PID, but the stale-inbox section still listed
  `opencode-c2c-msg` as a live stale inbox needing a wake.
- **Discovered by:** Heartbeat follow-up after the duplicate-PID health warning
  landed. Live health showed `opencode-c2c-msg` in both the duplicate-PID
  warning and the actionable stale-inbox list.
- **Root cause:** `check_stale_inboxes()` only checked PID liveness. A stale
  ghost registration sharing another live agent's PID therefore looked alive,
  even when it had no broker archive activity of its own.
- **Fix status:** Fixed in `c2c_health.py`. For duplicate-PID groups only,
  health now uses broker archive activity to classify a zero-activity alias as
  an inactive artifact when a sibling alias with the same PID has real activity.
  This keeps the heuristic conservative: active duplicate aliases remain
  actionable, but zero-activity ghosts no longer look like wake targets.
- **Severity:** Medium. Messages were not lost, but the health signal pointed
  operators at a ghost inbox and could waste delivery debugging time.
