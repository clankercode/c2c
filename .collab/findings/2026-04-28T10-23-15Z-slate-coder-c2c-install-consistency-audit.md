# `c2c install` consistency audit — c2c_setup.ml

- **Author**: slate-coder
- **Timestamp (UTC)**: 2026-04-28T10:23:15Z
- **Target**: `ocaml/cli/c2c_setup.ml` @ master `c6ac8924`
- **Type**: research / findings (no code changes)
- **Scope**: `setup_claude`, `setup_codex`, `setup_kimi`, `setup_gemini`, `setup_opencode`, `setup_crush` and the matching `client_configured` verifier branches.

## TL;DR

Six client setup paths grew organically and diverged on five axes that
matter to operators: env-var vocabulary, `command`/`args` shape (and
whether `opam exec --` wraps the server), config scope (project vs
home), JSON-merge semantics, and verify-side parity with the writer.
The clearest convergence wins are: (a) a single shared `env` builder so
`C2C_MCP_SESSION_ID` / `C2C_MCP_AUTO_REGISTER_ALIAS` /
`C2C_MCP_CLIENT_TYPE` stop drifting per client; (b) a single shared
`mcp_command/args` builder that already-knows the `c2c-mcp-server` vs
`opam exec -- <path>` rule; (c) parity between `setup_*` and
`client_configured` (opencode in particular checks the wrong key
*shape* relative to what it writes — `mcp` not `mcpServers`, but the
opencode write also uses `mcp`, so that one is actually fine; the
real asymmetry is gemini/claude global scope, see Dimension 8).

---

## 1. Config-path resolution

| Client   | Path                                                          | Scope        | Env override                | Notes |
| -------- | ------------------------------------------------------------- | ------------ | --------------------------- | ----- |
| claude   | `<claude_dir>/.claude.json` (global) OR `<project>/.mcp.json` | user OR proj | `CLAUDE_CONFIG_DIR` (in `resolve_claude_dir`) | only client with `--global`/`--target-dir` flags |
| codex    | `~/.codex/config.toml`                                        | user         | none                        | TOML, not JSON |
| kimi     | `~/.kimi/mcp.json`                                            | user         | none                        | |
| gemini   | `~/.gemini/settings.json`                                     | user         | none                        | comment claims "user-scope by precedent" |
| opencode | `<target_dir>/.opencode/opencode.json`                        | project      | `--target-dir`              | also writes `<target>/.opencode/c2c-plugin.json` sidecar + `<target>/.opencode/plugins/c2c.ts` symlink + global plugin symlink at `~/.config/opencode/plugins/c2c.ts` |
| crush    | `~/.config/crush/crush.json`                                  | user (XDG)   | none (does not honour `XDG_CONFIG_HOME`) | |

**Inconsistencies**:

- Three different "where home stuff lives" conventions: dotfile-in-home
  (`~/.codex`, `~/.kimi`, `~/.gemini`), XDG-ish
  (`~/.config/crush/`), and an explicit env-overridable resolver
  (`resolve_claude_dir`). Only claude honours an env override; only
  opencode honours a project-scope flag; codex/kimi/gemini/crush
  silently force user scope.
- `setup_crush` hardcodes `~/.config/crush` instead of
  `Sys.getenv "XDG_CONFIG_HOME"` with fallback. Minor, but breaks
  XDG-strict environments.
- The `target_dir`/`--target-dir` arg is plumbed to opencode only,
  even though claude has the same project/global concept (it uses a
  separate `--global` boolean). Two flags for the same axis.

## 2. JSON-merge semantics

| Client   | Read-existing | If non-JSON          | Preserves siblings | Replaces own entry | Section key |
| -------- | ------------- | -------------------- | ------------------ | ------------------ | ----------- |
| claude   | yes           | falls through to `_` arm → drops everything | yes (`mcpServers`-only filter) | yes           | `mcpServers` |
| codex    | textual line strip on `[mcp_servers.c2c*` | preserves rest verbatim | yes | yes | TOML section |
| kimi     | yes           | falls through to `_` arm → drops everything | yes | yes | `mcpServers` |
| gemini   | yes           | falls through to `_` arm → drops everything | yes | yes | `mcpServers` |
| opencode | yes           | falls through to `_` arm; `should_write_config` guard refuses overwrite without `--force` | yes | only when `--force` or no existing c2c entry | `mcp` (NOT `mcpServers`) |
| crush    | yes           | falls through to `_` arm → drops everything | yes | yes | `mcpServers` |

