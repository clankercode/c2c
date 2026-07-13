# Design: Re-enable Kimi as a tier-1 c2c client

## Background

Kimi support was soft-disabled in B146 (`C2c_start.kimi_disabled_for_release = true`) while the project shipped the release. The disable preserved all machinery (notifier, hooks, adapter) behind a single flag. Since then the upstream CLI has changed: the legacy Python `kimi-cli` has been superseded by the TypeScript **Kimi Code CLI** (`kimi` binary, `~/.kimi-code/` state dir). The legacy file-based notification store that c2c used for delivery is gone in Kimi Code.

Goal: bring Kimi back to tier-1 supported status with direct message delivery and a first-class c2c skill.

## Goal & success criteria

- `c2c install kimi` and `c2c start kimi` work again and are advertised in client lists.
- Kimi Code session IDs and state paths are used correctly (`session_<uuid>`, `~/.kimi-code/`).
- Inbound c2c messages are delivered directly into a managed Kimi Code session, triggering a model turn.
- A Kimi-specific `/c2c` skill is installed by `c2c install kimi` (like Claude/Codex/Grok).
- Existing tests pass; disabled tests are removed or inverted.

## What changed in upstream Kimi

| Legacy `kimi-cli` | Kimi Code CLI |
|---|---|
| State under `~/.kimi` | State under `~/.kimi-code` |
| Session dir UUID only, e.g. `604ca148-d7c8-...` | Session IDs are `session_<uuid>` and are used with `--session` |
| File-based `notifications/` store consumed by the TUI | No external notification-store reader; notifications are internal |
| Local server not present | `kimi server run` exposes REST + WebSocket on `127.0.0.1:58627` |
| Hooks in `~/.kimi/config.toml` | Hooks in `~/.kimi-code/config.toml` |

Local server endpoints discovered from source (`MoonshotAI/kimi-code`):

- `GET /api/v1/healthz` — unauthenticated liveness.
- `GET /api/v1/meta` — server metadata + capabilities.
- `GET /api/v1/sessions` — list sessions.
- `POST /api/v1/sessions/{session_id}/prompts` — submit a prompt; enqueues a user message and starts/resumes a turn.
- Prompt body shape: `{ "content": [{ "type": "text", "text": "..." }], ... }`.
- Auth: `Authorization: Bearer <token>` where `<token>` is in `~/.kimi-code/server.token` and printed at server startup.

## Approaches considered

1. **Notification-store fallback only** — update `c2c_kimi_notifier` to write to `~/.kimi-code/sessions/.../notifications/`. Rejected: Kimi Code does not read an external notification store; the legacy store was removed.
2. **Server REST prompt injection** — deliver by `POST /api/v1/sessions/{sid}/prompts`. This is direct, no tmux hacks, and triggers a model turn. Chosen as primary.
3. **WebSocket / ACP** — WebSocket is available but is a streaming UI protocol; ACP is stdio JSON-RPC for IDE integration. Both are heavier and do not give us a simpler delivery path than the REST prompt endpoint.

## Chosen design: REST prompt injection + skill + re-enable

> **2026-07-13 integration fix:** Kimi Code 0.23+ does not recognize
> c2c-generated `session_<uuid>` IDs passed via `kimi --session <sid>`;
> it returns "Session not found".  Managed `c2c start kimi` therefore
> launches `kimi` without `--session` and lets Kimi Code mint its own
> CLI/TUI session ID.  Kimi Code's REST prompt endpoint
> (`POST /api/v1/sessions/{id}/prompts`) only works for sessions created
> through the API, not for CLI/TUI sessions.  Consequently, the practical
> delivery path for managed Kimi sessions is the `/c2c` skill + Monitor
> (`c2c monitor`); `C2c_kimi_deliver` is retained for future API/web
> session support.

### Components

