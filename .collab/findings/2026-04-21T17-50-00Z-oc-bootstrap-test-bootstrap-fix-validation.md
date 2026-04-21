# 2026-04-21 — oc-bootstrap-test: Bootstrap Fix Validation

Role: bootstrap fix validator. Validated the three fixes from
`2026-04-21T15-50-00Z-coordinator1-fresh-oc-register-gap.md`.

## Validation method

Code audit of OCaml sources + OCaml test suite + registry inspection.

---

## Fix #1: `auto_register_startup` called at MCP init

**Finding claim**: `auto_register_startup()` was defined but never called.

**Verified**: `auto_register_startup` is now called in two places:
- `ocaml/server/c2c_mcp_server.ml:203` — MCP server init (`let () = …; C2c_mcp.auto_register_startup ~broker_root:root`)
- `ocaml/cli/c2c.ml:5085` — CLI `mcp` subcommand init

Both call sites pass `~broker_root` correctly. OCaml test suite confirms: 151 tests pass,
including `auto_register_startup skips when alive session has different alias`,
`auto_register_startup skips when alive session owns alias`, and
`auto_register_startup skips when alive same session has different pid`.

**Status**: ✅ FIXED and tested.

---

## Fix #2: `C2C_MCP_AUTO_REGISTER_ALIAS` propagated to opencode MCP child env

**Finding claim**: `c2c_start.ml` exported `C2C_MCP_AUTO_REGISTER_ALIAS` to the parent
env but opencode spawns its MCP subprocess from `opencode.json`, which only passed
`session_id + broker_root`.

**Verified**: `ocaml/c2c_start.ml:build_env` (line 470) now explicitly sets:
```ocaml
"C2C_MCP_AUTO_REGISTER_ALIAS", Option.value alias_override ~default:name;
```
This is propagated to the process environment of the managed opencode inner process.
Additionally, `refresh_opencode_identity` (line 504) actively strips `C2C_MCP_AUTO_REGISTER_ALIAS`
and `C2C_MCP_SESSION_ID` from the shared project `opencode.json` to prevent cross-instance
collision, ensuring these values come only from the per-instance process env.

**Status**: ✅ FIXED.

---

## Fix #3: `setup_opencode`/`refresh_opencode_identity` called during `cmd_start`

**Finding claim**: `setup_opencode()` sidecar write only ran during `c2c install opencode`,
not `c2c start opencode`, so the plugin's `c2c-plugin.json` was always null on start.

**Verified**: `c2c_start.ml:984–1018` in `run_outer_loop` calls
`refresh_opencode_identity ~name ~alias ~broker_root ~project_dir` for every opencode
launch (not just `c2c install`). This writes the sidecar
(`~/.local/share/opencode/…/.opencode/c2c-plugin.json`) with the correct
`session_id` and `alias` before the opencode MCP subprocess starts. Additionally,
if `opencode.json` is missing entirely, `cmd_start` prompts to run `c2c install opencode`
non-interactively in non-TTY contexts.

**Status**: ✅ FIXED.

---

## Registry live check

Current registry (`fresh-oc` repro case):
```
fresh-oc  pid=3486211  ← fix confirmed working
oc-coder1  pid=None    ← old phantom, needs restart to heal
opencode-havu-corin  pid=None ← old phantom, needs restart to heal
```

New opencode launches via `c2c start opencode -n <name>` register correctly with PID.
Old phantom entries (`oc-coder1`, `opencode-havu-corin`) are pre-fix residues —
they will self-heal on the next `c2c start` or can be manually cleaned.

---

## Blockers found

None for the bootstrap fixes themselves. One cross-cutting infrastructure issue:
**`Task` subagent tool fails with `ProviderModelNotFoundError`** — the `Task` tool
dispatch is non-functional for all subagent types (`explore`, `general`, `mm27-general`).
This blocks the required subagent-driven development workflow. See findings index for
writeup.

---

## OCaml test suite

```
opam exec -- ./_build/default/ocaml/test/test_c2c_mcp.exe
151 tests run in 1.331s — all PASS
```

No regressions introduced by the bootstrap fixes.

---

## Recommendation

No further bootstrap validation needed for these three fixes. The remaining open
items are:
1. `Task` tool infrastructure failure (blocker for subagent workflow)
2. Old phantom registry entries (`oc-coder1`, `opencode-havu-corin`) — self-heal on restart,
   or coordinator can sweep if they're known-dead
