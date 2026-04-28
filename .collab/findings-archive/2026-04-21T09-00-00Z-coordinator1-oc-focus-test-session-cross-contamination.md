---
reporter: coordinator1
ts_utc: 2026-04-21T09:00:00Z
severity: high
area: opencode-plugin
status: fixed — 7b063ac (bootstrap skip) + b3b2b1a (conflict preflight) + 7669ec4 (regression tests)
---

# oc-focus-test and oc-sitrep-demo report the same root_opencode_session_id

## Symptom

Max stopped oc-focus-test (launched by fresh-oc to E2E-validate the #58
TUI focus fix) because "couldn't load a session through it".

On inspection, both independent opencode instances have the **same**
`root_opencode_session_id` recorded in their plugin state:

- `~/.local/share/c2c/instances/oc-sitrep-demo/oc-plugin-state.json` →
  `ses_251dfab4afferFS3ZJ6blZlHo8`, opencode_pid=1855259
- `~/.local/share/c2c/instances/oc-focus-test/oc-plugin-state.json` →
  `ses_251dfab4afferFS3ZJ6blZlHo8`, opencode_pid=2017494

Two different opencode PIDs, two different c2c_session_ids / aliases,
two separate instance dirs — but the plugin in each reports the same
root session. That's wrong; each `--auto` kickoff should produce a
distinct `session.create()` result.

## Where discovered

Coordinator swarm status check after Max reported the manual E2E run
failed to load a session.

## Suspected cause (unverified)

OpenCode persists sessions under `~/.local/share/opencode/` app-wide.
If the c2c.ts server plugin's `session.create()` path races, errors
silently, or the plugin reads an existing last-session from shared
storage before creating its own, two concurrent opencode instances
on the same host could both end up referencing a prior session that
opencode itself considers "root".

Alternatively, the plugin state file is written atomically per
instance dir (that part looks correct), but the *value* it writes is
the same because opencode's internal session bookkeeping hands both
instances the same ID.

Needs: read c2c.ts kickoff path (lines ~1078-1107 per prior notes),
trace how `root_opencode_session_id` gets assigned, confirm whether
`session.create()` actually returns a unique ID per instance.

## Impact

- #58 TUI focus fix cannot be validated while two instances share a
  session ID; `route.navigate("session", { sessionID })` on the
  second instance points at a session owned by the first.
- Any multi-opencode swarm work (e.g. dual-opencode tests) is
  suspect until this is resolved.

## Next actions

1. fresh-oc (or whoever picks up): repro with two fresh `c2c start
   opencode --auto -n X` in parallel, dump plugin-state.json from
   both, confirm whether the collision is deterministic.
2. Trace `.opencode/plugins/c2c.ts` kickoff: does it call
   `session.create()` unconditionally, or does it read an existing
   session first?
3. If the cause is opencode app-wide session persistence, the
   `--auto` path may need to force a new session per instance
   (or set a unique session workspace dir via env).
