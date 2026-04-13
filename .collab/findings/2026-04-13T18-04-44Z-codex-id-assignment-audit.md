# C2C Identity Assignment Audit

Alias / session identity in c2c currently has two layers:

- `session_id`: storage key for inbox, archive, room membership, and MCP caller isolation.
- `alias`: human/social routing name used by peers for `send`, `send_all`, and rooms.

## Generation paths

### OCaml MCP broker

Source: `ocaml/c2c_mcp.ml`.

- `current_session_id()` reads `C2C_MCP_SESSION_ID`.
- `auto_register_alias()` reads `C2C_MCP_AUTO_REGISTER_ALIAS`.
- Startup auto-register runs only when both env vars exist.
- Register records include `session_id`, `alias`, `pid`, `pid_start_time`, and `registered_at`.
- If no explicit `C2C_MCP_CLIENT_PID` is valid, the broker uses `Unix.getppid()` as the client pid.
- `register` dedupes by either same `session_id` or same `alias`, then migrates undrained inbox messages from evicted session IDs to the new session ID.
- `register` rejects alias hijack if the requested alias is held by an alive different session.
- `send`, `send_all`, and `send_room` resolve sender alias from current `C2C_MCP_SESSION_ID` first. Caller-supplied `from_alias` / `alias` is legacy fallback.
- Sender impersonation is rejected when `from_alias` is held by an alive different session with a real pid.
- `poll_inbox` and `whoami` still use `resolve_session_id`, which honors a `session_id` argument override if supplied. `peek_inbox`, `history`, and `my_rooms` deliberately ignore `session_id` arguments and use env only.

### Python MCP wrapper

Source: `c2c_mcp.py`.

- Computes broker root from `C2C_MCP_BROKER_ROOT` or repo `.git/c2c/mcp`.
- If `C2C_MCP_SESSION_ID` is absent, tries Claude session discovery via `c2c_whoami.current_session_identifier()`.
- Syncs legacy YAML registry into broker `registry.json`, preserving existing broker-only registrations if their session_id and alias do not collide.
- Performs pre-server auto-register using `C2C_MCP_SESSION_ID` + `C2C_MCP_AUTO_REGISTER_ALIAS`.
- `maybe_auto_register_startup` has weaker guard behavior than the OCaml server: it skips only if the same `(session_id, alias)` is alive, then removes registrations whose session_id OR alias matches. OCaml startup has explicit hijack/alias-occupied guards.
- Chooses pid from Claude `/proc` scan when possible, otherwise `C2C_MCP_CLIENT_PID`, otherwise parent pid.

### Python legacy Claude registration

Sources: `c2c_register.py`, `c2c_registry.py`, `c2c_whoami.py`.

- `c2c register <session>` discovers a live Claude session and uses the Claude transcript session UUID as `session_id`.
- Existing same session_id keeps its alias and refreshes pid data.
- New sessions get first available `<word>-<word>` alias from `data/c2c_alias_words.txt`.
- The alias pool is deterministic, finite, and small.
- Legacy registry is YAML in `.git/c2c/registry.yaml`; broker registry is JSON in `.git/c2c/mcp/registry.json`.

### Setup scripts

