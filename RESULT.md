# B175 RESULT

**Branch:** `fix/bl-b175`  
**Commit:** `905e38654394263691723f820029b7aec093a3f8`  
**Claim commit (pre-existing):** `0e2559d7`

## Summary

Fixed Codex app-server startup failure handling so slow/supported Codex is not told to “upgrade”, readiness timeout is distinct from process death, the readiness deadline is longer/configurable, and hook-backed fallback no longer runs `codex resume --last` without an explicit thread target.

## Files changed

| Path | Change |
|------|--------|
| `ocaml/c2c_codex_app_server.ml` / `.mli` | Default readiness 90s; `C2C_CODEX_APP_SERVER_READINESS_TIMEOUT_S`; `wait_ready` returns typed death status; timeout vs died messages; log tail snippet |
| `ocaml/c2c_codex_session.ml` / `.mli` | `diagnostic_followup` — upgrade advice only for version/capability/not-found |
| `ocaml/c2c_start.ml` | Bare `resume_session_id` no longer implies `resume --last`; only `codex_resume_target` resumes |
| `ocaml/test/test_c2c_codex_app_server.ml` | Slow-ready success; supported-version timeout; env override; died exit status |
| `ocaml/test/test_c2c_codex_session.ml` | Followup text: upgrade only when version issue |
| `ocaml/test/test_c2c_start.ml` | Fresh launch without `--last`; kickoff on bare session id |
| `.collab/runbooks/c2c-env-vars.md` | Document readiness timeout env |

## Tests run

- `test_c2c_codex_app_server.exe` — **32/32 pass** (incl. B175 slow ready / env / supported-version timeout)
- `test_c2c_codex_session.exe` — **35/35 pass** (incl. diagnostic followup B175)
- `test_c2c_start.exe test launch_args` — **115 pass** (incl. bare session id → fresh, exact resume, kickoff)

Full `test_c2c_start.exe` has pre-existing env-sensitive failures (`get_tmux_location`, instances filter/gc) unrelated to this change.

## Residual risks

- **Re-launch without saved thread:** managed Codex restarts that never persisted `codex_resume_target` now start a **fresh** Codex session instead of `resume --last`. Intentional per B175; exact-thread resume still works when target is saved.
- **Real slow/hung codex app-server:** unit tests are fully scripted; live cold-start under load not re-dogfooded in this worktree (dune contention during parallel agent builds).
- **Env pollution in tests:** `test_readiness_timeout_from_env` leaves `C2C_CODEX_APP_SERVER_READINESS_TIMEOUT_S` set to an invalid value (falls back to default); other tests override timeout in config.
- **Adapter escape:** `CodexAdapter` still maps empty `resume_session_id` to `resume --last` if called that way; `prepare_launch_args` no longer does so for bare session UUIDs.

## Not done (per task)

- Not merged to master
- Not run `bl done`
