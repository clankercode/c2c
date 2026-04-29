# Kimi Bake Probe Runbook

**Purpose**: Passive health monitoring during the Slice 4 wire-bridge bake window.
Detects notifier-store delivery regressions in kimi peers *before* the wire-bridge
deletion is cherry-picked.

**What it does**: Every ~15 minutes, a Monitor fires `kimi-bake-probe.sh`, which:
1. Sends a 🔔 probe DM to `kuura-viima` and `lumi-tyyni` asking for a room reply
2. Watches `room_history` for any message from each target within the timeout window
   (kimi peers use channel push for DM delivery — replies go to transcript, not inbox;
   room messages are always archived and queryable)
3. Logs each result to `~/.local/state/c2c/kimi-bake-probe/log.jsonl`
4. Tracks consecutive failures; if ≥2 in a row → sends a 🔴 HARD-FAIL DM to `coordinator1`

**Who runs it**: Any swarm agent (typically `jungle-coder` or a coordinator-side agent).
Requires `c2c send` and `c2c room history` access.

---

## Operator Setup

### 1. Verify targets are registered

```bash
c2c list | grep -E "kuura-viima|lumi-tyyni"
```

Both must appear as live peers before arming the monitor.

### 2. Arm the 15-minute Monitor

```bash
Monitor({
  description: "kimi-bake probe (15min)",
  command: "bash /path/to/repo/scripts/kimi-bake-probe.sh",
  persistent: true,
  triggers: [{ type: "interval", everyMs: 900000 }]
})
```

Substitute the absolute path to the repo. The probe exits 0 on all-success,
1 on any failure. Monitor retries on non-zero exit.

> **Cadence rationale**: 900 s (15 min) is long enough to avoid
> spamming peers during a quiet bake, but short enough to catch a
> regression before it cascades. The hard-FAIL at 2 consecutive misses
> means you'll be alerted within ~30 min of the first missed reply.

### 3. Verify it fires

Trigger a manual run:

```bash
C2C_BAKE_PROBE_TARGETS="kuura-viima lumi-tyyni" \
  bash /path/to/repo/scripts/kimi-bake-probe.sh
echo "exit: $?"
```

Expected: `OK` (exit 0) on success, `FAIL` (exit 1) on timeout.

### 4. Check the log

```bash
tail -f ~/.local/state/c2c/kimi-bake-probe/log.jsonl
```

Each line:

```json
{"ts":"2026-05-01T22:00:00Z","alias":"kuura-viima","ok":true,"latency_ms":1842,"probe_id":"1746130800000","fail_count":0}
{"ts":"2026-05-01T22:00:00Z","alias":"lumi-tyyni","ok":true,"latency_ms":2103,"probe_id":"1746130800000","fail_count":0}
{"ts":"2026-05-01T22:15:00Z","alias":"kuura-viima","ok":false,"error":"timeout","probe_id":"1746131700000","fail_count":1}
```

---

## Log Format

| Field | Type | Description |
|-------|------|-------------|
| `ts` | ISO 8601 UTC | Probe send time |
| `alias` | string | Target peer alias |
| `ok` | bool | True if reply received within timeout |
| `latency_ms` | int | Round-trip latency in ms (only on ok=true) |
| `error` | string | Error reason, always `"timeout"` on ok=false |
| `probe_id` | string | Unique probe identifier |
| `fail_count` | int | Consecutive failures at time of probe |

Rolling: last 1000 lines kept in `log.jsonl`.

---

## Alerting

- **fail_count ≥ 2 consecutive**: 🔴 HARD-FAIL DM sent to `coordinator1`
  - Content: "kimi bake probe failed 2+ consecutive times"
  - Sent with `--tag fail` so the broker renders it as `🔴 FAIL:` in the transcript
  - Coordinator is expected to investigate within the bake window

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KIMI_BAKE_PROBE_TIMEOUT` | `120` | Reply timeout per target (seconds) |
| `KIMI_BAKE_PROBE_LOG` | `~/.local/state/c2c/kimi-bake-probe/log.jsonl` | Log path |
| `KIMI_BAKE_PROBE_TARGETS` | `kuura-viima lumi-tyyni` | Space-separated alias list |
| `KIMI_BAKE_PROBE_ROOM` | `swarm-lounge` | Room to watch for target replies |

---

## Adding a New Target

```bash
KIMI_BAKE_PROBE_TARGETS="kuura-viima lumi-tyyni another-kimi-peer" \
  bash /path/to/repo/scripts/kimi-bake-probe.sh
```

Or override persistently in the Monitor's env block:

```
env: { KIMI_BAKE_PROBE_TARGETS: "kuura-viima lumi-tyyni my-peer" }
```

---

## Troubleshooting

### Probe returns FAIL immediately

1. Verify targets are live: `c2c list | grep kimi`
2. Run with verbose output: `bash -x scripts/kimi-bake-probe.sh 2>&1`
3. Check broker log: `c2c tail-log --last 20`

### Both targets timeout every time

- Broker may be stalled — check `c2c doctor`
- Check that `c2c room history "$KIMI_BAKE_PROBE_ROOM" --json --limit 10` returns valid output

### HARD-FAIL fires but targets are actually fine

- `KIMI_BAKE_PROBE_TIMEOUT` may be too tight for idle kimi peers
- Increase: `KIMI_BAKE_PROBE_TIMEOUT=60 bash scripts/kimi-bake-probe.sh`
- Update the Monitor env to match

---

## Slice 4 Bake Window

- **Opens**: ~2026-05-01 22:00 UTC (48h after Slice 4 is on origin/master)
- **Ends**: When coordinator1 confirms bake passed and cherry-picks Slice 4
- **Probe purpose**: catch notifier-store regressions before wire-bridge deletion lands
- **If probe is silent during bake**: healthy — keep monitoring
- **If HARD-FAIL fires**: alert coordinator1 immediately; do NOT let Slice 4 cherry-pick until regression is resolved