**Inconsistencies**:

- **Destructive non-JSON path** (claude/kimi/gemini/crush): if the
  user's existing `settings.json`/`mcp.json` is malformed JSON,
  `json_read_file` raises, the surrounding `try` is shallow, and the
  fallback to `_ -> Assoc[mcpServers...]` *replaces the entire file*
  with just the c2c entry. Codex's textual approach is safer here —
  it preserves whatever was there. None of the JSON paths take a
  backup before overwriting.
- **Section-key drift**: opencode uses `mcp`, every other JSON client
  uses `mcpServers`. Opencode is consistent within itself
  (write+read both use `mcp`), so this is by-design but it means
  `client_configured` cannot share a single helper across clients.
- Only opencode has a "don't clobber existing c2c entry without
  `--force`" guard; the other writers replace c2c silently. With
  `--force` documented but not implemented for non-opencode clients,
  the `--force` flag in `install_common_args` is a no-op for codex,
  kimi, gemini, crush. (Claude *does* receive `~force` but only uses
  it in the human-mode `force_str` echo at the end — it doesn't
  actually gate the rewrite either.)

## 3. Env vars set per-client

Reference set per audit prompt: `C2C_MCP_BROKER_ROOT`, `C2C_MCP_SESSION_ID`, `C2C_MCP_AUTO_REGISTER_ALIAS`, `C2C_MCP_AUTO_JOIN_ROOMS`, `C2C_AUTO_JOIN_ROLE_ROOM`.

| Var                          | claude | codex | kimi | gemini | opencode | crush |
| ---------------------------- | :----: | :---: | :--: | :----: | :------: | :---: |
| `C2C_MCP_BROKER_ROOT`        | yes    | yes   | yes  | yes    | yes      | yes   |
| `C2C_MCP_SESSION_ID`         | **NO** | **NO**| yes  | yes    | **NO**   | yes   |
| `C2C_MCP_AUTO_REGISTER_ALIAS`| yes    | **NO**| yes  | yes    | **NO**   | yes   |
| `C2C_MCP_AUTO_JOIN_ROOMS`    | yes    | yes   | yes  | yes    | yes      | yes   |
| `C2C_AUTO_JOIN_ROLE_ROOM`    | yes    | yes   | yes  | yes    | yes      | yes   |
| `C2C_MCP_CHANNEL_DELIVERY`   | conditional (only if `--channel-delivery` chosen) | — | — | — | — | — |
| `C2C_MCP_CLIENT_TYPE`        | —      | yes (`"codex"`) | — | — | — | — |
| `C2C_MCP_AUTO_DRAIN_CHANNEL` | —      | —     | —    | —      | yes (`"0"`) | — |
| `C2C_CLI_COMMAND`            | —      | —     | —    | —      | yes      | —     |

**Inconsistencies**:

- **claude omits `C2C_MCP_SESSION_ID`**: the broker derives session
  identity from `CLAUDE_SESSION_ID` for claude, so it is intentional
  — but undocumented in the file and a footgun for any future
  Codex/Gemini-style child-process hijack scenario.
