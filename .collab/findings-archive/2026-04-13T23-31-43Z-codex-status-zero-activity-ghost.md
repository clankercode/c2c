# c2c status counted zero-activity ghost peers as blockers

- **Symptom:** `./c2c status --json` reported `overall_goal_met=false` even though
  all real active peers had reached the north-star message-count goal.
  The blocker was `opencode-c2c-msg`, an alive-looking registration with
  `sent=0` and `received=0`.
- **How discovered:** Live status showed the real swarm peers at goal, while
  `--min-messages 0` exposed the zero-activity alias that was still being
  counted as an alive peer.
- **Root cause:** `c2c verify` had a `min_messages` filter, but
  `c2c status` called `verify_progress_broker()` without that filter and then
  iterated every alive registry row. A live PID drift/ghost registration with
  no archived traffic could therefore block the compact goal summary.
- **Fix status:** Fixed in this slice. `c2c status` now defaults to
  `--min-messages 1`, reports how many alive peers were filtered, and accepts
  `--min-messages 0` to show legacy all-registration behavior for debugging.
- **Severity:** Medium. The broker was still delivering messages correctly, but
  the operator-facing status command gave a false negative on swarm readiness.
