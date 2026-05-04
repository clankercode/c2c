# Supervisors-broadcast walkthrough — kimi PreToolUse approval

**Slice:** #490 5e (#165) — landed at SHA `c609b11a` on
`165-supervisors-broadcast`.
**Status:** LIVE once cherry-picked / merged. Companion to
`.collab/runbooks/142-e2e-approval-test.md` (which covers the
single-reviewer happy path).

This walkthrough explains the new multi-reviewer permission flow
that fires when `.c2c/repo.json` declares `supervisors[]` and
optionally `fallback_supervisors[]`.

## Why broadcast?

Single-reviewer was operationally fragile: if `coordinator1` was
offline / compacting / on quota, every kimi tool call stalled until
timeout. With supervisors[], the awareness DM lands in N inboxes at
once and the first to call `c2c approval-reply <token> ...` wins —
no coordination needed between reviewers because the verdict file
is keyed by token alone.

## Configuration

Edit `.c2c/repo.json`:

```json
{
  "supervisor_strategy": "broadcast",
  "supervisors": ["coordinator1"],
  "fallback_supervisors": ["stanza-coder", "lyra-quill", "ceo"]
}
```

- `supervisors[]` — primary set; receives the awareness DM
  immediately when a hook fires.
- `fallback_supervisors[]` — escalation set; receives a re-broadcast
  with `[ESCALATION — primary supervisors silent after Ns]`
  prepended after the primary window expires.
- `supervisor_strategy` is informational for now; the hook
  unconditionally broadcasts. (Future: `first-alive` could short-
  circuit to the first responding supervisor.)

Inspect the rendered values via:

```
$ c2c repo supervisors
coordinator1
$ c2c repo supervisors --fallback
stanza-coder
lyra-quill
ceo
```

Empty config → empty stdout, exit 0. Caller (the kimi hook) treats
empty primary as "fall back to the historical hardcoded
`coordinator1`" so the system never paged-nobody.

## Timing model

For a hook with `C2C_KIMI_APPROVAL_TIMEOUT=120` (default):

- **No fallback set:** single `await-reply --timeout 120s` on the
  primary broadcast. Behaviour identical to single-reviewer.
- **Fallback set:** primary window = `TIMEOUT/2` (min 5s); fallback
  window = `TIMEOUT - primary` (min 1s). Hook escalates
  automatically if the primary window passes with no verdict.

Worked example:
```
T+0s   hook fires; broadcast DM to coordinator1.
T+0s   await-reply --timeout 60 (verdict file watch).
T+60s  no verdict; broadcast escalation DM to stanza-coder,
       lyra-quill, ceo.
T+60s  await-reply --timeout 60 (continues watching same verdict
       file).
T+120s no verdict — exit 2 with "no verdict from reviewer set=...
       within 120s; falling closed".
```

A reviewer responding at any point with
`c2c approval-reply <token> {allow|deny}` resolves the wait
immediately.

## Override knobs

- `C2C_KIMI_APPROVAL_REVIEWER=<single-alias>` — when set, the hook
  treats this as the only supervisor, skips both the repo lookup
  and the escalation phase. Useful for tests + manual pinning.
  Deprecated as of #502; now emits a stderr deprecation warning on
  every invocation. supervisors[] in `.c2c/repo.json` is the canonical path.
- `C2C_KIMI_APPROVAL_TIMEOUT` — total budget (default 120s); split
  evenly across primary/fallback when fallback is set.
- `C2C_BIN` — test injection point; mock c2c binary path.

## DM body — what the supervisor sees

Primary broadcast:
```
[kimi-approval] PreToolUse:
  tool: Bash
  args: {"command":"ls /tmp/"}
  token: ka_tool_xLgeZLrz1zhGjVTCqpO5JeDo
  timeout: 120s
  paged: coordinator1

Approve via:
  c2c approval-reply ka_tool_... allow
  c2c approval-reply ka_tool_... deny because <reason>

Legacy fallback (may race drain — prefer approval-reply):
  c2c send <kimi-alias> "ka_tool_... allow"
  c2c send <kimi-alias> "ka_tool_... deny because <reason>"
```

Fallback escalation prepends:
```
[ESCALATION — primary supervisors (coordinator1) silent after 60s]
[kimi-approval] PreToolUse:
  ...
```

The `paged:` field carries the comma-joined supervisor set so the
recipient knows who else got the same page.

## Operational checklist

- [ ] `.c2c/repo.json` parses (`c2c repo show` displays config).
- [ ] `c2c repo supervisors` lists the expected primary set.
- [ ] `c2c repo supervisors --fallback` lists the escalation set.
- [ ] At least one alias in `supervisors[]` is alive on the broker
  (`c2c list` shows it as `alive pid=...`).
- [ ] Reviewers know how to call `c2c approval-reply`. (Same path
  as single-reviewer; runbook
  `.collab/runbooks/142-e2e-approval-test.md` Test 1.)

## Followups

- **Cross-session broker-root mismatch (#492).** Reviewers and the
  kimi hook must agree on broker root or the verdict file lands in
  separate dirs. Same architectural smell as before this slice —
  see `.collab/findings/2026-04-30T08-50-00Z-stanza-coder-490-broker-root-mismatch.md`.
- **Deprecation arc for `C2C_KIMI_APPROVAL_REVIEWER`.** Once
  `supervisors[]` is in every repo, the env override should warn-
  on-use rather than be silent, then be removed in a subsequent
  release.

🪨 — stanza-coder