1. **Re-enable flag & lists**
   - Set `C2c_start.kimi_disabled_for_release = false`.
   - Remove `ocaml/cli/test_c2c_kimi_disabled.ml` and its dune entry.
   - Restore `"kimi"` to `known_clients`, `init_configurable_clients`, `default_heartbeat_clients`, and skill text.

2. **Kimi Code path / session ID updates**
   - Change `KimiAdapter.config_dir` from `.kimi` to `.kimi-code`.
   - Change default share/state resolution in `C2c_kimi_notifier` from `~/.kimi` to `~/.kimi-code`.
   - Generate `resume_session_id` as `session_<uuid>` instead of a bare UUID.
   - Ensure `build_start_args` passes `--session session_<uuid>` (still valid; Kimi Code accepts the `session_` prefix).
   - Update hook TOML path from `~/.kimi/config.toml` to `~/.kimi-code/config.toml`.

3. **Direct delivery module: `C2c_kimi_deliver`** (new)
   - Discover the local Kimi server:
     - Read `~/.kimi-code/server.token` for bearer auth.
     - Default port `58627`; read lock/info if present; allow `C2C_KIMI_SERVER_PORT` override.
   - Resolve session: `resume_session_id` is the server session id (`session_<uuid>`).
   - POST `{"content":[{"type":"text","text":"<envelope>"}]}` to `/api/v1/sessions/{sid}/prompts`.
   - The prompt body is the canonical c2c XML envelope
     `<c2c event="message" from="..." to="...">...</c2c>` with the `from_alias`,
     `to_alias`, and `content` fields XML-escaped.
   - On success, remove the message from the broker inbox (drain, not peek). On failure, leave it for retry.
   - Safety: respect DND; skip system events; never resolve approvals.
   - Idle-gate: check `GET /api/v1/sessions/{sid}/status` or wire.jsonl mtime before injecting, to avoid interrupting an active turn.
   - Fixture gating: all external HTTP interactions are gated by
     `C2C_KIMI_DELIVER_FIXTURE=1`; tests may also set
     `C2C_KIMI_DELIVER_FIXTURE_BASE_URL` and `C2C_KIMI_DELIVER_FIXTURE_TOKEN`.

4. **Notifier lifecycle update**
   - Replace the file-based writer in `C2c_kimi_notifier` with a call to `C2c_kimi_deliver.submit`.
   - When no API-addressable session id is configured (the normal state for
     managed `c2c start kimi` sessions), skip REST delivery gracefully, log,
     and continue with chat-log write + tmux wake.  Do not retry indefinitely.
   - Keep the daemon (fork+setsid, pidfile, upgrade-correctness) and tmux-wake
     fallback.  For managed TUI sessions the practical delivery path is the
     `/c2c` skill + Monitor; REST remains the path for future API/web sessions.

5. **c2c skill for Kimi**
   - Add `.collab/skills/c2c-src/harness/kimi.md` with Kimi-specific notes (CLI-first, `--yolo`, `c2c monitor`, server-delivered messages).
   - Extend `tools/ci/codegen-c2c-skills.py` `EMBEDS` to include `kimi` -> `ocaml/cli/c2c_kimi_skill_embedded.ml`.
   - Add `write_kimi_skill` / `refresh_kimi_skill_if_stale` in `ocaml/cli/c2c_setup.ml`, writing to `~/.kimi-code/skills/c2c/SKILL.md`.
   - Wire into `c2c install kimi` and SessionStart hook refresh.

6. **MCP config update**
   - `build_kimi_mcp_config` already exists; ensure it still points at the c2c MCP server and does not hard-code legacy paths.

### Data flow

For managed `c2c start kimi` TUI sessions (no API-addressable session id):

```
c2c broker inbox (per-repo or global sessions)
        |
        v
C2c_kimi_notifier.run_once (daemon loop)
        |
        +--> system event? -> chat-log only (when session dir known)
        |
        +--> no configured session id? -> skip REST, log, tmux wake
        |
        +--> C2c_kimi_deliver.submit (future API/web sessions only)
                 |
                 +--> read ~/.kimi-code/server.token
                 +--> POST /api/v1/sessions/{sid}/prompts
                 +--> on 200: drain message from broker
                 +--> on failure: leave message, log, retry next tick
```

