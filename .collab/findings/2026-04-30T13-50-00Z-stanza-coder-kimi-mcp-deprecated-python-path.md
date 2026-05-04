# `build_kimi_mcp_config` writes deprecated `python3 c2c_mcp.py` instead of canonical `c2c-mcp-server`

- **UTC:** 2026-04-30T13:50Z
- **Filed by:** stanza-coder
- **Severity:** MEDIUM (works today only because the python script still exists; brittle + slow + drift-prone)
- **Spotted during:** broker-fp split-brain post-mortem cleanup
  (`.collab/findings-archive/2026-04-30T13-30-00Z-broker-fp-split-brain-postmortem.md`),
  while hand-stripping legacy `broker_root` env injections from
  `~/.local/share/c2c/instances/{kuura-viima,lumi-tyyni}/kimi-mcp.json`.
- **Status:** OPEN — needs a slice. Parked as a postmortem follow-up.

## Symptom

Every kimi instance config (`~/.local/share/c2c/instances/<alias>/kimi-mcp.json`)
written by `c2c start kimi` looks like:

```json
{
  "mcpServers": {
    "c2c": {
      "type": "stdio",
      "command": "python3",
      "args": ["/home/xertrov/src/c2c/c2c_mcp.py"],
      "env": { ... }
    }
  }
}
```

The canonical MCP server is the OCaml binary `c2c-mcp-server` (installed
to `~/.local/bin/c2c-mcp-server` via `just install-all`). `c2c_mcp.py`
is in the deprecated python-scripts inventory
(`.collab/runbooks/python-scripts-deprecated.md`); it works only because
nobody has deleted the file yet.

## Root cause

`ocaml/c2c_start.ml:2631-2667` `build_kimi_mcp_config` hardcodes:

```ocaml
"command", `String "python3";
"args", `List [ `String script_path ];   (* script_path = <repo>/c2c_mcp.py *)
```

Compare to the claude/coord codepath in the same file which spawns
`c2c-mcp-server` directly. The kimi codepath was written before the
OCaml MCP server was the canonical surface and was never updated.

## Why it bites

1. **Slower startup** — `python3 c2c_mcp.py` boots a Python interpreter
   per kimi session vs. a native binary.
2. **Different feature set** — the python MCP server lags the OCaml
   one (e.g. tool-list drift; #137 follow-up). New broker tools added
   to `c2c-mcp-server` are silently absent from kimi sessions.
3. **Will break when `c2c_mcp.py` is removed** — once the python
   inventory shrinks (it's been shrinking all month), kimis fail to
   start with `python3: can't open file 'c2c_mcp.py'`. No fail-loud,
   no fallback.
4. **Drift carrier** — the same writer also bakes
   `C2C_MCP_BROKER_ROOT` into the env block (line 2661), which is the
   exact bug class #504 just fixed for `config.json`. So this writer
   has *two* drift bugs to fix in one slice.

## Fix sketch (proposed slice)

Update `build_kimi_mcp_config` in `ocaml/c2c_start.ml` to:

- Set `"command", `String "c2c-mcp-server"` and drop the `args` array
  (or use `["--stdio"]` if the binary needs it; check
  `ocaml/cli/c2c_mcp_main.ml`).
- Apply the #504 skip-when-default rule to `C2C_MCP_BROKER_ROOT`:
  only emit it when `br <> resolve_broker_root ()`.
- Add a regression test in `ocaml/test/test_c2c_start.ml`:
  `kimi_mcp_config_uses_canonical_server` (asserts `command =
  "c2c-mcp-server"`, NOT `"python3"`) and
  `kimi_mcp_config_omits_broker_root_env_when_default` (asserts no
  `C2C_MCP_BROKER_ROOT` key in env when default).
- Migration story for existing pinned configs: same as
  `config.json` — they keep working until next `c2c restart`, at
  which point the new writer regenerates without the pin. No
  forced rewrite.

## Acceptance criteria

- [ ] `command` field is `c2c-mcp-server`, args list reflects actual
      binary CLI (verify with `c2c-mcp-server --help`).
- [ ] `C2C_MCP_BROKER_ROOT` env entry only present when overridden.
- [ ] Both regression tests pass.
- [ ] Fresh kimi `c2c start kimi -n <name>` writes the new shape.
- [ ] Existing kimi sessions resume correctly (broker-side talks to
      both python and OCaml clients identically — no protocol diff
      we know of).

## Related

- #504 (today's slice) — same drift class for `config.json`.
- #137 — tool-list drift between python MCP and OCaml broker
  (root cause of (2) above).
- `.collab/findings-archive/2026-04-30T13-30-00Z-broker-fp-split-brain-postmortem.md`
  — discovery context.
- `.collab/runbooks/python-scripts-deprecated.md` — inventory.

— stanza-coder
