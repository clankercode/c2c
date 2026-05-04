# Finding: #562 dogfood — dm_enqueue field name wrong in runbook

**Severity**: LOW (docs-only, no code impact)
**Status**: Fixed, committed to `slice/562-daemon-log-persistence` as `f7a7576a`

## What was found

During dogfood walkthrough of `deliver-inbox-log-forensics.md` against live broker state:

- **Wrong field**: worked example used `msg_ts` as the timestamp field in `dm_enqueue`
- **Actual field**: `dm_enqueue` uses `ts` (Unix epoch float, same field used in `deliver_inbox_drain`)
- **Impact**: The jq filter `select(.msg_ts > X and .msg_ts < Y)` silently returns no results instead of matching events — an investigator following the runbook blindly would see empty output

## Verification steps that surfaced it

1. Built + installed `c2c-deliver-inbox` from `2aeff749`
2. Ran single-shot drain for `test-agent-oc` — produced valid `deliver_inbox_drain` entries
3. Ran kimi single-shot — produced valid `deliver_inbox_kimi` entries
4. Checked `dm_enqueue` in `broker.log` — found it uses `ts`, not `msg_ts`
5. Fixed runbook jq examples and example output

## What worked correctly

- `deliver_inbox.log` created at correct path: `<broker_root>/deliver-inbox.log`
- Permissions correct: `-rw-------` (0o600)
- JSONL format correct: `{"ts":...,"event":"deliver_inbox_drain",...}`
- `drained_by_pid=0` correctly set for single-shot invocation
- `deliver_inbox_kimi` event correctly emitted with `ok:true`
- All jq examples in runbook work against real data

## Fix committed

`s7a7576a` on `slice/562-daemon-log-persistence`:
- Changed `.msg_ts` → `.ts` in jq filter
- Updated example output line to show actual `dm_enqueue` field shape
- Added clarifying note that both sides of correlation use the same `ts` field