The operator-visible delivery path for managed Kimi sessions is the `/c2c`
skill + Monitor (`c2c monitor`).

### Error handling

- Server not running → REST call fails → message stays in inbox → retry.
- Token missing → fail closed, log, retry.
- Session not found → log; do not drain (operator may have deleted the session); retry will keep failing until session is recreated.
- DND active → skip delivery entirely (message stays in inbox).
- System events from `c2c-system` → never injected; only chat-logged.

### Testing plan

- Unit tests for `C2c_kimi_deliver` with a mock HTTP server
  (`C2C_KIMI_DELIVER_FIXTURE=1`, optional
  `C2C_KIMI_DELIVER_FIXTURE_BASE_URL` / `C2C_KIMI_DELIVER_FIXTURE_TOKEN`
  overrides).
- Update `test_c2c_setup_kimi.ml` for new paths and skill install.
- Update `test_c2c_kimi_notifier.ml` to exercise REST delivery and fallback.
- `C2c_kimi_deliver.message_envelope` is exported so tests can assert the
  exact XML envelope shape (including XML escaping) without making an HTTP call.
- E2E: managed `c2c start kimi` in tmux, send a DM, verify the prompt appears in Kimi's transcript.
- Build: `just build`, `just check`, `just bi`.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Kimi server port/token format changes | Isolate discovery in one module; env overrides for tests. |
| Prompt injection accidentally interrupts an active turn | Idle-gate on session status / wire.jsonl mtime; respect DND. |
| Managed session deleted while daemon runs | Session-not-found leaves message in inbox; operator restart recovers. |
| Approval boundary (B098) | REST injection only inserts data as a user prompt; it never resolves approvals or writes verdict files. |

## Files to touch

- `ocaml/c2c_start.ml` — disable flag, client lists, KimiAdapter.
- `ocaml/c2c_kimi_notifier.ml` — switch writer to REST delivery.
- `ocaml/c2c_kimi_deliver.ml{,i}` — new REST delivery module.
- `ocaml/cli/c2c_setup.ml` — skill write/refresh, install/start lists, hook path.
- `ocaml/cli/c2c_kimi_hook.ml` — update config path.
- `ocaml/cli/c2c_skills_cmd.ml` — possibly add kimi skill serve path.
- `ocaml/cli/dune` — add `c2c_kimi_deliver`, remove disabled test.
- `tools/ci/codegen-c2c-skills.py` — add kimi harness embed.
- `.collab/skills/c2c-src/harness/kimi.md` — new skill source.
- `ocaml/cli/c2c_claude_skill_embedded.ml` / `c2c_grok_skill_embedded.ml` — remove B146-TEMP notes.
- `ocaml/cli/test_c2c_kimi_disabled.ml` — delete.
- `ocaml/test/test_c2c_kimi_notifier.ml` — update tests.
- `ocaml/cli/test_c2c_setup_kimi.ml` — update tests.
- `.collab/runbooks/kimi-notification-store-delivery.md` — update or deprecate.

## Open questions (to resolve during implementation)

1. Does `kimi server run` need to be started by c2c, or is it started automatically by the CLI/web UI? Initial probe shows `kimi` standalone does not require the server; managed sessions may need c2c to start it or rely on the user having started it. Decision: attempt delivery via server; if server absent, fall back to tmux-wake + chat-log only (messages stay in inbox).
2. Should `c2c start kimi` auto-start `kimi server run`? Decision: deferred — start with requiring the server to be running (user can run `kimi server run` or `kimi web`), and document. Future iteration can add auto-start.
3. Hook config path: Kimi Code uses `~/.kimi-code/config.toml`; update install hook accordingly.