- **codex omits both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS`**.
  The codex human-mode banner explicitly says "shared MCP config
  only; managed sessions set identity at launch", so this is
  by-design (codex sets identity per-instance via `c2c start codex`
  env injection). However, that means the *standalone* `codex`
  session — somebody who runs the bare client without `c2c start` —
  will get an unregistered MCP session. Same shape as claude, but
  unlike claude it has *no* fallback (claude has the alias env
  baked into the global `.claude.json`).
- **opencode omits `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS`** —
  intentionally; the OC plugin reads them from the sidecar
  (`c2c-plugin.json`) at runtime, since session id is derived from
  `target_dir` (`opencode-<dirname>`). This is unique to opencode.
- **`C2C_MCP_CLIENT_TYPE` is set only on codex.** The broker can
  use this to differentiate behavior; no other client writes it,
  so client-type-aware code paths can only key on codex right now.
  Either remove it (if unused) or set it for everyone.
- **`C2C_MCP_AUTO_DRAIN_CHANNEL=0` only on opencode.** Per CLAUDE.md,
  the broker now defaults to `0`, so this is redundant — historical
  artifact.
- **`C2C_CLI_COMMAND` only on opencode.** The OC plugin uses it to
  shell out to `c2c`; if other clients ever need to call back to the
  CLI, they'd need the same wiring.

## 4. server-path arg

| Client   | `command`             | `args`                                         |
| -------- | --------------------- | ---------------------------------------------- |
| claude   | `mcp_command` (= `c2c-mcp-server` if installed, else `opam`) | `[]` if `c2c-mcp-server`, else `["exec","--",server_path]` |
| codex    | `c2c-mcp-server` OR `opam` (same logic) | `[]` OR `["exec","--",server_path]` |
| kimi     | always `opam`         | `["exec","--",server_path]`                    |
| gemini   | always `c2c-mcp-server` | `[]` (server_path **ignored** — `~server_path:_`) |
| opencode | always `opam`         | `["exec","--",server_path]` (note: `command` is a list-form including the binary) |
| crush    | always `opam`         | `["exec","--",server_path]`                    |

**Inconsistencies**:

- Two clients (claude, codex) use the smart "prefer installed binary,
  fall back to `opam exec`" logic. Three clients (kimi, opencode,
  crush) hardcode the `opam exec --` wrapper. Gemini hardcodes the
  *opposite* — assumes `c2c-mcp-server` is on PATH and discards
  `server_path` entirely.
- Gemini's discard of `server_path` means: if `c2c-mcp-server` is
  *not* on PATH, gemini will fail at MCP server startup, while
  claude/codex would still work via the opam fallback. The argument
  shape (`server_path:_` ignored) is a real bug surface — the
  `resolve_mcp_server_paths` resolver picked a path for a reason.
- Kimi/opencode/crush will needlessly invoke `opam exec --` even
  when `c2c-mcp-server` is on PATH, adding ~100ms of opam overhead
  per launch. Cosmetic, but uniform shape would be nicer.

## 5. trust / confirmation bypass

| Client   | Bypass mechanism                                              |
| -------- | ------------------------------------------------------------- |
| claude   | none in config; relies on operator passing `--strict-mcp-config` or accepting prompts; PostToolUse hook + `C2C_MCP_CHANNEL_DELIVERY` flag enable push delivery. |
| codex    | Per-tool `[mcp_servers.c2c.tools.<tool>] approval_mode = "auto"` for the 19 tools in `c2c_tools_list`. |
| kimi     | none. Operator must approve interactively (or kimi's harness handles it). |
| gemini   | `"trust": true` at server level — bypasses *all* tool prompts. |
| opencode | not needed at config level — OC plugin runs in-process. |
| crush    | none. Status: experimental. |

**Inconsistencies**:

- Three different bypass strategies (per-tool allowlist, server-level
  trust, in-process plugin) and two clients with no bypass at all
  (claude config-level, kimi, crush). For an operator running a
  swarm, that is operator-visible: every fresh kimi session prompts
  on first send.
- Codex's `c2c_tools_list` is a hand-maintained list of 19 tools.
  When a new MCP tool is added (e.g. `memory_write`,
  `set_room_visibility`, `dnd_status`, `check_pending_reply`,
  `clear_compact`, etc. — see the deferred MCP tool catalog), this
  list silently goes stale and the new tool will start prompting.
  **This list is already stale today** — comparing to the deferred
  tool catalog visible in this session, it lacks `memory_*`,
  `set_dnd`, `set_room_visibility`, `delete_room`, `prune_rooms`,
  `set_compact`, `clear_compact`, `check_pending_reply`,
  `open_pending_reply`, `stop_self`, `debug`, `tail_log`,
  `send_room_invite`. That is ~13 missing tools.

## 6. dry-run shape

All six setup functions thread `~dry_run` and use
`json_write_file_or_dryrun` (or, in codex, an ad-hoc
`Printf.printf "[DRY-RUN] would write %d bytes…"`).

**Inconsistencies**:

- Codex prints a single-line byte count; the JSON helpers print one
  line per file written. Operators piping `--dry-run --json` get
  different shapes per client.
- Opencode's plugin install path also uses `[DRY-RUN] would copy %d
  bytes…` and `[DRY-RUN] would symlink…` lines, so an opencode
  dry-run produces 3-5 dry-run lines while claude/codex/kimi/gemini/crush
  produce 1-2.
- None of the dry-run paths emit a final structured "would-write"
  summary in `--json` mode; the JSON success object is printed
  unconditionally at the end of each setup function whether or not
  anything was actually written. So a `--json --dry-run` looks like
  a successful install in JSON.

## 7. JSON output shape

Common keys across clients (when `--json`):

| Key            | claude | codex | kimi | gemini | opencode | crush |
| -------------- | :----: | :---: | :--: | :----: | :------: | :---: |
| `ok`           | yes    | yes   | yes  | yes    | yes      | yes   |
| `client`       | yes    | yes   | yes  | yes    | yes      | yes   |
| `alias`        | yes    | yes   | yes  | yes    | yes      | yes   |
| `broker_root`  | yes    | yes   | yes  | yes    | yes      | yes   |
| `config`       | yes    | yes   | yes  | yes    | yes      | yes   |
| `scope`        | yes    | —     | —    | —      | —        | —     |
| `hook_status`  | yes    | —     | —    | —      | —        | —     |
| `trust`        | —      | —     | —    | yes    | —        | —     |
| `session_id`   | —      | —     | —    | —      | yes      | —     |
| `plugin`       | —      | —     | —    | —      | yes      | —     |

**Inconsistencies**:

- Five common keys are shared, but kimi/crush emit *only* the
  common five — no client-specific extras even where they would be
  useful (`server_path`, for example, is not in any output).
- `scope` is claude-only but is meaningful for opencode (project
  scope) and would help operators distinguish a project-local
  install. `server_path` (which one was actually wired) is in nobody's
  JSON but appears in every client's human output.

## 8. `client_configured` symmetry with writes

| Client   | Writer path                                                | Verifier path                                | Symmetric? |
| -------- | ---------------------------------------------------------- | -------------------------------------------- | ---------- |
| claude   | `<claude_dir>/.claude.json` (global) or `<proj>/.mcp.json` (project) | `~/.claude.json` only — does NOT honour `CLAUDE_CONFIG_DIR`, does NOT check project-scoped `.mcp.json` | **NO** |
| codex    | `~/.codex/config.toml`                                     | `~/.codex/config.toml`, substring scan for `[mcp_servers.c2c]` | yes (substring is loose but adequate) |
| kimi     | `~/.kimi/mcp.json`                                         | `~/.kimi/mcp.json`, key `mcpServers.c2c`     | yes |
| gemini   | `~/.gemini/settings.json`                                  | `~/.gemini/settings.json`, key `mcpServers.c2c` | yes |
| opencode | `<target>/.opencode/opencode.json`, key `mcp.c2c`          | `<cwd>/.opencode/opencode.json`, key `mcp.c2c` | yes if cwd == target_dir; **NO** if user installed with `--target-dir` elsewhere |
| crush    | `~/.config/crush/crush.json`                               | `~/.config/crush/crush.json`, key `mcpServers.c2c` | yes |

**Critical gap**:

- **Claude project-scope install is invisible to `client_configured`.**
  An operator who runs `c2c install claude` (default = project
  scope) and then runs `c2c install` (TUI) or `c2c install all`
  will see claude reported as "not configured" because the verifier
  only inspects `~/.claude.json`. This causes `install all` to
  re-install over the top, and the TUI to suggest claude even
  though it works fine in this project. The verifier should check
  *both* `<cwd>/.mcp.json` and `~/.claude.json` (and ideally also
  `<claude_dir>/.claude.json` when `CLAUDE_CONFIG_DIR` is set).

- **Opencode verifier hardcodes `Sys.getcwd ()`.** A user who
  installed opencode from one project and then runs `c2c list`-style
  status from another will see opencode as not configured. Could
  also affect TUI flow; minor since opencode is project-scoped by
  design.

- The `client_configured` switch silently returns `false` for
  `codex-headless` even though `codex-headless` shares the codex
  TOML — the writer path normalises (line 1085 covers both), but
  there is no `gemini`/`opencode-headless` style alias. Fine today,
  worth a comment.

## 9. `force` flag

| Client   | Accepts `~force` parameter? | Actually uses it? |
| -------- | --------------------------- | ----------------- |
| claude   | yes                         | only echoed in the trailing human-mode hint; *does not gate the file rewrite* — claude unconditionally replaces its `c2c` entry. |
| codex    | no                          | n/a — unconditional rewrite |
| kimi     | no                          | n/a — unconditional rewrite |
| gemini   | no                          | n/a — unconditional rewrite |
| opencode | yes (default `false`)       | yes — gates `should_write_config` and the bare-c2c-entry warning |
| crush    | no                          | n/a — unconditional rewrite |

**Inconsistency**: `--force` is documented in
`install_common_args ()` ("Overwrite existing configuration") but
only opencode checks for an existing entry before writing, so
`--force` is a no-op for codex/kimi/gemini/crush, and for claude it
only affects the trailing hint string. The flag advertises a
behaviour it does not deliver for 4-of-6 clients.

## 10. `c2c install --help` cross-reference

`install_client_subcmd` (l. 1310) builds every client subcommand from
the same `install_common_args` Term, so every client's
`c2c install <client> --help` advertises:

  `--alias / -a`, `--broker-root / -b`, `--target-dir / -t`,
  `--force / -f`, `--dry-run / -n`, `--global`

The `--global` doc-string explicitly says "(claude only)" — but
`--target-dir` is also effectively claude+opencode only, with no
caveat. `--force` is honored only by opencode (and partially by
claude). So the help text overpromises uniformity.

`init_configurable_clients` includes `codex-headless` separately
from `codex` (l. 1026), but `install_subcommand_clients` also lists
`codex-headless` (l. 1023), and the dispatcher
`canonical_install_client` collapses it to `codex` (l. 1017-1019).
Net effect: `c2c install codex-headless` works and writes the same
codex config. Cosmetically OK; might confuse operators who expect a
distinct headless config.

---

## Summary matrix

| Dimension | Single-source helper exists? | Drift severity |
| --------- | :--------------------------: | :------------- |
| 1. Config path resolution | no  | medium — XDG miss in crush; mixed user/project scopes |
| 2. JSON merge             | no  | **high** — non-JSON existing files clobbered on 4 clients |
| 3. Env vars               | no  | **high** — `C2C_MCP_SESSION_ID` set inconsistently; stale `AUTO_DRAIN` |
| 4. server-path / command  | partially (`resolve_mcp_server_paths`) | **high** — gemini ignores resolved path |
| 5. Trust bypass           | no  | medium — codex tool list stale; kimi has no bypass |
| 6. Dry-run                | partial (`json_write_file_or_dryrun`) | low |
| 7. JSON shape             | no  | low — 5 common keys, divergent extras |
| 8. `client_configured`    | no  | **high** — claude project-scope invisible; opencode cwd-only |
| 9. `--force`              | flag yes, behavior partial | medium — advertised, not delivered for 4 clients |
| 10. `--help`              | shared term | low — overpromises |

---

## Convergence candidates (prioritized)

### P1 — `client_configured` symmetry with writers (Dimension 8)

**Rule**: every writer path that produces a config file must have a
verifier that checks the *same* file and key path the writer used.
Claude's verifier should consult both project (`<cwd>/.mcp.json`) and
global (`<claude_dir>/.claude.json`) paths, not just the global one.
**Impact**: fixes a real bug today — `c2c install all` re-prompts
claude installs that already work; `c2c install` TUI mis-reports
state. Highest user-facing severity.

### P2 — Single env builder, with a per-client override hook (Dimension 3)

**Rule**: introduce `let common_env ~root ~alias ~client_type =
[ BROKER_ROOT; SESSION_ID; AUTO_REGISTER_ALIAS; AUTO_JOIN_ROOMS;
AUTO_JOIN_ROLE_ROOM; CLIENT_TYPE ]` and let each `setup_*` add only
the genuinely-client-specific extras (claude's
`C2C_MCP_CHANNEL_DELIVERY`, opencode's `C2C_CLI_COMMAND`). Document
*why* claude and codex omit `C2C_MCP_SESSION_ID` (= harness sets
it at launch) inline; if that's actually the right behavior, gate
it with an explicit `~harness_sets_identity:true` flag rather than
implicit per-client divergence. Drop the redundant
`C2C_MCP_AUTO_DRAIN_CHANNEL=0` from opencode (broker default
matches). **Impact**: kills a whole class of "why doesn't my codex
session register?" footguns and shrinks each setup function ~10
lines.

### P3 — Single `mcp_command/args` builder, used by everyone (Dimension 4)

**Rule**: `let mcp_invocation server_path mcp_command = if mcp_command
= "c2c-mcp-server" then ("c2c-mcp-server", []) else ("opam", ["exec";
"--"; server_path])`. Apply uniformly. Specifically, **gemini must
stop discarding `server_path`** — that is a real failure mode if
`c2c-mcp-server` is not on PATH. Kimi/opencode/crush should adopt the
"prefer installed binary" optimisation. **Impact**: removes a
silent gemini-breakage path; saves ~100ms per cold start on three
clients; one fewer divergence to maintain.

### P4 — JSON merge: handle non-JSON existing files non-destructively (Dimension 2)

**Rule**: when `json_read_file` raises, *do not* fall through to a
fresh-document write. Instead, emit a clear error
("existing config at PATH is not valid JSON; refusing to overwrite —
back it up and retry, or pass `--force-replace`"). Codex's
text-strip approach is also acceptable as a model. **Impact**:
prevents data loss from a single corrupted `settings.json`. Low
incidence, high blast radius.

### P5 — Make `--force` actually do something on the four no-op clients (Dimension 9)

**Rule**: every non-opencode setup should check for an existing
`c2c` entry; without `--force`, warn and skip the rewrite. With
`--force`, replace. Brings codex/kimi/gemini/crush in line with
opencode and with the `install_common_args` doc-string. **Impact**:
flag stops being a lie; protects operator-customised env var
overrides (e.g. someone hand-edited `C2C_NUDGE_IDLE_MINUTES` into
their `~/.kimi/mcp.json`).

### P6 — Refresh codex `c2c_tools_list` and document the maintenance contract (Dimension 5)

**Rule**: derive `c2c_tools_list` from a single source of truth
(MCP server's tool registration), or at minimum add a comment
pointing at the canonical source and a CI check. Today the list
omits ~13 tools. **Impact**: codex sessions stop prompting on every
new tool; one less divergence between codex (per-tool auto) and
opencode/gemini (whole-server trust).

### P7 — Uniform JSON output: add `server_path`, `scope`, `dry_run` to every client's success object (Dimension 7)

**Rule**: every `--json` success object includes `ok`, `client`,
`alias`, `broker_root`, `config`, `server_path`, `scope`
(`"global"|"project"|"user"`), `dry_run`. Client-specifics
(`hook_status`, `trust`, `session_id`, `plugin`) remain client-keyed.
**Impact**: `c2c install all --json --dry-run` becomes scriptable.

### P8 — XDG-correct crush path (Dimension 1)

**Rule**: `setup_crush` should honour `XDG_CONFIG_HOME` with
fallback to `~/.config`. Two-line fix. **Impact**: tiny but
removes one easy gotcha for XDG-strict users.

---

## Open questions for the next slice

1. Is `C2C_MCP_CLIENT_TYPE` actually consumed by the broker today?
   If not, either remove from codex or set everywhere.
2. Should claude project-scope installs *also* write the alias/session
   env vars (currently they are inherited from `c2c start`'s env, not
   the config), or is the harness-sets-identity contract intentional?
3. Should `c2c install --target-dir` work for claude project-scope
   installs (currently `target_dir_opt` is plumbed to claude as
   `~project_dir` but the help text says "opencode/claude project
   config" — this is OK today, just under-tested)?
4. Should there be a `c2c install verify <client>` subcommand that
   round-trips writer→verifier symmetry as an explicit test surface?

## File:function reference

- `c2c_setup.ml:252  setup_codex`
- `c2c_setup.ml:331  setup_kimi`
- `c2c_setup.ml:389  setup_gemini`
- `c2c_setup.ml:444  setup_opencode`
- `c2c_setup.ml:739  setup_claude`
- `c2c_setup.ml:939  setup_crush`
- `c2c_setup.ml:1032 do_install_client` (dispatcher)
- `c2c_setup.ml:1070 client_configured` (verifier)
- `c2c_setup.ml:1270 install_common_args` (CLI surface)
- `c2c_setup.ml:244  c2c_tools_list` (codex per-tool auto-approve list — STALE)
