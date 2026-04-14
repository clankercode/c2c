# Kimi Session Capture Dirties Tracked Config

- **Symptom:** `run-kimi-inst.d/kimi-nova.json` was dirty after routine Kimi
  restarts, with only `kimi_session_id` changing.
- **How discovered:** Post-commit `git status --short` showed a persistent
  tracked change to the live Kimi instance config.
- **Root cause:** `run-kimi-inst-outer` captured Kimi's latest interactive
  session id and wrote it back into `<name>.json`, but the live instance config
  files are tracked. Runtime session state therefore looked like source changes.
- **Fix status:** Fixed by writing captured session ids to ignored
  `run-kimi-inst.d/<name>.session.json` sidecar files. `run-kimi-inst` now
  reads that sidecar as a fallback when `kimi_session_id` is absent from the
  config. The live legacy `run-kimi-inst-outer kimi-nova` process that was
  still running old code and rewriting the tracked config was stopped after
  confirming `kimi-nova-2` remained alive through the Wire daemon.
- **Severity:** Medium. The bug does not break delivery, but it creates
  constant dirty-worktree noise and makes agents more likely to commit runtime
  state accidentally.
