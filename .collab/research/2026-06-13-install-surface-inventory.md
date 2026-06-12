# c2c Install Surface — Complete Inventory (2026-06-13)

Basis for the uninstall/manifest design (`.collab/design/2026-06-13-uninstall-and-install-manifest-spec.md`).
Mapped by an Explore subagent over `ocaml/cli/c2c_setup.ml`, `ocaml/cli/c2c.ml`,
`ocaml/c2c_start.ml`, `ocaml/cli/c2c_kimi_hook.ml`, `justfile`.
Anchors are `file:function`. **OWNED** = c2c is sole writer (delete on uninstall). **SHARED** =
c2c injects a key/stanza/block into a user-owned file (surgically remove only the c2c part).

## Cross-cutting facts
- **No backup is ever made** before config edits (atomic-rename overwrite, no pre-image).
- **No uninstall/teardown/cleanup logic exists** anywhere — greenfield.
- `--dry-run` today only prints per-write `[DRY-RUN] would write …` lines
  (`json_write_file_or_dryrun`, `mkdir_or_dryrun`, kimi-hook helpers) — no consolidated summary.
- Idempotent re-install: every client setup filters out the prior `c2c` key before re-adding
  (`List.filter (fun (k,_) -> k <> "c2c")`), so the surgical removal target is uniformly the
  `c2c` entry under the server map.

## self — `do_install_self` (`c2c_setup.ml:do_install_self`)
- OWNED `~/.local/bin/c2c` (whole-file copy); `~/.local/bin/c2c-mcp-server` only if `--mcp-server`.
- Triggers git-shim creation via `C2c_start.ensure_swarm_git_shim_installed` (best-effort).
- Does NOT write the kimi approval hook (stale comment in `c2c_kimi_hook.ml`); that's `setup_kimi`.

## git-shim — `c2c_start.ml:ensure_swarm_git_shim_installed` / `install_pre_reset_shim` / `write_git_shim_atomic`
Shim dir = `$C2C_GIT_SHIM_DIR` else `$XDG_STATE_HOME/c2c/bin` else `~/.local/state/c2c/bin`
(`c2c_start.ml:swarm_git_shim_dir`).
- OWNED `<shim_dir>/git` (attribution shim; execs git-pre-reset), `<shim_dir>/git-pre-reset`
  (cp of repo `git-shim.sh`).
- OWNED per-instance duplicates on every `c2c start`: `~/.local/share/c2c/instances/<name>/bin/{git,git-pre-reset}`
  (instances dir via `C2C_INSTANCES_DIR`, `c2c_start.ml:instances_dir`).
- PATH prepend for managed sessions is process-env only (`build_inner_env`) — no rc file written.

## claude — `setup_claude` (+ inline hook logic; `configure_claude_hook` is a dead alt copy)
Claude dir = `CLAUDE_CONFIG_DIR` else `~/.claude` (`resolve_claude_dir`).
- SHARED MCP stanza `mcpServers.c2c`: project `.mcp.json` (default, includes `"type":"stdio"`)
  AND/OR global `~/.claude.json` (`--global`). Verifier `client_configured` checks both.
- OWNED hook scripts `~/.claude/hooks/{c2c-inbox-check.sh,c2c-stop-deliver.sh}`.
- SHARED `~/.claude/settings.json`: `hooks.PostToolUse[]` + `hooks.Stop[]` entries whose
  `hooks[].command` == the two script paths; `hooks.PreToolUse[]` entry with sentinel
  `matcher:"__C2C_PREAUTH_DISABLED__"` → `~/.local/bin/c2c-kimi-approval-hook.sh` (opt-in).
- Env in `mcpServers.c2c.env`: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_AUTO_REGISTER_ALIAS`,
  `C2C_MCP_AUTO_DRAIN_CHANNEL=0`, `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`, `C2C_AUTO_JOIN_ROLE_ROOM=1`,
  opt `C2C_MCP_CHANNEL_DELIVERY=1`, opt `C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN=1`.

## codex (codex-headless→codex) — `setup_codex`
- SHARED `~/.codex/config.toml`: strips existing `[mcp_servers.c2c*]` then appends
  `[mcp_servers.c2c]`, `[mcp_servers.c2c.env]`, one `[mcp_servers.c2c.tools.<tool>]` per tool.
  Surgical removal: strip every section whose header starts `mcp_servers.c2c`.
- Env: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_CLIENT_TYPE=codex`, `C2C_MCP_AUTO_DRAIN_CHANNEL=0`,
  `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`, `C2C_AUTO_JOIN_ROLE_ROOM=1`, opt `…FROM_AUTO_GEN=1`.
  (No `C2C_MCP_AUTO_REGISTER_ALIAS` — alias is launch-time.)
- OWNED deliver-watch `~/.c2c/clients/codex/{deliver-watch.sh,start-hooks/pre-deliver.sh}` (+ runtime
  pid/log/session-id). `--no-deliver-watch` unlinks the two scripts.

## kimi — `setup_kimi`/`build_kimi_mcp_config` + `c2c_kimi_hook.ml`
- SHARED `~/.kimi/mcp.json` → `mcpServers.c2c` (`allowedTools`). Verifier checks `mcpServers.c2c`.
- Env: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_AUTO_DRAIN_CHANNEL=0`,
  `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`, `C2C_AUTO_JOIN_ROLE_ROOM=1`, opt `…FROM_AUTO_GEN=1`.
- OWNED `~/.local/bin/c2c-kimi-approval-hook.sh` (`c2c_kimi_hook.ml:install_approval_hook_script`).
- SHARED `~/.kimi/config.toml`: enveloped `[[hooks]]` block between
  `# c2c-managed:BEGIN preuse-approval-hook-142` … `# c2c-managed:END preuse-approval-hook-142`
  (`approval_hook_block_id`); legacy marker `# c2c-managed PreToolUse hook (#142)`
  (`toml_block_legacy_marker`); ships fully commented (opt-in).