- `c2c setup codex`: default alias is `codex-<user>-<host>`, and writes both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS` to the same alias.
- `c2c setup kimi`: default alias is `kimi-<user>-<host>`; if no explicit session id is provided, session_id equals alias.
- `c2c setup crush`: same pattern as Kimi, `crush-<user>-<host>`.
- `c2c setup opencode`: session_id defaults to `opencode-<target-dir-name>`; alias defaults to same unless explicitly overridden.
- `c2c setup claude-code`: default alias is `claude-<user>-<host>`; session_id is optional and omitted by default, so wrapper discovery or host env must supply it.

### Managed launchers

- `run-codex-inst`: default session_id is `codex-<instance-name>`, but alias comes from `c2c_alias` or `RUN_CODEX_INST_ALIAS_HINT`. Current `c2c-codex-b4` uses `session_id=codex-local`, alias hint `codex`.
- `run-kimi-inst`: default session_id is `kimi-<instance-name>`; alias defaults to session_id. It sets `C2C_MCP_CLIENT_PID` to its own pid.
- `run-crush-inst`: default session_id is `crush-<instance-name>`; alias defaults to session_id.
- OpenCode managed configs pin session_id and alias in generated `.opencode.json`.
- Outer loops now call `c2c refresh-peer <alias> --pid <child> --session-id <expected>` for several clients to close stale pid/session drift windows.

## Live registry observations

At audit time, `mcp__c2c__whoami` returned `codex-xertrov-x-game`. The list tool showed:

- `codex-xertrov-x-game` registered but `alive=false`.
- `codex` / `codex-local` alive.
- `storm-ember` present with `alive=null` because it is pidless.
- `storm-beacon` currently registered under `session_id=opencode-c2c-msg`, `alive=false`, which matches prior drift findings.
- `kimi-nova` and `crush-xertrov-x-game` currently share the same pid, suggesting either shared parent/process accounting or a stale pid update path.
- Several dead/fixture rows remain (`storm-storm`, `storm-herald`, `opencode-a`).

The current session binding fix means this Codex sends as `codex-xertrov-x-game` even though its registry row is stale. That is intentional after the stale-pid edge fix, but it makes `list` liveness misleading for the current caller.

## Risk assessment

1. There is no single canonical identity allocator. Identities come from setup defaults, managed config files, Claude UUID discovery, first-available word pairs, env vars, and ad hoc smoke-test names.
2. Python `c2c_mcp.py` pre-server auto-register is not as strict as OCaml startup/register guards. If it runs before the OCaml server, it can still rewrite broker registry rows with less protection.
3. Many clients deliberately use `session_id == alias`. This is pragmatic for Kimi/Crush/OpenCode but blurs storage identity and social identity, making renames harder to reason about.
4. Generic defaults like `codex-<user>-<host>` or `kimi-<user>-<host>` collide across repos or multiple sessions for the same client/user/host unless overridden.
5. Legacy CLI fallback can write messages directly to broker inboxes and resolves sender alias by env/session lookup. It is useful, but it bypasses the OCaml sender guard surface.
6. `poll_inbox` still honors explicit `session_id` arguments, unlike `peek_inbox`, `history`, and `my_rooms`. That is a privacy/isolation inconsistency.
7. Pidless rows are treated as alive by core resolution for compatibility, but list reports `alive=null`. This avoids breaking legacy rows but keeps zombie rows operationally confusing.

## Recommendations

1. Make OCaml the only writer for broker registration semantics. Remove or narrow `c2c_mcp.py` pre-server registry mutation, or copy OCaml's exact hijack/alias-occupied guards into it.
2. Introduce an explicit identity schema: `client_type`, `instance_id`, `session_id`, `alias`, `owner`, and `source`. Keep alias as a display/routing name, not the default storage key unless the operator explicitly chooses that.
3. Generate managed session IDs as `<client>-<instance>-<stable-id>` and aliases as human names. For one-shot probes, require a suffix like `-smoke-<timestamp>` and never reuse durable aliases.
4. Make `poll_inbox` ignore caller-supplied `session_id` by default, matching `peek_inbox` / `history` / `my_rooms`. If operator override is needed, add an explicitly named admin tool or CLI flag.
5. Add a `diagnose_identity` / `identity_health` tool that reports duplicate aliases, dead aliases, pidless rows, session_id/alias drift against managed config, shared pid anomalies, and whether caller env maps to a live registry row.
6. Add tests for parity between Python wrapper auto-register and OCaml startup/register guards.
7. Treat pidless rows as legacy only: warn loudly in list/health and avoid considering pidless rows authoritative for alias ownership once all managed clients write pid metadata.

