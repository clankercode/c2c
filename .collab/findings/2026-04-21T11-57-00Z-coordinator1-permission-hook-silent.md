---
ts: 2026-04-21T11:57:00+10:00
author: coordinator1
severity: medium
status: open
---

# OpenCode permission.ask hook silent for config-declared `permission.bash: "ask"`

## Symptom

Set `"permission": {"bash": "ask"}` in `.opencode/opencode.json`. Asked
oc-coder1 to run `echo perm-test-$(date +%s)`. The TUI correctly shows
`△ Permission required` dialog. But the plugin's `permission.ask` hook
(and `permission.asked` event handler) does NOT fire — no DM to
coordinator1, no entry in `.opencode/c2c-debug.log`.

## Evidence

- Dialog visible in oc-coder1 pane 5 (tmux capture).
- Plugin IS loaded on pid 1682193 (same pid delivered coder2-expert's
  lounge message at 01:55:42 via `deliverMessages`).
- No `permission` log entries in `.opencode/c2c-debug.log` after the
  dialog popped (checked 01:54 → 01:57 UTC).
- Earlier today at 01:12:58 UTC pid 1682193 successfully DMed
  coordinator1+planner1 for a permission request (see
  `c2c-debug.log.1:508-509`). So the code path works end-to-end — just
  not firing this time.

## Hypothesis

OpenCode may not emit `permission.asked` / call `permission.ask` hook
when the ask is config-declared (via `permission.bash: "ask"` in
opencode.json) vs when a tool itself defaults to ask at runtime. The
01:12 success was on a runtime-ask path; this test was config-ask.

Alternative: `permission.asked` event payload shape differs between
cases and our handler filters it out silently.

## Next step

- coder2-expert to instrument the `event` handler with a log-every-event
  trace and reproduce.
- Or test with a runtime-ask tool (edit/write on a protected path) to
  confirm the divergence.

## Impact

Blocks the "supervisor DM on permission ask" flow for the common case
where operators enforce bash:ask via project config. Permission
dialogs still work in the TUI (operator can click Allow), so not a
hard block — just loses the c2c async-approval UX.