- OWNED deliver-watch `~/.c2c/clients/kimi/{deliver-watch.sh,start-hooks/pre-deliver.sh}` (Human branch).

## opencode — `setup_opencode`
Target = `--target-dir` else cwd; config `<target>/.opencode`.
- SHARED `<target>/.opencode/opencode.json` → `mcp.c2c` (`type:"local"`, command, environment,
  enabled). Guard: if `mcp.c2c` present and not `--force`, skips json (still updates plugin+sidecar).
- Env in `mcp.c2c.environment`: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_AUTO_DRAIN_CHANNEL=0`,
  `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge`, `C2C_CLI_COMMAND=<resolved c2c>`, `C2C_AUTO_JOIN_ROLE_ROOM=1`,
  opt `…FROM_AUTO_GEN=1`.
- OWNED sidecar `<target>/.opencode/c2c-plugin.json`.
- OWNED plugin `<target>/.opencode/plugins/c2c.ts`: symlink→repo `data/opencode-plugin/c2c.ts` in dev
  (`find_canonical_plugin_from_target`), else embedded-blob write. Uninstall must unlink either way.
- OWNED deliver-watch `~/.c2c/clients/opencode/{deliver-watch.sh,start-hooks/pre-deliver.sh}`.

## crush (deprecated, still writes) — `setup_crush`
- SHARED `~/.config/crush/crush.json` → `mcpServers.c2c`. OWNED `~/.c2c/clients/crush/{…}`.

## gemini (deprecated; `do_install_client` refuses w/ exit 1) — `setup_gemini` (dead at entrypoint)
- Would write `~/.gemini/settings.json` → `mcpServers.c2c` (+ `trust:true`), `~/.c2c/clients/gemini/`.
- Uninstall completeness: legacy installs may still have these — recompute path should clean them.

## cross-client wake schedule — `ensure_default_wake_schedule`
- After every successful client install: OWNED `<schedule_root>/<alias>/wake.toml`
  (`C2c_mcp.schedule_base_dir alias`//`wake`; `c2c_mcp_helpers.ml:schedule_base_dir`/`schedule_entry_path`),
  interval 246s, idle-gated; skipped if exists. Keyed by install-time alias → uninstall needs the alias.

## git-hook — `do_install_git_hook`
- Source `<repo_parent>/.c2c/hooks/pre-commit.sh`. Writes `<git-common-dir>/hooks/pre-commit`
  (whole-file copy + chmod 755). No embedded marker → uninstall compares against source before removing.

## justfile `just bi`/`install-all` (dev toolchain — distinct from `c2c install`)
- OWNED `~/.local/bin/{c2c,c2c-mcp-server,c2c-mcp-inner,c2c-inbox-hook-ocaml,c2c-cold-boot-hook,
  c2c-post-compact-hook,cc-quota,c2c-deliver-inbox}` (flock `~/.local/bin/.c2c-install.lock`).
- OWNED stamp `~/.local/bin/.c2c-version` (`scripts/c2c-install-stamp.sh`; override `C2C_INSTALL_STAMP`).
- `install-git-hooks`: symlink `<git-common-dir>/hooks/<name>` → `realpath(scripts/git-hooks/<name>)`
  for `pre-commit`,`pre-push` — DIFFERENT mechanism/source than `c2c install git-hook`. Uninstall must
  distinguish symlink-into-`scripts/git-hooks` (justfile) vs copy-from-`.c2c/hooks` (subcommand).
- `install-gui`: `~/.local/bin/c2c-gui` (if built).

## Uninstall cheatsheet (path × disposition)
OWNED (delete): the `~/.local/bin/*` binaries + `.c2c-version`; `$XDG_STATE_HOME/c2c/bin/{git,git-pre-reset}`
(+ instances `*/bin/{git,git-pre-reset}`); `~/.c2c/clients/<client>/` trees;
`~/.claude/hooks/{c2c-inbox-check.sh,c2c-stop-deliver.sh}`; `<target>/.opencode/{c2c-plugin.json,plugins/c2c.ts}`;
`<schedule_root>/<alias>/wake.toml`; `~/.local/bin/c2c-kimi-approval-hook.sh`.
SHARED (strip c2c key/block only): `.mcp.json`/`~/.claude.json` `mcpServers.c2c`;
`~/.claude/settings.json` hook entries; `~/.codex/config.toml` `[mcp_servers.c2c*]`;
`~/.kimi/mcp.json` `mcpServers.c2c` + `~/.kimi/config.toml` managed block;
`<target>/.opencode/opencode.json` `mcp.c2c`; `~/.config/crush/crush.json` + legacy `~/.gemini/settings.json`;
`.git/hooks/{pre-commit,pre-push}` (verify c2c-owned first).
Injected env-var union (for the "what was installed" report): `C2C_MCP_BROKER_ROOT`,
`C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_AUTO_REGISTER_ALIAS_FROM_AUTO_GEN`, `C2C_MCP_AUTO_DRAIN_CHANNEL`,
`C2C_MCP_AUTO_JOIN_ROOMS`, `C2C_AUTO_JOIN_ROLE_ROOM`, `C2C_MCP_CLIENT_TYPE`(codex), `C2C_CLI_COMMAND`(opencode),
`C2C_MCP_CHANNEL_DELIVERY`(claude opt-in).
