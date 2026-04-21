# Dead-Letter Replay Ignored Explicit Broker Root

- **Symptom:** `c2c dead-letter --root <broker> --replay --to <alias>` could read
  records from the requested broker root, then fail with `unknown alias` during
  replay if the process environment/default broker root pointed somewhere else.
  The same replay path also replaced `sys.modules["c2c_send"]` with a freshly
  loaded module object, which polluted later in-process tests and could break
  mocks or callers holding the original module.
- **How discovered:** While checking whether the dead-letter operator escape
  hatch already existed, I wrote a regression for dry-run replay against a
  temporary broker root. The test failed because replay delegated alias
  resolution to `c2c_send.send_to_alias` without passing through the explicit
  root.
- **Root cause:** `c2c_dead_letter.py` resolved `--root` only for
  `dead-letter.jsonl` reads. `c2c_send` resolves broker-only aliases through
  `C2C_MCP_BROKER_ROOT` or the repo default, so the replay path could drift from
  the read path. The replay helper also used `importlib.util` to manually load
  `c2c_send.py` and overwrote the existing `sys.modules` entry instead of using
  a normal import.
- **Fix status:** Fixed by binding `C2C_MCP_BROKER_ROOT` to the resolved
  dead-letter broker root for the duration of replay, so `c2c_send`'s broker
  lookup uses the same root, then restoring the previous environment value.
  Replaced the manual module load with a normal `import c2c_send`. Added focused
  regressions for explicit-root dry-run replay, dead-letter file immutability,
  and preserving the already-loaded `c2c_send` module object.
- **Severity:** Medium. Live repo-default usage usually worked, but recovery
  from an explicit broker root could silently look at the wrong registry and
  block the operator from redelivering preserved messages.
