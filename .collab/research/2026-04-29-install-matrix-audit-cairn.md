# `c2c install <client>` — install matrix audit

- Author: cairn (subagent of coordinator1)
- Date: 2026-04-29
- Source of truth: `/home/xertrov/src/c2c/ocaml/cli/c2c_setup.ml` @ master HEAD
- Scope: claude, codex, opencode, kimi, gemini (5 clients per request); crush still installable but mid-deprecation (#405 on a feature branch, not yet on master)
- Companion / prior audit: `.collab/research/2026-04-28T10-23-00Z-coordinator1-c2c-install-cross-client-audit.md`

This audit is a current-state refresh. Several findings from the prior audit (#410 gemini fallback, #411 claude project-scope verifier, #334 default-project-scope, #412/#412b env-block centralisation, #405 crush deprecation) are partly landed; this doc reconciles "what's actually on master".

---

## 1. Entry points (master)

- Top-level command: `c2c install` — wired in `c2c.ml:5377` via `C2c_setup.install_default_term` (interactive TUI) plus subcommands.
- Per-client subcommand list: `install_subcommand_clients` (`c2c_setup.ml:1052`) → `claude, codex, codex-headless, opencode, kimi, crush, gemini`.
- `codex-headless` aliases to `codex` via `canonical_install_client` (`c2c_setup.ml:1046`).
- Dispatch: `do_install_client` (`c2c_setup.ml:1061`) → `setup_<client>`.
- TUI driver: `run_install_tui` (`c2c_setup.ml:1226`) — auto-detects per-client binary on PATH, defaults `do_it = on_path && not configured`.
- Install verifier: `client_configured` (`c2c_setup.ml:1112`) — used by both `detect_installation` and the doctor `check_plugin_installs` (`c2c.ml:1444`).
- Common args: `--alias`, `--broker-root`, `--target-dir`, `--force`, `--dry-run`, `--global` (`c2c_setup.ml:1311-1330`); `--global` is **claude-only** but lives at the common layer.

---

## 2. Per-client matrix (master HEAD)

| Property | claude | codex | opencode | kimi | gemini |
|---|---|---|---|---|---|
| `setup_<client>` line | 768 | 273 | 473 | 352 | 410 |
| Config path | `<proj>/.mcp.json` (default) or `~/.claude.json` (`--global`) | `~/.codex/config.toml` | `<cwd>/.opencode/opencode.json` (+ `c2c-plugin.json` sidecar + plugin symlink) | `~/.kimi/mcp.json` | `~/.gemini/settings.json` |
| Format | JSON | TOML (hand-rolled, no library) | JSON | JSON | JSON |
| Default scope | **project** (#334) | user | project (cwd) | user | user |
| Top-level config key | `mcpServers` | `[mcp_servers.c2c]` (TOML) | **`mcp`** (singular) | `mcpServers` | `mcpServers` |
| Env block key | `env` | `[mcp_servers.c2c.env]` | **`environment`** | `env` | `env` |
| Atomic write | yes (`tmp + rename`) | yes (`tmp + rename`, line 326-330) | yes (`json_write_file_or_dryrun`) | yes | yes |
| `--force` honored | yes | no — always rewrites stanza | yes — gates `opencode.json` overwrite (warns + skips) | no | no |
| Hook script installed | **yes** — `~/.claude/hooks/c2c-inbox-check.sh` + `settings.json:hooks.PostToolUse` matcher `^(?!mcp__).*` | no | no (TS plugin instead) | no | no |
| Plugin file | n/a | n/a | symlinks `data/opencode-plugin/c2c.ts` → `<proj>/.opencode/plugins/c2c.ts` AND `~/.config/opencode/plugins/c2c.ts` (`canonical_exists` gate, line 582) | n/a | n/a |
| `trust: true` flag | no | no | no | no | **yes** (line 437 — bypasses gemini per-tool confirmation) |
| `server_path` fallback | yes | yes | yes (via `opam exec --` always) | yes | **yes since #410** (was broken at the prior audit; line 422-425 now mirrors kimi) |

### Env vars written per client

| Env var | claude | codex | opencode | kimi | gemini |
|---|---|---|---|---|---|
| `C2C_MCP_BROKER_ROOT` | yes | yes | yes | yes | yes |
| `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` | yes | yes | yes | yes | yes |
| `C2C_AUTO_JOIN_ROLE_ROOM=1` | yes | yes | yes | yes | yes |
| `C2C_MCP_AUTO_REGISTER_ALIAS=<alias>` | **yes** | **NO** | **NO** | yes | yes |
| `C2C_MCP_SESSION_ID=<alias>` | **NO** | **NO** | **NO** | yes | yes |
| `C2C_MCP_CLIENT_TYPE` | no | **yes (`codex`)** | no | no | no |
| `C2C_MCP_AUTO_DRAIN_CHANNEL=0` | no | no | **yes (opencode-only)** | no | no |
| `C2C_CLI_COMMAND` | no | no | **yes (opencode-only, set via `current_c2c_command ()`)** | no | no |
| `C2C_MCP_CHANNEL_DELIVERY=1` | conditional (interactive prompt, default off — `prompt_channel_delivery`, `c2c_setup.ml:1215`) | no | no | no | no |

The asymmetry on `AUTO_REGISTER_ALIAS` / `SESSION_ID` is the same one called out in the prior audit (Section 2A/2B): codex/opencode defer identity to `c2c start` launch-time wiring, kimi/gemini bake it in at install, claude is the half-and-half outlier (sets ALIAS but not SESSION_ID). #412b on the `412b-env-builder-centralization` branch tightens this via an explicit `identity_mode = Install_sets_identity | Harness_sets_identity` policy but is **not on master**.

---

## 3. Per-client deep-dive

### claude — `setup_claude` (`c2c_setup.ml:768`)

**Writes:**
1. MCP server entry into `<proj>/.mcp.json` (default, #334) or `~/.claude.json` (`--global`). Project shape includes `"type": "stdio"`; global shape omits it (legacy convention, lines 791-797).
2. PostToolUse hook script body to `~/.claude/hooks/c2c-inbox-check.sh` (always, regardless of `--global`). Script body in `claude_hook_script` literal at line 640.
3. Hook registration in `~/.claude/settings.json:hooks.PostToolUse[].hooks[]`, matcher `^(?!mcp__).*`. Existing-matcher upgrade path at lines 890-906 (matcher upgraded if a registered hook entry has a wrong matcher).

**Verifies post-install:**
- `client_configured "claude"` (`c2c_setup.ml:1115-1125`) accepts EITHER `~/.claude.json` OR `<cwd>/.mcp.json` containing `mcpServers.c2c` (#411 — prior audit caught the bug where only the global file was checked).
- Hook-status string ("registered" / "matcher upgraded" / "script updated" / "already registered") emitted in JSON output.

**Footguns:**
- Hook script uses `c2c hook` not `exec c2c hook` (Node ECHILD bug — comment at line 648). Tested in `tests/test_c2c_install_claude_hook.py`.
- `claude_hook_script` is a raw heredoc literal — any future hook-body change needs the install run to re-write it. The `script_changed` check (line 846) detects drift but only fires on install, not on `c2c doctor`.
- `CLAUDE_CONFIG_DIR` env override resolves with symlink chase (max depth 10, lines 19-32). Untested path.
- `--global` retains the legacy global-scope behaviour but the install_common_args doc says "(claude only)" — silently a no-op for the other 4 clients (UX confusion).

### codex — `setup_codex` (`c2c_setup.ml:273`)

**Writes:**
- Hand-rolled TOML stanza into `~/.codex/config.toml`. Strips any existing `[mcp_servers.c2c*]` section by line-walking `String.split_on_char '\n'` (lines 285-301).
- Adds `[mcp_servers.c2c]` + `[mcp_servers.c2c.env]` + per-tool `[mcp_servers.c2c.tools.<name>]` with `approval_mode = "auto"`.

**Verifies post-install:**
- `client_configured "codex"` (`c2c_setup.ml:1126-1143`) — substring match for the literal string `[mcp_servers.c2c]` (no real TOML parser).

**Footguns:**
- `c2c_tools_list` (line 248) is **hand-maintained** and must stay in sync with `C2c_mcp.base_tool_definitions`. Comment at line 240 explicitly flags this. #412 added the 14 tools that were silently missing; that fix is on a feature branch (`7c9bd5d1`) but the master version of this list is still the longer one — confirm on next slice.
- Hand-rolled TOML section detection drops adjacent comments inside the c2c section (prior audit Section 2E).
- `--force` is not honoured — every install rewrites the stanza (idempotent but obliterates user edits to env vars).
- Per-tool `approval_mode = "auto"` writes a section per tool — verbose, no compaction. If a future codex release adds wildcard support, this stays verbose.
- No `C2C_MCP_AUTO_REGISTER_ALIAS` / `C2C_MCP_SESSION_ID`: managed sessions wire identity at launch (line 347 comment). Raw `codex` outside `c2c start` will not auto-register.

### opencode — `setup_opencode` (`c2c_setup.ml:473`)

**Writes:**
1. `<cwd>/.opencode/opencode.json` with top-level `mcp.c2c` entry (NOTE: `mcp` singular, `environment` not `env`).
2. `<cwd>/.opencode/c2c-plugin.json` sidecar with `{session_id, alias, broker_root}`.
3. Plugin symlink at `<cwd>/.opencode/plugins/c2c.ts` → `data/opencode-plugin/c2c.ts` (canonical) — and a global symlink at `~/.config/opencode/plugins/c2c.ts` to the same canonical source.
4. Falls back to **copy** instead of symlink when canonical source is missing (line 612-614 — used outside the c2c repo where no `data/opencode-plugin/c2c.ts` exists).

**Verifies post-install:**
- `client_configured "opencode"` (`c2c_setup.ml:1168-1179`) checks `<cwd>/.opencode/opencode.json` for `mcp.c2c`.
- `c2c doctor` `check_plugin_installs` (`c2c.ml:1444-1480`) classifies global plugin into `installed` / `stub (<1024 bytes)` / `not installed`. The stub-detection threshold is 1024 bytes (line 582 + 585 in setup_opencode mirror this).

**Footguns:**
- `--force` warns-but-does-something-different: when `c2c` already exists in `mcp`, it **skips opencode.json** but **still updates plugin + sidecar** (line 491-499, 506-515). Confusing intermediate state.
- Symlinks store the source as written (line 572 comment) — `make_symlink` fixes this by absoluting via cwd, but a non-c2c-repo install can't use the canonical source at all.
- Session ID is derived from `target_dir` basename (line 504): `opencode-<dirname>`. Two project dirs with the same basename collide silently.
- `C2C_MCP_AUTO_DRAIN_CHANNEL=0` is set explicitly (line 525) — opencode-only override; #412b drops it as stale but #412b is not on master.
- `C2C_CLI_COMMAND` is set to the install-time `current_c2c_command ()` value — pins the command path; if `~/.local/bin/c2c` is later moved/renamed, the env var goes stale.

### kimi — `setup_kimi` (`c2c_setup.ml:352`)

**Writes:**
- Single JSON file at `~/.kimi/mcp.json`. Standard `mcpServers.c2c` shape with `type: "stdio"`, `command: "opam"`, `args: ["exec", "--", <server_path>]`.
- Env: `BROKER_ROOT, SESSION_ID, AUTO_REGISTER_ALIAS, AUTO_JOIN_ROOMS, ROLE_ROOM`.

**Verifies post-install:**
- `client_configured "kimi"` (`c2c_setup.ml:1144-1155`) checks file presence + `mcpServers.c2c` membership.

**Footguns:**
- `--force` not honoured (silently overwrites c2c key under `mcpServers`).
- No fallback to bare `c2c-mcp-server` PATH command — always uses `opam exec --`. This is a real silent-fail when a user has installed `c2c-mcp-server` to PATH and uninstalled the opam switch (claude/codex/opencode use `resolve_mcp_server_paths` to pick whichever is available; kimi hardcodes `opam`).
- Bakes `C2C_MCP_SESSION_ID = <alias>` permanently — a kimi instance keeps the same SESSION_ID forever, unlike claude/codex/opencode which get a fresh one per `c2c start`.
- No `C2C_MCP_CLIENT_TYPE` — the broker can't telemetry-tag kimi sessions.

### gemini — `setup_gemini` (`c2c_setup.ml:410`)

**Writes:**
- `~/.gemini/settings.json`, top-level `mcpServers.c2c` shape (matches Claude Code) plus `trust: true`.
- Env: `BROKER_ROOT, SESSION_ID, AUTO_REGISTER_ALIAS, AUTO_JOIN_ROOMS, ROLE_ROOM`.

**Verifies post-install:**
- `client_configured "gemini"` (`c2c_setup.ml:1156-1167`) checks file + `mcpServers.c2c` membership.

**Footguns:**
- `trust: true` (line 437) **bypasses per-tool confirmation prompts** — security trade-off documented in the inline comment block at line 401-409.
- User-scope only; no `--scope=project` path. Multi-project users get one shared MCP entry.
- Requires `~/.gemini/oauth_creds.json` to exist (created by running `gemini` interactively once). The Human-mode output explicitly tells the user this (line 469) but the JSON output does not flag the precondition.
- `--force` not honoured.
- Like kimi, bakes `C2C_MCP_SESSION_ID = <alias>` permanently.

---

## 4. Hard-fail vs silent-fail (master)

**Hard-fail (exit 1):**
- Unknown client name in `do_install_client` (line 1090).
- `setup_opencode` target_dir doesn't exist (line 480).
- `do_install_self` can't find executable / can't write to dest (lines 96-98, 159-161).
- `resolve_mcp_server_paths` can't find `c2c-mcp-server` OR a `_build/` server binary (line 1037).

**Silent-success-but-broken (no rc, no warning):**
- codex hand-rolled TOML strips comments inside the c2c section.
- opencode `--force` skips opencode.json but still rewrites plugin + sidecar — partial state.
- kimi: no `c2c-mcp-server` PATH fallback; if opam isn't available the config is broken on next launch.
- All clients: `AUTO_JOIN_ROOMS` overwrites — a user who manually added a second room loses it on next install.
- gemini: depends on oauth_creds.json out-of-band; install succeeds even if gemini hasn't been run interactively yet.
- `--target-dir` is silently no-op for codex/kimi/gemini (#411 audit, Section 2H).
- `--global` is silently no-op for everything except claude.
- `client_configured` for codex is a string-substring match — can be fooled by a commented-out section (`# [mcp_servers.c2c]`).
- TUI auto-checkbox logic (`do_it = on_path && not configured`, line 1233) — `client_configured` returning false-positive means a re-install gets skipped.

**Soft warnings (printed but rc=0):**
- opencode: warning on existing c2c entry without `--force` (line 491-495).
- gemini: human-mode message about oauth_creds.json (line 469) — only prints when `output_mode = Human`.

---

## 5. Test coverage (master)

| Test file | Scope | Lines |
|---|---|---|
| `tests/test_c2c_install.py` | Wrapper-installation smoke (`install`/`install --target-dir`) + per-client `--dry-run` smoke for codex / kimi / opencode / crush / claude | 272 |
| `tests/test_c2c_install_claude_hook.py` | Hook-body regression: ECHILD-bug guard (no `exec c2c hook`) | 114 |
| `tests/test_c2c_install_stamp.py` | `~/.local/bin/.c2c-version` stamp file shape | 59 |
| `ocaml/cli/test_c2c_opencode_plugin_drift.ml` | Plugin-source drift between repo + installed copy | — |
| `ocaml/cli/test_c2c_onboarding.ml` | Relay setup (`c2c relay setup`), unrelated to MCP install | — |
| **`gemini`** | **No install test on master** (gemini is post-#406a, no per-client smoke yet) | — |

Dry-run tests (`test_install_dry_run_<client>`) only assert `[DRY-RUN]` lines appear in stdout; they don't parse `--json` output to verify env-var presence per the matrix above.

`test_install_dry_run_leaves_filesystem_unchanged` (line 253) checks four canonical config paths but excludes gemini's `~/.gemini/settings.json`.

The on-feature-branch `c2c_mcp_env.ml` (#412b) brings `test_c2c_mcp_env.ml` (87 lines) which is the closest thing to a per-client env-block contract test — it lives off-master.

---

## 6. Summary of drift since prior audit (2026-04-28)

| Slice | Status |
|---|---|
| Slice 1 (`C2C_MCP_CLIENT_TYPE` universal) | inflight on `412b-env-builder-centralization`, not master |
| Slice 2 (env-block helper) | same — inflight on `412b` |
| Slice 3 (gemini `server_path` fallback) | **landed via #410** (`ec1371a1`) — verified at line 422-425 |
| Slice 4 (per-client install integration tests) | partial: dry-run smoke landed in `test_c2c_install.py:212-251`; gemini still has no test |
| Slice 5 (`--scope` for all user-scope clients) | not started |

Crush deprecation (#405, `203b901e`) is a separate worktree branch — master still has `setup_crush` and `crush` in `install_subcommand_clients`. The user's request listed 5 clients (claude/codex/opencode/kimi/gemini), so this audit treats crush as out-of-scope.

---

## 7. Top three near-term ROI plays (fresh)

1. **Land #412b** (env-block centralisation). It already converges Slice 1+2 from the prior audit. Risk: low (pure refactor + `test_c2c_mcp_env.ml`).
2. **Add `c2c install gemini --dry-run --json` smoke test** to `tests/test_c2c_install.py` covering: `mcpServers.c2c.env` contains `BROKER_ROOT`, `SESSION_ID`, `AUTO_REGISTER_ALIAS`, `AUTO_JOIN_ROOMS=swarm-lounge`, `ROLE_ROOM=1`; top-level `trust: true`. ~30 lines.
3. **Strengthen `client_configured "codex"`** (`c2c_setup.ml:1126-1143`) — replace the substring match with a line-anchored check (start of line, no leading `#`) or a proper TOML parse. Today a single commented-out `# [mcp_servers.c2c]` line claims "configured".

---

## Appendix: command-name → handler line map (master)

| Path | Line |
|---|---|
| `c2c install` (group) | `c2c.ml:5377` |
| `install` default term (TUI) | `c2c_setup.ml:install_default_term` (search "default_term") |
| `install self` | `c2c_setup.ml:1332` |
| `install all` | `c2c_setup.ml:1382` (approx, via `install_all_subcmd`) |
| `install <client>` factory | `c2c_setup.ml:1351` |
| `install git-hook` | `c2c_setup.ml:1462` |
| `do_install_client` dispatch | `c2c_setup.ml:1061-1090` |
| `setup_codex` | `c2c_setup.ml:273` |
| `setup_kimi` | `c2c_setup.ml:352` |
| `setup_gemini` | `c2c_setup.ml:410` |
| `setup_opencode` | `c2c_setup.ml:473` |
| `setup_claude` | `c2c_setup.ml:768` |
| `setup_crush` (still on master) | `c2c_setup.ml:968` |
| `client_configured` verifier | `c2c_setup.ml:1112` |
| `claude_hook_script` literal | `c2c_setup.ml:640` |
| Common args (`--alias`, `--global`, etc.) | `c2c_setup.ml:1311-1330` |
| Doctor `check_plugin_installs` | `c2c.ml:1444-1492` |
