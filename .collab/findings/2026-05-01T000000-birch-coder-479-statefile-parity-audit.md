# Statefile Parity Audit — #479

**Date**: 2026-05-01
**Agent**: birch-coder
**Worktree**: `.worktrees/479-statefile-parity-audit/`

---

## Scope

Per-client catalog of which statefiles are read and written, and known gaps
(fields that should flow through but don't).

---

## 1. `instances/<name>/config.json`

Canonical per-instance config. Written by `c2c start` on every launch
(`c2c_start.ml:2155` `write_config`). Read by `c2c start` on resume
(`c2c_start.ml:2216` `load_config_opt`).

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `name` | `write_config` | `load_config_opt` | Always |
| `client` | `write_config` | `load_config_opt` | Always |
| `session_id` | `write_config` | `load_config_opt` | Always |
| `resume_session_id` | `write_config` | `load_config_opt` | Always |
| `alias` | `write_config` | `load_config_opt` | Always |
| `extra_args` | `write_config` | `load_config_opt` | Always |
| `created_at` | `write_config` | `load_config_opt` | Always |
| `last_launch_at` | `write_config` | `load_config_opt` | Only when set |
| `last_exit_code` | `write_config` (on exit) | `load_config_opt` | Only when set |
| `last_exit_reason` | `write_config` (on exit) | `load_config_opt` | Only when set |
| `broker_root` | `write_config` | `load_config_opt` | **Conditional**: only when non-default; see #504 |
| `auto_join_rooms` | `write_config` | `load_config_opt` | Always |
| `codex_resume_target` | `write_config` | `load_config_opt` | Only for codex/codex-headless |
| `binary_override` | `write_config` | `load_config_opt` | Only when set |
| `model_override` | `write_config` | `load_config_opt` | Only when set |
| `agent_name` | `write_config` | `load_config_opt` | Only when set |

### Key behavior

- `broker_root` is intentionally **omitted from the written file** when it equals
  the resolver default (`c2c_start.ml:2166–2170`). At load time, absent/empty
  `broker_root` falls back to the resolver (`c2c_start.ml:2236–2240`). This prevents
  stale-fingerprint drift after broker migrations (#504/#501).

- `resume_session_id` is a raw string; `codex_resume_target` is the codex-specific
  thread/session target; for OpenCode the `opencode-session.txt` file (plugin-written)
  overrides both on resume (`c2c_start.ml:4962–4995`).

---

## 2. `instances/<name>/c2c-plugin.json` — OpenCode sidecar

Written by `c2c setup opencode` (`c2c_setup.ml:607–616`) and refreshed by
`c2c start` via `refresh_opencode_identity` (`c2c_start.ml:1312–1389`).

Read by the OpenCode TS plugin at startup.

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `session_id` | `setup_opencode`, `refresh_identity` | OpenCode TS plugin | c2c instance name (= session_id) |
| `alias` | `setup_opencode`, `refresh_identity` | OpenCode TS plugin | Always |
| `broker_root` | `setup_opencode` (always) | OpenCode TS plugin | **Gap**: setup_write always persists it; but `refresh_identity` conditionally omits when == resolver default (#504) |
| `broker_root_fingerprint` | `setup_opencode` (always, #507) | OpenCode TS plugin | SHA-256 of remote.origin.url; used to detect staleness |

### Gap — `broker_root` conditional in `refresh_identity` vs unconditional in `setup_opencode`

`setup_opencode` (`c2c_setup.ml:611`) writes `broker_root` unconditionally.
`refresh_identity` (`c2c_start.ml:1379–1382`) uses the #504 skip logic:
only writes `broker_root` when non-default.

This means after `c2c install opencode`, the sidecar always has `broker_root`.
After `c2c start opencode`, `refresh_identity` may strip it. The plugin's
own canonical resolver handles the absent case, so no functional bug — but
the asymmetry means the sidecar is not a stable snapshot of what the plugin
will actually use.

---

## 3. `instances/<name>/kimi-mcp.json`

Written fresh on every `c2c start kimi` launch by `KimiAdapter.build_start_args`
(`c2c_start.ml:3293–3302`). Passed to kimi as `--mcp-config-file` argument.

Read by kimi binary at startup.

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `mcpServers.c2c.command` | `build_kimi_mcp_config` | kimi binary | `"c2c-mcp-server"` |
| `mcpServers.c2c.args` | `build_kimi_mcp_config` | kimi binary | `[]` |
| `mcpServers.c2c.type` | `build_kimi_mcp_config` | kimi binary | `"stdio"` |
| `mcpServers.c2c.env.C2C_MCP_SESSION_ID` | `build_kimi_mcp_config` | kimi/MCP server | instance name |
| `mcpServers.c2c.env.C2C_MCP_AUTO_REGISTER_ALIAS` | `build_kimi_mcp_config` | kimi/MCP server | alias |
| `mcpServers.c2c.env.C2C_MCP_AUTO_JOIN_ROOMS` | `build_kimi_mcp_config` | kimi/MCP server | `"swarm-lounge"` |
| `mcpServers.c2c.env.C2C_MCP_AUTO_DRAIN_CHANNEL` | `build_kimi_mcp_config` | kimi/MCP server | `"0"` |
| `mcpServers.c2c.env.C2C_MCP_BROKER_ROOT` | `build_kimi_mcp_config` | kimi/MCP server | **Conditional**: only when non-default |
| `mcpServers.c2c.allowedTools` | `build_kimi_mcp_config` | kimi binary | Tool allowlist |

### Gap — `C2C_MCP_BROKER_ROOT` not persisted in `kimi-mcp.json` when using resolver default

`build_kimi_mcp_config` (`c2c_start.ml:2751–2762`) uses the #504 skip logic:
only emits `C2C_MCP_BROKER_ROOT` in the env when it differs from the resolver
default. This is correct drift-prevention — but it means `kimi-mcp.json` is **not
a complete snapshot** of the kimi launch environment. The broker root must
be re-resolved by the kimi MCP server at startup.

---

## 4. `instances/<name>/oc-plugin-state.json`

**Written by the OpenCode TS plugin itself** (`.opencode/plugins/c2c.ts`), not by
c2c. c2c reads it to determine plugin活性 (`opencode_plugin_active`,
`c2c_start.ml:3449–3487`).

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `state` (or root) | OpenCode TS plugin | `opencode_plugin_active` | Object or root-level |
| `state.c2c_session_id` | OpenCode TS plugin | `opencode_plugin_active` | Must equal instance name for match |
| `state.activity_sources.plugin.last_active_at` | OpenCode TS plugin | `opencode_plugin_active` | RFC3339 UTC; freshness check |

c2c does **not write** this file. It is purely a plugin-to-c2c contract.

---

## 5. `instances/<name>/tmux.json`

Written by `capture_and_write_tmux_location` (`c2c_start.ml:1724–1749`) at
session start. Read by `read_tmux_location_opt` (`c2c_start.ml:1754–1768`) in
`build_env` to surface `C2C_TMUX_LOCATION`.

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `session` | `capture_and_write_tmux_location` | `read_tmux_location_opt` | tmux session:window.pane |
| `pane_id` | `capture_and_write_tmux_location` | `write_tmux_target_info` | Written but not read by c2c |
| `captured_at` | `capture_and_write_tmux_location` | — | Written but never read by c2c |

### Gaps

- `pane_id` is written by c2c but **never read back** by any c2c function.
  Only `session` is used in `read_tmux_location_opt`.
- `captured_at` is written but **never read** by c2c. Could be used for
  staleness checks.

---

## 6. `instances/<name>/thread-id-handoff.jsonl`

Used by **codex-headless only**. Written by the headless thread-id watcher
(`start_headless_thread_id_watcher`, `c2c_start.ml:3707–3745`). Read by the
same watcher on resume.

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `thread_id` (JSON object per line) | Bridge emits line; watcher reads + persists | `persist_headless_thread_id` → `resume_session_id` in config.json | Codex thread ID handoff |

Other clients (claude, codex TUI, opencode, kimi) do **not use** this file.

---

## 7. `.c2c/repo.json`

Project-level config at `<repo>/.c2c/repo.json`. Written by `c2c init`,
`c2c setup`, `c2c repo set`. Read by various subcommands.

### Fields

| Field | Written by | Read by | Notes |
|-------|------------|---------|-------|
| `authorizers` | `c2c init` (or `c2c repo set authorizers`) | `c2c_authorizers.get_authorizers` | Ordered alias list |
| `supervisors` | `c2c init --supervisor` | `c2c_setup`-via-`c2c init` | Alias list (written; routing uses authorizers) |
| `supervisor_strategy` | `c2c init --supervisor-strategy` | — | Written but **never read** by any current code path |

### Gap — `supervisor_strategy` written but never read

`c2c init` accepts `--supervisor-strategy` and writes it to repo.json
(`c2c_setup.ml:5894–5898`). However, no current code path reads
`supervisor_strategy` back from repo.json. The supervisor dispatch logic
in `c2c_approval_paths.ml` and `c2c_authorizers.ml` does not reference it.
The field is persisted but inert.

---

## Per-Client Summary

### claude

**Reads**:
- `instances/<name>/config.json` — all fields on resume (`load_config_opt`)

**Writes**:
- `instances/<name>/config.json` — all config fields (`write_config`)
- `instances/<name>/meta.json` — launch metadata (binary, args, pid, start_ts) (`c2c_start.ml:4221–4235`)

**Does NOT use**: `c2c-plugin.json`, `kimi-mcp.json`, `oc-plugin-state.json`,
`thread-id-handoff.jsonl`, `tmux.json`

**Gaps**:
- `agent_name` is persisted in `config.json` but NOT surfaced to the claude
  MCP server entry. `setup_claude` writes env vars to `.mcp.json`/`~/.mcp.json`
  but does NOT include `agent_name` there. The claude MCP server receives it
  via `C2C_AGENT_NAME` from `build_env` (`c2c_start.ml:4086–4089`), not from
  the MCP config file. This is fine for functionality but means the MCP config
  file is not self-contained for claude restart.

---

### codex

**Reads**:
- `instances/<name>/config.json` — all fields on resume (`load_config_opt`)
- `~/.codex/config.toml` — written by `c2c install codex`; not read by c2c

**Writes**:
- `instances/<name>/config.json` — all config fields (`write_config`)
- `instances/<name>/thread-id-handoff.jsonl` — only for codex-headless

**Does NOT use**: `c2c-plugin.json`, `kimi-mcp.json`, `oc-plugin-state.json`,
`tmux.json`

**Gaps**:
- `broker_root` written to `config.json` (conditional) but NOT to
  `~/.codex/config.toml` by c2c setup. The setup (`c2c_setup.ml:337–341`)
  writes `C2C_MCP_BROKER_ROOT` to the `[mcp_servers.c2c.env]` section,
  which is correct — the TOML env var, not a statefile.
- No per-instance statefile surfaces `codex_resume_target` back to any
  codex-side file. The config.json field is c2c-internal only.

---

### opencode

**Reads**:
- `instances/<name>/config.json` — all fields on resume (`load_config_opt`)
- `.opencode/opencode.json` — MCP config; read by the TS plugin (not by c2c OCaml)
- `instances/<name>/oc-plugin-state.json` — written by TS plugin; read by c2c
  to check plugin freshness (`opencode_plugin_active`)

**Writes**:
- `instances/<name>/config.json` — all config fields (`write_config`)
- `instances/<name>/c2c-plugin.json` — session_id, alias, (conditional) broker_root,
  broker_root_fingerprint (`refresh_identity`, `c2c_setup.ml:607–616`)
- `.opencode/opencode.json` — env block updated by `refresh_identity` to add
  `C2C_MCP_BROKER_ROOT`, `C2C_MCP_AUTO_JOIN_ROOMS`, etc. (`c2c_start.ml:1317–1358`)
- `instances/<name>/kickoff-prompt.txt` — written by `deliver_kickoff` for fresh spawns

**Does NOT use**: `kimi-mcp.json`, `thread-id-handoff.jsonl`, `tmux.json`

**Gaps**:
- `opencode_session_id` (OpenCode's own session ID, e.g. `ses_abc123`) is NOT
  written to any statefile by c2c. The plugin writes it to
  `instances/<name>/opencode-session.txt` (plugin behavior), but c2c only reads
  that file on resume (`c2c_start.ml:4962–4973`). There is no c2c statefile
  that records the OpenCode session ID — it lives in `opencode-session.txt`
  (plugin-owned) and `config.json`'s `resume_session_id`.
- `agent_name` is NOT written to the `c2c-plugin.json` sidecar. It IS passed
  via `C2C_AGENT_NAME` env var (`c2c_start.ml:4086–4089`) and the TS plugin
  reads it from env. But the sidecar has no `agent_name` field, so a restart
  of just the plugin process (without `c2c start`) would lose the agent_name.

---

### kimi

**Reads**:
- `instances/<name>/config.json` — all fields on resume (`load_config_opt`)
- `instances/<name>/kimi-mcp.json` — written by c2c; read by kimi binary

**Writes**:
- `instances/<name>/config.json` — all config fields (`write_config`)
- `instances/<name>/kimi-mcp.json` — full MCP server config (`build_kimi_mcp_config`)
- `instances/<name>/kickoff-prompt.txt` — written for fresh spawns

**Does NOT use**: `c2c-plugin.json`, `oc-plugin-state.json`,
`thread-id-handoff.jsonl`, `tmux.json`

**Gaps**:
- `kimi_mcp_server_path` (the server binary path) is NOT a field in
  `kimi-mcp.json`. The `command` field in the JSON is always `"c2c-mcp-server"`.
  The actual binary path is determined by PATH resolution on the kimi side. This
  is fine for the canonical case, but if an operator needs a non-default server
  path, there is no statefile field to record it.
- `broker_root` is conditionally omitted from `kimi-mcp.json` (correct behavior
  per #504), but there is no companion field indicating whether it was omitted
  vs truly absent. The MCP server must re-resolve at startup.

---

## Cross-Cutting Gaps

### `broker_root` — inconsistent persistence across setup vs start

`c2c install <client>` (setup) writes `broker_root` to:
- `~/.codex/config.toml` via `setup_codex` (always, `c2c_setup.ml:338`)
- `~/.kimi/mcp.json` via `setup_kimi` (always, `c2c_setup.ml:396`)
- `.opencode/c2c-plugin.json` via `setup_opencode` (always, `c2c_setup.ml:611`)
- `~/.claude/settings.json` / `<project>/.mcp.json` via `setup_claude`
  (always, `c2c_setup.ml:854`)
- `~/.gemini/settings.json` via `setup_gemini` (always, `c2c_setup.ml:487`)
- `~/.config/crush/crush.json` via `setup_crush` (always, `c2c_setup.ml:1103`)

`c2c start` writes `broker_root` to `instances/<name>/config.json` **conditionally**
(only when non-default, per #504). This asymmetry means:
- After `c2c install opencode`, the sidecar always has `broker_root`.
- After `c2c start opencode`, `refresh_identity` may strip it from the sidecar.
- On resume, `setup_opencode` re-writes it (unconditionally) before `refresh_identity`
  runs.

The net effect: the sidecar version of `broker_root` depends on whether
`c2c start` has run since the last `c2c install`. Not a functional bug (plugin
has canonical resolver), but a confusing invariant.

### `session_id` — per-client naming

The `session_id` field in `config.json` always equals the instance `name`
(`c2c_start.ml:5052`: `session_id = name`). This is the c2c session ID,
NOT the client's native session ID.

| Client | Client's native session ID | Stored where |
|--------|--------------------------|-------------|
| claude | UUID in `config.json`/`last_launch_at` | `resume_session_id` in config.json |
| codex | Thread/session string | `codex_resume_target` in config.json |
| opencode | `ses_*` from plugin | `opencode-session.txt` (plugin-owned) + `resume_session_id` in config.json |
| kimi | UUID | `resume_session_id` in config.json |

No per-client statefile surfaces the client's native session ID in a
client-neutral way, other than `resume_session_id` (which is client-specific
in format). `thread-id-handoff.jsonl` carries codex-headless thread IDs only.

### `supervisors` / `authorizers` — repo.json fields not fully wired

`supervisors` is written to `.c2c/repo.json` by `c2c init --supervisor`.
`authorizers` is written to `.c2c/repo.json` by `c2c init`. Both are read
by `c2c_authorizers.get_authorizers` for permission routing.

`supervisor_strategy` is written but **never read**.

### `opencode_session_id` — no c2c statefile field

The OpenCode plugin generates and uses `ses_*` session IDs. c2c captures them
in `opencode-session.txt` (plugin-written, c2c-read), but there is no
`opencode_session_id` field in `config.json` or `c2c-plugin.json`. The
`opencode-session.txt` mechanism works but is not part of the documented
statefile contract.

---

## Recommendations

1. **`tmux.json` — read back `pane_id`** (`c2c_start.ml:1754`): add `pane_id`
   to `read_tmux_location_opt` return type and pass it through `C2C_TMUX_LOCATION`
   or a new env var if tmux delivery ever needs the pane ID separately from
   the session:window.pane string.

2. **`supervisor_strategy` — wire or remove**: either read it back in
   `c2c_authorizers.ml` for dispatch decision, or stop writing it to repo.json
   to avoid dead state.

3. **`kimi-mcp.json` — add a `broker_root_source` marker**: since
   `broker_root` is conditionally omitted, add `"broker_root_source": "resolver"`
   when omitted so the reader knows the value was intentionally absent rather than
   forgotten.

4. **`c2c-plugin.json` — document the `broker_root` asymmetry**: the
   setup-vs-start inconsistency in broker_root persistence should be documented
   in the statefile contract so future changes don't accidentally break the
   plugin's canonical-resolver fallback.

5. **`agent_name` in sidecar for opencode**: add `agent_name` to
   `c2c-plugin.json` written by `refresh_identity` so the sidecar is
   self-contained for plugin-process restarts.
