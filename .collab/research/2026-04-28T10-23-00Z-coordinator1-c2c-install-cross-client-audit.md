# c2c install — cross-client audit (5 setup_<client> functions)

Date: 2026-04-28T10:23Z
Author: coordinator1 (Cairn-Vigil)
Source of truth: `ocaml/cli/c2c_setup.ml` (1433 lines)
Scope: `setup_claude`, `setup_codex`, `setup_opencode`, `setup_kimi`, `setup_gemini`
(plus `setup_crush` for completeness)

---

## 1. Per-client matrix

| Property | claude | codex | opencode | kimi | gemini | crush |
|---|---|---|---|---|---|---|
| Function line | 739 | 252 | 444 | 331 | 389 | 939 |
| Config path | `<proj>/.mcp.json` (default) or `~/.claude.json` (--global) | `~/.codex/config.toml` | `<cwd>/.opencode/opencode.json` + `.opencode/c2c-plugin.json` + plugin symlink | `~/.kimi/mcp.json` | `~/.gemini/settings.json` | `~/.config/crush/crush.json` |
| Format | JSON | TOML (hand-rolled) | JSON | JSON | JSON | JSON |
| Default scope | **project** (since #334) | user | project (cwd) | user | user | user |
| `--scope` flag | **`--global`** flag (claude-only) | none | `--target-dir` flag | none | none | none |
| `--force` honored | yes (passes through) | no (always overwrites c2c stanza) | yes (gates opencode.json overwrite) | no (overwrites c2c key) | no (overwrites c2c key) | no |
| Merge strategy | JSON merge: preserves other `mcpServers.*`, replaces `c2c` | TOML stanza-rewrite: strips `[mcp_servers.c2c*]` sections, appends new | JSON merge: preserves siblings, replaces `c2c` (under `mcp` not `mcpServers`) | JSON merge under `mcpServers` | JSON merge under `mcpServers` | JSON merge under `mcpServers` |
| Top-level key | `mcpServers` | `mcp_servers.c2c` | **`mcp`** (NOT `mcpServers`) | `mcpServers` | `mcpServers` | `mcpServers` |
| Env block key | `env` | `[mcp_servers.c2c.env]` | **`environment`** | `env` | `env` | `env` |
| Hook installed | yes (`~/.claude/hooks/c2c-inbox-check.sh` + settings.json `PostToolUse`) | no | no (uses TS plugin instead) | no | no | no |
| Plugin file | n/a | n/a | symlinks `data/opencode-plugin/c2c.ts` to `.opencode/plugins/c2c.ts` and `~/.config/opencode/plugins/c2c.ts` | n/a | n/a | n/a |

### Env vars per client

| Env var | claude | codex | opencode | kimi | gemini | crush |
|---|---|---|---|---|---|---|
| `C2C_MCP_BROKER_ROOT` | yes | yes | yes | yes | yes | yes |
| `C2C_MCP_AUTO_JOIN_ROOMS=swarm-lounge` | yes | yes | yes | yes | yes | yes |
| `C2C_AUTO_JOIN_ROLE_ROOM=1` | yes | yes | yes | yes | yes | yes |
| `C2C_MCP_AUTO_REGISTER_ALIAS=<alias>` | **yes** | **NO** | **NO** | yes | yes | yes |
| `C2C_MCP_SESSION_ID=<alias>` | **NO** | **NO** | **NO** | yes | yes | yes |
| `C2C_MCP_CLIENT_TYPE` | no | **yes (`codex`)** | no (set elsewhere) | no | no | no |
| `C2C_MCP_AUTO_DRAIN_CHANNEL=0` | no | no | **yes (only opencode)** | no | no | no |
| `C2C_CLI_COMMAND` | no | no | **yes (only opencode)** | no | no | no |
| `C2C_MCP_CHANNEL_DELIVERY=1` | conditional (interactive prompt; default off) | no | no | no | no | no |

Rationale notes from the source:
- claude/codex/opencode managed sessions set `C2C_MCP_SESSION_ID` per-launch in `c2c start`, so the install-time env intentionally omits it. Codex setup explicitly says "shared MCP config only; managed sessions set identity at launch" (line 326).
- kimi/gemini/crush hardcode session=alias because there's no equivalent managed-launch path for them (or, in gemini's case, the path is brand-new from #406a and just landed).
- claude includes `C2C_MCP_AUTO_REGISTER_ALIAS` but NOT `C2C_MCP_SESSION_ID` — asymmetric with codex/opencode (which include neither). This is the only client with that mid-state.

---

## 2. Inconsistencies (headline)

### A. `C2C_MCP_AUTO_REGISTER_ALIAS` is set on 4/6 clients
- **Set**: claude, kimi, gemini, crush
- **Not set**: codex, opencode

Codex and opencode rely on `c2c start` to wire `AUTO_REGISTER_ALIAS` per-launch; if a user runs raw `codex` / `opencode` outside the managed harness, they will not auto-register. claude, by contrast, *does* set it at install time, which means a raw `claude` (no `c2c start`) still auto-registers under the install-time alias. This asymmetry is invisible — there's no doc explaining the split, and the comment at line 326 only covers codex.

### B. `C2C_MCP_SESSION_ID` is set on 3/6 clients
- **Set**: kimi, gemini, crush
- **Not set**: claude, codex, opencode

Same shape of split, but claude is on the *opposite* side from (A). Codex/opencode/claude all defer SESSION_ID to launch time; only kimi/gemini/crush bake it in at install. The cross-cutting consequence: a kimi instance that is `c2c install kimi`'d once and then never re-installed will reuse the same SESSION_ID across every launch, where claude/codex/opencode get a fresh one each `c2c start`. This is a genuine semantic difference, not just a naming inconsistency.

### C. Default scope is split 3-3
- **project**: claude (since #334), opencode
- **user**: codex, kimi, gemini, crush

Only claude exposes a `--scope`-like flag (`--global`). For the other four user-scope clients, switching to project-scope requires hand-editing.

### D. Three different "merge" strategies for JSON
- **claude**: filters `mcpServers` field, removes `c2c`, re-appends. Preserves other servers cleanly.
- **opencode**: same idea but under `mcp` (singular), with a `--force` gate that warns rather than clobbering.
- **kimi/gemini/crush**: similar filter-and-replace, but no `--force` gate; always clobbers.

### E. TOML codex setup hand-rolls section parsing
Lines 263-281 walk lines, detect `[mcp_servers.c2c*]` headers, drop until the next `[`. No real TOML parser. Comments inside a stripped section are silently dropped. Adjacent unrelated comments (e.g. a comment immediately above `[mcp_servers.c2c]`) are preserved but become orphan, which can look like the install corrupted the file.

### F. opencode is the only client whose top-level key is `mcp` (singular)
Every other client uses `mcpServers`. The `client_configured` detector (lines 1070-1151) handles this correctly, but any future shared helper that assumes `mcpServers` will silently miss opencode.

### G. opencode is the only client with `environment` (vs `env`)
opencode-config-schema thing — fine, but no shared `write_mcp_entry` helper exists, so each client's writer hand-codes its env-key name.

### H. `--target-dir` is opencode-only in spirit, but the flag exists at the install_common_args level (line 1277) and is silently ignored for kimi/codex/gemini/crush.
The doc string at line 1278 says "for opencode/claude project config" but it's also threaded into claude as `~project_dir`. For codex/kimi/gemini/crush it has no effect — confusing UX.

### I. `--global` is documented as "(claude only)" at line 1287 and only setup_claude reads it.
Other user-scope clients (kimi, gemini, crush) cannot be flipped to project-scope at all.

### J. Test coverage is wildly uneven
- **claude**: Python regression test for hook body (`tests/test_c2c_install_claude_hook.py`) — guards the `exec` ECHILD bug only.
- **opencode**: there's a `test_c2c_opencode_plugin_drift.ml` for plugin freshness, but no `test_c2c_opencode_install.ml` in the main tree (one exists in a stale worktree).
- **codex, kimi, gemini, crush**: no install tests.
- `tests/test_c2c_install.py` is mostly setup boilerplate; no per-client assertions visible.

### K. setup_gemini ignores `server_path` (`~server_path:_` at line 389)
It hardcodes `command = "c2c-mcp-server"` and `args = []`. If `c2c-mcp-server` is not on PATH, gemini install silently writes a config that won't run. Compare codex/kimi/opencode/crush which fall back to `opam exec -- <server_path>`.

### L. setup_crush is in `install_subcommand_clients` but missing from the docstring narrative around #406a
crush has the full `SESSION_ID + AUTO_REGISTER_ALIAS + AUTO_JOIN_ROOMS + ROLE_ROOM` set, but no comment block above its function explaining the choice (cf. gemini at lines 380-388 which has a 9-line rationale).

### M. CLIENT_TYPE is only set on codex
codex sets `C2C_MCP_CLIENT_TYPE = "codex"` (line 293). The broker can read this for telemetry/branching. No other setup_<client> sets it, so a broker that branches on CLIENT_TYPE silently treats kimi/gemini/crush as "unknown".

---

## 3. Top 5 cleanup slices (1-2hr each, independently sliceable)

### Slice 1: unify `C2C_MCP_CLIENT_TYPE` across all setup_<client> [touches all 5 functions, but tiny]
- File: `ocaml/cli/c2c_setup.ml`
- Lines: 293 (codex sets it), add to claude (~754), opencode (~495), kimi (~343), gemini (~402), crush (~951)
- Change: every env block adds `("C2C_MCP_CLIENT_TYPE", \`String "<client>")`.
- Why: gives the broker a reliable client tag for telemetry without per-launch wiring; trivial review.
- Test: extend `tests/test_c2c_install.py` to invoke `c2c install <client> --dry-run --json` and assert the env contains `C2C_MCP_CLIENT_TYPE` per client.
- Sliceable: yes — purely additive, no semantic change.

### Slice 2: factor out `c2c_env_block` helper [code quality, no behavior change]
- File: `ocaml/cli/c2c_setup.ml`, new helper near line 245 (just before `setup_codex`)
- Replace the 4-5 line `[("C2C_MCP_BROKER_ROOT", ...); ("C2C_MCP_AUTO_JOIN_ROOMS", ...); ...]` literal in setup_claude (752-757), setup_codex (292-295 — TOML, separate writer), setup_kimi (343-347), setup_gemini (402-406), setup_opencode (495-499), setup_crush (951-955).
- Helper signature: `let c2c_mcp_env ~broker_root ~client ?session_id ?auto_register_alias ?(channel_delivery=false) ?(auto_drain_channel=None) ?cli_command () : (string * Yojson.Safe.t) list`
- Why: today there is no single source of truth for "what env vars does a c2c MCP server want?" Future `C2C_MCP_*` additions need 6 separate edits; this drops it to 1.
- Sliceable: yes — pure refactor, semantics preserved.

### Slice 3: add `c2c install gemini` `server_path` fallback [bug fix, gemini-only]
- File: `ocaml/cli/c2c_setup.ml` line 389-441
- Today: hardcoded `command = "c2c-mcp-server"`, throws away `server_path`.
- Change: mirror kimi (lines 339-341) — if `mcp_command = "c2c-mcp-server"` use bare command, else `opam exec -- <server_path>`. Drop the `~server_path:_` underscore.
- Why: install on a host without `c2c-mcp-server` on PATH currently writes broken config silently.
- Test: `tests/test_c2c_install.py::test_gemini_falls_back_to_opam_exec` running with empty PATH.
- Sliceable: yes — single function, no cross-client coupling.

### Slice 4: per-client install integration tests [test coverage]
- New file: `ocaml/cli/test_c2c_install_clients.ml` (or extend `tests/test_c2c_install.py`).
- One test per client: invoke `c2c install <client> --dry-run --json` in a tmpdir HOME, parse the JSON output, assert config path + env var presence per the matrix above.
- Why: today only claude has a regression test (and only for the hook ECHILD bug). The codex/kimi/gemini/crush installers have no smoke at all — easy to break in a #406b-style follow-up.
- Sliceable: yes — additive; pick any subset of clients.

### Slice 5: extend `--global` / `--scope` to all user-scope clients [UX consistency]
- File: `ocaml/cli/c2c_setup.ml` lines 1286-1287 (flag), 1049-1054 (dispatch), 252/331/389/939 (setup_codex/kimi/gemini/crush).
- Today `--global` only affects claude (line 1287 doc says "(claude only)").
- Change: rename to `--scope=user|project` with `--global` retained as alias. For codex/kimi/gemini/crush, `--scope=project` writes `<cwd>/.<client>/<configfile>` instead of `~/.<client>/<configfile>`. (codex already supports per-project `.codex/config.toml` since 0.125 — verify.)
- Why: closes inconsistency (C). Lets a fresh clone wire all clients without polluting user-global configs.
- Test: per-client `--scope=project` test, asserting cwd-relative config path.
- Sliceable: yes — can be done one client at a time (slice5a kimi, 5b gemini, 5c crush, 5d codex).

(Slices ranked roughly by ROI: Slice 2 reduces footprint for every future install change; Slice 1 is the cheapest "make 6 things consistent"; Slice 3 is a real silent-fail bug; Slice 4 is the missing safety net; Slice 5 is the biggest UX win but also the largest behavioral change.)

---

## 4. Recommended baseline contract for `setup_<client>`

Every `setup_<client>` function MUST satisfy these properties. New clients (and #406a/b-style follow-ups) should cross-reference this list.

### Required env vars (write-time)
1. `C2C_MCP_BROKER_ROOT` — absolute broker path.
2. `C2C_MCP_CLIENT_TYPE` — client tag (`"claude"|"codex"|"opencode"|"kimi"|"gemini"|"crush"`). Currently codex-only; should be universal.
3. `C2C_MCP_AUTO_JOIN_ROOMS = "swarm-lounge"` — default social room. Append, don't replace, if user already has rooms configured (today none of the clients implement this — they overwrite).
4. `C2C_AUTO_JOIN_ROLE_ROOM = "1"` — opt-in to role rooms.

### Conditional env vars (write-time)
5. `C2C_MCP_AUTO_REGISTER_ALIAS = <alias>` — set IFF the client has no managed-launch path that injects identity per-session. Document the choice in a comment block above the function.
6. `C2C_MCP_SESSION_ID = <alias>` — same gate as (5). Today this and (5) move together for kimi/gemini/crush but split for claude — claude's behavior should be considered the bug.

### Config write semantics
7. **Atomic**: write to `<path>.tmp`, then `Unix.rename`. (codex/claude do this; kimi/gemini/crush use `json_write_file_or_dryrun` — verify it's atomic.)
8. **Merge-preserving**: never clobber sibling keys (other `mcpServers.*` entries, unrelated TOML sections, unrelated JSON keys). Currently every setup does this for the top-level key but only opencode has a `--force` gate to warn before replacing the c2c entry itself.
9. **Dry-run**: respect `~dry_run`, emit a `[DRY-RUN] would write N bytes to <path>` line.
10. **JSON output**: emit `{ok, client, alias, broker_root, config, ...}` when `output_mode = Json`. Required keys: `ok`, `client`, `alias`, `broker_root`, `config`. (Claude adds `scope` and `hook_status`; opencode adds `session_id` and `plugin`. Optional extensions are fine; required keys must always be present.)
11. **Server-path fallback**: if `mcp_command = "c2c-mcp-server"` use bare command + empty args; else `opam exec -- <server_path>`. setup_gemini violates this today.

### Scope and overrides
12. Honor `--target-dir` if the client has a project-scope config (claude, opencode). Document explicitly when it's a no-op (codex/kimi/gemini/crush today).
13. Honor `--scope=user|project` (post-Slice-5) or document why the client has no project-scope option.
14. Honor `--force` to bypass the "already configured" guard. Today only opencode and claude implement this; kimi/gemini/crush silently overwrite.

### Tests (new contract requirement)
15. Per-client smoke test invoking `c2c install <client> --dry-run --json`, asserting:
    - exit 0
    - JSON output contains required keys from (10)
    - env block in the would-be-written config contains the four required vars from (1)-(4)
    - conditional vars from (5)-(6) match the documented gate

### Documentation
16. Comment block above each `setup_<client>` explaining: config path, scope rationale, why specific env vars are/aren't included, and undo command (e.g. gemini's "Use `gemini mcp remove c2c` to undo" at line 388 is the gold standard).

---

## Appendix: line references (for slice authors)

- `setup_codex`            — `ocaml/cli/c2c_setup.ml:252-327`
- `setup_kimi`             — `ocaml/cli/c2c_setup.ml:331-378`
- `setup_gemini`           — `ocaml/cli/c2c_setup.ml:389-440`
- `setup_opencode`         — `ocaml/cli/c2c_setup.ml:444-607`
- `setup_claude`           — `ocaml/cli/c2c_setup.ml:739-935`
- `setup_crush`            — `ocaml/cli/c2c_setup.ml:939-1021`
- `do_install_client` dispatch — `ocaml/cli/c2c_setup.ml:1032-1061`
- `install_common_args`    — `ocaml/cli/c2c_setup.ml:1270-1289`
- `client_configured` detector — `ocaml/cli/c2c_setup.ml:1070-1151`
- claude hook body         — `ocaml/cli/c2c_setup.ml:611-648`
- claude hook test         — `tests/test_c2c_install_claude_hook.py`
- generic install tests    — `tests/test_c2c_install.py` (mostly boilerplate today)
