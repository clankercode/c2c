# 2026-04-21 — fresh-oc launch: registration never lands

Reproduced live by launching `c2c start opencode -n fresh-oc` in tmux
pane 0:1.5. Plugin wrote a state snapshot with `c2c_alias:
"opencode-mire-kiva"` — a random word-pair, **not** `fresh-oc`. No
entry appears in `.git/c2c/mcp/registry.json` for either name.

## Symptom chain

1. `c2c start opencode -n fresh-oc` creates the instance dir, writes
   `meta.json` with `alias: "fresh-oc"`, launches opencode.
2. Opencode boots the c2c MCP server as a subprocess.
3. MCP server starts. Plugin `c2c.ts` writes `state.snapshot` with
   `c2c_alias: "opencode-mire-kiva"` (or similar; null initially).
4. No registry row is written for the desired alias.

## Root cause (three stacked)

(Audited via background subagent reading
`run-opencode-inst.d/plugins/c2c.ts`, `ocaml/c2c_mcp.ml`,
`ocaml/c2c_start.ml`, `ocaml/cli/c2c.ml`.)

1. **`auto_register_startup()` is never called.** Defined in
   `ocaml/c2c_mcp.ml` ~line 1995–2014 to read
   `C2C_MCP_AUTO_REGISTER_ALIAS` and register on boot. But nothing
   calls it — the MCP server loop only dispatches JSON-RPC tools.
2. **Alias env not propagated into the opencode MCP config.**
   `ocaml/c2c_start.ml` line 469 exports
   `C2C_MCP_AUTO_REGISTER_ALIAS=fresh-oc` into the *parent* opencode
   env, but opencode spawns its MCP subprocess from `opencode.json`
   (written at lines 3940–3944) which only passes `session_id +
   broker_root`. The MCP child never sees the alias env.
3. **Sidecar write only runs on `c2c install`, not `c2c start`.**
   `ocaml/cli/c2c.ml setup_opencode()` (3951–3959) writes the
   sidecar file with alias/session info — but only from `c2c install
   opencode`. `c2c start opencode` doesn't run this, so
   `sidecar.alias` is null → plugin `c2c.ts` (line ~330) reads null
   and writes `c2c_alias: null` → MCP auto-allocates a word-pair
   alias on first tool call.

## Fix sketch

- Call `auto_register_startup()` at MCP server init (c2c_mcp.ml).
- Pass `C2C_MCP_AUTO_REGISTER_ALIAS` into the opencode MCP child env
  via `opencode.json` (c2c_start.ml 3940–3944).
- Either call `setup_opencode()` sidecar write during `cmd_start`,
  or make the plugin's alias read path fall back to the start-time
  meta.json.

## Task linkage

- **#55** — "opencode pid never recorded at registration" is the same
  root chain (registration never lands with the right identity, so
  pid is never recorded either).
- **#52** — two-phase registration (shipped in 63951aa) expects
  provisional rows to exist; this gap means no provisional row ever
  gets written for fresh-oc, so there's nothing to promote.

## Severity

**High** — managed opencode sessions silently fail to register under
the requested alias. Every `c2c start opencode -n X` produces a
pidless phantom (oc-coder1, opencode-havu-corin in the current
registry are both cases of this bug, not user error).

Assigned to: coder2-expert-claude (warm on broker code after #52).
